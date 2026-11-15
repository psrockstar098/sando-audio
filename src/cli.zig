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
//!   sando-audio converse [--config path] [--wav turn.wav ...] [--interrupt in.wav]
//!                     [--brain mock|http] [--brain-url url] [--brain-model name]
//!                     [--voice name] [--language en] [--cache] [--out-dir dir]
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
const brain = @import("brain.zig");
const conversation = @import("conversation.zig");
const models = @import("models.zig");
const language = @import("language.zig");
const vocabulary = @import("vocabulary.zig");
const pronunciation = @import("pronunciation.zig");
const adaptive_ear = @import("adaptive_ear.zig");
const languageforge = @import("languageforge.zig");
const evaluate = @import("evaluate.zig");
const oneapi = @import("oneapi.zig");
const server = @import("server.zig");

pub const usage =
    \\sando-audio 0.5.0 — SANDO Audio, Phase 5 (Developer Ecosystem, Production & Applications)
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
    \\  sando-audio converse [--config path] [--wav turn.wav ...] [--interrupt in.wav]
    \\                   [--brain mock|http] [--brain-url url] [--brain-model name]
    \\                   [--voice name] [--language en] [--cache] [--out-dir dir]
    \\  sando-audio talk <text> [--language en] [--voice name] [--correct wrong=right ...]
    \\  sando-audio language list
    \\  sando-audio language identify <text> [--data-dir dir]
    \\  sando-audio language vocab <word> [--language kq] --data-dir dir
    \\  sando-audio language pronounce <word> [--language kq] --data-dir dir
    \\  sando-audio language route <text>
    \\  sando-audio language evaluate [--data-dir dir] [--limit n]
    \\  sando-audio languageforge validate <file>
    \\  sando-audio voices list
    \\  sando-audio voices enroll-synthetic <id> <name> [--language en]
    \\  sando-audio voices delete <id>
    \\  sando-audio bench [--config path] [--model name] [--task asr|tts]
    \\                    [--iterations n] [--text "..."]
    \\  sando-audio models list [--config path]
    \\  sando-audio models install <path> [--name n] [--kind stt|tts|vad] [--config path]
    \\  sando-audio models remove <name> [--config path]
    \\  sando-audio serve [--config path] [--host 127.0.0.1] [--port 8080]
    \\                   [--max-sessions 32] [--data-dir dir]
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

/// Options for `serve` (the OneAPI REST server, Phase 5).
pub const ServeOpts = struct {
    config_path: []const u8 = engine.default_config_path,
    host: []const u8 = "127.0.0.1",
    port: u16 = server.default_port,
    max_sessions: usize = server.default_max_sessions,
    data_dir: ?[]const u8 = null,
};

/// Which brain answers a `converse` turn. `mock` is the scripted
/// local brain; `http` posts to an OpenAI-compatible endpoint
/// (local/unauthenticated only — no Authorization header is sent,
/// so no key is ever needed or used).
pub const ConverseBrain = enum { mock, http };

pub const ConverseOpts = struct {
    config_path: []const u8 = engine.default_config_path,
    /// One turn file per entry, in order. Repeatable --wav.
    wavs: []const []const u8 = &.{},
    /// Spoken interruption: transcribed on the first poll during a
    /// reply (barge-in). If never consumed, runs as a final turn.
    interrupt_wav: ?[]const u8 = null,
    brain: ConverseBrain = .mock,
    brain_url: []const u8 = "http://127.0.0.1:11434/v1/chat/completions",
    brain_model: []const u8 = "local",
    voice: []const u8 = "v1",
    language: []const u8 = "en",
    cache: bool = false,
    /// Where spoken TTS audio is written (turn<N>-sent<M>.wav).
    out_dir: []const u8 = "converse-out",
};

/// Language commands (Phase 4, Polyglot / NativeTongue).
pub const LanguageOpts = union(enum) {
    list,
    identify: struct { text: []const u8, data_dir: ?[]const u8 },
    vocab: struct { word: []const u8, language: []const u8, data_dir: ?[]const u8 },
    pronounce: struct { word: []const u8, language: []const u8, data_dir: ?[]const u8 },
    route: struct { text: []const u8 },
    evaluate: struct { data_dir: ?[]const u8, limit: usize },
};

/// Text-only conversation (Phase 4, Polyglot demo): one mock-brain
/// turn over text, no audio, no weights. `correct` holds
/// "wrong=right" pairs for the AdaptiveEar correction lexicon.
pub const TalkOpts = struct {
    text: []const u8,
    language: []const u8 = "en",
    voice: []const u8 = "v1",
    correct: []const []const u8 = &.{},
};

pub const ModelsInstallOpts = struct {
    path: []const u8,
    name: ?[]const u8,
    kind: []const u8,
    config_path: []const u8,
};

pub const ModelsRemoveOpts = struct {
    name: []const u8,
    config_path: []const u8,
};

pub const Command = union(enum) {
    version,
    doctor,
    help,
    config_validate: struct { path: []const u8 },
    run: RunOpts,
    stream: StreamOpts,
    vad: VadOpts,
    converse: ConverseOpts,
    talk: TalkOpts,
    language: LanguageOpts,
    languageforge_validate: struct { path: []const u8 },
    voices: VoicesOpts,
    bench: BenchOpts,
    models_list: struct { config_path: []const u8 },
    models_install: ModelsInstallOpts,
    models_remove: ModelsRemoveOpts,
    serve: ServeOpts,
    plugins_list: struct { dir: []const u8 },
    plugins_load: struct { path: []const u8 },
    plugins_load_manifest: struct { path: []const u8 },
};

pub const ParseError = error{ Usage, OutOfMemory };

