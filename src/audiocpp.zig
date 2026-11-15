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
    extern "c" fn audiocpp_request_set_text_language(request: *RequestHandle, language: [*:0]const u8) c_int;
    extern "c" fn audiocpp_request_set_audio(request: *RequestHandle, samples: [*]const f32, frames: usize, sample_rate: c_int, channels: c_int) c_int;
    extern "c" fn audiocpp_request_set_voice_audio(request: *RequestHandle, samples: [*]const f32, frames: usize, sample_rate: c_int, channels: c_int) c_int;
    extern "c" fn audiocpp_request_set_voice_id(request: *RequestHandle, cached_voice_id: [*:0]const u8) c_int;
    extern "c" fn audiocpp_request_set_style_language(request: *RequestHandle, language: [*:0]const u8) c_int;
    extern "c" fn audiocpp_request_set_emotion(request: *RequestHandle, emotion: [*:0]const u8) c_int;
    extern "c" fn audiocpp_request_set_speaking_rate(request: *RequestHandle, speaking_rate: f32) c_int;
    extern "c" fn audiocpp_request_set_pitch_shift(request: *RequestHandle, pitch_shift: f32) c_int;
    extern "c" fn audiocpp_request_set_energy_scale(request: *RequestHandle, energy_scale: f32) c_int;
    extern "c" fn audiocpp_request_set_style_tag(request: *RequestHandle, key: [*:0]const u8, value: [*:0]const u8) c_int;
    extern "c" fn audiocpp_request_add_artifact(request: *RequestHandle, kind: c_int, id: [*:0]const u8, payload: *const anyopaque, payload_bytes: usize, out_index: ?*usize) c_int;
    extern "c" fn audiocpp_request_set_artifact_meta(request: *RequestHandle, index: usize, key: [*:0]const u8, value: [*:0]const u8) c_int;
    extern "c" fn audiocpp_request_set_option(request: *RequestHandle, key: [*:0]const u8, value: [*:0]const u8) c_int;
    extern "c" fn audiocpp_result_free(result: ?*ResultHandle) void;
    extern "c" fn audiocpp_result_audio(result: *const ResultHandle, out_samples: ?*[*]const f32, out_frames: ?*usize, out_sample_rate: ?*c_int, out_channels: ?*c_int) c_int;
    extern "c" fn audiocpp_result_text(result: *const ResultHandle, out_text: ?*[*:0]const u8, out_language: ?*[*:0]const u8) c_int;
    extern "c" fn audiocpp_result_segment_count(result: *const ResultHandle) usize;
    extern "c" fn audiocpp_result_segment(result: *const ResultHandle, index: usize, out_start_sample: ?*i64, out_end_sample: ?*i64, out_confidence: ?*f32, out_text: ?*[*:0]const u8) c_int;
    extern "c" fn audiocpp_result_speaker_turn_count(result: *const ResultHandle) usize;
    extern "c" fn audiocpp_result_speaker_turn(result: *const ResultHandle, index: usize, out_start_sample: ?*i64, out_end_sample: ?*i64, out_speaker_id: ?*[*:0]const u8, out_confidence: ?*f32, out_text: ?*[*:0]const u8) c_int;
    extern "c" fn audiocpp_result_word_count(result: *const ResultHandle) usize;
    extern "c" fn audiocpp_result_word(result: *const ResultHandle, index: usize, out_word: ?*[*:0]const u8, out_start_sample: ?*i64, out_end_sample: ?*i64, out_confidence: ?*f32) c_int;
    extern "c" fn audiocpp_result_named_audio_count(result: *const ResultHandle) usize;
    extern "c" fn audiocpp_result_named_audio(result: *const ResultHandle, index: usize, out_id: ?*[*:0]const u8, out_samples: ?*[*]const f32, out_frames: ?*usize, out_sample_rate: ?*c_int, out_channels: ?*c_int) c_int;
    extern "c" fn audiocpp_result_artifact_count(result: *const ResultHandle) usize;
    extern "c" fn audiocpp_result_artifact(result: *const ResultHandle, index: usize, out_kind: ?*c_int, out_id: ?*[*:0]const u8, out_payload: ?*?*const anyopaque, out_payload_bytes: ?*usize) c_int;
    extern "c" fn audiocpp_result_artifact_meta_count(result: *const ResultHandle, index: usize) usize;
    extern "c" fn audiocpp_result_artifact_meta(result: *const ResultHandle, index: usize, meta_index: usize, out_key: ?*[*:0]const u8, out_value: ?*[*:0]const u8) c_int;
    extern "c" fn audiocpp_stream_policy(session: *const SessionHandle, out_input: ?*c_int, out_output: ?*c_int, out_chunk_samples: ?*i64, out_chunk_seconds: ?*f64) c_int;
    extern "c" fn audiocpp_stream_start(session: *SessionHandle, request: ?*const RequestHandle) c_int;
    extern "c" fn audiocpp_stream_push(session: *SessionHandle, samples: [*]const f32, frames: usize, sample_rate: c_int, channels: c_int, start_sample: i64, out_event: ?*?*EventHandle) c_int;
    extern "c" fn audiocpp_stream_next_event(session: *SessionHandle, out_event: *?*EventHandle) c_int;
    extern "c" fn audiocpp_stream_finish(session: *SessionHandle, out_result: **ResultHandle) c_int;
    extern "c" fn audiocpp_stream_reset(session: *SessionHandle) c_int;
    extern "c" fn audiocpp_event_free(event: ?*EventHandle) void;
    extern "c" fn audiocpp_event_is_final(event: *const EventHandle) c_int;
    extern "c" fn audiocpp_event_as_result(event: *const EventHandle) *const ResultHandle;
    extern "c" fn audiocpp_event_voice_activity_count(event: *const EventHandle) usize;
    extern "c" fn audiocpp_event_voice_activity(event: *const EventHandle, index: usize, out_kind: ?*c_int, out_sample: ?*i64, out_probability: ?*f32) c_int;
    extern "c" fn audiocpp_model_option_count(model: *const ModelHandle, scope: c_int) usize;
    extern "c" fn audiocpp_model_option(model: *const ModelHandle, scope: c_int, index: usize, out_name: ?*[*:0]const u8, out_value_name: ?*[*:0]const u8, out_description: ?*[*:0]const u8, out_default_value: ?*[*:0]const u8, out_min_value: ?*[*:0]const u8, out_max_value: ?*[*:0]const u8, out_required: ?*c_int) c_int;
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

    /// Number of declared options in `scope` (request/session/load).
    pub fn optionCount(self: *const Model, scope: OptionScope) usize {
        if (comptime has_link) return C.audiocpp_model_option_count(self.handle, @intFromEnum(scope));
        return 0;
    }

    /// Declared option at `index`. Strings are borrowed from the model
    /// ("" when the model did not declare one) — valid while the model
    /// lives.
    pub fn option(self: *const Model, scope: OptionScope, index: usize) Error!ModelOption {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var name: [*:0]const u8 = undefined;
        var value_name: [*:0]const u8 = undefined;
        var desc: [*:0]const u8 = undefined;
        var def: [*:0]const u8 = undefined;
        var min_v: [*:0]const u8 = undefined;
        var max_v: [*:0]const u8 = undefined;
        var required: c_int = 0;
        try check(C.audiocpp_model_option(self.handle, @intFromEnum(scope), index, &name, &value_name, &desc, &def, &min_v, &max_v, &required));
        return .{
            .name = std.mem.span(name),
            .value_name = std.mem.span(value_name),
            .description = std.mem.span(desc),
            .default_value = std.mem.span(def),
            .min_value = std.mem.span(min_v),
            .max_value = std.mem.span(max_v),
            .required = required != 0,
        };
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

    /// The chunk schedule the family wants for this session.
    pub fn streamPolicy(self: *Session) Error!StreamPolicy {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var input: c_int = 0;
        var output: c_int = 0;
        var chunk_samples: i64 = 0;
        var chunk_seconds: f64 = 0;
        try check(C.audiocpp_stream_policy(self.handle, &input, &output, &chunk_samples, &chunk_seconds));
        return .{
            .input = if (input == 1) .audio_chunks else .none,
            .output = if (output == 1) .pull_events else .final_result,
            .chunk_samples = chunk_samples,
            .chunk_seconds = chunk_seconds,
        };
    }

    /// Pull the next queued stream event, or null when the queue is
    /// empty (that is success, not an error). The caller frees it.
    pub fn streamNextEvent(self: *Session) Error!?*EventHandle {
        if (comptime !has_link) return error.AudioCppNotLinked;
        var event: ?*EventHandle = null;
        try check(C.audiocpp_stream_next_event(self.handle, &event));
        return event;
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

    /// Transcript language without touching options["language"].
    pub fn setTextLanguage(self: *Request, alloc: std.mem.Allocator, language: []const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zl = try dupeZ(alloc, language);
        defer alloc.free(zl);
        try check(C.audiocpp_request_set_text_language(self.handle, zl.ptr));
    }

    /// Speaker reference audio for cloning/conversion families.
    /// Interleaved float PCM, copied into the request.
    pub fn setVoiceAudio(self: *Request, samples: []const f32, sample_rate: u32, channels: u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        try check(C.audiocpp_request_set_voice_audio(self.handle, samples.ptr, samples.len / @as(usize, channels), @intCast(sample_rate), @intCast(channels)));
    }

    /// Cached voice id for cloning families (from a previous enrollment).
    pub fn setVoiceId(self: *Request, alloc: std.mem.Allocator, voice_id: []const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zv = try dupeZ(alloc, voice_id);
        defer alloc.free(zv);
        try check(C.audiocpp_request_set_voice_id(self.handle, zv.ptr));
    }

    /// Style conditioning — only meaningful for families that advertise
    /// it (Model.supportsStyleCondition). Each setter is independent.
    pub fn setStyleLanguage(self: *Request, alloc: std.mem.Allocator, language: []const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zl = try dupeZ(alloc, language);
        defer alloc.free(zl);
        try check(C.audiocpp_request_set_style_language(self.handle, zl.ptr));
    }

    pub fn setEmotion(self: *Request, alloc: std.mem.Allocator, emotion: []const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const ze = try dupeZ(alloc, emotion);
        defer alloc.free(ze);
        try check(C.audiocpp_request_set_emotion(self.handle, ze.ptr));
    }

    pub fn setSpeakingRate(self: *Request, rate: f32) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        try check(C.audiocpp_request_set_speaking_rate(self.handle, rate));
    }

    pub fn setPitchShift(self: *Request, semitones: f32) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        try check(C.audiocpp_request_set_pitch_shift(self.handle, semitones));
    }

    pub fn setEnergyScale(self: *Request, scale: f32) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        try check(C.audiocpp_request_set_energy_scale(self.handle, scale));
    }

    pub fn setStyleTag(self: *Request, alloc: std.mem.Allocator, key: []const u8, value: []const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zk = try dupeZ(alloc, key);
        defer alloc.free(zk);
        const zv = try dupeZ(alloc, value);
        defer alloc.free(zv);
        try check(C.audiocpp_request_set_style_tag(self.handle, zk.ptr, zv.ptr));
    }

    /// Attach an artifact payload (speaker embedding, acoustic tokens,
    /// diarization state, ...). The payload is copied. Returns the
    /// artifact's index for setArtifactMeta.
    pub fn addArtifact(self: *Request, alloc: std.mem.Allocator, kind: ArtifactKind, id: []const u8, payload: []const u8) Error!usize {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zid = try dupeZ(alloc, id);
        defer alloc.free(zid);
        var index: usize = 0;
        try check(C.audiocpp_request_add_artifact(self.handle, @intFromEnum(kind), zid.ptr, payload.ptr, payload.len, &index));
        return index;
    }

    pub fn setArtifactMeta(self: *Request, alloc: std.mem.Allocator, index: usize, key: []const u8, value: []const u8) Error!void {
        if (comptime !has_link) return error.AudioCppNotLinked;
        const zk = try dupeZ(alloc, key);
        defer alloc.free(zk);
        const zv = try dupeZ(alloc, value);
        defer alloc.free(zv);
        try check(C.audiocpp_request_set_artifact_meta(self.handle, index, zk.ptr, zv.ptr));
    }
};

