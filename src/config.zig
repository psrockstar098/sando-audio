//! TOML configuration: hand-rolled parser, validated, reloadable.
//!
//! One format done well (TOML). The parser is strict: unknown sections and
//! unknown keys are errors, so `config validate` catches typos instead of
//! silently ignoring them. Values supported: double-quoted strings,
//! integers, booleans. No floats, arrays, or inline tables in Phase 1 —
//! the config schema does not need them.

const std = @import("std");

pub const ConfigError = error{
    InvalidSyntax,
    UnknownSection,
    UnknownKey,
    MissingField,
    InvalidValue,
    DuplicateModel,
    OutOfMemory,
};

pub const RuntimeMode = enum { realtime, offline };

pub const ModelKind = enum {
    stt,
    tts,
    vad,

    pub fn fromName(s: []const u8) ?ModelKind {
        if (std.mem.eql(u8, s, "stt")) return .stt;
        if (std.mem.eql(u8, s, "tts")) return .tts;
        if (std.mem.eql(u8, s, "vad")) return .vad;
        return null;
    }
};

pub const ModelEntry = struct {
    name: []const u8,
    kind: ModelKind,
    file: []const u8,
    voice: ?[]const u8 = null,
    /// Speaker reference clip for TTS families that clone a voice
    /// from audio. Qwen3-TTS Base cannot speak without one — its
    /// session throws at the first request when no reference audio
    /// is attached ("Qwen3 base TTS requires voice clone reference
    /// audio"). Path to a WAV file, relative to the working
    /// directory. Best-effort: a missing file leaves the request
    /// voiceless, exactly as before this field existed.
    reference_wav: ?[]const u8 = null,
    /// Transcript of `reference_wav`, word for word. Qwen3-TTS
    /// Base's in-context-learning mode requires it whenever a
    /// reference clip is given. Must appear together with
    /// `reference_wav` (the config rejects one without the other).
    reference_text: ?[]const u8 = null,
    streaming: bool = false,
    language: ?[]const u8 = null,
    config_id: ?[]const u8 = null,
    weight_id: ?[]const u8 = null,
};

/// The brain model path. The engine does NOT run LLM weights
/// itself (audio.cpp is audio models only) — the brain lives
/// behind an OpenAI-compatible server (Ollama by default), and
/// this section says which server and which model to ask for.
pub const BrainConfig = struct {
    url: []const u8 = "http://127.0.0.1:11434/v1/chat/completions",
    model: []const u8 = "local",
};