/// Parse argv (without argv[0]) into a Command. Pure — no I/O, but
/// takes an allocator for the repeatable --wav list of `converse`.
pub fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8) ParseError!Command {
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
        if (args.len >= 3 and std.mem.eql(u8, args[1], "install")) {
            var name: ?[]const u8 = null;
            var kind: []const u8 = "stt";
            var path: []const u8 = engine.default_config_path;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (i + 1 < args.len and std.mem.eql(u8, args[i], "--name")) {
                    name = args[i + 1];
                    i += 1;
                } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--kind")) {
                    kind = args[i + 1];
                    i += 1;
                } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--config")) {
                    path = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .models_install = .{ .path = args[2], .name = name, .kind = kind, .config_path = path } };
        }
        if (args.len >= 3 and std.mem.eql(u8, args[1], "remove")) {
            var path: []const u8 = engine.default_config_path;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (i + 1 < args.len and std.mem.eql(u8, args[i], "--config")) {
                    path = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .models_remove = .{ .name = args[2], .config_path = path } };
        }
        return error.Usage;
    }

    if (std.mem.eql(u8, cmd, "serve")) {
        var opts = ServeOpts{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (i + 1 < args.len and std.mem.eql(u8, a, "--config")) {
                opts.config_path = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--host")) {
                opts.host = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--port")) {
                opts.port = std.fmt.parseInt(u16, args[i + 1], 10) catch return error.Usage;
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--max-sessions")) {
                opts.max_sessions = std.fmt.parseInt(usize, args[i + 1], 10) catch return error.Usage;
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--data-dir")) {
                opts.data_dir = args[i + 1];
                i += 1;
            } else return error.Usage;
        }
        return .{ .serve = opts };
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

    if (std.mem.eql(u8, cmd, "converse")) {
        var opts = ConverseOpts{};
        var wavs = std.ArrayList([]const u8).empty;
        errdefer wavs.deinit(alloc); // error paths (bad --brain, etc.) must not leak the list
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (i + 1 < args.len and std.mem.eql(u8, a, "--config")) {
                opts.config_path = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--wav")) {
                try wavs.append(alloc, args[i + 1]);
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--interrupt")) {
                opts.interrupt_wav = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--brain")) {
                const b = args[i + 1];
                if (std.mem.eql(u8, b, "mock")) opts.brain = .mock else if (std.mem.eql(u8, b, "http")) opts.brain = .http else return error.Usage;
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--brain-url")) {
                opts.brain_url = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--brain-model")) {
                opts.brain_model = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--voice")) {
                opts.voice = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--language")) {
                opts.language = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, a, "--cache")) {
                opts.cache = true;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--out-dir")) {
                opts.out_dir = args[i + 1];
                i += 1;
            } else return error.Usage;
        }
        if (wavs.items.len == 0) return error.Usage;
        opts.wavs = try wavs.toOwnedSlice(alloc);
        return .{ .converse = opts };
    }

    if (std.mem.eql(u8, cmd, "language")) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "list")) {
            return .{ .language = .list };
        }
        if (args.len >= 3 and std.mem.eql(u8, args[1], "identify")) {
            var data_dir: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (i + 1 < args.len and std.mem.eql(u8, args[i], "--data-dir")) {
                    data_dir = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .language = .{ .identify = .{ .text = args[2], .data_dir = data_dir } } };
        }
        if (args.len >= 3 and std.mem.eql(u8, args[1], "vocab")) {
            var lang: []const u8 = "kq";
            var data_dir: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (i + 1 < args.len and std.mem.eql(u8, args[i], "--language")) {
                    lang = args[i + 1];
                    i += 1;
                } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--data-dir")) {
                    data_dir = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .language = .{ .vocab = .{ .word = args[2], .language = lang, .data_dir = data_dir } } };
        }
        if (args.len >= 3 and std.mem.eql(u8, args[1], "pronounce")) {
            var lang: []const u8 = "kq";
            var data_dir: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (i + 1 < args.len and std.mem.eql(u8, args[i], "--language")) {
                    lang = args[i + 1];
                    i += 1;
                } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--data-dir")) {
                    data_dir = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .language = .{ .pronounce = .{ .word = args[2], .language = lang, .data_dir = data_dir } } };
        }
        if (args.len == 3 and std.mem.eql(u8, args[1], "route")) {
            return .{ .language = .{ .route = .{ .text = args[2] } } };
        }
        if (args.len >= 2 and std.mem.eql(u8, args[1], "evaluate")) {
            var data_dir: ?[]const u8 = null;
            var limit: usize = 50;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (i + 1 < args.len and std.mem.eql(u8, args[i], "--data-dir")) {
                    data_dir = args[i + 1];
                    i += 1;
                } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--limit")) {
                    limit = std.fmt.parseInt(usize, args[i + 1], 10) catch return error.Usage;
                    if (limit == 0) return error.Usage;
                    i += 1;
                } else return error.Usage;
            }
            return .{ .language = .{ .evaluate = .{ .data_dir = data_dir, .limit = limit } } };
        }
        return error.Usage;
    }

    if (std.mem.eql(u8, cmd, "languageforge")) {
        if (args.len == 3 and std.mem.eql(u8, args[1], "validate")) {
            return .{ .languageforge_validate = .{ .path = args[2] } };
        }
        return error.Usage;
    }

    if (std.mem.eql(u8, cmd, "talk")) {
        if (args.len < 2) return error.Usage;
        var opts = TalkOpts{ .text = args[1] };
        var correct = std.ArrayList([]const u8).empty;
        errdefer correct.deinit(alloc);
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (i + 1 < args.len and std.mem.eql(u8, a, "--language")) {
                opts.language = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--voice")) {
                opts.voice = args[i + 1];
                i += 1;
            } else if (i + 1 < args.len and std.mem.eql(u8, a, "--correct")) {
                try correct.append(alloc, args[i + 1]);
                i += 1;
            } else return error.Usage;
        }
        opts.correct = try correct.toOwnedSlice(alloc);
        return .{ .talk = opts };
    }

    if (std.mem.eql(u8, cmd, "voices")) {
        if (args.len >= 2 and std.mem.eql(u8, args[1], "list")) {
            if (args.len != 2) return error.Usage;
            return .{ .voices = .list };
        }
        if (args.len >= 2 and std.mem.eql(u8, args[1], "enroll-synthetic")) {
            if (args.len < 4) return error.Usage;
            var lang: []const u8 = "en";
            var i: usize = 4;
            while (i < args.len) : (i += 1) {
                if (i + 1 < args.len and std.mem.eql(u8, args[i], "--language")) {
                    lang = args[i + 1];
                    i += 1;
                } else return error.Usage;
            }
            return .{ .voices = .{ .enroll_synthetic = .{ .id = args[2], .name = args[3], .language = lang } } };
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

    const cmd = parseArgs(alloc, argv.items) catch {
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
        .converse => |opts| return cmdConverse(alloc, io, out, opts),
        .talk => |opts| return cmdTalk(alloc, io, out, opts),
        .language => |opts| return cmdLanguage(alloc, io, out, opts),
        .languageforge_validate => |v| return cmdLanguageForgeValidate(alloc, io, out, v.path),
        .voices => |opts| return cmdVoices(alloc, io, out, opts),
        .bench => |opts| return cmdBench(alloc, io, out, opts),
        .models_install => |opts| return cmdModelsInstall(alloc, io, out, opts),
        .models_remove => |opts| return cmdModelsRemove(alloc, io, out, opts),
        .serve => |opts| return cmdServe(alloc, io, out, opts),
    }
}

/// Install a model file into models/ (see models.installModel).
fn cmdModelsInstall(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: ModelsInstallOpts) !u8 {
    var eng = loadEngine(alloc, io, opts.config_path) catch |err| {
        std.debug.print("cannot start engine from {s} ({t})\n", .{ opts.config_path, err });
        return 1;
    };
    defer eng.deinit();
    const kind = config.ModelKind.fromName(opts.kind) orelse {
        std.debug.print("kind must be one of stt, tts, vad\n", .{});
        return 2;
    };
    const name = opts.name orelse std.Io.Dir.path.basename(opts.path);
    const rec = models.installModel(alloc, io, &eng.registry, opts.path, name, kind, "models") catch |err| {
        std.debug.print("cannot install {s} ({t})\n", .{ opts.path, err });
        return 1;
    };
    try out.print("installed {s} [{s}] {s} ({d} bytes, sha256 in models/{s}.json)\n", .{ rec.name, @tagName(rec.kind), rec.path, rec.size_bytes, rec.name });
    try out.flush();
    return 0;
}

/// Remove a model from the registry and delete its file + manifest.
fn cmdModelsRemove(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: ModelsRemoveOpts) !u8 {
    var eng = loadEngine(alloc, io, opts.config_path) catch |err| {
        std.debug.print("cannot start engine from {s} ({t})\n", .{ opts.config_path, err });
        return 1;
    };
    defer eng.deinit();
    models.removeModel(alloc, io, &eng.registry, opts.name, "models") catch |err| {
        std.debug.print("cannot remove {s} ({t})\n", .{ opts.name, err });
        return 1;
    };
    try out.print("removed {s}\n", .{opts.name});
    try out.flush();
    return 0;
}

/// Start the OneAPI REST server. Runs until killed (Ctrl-C).
fn cmdServe(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: ServeOpts) !u8 {
    var eng = loadEngine(alloc, io, opts.config_path) catch |err| {
        std.debug.print("cannot start engine from {s} ({t})\n", .{ opts.config_path, err });
        return 1;
    };
    errdefer eng.deinit();
    var vocab: ?vocabulary.Vocabulary = null;
    if (opts.data_dir) |dir| {
        vocab = loadVocabulary(alloc, io, dir) catch |err| {
            std.debug.print("cannot load dataset from {s} ({t})\n", .{ dir, err });
            return 1;
        };
        try out.print("(dataset: {d} language(s) loaded)\n", .{vocab.?.languageCount()});
    }
    const api_key = oneapi.readApiKey();
    if (api_key == null) {
        try out.print("WARNING: no SANDO_API_KEY set — the server is in OPEN DEV MODE (anyone on this machine can call it)\n", .{});
    }
    if (std.mem.eql(u8, opts.host, "0.0.0.0")) {
        try out.print("WARNING: listening on 0.0.0.0 — the server is reachable from the network\n", .{});
    }
    var srv = server.Server.init(alloc, io, .{
        .host = opts.host,
        .port = opts.port,
        .max_sessions = opts.max_sessions,
        .config_path = opts.config_path,
        .api_key = api_key,
    }, eng, vocab) catch |err| {
        std.debug.print("cannot listen on {s}:{d} ({t})\n", .{ opts.host, opts.port, err });
        return 1;
    };
    defer srv.deinit();
    try out.print("sando-audio {s} listening on http://{s}:{d} (OneAPI, {d} max sessions)\n", .{
        root.version, opts.host, srv.boundPort(), opts.max_sessions,
    });
    try out.flush();
    srv.run();
    return 0;
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

/// Free memory (bytes) from /proc/meminfo, or null when unreadable
/// (non-Linux, or /proc not mounted). The TTS size guard uses it.
/// Load the TTS model only when it fits in free memory. Returns null
/// (with a plain message) when there is no room — the TTS leg is
/// then skipped honestly instead of OOMing the machine.
fn loadTtsIfFits(
    alloc: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    eng: *engine.Engine,
    tts_model: *const config.ModelEntry,
) !?runtime.Session {
    const size = models.fileSize(io, tts_model.file) catch 0;
    if (oneapi.memAvailableBytes(alloc, io)) |free| {
        if (size > free) {
            try out.print("tts skipped: model {s} is {d} MB but only {d} MB is free — this machine cannot load it\n", .{ tts_model.name, size >> 20, free >> 20 });
            return null;
        }
    } else {
        try out.print("tts: /proc/meminfo unavailable, loading without a size guard\n", .{});
    }
    eng.loadModelsForTask(.tts) catch |err| {
        std.debug.print("cannot load tts model {s} ({t}) — tts leg skipped\n", .{ eng.last_error_model orelse "?", err });
        return null;
    };
    return eng.createSession(tts_model.name, .tts, .offline) catch |err| {
        std.debug.print("cannot create tts session for {s} ({t}) — tts leg skipped\n", .{ tts_model.name, err });
        return null;
    };
}

/// The spoken interruption for a `converse` run. The first poll
/// transcribes the interrupt WAV through the ASR session; later
/// polls return null. `delivered` tells the caller whether the
/// interruption actually fired, so an unconsumed one can run as a
/// final normal turn instead.
const InterruptCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    samples: []const f32,
    sample_rate: u32,
    channels: u8,
    language: []const u8,
    asr: ?*runtime.Session = null,
    polled: bool = false,
    delivered: bool = false,
    transcript: ?[]const u8 = null,

    fn deinit(self: *InterruptCtx) void {
        if (self.transcript) |t| self.alloc.free(t);
    }

    fn poll(ctx: *anyopaque) ?[]const u8 {
        const c: *@This() = @ptrCast(@alignCast(ctx));
        if (c.polled) return null;
        c.polled = true;
        const asr = c.asr orelse return null;
        const req = runtime.Request{
            .task = .asr,
            .mode = .offline,
            .audio = c.samples,
            .sample_rate = c.sample_rate,
            .channels = c.channels,
            .language = c.language,
        };
        var resp = asr.run(c.io, c.alloc, req) catch return null;
        defer resp.deinit();
        const t = resp.text() catch return null;
        const text = std.mem.trim(u8, t.text, " \t\n\r");
        if (text.len == 0) return null;
        c.transcript = c.alloc.dupe(u8, text) catch return null;
        c.delivered = true;
        return c.transcript.?;
    }
};

/// Writes spoken TTS audio to `<out-dir>/turn<N>-sent<M>.wav`.
/// An error here is recorded by the conversation (tts_out_errors),
/// never fatal to the turn.
const TtsOutCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    turn: u32 = 0,
    sentence: u32 = 0,

    fn write(ctx: *anyopaque, sentence_text: []const u8, samples: []const f32, sample_rate: u32, channels: u8) anyerror!void {
        const c: *@This() = @ptrCast(@alignCast(ctx));
        _ = sentence_text;
        std.Io.Dir.cwd().createDirPath(c.io, c.out_dir) catch {};
        const path = try std.fmt.allocPrint(c.alloc, "{s}/turn{d}-sent{d}.wav", .{ c.out_dir, c.turn, c.sentence });
        defer c.alloc.free(path);
        try audio.writeWavFile(c.io, path, samples, sample_rate, channels, .pcm16);
        c.sentence += 1;
    }
};

