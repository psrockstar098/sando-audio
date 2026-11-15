//! Command-line interface.
//!
//!   sando-audio version
//!   sando-audio doctor
//!   sando-audio config validate <path>
//!   sando-audio run [--config path] [--model name] [--task asr|tts|vad]
//!                   [--mode offline|streaming] [--text "..."]
//!                   [--wav in.wav] [--out out.wav]
//!   sando-audio bench [--config path] [--model name] [--task asr|tts]
//!                     [--iterations n] [--text "..."]
//!   sando-audio models list [--config path]
//!   sando-audio plugins list [--dir path]
//!   sando-audio plugins load <path>
//!   sando-audio help
//!
//! Exit codes: 0 ok, 1 runtime failure, 2 usage error.

const std = @import("std");
const root = @import("root.zig");
const audiocpp = @import("audiocpp.zig");
const config = @import("config.zig");
const engine = @import("engine.zig");
const runtime = @import("runtime.zig");
const audio = @import("audio.zig");
const doctor = @import("doctor.zig");
const bench = @import("bench.zig");
const plugin = @import("plugin.zig");
const streaming = @import("streaming.zig");
const vad = @import("vad.zig");
const voicedna = @import("voicedna.zig");
const cache = @import("cache.zig");
const audiosense = @import("audiosense.zig");

pub const usage =
    \\sando-audio 0.2.0 — SANDO Audio, Phase 2 (Real-Time Speech & Voice Intelligence)
    \\
    \\Usage:
    \\  sando-audio version
    \\  sando-audio doctor
    \\  sando-audio config validate <path>
    \\  sando-audio run [--config path] [--model name] [--task asr|tts|vad]
    \\                  [--mode offline|streaming] [--text "..."]
    \\                  [--wav in.wav] [--out out.wav] [--cache] [--voice name]
    \\  sando-audio stream [--config path] [--model name] [--wav in.wav] [--cache]
    \\  sando-audio vad [--config path] [--model name] [--wav in.wav]
    \\  sando-audio voices list
    \\  sando-audio voices enroll-synthetic <id> <name> [--language en]
    \\  sando-audio voices delete <id>
    \\  sando-audio bench [--config path] [--model name] [--task asr|tts]
    \\                    [--iterations n] [--text "..."]
    \\  sando-audio models list [--config path]
    \\  sando-audio plugins list [--dir path]
    \\  sando-audio plugins load <path>
    \\  sando-audio plugins load --manifest <path>
    \\  sando-audio help
    \\
;

pub const RunOpts = struct {
    config_path: []const u8 = engine.default_config_path,
    model: ?[]const u8 = null,
    task: runtime.TaskKind = .tts,
    mode: runtime.StreamMode = .offline,
    text: ?[]const u8 = null,
    wav_in: ?[]const u8 = null,
    wav_out: ?[]const u8 = null,
    /// Use the SmartCache (voice/language/context-aware). A hit skips
    /// inference entirely and prints "cache hit".
    cache: bool = false,
    /// Voice id for the TTS cache key (defaults to the model's voice).
    voice: ?[]const u8 = null,
};

pub const StreamOpts = struct {
    config_path: []const u8 = engine.default_config_path,
    model: ?[]const u8 = null,
    wav_in: ?[]const u8 = null,
    cache: bool = false,
};

pub const VadOpts = struct {
    config_path: []const u8 = engine.default_config_path,
    model: ?[]const u8 = null,
    wav_in: ?[]const u8 = null,
};

pub const VoicesOpts = union(enum) {
    list,
    enroll_synthetic: struct { id: []const u8, name: []const u8, language: []const u8 },
    delete: struct { id: []const u8 },
};

pub const BenchOpts = struct {
    config_path: []const u8 = engine.default_config_path,
    model: ?[]const u8 = null,
    task: runtime.TaskKind = .tts,
    iterations: u64 = 100,
    text: ?[]const u8 = null,
};

pub const Command = union(enum) {
    version,
    doctor,
    help,
    config_validate: struct { path: []const u8 },
    run: RunOpts,
    stream: StreamOpts,
    vad: VadOpts,
    voices: VoicesOpts,
    bench: BenchOpts,
    models_list: struct { config_path: []const u8 },
    plugins_list: struct { dir: []const u8 },
    plugins_load: struct { path: []const u8 },
    plugins_load_manifest: struct { path: []const u8 },
};

