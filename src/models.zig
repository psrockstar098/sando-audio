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

/// A ModelHub install manifest: a JSON sidecar written next to the
/// installed file (`models/<name>.json`). It records where the file
/// came from and its SHA-256, so a later `models list` (or a human)
/// can tell a real installed model from a stray file. Manifests are
/// metadata only — the engine never trusts a manifest over the file
/// itself.
pub const Manifest = struct {
    name: []const u8,
    kind: ModelKind,
    file: []const u8,
    sha256: []const u8,
    size_bytes: u64,
    source: []const u8,
    installed_ms: i64,
};

/// SHA-256 of a file, as a lowercase hex string. Owned; the caller
/// frees it. Streams the file in 64 KiB chunks — a 2 GB weight
/// never sits in RAM whole.
pub fn sha256HexFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try openFileForRead(io, path);
    defer file.close(io);
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        // readSliceShort returns 0 at EOF (no EndOfStream in 0.17.1).
        // NOTE: the destination buffer must NOT be the reader's own
        // buffer — reading into it panics on @memcpy aliasing
        // (found live 2026-11-15: models install crashed the server).
        const n = try reader.interface.readSliceShort(buf[0..]);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

fn openFileForRead(io: std.Io, path: []const u8) !std.Io.File {
    if (std.Io.Dir.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

/// Install a model file into `models_dir` (created when missing)
/// and register it. The source may be any local path; the engine
/// NEVER downloads weights. The installed file keeps the source's
/// base name; the manifest records the SHA-256 and source path.
/// Refuses a non-model extension, a kind/extension mismatch, and
/// overwriting a loaded model. Returns the registry record.
pub fn installModel(
    alloc: std.mem.Allocator,
    io: std.Io,
    registry: *ModelRegistry,
    src_path: []const u8,
    name: []const u8,
    kind: ModelKind,
    models_dir: []const u8,
) !*ModelRecord {
    const ext = std.Io.Dir.path.extension(src_path);
    if (!std.mem.eql(u8, ext, ".gguf") and !std.mem.eql(u8, ext, ".onnx")) return error.InvalidExtension;
    if (std.mem.eql(u8, ext, ".onnx") and kind != .vad) return error.ModelKindMismatch;
    if (std.mem.eql(u8, ext, ".gguf") and kind == .vad) return error.ModelKindMismatch;
    if (registry.lookup(name)) |existing| {
        if (existing.loaded) return error.ModelLoaded;
    }
    const size = try fileSize(io, src_path);
    const base = std.Io.Dir.path.basename(src_path);
    const dest_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ models_dir, base });
    defer alloc.free(dest_path);
    std.Io.Dir.cwd().createDirPath(io, models_dir) catch {};
    // Copy + hash in one streaming pass.
    var src = try openFileForRead(io, src_path);
    defer src.close(io);
    var dst = try std.Io.Dir.cwd().createFile(io, dest_path, .{});
    defer dst.close(io);
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = src.reader(io, &rbuf);
    var wbuf: [64 * 1024]u8 = undefined;
    var writer = dst.writer(io, &wbuf);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        // readSliceShort returns 0 at EOF (no EndOfStream in 0.17.1).
        // NOTE: the destination buffer must NOT be the reader's own
        // buffer — reading into it panics on @memcpy aliasing
        // (found live 2026-11-15: models install crashed the server).
        const n = try reader.interface.readSliceShort(buf[0..]);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        try writer.interface.writeAll(buf[0..n]);
    }
    try writer.interface.flush();
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    // Manifest sidecar: models/<name>.json.
    const manifest_path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ models_dir, name });
    defer alloc.free(manifest_path);
    const manifest = try std.fmt.allocPrint(alloc, "{{\n  \"name\": \"{s}\",\n  \"kind\": \"{s}\",\n  \"file\": \"{s}\",\n  \"sha256\": \"{s}\",\n  \"size_bytes\": {d},\n  \"source\": \"{s}\",\n  \"installed_ms\": {d}\n}}\n", .{ name, @tagName(kind), dest_path, hex, size, src_path, nowMs(io) });
    defer alloc.free(manifest);
    var mfile = try std.Io.Dir.cwd().createFile(io, manifest_path, .{});
    defer mfile.close(io);
    var mbuf: [4096]u8 = undefined;
    var mwriter = mfile.writer(io, &mbuf);
    try mwriter.interface.writeAll(manifest);
    try mwriter.interface.flush();
    return registry.register(name, kind, dest_path, size);
}