/// One turn of a conversation: prints the "Sando: " prefix, then
/// the brain's reply streams live through the echo while
/// `processAudio` runs, then the transcript and leg summary.
fn runConverseTurn(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    conv: *conversation.Conversation,
    tts_ctx: *TtsOutCtx,
    samples: []const f32,
    sample_rate: u32,
    channels: u8,
    turn_no: usize,
) !void {
    tts_ctx.turn = @intCast(turn_no);
    tts_ctx.sentence = 0;
    try out.print("--- turn {d} ---\nSando: ", .{turn_no});
    try out.flush();
    var result = try conv.processAudio(samples, sample_rate, channels);
    defer result.deinit(alloc);
    try out.print("\n  you said: \"{s}\"\n", .{result.transcript});
    // Phase 4 (AdaptiveEar): what language was heard, and which ASR
    // route that implies. Marker-only identification (no dataset
    // load mid-turn) — the route is a decision, not a model.
    if (language.identify(alloc, result.transcript, null)) |id| {
        const route = adaptive_ear.routeFor(id.language);
        const rep = adaptive_ear.report(alloc, &route) catch null;
        if (rep) |r| {
            defer alloc.free(r);
            try out.print("  {s} (confidence {d:.2}, {d}/{d} tokens scored)\n", .{ r, id.confidence, id.scored, id.tokens });
        }
    } else |_| {}
    if (result.partial_reply) |p| try out.print("  reply cut short at: \"{s}\"\n", .{p});
    if (result.interrupt_text) |t| try out.print("  interrupted by: \"{s}\"\n", .{t});
    try out.print("  legs: asr={s} brain={s} tts={s} (spoken {d}, cached {d}, skipped {d}, tts errors {d})\n", .{
        @tagName(result.asr),
        @tagName(result.brain),
        @tagName(result.tts),
        result.sentences_spoken,
        result.sentences_from_cache,
        result.sentences_skipped,
        result.tts_out_errors,
    });
    try out.print("  barge-in: {s}\n", .{if (result.barged_in) "yes" else "no"});
    try out.flush();
}

