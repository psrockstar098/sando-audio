//! Bindings to audio.cpp's public C ABI (audiocpp.h).
//!
//! Targets the ABI 0.2.0 surface (audio.cpp 0.9.3), which is also present
//! in ABI 0.3.0 (0.9.5): the only addition in 0.3.0 is `audiocpp_log_set`,
//! deliberately excluded here so the same bindings link against either
//! library. The prebuilt 0.9.4/0.9.5 libraries require glibc 2.43 and do
//! NOT load on Ubuntu 24.04 (glibc 2.39); the vendored 0.9.3 prebuilt does.
//!
//! When the engine is built without `-Daudiocpp-dir`, every call returns
//! error.AudioCppNotLinked instead of touching a missing library. The
//! null backend is honest, never a fake success.

const std = @import("std");
const build_options = @import("build_options");

pub const has_link: bool = build_options.has_audiocpp;

/// ABI version the bindings were written against (0.2.0).
pub const abi_major: u32 = 0;
pub const abi_minor: u32 = 2;

pub const Error = error{
    AudioCppNotLinked,
    InvalidArgument,
    UnsupportedFamily,
    LoadFailed,
    Runtime,
    OutOfMemory,
    OutOfRange,
    NotAvailable,
};

pub const RegistryHandle = opaque {};
pub const ModelHandle = opaque {};
pub const SessionHandle = opaque {};
pub const OptionsHandle = opaque {};
pub const RequestHandle = opaque {};
pub const ResultHandle = opaque {};
pub const EventHandle = opaque {};

/// Mirrors audiocpp_model_config. Every field may be NULL.
pub const ModelConfig = extern struct {
    family_hint: ?[*:0]const u8 = null,
    config_id: ?[*:0]const u8 = null,
    weight_id: ?[*:0]const u8 = null,
    model_spec_override: ?[*:0]const u8 = null,
};

/// Mirrors audiocpp_backend_config. backend is "cpu", "cuda", "hip"/"rocm",
/// "vulkan", "metal", "webgpu", "sycl" or "best"; NULL means "cpu".
pub const BackendConfig = extern struct {
    backend: ?[*:0]const u8 = null,
    device: c_int = 0,
    threads: c_int = 1,
};