pub const ParseError = error{ Usage, OutOfMemory };

/// Parse argv (without argv[0]) into a Command. Pure — no I/O.
pub fn parseArgs(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.Usage;
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "version")) return .version;
    if (std.mem.eql(u8, cmd, "doctor")) return .doctor;
    if (std.mem.eql(u8, cmd, "help")) return .help;

    if (std.mem.eql(u8, cmd, "config")) {
        if (args.len == 3 and std.mem.eql(u8, args[1], "validate")) {
            return .{ .config_validate = .{ .path = args[2] } };
        }
        return error.Usage;
    }

    if (std.mem.eql(u8, cmd, "models")) {
        if (args.len >= 2 and std.mem.eql(u8, args[1], "list")) {
            var path: []const u8 = engine.default_config_path;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
                    path = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .models_list = .{ .config_path = path } };
        }
        return error.Usage;
    }

    if (std.mem.eql(u8, cmd, "plugins")) {
        if (args.len >= 2 and std.mem.eql(u8, args[1], "list")) {
            var dir: []const u8 = "plugins";
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--dir") and i + 1 < args.len) {
                    dir = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .plugins_list = .{ .dir = dir } };
        }
        if (args.len == 4 and std.mem.eql(u8, args[1], "load") and std.mem.eql(u8, args[2], "--manifest")) {
            return .{ .plugins_load_manifest = .{ .path = args[3] } };
        }
        if (args.len == 3 and std.mem.eql(u8, args[1], "load")) {
            return .{ .plugins_load = .{ .path = args[2] } };
        }
        return error.Usage;
    }

    if (std.mem.eql(u8, cmd, "run")) {
        var opts = RunOpts{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (i + 1 < args.len and std.mem.eql(u8, a, "--config")) {
                opts.config_path = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--model")) {
                opts.model = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--task")) {
                const t = args[i + 1];
                if (std.mem.eql(u8, t, "asr")) opts.task = .asr else if (std.mem.eql(u8, t, "tts")) opts.task = .tts else if (std.mem.eql(u8, t, "vad")) opts.task = .vad else return error.Usage;
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--mode")) {
                const m = args[i + 1];
                if (std.mem.eql(u8, m, "offline")) opts.mode = .offline else if (std.mem.eql(u8, m, "streaming")) opts.mode = .streaming else return error.Usage;
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--text")) {
                opts.text = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--wav")) {
                opts.wav_in = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--out")) {
                opts.wav_out = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, a, "--cache")) {
                opts.cache = true;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--voice")) {
                opts.voice = args[i + 1];
                i += 1;
            } else return error.Usage;
        }
        return .{ .run = opts };
    }

    if (std.mem.eql(u8, cmd, "stream")) {
        var opts = StreamOpts{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (i + 1 < args.len and std.mem.eql(u8, a, "--config")) {
                opts.config_path = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--model")) {
                opts.model = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--wav")) {
                opts.wav_in = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, a, "--cache")) {
                opts.cache = true;
            } else return error.Usage;
        }
        if (opts.wav_in == null) return error.Usage;
        return .{ .stream = opts };
    }

    if (std.mem.eql(u8, cmd, "vad")) {
        var opts = VadOpts{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (i + 1 < args.len and std.mem.eql(u8, a, "--config")) {
                opts.config_path = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--model")) {
                opts.model = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--wav")) {
                opts.wav_in = args[i + 1];
                i += 1;
            } else return error.Usage;
        }
        if (opts.wav_in == null) return error.Usage;
        return .{ .vad = opts };
    }

    if (std.mem.eql(u8, cmd, "voices")) {
        if (args.len >= 2 and std.mem.eql(u8, args[1], "list")) {
            if (args.len != 2) return error.Usage;
            return .{ .voices = .list };
        }
        if (args.len >= 2 and std.mem.eql(u8, args[1], "enroll-synthetic")) {
            if (args.len < 4) return error.Usage;
            var language: []const u8 = "en";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (i + 1 < args.len and std.mem.eql(u8, args[i], "--language")) {
                    language = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .voices = .{ .enroll_synthetic = .{ .id = args[2], .name = args[3], .language = language } } };
        }
        if (args.len == 3 and std.mem.eql(u8, args[1], "delete")) {
            return .{ .voices = .{ .delete = .{ .id = args[2] } } };
        }
        return error.Usage;
    }

    if (std.mem.eql(u8, cmd, "bench")) {
        var opts = BenchOpts{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (i + 1 < args.len and std.mem.eql(u8, a, "--config")) {
                opts.config_path = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--model")) {
                opts.model = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--task")) {
                const t = args[i + 1];
                if (std.mem.eql(u8, t, "asr")) opts.task = .asr else if (std.mem.eql(u8, t, "tts")) opts.task = .tts else return error.Usage;
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--iterations")) {
                opts.iterations = std.fmt.parseInt(u64, args[i + 1], 10) catch return error.Usage;
                if (opts.iterations == 0) return error.Usage;
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--text")) {
                opts.text = args[i + 1];
                i += 1;
            } else return error.Usage;
        }
        return .{ .bench = opts };
    }

    return error.Usage;
}