/// Speech-to-brain-to-speech over WAV files: each --wav is VAD
/// segmented (energy fallback, labelled), segments are grouped into
/// turns on silence gaps via the ReflexEngine turn-end probability,
/// and each turn runs ASR -> brain -> TTS through `Conversation`.
/// The brain streams live; TTS audio lands in --out-dir. With
/// --cache, repeat ASR/TTS legs are served from the SmartCache.
fn cmdConverse(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: ConverseOpts) !u8 {
    var eng = loadEngine(alloc, io, opts.config_path) catch |err| {
        std.debug.print("cannot start engine from {s} ({t})\n", .{ opts.config_path, err });
        return 1;
    };
    defer eng.deinit();

    // ASR is the input leg: without it there is nothing to converse
    // about, so a failure here is fatal (unlike TTS below).
    eng.loadModelsForTask(.asr) catch |err| {
        std.debug.print("cannot load asr model {s} ({t})\n", .{ eng.last_error_model orelse "?", err });
        return 1;
    };
    const asr_model = pickModel(&eng.cfg, null, .asr) orelse {
        std.debug.print("no asr model in {s}\n", .{opts.config_path});
        return 1;
    };
    var asr_session = eng.createSession(asr_model.name, .asr, .offline) catch |err| {
        std.debug.print("cannot create asr session for {s} ({t})\n", .{ asr_model.name, err });
        return 1;
    };
    defer asr_session.deinit(alloc);

    // TTS is the output leg, but optional: a model too big for this
    // machine's free RAM is skipped honestly, never loaded.
    var tts_session: ?runtime.Session = null;
    defer if (tts_session) |*s| s.deinit(alloc);
    if (pickModel(&eng.cfg, null, .tts)) |tts_model| {
        tts_session = try loadTtsIfFits(alloc, io, out, &eng, tts_model);
    } else {
        try out.print("tts skipped: no tts model in {s}\n", .{opts.config_path});
    }

    var mock = brain.MockBrain{};
    var http_sender = brain.StdHttpSender{};
    var http_brain = brain.HttpBrain.init(opts.brain_url, opts.brain_model, http_sender.asSender());
    const brain_value: brain.Brain = switch (opts.brain) {
        .mock => mock.asBrain(),
        .http => http_brain.asBrain(),
    };
    if (opts.brain == .http) {
        try out.print("brain: http {s} model {s} (local/unauthenticated only, no key)\n", .{ opts.brain_url, opts.brain_model });
    }

    var smart_cache = cache.SmartCache.init(alloc, 64 << 20);
    defer smart_cache.deinit();

    var interrupt_wav: ?audio.WavData = null;
    defer if (interrupt_wav) |*w| w.deinit(alloc);
    var interrupt_ctx: ?InterruptCtx = null;
    defer if (interrupt_ctx) |*c| c.deinit();
    if (opts.interrupt_wav) |path| {
        const w = audio.readWavFile(alloc, io, path) catch |err| {
            std.debug.print("cannot read interrupt wav {s} ({t})\n", .{ path, err });
            return 1;
        };
        interrupt_wav = w;
        interrupt_ctx = InterruptCtx{
            .alloc = alloc,
            .io = io,
            .samples = w.samples,
            .sample_rate = w.sample_rate,
            .channels = w.channels,
            .language = opts.language,
            .asr = &asr_session,
        };
    }

    var conv = conversation.Conversation.init(alloc, io, brain_value, opts.voice, opts.language) catch |err| {
        std.debug.print("cannot start conversation ({t})\n", .{err});
        return 1;
    };
    defer conv.deinit();
    // Operator persona override from the config; otherwise the
    // built-in Sando persona (persona.zig) is the default.
    if (eng.cfg.persona_prompt) |p| conv.session.system_prompt = p;
    conv.asr = &asr_session;
    if (tts_session) |*s| conv.tts = s;
    if (opts.cache) conv.cache = &smart_cache;
    conv.echo = out;
    if (interrupt_ctx) |*c| {
        conv.interrupt_fn = InterruptCtx.poll;
        conv.interrupt_ctx = c;
    }
    var tts_ctx = TtsOutCtx{ .alloc = alloc, .io = io, .out_dir = opts.out_dir };
    conv.on_tts_audio = TtsOutCtx.write;
    conv.tts_audio_ctx = &tts_ctx;

    var turn_no: usize = 0;
    for (opts.wavs) |path| {
        var wav = audio.readWavFile(alloc, io, path) catch |err| {
            std.debug.print("cannot read {s} ({t})\n", .{ path, err });
            return 1;
        };
        defer wav.deinit(alloc);
        try out.print("input: {s} ({d} samples @ {d} Hz, {d} ch)\n", .{ path, wav.samples.len, wav.sample_rate, wav.channels });

        var energy = vad.EnergyVad.init(wav.sample_rate);
        var tracker = vad.VadTracker.init(alloc, wav.sample_rate);
        defer tracker.deinit();
        var offset: usize = 0;
        const chunk_frames = wav.sample_rate / 10; // 100 ms chunks
        while (offset < wav.samples.len) {
            const end = @min(offset + chunk_frames * @as(usize, wav.channels), wav.samples.len);
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
        try out.print("vad: energy fallback, {d} speech segment(s)\n", .{tracker.segmentCount()});
        if (tracker.segmentCount() == 0) {
            try out.print("no speech detected in {s} — skipped\n", .{path});
            try out.flush();
            continue;
        }

        // Group segments into turns on silence gaps, using the
        // ReflexEngine turn-end probability (silence-driven here:
        // there is no partial transcript yet at grouping time).
        var pending = std.ArrayList(f32).empty;
        defer pending.deinit(alloc);
        const segs = tracker.segments.items;
        for (segs, 0..) |seg, si| {
            const s0 = @as(usize, @intCast(seg.start_sample)) * @as(usize, wav.channels);
            const s1 = @as(usize, @intCast(seg.end_sample)) * @as(usize, wav.channels);
            try pending.appendSlice(alloc, wav.samples[s0..@min(s1, wav.samples.len)]);
            const is_last = si == segs.len - 1;
            const silence_ms: u32 = if (is_last) 10_000 else blk: {
                const gap_frames = segs[si + 1].start_sample - seg.end_sample;
                break :blk @intCast(@divFloor(gap_frames * 1000, @as(i64, wav.sample_rate)));
            };
            const reply_now = is_last or conv.shouldReply(silence_ms, tracker.silence_ms, "", false);
            if (reply_now) {
                turn_no += 1;
                try runConverseTurn(alloc, out, &conv, &tts_ctx, pending.items, wav.sample_rate, wav.channels, turn_no);
                pending.clearRetainingCapacity();
            }
        }
        if (pending.items.len > 0) {
            turn_no += 1;
            try runConverseTurn(alloc, out, &conv, &tts_ctx, pending.items, wav.sample_rate, wav.channels, turn_no);
            pending.clearRetainingCapacity();
        }
    }

    // An interruption that never fired during a reply (e.g. the
    // reply had no spoken sentences to poll after) still gets heard:
    // it runs as a final normal turn.
    if (interrupt_ctx) |*c| {
        if (!c.delivered) {
            if (interrupt_wav) |w| {
                turn_no += 1;
                try out.print("interrupt was not consumed during a reply — running as a final turn\n", .{});
                try runConverseTurn(alloc, out, &conv, &tts_ctx, w.samples, w.sample_rate, w.channels, turn_no);
            }
        }
    }

    try out.print("converse done: {d} turn(s), {d} barge-in(s), {d} history turn(s)\n", .{
        turn_no,
        conv.stats.barge_ins,
        conv.session.history.items.len,
    });
    try out.flush();
    return 0;
}

/// Load every registry language that has a dataset file in
/// `dir`. Missing files are skipped (the directory may hold only
/// some languages); a missing directory is an error.
fn loadVocabulary(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) !vocabulary.Vocabulary {
    var dir_handle = std.Io.Dir.cwd().openDir(io, dir, .{}) catch {
        std.debug.print("no dataset directory at {s}\n", .{dir});
        return error.FileNotFound;
    };
    dir_handle.close(io);
    var vocab = vocabulary.Vocabulary.init(alloc);
    errdefer vocab.deinit();
    for (&language.registry) |l| {
        const file = l.dataset_file orelse continue;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, file });
        defer alloc.free(path);
        vocab.load(io, l.code, path) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
    }
    return vocab;
}