/// Sando Pulse, the knowledge side. The engine asks Pulse for
/// knowledge out of the box (enabled by default); the URL points
/// at the local Pulse server.
pub const PulseConfig = struct {
    url: []const u8 = "http://127.0.0.1:9000",
    enabled: bool = true,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    mode: RuntimeMode = .realtime,
    sample_rate: u32 = 24000,
    channels: u8 = 1,
    backend: []const u8 = "auto",
    webgpu: bool = false,
    low_power: bool = false,
    /// Operator system-prompt override (borrowed from the config
    /// arena). Null = use the built-in Sando persona (persona.zig).
    persona_prompt: ?[]const u8 = null,
    /// Which brain server + model to ask for (CLI flags override).
    brain: BrainConfig = .{},
    /// Pulse knowledge integration (CLI flags override).
    pulse: PulseConfig = .{},
    models: []ModelEntry = &.{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findModel(self: *const Config, name: []const u8) ?*const ModelEntry {
        for (self.models) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    pub fn modelsOfKind(self: *const Config, kind: ModelKind, alloc: std.mem.Allocator) ![]const ModelEntry {
        var out: std.ArrayList(ModelEntry) = .empty;
        for (self.models) |m| {
            if (m.kind == kind) try out.append(alloc, m);
        }
        return out.toOwnedSlice(alloc);
    }
};

const valid_sample_rates = [_]u32{ 8000, 16000, 22050, 24000, 32000, 44100, 48000 };
const valid_backends = [_][]const u8{ "auto", "cpu", "cuda", "hip", "metal", "vulkan", "sycl", "webgpu" };

/// Parse TOML text into a validated Config. `alloc` is the backing
/// allocator for the config's arena (freed by Config.deinit).
pub fn parse(alloc: std.mem.Allocator, text: []const u8) ConfigError!Config {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    var mode: RuntimeMode = .realtime;
    var sample_rate: u32 = 24000;
    var channels: u8 = 1;
    var backend: []const u8 = "auto";
    var webgpu = false;
    var low_power = false;
    var persona_prompt: ?[]const u8 = null;
    var brain_cfg = BrainConfig{};
    var pulse_cfg = PulseConfig{};
    var models: std.ArrayList(ModelEntry) = .empty;
    defer models.deinit(a);

    var section: enum { none, runtime, hardware, persona, brain, pulse, models } = .none;
    var cur: ?*ModelEntry = null;
    var seen_runtime_mode = false;
    var seen_sample_rate = false;
    var seen_channels = false;
    var seen_backend = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "[[")) {
            // Array of tables: only [[models]] is supported.
            if (!std.mem.endsWith(u8, trimmed, "]]")) return error.InvalidSyntax;
            const name = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
            if (!std.mem.eql(u8, name, "models")) return error.UnknownSection;
            section = .models;
            try models.append(a, .{ .name = "", .kind = .stt, .file = "" });
            cur = &models.items[models.items.len - 1];
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "[")) {
            if (!std.mem.endsWith(u8, trimmed, "]")) return error.InvalidSyntax;
            const name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
            cur = null;
            if (std.mem.eql(u8, name, "runtime")) {
                section = .runtime;
            } else if (std.mem.eql(u8, name, "hardware")) {
                section = .hardware;
            } else if (std.mem.eql(u8, name, "persona")) {
                section = .persona;
            } else if (std.mem.eql(u8, name, "brain")) {
                section = .brain;
            } else if (std.mem.eql(u8, name, "pulse")) {
                section = .pulse;
            } else {
                return error.UnknownSection;
            }
            continue;
        }

        // key = value
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidSyntax;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const raw_value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (key.len == 0 or raw_value.len == 0) return error.InvalidSyntax;

        switch (section) {
            .none => return error.InvalidSyntax,
            .runtime => {
                if (std.mem.eql(u8, key, "mode")) {
                    const v = try parseString(raw_value);
                    if (std.mem.eql(u8, v, "realtime")) mode = .realtime else if (std.mem.eql(u8, v, "offline")) mode = .offline else return error.InvalidValue;
                    seen_runtime_mode = true;
                } else if (std.mem.eql(u8, key, "sample_rate")) {
                    const v = try parseInt(raw_value);
                    if (v < 0 or v > 0xffff_ffff) return error.InvalidValue;
                    sample_rate = @intCast(v);
                    seen_sample_rate = true;
                } else if (std.mem.eql(u8, key, "channels")) {
                    const v = try parseInt(raw_value);
                    if (v < 1 or v > 2) return error.InvalidValue;
                    channels = @intCast(v);
                    seen_channels = true;
                } else {
                    return error.UnknownKey;
                }
            },
            .hardware => {
                if (std.mem.eql(u8, key, "backend")) {
                    const v = try parseString(raw_value);
                    backend = try a.dupe(u8, v);
                    seen_backend = true;
                } else if (std.mem.eql(u8, key, "webgpu")) {
                    webgpu = try parseBool(raw_value);
                } else if (std.mem.eql(u8, key, "low_power")) {
                    low_power = try parseBool(raw_value);
                } else {
                    return error.UnknownKey;
                }
            },
            .persona => {
                // The operator's system-prompt override. Optional:
                // when absent the built-in Sando persona is used.
                if (std.mem.eql(u8, key, "system_prompt")) {
                    persona_prompt = try a.dupe(u8, try parseString(raw_value));
                } else {
                    return error.UnknownKey;
                }
            },
            .brain => {
                if (std.mem.eql(u8, key, "url")) {
                    brain_cfg.url = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "model")) {
                    brain_cfg.model = try a.dupe(u8, try parseString(raw_value));
                } else {
                    return error.UnknownKey;
                }
            },
            .pulse => {
                if (std.mem.eql(u8, key, "url")) {
                    pulse_cfg.url = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "enabled")) {
                    pulse_cfg.enabled = try parseBool(raw_value);
                } else {
                    return error.UnknownKey;
                }
            },
            .models => {
                const m = cur orelse return error.InvalidSyntax;
                if (std.mem.eql(u8, key, "name")) {
                    m.name = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "kind")) {
                    m.kind = ModelKind.fromName(try parseString(raw_value)) orelse return error.InvalidValue;
                } else if (std.mem.eql(u8, key, "file")) {
                    m.file = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "voice")) {
                    m.voice = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "reference_wav")) {
                    m.reference_wav = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "reference_text")) {
                    m.reference_text = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "streaming")) {
                    m.streaming = try parseBool(raw_value);
                } else if (std.mem.eql(u8, key, "language")) {
                    m.language = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "config_id")) {
                    m.config_id = try a.dupe(u8, try parseString(raw_value));
                } else if (std.mem.eql(u8, key, "weight_id")) {
                    m.weight_id = try a.dupe(u8, try parseString(raw_value));
                } else {
                    return error.UnknownKey;
                }
            },
        }
    }

    // Required fields.
    if (!seen_runtime_mode or !seen_sample_rate or !seen_channels) return error.MissingField;
    if (!seen_backend) return error.MissingField;

    // Value validation.
    var rate_ok = false;
    for (valid_sample_rates) |r| {
        if (sample_rate == r) rate_ok = true;
    }
    if (!rate_ok) return error.InvalidValue;

    var backend_ok = false;
    for (valid_backends) |b| {
        if (std.mem.eql(u8, backend, b)) backend_ok = true;
    }
    if (!backend_ok) return error.InvalidValue;

    // URLs must name a server (http/https). A bare word is a typo,
    // not a server — reject it here instead of failing mid-turn.
    if (brain_cfg.url.len == 0 or (!std.mem.startsWith(u8, brain_cfg.url, "http://") and !std.mem.startsWith(u8, brain_cfg.url, "https://"))) return error.InvalidValue;
    if (pulse_cfg.url.len == 0 or (!std.mem.startsWith(u8, pulse_cfg.url, "http://") and !std.mem.startsWith(u8, pulse_cfg.url, "https://"))) return error.InvalidValue;
    if (brain_cfg.model.len == 0) return error.InvalidValue;

    for (models.items) |m| {
        if (m.name.len == 0 or m.file.len == 0) return error.MissingField;
        // A reference clip without its transcript (or the reverse)
        // fails at runtime inside Qwen3-TTS with a bare "Runtime"
        // error — reject it here with a clear cause instead.
        if ((m.reference_wav != null) != (m.reference_text != null)) return error.InvalidValue;
    }
    for (models.items, 0..) |m, i| {
        for (models.items, 0..) |other, j| {
            if (i != j and std.mem.eql(u8, m.name, other.name)) return error.DuplicateModel;
        }
    }

    // The arena is moved into the Config only here, after every allocation
    // is done — copying it earlier would leave the Config holding a stale
    // buffer list and leak every chunk allocated afterwards.
    return .{
        .arena = arena,
        .mode = mode,
        .sample_rate = sample_rate,
        .channels = channels,
        .backend = backend,
        .webgpu = webgpu,
        .low_power = low_power,
        .persona_prompt = persona_prompt,
        .brain = brain_cfg,
        .pulse = pulse_cfg,
        .models = try models.toOwnedSlice(a),
    };
}