/// The raw C entry points. Only compiled in when the library is linked;
/// otherwise this struct is empty and every wrapper takes the null path.
const C = if (has_link) struct {
    extern "c" fn audiocpp_abi_version() u32;
    extern "c" fn audiocpp_build_version() [*:0]const u8;
    extern "c" fn audiocpp_last_error() [*:0]const u8;
    extern "c" fn audiocpp_status_string(status: c_int) [*:0]const u8;
    extern "c" fn audiocpp_registry_create(config_path: ?[*:0]const u8, out_registry: **RegistryHandle) c_int;
    extern "c" fn audiocpp_registry_free(registry: ?*RegistryHandle) void;
    extern "c" fn audiocpp_registry_family_count(registry: *const RegistryHandle) usize;
    extern "c" fn audiocpp_registry_family(registry: *const RegistryHandle, index: usize, out_family: *[*:0]const u8) c_int;
    extern "c" fn audiocpp_task_count() usize;
    extern "c" fn audiocpp_task_name(index: usize) ?[*:0]const u8;
    extern "c" fn audiocpp_task_from_spec_name(spec_task: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn audiocpp_options_create() ?*OptionsHandle;
    extern "c" fn audiocpp_options_set(options: *OptionsHandle, key: [*:0]const u8, value: [*:0]const u8) c_int;
    extern "c" fn audiocpp_options_free(options: ?*OptionsHandle) void;
    extern "c" fn audiocpp_model_load(registry: *RegistryHandle, model_path: [*:0]const u8, config: ?*const ModelConfig, options: ?*OptionsHandle, out_model: **ModelHandle) c_int;
    extern "c" fn audiocpp_model_free(model: ?*ModelHandle) void;
    extern "c" fn audiocpp_model_family(model: *const ModelHandle) [*:0]const u8;
    extern "c" fn audiocpp_model_description(model: *const ModelHandle) [*:0]const u8;
    extern "c" fn audiocpp_model_supports(model: *const ModelHandle, task: [*:0]const u8, mode: [*:0]const u8) c_int;
    extern "c" fn audiocpp_model_supports_timestamps(model: *const ModelHandle) c_int;
    extern "c" fn audiocpp_model_supports_speaker_reference(model: *const ModelHandle) c_int;
    extern "c" fn audiocpp_model_supports_style_condition(model: *const ModelHandle) c_int;
    extern "c" fn audiocpp_model_language_count(model: *const ModelHandle) usize;
    extern "c" fn audiocpp_model_language(model: *const ModelHandle, index: usize, out_language: *[*:0]const u8) c_int;
    extern "c" fn audiocpp_session_create(model: *const ModelHandle, task: [*:0]const u8, mode: [*:0]const u8, backend_config: ?*const BackendConfig, options: ?*OptionsHandle, out_session: **SessionHandle) c_int;
    extern "c" fn audiocpp_session_free(session: ?*SessionHandle) void;
    extern "c" fn audiocpp_session_family(session: *const SessionHandle) [*:0]const u8;
    extern "c" fn audiocpp_session_prepare(session: *SessionHandle, request: *const RequestHandle) c_int;
    extern "c" fn audiocpp_session_run(session: *SessionHandle, request: *const RequestHandle, out_result: **ResultHandle) c_int;
    extern "c" fn audiocpp_request_create() ?*RequestHandle;
    extern "c" fn audiocpp_request_free(request: ?*RequestHandle) void;
    extern "c" fn audiocpp_request_set_text(request: *RequestHandle, text: [*:0]const u8, language: ?[*:0]const u8) c_int;
    extern "c" fn audiocpp_request_set_audio(request: *RequestHandle, samples: [*]const f32, frames: usize, sample_rate: c_int, channels: c_int) c_int;
    extern "c" fn audiocpp_request_set_option(request: *RequestHandle, key: [*:0]const u8, value: [*:0]const u8) c_int;
    extern "c" fn audiocpp_result_free(result: ?*ResultHandle) void;
    extern "c" fn audiocpp_result_audio(result: *const ResultHandle, out_samples: ?*[*]const f32, out_frames: ?*usize, out_sample_rate: ?*c_int, out_channels: ?*c_int) c_int;
    extern "c" fn audiocpp_result_text(result: *const ResultHandle, out_text: ?*[*:0]const u8, out_language: ?*[*:0]const u8) c_int;
    extern "c" fn audiocpp_stream_policy(session: *const SessionHandle, out_input: ?*c_int, out_output: ?*c_int, out_chunk_samples: ?*i64, out_chunk_seconds: ?*f64) c_int;
    extern "c" fn audiocpp_stream_start(session: *SessionHandle, request: ?*const RequestHandle) c_int;
    extern "c" fn audiocpp_stream_push(session: *SessionHandle, samples: [*]const f32, frames: usize, sample_rate: c_int, channels: c_int, start_sample: i64, out_event: ?*?*EventHandle) c_int;
    extern "c" fn audiocpp_stream_finish(session: *SessionHandle, out_result: **ResultHandle) c_int;
    extern "c" fn audiocpp_stream_reset(session: *SessionHandle) c_int;
    extern "c" fn audiocpp_event_free(event: ?*EventHandle) void;
    extern "c" fn audiocpp_event_is_final(event: *const EventHandle) c_int;
    extern "c" fn audiocpp_event_as_result(event: *const EventHandle) *const ResultHandle;
} else struct {};

fn check(status: c_int) Error!void {
    return switch (status) {
        0 => {},
        1 => error.InvalidArgument,
        2 => error.UnsupportedFamily,
        3 => error.LoadFailed,
        4 => error.Runtime,
        5 => error.OutOfMemory,
        6 => error.OutOfRange,
        7 => error.NotAvailable,
        else => error.Runtime,
    };
}

fn dupeZ(alloc: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const buf = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len :0];
}