/// Phase 4 language commands: list / identify / vocab /
/// pronounce / route / evaluate.
fn cmdLanguage(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: LanguageOpts) !u8 {
    switch (opts) {
        .list => {
            for (&language.registry) |l| {
                try out.print("  {s}  {s}  [{s}]  script={s}  asr={s}  tts={s}\n", .{
                    l.code,
                    l.name,
                    @tagName(l.status),
                    l.script,
                    l.asr_model orelse "none",
                    if (l.tts_available) "yes" else "no",
                });
            }
            try out.flush();
            return 0;
        },
        .identify => |o| {
            var vocab: ?vocabulary.Vocabulary = null;
            defer if (vocab) |*v| v.deinit();
            if (o.data_dir) |dir| {
                vocab = loadVocabulary(alloc, io, dir) catch |err| {
                    std.debug.print("cannot load dataset from {s} ({t})\n", .{ dir, err });
                    return 1;
                };
                try out.print("(dataset: {d} language(s) loaded)\n", .{vocab.?.languageCount()});
            } else {
                try out.print("(dataset not loaded — pass --data-dir <path> for wordlist-backed identification)\n", .{});
            }
            const vptr: ?*const vocabulary.Vocabulary = if (vocab) |*v| v else null;
            const id = try language.identify(alloc, o.text, vptr);
            const lang = language.find(id.language);
            try out.print("language: {s} ({s})\n", .{ id.language, if (lang) |l| l.name else "Unknown" });
            try out.print("confidence: {d:.2} ({d}/{d} tokens scored)\n", .{ id.confidence, id.scored, id.tokens });
            try out.print("scores:", .{});
            for (&language.registry, 0..) |l, i| {
                if (id.scores[i] > 0) try out.print(" {s} {d:.1}", .{ l.code, id.scores[i] });
            }
            try out.print("\n", .{});
            try out.flush();
            return 0;
        },
        .vocab => |o| {
            const dir = o.data_dir orelse {
                std.debug.print("vocab needs --data-dir <path> to the dataset directory\n", .{});
                return 2;
            };
            const code = language.normalizeCode(o.language) orelse {
                std.debug.print("unknown language {s}\n", .{o.language});
                return 2;
            };
            var vocab = loadVocabulary(alloc, io, dir) catch |err| {
                std.debug.print("cannot load dataset from {s} ({t})\n", .{ dir, err });
                return 1;
            };
            defer vocab.deinit();
            const ds = vocab.dataset(code) orelse {
                std.debug.print("no dataset for {s} in {s}\n", .{ code, dir });
                return 1;
            };
            const hits = try ds.lookup(alloc, o.word, 8);
            defer alloc.free(hits);
            if (hits.len == 0) {
                try out.print("no entry for \"{s}\" in {s}\n", .{ o.word, code });
                try out.flush();
                return 0;
            }
            for (hits) |h| {
                try out.print("  \"{s}\" [{s}] = \"{s}\"  ({s}, {s})\n", .{
                    h.entry.response,
                    h.side,
                    if (h.entry.input.len > 0) h.entry.input else h.entry.standard_english,
                    h.entry.id,
                    h.entry.source,
                });
            }
            try out.flush();
            return 0;
        },
        .pronounce => |o| {
            const dir = o.data_dir orelse {
                std.debug.print("pronounce needs --data-dir <path> to the dataset directory\n", .{});
                return 2;
            };
            const code = language.normalizeCode(o.language) orelse {
                std.debug.print("unknown language {s}\n", .{o.language});
                return 2;
            };
            var vocab = loadVocabulary(alloc, io, dir) catch |err| {
                std.debug.print("cannot load dataset from {s} ({t})\n", .{ dir, err });
                return 1;
            };
            defer vocab.deinit();
            const ds = vocab.dataset(code) orelse {
                std.debug.print("no dataset for {s} in {s}\n", .{ code, dir });
                return 1;
            };
            const p = (try pronunciation.lookup(alloc, ds, o.word)) orelse {
                try out.print("no pronunciation for \"{s}\" in {s} — the dataset has no such word\n", .{ o.word, code });
                try out.flush();
                return 0;
            };
            defer {
                for (p.syllables) |s| alloc.free(s);
                alloc.free(p.syllables);
            }
            try out.print("{s} -> {s}  (syllables: ", .{ p.word, p.attested_form });
            for (p.syllables, 0..) |s, i| {
                if (i > 0) try out.print("-", .{});
                try out.print("{s}", .{s});
            }
            try out.print(", heuristic)  \"{s}\"  ({s}, {s})\n", .{ p.meaning, p.id, p.source });
            try out.flush();
            return 0;
        },
        .route => |o| {
            const id = try language.identify(alloc, o.text, null);
            const route = adaptive_ear.routeFor(id.language);
            const rep = try adaptive_ear.report(alloc, &route);
            defer alloc.free(rep);
            try out.print("{s} (confidence {d:.2})\n", .{ rep, id.confidence });
            try out.flush();
            return 0;
        },
        .evaluate => |o| {
            const dir = o.data_dir orelse {
                std.debug.print("evaluate needs --data-dir <path> to the dataset directory\n", .{});
                return 2;
            };
            var vocab = loadVocabulary(alloc, io, dir) catch |err| {
                std.debug.print("cannot load dataset from {s} ({t})\n", .{ dir, err });
                return 1;
            };
            defer vocab.deinit();
            try out.print("dataset: {d} language(s) loaded, limit {d} per language\n", .{ vocab.languageCount(), o.limit });
            const ident = try evaluate.evaluateIdentification(alloc, &vocab, o.limit);
            defer alloc.free(ident.per_language);
            const cs = try evaluate.evaluateCodeSwitch(alloc, &vocab, o.limit);
            try evaluate.printReport(out, &ident, &cs);
            try out.flush();
            return 0;
        },
    }
}