/// Load and validate a config file. Absolute paths are used as-is;
/// relative paths resolve against the working directory.
pub fn loadFromFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const text = if (std.Io.Dir.path.isAbsolute(path)) blk: {
        var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.ConfigFileNotFound;
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);
        break :blk reader.interface.readAllocShort(alloc, 1 << 20) catch return error.ConfigFileNotFound;
    } else std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return error.ConfigFileNotFound;
    defer alloc.free(text);
    return parse(alloc, text);
}

/// Re-parse `path` into a fresh Config. On error the old config is
/// untouched; the caller swaps on success.
pub fn reload(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    return loadFromFile(alloc, io, path);
}

fn stripComment(line: []const u8) []const u8 {
    var in_quotes = false;
    for (line, 0..) |c, i| {
        if (c == '"' and (i == 0 or line[i - 1] != '\\')) in_quotes = !in_quotes;
        if (c == '#' and !in_quotes) return line[0..i];
    }
    return line;
}

fn parseString(raw: []const u8) ConfigError![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidValue;
    return raw[1 .. raw.len - 1];
}

fn parseInt(raw: []const u8) ConfigError!i64 {
    return std.fmt.parseInt(i64, raw, 10) catch return error.InvalidValue;
}

fn parseBool(raw: []const u8) ConfigError!bool {
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    return error.InvalidValue;
}

