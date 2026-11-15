//! The engine: owns config, hardware, runtime, model registry, plugins,
//! frame pool and rings. One Engine per process.
//!
//! Start-up order: config -> hardware -> runtime -> models -> plugins.
//! Shutdown is the reverse. Nothing in the audio path allocates: frames
//! are preallocated, moved by pointer through lock-free rings, and
//! short-lived scratch comes from a bump arena.
//!
//! Reloading the config is deliberately conservative: the model registry
//! and the runtime borrow the config's name/path strings, so a reload
//! that changes the runtime shape (mode, sample rate, channels, or the
//! model list) returns error.ConfigReloadRequiresRestart instead of
//! dangling pointers. Backend and flag-only changes reload live.

const std = @import("std");
const hardware = @import("hardware.zig");
const memory = @import("memory.zig");
const config = @import("config.zig");
const audiocpp = @import("audiocpp.zig");
const runtime = @import("runtime.zig");
const models = @import("models.zig");
const plugin = @import("plugin.zig");

pub const default_config_path = "config/sando.toml";
pub const default_frame_pool_size = 64;
pub const default_ring_capacity = 64;
pub const default_arena_bytes = 1 << 20; // 1 MiB of per-frame scratch

pub const Engine = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    cpu: hardware.CpuInfo,
    backends: []hardware.Backend,
    selected_backend: hardware.Backend,
    rt: runtime.Runtime,
    registry: models.ModelRegistry,
    plugins: plugin.PluginManager,
    pool: memory.FramePool,
    input_ring: memory.RingBuffer(*memory.Frame),
    output_ring: memory.RingBuffer(*memory.Frame),
    arena: memory.AudioArena,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Name of the model that most recently failed to load, if any.
    last_error_model: ?[]const u8 = null,

    /// `cfg` is moved into the engine — the caller must not use it after.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, cfg: config.Config) !Engine {
        var owned_cfg = cfg;
        errdefer owned_cfg.deinit();

        const cpu = hardware.detectCpu(alloc, io) catch hardware.CpuInfo{
            .model_name = try alloc.dupe(u8, "unknown"),
            .vendor = try alloc.dupe(u8, "unknown"),
            .cores = std.Thread.getCpuCount() catch 1,
            .flags = &.{},
        };
        errdefer {
            alloc.free(cpu.model_name);
            alloc.free(cpu.vendor);
            for (cpu.flags) |f| alloc.free(f);
            alloc.free(cpu.flags);
        }

        const backends = try hardware.detectBackends(alloc, io);
        errdefer alloc.free(backends);
        const selected = try hardware.selectBackend(backends, owned_cfg.backend);

        var rt = try runtime.Runtime.init(alloc, io);
        errdefer rt.deinit();

        var registry = models.ModelRegistry.init(alloc, 16, 4 << 30);
        errdefer registry.deinit();

        var plugins = plugin.PluginManager.init(alloc);
        errdefer plugins.deinit();

        const frame_len = owned_cfg.sample_rate / 100; // 10 ms frames
        var pool = try memory.FramePool.init(alloc, default_frame_pool_size, frame_len);
        errdefer pool.deinit(alloc);

        var input_ring = try memory.RingBuffer(*memory.Frame).init(alloc, default_ring_capacity);
        errdefer input_ring.deinit(alloc);
        var output_ring = try memory.RingBuffer(*memory.Frame).init(alloc, default_ring_capacity);
        errdefer output_ring.deinit(alloc);

        var arena = try memory.AudioArena.init(alloc, default_arena_bytes);
        errdefer arena.deinit(alloc);

        return .{
            .alloc = alloc,
            .io = io,
            .cfg = owned_cfg,
            .cpu = cpu,
            .backends = backends,
            .selected_backend = selected,
            .rt = rt,
            .registry = registry,
            .plugins = plugins,
            .pool = pool,
            .input_ring = input_ring,
            .output_ring = output_ring,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.arena.deinit(self.alloc);
        self.output_ring.deinit(self.alloc);
        self.input_ring.deinit(self.alloc);
        self.pool.deinit(self.alloc);
        self.plugins.deinit();
        self.registry.deinit();
        self.rt.deinit();
        self.alloc.free(self.backends);
        self.alloc.free(self.cpu.model_name);
        self.alloc.free(self.cpu.vendor);
        for (self.cpu.flags) |f| self.alloc.free(f);
        self.alloc.free(self.cpu.flags);
        self.cfg.deinit();
        self.* = undefined;
    }

    pub fn isLinked(self: *const Engine) bool {
        return self.rt.isLinked();
    }

    pub fn frameLen(self: *const Engine) usize {
        return self.pool.frame_len;
    }

    /// Register every model in the config and load its weights through
    /// the runtime. Stops at the first failure and records the model
    /// name in `last_error_model`. No weights are ever downloaded.
    pub fn loadConfigModels(self: *Engine) !void {
        for (self.cfg.models) |m| {
            self.loadModel(m.name, m.kind, m.file) catch |err| {
                self.last_error_model = m.name;
                return err;
            };
        }
    }

    /// Load only the config models of one kind. A missing model of
    /// another kind never blocks the run: `run --task asr` works when
    /// the TTS model file is absent. Failures in the requested kind
    /// still fail and record `last_error_model`.
    pub fn loadModelsOfKind(self: *Engine, kind: config.ModelKind) !void {
        for (self.cfg.models) |m| {
            if (m.kind != kind) continue;
            self.loadModel(m.name, m.kind, m.file) catch |err| {
                self.last_error_model = m.name;
                return err;
            };
        }
    }

    /// Load only the models a task needs (asr → stt, tts → tts,
    /// vad → vad). See loadModelsOfKind.
    pub fn loadModelsForTask(self: *Engine, task: runtime.TaskKind) !void {
        const kind: config.ModelKind = switch (task) {
            .asr => .stt,
            .tts => .tts,
            .vad => .vad,
        };
        return self.loadModelsOfKind(kind);
    }

    /// Register one model and load its weights. `config_id`/`weight_id`
    /// are optional audio.cpp model-spec identifiers.
    pub fn loadModel(
        self: *Engine,
        name: []const u8,
        kind: config.ModelKind,
        path: []const u8,
    ) !void {
        const size = models.fileSize(self.io, path) catch 0;
        _ = try self.registry.register(name, kind, path, size);
        // config_id/weight_id are NUL-terminated only for the load
        // call; freed immediately afterwards (block-scoped defer).
        const entry = self.cfg.findModel(name);
        {
            var config_id_z: ?[:0]const u8 = null;
            var weight_id_z: ?[:0]const u8 = null;
            if (entry) |e| {
                if (e.config_id) |id| config_id_z = try dupeZTemp(self.alloc, id);
                if (e.weight_id) |id| weight_id_z = try dupeZTemp(self.alloc, id);
            }
            defer if (config_id_z) |z| self.alloc.free(z);
            defer if (weight_id_z) |z| self.alloc.free(z);
            try self.rt.loadModel(name, path, .{
                .config_id = if (config_id_z) |z| z.ptr else null,
                .weight_id = if (weight_id_z) |z| z.ptr else null,
            });
        }
        try self.registry.markLoaded(name, true);
        try self.registry.touch(self.io, name);
    }

    /// Create a session for a loaded model. Threads default to the CPU
    /// core count; the backend is the engine's selected backend.
    pub fn createSession(
        self: *Engine,
        model_name: []const u8,
        task: runtime.TaskKind,
        mode: runtime.StreamMode,
    ) !runtime.Session {
        const threads: i32 = @intCast(@min(self.cpu.cores, 8));
        return self.rt.createSession(
            model_name,
            task,
            mode,
            self.selected_backend.kind.name(),
            0,
            threads,
        );
    }

    /// Reload a freshly parsed config. Only backend and flag-only
    /// changes apply live; anything that changes the runtime shape
    /// (mode, sample rate, channels, model list) requires a restart.
    pub fn reloadConfig(self: *Engine, new_cfg: config.Config) !void {
        var new_owned = new_cfg;
        errdefer new_owned.deinit();

        const shape_changed =
            new_owned.mode != self.cfg.mode or
            new_owned.sample_rate != self.cfg.sample_rate or
            new_owned.channels != self.cfg.channels or
            !sameModelList(self.cfg.models, new_owned.models);
        if (shape_changed) return error.ConfigReloadRequiresRestart;

        const selected = try hardware.selectBackend(self.backends, new_owned.backend);
        self.selected_backend = selected;

        const old = self.cfg;
        self.cfg = new_owned;
        self.last_error_model = null;
        var old_mut = old;
        old_mut.deinit();

        // Refresh registry sizes from the new config (records are
        // self-owned, so the swap cannot dangle them).
        for (self.cfg.models) |m| {
            const size = models.fileSize(self.io, m.file) catch 0;
            _ = try self.registry.register(m.name, m.kind, m.file, size);
        }
    }

    /// Whether `new_cfg` may replace the running config (see reloadConfig).
    pub fn canReload(self: *const Engine, new_cfg: *const config.Config) bool {
        return new_cfg.mode == self.cfg.mode and
            new_cfg.sample_rate == self.cfg.sample_rate and
            new_cfg.channels == self.cfg.channels and
            sameModelList(self.cfg.models, new_cfg.models);
    }
};