/// Remove a model from the registry and delete its file and
/// manifest. Refuses while the model is loaded (unload via the
/// runtime first) and when the name is unknown.
pub fn removeModel(
    alloc: std.mem.Allocator,
    io: std.Io,
    registry: *ModelRegistry,
    name: []const u8,
    models_dir: []const u8,
) !void {
    // The registry is in-memory (built from the config), so a model
    // installed by an earlier process is not in it — but its manifest
    // (models/<name>.json) is the persistent record. A manifest alone
    // is enough to remove: the file it names is deleted too. A loaded
    // model is still refused (it can only be loaded in this process,
    // so it is always in the registry when loaded).
    if (registry.lookup(name)) |rec| {
        if (rec.loaded) return error.ModelLoaded;
        const path = try alloc.dupe(u8, rec.path);
        defer alloc.free(path);
        try registry.remove(name);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    } else {
        const manifest_path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ models_dir, name });
        defer alloc.free(manifest_path);
        const manifest = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, alloc, .limited(1 << 20)) catch
            return error.ModelNotFound;
        defer alloc.free(manifest);
        const parsed = std.json.parseFromSlice(Manifest, alloc, manifest, .{}) catch
            return error.ModelNotFound;
        defer parsed.deinit();
        std.Io.Dir.cwd().deleteFile(io, parsed.value.file) catch {};
    }
    const manifest_path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ models_dir, name });
    defer alloc.free(manifest_path);
    std.Io.Dir.cwd().deleteFile(io, manifest_path) catch {};
}

test "install + remove round-trip from a local file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir = "test-models-install";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    // A small fake weight (not a real model — install only copies
    // and hashes; loading is never attempted here).
    const src_path = "test-models-install-src.gguf";
    {
        var f = try std.Io.Dir.cwd().createFile(io, src_path, .{});
        defer f.close(io);
        var buf: [256]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("fake-gguf-bytes-for-install-test");
        try w.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, src_path) catch {};
    var reg = ModelRegistry.init(alloc, 10, 1 << 30);
    defer reg.deinit();
    const rec = try installModel(alloc, io, &reg, src_path, "test-model", .stt, dir);
    try std.testing.expectEqualStrings("test-model", rec.name);
    try std.testing.expectEqual(@as(u64, 32), rec.size_bytes);
    // Manifest exists and names the model.
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test-models-install/test-model.json", alloc, .limited(1 << 20));
    defer alloc.free(manifest_bytes);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"test-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"sha256\"") != null);
    // Wrong extension refused; loaded model refused on remove.
    try std.testing.expectError(error.InvalidExtension, installModel(alloc, io, &reg, "LICENSE", "bad", .stt, dir));
    try reg.markLoaded("test-model", true);
    try std.testing.expectError(error.ModelLoaded, removeModel(alloc, io, &reg, "test-model", dir));
    try reg.markLoaded("test-model", false);
    try removeModel(alloc, io, &reg, "test-model", dir);
    try std.testing.expect(reg.lookup("test-model") == null);
    try std.testing.expectError(error.ModelNotFound, removeModel(alloc, io, &reg, "test-model", dir));
}

test "install a file larger than the 64 KiB copy buffer (aliasing regression)" {
    // 2026-11-15: installModel read into the reader's own buffer,
    // which panicked on @memcpy aliasing once the file exceeded one
    // buffer fill — and crashed the live server on a real install.
    // A 200 KiB file forces several copy passes.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const dir = "test-models-install-big";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const src_path = "test-models-install-big-src.gguf";
    {
        var f = try std.Io.Dir.cwd().createFile(io, src_path, .{});
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        var written: usize = 0;
        while (written < 200 * 1024) : (written += 8) {
            try w.interface.writeAll("abcdefgh");
        }
        try w.interface.flush();
    }
    defer std.Io.Dir.cwd().deleteFile(io, src_path) catch {};
    var reg = ModelRegistry.init(alloc, 10, 1 << 30);
    defer reg.deinit();
    const rec = try installModel(alloc, io, &reg, src_path, "big-model", .stt, dir);
    try std.testing.expectEqual(@as(u64, 200 * 1024), rec.size_bytes);
    // The copy is byte-identical: hash the copy and compare.
    const copied = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, "test-models-install-big-src.gguf" });
    defer alloc.free(copied);
    const hex_src = try sha256HexFile(alloc, io, src_path);
    defer alloc.free(hex_src);
    const hex_dst = try sha256HexFile(alloc, io, copied);
    defer alloc.free(hex_dst);
    try std.testing.expectEqualStrings(hex_src, hex_dst);
    try removeModel(alloc, io, &reg, "big-model", dir);
    try std.testing.expect(reg.lookup("big-model") == null);
}

test "sha256HexFile matches the known empty-string digest" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const path = "test-models-empty.gguf";
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        f.close(io);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const hex = try sha256HexFile(alloc, io, path);
    defer alloc.free(hex);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hex);
}