pub const example_config =
    \\[runtime]
    \\mode = "realtime"
    \\sample_rate = 24000
    \\channels = 1
    \\
    \\[hardware]
    \\backend = "auto"
    \\webgpu = true
    \\low_power = true
    \\
    \\[persona]
    \\system_prompt = "You are Sando. Talk like a real person, not like a voice assistant. Speak natural Liberian English, warm, easy, and free-flowing. Use Koloqua words and expressions when they fit, the way people in Liberia actually talk. Keep it short, like something you would say out loud. One or two sentences is usually enough; say more only when the person really needs it. You can talk about anything. If the person is just chatting, chat back. Answer questions straight, react to what they say, and ask something back when it feels natural. Remember what was said earlier in this conversation and build on it. Never introduce yourself as a machine or an assistant, and never open with a stiff greeting or an offer to help. Just talk."
    \\
    \\# The brain model path. The engine does not run LLM weights
    \\# itself — the brain lives behind an OpenAI-compatible server
    \\# (Ollama by default). Set the server and model here; the
    \\# --brain-url / --brain-model flags override these two lines.
    \\[brain]
    \\url = "http://127.0.0.1:11434/v1/chat/completions"
    \\model = "local"
    \\
    \\# Sando Pulse, the knowledge side. On out of the box: when a
    \\# turn needs knowledge, the engine asks Pulse first and the
    \\# answer rides in the prompt. Set enabled = false to talk
    \\# without Pulse; --no-pulse does the same for one run.
    \\[pulse]
    \\url = "http://127.0.0.1:9000"
    \\enabled = true
    \\
    \\[[models]]
    \\name = "qwen3-tts-0.6b"
    \\kind = "tts"
    \\file = "models/qwen3-tts-12hz-0.6b-base-q8_0.gguf"
    \\voice = "liberian-voice-01"
    \\reference_wav = "assets/voices/demo-voice.wav"
    \\reference_text = "Hello, this is Sando, your Liberian voice. I can hear you, and I can speak."
    \\streaming = true
    \\language = "en"
    \\
    \\[[models]]
    \\name = "whisper-small"
    \\kind = "stt"
    \\file = "models/whisper-small-q8_0.gguf"
    \\streaming = true
    \\language = "auto"
    \\
    \\[[models]]
    \\name = "silero-vad"
    \\kind = "vad"
    \\file = "models/silero_vad.onnx"
    \\streaming = false
    \\
;

test "parse example config" {
    const alloc = std.testing.allocator;
    var cfg = try parse(alloc, example_config);
    defer cfg.deinit();
    try std.testing.expect(cfg.mode == .realtime);
    try std.testing.expectEqual(@as(u32, 24000), cfg.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), cfg.channels);
    try std.testing.expectEqualStrings("auto", cfg.backend);
    try std.testing.expect(cfg.webgpu);
    try std.testing.expectEqual(@as(usize, 3), cfg.models.len);
    // The example ships the default persona as the override text.
    try std.testing.expect(cfg.persona_prompt != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg.persona_prompt.?, "Talk like a real person") != null);
    // The example ships the brain + pulse sections.
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/chat/completions", cfg.brain.url);
    try std.testing.expectEqualStrings("local", cfg.brain.model);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", cfg.pulse.url);
    try std.testing.expect(cfg.pulse.enabled);
    try std.testing.expectEqualStrings("qwen3-tts-0.6b", cfg.models[0].name);
    try std.testing.expect(cfg.models[0].kind == .tts);
    try std.testing.expectEqualStrings("liberian-voice-01", cfg.models[0].voice.?);
    // The example ships the demo reference voice for Qwen3-TTS Base.
    try std.testing.expectEqualStrings("assets/voices/demo-voice.wav", cfg.models[0].reference_wav.?);
    try std.testing.expectEqualStrings("Hello, this is Sando, your Liberian voice. I can hear you, and I can speak.", cfg.models[0].reference_text.?);
    try std.testing.expect(cfg.findModel("whisper-small") != null);
    try std.testing.expect(cfg.findModel("nope") == null);
    const tts = try cfg.modelsOfKind(.tts, alloc);
    defer alloc.free(tts);
    try std.testing.expectEqual(@as(usize, 1), tts.len);
}