pub const Result = struct {
    handle: *ResultHandle,

    pub fn deinit(self: *Result) void {
        if (comptime has_link) C.audiocpp_result_free(self.handle);
        self.* = undefined;
    }

    /// Borrowed samples; valid until the result is freed.
    pub fn audio(self: *const Result) Error!ResultAudio {
        return audioOf(self.handle);
    }

    /// Borrowed text; valid until the result is freed.
    pub fn text(self: *const Result) Error!ResultText {
        return textOf(self.handle);
    }

    /// Word-level timestamps, when the task produced them.
    pub fn words(self: *const Result, alloc: std.mem.Allocator) Error![]Word {
        const n = wordCountOf(self.handle);
        const out = try alloc.alloc(Word, n);
        errdefer alloc.free(out);
        for (0..n) |i| out[i] = try wordOf(self.handle, i);
        return out;
    }

    pub fn segments(self: *const Result, alloc: std.mem.Allocator) Error![]Segment {
        const n = segmentCountOf(self.handle);
        const out = try alloc.alloc(Segment, n);
        errdefer alloc.free(out);
        for (0..n) |i| out[i] = try segmentOf(self.handle, i);
        return out;
    }

    /// Speaker turns (diarization), when the task produced them.
    pub fn speakerTurns(self: *const Result, alloc: std.mem.Allocator) Error![]SpeakerTurn {
        const n = speakerTurnCountOf(self.handle);
        const out = try alloc.alloc(SpeakerTurn, n);
        errdefer alloc.free(out);
        for (0..n) |i| out[i] = try speakerTurnOf(self.handle, i);
        return out;
    }

    /// Named audio outputs (separation, multi-speaker TTS).
    pub fn namedAudio(self: *const Result, alloc: std.mem.Allocator) Error![]NamedAudio {
        const n = namedAudioCountOf(self.handle);
        const out = try alloc.alloc(NamedAudio, n);
        errdefer alloc.free(out);
        for (0..n) |i| out[i] = try namedAudioOf(self.handle, i);
        return out;
    }

    /// Artifacts the task produced (embeddings, tokens, state, ...).
    pub fn artifacts(self: *const Result, alloc: std.mem.Allocator) Error![]ArtifactInfo {
        const n = artifactCountOf(self.handle);
        const out = try alloc.alloc(ArtifactInfo, n);
        errdefer alloc.free(out);
        for (0..n) |i| out[i] = try artifactOf(self.handle, i);
        return out;
    }
};

