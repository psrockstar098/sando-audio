//! The runtime: sessions, requests, responses, streaming, latency.
//!
//! A thin, honest layer over audiocpp.zig. It maps SANDO task kinds to
//! audio.cpp task tokens (discovered live: asr, tts, vad), owns the
//! registry and loaded models, and measures per-request latency on the
//! monotonic clock. No model is ever faked: when the library is not
//! linked, every inference call returns error.AudioCppNotLinked.

const std = @import("std");
const audiocpp = @import("audiocpp.zig");

pub const TaskKind = enum { vad, asr, tts };

/// Audio.cpp task tokens, verified live against the vendored 0.9.3
/// library (17 tasks: vad asr diar sep gen tts clon vc s2s align vdes
/// spk svc midi turn wake cls).
pub fn taskToken(kind: TaskKind) []const u8 {
    return switch (kind) {
        .vad => "vad",
        .asr => "asr",
        .tts => "tts",
    };
}

pub const StreamMode = enum { offline, streaming };

pub fn modeToken(mode: StreamMode) []const u8 {
    return switch (mode) {
        .offline => "offline",
        .streaming => "streaming",
    };
}

/// One inference request. For TTS set `text`; for ASR/VAD set `audio`.
/// `audio` is interleaved float PCM, copied into the request by the
/// backend — the caller keeps ownership.
pub const Request = struct {
    task: TaskKind,
    mode: StreamMode = .offline,
    text: ?[]const u8 = null,
    language: ?[]const u8 = null,
    audio: ?[]const f32 = null,
    sample_rate: u32 = 24000,
    channels: u8 = 1,
};

/// One inference response. Wraps the audio.cpp result; `deinit` frees it.
/// Text and audio accessors borrow from the result — valid until deinit.
pub const Response = struct {
    result: audiocpp.Result,
    latency_ns: u64 = 0,

    pub fn deinit(self: *Response) void {
        self.result.deinit();
        self.* = undefined;
    }

    pub fn text(self: *Response) !struct { text: []const u8, language: []const u8 } {
        const t = try self.result.text();
        return .{ .text = t.text, .language = t.language };
    }

    pub fn audio(self: *Response) !struct { samples: []const f32, sample_rate: u32, channels: u8 } {
        const a = try self.result.audio();
        return .{ .samples = a.samples, .sample_rate = a.sample_rate, .channels = a.channels };
    }

    /// Latency in milliseconds, for display and bench output.
    pub fn latencyMs(self: *const Response) f64 {
        return @as(f64, @floatFromInt(self.latency_ns)) / 1_000_000.0;
    }
};

/// A live inference session: one loaded model + one task + one mode.
/// Owns its backend-name string (NUL-terminated copy for the C ABI).
pub const Session = struct {
    inner: audiocpp.Session,
    task: TaskKind,
    mode: StreamMode,
    backend_name_z: ?[:0]const u8 = null,

    pub fn create(
        alloc: std.mem.Allocator,
        model: *const audiocpp.Model,
        task: TaskKind,
        mode: StreamMode,
        backend_name: ?[]const u8,
        device: i32,
        threads: i32,
    ) !Session {
        var backend_z: ?[:0]const u8 = null;
        if (backend_name) |name| {
            const buf = try alloc.allocSentinel(u8, name.len, 0);
            @memcpy(buf[0..name.len], name);
            backend_z = buf[0..name.len :0];
        }
        errdefer if (backend_z) |z| alloc.free(z);
        const cfg = audiocpp.BackendConfig{
            .backend = if (backend_z) |z| z.ptr else null,
            .device = @intCast(device),
            .threads = @intCast(threads),
        };
        var inner = try audiocpp.Session.create(alloc, model, taskToken(task), modeToken(mode), cfg);
        errdefer inner.deinit();
        return .{
            .inner = inner,
            .task = task,
            .mode = mode,
            .backend_name_z = backend_z,
        };
    }

    pub fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        self.inner.deinit();
        if (self.backend_name_z) |z| alloc.free(z);
        self.* = undefined;
    }

    pub fn family(self: *const Session) []const u8 {
        return self.inner.family();
    }

    /// Run one offline request. Measures latency on the monotonic clock.
    pub fn run(self: *Session, io: std.Io, alloc: std.mem.Allocator, req: Request) !Response {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        var request = try audiocpp.Request.create();
        defer request.deinit();
        if (req.text) |t| try request.setText(alloc, t, req.language);
        if (req.audio) |a| try request.setAudio(a, req.sample_rate, req.channels);
        var result = try self.inner.run(&request);
        errdefer result.deinit();
        const end = std.Io.Clock.Timestamp.now(io, .awake);
        const ns: u64 = @intCast(start.durationTo(end).raw.nanoseconds);
        return .{ .result = result, .latency_ns = ns };
    }

    /// Streaming: open a stream, optionally seeded with `req`.
    pub fn streamStart(self: *Session, alloc: std.mem.Allocator, req: ?Request) !void {
        if (req) |r| {
            var request = try audiocpp.Request.create();
            defer request.deinit();
            if (r.text) |t| try request.setText(alloc, t, r.language);
            if (r.audio) |a| try request.setAudio(a, r.sample_rate, r.channels);
            return self.inner.streamStart(&request);
        }
        return self.inner.streamStart(null);
    }

    /// Push one audio chunk. Returns an event handle when the backend
    /// produced output for this chunk; the caller must free it.
    pub fn streamPush(
        self: *Session,
        samples: []const f32,
        sample_rate: u32,
        channels: u8,
        start_sample: i64,
    ) !?*audiocpp.EventHandle {
        return self.inner.streamPush(samples, sample_rate, channels, start_sample);
    }

    pub fn streamFinish(self: *Session) !Response {
        var result = try self.inner.streamFinish();
        errdefer result.deinit();
        return .{ .result = result, .latency_ns = 0 };
    }

    pub fn streamReset(self: *Session) !void {
        return self.inner.streamReset();
    }

    /// The chunk schedule the family wants for this session.
    pub fn streamPolicy(self: *Session) !audiocpp.StreamPolicy {
        return self.inner.streamPolicy();
    }

    /// Pull the next queued stream event, or null when the queue is
    /// empty. The caller frees the returned event handle.
    pub fn streamNextEvent(self: *Session) !?*audiocpp.EventHandle {
        return self.inner.streamNextEvent();
    }
};

