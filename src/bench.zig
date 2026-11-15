//! Benchmarks: memory-path throughput (always runnable) and inference
//! latency (requires a loaded model + session; reported as skipped
//! otherwise — never faked).

const std = @import("std");
const memory = @import("memory.zig");
const runtime = @import("runtime.zig");

pub const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,

    pub fn meanNs(self: *const BenchResult) f64 {
        if (self.iterations == 0) return 0;
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.iterations));
    }

    pub fn opsPerSecond(self: *const BenchResult) f64 {
        if (self.total_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.iterations)) * 1_000_000_000.0 /
            @as(f64, @floatFromInt(self.total_ns));
    }
};

fn nowNs(io: std.Io) u64 {
    const ts = std.Io.Clock.Timestamp.now(io, .awake);
    return @intCast(ts.raw.nanoseconds);
}

/// Benchmark the zero-copy memory path: frame pool acquire/release,
/// ring push/pop, and arena bump allocation. Always runnable.
pub fn benchMemory(alloc: std.mem.Allocator, io: std.Io, iterations: u64) !BenchResult {
    var pool = try memory.FramePool.init(alloc, 64, memory.default_frame_len);
    defer pool.deinit(alloc);
    var ring = try memory.RingBuffer(*memory.Frame).init(alloc, 64);
    defer ring.deinit(alloc);
    var arena = try memory.AudioArena.init(alloc, 1 << 20);
    defer arena.deinit(alloc);

    // Warm up once so first-touch costs do not dominate.
    const f = pool.acquire().?;
    _ = ring.push(f);
    _ = ring.pop();
    pool.release(f);
    _ = arena.allocBytes(64, 8);
    arena.reset();

    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const start = nowNs(io);
        const frame = pool.acquire() orelse return error.OutOfMemory;
        _ = ring.push(frame);
        const back = ring.pop() orelse return error.OutOfMemory;
        pool.release(back);
        _ = arena.allocBytes(64, 8);
        arena.reset();
        const elapsed = nowNs(io) - start;
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }
    return .{
        .name = "memory-path (pool + ring + arena, per iteration)",
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

/// Benchmark one offline inference request, repeated. Requires a live
/// session (a loaded model). Returns the per-request latency distribution.
pub fn benchInference(
    session: *runtime.Session,
    io: std.Io,
    alloc: std.mem.Allocator,
    req: runtime.Request,
    iterations: u64,
) !BenchResult {
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        var resp = try session.run(io, alloc, req);
        defer resp.deinit();
        total_ns += resp.latency_ns;
        if (resp.latency_ns < min_ns) min_ns = resp.latency_ns;
        if (resp.latency_ns > max_ns) max_ns = resp.latency_ns;
    }
    return .{
        .name = "inference (per request)",
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

pub fn printResult(writer: *std.Io.Writer, r: *const BenchResult) !void {
    try writer.print(
        "  {s}\n    iterations: {d}  mean: {d:.1} ns  min: {d} ns  max: {d} ns  ({d:.0} ops/s)\n",
        .{ r.name, r.iterations, r.meanNs(), r.min_ns, r.max_ns, r.opsPerSecond() },
    );
}

test "memory bench runs and reports sane numbers" {
    const alloc = std.testing.allocator;
    const r = try benchMemory(alloc, std.testing.io, 1000);
    try std.testing.expectEqual(@as(u64, 1000), r.iterations);
    try std.testing.expect(r.meanNs() > 0);
    try std.testing.expect(r.min_ns <= r.max_ns);
    try std.testing.expect(r.opsPerSecond() > 0);
}