/// Free an event returned by streamPush. Events wrap results; freeing
/// the event frees its result too.
pub fn eventFree(event: *EventHandle) void {
    if (comptime has_link) C.audiocpp_event_free(event);
}

/// Whether a stream event is the final event of the stream.
pub fn eventIsFinal(event: *const EventHandle) bool {
    if (comptime has_link) return C.audiocpp_event_is_final(event) != 0;
    return false;
}

/// The result view carried by an event. Borrowed — valid only until the
/// event is freed. Never free it; read it through the `*Of` accessors.
pub fn eventAsResult(event: *const EventHandle) *const ResultHandle {
    if (comptime has_link) return C.audiocpp_event_as_result(event);
    unreachable;
}

/// Artifact kinds (audio.cpp artifact payloads: speaker/style/prompt
/// embeddings, acoustic tokens, MIDI, alignment, diarization/VAD state).
pub const ArtifactKind = enum(u8) {
    speaker_embedding = 0,
    style_embedding = 1,
    prompt_embedding = 2,
    acoustic_tokens = 3,
    midi = 4,
    transcript_alignment = 5,
    diarization_state = 6,
    vad_state = 7,
    custom = 8,
};

pub const StreamInputKind = enum { none, audio_chunks };
pub const StreamOutputKind = enum { final_result, pull_events };