/// Entry point for main.zig. Returns the process exit code.
pub fn run(init: std.process.Init) u8 {
    const alloc = init.arena.allocator();
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.iterate(init.minimal.args);
    _ = it.next(); // argv[0]
    while (it.next()) |arg| argv.append(alloc, arg) catch return 1;

    const cmd = parseArgs(argv.items) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    var out_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;

    return dispatch(alloc, io, out, cmd) catch |err| {
        std.debug.print("error: {t}\n", .{err});
        return 1;
    };
}

fn dispatch(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, cmd: Command) !u8 {
    switch (cmd) {
        .version => {
            try out.print("{s}\n", .{root.version_string});
            try out.flush();
            return 0;
        },
        .help => {
            try out.print("{s}", .{usage});
            try out.flush();
            return 0;
        },
        .doctor => {
            var report = try doctor.collect(alloc, io);
            defer report.deinit(alloc);
            try doctor.print(out, &report);
            try out.flush();
            return 0;
        },
        .config_validate => |v| {
            var cfg = config.loadFromFile(alloc, io, v.path) catch |err| {
                std.debug.print("config {s}: INVALID ({t})\n", .{ v.path, err });
                return 1;
            };
            defer cfg.deinit();
            try out.print("config {s}: valid ({d} model(s), backend {s})\n", .{ v.path, cfg.models.len, cfg.backend });
            try out.flush();
            return 0;
        },
        .models_list => |m| {
            var cfg = config.loadFromFile(alloc, io, m.config_path) catch |err| {
                std.debug.print("config {s}: INVALID ({t})\n", .{ m.config_path, err });
                return 1;
            };
            defer cfg.deinit();
            if (cfg.models.len == 0) {
                try out.print("no models in {s}\n", .{m.config_path});
            }
            for (cfg.models) |model| {
                try out.print("  {s} [{s}] {s} streaming={} voice={s}\n", .{
                    model.name,
                    @tagName(model.kind),
                    model.file,
                    model.streaming,
                    model.voice orelse "-",
                });
            }
            try out.flush();
            return 0;
        },
        .plugins_list => |p| {
            var mgr = plugin.PluginManager.init(alloc);
            defer mgr.deinit();
            const names = listPluginFiles(io, alloc, p.dir) catch {
                try out.print("no plugins directory at {s}\n", .{p.dir});
                try out.flush();
                return 0;
            };
            defer {
                for (names) |n| alloc.free(n);
                alloc.free(names);
            }
            var found = false;
            for (names) |name| {
                found = true;
                const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ p.dir, name });
                if (mgr.load(path)) |loaded| {
                    try out.print("  {s} [{s}] {s} — loads OK\n", .{
                        std.mem.span(loaded.descriptor.name),
                        @tagName(loaded.kind),
                        std.mem.span(loaded.descriptor.version),
                    });
                    mgr.unload(loaded.name) catch {};
                } else |err| {
                    try out.print("  {s} — does not load ({t})\n", .{ name, err });
                }
            }
            if (!found) try out.print("no .so plugins in {s}\n", .{p.dir});
            try out.flush();
            return 0;
        },
        .plugins_load => |p| {
            var mgr = plugin.PluginManager.init(alloc);
            defer mgr.deinit();
            const loaded = mgr.load(p.path) catch |err| {
                std.debug.print("plugin {s}: failed to load ({t})\n", .{ p.path, err });
                return 1;
            };
            try out.print("loaded plugin {s} [{s}] version {s}\n", .{
                std.mem.span(loaded.descriptor.name),
                @tagName(loaded.kind),
                std.mem.span(loaded.descriptor.version),
            });
            try out.flush();
            return 0;
        },
        .plugins_load_manifest => |p| {
            var mgr = plugin.PluginManager.init(alloc);
            defer mgr.deinit();
            const loaded = mgr.loadWithManifest(io, p.path) catch |err| {
                std.debug.print("plugin manifest {s}: failed to load ({t})\n", .{ p.path, err });
                return 1;
            };
            try out.print("loaded plugin {s} [{s}] version {s} (manifest {s})\n", .{
                std.mem.span(loaded.descriptor.name),
                @tagName(loaded.kind),
                std.mem.span(loaded.descriptor.version),
                p.path,
            });
            try out.flush();
            return 0;
        },
        .run => |opts| return cmdRun(alloc, io, out, opts),
        .stream => |opts| return cmdStream(alloc, io, out, opts),
        .vad => |opts| return cmdVad(alloc, io, out, opts),
        .voices => |opts| return cmdVoices(alloc, io, out, opts),
        .bench => |opts| return cmdBench(alloc, io, out, opts),
    }
}

