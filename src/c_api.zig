//! C API for embedding sando-audio in other programs.
//!
//! Plain C ABI. Single-engine-per-process in Phase 1; functions are
//! not thread-safe. Strings returned are static (owned by the engine
//! or the library) unless noted. Inference entry points land in Phase 2
//! — this surface covers lifecycle, introspection, and model loading,
//! all of which are verifiable now.

const std = @import("std");
const audiocpp = @import("audiocpp.zig");
const config = @import("config.zig");
const engine = @import("engine.zig");

pub const version_string: [:0]const u8 = "0.1.0";

const CEngine = struct {
    threaded: std.Io.Threaded,
    eng: engine.Engine,
};

var last_error_buf: [512]u8 = undefined;
var last_error_len: usize = 0;

fn setError(msg: []const u8) void {
    const n = @min(msg.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..n], msg[0..n]);
    last_error_buf[n] = 0;
    last_error_len = n;
}

fn setErrorFromErr(err: anyerror) void {
    setError(@errorName(err));
}

/// Human-readable detail for the most recent failure, or "no error".
pub export fn sando_last_error() [*:0]const u8 {
    if (last_error_len == 0) return "no error";
    return @ptrCast(&last_error_buf);
}

/// Library version, e.g. "0.1.0".
pub export fn sando_version() [*:0]const u8 {
    return version_string;
}

/// Create an engine from a config file. `config_path` may be NULL for
/// the default (config/sando.toml). Returns NULL on failure — see
/// sando_last_error(). Destroy with sando_engine_destroy().
pub export fn sando_engine_create(config_path: ?[*:0]const u8) ?*CEngine {
    const alloc = std.heap.c_allocator;
    const out = alloc.create(CEngine) catch {
        setError("OutOfMemory");
        return null;
    };
    // Initialise Threaded in place: the engine's Io borrows this address,
    // so it must be heap-stable before anything uses it.
    out.threaded = std.Io.Threaded.init(alloc, .{});
    const io = out.threaded.io();
    errdefer {
        out.threaded.deinit();
        alloc.destroy(out);
    }

    const path = if (config_path) |p| std.mem.span(p) else engine.default_config_path;
    const cfg = config.loadFromFile(alloc, io, path) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    out.eng = engine.Engine.init(alloc, io, cfg) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    return out;
}

pub export fn sando_engine_destroy(e: ?*CEngine) void {
    const eng = e orelse return;
    eng.eng.deinit();
    eng.threaded.deinit();
    std.heap.c_allocator.destroy(eng);
}

/// Selected backend name, e.g. "cpu".
pub export fn sando_engine_backend(e: *CEngine) [*:0]const u8 {
    return switch (e.eng.selected_backend.kind) {
        .cuda => "cuda",
        .hip => "hip",
        .vulkan => "vulkan",
        .metal => "metal",
        .sycl => "sycl",
        .webgpu => "webgpu",
        .cpu => "cpu",
    };
}

/// 1 when audio.cpp is linked, 0 for the null backend.
pub export fn sando_engine_linked(e: *CEngine) c_int {
    return if (e.eng.isLinked()) 1 else 0;
}

/// Number of audio.cpp task tokens (0 when not linked).
pub export fn sando_engine_task_count(e: *CEngine) usize {
    return e.eng.rt.taskCount();
}

/// Task token at `index`, or NULL when out of range. The string is
/// owned by audio.cpp and stays valid while the engine lives.
pub export fn sando_engine_task_name(e: *CEngine, index: usize) ?[*:0]const u8 {
    const name = e.eng.rt.taskName(index) orelse return null;
    // taskName slices a NUL-terminated C string, so the terminator
    // follows the slice.
    return @ptrCast(name.ptr);
}

/// Load a model file into the engine. `kind` is "tts", "stt" or "vad".
/// Returns 0 on success, -1 on failure (see sando_last_error()).
/// No weights are ever downloaded — `path` must already exist.
pub export fn sando_engine_load_model(
    e: *CEngine,
    name: [*:0]const u8,
    kind: [*:0]const u8,
    path: [*:0]const u8,
) c_int {
    const model_kind = config.ModelKind.fromName(std.mem.span(kind)) orelse {
        setError("UnknownModelKind");
        return -1;
    };
    e.eng.loadModel(std.mem.span(name), model_kind, std.mem.span(path)) catch |err| {
        setErrorFromErr(err);
        return -1;
    };
    return 0;
}

/// Validate a config file without starting an engine. Returns 0 when
/// the file parses and validates, -1 otherwise.
pub export fn sando_config_validate(path: [*:0]const u8) c_int {
    const alloc = std.heap.c_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var cfg = config.loadFromFile(alloc, io, std.mem.span(path)) catch |err| {
        setErrorFromErr(err);
        return -1;
    };
    cfg.deinit();
    return 0;
}

test "c api create and destroy with a real config" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg_text =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "cpu"
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "sando.toml", .data = cfg_text });
    // tmpDir lives under .zig-cache/tmp/<random> in the working dir.
    const rel = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/sando.toml", .{tmp.sub_path});
    defer alloc.free(rel);
    const rel_buf = try alloc.allocSentinel(u8, rel.len, 0);
    defer alloc.free(rel_buf);
    @memcpy(rel_buf[0..rel.len], rel);
    const rel_z = rel_buf[0..rel.len :0];

    const e = sando_engine_create(rel_z.ptr) orelse {
        std.debug.print("create failed: {s}\n", .{std.mem.span(sando_last_error())});
        return error.EngineCreateFailed;
    };
    defer sando_engine_destroy(e);
    try std.testing.expectEqualStrings("cpu", std.mem.span(sando_engine_backend(e)));
    if (audiocpp.has_link) {
        try std.testing.expectEqual(@as(c_int, 1), sando_engine_linked(e));
        try std.testing.expectEqual(@as(usize, 17), sando_engine_task_count(e));
        try std.testing.expectEqualStrings("tts", std.mem.span(sando_engine_task_name(e, 5).?));
    } else {
        try std.testing.expectEqual(@as(c_int, 0), sando_engine_linked(e));
        try std.testing.expectEqual(@as(usize, 0), sando_engine_task_count(e));
    }
    try std.testing.expect(sando_engine_task_name(e, 1_000_000) == null);
    try std.testing.expectEqual(@as(c_int, 0), sando_config_validate(rel_z.ptr));
}

test "c api create fails honestly without a config file" {
    // No config/sando.toml exists in the repo yet — create must fail
    // cleanly instead of crashing, and last_error must say why.
    const e = sando_engine_create("config/does-not-exist.toml");
    try std.testing.expect(e == null);
    try std.testing.expect(!std.mem.eql(u8, std.mem.span(sando_last_error()), "no error"));
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(sando_version()));
    try std.testing.expectEqual(@as(c_int, -1), sando_config_validate("config/does-not-exist.toml"));
}