/// The chunk schedule a streaming session wants. `chunk_samples` <= 0
/// means the family did not specify one.
pub const StreamPolicy = struct {
    input: StreamInputKind,
    output: StreamOutputKind,
    chunk_samples: i64,
    chunk_seconds: f64,
};

pub const VadActivityKind = enum { speech_start, speech_end, speech_segment };

pub const VadActivity = struct {
    kind: VadActivityKind,
    sample: i64,
    probability: f32,
};

pub const Word = struct {
    word: []const u8,
    start_sample: i64,
    end_sample: i64,
    confidence: f32,
};

/// Borrowed result text + detected language; valid until the owning result is freed.
pub const ResultText = struct {
    text: []const u8,
    language: []const u8,
};

/// Borrowed result audio samples; valid until the owning result is freed.
pub const ResultAudio = struct {
    samples: []const f32,
    sample_rate: u32,
    channels: u8,
};

pub const Segment = struct {
    start_sample: i64,
    end_sample: i64,
    confidence: f32,
    text: []const u8,
};

pub const SpeakerTurn = struct {
    start_sample: i64,
    end_sample: i64,
    speaker_id: []const u8,
    confidence: f32,
    text: []const u8,
};

pub const NamedAudio = struct {
    id: []const u8,
    samples: []const f32,
    sample_rate: u32,
    channels: u8,
};