/// Lists the .so files in a directory. The directory MUST be opened with
/// `.iterate = true` — without it the OS handle is O_PATH and iterating
/// panics with BADF (caught by the smoke test 2026-11-15).
fn listPluginFiles(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var out = std.ArrayList([]const u8).empty;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".so")) continue;
        try out.append(alloc, try alloc.dupe(u8, entry.name));
    }
    return out.toOwnedSlice(alloc);
}

fn loadEngine(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !engine.Engine {
    const cfg = try config.loadFromFile(alloc, io, path);
    return engine.Engine.init(alloc, io, cfg);
}

fn pickModel(cfg: *const config.Config, wanted: ?[]const u8, task: runtime.TaskKind) ?*const config.ModelEntry {
    if (wanted) |name| return cfg.findModel(name);
    for (cfg.models) |*m| {
        const kind_matches = switch (task) {
            .asr => m.kind == .stt,
            .tts => m.kind == .tts,
            .vad => m.kind == .vad,
        };
        if (kind_matches) return m;
    }
    return null;
}

fn cmdRun(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: RunOpts) !u8 {
    // Usage checks before the engine starts, so a missing --text/--wav is
    // a usage error (2), not a runtime failure (1).
    if (opts.task == .tts and opts.text == null) {
        std.debug.print("tts needs --text \"...\"\n", .{});
        return 2;
    }
    if (opts.task != .tts and opts.wav_in == null) {
        std.debug.print("{s} needs --wav in.wav\n", .{@tagName(opts.task)});
        return 2;
    }
    var eng = loadEngine(alloc, io, opts.config_path) catch |err| {
        std.debug.print("cannot start engine from {s} ({t})\n", .{ opts.config_path, err });
        return 1;
    };
    defer eng.deinit();

    // Lazy: load only the models this task needs. A missing TTS file
    // never blocks an ASR run (and vice versa).
    eng.loadModelsForTask(opts.task) catch |err| {
        std.debug.print("cannot load model {s} ({t})\n", .{ eng.last_error_model orelse "?", err });
        return 1;
    };

    const model = pickModel(&eng.cfg, opts.model, opts.task) orelse {
        std.debug.print("no {s} model in {s}\n", .{ @tagName(opts.task), opts.config_path });
        return 1;
    };
    const task_kind: runtime.TaskKind = switch (model.kind) {
        .stt => .asr,
        .tts => .tts,
        .vad => .vad,
    };

    // The SmartCache is in-process only (64 MiB). A hit skips
    // inference entirely.
    var smart_cache = cache.SmartCache.init(alloc, 64 << 20);
    defer smart_cache.deinit();

    switch (task_kind) {
        .tts => {
            const text = opts.text orelse {
                std.debug.print("tts needs --text \"...\"\n", .{});
                return 2;
            };
            if (opts.cache) {
                const voice = opts.voice orelse model.voice orelse "default";
                const lang = model.language orelse "en";
                if (try smart_cache.getTts(voice, lang, "cli-run", text)) |hit| {
                    const path = opts.wav_out orelse "out.wav";
                    try audio.writeWavFile(io, path, hit.samples, hit.sample_rate, hit.channels, .pcm16);
                    try out.print("cache hit: wrote {s} ({d} samples @ {d} Hz)\n", .{ path, hit.samples.len, hit.sample_rate });
                    try out.flush();
                    return 0;
                }
            }
            var session = eng.createSession(model.name, task_kind, opts.mode) catch |err| {
                std.debug.print("cannot create session for {s} ({t})\n", .{ model.name, err });
                return 1;
            };
            defer session.deinit(alloc);
            const req = runtime.Request{
                .task = .tts,
                .mode = opts.mode,
                .text = text,
                .language = model.language,
            };
            var resp: runtime.Response = undefined;
            if (opts.mode == .streaming) {
                try session.streamStart(alloc, req);
                resp = try session.streamFinish();
            } else {
                resp = try session.run(io, alloc, req);
            }
            defer resp.deinit();
            if (opts.cache) {
                const a = try resp.audio();
                const voice = opts.voice orelse model.voice orelse "default";
                const lang = model.language orelse "en";
                try smart_cache.putTts(voice, lang, "cli-run", text, a.samples, a.sample_rate, a.channels);
            }
            return writeTtsOutput(io, out, &resp, opts.wav_out);
        },
        .asr, .vad => {
            const wav_path = opts.wav_in orelse {
                std.debug.print("{s} needs --wav in.wav\n", .{@tagName(task_kind)});
                return 2;
            };
            var wav = audio.readWavFile(alloc, io, wav_path) catch |err| {
                std.debug.print("cannot read {s} ({t})\n", .{ wav_path, err });
                return 1;
            };
            defer wav.deinit(alloc);
            if (opts.cache and task_kind == .asr) {
                const lang = model.language orelse "en";
                if (try smart_cache.getAsr(lang, wav.samples)) |cached| {
                    try out.print("{s}\n", .{cached});
                    try out.print("cache hit (asr)\n", .{});
                    try out.flush();
                    return 0;
                }
            }
            var session = eng.createSession(model.name, task_kind, opts.mode) catch |err| {
                std.debug.print("cannot create session for {s} ({t})\n", .{ model.name, err });
                return 1;
            };
            defer session.deinit(alloc);
            var resp: runtime.Response = undefined;
            if (opts.mode == .streaming) {
                try session.streamStart(alloc, null);
                const frame_len = eng.frameLen();
                var offset: usize = 0;
                while (offset < wav.samples.len) {
                    const end = @min(offset + frame_len * @as(usize, wav.channels), wav.samples.len);
                    const chunk = wav.samples[offset..end];
                    const event = try session.streamPush(chunk, wav.sample_rate, wav.channels, @intCast(offset / @as(usize, wav.channels)));
                    if (event) |ev| audiocpp.eventFree(ev);
                    offset = end;
                }
                resp = try session.streamFinish();
            } else {
                const req = runtime.Request{
                    .task = task_kind,
                    .mode = .offline,
                    .audio = wav.samples,
                    .sample_rate = wav.sample_rate,
                    .channels = wav.channels,
                    .language = model.language,
                };
                resp = try session.run(io, alloc, req);
            }
            defer resp.deinit();
            if (opts.cache and task_kind == .asr) {
                const t = try resp.text();
                try smart_cache.putAsr(model.language orelse "en", wav.samples, t.text);
            }
            return writeAsrOutput(out, &resp);
        },
    }
}

/// Streaming ASR over a WAV file through the LiveStream Engine:
/// partial transcripts and VAD activity print as they arrive, then
/// the final text. With --cache, a repeat of the same audio prints
/// the cached transcript without inference.
fn cmdStream(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: StreamOpts) !u8 {
    const wav_path = opts.wav_in orelse {
        std.debug.print("stream needs --wav in.wav\n", .{});
        return 2;
    };
    var eng = loadEngine(alloc, io, opts.config_path) catch |err| {
        std.debug.print("cannot start engine from {s} ({t})\n", .{ opts.config_path, err });
        return 1;
    };
    defer eng.deinit();

    eng.loadModelsForTask(.asr) catch |err| {
        std.debug.print("cannot load model {s} ({t})\n", .{ eng.last_error_model orelse "?", err });
        return 1;
    };
    const model = pickModel(&eng.cfg, opts.model, .asr) orelse {
        std.debug.print("no asr model in {s}\n", .{opts.config_path});
        return 1;
    };
    var wav = audio.readWavFile(alloc, io, wav_path) catch |err| {
        std.debug.print("cannot read {s} ({t})\n", .{ wav_path, err });
        return 1;
    };
    defer wav.deinit(alloc);

    var smart_cache = cache.SmartCache.init(alloc, 64 << 20);
    defer smart_cache.deinit();
    if (opts.cache) {
        const lang = model.language orelse "en";
        if (try smart_cache.getAsr(lang, wav.samples)) |cached| {
            try out.print("{s}\n", .{cached});
            try out.print("cache hit (asr)\n", .{});
            try out.flush();
            return 0;
        }
    }

    var session = eng.createSession(model.name, .asr, .streaming) catch |err| {
        std.debug.print("cannot create session for {s} ({t})\n", .{ model.name, err });
        return 1;
    };
    defer session.deinit(alloc);
    try session.streamStart(alloc, null);

    var live = streaming.LiveStream.init(alloc, &session, null, wav.sample_rate);
    defer live.deinit();

    const frame_len = eng.frameLen();
    var offset: usize = 0;
    var partials: usize = 0;
    while (offset < wav.samples.len) {
        const end = @min(offset + frame_len * @as(usize, wav.channels), wav.samples.len);
        const chunk = wav.samples[offset..end];
        const events = try live.pushMic(chunk, wav.sample_rate, wav.channels);
        defer {
            for (events) |*ev| ev.deinit(alloc);
            alloc.free(events);
        }
        for (events) |ev| {
            for (ev.vad) |act| {
                try out.print("vad: {s} @{d} ({d:.2})\n", .{ @tagName(act.kind), act.sample, act.probability });
            }
            if (ev.text) |t| {
                partials += 1;
                try out.print("partial: {s}\n", .{t});
            }
        }
        offset = end;
    }
    var resp = try session.streamFinish();
    defer resp.deinit();
    const t = try resp.text();
    try out.print("final: {s}\n", .{t.text});
    try out.print("vad segments: {d}, partial events: {d}, barge-ins: {d}\n", .{
        live.tracker.segmentCount(),
        partials,
        live.bargeInCount(),
    });
    if (opts.cache) {
        try smart_cache.putAsr(model.language orelse "en", wav.samples, t.text);
    }
    try out.flush();
    return 0;
}

/// VAD over a WAV file. With a vad model loaded, the model runs and
/// its segments print; without one, the energy fallback runs and the
/// output says so — never presented as a model result.
fn cmdVad(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: VadOpts) !u8 {
    const wav_path = opts.wav_in orelse {
        std.debug.print("vad needs --wav in.wav\n", .{});
        return 2;
    };
    var eng = loadEngine(alloc, io, opts.config_path) catch |err| {
        std.debug.print("cannot start engine from {s} ({t})\n", .{ opts.config_path, err });
        return 1;
    };
    defer eng.deinit();
    var wav = audio.readWavFile(alloc, io, wav_path) catch |err| {
        std.debug.print("cannot read {s} ({t})\n", .{ wav_path, err });
        return 1;
    };
    defer wav.deinit(alloc);

    const model = pickModel(&eng.cfg, opts.model, .vad);
    if (model) |m| {
        if (eng.loadModelsForTask(.vad)) {
            var session = eng.createSession(m.name, .vad, .offline) catch null;
            if (session) |*s| {
                defer s.deinit(alloc);
                const req = runtime.Request{
                    .task = .vad,
                    .mode = .offline,
                    .audio = wav.samples,
                    .sample_rate = wav.sample_rate,
                    .channels = wav.channels,
                    .language = m.language,
                };
                if (s.run(io, alloc, req)) |resp| {
                    var r = resp;
                    defer r.deinit();
                    const segs = try r.result.segments(alloc);
                    defer alloc.free(segs);
                    for (segs) |seg| {
                        try out.print("segment: {d}..{d} conf {d:.2}\n", .{ seg.start_sample, seg.end_sample, seg.confidence });
                    }
                    try out.print("vad: model ({s}), {d} segment(s)\n", .{ m.name, segs.len });
                    try out.flush();
                    return 0;
                } else |_| {}
            }
        } else |_| {}
    }

    // No vad model available: energy fallback, labelled as such.
    var energy = vad.EnergyVad.init(wav.sample_rate);
    var tracker = vad.VadTracker.init(alloc, wav.sample_rate);
    defer tracker.deinit();
    var offset: usize = 0;
    const chunk_frames = wav.sample_rate / 10; // 100 ms chunks
    while (offset < wav.samples.len) {
        const end = @min(offset + chunk_frames * @as(usize, wav.channels), wav.samples.len);
        // EnergyVad is mono: feed channel 0 when stereo.
        if (wav.channels == 1) {
            if (energy.feed(wav.samples[offset..end])) |act| try tracker.feed(act);
        } else {
            var mono = try alloc.alloc(f32, (end - offset) / @as(usize, wav.channels));
            defer alloc.free(mono);
            for (0..mono.len) |i| mono[i] = wav.samples[offset + i * @as(usize, wav.channels)];
            if (energy.feed(mono)) |act| try tracker.feed(act);
        }
        offset = end;
    }
    try tracker.finish(@intCast(wav.samples.len / @as(usize, wav.channels)));
    for (tracker.segments.items) |seg| {
        try out.print("segment: {d}..{d} peak {d:.2}\n", .{ seg.start_sample, seg.end_sample, seg.peak_probability });
    }
    try out.print("vad: energy fallback (no vad model loaded), {d} segment(s)\n", .{tracker.segmentCount()});
    try out.flush();
    return 0;
}

/// VoiceDNA voice profiles: list, enroll a synthetic voice, delete.
fn cmdVoices(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: VoicesOpts) !u8 {
    const store = voicedna.VoiceStore.init(alloc, io, "voices");
    switch (opts) {
        .list => {
            const profiles = try store.list();
            defer {
                for (profiles) |*p| p.deinit(alloc);
                alloc.free(profiles);
            }
            if (profiles.len == 0) {
                try out.print("no voice profiles in voices/\n", .{});
            }
            for (profiles) |p| {
                try out.print("  {s} \"{s}\" [{s}] source={s} consent={}\n", .{
                    p.id, p.name, p.language, p.source.name(), p.consent,
                });
            }
            try out.flush();
            return 0;
        },
        .enroll_synthetic => |e| {
            var profile = store.enrollSynthetic(e.id, e.name, e.language) catch |err| {
                std.debug.print("cannot enroll voice {s} ({t})\n", .{ e.id, err });
                return 1;
            };
            defer profile.deinit(alloc);
            try out.print("enrolled synthetic voice {s} \"{s}\" [{s}] -> {s}\n", .{
                profile.id, profile.name, profile.language, profile.reference_wav,
            });
            try out.flush();
            return 0;
        },
        .delete => |d| {
            store.delete(d.id) catch |err| {
                std.debug.print("cannot delete voice {s} ({t})\n", .{ d.id, err });
                return 1;
            };
            try out.print("deleted voice {s}\n", .{d.id});
            try out.flush();
            return 0;
        },
    }
}

fn writeTtsOutput(io: std.Io, out: *std.Io.Writer, resp: *runtime.Response, wav_out: ?[]const u8) !u8 {
    const a = try resp.audio();
    const path = wav_out orelse "out.wav";
    try audio.writeWavFile(io, path, a.samples, a.sample_rate, a.channels, .pcm16);
    try out.print("wrote {s} ({d} samples @ {d} Hz, {d:.1} ms)\n", .{ path, a.samples.len, a.sample_rate, resp.latencyMs() });
    try out.flush();
    return 0;
}

fn writeAsrOutput(out: *std.Io.Writer, resp: *runtime.Response) !u8 {
    const t = try resp.text();
    try out.print("{s}\n", .{t.text});
    try out.flush();
    return 0;
}

fn cmdBench(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: BenchOpts) !u8 {
    try out.print("sando-audio bench\n", .{});
    const mem_result = try bench.benchMemory(alloc, io, 1000);
    try bench.printResult(out, &mem_result);

    var eng = loadEngine(alloc, io, opts.config_path) catch |err| {
        std.debug.print("inference skipped: cannot start engine ({t})\n", .{err});
        try out.flush();
        return 0;
    };
    defer eng.deinit();
    eng.loadModelsForTask(opts.task) catch |err| {
        std.debug.print("inference skipped: cannot load model {s} ({t})\n", .{ eng.last_error_model orelse "?", err });
        try out.flush();
        return 0;
    };
    const model = pickModel(&eng.cfg, opts.model, opts.task) orelse {
        std.debug.print("inference skipped: no {s} model in {s}\n", .{ @tagName(opts.task), opts.config_path });
        try out.flush();
        return 0;
    };
    const task_kind: runtime.TaskKind = switch (model.kind) {
        .stt => .asr,
        .tts => .tts,
        .vad => .vad,
    };
    var session = eng.createSession(model.name, task_kind, .offline) catch |err| {
        std.debug.print("inference skipped: cannot create session ({t})\n", .{err});
        try out.flush();
        return 0;
    };
    defer session.deinit(alloc);

    const req: runtime.Request = switch (task_kind) {
        .tts => .{
            .task = .tts,
            .mode = .offline,
            .text = opts.text orelse "Hello, this is Sando.",
            .language = model.language,
        },
        .asr, .vad => blk: {
            // One second of silence at the engine's sample rate.
            const samples = try alloc.alloc(f32, eng.cfg.sample_rate);
            @memset(samples, 0);
            break :blk .{
                .task = task_kind,
                .mode = .offline,
                .audio = samples,
                .sample_rate = eng.cfg.sample_rate,
                .channels = eng.cfg.channels,
                .language = model.language,
            };
        },
    };
    const inf_result = try bench.benchInference(&session, io, alloc, req, opts.iterations);
    try bench.printResult(out, &inf_result);
    try out.flush();
    return 0;
}

test "parseArgs accepts the main commands" {
    const v = try parseArgs(&.{"version"});
    try std.testing.expect(v == .version);
    const d = try parseArgs(&.{"doctor"});
    try std.testing.expect(d == .doctor);
    const cv = try parseArgs(&.{ "config", "validate", "config/sando.toml" });
    try std.testing.expect(std.mem.eql(u8, cv.config_validate.path, "config/sando.toml"));
    const r = try parseArgs(&.{ "run", "--task", "tts", "--text", "hello", "--mode", "streaming" });
    try std.testing.expect(r.run.task == .tts);
    try std.testing.expect(r.run.mode == .streaming);
    try std.testing.expectEqualStrings("hello", r.run.text.?);
    const rc = try parseArgs(&.{ "run", "--task", "tts", "--text", "hi", "--cache", "--voice", "v1" });
    try std.testing.expect(rc.run.cache);
    try std.testing.expectEqualStrings("v1", rc.run.voice.?);
    const s = try parseArgs(&.{ "stream", "--wav", "in.wav", "--cache" });
    try std.testing.expectEqualStrings("in.wav", s.stream.wav_in.?);
    try std.testing.expect(s.stream.cache);
    const vc = try parseArgs(&.{ "vad", "--wav", "in.wav" });
    try std.testing.expectEqualStrings("in.wav", vc.vad.wav_in.?);
    const vl = try parseArgs(&.{ "voices", "list" });
    try std.testing.expect(vl.voices == .list);
    const ve = try parseArgs(&.{ "voices", "enroll-synthetic", "id1", "My Voice", "--language", "kq" });
    try std.testing.expectEqualStrings("id1", ve.voices.enroll_synthetic.id);
    try std.testing.expectEqualStrings("kq", ve.voices.enroll_synthetic.language);
    const vd = try parseArgs(&.{ "voices", "delete", "id1" });
    try std.testing.expectEqualStrings("id1", vd.voices.delete.id);
    const pm = try parseArgs(&.{ "plugins", "load", "--manifest", "examples/plugins/noop/manifest.toml" });
    try std.testing.expectEqualStrings("examples/plugins/noop/manifest.toml", pm.plugins_load_manifest.path);
    const b = try parseArgs(&.{ "bench", "--iterations", "50" });
    try std.testing.expectEqual(@as(u64, 50), b.bench.iterations);
}

test "parseArgs rejects bad input" {
    try std.testing.expectError(error.Usage, parseArgs(&.{}));
    try std.testing.expectError(error.Usage, parseArgs(&.{"frobnicate"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "run", "--task", "telepathy" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "bench", "--iterations", "0" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "config", "validate" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "stream" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{"vad"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "voices", "enroll-synthetic", "only-id" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "voices", "delete" }));
}

test "listPluginFiles lists .so files in a real directory" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.so", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.so", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "x" });
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(path);
    const names = try listPluginFiles(io, alloc, path);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectError(error.FileNotFound, listPluginFiles(io, alloc, ".zig-cache/tmp/does-not-exist"));
}