fn sameModelList(a: []const config.ModelEntry, b: []const config.ModelEntry) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (x.kind != y.kind) return false;
        if (!std.mem.eql(u8, x.file, y.file)) return false;
    }
    return true;
}

/// Temporary NUL-terminated copy for the C ABI. The caller frees it
/// after the call that needs it.
fn dupeZTemp(alloc: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    const buf = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len :0];
}

test "engine init from the example config" {
    const alloc = std.testing.allocator;
    const cfg = try config.parse(alloc,
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[[models]]
        \\name = "qwen3-tts-0.6b"
        \\kind = "tts"
        \\file = "models/qwen3-tts-0.6b-q8_0.gguf"
        \\voice = "liberian-voice-01"
        \\streaming = true
        \\language = "en"
        \\
    );
    var engine = try Engine.init(alloc, std.testing.io, cfg);
    defer engine.deinit();
    try std.testing.expect(engine.selected_backend.available);
    try std.testing.expectEqual(@as(usize, 240), engine.frameLen());
    try std.testing.expectEqual(@as(usize, default_frame_pool_size), engine.pool.capacity());
    try std.testing.expect(engine.input_ring.len() == 0);
    // Model files do not exist in the repo — loading fails honestly and
    // names the model.
    try std.testing.expectError(error.LoadFailed, engine.loadConfigModels());
    try std.testing.expectEqualStrings("qwen3-tts-0.6b", engine.last_error_model.?);
}

