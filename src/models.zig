//! Model registry (ModelHub + SmartCache): bookkeeping for every model
//! the engine knows about, with LRU eviction over *unloaded* models.
//!
//! Loading itself stays in runtime.zig; this module only tracks. A
//! loaded model is never evicted silently — unloading a live model
//! mid-session would desync the runtime, so eviction stops with
//! error.RegistryFull and the caller decides.

const std = @import("std");
const config = @import("config.zig");

pub const ModelKind = config.ModelKind;

pub const ModelRecord = struct {
    /// Owned by the registry's arena (copied at register time).
    name: []const u8,
    kind: ModelKind,
    /// Owned by the registry's arena (copied at register time).
    path: []const u8,
    loaded: bool = false,
    size_bytes: u64 = 0,
    /// Wall-clock milliseconds of last use (for LRU).
    last_used_ms: i64 = 0,
};

pub const RegistryError = error{
    RegistryFull,
    ModelLoaded,
    ModelNotFound,
    OutOfMemory,
};

pub const ModelRegistry = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    records: std.StringHashMap(*ModelRecord),
    max_models: usize,
    max_bytes: u64,

    pub fn init(alloc: std.mem.Allocator, max_models: usize, max_bytes: u64) ModelRegistry {
        return .{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .records = std.StringHashMap(*ModelRecord).init(alloc),
            .max_models = max_models,
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *ModelRegistry) void {
        self.records.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const ModelRegistry) usize {
        return self.records.count();
    }

    pub fn totalBytes(self: *const ModelRegistry) u64 {
        var total: u64 = 0;
        var it = self.records.valueIterator();
        while (it.next()) |r| total += r.*.size_bytes;
        return total;
    }

    pub fn lookup(self: *ModelRegistry, name: []const u8) ?*ModelRecord {
        return self.records.get(name);
    }

    /// Register a model (or refresh an existing entry's size). Names and
    /// paths are copied into the registry's arena — the registry never
    /// borrows config strings. Evicts least-recently-used *unloaded*
    /// models while over either limit.
    pub fn register(
        self: *ModelRegistry,
        name: []const u8,
        kind: ModelKind,
        path: []const u8,
        size_bytes: u64,
    ) !*ModelRecord {
        if (self.records.get(name)) |existing| {
            existing.size_bytes = size_bytes;
            return existing;
        }
        while (self.count() >= self.max_models or
            self.totalBytes() + size_bytes > self.max_bytes)
        {
            // evictOne only ever fails with RegistryFull.
            self.evictOne() catch return error.RegistryFull;
        }
        const a = self.arena.allocator();
        const owned_name = try a.dupe(u8, name);
        const owned_path = try a.dupe(u8, path);
        const rec = try a.create(ModelRecord);
        rec.* = .{
            .name = owned_name,
            .kind = kind,
            .path = owned_path,
            .size_bytes = size_bytes,
        };
        try self.records.put(owned_name, rec);
        return rec;
    }

    /// Remove a record. Refuses while the model is loaded — unload via
    /// the runtime first.
    pub fn remove(self: *ModelRegistry, name: []const u8) RegistryError!void {
        const rec = self.records.get(name) orelse return error.ModelNotFound;
        if (rec.loaded) return error.ModelLoaded;
        _ = self.records.remove(name);
    }

    pub fn markLoaded(self: *ModelRegistry, name: []const u8, loaded: bool) RegistryError!void {
        const rec = self.records.get(name) orelse return error.ModelNotFound;
        rec.loaded = loaded;
    }

    /// Record a use at wall-clock time `now_ms` (milliseconds since epoch).
    pub fn markUsed(self: *ModelRegistry, name: []const u8, now_ms: i64) RegistryError!void {
        const rec = self.records.get(name) orelse return error.ModelNotFound;
        rec.last_used_ms = now_ms;
    }

    /// Record a use right now.
    pub fn touch(self: *ModelRegistry, io: std.Io, name: []const u8) RegistryError!void {
        return self.markUsed(name, nowMs(io));
    }

    /// Evict the least-recently-used unloaded record. Fails honestly
    /// when every record is loaded.
    fn evictOne(self: *ModelRegistry) !void {
        var victim: ?*ModelRecord = null;
        var it = self.records.valueIterator();
        while (it.next()) |r| {
            if (r.*.loaded) continue;
            if (victim == null or r.*.last_used_ms < victim.?.last_used_ms) {
                victim = r.*;
            }
        }
        const v = victim orelse return error.RegistryFull;
        _ = self.records.remove(v.name);
    }
};

/// Wall-clock milliseconds since the Unix epoch.
pub fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return @intCast(@divFloor(ts.raw.nanoseconds, 1_000_000));
}

/// File size in bytes. Relative paths resolve against the working
/// directory; absolute paths are used as-is.
pub fn fileSize(io: std.Io, path: []const u8) !u64 {
    if (std.Io.Dir.path.isAbsolute(path)) {
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        return (try file.stat(io)).size;
    }
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    return st.size;
}

test "register, lookup, totals" {
    const alloc = std.testing.allocator;
    var reg = ModelRegistry.init(alloc, 10, 1 << 30);
    defer reg.deinit();
    _ = try reg.register("tts", .tts, "models/tts.gguf", 600_000_000);
    _ = try reg.register("stt", .stt, "models/stt.gguf", 400_000_000);
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expectEqual(@as(u64, 1_000_000_000), reg.totalBytes());
    const tts = reg.lookup("tts").?;
    try std.testing.expect(tts.kind == .tts);
    try std.testing.expect(!tts.loaded);
    try std.testing.expect(reg.lookup("ghost") == null);
    // Re-registering refreshes size instead of duplicating.
    _ = try reg.register("tts", .tts, "models/tts.gguf", 610_000_000);
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expectEqual(@as(u64, 1_010_000_000), reg.totalBytes());
}

test "LRU eviction removes the least recently used unloaded model" {
    const alloc = std.testing.allocator;
    var reg = ModelRegistry.init(alloc, 2, 1 << 30);
    defer reg.deinit();
    _ = try reg.register("a", .tts, "a.gguf", 100);
    _ = try reg.register("b", .stt, "b.gguf", 100);
    try reg.markUsed("a", 1000);
    try reg.markUsed("b", 500); // b is older
    _ = try reg.register("c", .vad, "c.gguf", 100);
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expect(reg.lookup("b") == null);
    try std.testing.expect(reg.lookup("a") != null);
    try std.testing.expect(reg.lookup("c") != null);
}

test "eviction refuses when every model is loaded" {
    const alloc = std.testing.allocator;
    var reg = ModelRegistry.init(alloc, 1, 1 << 30);
    defer reg.deinit();
    _ = try reg.register("a", .tts, "a.gguf", 100);
    try reg.markLoaded("a", true);
    try std.testing.expectError(error.RegistryFull, reg.register("b", .stt, "b.gguf", 100));
    try std.testing.expectError(error.ModelLoaded, reg.remove("a"));
    try reg.markLoaded("a", false);
    try reg.remove("a");
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

test "fileSize reads a real file" {
    const io = std.testing.io;
    const size = try fileSize(io, "LICENSE");
    try std.testing.expect(size > 0);
    try std.testing.expectError(error.FileNotFound, fileSize(io, "no-such-file-xyz"));
}