/// Validate a LanguageForge contribution JSON file. Exit 0 when
/// valid, 1 with the problems listed when not.
fn cmdLanguageForgeValidate(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, path: []const u8) !u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch |err| {
        std.debug.print("cannot read {s} ({t})\n", .{ path, err });
        return 1;
    };
    defer alloc.free(bytes);
    var c = languageforge.parse(alloc, bytes) catch |err| {
        std.debug.print("invalid contribution JSON in {s} ({t})\n", .{ path, err });
        return 1;
    };
    defer languageforge.freeContribution(alloc, &c);
    const problems = try c.validate(alloc);
    defer alloc.free(problems);
    if (problems.len == 0) {
        try out.print("valid contribution: {s} [{s}] \"{s}\" speaker {s}\n", .{ c.id, c.language, c.transcript, c.speaker_id });
        try out.flush();
        return 0;
    }
    try out.print("invalid contribution: {d} problem(s)\n", .{problems.len});
    for (problems) |p| {
        try out.print("  {s}: {s}\n", .{ p.field, p.message });
    }
    try out.flush();
    return 1;
}

/// Text-only Polyglot conversation: one mock-brain turn over
/// text. No audio, no weights. Prints the reply, the detected
/// language of the input, and the AdaptiveEar route.
fn cmdTalk(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, opts: TalkOpts) !u8 {
    const code = language.normalizeCode(opts.language) orelse {
        std.debug.print("unknown language {s}\n", .{opts.language});
        return 2;
    };
    // AdaptiveEar corrections first: the brain hears the corrected
    // text, as it would a corrected transcript.
    var lex = adaptive_ear.CorrectionLexicon.init(alloc);
    defer lex.deinit();
    for (opts.correct) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            std.debug.print("--correct needs wrong=right, got \"{s}\"\n", .{pair});
            return 2;
        };
        try lex.add(pair[0..eq], pair[eq + 1 ..]);
    }
    const fixed = try lex.apply(alloc, opts.text);
    defer alloc.free(fixed.text);
    if (fixed.corrected > 0) {
        try out.print("corrected: {d} word(s) -> \"{s}\"\n", .{ fixed.corrected, fixed.text });
    }

    const id = try language.identify(alloc, fixed.text, null);
    const route = adaptive_ear.routeFor(id.language);
    const rep = try adaptive_ear.report(alloc, &route);
    defer alloc.free(rep);
    try out.print("{s} (confidence {d:.2})\n", .{ rep, id.confidence });

    var mock = brain.MockBrain{};
    var conv = conversation.Conversation.init(alloc, io, mock.asBrain(), opts.voice, code) catch |err| {
        std.debug.print("cannot start conversation ({t})\n", .{err});
        return 1;
    };
    defer conv.deinit();
    var result = try conv.processText(fixed.text);
    defer result.deinit(alloc);
    try out.print("Sando: {s}\n", .{result.reply});
    if (std.mem.eql(u8, code, "kq") and std.mem.eql(u8, result.reply, brain.MockBrain.default_reply_text)) {
        try out.print("note: the mock brain answers from scripted replies — its Koloqua is verbatim dataset sentences only (see brain.zig).\n", .{});
    }
    try out.print("legs: brain={s} tts={s} (spoken {d}, skipped {d})\n", .{
        @tagName(result.brain),
        @tagName(result.tts),
        result.sentences_spoken,
        result.sentences_skipped,
    });
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
    const alloc = std.testing.allocator;
    const v = try parseArgs(alloc, &.{"version"});
    try std.testing.expect(v == .version);
    const d = try parseArgs(alloc, &.{"doctor"});
    try std.testing.expect(d == .doctor);
    const cv = try parseArgs(alloc, &.{ "config", "validate", "config/sando.toml" });
    try std.testing.expect(std.mem.eql(u8, cv.config_validate.path, "config/sando.toml"));
    const r = try parseArgs(alloc, &.{ "run", "--task", "tts", "--text", "hello", "--mode", "streaming" });
    try std.testing.expect(r.run.task == .tts);
    try std.testing.expect(r.run.mode == .streaming);
    try std.testing.expectEqualStrings("hello", r.run.text.?);
    const rc = try parseArgs(alloc, &.{ "run", "--task", "tts", "--text", "hi", "--cache", "--voice", "v1" });
    try std.testing.expect(rc.run.cache);
    try std.testing.expectEqualStrings("v1", rc.run.voice.?);
    const s = try parseArgs(alloc, &.{ "stream", "--wav", "in.wav", "--cache" });
    try std.testing.expectEqualStrings("in.wav", s.stream.wav_in.?);
    try std.testing.expect(s.stream.cache);
    const vc = try parseArgs(alloc, &.{ "vad", "--wav", "in.wav" });
    try std.testing.expectEqualStrings("in.wav", vc.vad.wav_in.?);
    const vl = try parseArgs(alloc, &.{ "voices", "list" });
    try std.testing.expect(vl.voices == .list);
    const ve = try parseArgs(alloc, &.{ "voices", "enroll-synthetic", "id1", "My Voice", "--language", "kq" });
    try std.testing.expectEqualStrings("id1", ve.voices.enroll_synthetic.id);
    try std.testing.expectEqualStrings("kq", ve.voices.enroll_synthetic.language);
    const vd = try parseArgs(alloc, &.{ "voices", "delete", "id1" });
    try std.testing.expectEqualStrings("id1", vd.voices.delete.id);
    const pm = try parseArgs(alloc, &.{ "plugins", "load", "--manifest", "examples/plugins/noop/manifest.toml" });
    try std.testing.expectEqualStrings("examples/plugins/noop/manifest.toml", pm.plugins_load_manifest.path);
    const b = try parseArgs(alloc, &.{ "bench", "--iterations", "50" });
    try std.testing.expectEqual(@as(u64, 50), b.bench.iterations);
    const ll = try parseArgs(alloc, &.{ "language", "list" });
    try std.testing.expect(ll.language == .list);
    const li = try parseArgs(alloc, &.{ "language", "identify", "I de go.", "--data-dir", "datasets" });
    try std.testing.expectEqualStrings("I de go.", li.language.identify.text);
    try std.testing.expectEqualStrings("datasets", li.language.identify.data_dir.?);
    const lv = try parseArgs(alloc, &.{ "language", "vocab", "fini", "--language", "kq", "--data-dir", "datasets" });
    try std.testing.expectEqualStrings("fini", lv.language.vocab.word);
    try std.testing.expectEqualStrings("kq", lv.language.vocab.language);
    const lr = try parseArgs(alloc, &.{ "language", "route", "I de go." });
    try std.testing.expectEqualStrings("I de go.", lr.language.route.text);
    const le = try parseArgs(alloc, &.{ "language", "evaluate", "--data-dir", "datasets", "--limit", "10" });
    try std.testing.expectEqual(@as(usize, 10), le.language.evaluate.limit);
    const lf = try parseArgs(alloc, &.{ "languageforge", "validate", "contrib.json" });
    try std.testing.expectEqualStrings("contrib.json", lf.languageforge_validate.path);
    const tk = try parseArgs(alloc, &.{ "talk", "I de go.", "--language", "kq", "--correct", "the=de" });
    defer alloc.free(tk.talk.correct);
    try std.testing.expectEqualStrings("I de go.", tk.talk.text);
    try std.testing.expectEqualStrings("kq", tk.talk.language);
    try std.testing.expectEqual(@as(usize, 1), tk.talk.correct.len);
    try std.testing.expectEqualStrings("the=de", tk.talk.correct[0]);
}