test "reload accepts flag-only changes, refuses shape changes" {
    const alloc = std.testing.allocator;
    const cfg = try config.parse(alloc,
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\
    );
    var engine = try Engine.init(alloc, std.testing.io, cfg);
    defer engine.deinit();

    var same = try config.parse(alloc,
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "cpu"
        \\webgpu = true
        \\
    );
    try std.testing.expect(engine.canReload(&same));
    try engine.reloadConfig(same);
    try std.testing.expectEqualStrings("cpu", engine.selected_backend.kind.name());

    var changed = try config.parse(alloc,
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 48000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\
    );
    try std.testing.expect(!engine.canReload(&changed));
    try std.testing.expectError(error.ConfigReloadRequiresRestart, engine.reloadConfig(changed));
}

test "lazy loading: asr run succeeds when the tts model file is missing" {
    const alloc = std.testing.allocator;
    const cfg = try config.parse(alloc,
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[[models]]
        \\name = "qwen3-tts-0.6b"
        \\kind = "tts"
        \\file = "models/does-not-exist-tts.gguf"
        \\[[models]]
        \\name = "moonshine-small"
        \\kind = "stt"
        \\file = "models/does-not-exist-stt.gguf"
        \\
    );
    var engine = try Engine.init(alloc, std.testing.io, cfg);
    defer engine.deinit();
    // No stt model file exists, so loading the asr kind fails — but on
    // the STT model, never on the (also missing) TTS model. The point:
    // the TTS entry is never attempted.
    if (audiocpp.has_link) {
        try std.testing.expectError(error.LoadFailed, engine.loadModelsForTask(.asr));
    } else {
        try std.testing.expectError(error.AudioCppNotLinked, engine.loadModelsForTask(.asr));
    }
    try std.testing.expectEqualStrings("moonshine-small", engine.last_error_model.?);

    // And with a config that has ONLY a tts model, an asr run loads
    // nothing and succeeds — the missing TTS file never blocks it.
    const cfg2 = try config.parse(alloc,
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[[models]]
        \\name = "qwen3-tts-0.6b"
        \\kind = "tts"
        \\file = "models/does-not-exist-tts.gguf"
        \\
    );
    var engine2 = try Engine.init(alloc, std.testing.io, cfg2);
    defer engine2.deinit();
    try engine2.loadModelsForTask(.asr);
    try std.testing.expect(engine2.last_error_model == null);
}
