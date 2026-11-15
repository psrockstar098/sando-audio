//! High-performance memory management for the real-time audio path.
//!
//! Rules enforced here:
//!   - All buffers are preallocated at engine start. Nothing in the audio
//!     path allocates after that.
//!   - Frames move by pointer through a lock-free SPSC ring (zero-copy).
//!   - `AudioArena` is a bump allocator over a preallocated block for
//!     short-lived per-frame scratch; it is reset, never freed per item.

const std = @import("std");

/// One audio frame: 10 ms at 24 kHz = 240 samples, mono f32.
/// Frame length is fixed at pool creation time; this is the default.
pub const default_frame_len: usize = 240;

/// A spinlock for the frame pool's short critical sections (a few array
/// accesses). No `std.Thread.Mutex` in Zig 0.17 — the replacement
/// `std.Io.Mutex` needs an Io instance, which the pool API does not carry.
const SpinLock = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

pub const Frame = struct {
    samples: []f32,
    /// Number of valid samples in `samples` (<= samples.len).
    len: usize = 0,
    /// Monotonic sequence number assigned by the producer.
    seq: u64 = 0,
};

/// A preallocated pool of frames. acquire() hands out a frame, release()
/// returns it. No allocation happens after init. The pool is mutex-guarded:
/// it is for setup/worker threads, not for the lock-free audio callback —
/// the callback passes already-acquired frame pointers through RingBuffer.
pub const FramePool = struct {
    frames: []Frame,
    storage: []f32,
    free_list: []usize,
    free_len: usize,
    mutex: SpinLock = .{},
    frame_len: usize,

    pub fn init(alloc: std.mem.Allocator, frame_count: usize, frame_len: usize) !FramePool {
        const storage = try alloc.alloc(f32, frame_count * frame_len);
        errdefer alloc.free(storage);
        const frames = try alloc.alloc(Frame, frame_count);
        errdefer alloc.free(frames);
        const free_list = try alloc.alloc(usize, frame_count);
        errdefer alloc.free(free_list);
        for (0..frame_count) |i| {
            frames[i] = .{ .samples = storage[i * frame_len .. (i + 1) * frame_len] };
            free_list[i] = frame_count - 1 - i;
        }
        return .{
            .frames = frames,
            .storage = storage,
            .free_list = free_list,
            .free_len = frame_count,
            .frame_len = frame_len,
        };
    }

    pub fn deinit(self: *FramePool, alloc: std.mem.Allocator) void {
        alloc.free(self.storage);
        alloc.free(self.frames);
        alloc.free(self.free_list);
        self.* = undefined;
    }

    pub fn acquire(self: *FramePool) ?*Frame {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.free_len == 0) return null;
        self.free_len -= 1;
        const idx = self.free_list[self.free_len];
        const frame = &self.frames[idx];
        frame.len = 0;
        return frame;
    }

    pub fn release(self: *FramePool, frame: *Frame) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = (@intFromPtr(frame) - @intFromPtr(self.frames.ptr)) / @sizeOf(Frame);
        std.debug.assert(idx < self.frames.len);
        self.free_list[self.free_len] = idx;
        self.free_len += 1;
    }

    pub fn available(self: *FramePool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.free_len;
    }

    pub fn capacity(self: *const FramePool) usize {
        return self.frames.len;
    }
};

/// Single-producer / single-consumer lock-free ring. The hot path moves
/// frame pointers, never sample data. Capacity must be a power of two.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        items: []T,
        mask: usize,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, cap: usize) !Self {
            std.debug.assert(cap > 0 and (cap & (cap - 1)) == 0);
            return .{
                .items = try alloc.alloc(T, cap),
                .mask = cap - 1,
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            alloc.free(self.items);
            self.* = undefined;
        }

        pub fn push(self: *Self, item: T) bool {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            if (head - tail >= self.items.len) return false; // full
            self.items[head & self.mask] = item;
            self.head.store(head + 1, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.acquire);
            const head = self.head.load(.acquire);
            if (tail == head) return null; // empty
            const item = self.items[tail & self.mask];
            self.tail.store(tail + 1, .release);
            return item;
        }

        pub fn len(self: *Self) usize {
            return self.head.load(.acquire) -% self.tail.load(.acquire);
        }

        pub fn capacity(self: *const Self) usize {
            return self.items.len;
        }
    };
}

/// Bump allocator over a preallocated block. For short-lived per-frame
/// scratch inside the audio path. reset() reclaims everything at once;
/// individual frees do not exist by design.
pub const AudioArena = struct {
    buf: []u8,
    used: usize = 0,

    pub fn init(alloc: std.mem.Allocator, size: usize) !AudioArena {
        return .{ .buf = try alloc.alloc(u8, size) };
    }

    pub fn deinit(self: *AudioArena, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        self.* = undefined;
    }

    pub fn allocBytes(self: *AudioArena, n: usize, alignment: u29) ?[]u8 {
        const addr = @intFromPtr(self.buf.ptr) + self.used;
        const aligned = std.mem.alignForward(usize, addr, alignment);
        const pad = aligned - addr;
        if (self.used + pad + n > self.buf.len) return null;
        self.used += pad + n;
        return self.buf[self.used - n .. self.used];
    }

    pub fn reset(self: *AudioArena) void {
        self.used = 0;
    }

    pub fn usedBytes(self: *const AudioArena) usize {
        return self.used;
    }

    pub fn capacityBytes(self: *const AudioArena) usize {
        return self.buf.len;
    }
};

test "frame pool acquire/release" {
    const alloc = std.testing.allocator;
    var pool = try FramePool.init(alloc, 4, default_frame_len);
    defer pool.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), pool.available());
    const f0 = pool.acquire().?;
    const f1 = pool.acquire().?;
    _ = f1;
    try std.testing.expectEqual(@as(usize, 2), pool.available());
    pool.release(f0);
    try std.testing.expectEqual(@as(usize, 3), pool.available());
    // Exhaustion returns null instead of allocating.
    _ = pool.acquire().?;
    _ = pool.acquire().?;
    _ = pool.acquire().?;
    try std.testing.expect(pool.acquire() == null);
}

test "ring buffer wraparound and full/empty" {
    const alloc = std.testing.allocator;
    var ring = try RingBuffer(u32).init(alloc, 4);
    defer ring.deinit(alloc);
    try std.testing.expect(ring.pop() == null);
    try std.testing.expect(ring.push(1));
    try std.testing.expect(ring.push(2));
    try std.testing.expect(ring.push(3));
    try std.testing.expect(ring.push(4));
    try std.testing.expect(!ring.push(5)); // full
    try std.testing.expectEqual(@as(?u32, 1), ring.pop());
    try std.testing.expect(ring.push(5)); // wraparound slot reuse
    try std.testing.expectEqual(@as(?u32, 2), ring.pop());
    try std.testing.expectEqual(@as(?u32, 3), ring.pop());
    try std.testing.expectEqual(@as(?u32, 4), ring.pop());
    try std.testing.expectEqual(@as(?u32, 5), ring.pop());
    try std.testing.expect(ring.pop() == null);
}

test "audio arena bump and reset" {
    const alloc = std.testing.allocator;
    var arena = try AudioArena.init(alloc, 64);
    defer arena.deinit(alloc);
    const a = arena.allocBytes(16, 8).?;
    try std.testing.expectEqual(@as(usize, 16), a.len);
    try std.testing.expect(arena.allocBytes(64, 8) == null); // does not fit
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.usedBytes());
    try std.testing.expect(arena.allocBytes(64, 8) != null);
}