pub const ArtifactInfo = struct {
    kind: ArtifactKind,
    id: []const u8,
    payload: []const u8,
};

pub const ModelOption = struct {
    name: []const u8,
    value_name: []const u8,
    description: []const u8,
    default_value: []const u8,
    min_value: []const u8,
    max_value: []const u8,
    required: bool,
};

/// Which option map a model option belongs to (mirrors the C enum).
pub const OptionScope = enum(c_int) {
    request = 0,
    session = 1,
    load = 2,
};

/// Canonical task token for a spec-declared task name, or null when the
/// build does not serve it. Static lifetime.
pub fn taskFromSpecName(alloc: std.mem.Allocator, spec_task: []const u8) Error!?[]const u8 {
    if (comptime !has_link) return error.AudioCppNotLinked;
    const z = try dupeZ(alloc, spec_task);
    defer alloc.free(z);
    const p = C.audiocpp_task_from_spec_name(z.ptr) orelse return null;
    return std.mem.span(p);
}

/// Voice-activity events carried by a stream event. Borrowed values are
/// plain numbers — no lifetime issues. Returns an empty slice when the
/// event carries none.
pub fn eventVoiceActivity(event: *const EventHandle, alloc: std.mem.Allocator) Error![]VadActivity {
    if (comptime !has_link) return error.AudioCppNotLinked;
    const n = C.audiocpp_event_voice_activity_count(event);
    const out = try alloc.alloc(VadActivity, n);
    errdefer alloc.free(out);
    for (0..n) |i| {
        var kind: c_int = 0;
        var sample: i64 = 0;
        var prob: f32 = 0;
        try check(C.audiocpp_event_voice_activity(event, i, &kind, &sample, &prob));
        out[i] = .{
            .kind = switch (kind) {
                0 => .speech_start,
                1 => .speech_end,
                else => .speech_segment,
            },
            .sample = sample,
            .probability = prob,
        };
    }
    return out;
}

/// Result accessors that work on any result handle — an owned Result or
/// a borrowed event result. Borrowed strings/samples are valid until
/// the owning result/event is freed.
pub fn textOf(handle: *const ResultHandle) Error!ResultText {
    if (comptime !has_link) return error.AudioCppNotLinked;
    var t: [*:0]const u8 = undefined;
    var l: [*:0]const u8 = undefined;
    try check(C.audiocpp_result_text(handle, &t, &l));
    return .{ .text = std.mem.span(t), .language = std.mem.span(l) };
}

pub fn audioOf(handle: *const ResultHandle) Error!ResultAudio {
    if (comptime !has_link) return error.AudioCppNotLinked;
    var samples: [*]const f32 = undefined;
    var frames: usize = 0;
    var rate: c_int = 0;
    var ch: c_int = 0;
    try check(C.audiocpp_result_audio(handle, &samples, &frames, &rate, &ch));
    return .{
        .samples = samples[0 .. frames * @as(usize, @intCast(ch))],
        .sample_rate = @intCast(rate),
        .channels = @intCast(ch),
    };
}

pub fn wordCountOf(handle: *const ResultHandle) usize {
    if (comptime has_link) return C.audiocpp_result_word_count(handle);
    return 0;
}