test "reference_wav without reference_text is rejected" {
    const alloc = std.testing.allocator;
    const bad =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\
        \\[hardware]
        \\backend = "auto"
        \\
        \\[[models]]
        \\name = "qwen3-tts-0.6b"
        \\kind = "tts"
        \\file = "models/qwen3-tts-12hz-0.6b-base-q8_0.gguf"
        \\reference_wav = "assets/voices/demo-voice.wav"
        \\
    ;
    try std.testing.expectError(error.InvalidValue, parse(alloc, bad));
}

test "persona prompt is optional, unknown persona key rejected" {
    const alloc = std.testing.allocator;
    const no_persona =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\
    ;
    var cfg = try parse(alloc, no_persona);
    defer cfg.deinit();
    try std.testing.expect(cfg.persona_prompt == null);

    const bad_key =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[persona]
        \\tone = "pirate"
        \\
    ;
    try std.testing.expectError(error.UnknownKey, parse(alloc, bad_key));
}

test "reject bad sample rate" {
    const alloc = std.testing.allocator;
    const bad =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 12345
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\
    ;
    try std.testing.expectError(error.InvalidValue, parse(alloc, bad));
}

test "reject unknown backend and unknown key" {
    const alloc = std.testing.allocator;
    const bad_backend =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "quantum"
        \\
    ;
    try std.testing.expectError(error.InvalidValue, parse(alloc, bad_backend));

    const bad_key =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\loudness = 11
        \\[hardware]
        \\backend = "auto"
        \\
    ;
    try std.testing.expectError(error.UnknownKey, parse(alloc, bad_key));
}

test "reject duplicate model names and missing fields" {
    const alloc = std.testing.allocator;
    const dup =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[[models]]
        \\name = "same"
        \\kind = "tts"
        \\file = "a.gguf"
        \\[[models]]
        \\name = "same"
        \\kind = "stt"
        \\file = "b.gguf"
        \\
    ;
    try std.testing.expectError(error.DuplicateModel, parse(alloc, dup));

    const missing =
        \\[runtime]
        \\mode = "realtime"
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\
    ;
    try std.testing.expectError(error.MissingField, parse(alloc, missing));
}

test "brain and pulse sections default when absent, override when present" {
    const alloc = std.testing.allocator;
    const minimal =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\
    ;
    var cfg = try parse(alloc, minimal);
    defer cfg.deinit();
    // Absent sections = the out-of-the-box defaults.
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/chat/completions", cfg.brain.url);
    try std.testing.expectEqualStrings("local", cfg.brain.model);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", cfg.pulse.url);
    try std.testing.expect(cfg.pulse.enabled);

    const overridden =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[brain]
        \\url = "http://192.168.1.5:11434/v1/chat/completions"
        \\model = "sando-brain-7b"
        \\[pulse]
        \\url = "http://192.168.1.5:9000"
        \\enabled = false
        \\
    ;
    var cfg2 = try parse(alloc, overridden);
    defer cfg2.deinit();
    try std.testing.expectEqualStrings("http://192.168.1.5:11434/v1/chat/completions", cfg2.brain.url);
    try std.testing.expectEqualStrings("sando-brain-7b", cfg2.brain.model);
    try std.testing.expectEqualStrings("http://192.168.1.5:9000", cfg2.pulse.url);
    try std.testing.expect(!cfg2.pulse.enabled);
}

test "brain and pulse reject bad urls and unknown keys" {
    const alloc = std.testing.allocator;
    const bad_brain_url =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[brain]
        \\url = "not-a-server"
        \\
    ;
    try std.testing.expectError(error.InvalidValue, parse(alloc, bad_brain_url));

    const bad_pulse_url =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[pulse]
        \\url = "ftp://example.com"
        \\
    ;
    try std.testing.expectError(error.InvalidValue, parse(alloc, bad_pulse_url));

    const bad_key =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[pulse]
        \\timeout = 5
        \\
    ;
    try std.testing.expectError(error.UnknownKey, parse(alloc, bad_key));

    const bad_section =
        \\[runtime]
        \\mode = "realtime"
        \\sample_rate = 24000
        \\channels = 1
        \\[hardware]
        \\backend = "auto"
        \\[knowledge]
        \\url = "http://127.0.0.1:9000"
        \\
    ;
    try std.testing.expectError(error.UnknownSection, parse(alloc, bad_section));
}