test "parseArgs rejects bad input" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{}));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{"frobnicate"}));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "run", "--task", "telepathy" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "bench", "--iterations", "0" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "config", "validate" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{"stream"}));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{"vad"}));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "voices", "enroll-synthetic", "only-id" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "voices", "delete" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{"converse"}));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "converse", "--wav", "a.wav", "--brain", "telepathy" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{"language"}));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "language", "identify" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "language", "evaluate", "--limit", "0" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{ "languageforge", "validate" }));
    try std.testing.expectError(error.Usage, parseArgs(alloc, &.{"talk"}));
}

test "parseArgs accepts converse with repeatable --wav" {
    const alloc = std.testing.allocator;
    const c = try parseArgs(alloc, &.{
        "converse",
        "--wav",
        "a.wav",
        "--wav",
        "b.wav",
        "--interrupt",
        "i.wav",
        "--brain",
        "http",
        "--brain-url",
        "http://127.0.0.1:11434/v1/chat/completions",
        "--brain-model",
        "local",
        "--voice",
        "v1",
        "--language",
        "kq",
        "--cache",
        "--out-dir",
        "out",
    });
    defer alloc.free(c.converse.wavs);
    try std.testing.expectEqual(@as(usize, 2), c.converse.wavs.len);
    try std.testing.expectEqualStrings("a.wav", c.converse.wavs[0]);
    try std.testing.expectEqualStrings("b.wav", c.converse.wavs[1]);
    try std.testing.expectEqualStrings("i.wav", c.converse.interrupt_wav.?);
    try std.testing.expect(c.converse.brain == .http);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/chat/completions", c.converse.brain_url);
    try std.testing.expectEqualStrings("local", c.converse.brain_model);
    try std.testing.expectEqualStrings("v1", c.converse.voice);
    try std.testing.expectEqualStrings("kq", c.converse.language);
    try std.testing.expect(c.converse.cache);
    try std.testing.expectEqualStrings("out", c.converse.out_dir);

    const defaults = try parseArgs(alloc, &.{ "converse", "--wav", "only.wav" });
    defer alloc.free(defaults.converse.wavs);
    try std.testing.expect(defaults.converse.brain == .mock);
    try std.testing.expect(!defaults.converse.cache);
    try std.testing.expectEqualStrings("converse-out", defaults.converse.out_dir);
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