/// The runtime: owns the audio.cpp registry and every loaded model.
/// Map keys are owned copies in `key_arena` — the runtime never borrows
/// config strings, so a config reload cannot dangle it.
pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    registry: ?audiocpp.Registry = null,
    models: std.StringHashMap(audiocpp.Model),
    key_arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) !Runtime {
        var rt = Runtime{
            .alloc = alloc,
            .io = io,
            .models = std.StringHashMap(audiocpp.Model).init(alloc),
            .key_arena = std.heap.ArenaAllocator.init(alloc),
        };
        if (audiocpp.has_link) {
            rt.registry = try audiocpp.Registry.create(alloc, null);
        }
        return rt;
    }

    pub fn deinit(self: *Runtime) void {
        var it = self.models.valueIterator();
        while (it.next()) |m| m.deinit();
        self.models.deinit();
        self.key_arena.deinit();
        if (self.registry) |*r| r.deinit();
        self.* = undefined;
    }

    pub fn isLinked(self: *const Runtime) bool {
        _ = self;
        return audiocpp.has_link;
    }

    pub fn abiVersion(self: *const Runtime) u32 {
        _ = self;
        return audiocpp.abiVersion();
    }

    pub fn buildVersion(self: *const Runtime) []const u8 {
        _ = self;
        return audiocpp.buildVersion();
    }

    pub fn taskCount(self: *const Runtime) usize {
        _ = self;
        return audiocpp.taskCount();
    }

    pub fn taskName(self: *const Runtime, index: usize) ?[]const u8 {
        _ = self;
        return audiocpp.taskName(index);
    }

    /// Load a model file into the runtime under `name`. No weights are
    /// ever downloaded — `path` must already exist on disk.
    pub fn loadModel(
        self: *Runtime,
        name: []const u8,
        path: []const u8,
        cfg: ?audiocpp.ModelConfig,
    ) !void {
        const reg = &(self.registry orelse return error.AudioCppNotLinked);
        var loaded = try audiocpp.Model.load(self.alloc, reg, path, cfg);
        errdefer loaded.deinit();
        // Own the key: fetchPut keeps the existing key on replace, so
        // only dupe when the name is new.
        const key = if (self.models.contains(name))
            name
        else
            try self.key_arena.allocator().dupe(u8, name);
        if (try self.models.fetchPut(key, loaded)) |old| {
            var old_model = old.value;
            old_model.deinit();
        }
    }

    pub fn model(self: *Runtime, name: []const u8) ?*audiocpp.Model {
        return self.models.getPtr(name);
    }

    pub fn unloadModel(self: *Runtime, name: []const u8) bool {
        if (self.models.fetchRemove(name)) |kv| {
            var m = kv.value;
            m.deinit();
            return true;
        }
        return false;
    }

    pub fn createSession(
        self: *Runtime,
        model_name: []const u8,
        task: TaskKind,
        mode: StreamMode,
        backend_name: ?[]const u8,
        device: i32,
        threads: i32,
    ) !Session {
        const m = self.model(model_name) orelse return error.ModelNotLoaded;
        return Session.create(self.alloc, m, task, mode, backend_name, device, threads);
    }
};

test "task tokens match the live vocabulary" {
    try std.testing.expectEqualStrings("asr", taskToken(.asr));
    try std.testing.expectEqualStrings("tts", taskToken(.tts));
    try std.testing.expectEqualStrings("vad", taskToken(.vad));
    try std.testing.expectEqualStrings("offline", modeToken(.offline));
    try std.testing.expectEqualStrings("streaming", modeToken(.streaming));
}

test "runtime lists the live task vocabulary when linked" {
    const alloc = std.testing.allocator;
    var rt = try Runtime.init(alloc, std.testing.io);
    defer rt.deinit();
    if (audiocpp.has_link) {
        try std.testing.expectEqual(@as(usize, 17), rt.taskCount());
        try std.testing.expectEqualStrings("vad", rt.taskName(0).?);
        try std.testing.expectEqualStrings("asr", rt.taskName(1).?);
        try std.testing.expectEqualStrings("tts", rt.taskName(5).?);
        try std.testing.expect(rt.abiVersion() == 0x200);
        try std.testing.expectEqualStrings("0.9.3", rt.buildVersion());
    } else {
        try std.testing.expectEqual(@as(usize, 0), rt.taskCount());
    }
}

test "loadModel fails honestly on a missing file" {
    const alloc = std.testing.allocator;
    var rt = try Runtime.init(alloc, std.testing.io);
    defer rt.deinit();
    if (audiocpp.has_link) {
        try std.testing.expectError(error.LoadFailed, rt.loadModel("ghost", "models/does-not-exist.gguf", null));
    } else {
        try std.testing.expectError(error.AudioCppNotLinked, rt.loadModel("ghost", "models/does-not-exist.gguf", null));
    }
}

test "createSession without a loaded model fails honestly" {
    const alloc = std.testing.allocator;
    var rt = try Runtime.init(alloc, std.testing.io);
    defer rt.deinit();
    try std.testing.expectError(error.ModelNotLoaded, rt.createSession("ghost", .tts, .offline, null, 0, 1));
}