pub fn wordOf(handle: *const ResultHandle, index: usize) Error!Word {
    if (comptime !has_link) return error.AudioCppNotLinked;
    var w: [*:0]const u8 = undefined;
    var start: i64 = 0;
    var end: i64 = 0;
    var conf: f32 = 0;
    try check(C.audiocpp_result_word(handle, index, &w, &start, &end, &conf));
    return .{ .word = std.mem.span(w), .start_sample = start, .end_sample = end, .confidence = conf };
}

pub fn segmentCountOf(handle: *const ResultHandle) usize {
    if (comptime has_link) return C.audiocpp_result_segment_count(handle);
    return 0;
}

pub fn segmentOf(handle: *const ResultHandle, index: usize) Error!Segment {
    if (comptime !has_link) return error.AudioCppNotLinked;
    var start: i64 = 0;
    var end: i64 = 0;
    var conf: f32 = 0;
    var t: [*:0]const u8 = undefined;
    try check(C.audiocpp_result_segment(handle, index, &start, &end, &conf, &t));
    return .{ .start_sample = start, .end_sample = end, .confidence = conf, .text = std.mem.span(t) };
}

pub fn speakerTurnCountOf(handle: *const ResultHandle) usize {
    if (comptime has_link) return C.audiocpp_result_speaker_turn_count(handle);
    return 0;
}

pub fn speakerTurnOf(handle: *const ResultHandle, index: usize) Error!SpeakerTurn {
    if (comptime !has_link) return error.AudioCppNotLinked;
    var start: i64 = 0;
    var end: i64 = 0;
    var id: [*:0]const u8 = undefined;
    var conf: f32 = 0;
    var t: [*:0]const u8 = undefined;
    try check(C.audiocpp_result_speaker_turn(handle, index, &start, &end, &id, &conf, &t));
    return .{ .start_sample = start, .end_sample = end, .speaker_id = std.mem.span(id), .confidence = conf, .text = std.mem.span(t) };
}

pub fn namedAudioCountOf(handle: *const ResultHandle) usize {
    if (comptime has_link) return C.audiocpp_result_named_audio_count(handle);
    return 0;
}

pub fn namedAudioOf(handle: *const ResultHandle, index: usize) Error!NamedAudio {
    if (comptime !has_link) return error.AudioCppNotLinked;
    var id: [*:0]const u8 = undefined;
    var samples: [*]const f32 = undefined;
    var frames: usize = 0;
    var rate: c_int = 0;
    var ch: c_int = 0;
    try check(C.audiocpp_result_named_audio(handle, index, &id, &samples, &frames, &rate, &ch));
    return .{
        .id = std.mem.span(id),
        .samples = samples[0 .. frames * @as(usize, @intCast(ch))],
        .sample_rate = @intCast(rate),
        .channels = @intCast(ch),
    };
}

pub fn artifactCountOf(handle: *const ResultHandle) usize {
    if (comptime has_link) return C.audiocpp_result_artifact_count(handle);
    return 0;
}

pub fn artifactOf(handle: *const ResultHandle, index: usize) Error!ArtifactInfo {
    if (comptime !has_link) return error.AudioCppNotLinked;
    var kind: c_int = 0;
    var id: [*:0]const u8 = undefined;
    var payload: ?*const anyopaque = null;
    var bytes: usize = 0;
    try check(C.audiocpp_result_artifact(handle, index, &kind, &id, &payload, &bytes));
    const p = payload orelse return .{ .kind = @enumFromInt(@as(u8, @intCast(kind))), .id = std.mem.span(id), .payload = &.{} };
    const bytes_ptr: [*]const u8 = @ptrCast(p);
    return .{ .kind = @enumFromInt(@as(u8, @intCast(kind))), .id = std.mem.span(id), .payload = bytes_ptr[0..bytes] };
}

test "taskFromSpecName maps spec names to canonical tokens (live when linked)" {
    const alloc = std.testing.allocator;
    if (comptime has_link) {
        try std.testing.expectEqualStrings("asr", (try taskFromSpecName(alloc, "asr")).?);
        try std.testing.expectEqualStrings("tts", (try taskFromSpecName(alloc, "tts")).?);
        try std.testing.expect((try taskFromSpecName(alloc, "not-a-real-task-xyz")) == null);
    } else {
        try std.testing.expectError(error.AudioCppNotLinked, taskFromSpecName(alloc, "asr"));
    }
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