/// Packed (major << 16) | (minor << 8) | patch. 0 when not linked.
pub fn abiVersion() u32 {
    if (comptime has_link) return C.audiocpp_abi_version();
    return 0;
}

/// audio.cpp's own build version, e.g. "0.9.3". Static lifetime.
pub fn buildVersion() []const u8 {
    if (comptime has_link) return std.mem.span(C.audiocpp_build_version());
    return "unavailable (audio.cpp not linked)";
}

/// Detail for the most recent failure on this thread.
pub fn lastError() []const u8 {
    if (comptime has_link) return std.mem.span(C.audiocpp_last_error());
    return "audio.cpp not linked";
}

pub fn taskCount() usize {
    if (comptime has_link) return C.audiocpp_task_count();
    return 0;
}

/// Canonical task token at `index`, or null when out of range.
/// Static lifetime.
pub fn taskName(index: usize) ?[]const u8 {
    if (comptime has_link) {
        const p = C.audiocpp_task_name(index) orelse return null;
        return std.mem.span(p);
    }
    return null;
}

pub const Registry = struct {
    handle: *RegistryHandle,

    /// config_path may be null for the default loader set.
    pub fn create(alloc: std.mem.Allocator, config_path: ?[]const u8) Error!Registry {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var zpath: ?[:0]const u8 = null;
        if (config_path) |p| zpath = try dupeZ(alloc, p);
        defer if (zpath) |z| alloc.free(z);
        var handle: *RegistryHandle = undefined;
        try check(C.audiocpp_registry_create(if (zpath) |z| z.ptr else null, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Registry) void {
        if (comptime has_link) C.audiocpp_registry_free(self.handle);
        self.* = undefined;
    }

    pub fn familyCount(self: *const Registry) usize {
        if (comptime has_link) return C.audiocpp_registry_family_count(self.handle);
        return 0;
    }

    /// Family name at `index`. Borrowed from the registry — valid until
    /// the registry is freed.
    pub fn family(self: *const Registry, index: usize) Error![]const u8 {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var out: [*:0]const u8 = undefined;
        try check(C.audiocpp_registry_family(self.handle, index, &out));
        return std.mem.span(out);
    }
};

pub const Options = struct {
    handle: *OptionsHandle,

    pub fn create() Error!Options {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const h = C.audiocpp_options_create() orelse return error.OutOfMemory;
        return .{ .handle = h };
    }

    pub fn deinit(self: *Options) void {
        if (comptime has_link) C.audiocpp_options_free(self.handle);
        self.* = undefined;
    }

    pub fn set(self: *Options, alloc: std.mem.Allocator, key: []const u8, value: []const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zk = try dupeZ(alloc, key);
        defer alloc.free(zk);
        const zv = try dupeZ(alloc, value);
        defer alloc.free(zv);
        try check(C.audiocpp_options_set(self.handle, zk.ptr, zv.ptr));
    }
};

pub const Model = struct {
    handle: *ModelHandle,

    /// Load a model from a GGUF/ONNX weight file. No weights are
    /// downloaded — `path` must already exist on disk.
    pub fn load(alloc: std.mem.Allocator, registry: *Registry, path: []const u8, cfg: ?ModelConfig) Error!Model {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zpath = try dupeZ(alloc, path);
        defer alloc.free(zpath);
        var handle: *ModelHandle = undefined;
        try check(C.audiocpp_model_load(registry.handle, zpath.ptr, if (cfg) |*c| c else null, null, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Model) void {
        if (comptime has_link) C.audiocpp_model_free(self.handle);
        self.* = undefined;
    }

    pub fn family(self: *const Model) []const u8 {
        if (comptime has_link) return std.mem.span(C.audiocpp_model_family(self.handle));
        return "";
    }

    pub fn description(self: *const Model) []const u8 {
        if (comptime has_link) return std.mem.span(C.audiocpp_model_description(self.handle));
        return "";
    }

    /// task is a token from taskName(); mode is "offline" or "streaming".
    pub fn supports(self: *const Model, alloc: std.mem.Allocator, task: []const u8, mode: []const u8) Error!bool {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zt = try dupeZ(alloc, task);
        defer alloc.free(zt);
        const zm = try dupeZ(alloc, mode);
        defer alloc.free(zm);
        return C.audiocpp_model_supports(self.handle, zt.ptr, zm.ptr) == 1;
    }

    pub fn supportsTimestamps(self: *const Model) bool {
        if (comptime has_link) return C.audiocpp_model_supports_timestamps(self.handle) == 1;
        return false;
    }

    pub fn supportsSpeakerReference(self: *const Model) bool {
        if (comptime has_link) return C.audiocpp_model_supports_speaker_reference(self.handle) == 1;
        return false;
    }

    pub fn supportsStyleCondition(self: *const Model) bool {
        if (comptime has_link) return C.audiocpp_model_supports_style_condition(self.handle) == 1;
        return false;
    }

    pub fn languageCount(self: *const Model) usize {
        if (comptime has_link) return C.audiocpp_model_language_count(self.handle);
        return 0;
    }

    pub fn language(self: *const Model, index: usize) Error![]const u8 {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var out: [*:0]const u8 = undefined;
        try check(C.audiocpp_model_language(self.handle, index, &out));
        return std.mem.span(out);
    }
};

pub const Session = struct {
    handle: *SessionHandle,

    /// task is a token from taskName(); mode is "offline" or "streaming".
    /// backend_config may be null for CPU / device 0 / 1 thread.
    pub fn create(alloc: std.mem.Allocator, model: *const Model, task: []const u8, mode: []const u8, backend_config: ?BackendConfig) Error!Session {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zt = try dupeZ(alloc, task);
        defer alloc.free(zt);
        const zm = try dupeZ(alloc, mode);
        defer alloc.free(zm);
        var handle: *SessionHandle = undefined;
        try check(C.audiocpp_session_create(model.handle, zt.ptr, zm.ptr, if (backend_config) |*b| b else null, null, &handle));
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Session) void {
        if (comptime has_link) C.audiocpp_session_free(self.handle);
        self.* = undefined;
    }

    pub fn family(self: *const Session) []const u8 {
        if (comptime has_link) return std.mem.span(C.audiocpp_session_family(self.handle));
        return "";
    }

    pub fn prepare(self: *Session, request: *const Request) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        try check(C.audiocpp_session_prepare(self.handle, request.handle));
    }

    pub fn run(self: *Session, request: *const Request) Error!Result {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var handle: *ResultHandle = undefined;
        try check(C.audiocpp_session_run(self.handle, request.handle, &handle));
        return .{ .handle = handle };
    }

    pub fn streamStart(self: *Session, request: ?*const Request) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        try check(C.audiocpp_stream_start(self.handle, if (request) |r| r.handle else null));
    }

    pub fn streamPush(self: *Session, samples: []const f32, sample_rate: u32, channels: u8, start_sample: i64) Error!?*EventHandle {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var event: ?*EventHandle = null;
        try check(C.audiocpp_stream_push(self.handle, samples.ptr, samples.len / @as(usize, channels), @intCast(sample_rate), @intCast(channels), start_sample, &event));
        return event;
    }

    pub fn streamFinish(self: *Session) Error!Result {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var handle: *ResultHandle = undefined;
        try check(C.audiocpp_stream_finish(self.handle, &handle));
        return .{ .handle = handle };
    }

    pub fn streamReset(self: *Session) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        try check(C.audiocpp_stream_reset(self.handle));
    }
};

pub const Request = struct {
    handle: *RequestHandle,

    pub fn create() Error!Request {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const h = C.audiocpp_request_create() orelse return error.OutOfMemory;
        return .{ .handle = h };
    }

    pub fn deinit(self: *Request) void {
        if (comptime has_link) C.audiocpp_request_free(self.handle);
        self.* = undefined;
    }

    pub fn setText(self: *Request, alloc: std.mem.Allocator, text: []const u8, language: ?[]const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zt = try dupeZ(alloc, text);
        defer alloc.free(zt);
        var zl: ?[:0]const u8 = null;
        if (language) |l| zl = try dupeZ(alloc, l);
        defer if (zl) |z| alloc.free(z);
        try check(C.audiocpp_request_set_text(self.handle, zt.ptr, if (zl) |z| z.ptr else null));
    }

    /// Interleaved float PCM. Copied into the request.
    pub fn setAudio(self: *Request, samples: []const f32, sample_rate: u32, channels: u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        try check(C.audiocpp_request_set_audio(self.handle, samples.ptr, samples.len / @as(usize, channels), @intCast(sample_rate), @intCast(channels)));
    }

    pub fn setOption(self: *Request, alloc: std.mem.Allocator, key: []const u8, value: []const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zk = try dupeZ(alloc, key);
        defer alloc.free(zk);
        const zv = try dupeZ(alloc, value);
        defer alloc.free(zv);
        try check(C.audiocpp_request_set_option(self.handle, zk.ptr, zv.ptr));
    }
};

pub const Result = struct {
    handle: *ResultHandle,

    pub fn deinit(self: *Result) void {
        if (comptime has_link) C.audiocpp_result_free(self.handle);
        self.* = undefined;
    }

    /// Borrowed samples; valid until the result is freed.
    pub fn audio(self: *const Result) Error!struct { samples: []const f32, sample_rate: u32, channels: u8 } {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var samples: [*]const f32 = undefined;
        var frames: usize = 0;
        var rate: c_int = 0;
        var ch: c_int = 0;
        try check(C.audiocpp_result_audio(self.handle, &samples, &frames, &rate, &ch));
        return .{
            .samples = samples[0 .. frames * @as(usize, @intCast(ch))],
            .sample_rate = @intCast(rate),
            .channels = @intCast(ch),
        };
    }

    /// Borrowed text; valid until the result is freed.
    pub fn text(self: *const Result) Error!struct { text: []const u8, language: []const u8 } {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var t: [*:0]const u8 = undefined;
        var l: [*:0]const u8 = undefined;
        try check(C.audiocpp_result_text(self.handle, &t, &l));
        return .{ .text = std.mem.span(t), .language = std.mem.span(l) };
    }
};

/// Free an event returned by streamPush. Events wrap results; freeing
/// the event frees its result too.
pub fn eventFree(event: *EventHandle) void {
    if (comptime has_link) C.audiocpp_event_free(event);
}

test "abi version and task vocabulary (live when linked)" {
    if (comptime has_link) {
        const v = abiVersion();
        try std.testing.expect(v != 0);
        // Major version must be 0 for this binding generation.
        try std.testing.expect((v >> 16) == 0);
        try std.testing.expect(std.mem.startsWith(u8, buildVersion(), "0."));
        try std.testing.expect(taskCount() > 0);
        try std.testing.expect(taskName(0) != null);
        try std.testing.expect(taskName(1_000_000) == null);
    } else {
        try std.testing.expectEqual(@as(u32, 0), abiVersion());
        try std.testing.expectEqual(@as(usize, 0), taskCount());
        try std.testing.expect(taskName(0) == null);
    }
}

test "registry create lists families (live when linked)" {
    const alloc = std.testing.allocator;
    if (comptime has_link) {
        var reg = try Registry.create(alloc, null);
        defer reg.deinit();
        try std.testing.expect(reg.familyCount() > 0);
        const first = try reg.family(0);
        try std.testing.expect(first.len > 0);
        try std.testing.expectError(error.OutOfRange, reg.family(1_000_000));
    } else {
        try std.testing.expectError(error.AudioCppNotLinked, Registry.create(alloc, null));
    }
}

test "model load fails honestly on a missing file (live when linked)" {
    const alloc = std.testing.allocator;
    if (comptime has_link) {
        var reg = try Registry.create(alloc, null);
        defer reg.deinit();
        try std.testing.expectError(error.LoadFailed, Model.load(alloc, &reg, "models/does-not-exist.gguf", null));
    } else {
        var reg: Registry = undefined;
        try std.testing.expectError(error.AudioCppNotLinked, Model.load(alloc, &reg, "models/does-not-exist.gguf", null));
    }
}
