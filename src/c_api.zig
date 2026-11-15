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
const runtime = @import("runtime.zig");
const audio = @import("audio.zig");
const streaming = @import("streaming.zig");
const brain = @import("brain.zig");
const conversation = @import("conversation.zig");

pub const version_string: [:0]const u8 = "0.3.0";

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

// ---------------------------------------------------------------------------
// Inference entry points (Phase 2).
//
// The engine does NOT load models at create time; these entry points
// lazy-load exactly the model they need from the engine's config
// (nothing is downloaded — the file must already exist). Returned
// strings are owned by the caller; free them with sando_free_string.
// A streaming session borrows the engine — destroy the stream before
// the engine.
// ---------------------------------------------------------------------------

fn parseTaskKind(s: []const u8) ?runtime.TaskKind {
    if (std.mem.eql(u8, s, "asr")) return .asr;
    if (std.mem.eql(u8, s, "tts")) return .tts;
    if (std.mem.eql(u8, s, "vad")) return .vad;
    return null;
}

/// Load `name` from the engine's config when it is not loaded yet.
fn ensureModelLoaded(e: *CEngine, name: []const u8) !void {
    if (e.eng.rt.model(name) != null) return;
    const entry = e.eng.cfg.findModel(name) orelse return error.ModelNotInConfig;
    try e.eng.loadModel(entry.name, entry.kind, entry.file);
}

fn dupeCString(text: []const u8) ?[*:0]const u8 {
    const alloc = std.heap.c_allocator;
    const out = alloc.allocSentinel(u8, text.len, 0) catch {
        setError("OutOfMemory");
        return null;
    };
    @memcpy(out[0..text.len], text);
    return out.ptr;
}

/// Free a string returned by sando_engine_infer_text,
/// sando_stream_push or sando_stream_finish.
pub export fn sando_free_string(s: ?[*:0]u8) void {
    const p = s orelse return;
    std.heap.c_allocator.free(std.mem.span(p));
}

/// Offline text inference (ASR/VAD): run `model_name` over a WAV
/// file and return the transcript. NULL on failure.
pub export fn sando_engine_infer_text(
    e: *CEngine,
    model_name: [*:0]const u8,
    task: [*:0]const u8,
    wav_path: [*:0]const u8,
) ?[*:0]const u8 {
    const alloc = std.heap.c_allocator;
    const io = e.threaded.io();
    const task_kind = parseTaskKind(std.mem.span(task)) orelse {
        setError("UnknownTask");
        return null;
    };
    ensureModelLoaded(e, std.mem.span(model_name)) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    var session = e.eng.createSession(std.mem.span(model_name), task_kind, .offline) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    defer session.deinit(alloc);
    var wav = audio.readWavFile(alloc, io, std.mem.span(wav_path)) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    defer wav.deinit(alloc);
    const req = runtime.Request{
        .task = task_kind,
        .mode = .offline,
        .audio = wav.samples,
        .sample_rate = wav.sample_rate,
        .channels = wav.channels,
    };
    var resp = session.run(io, alloc, req) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    defer resp.deinit();
    const t = resp.text() catch |err| {
        setErrorFromErr(err);
        return null;
    };
    return dupeCString(t.text);
}

/// Offline TTS: synthesize `text` with `model_name` and write a WAV
/// file to `wav_out_path`. Returns 0 on success, -1 on failure.
pub export fn sando_engine_infer_tts(
    e: *CEngine,
    model_name: [*:0]const u8,
    text: [*:0]const u8,
    language: ?[*:0]const u8,
    wav_out_path: [*:0]const u8,
) c_int {
    const alloc = std.heap.c_allocator;
    const io = e.threaded.io();
    ensureModelLoaded(e, std.mem.span(model_name)) catch |err| {
        setErrorFromErr(err);
        return -1;
    };
    var session = e.eng.createSession(std.mem.span(model_name), .tts, .offline) catch |err| {
        setErrorFromErr(err);
        return -1;
    };
    defer session.deinit(alloc);
    const req = runtime.Request{
        .task = .tts,
        .mode = .offline,
        .text = std.mem.span(text),
        .language = if (language) |l| std.mem.span(l) else null,
    };
    var resp = session.run(io, alloc, req) catch |err| {
        setErrorFromErr(err);
        return -1;
    };
    defer resp.deinit();
    const a = resp.audio() catch |err| {
        setErrorFromErr(err);
        return -1;
    };
    audio.writeWavFile(io, std.mem.span(wav_out_path), a.samples, a.sample_rate, a.channels, .pcm16) catch |err| {
        setErrorFromErr(err);
        return -1;
    };
    return 0;
}

/// A streaming inference session. Borrows the engine — destroy the
/// stream before the engine.
const CStream = struct {
    eng: *CEngine,
    session: runtime.Session,
    pushed_samples: i64 = 0,
};

/// Create a streaming session for `model_name` + `task`
/// ("asr", "tts" or "vad"). NULL on failure.
pub export fn sando_stream_create(
    e: *CEngine,
    model_name: [*:0]const u8,
    task: [*:0]const u8,
) ?*CStream {
    const alloc = std.heap.c_allocator;
    const task_kind = parseTaskKind(std.mem.span(task)) orelse {
        setError("UnknownTask");
        return null;
    };
    ensureModelLoaded(e, std.mem.span(model_name)) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    var session = e.eng.createSession(std.mem.span(model_name), task_kind, .streaming) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    errdefer session.deinit(alloc);
    // Open the stream (no seed request).
    session.streamStart(alloc, null) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    const out = alloc.create(CStream) catch {
        setError("OutOfMemory");
        return null;
    };
    out.* = .{ .eng = e, .session = session };
    return out;
}

pub export fn sando_stream_destroy(s: ?*CStream) void {
    const stream = s orelse return;
    stream.session.deinit(std.heap.c_allocator);
    std.heap.c_allocator.destroy(stream);
}

/// Push one audio chunk (interleaved float PCM, `frames` per
/// channel). Returns the newest partial text the backend produced
/// for this chunk, or NULL when no event carried text. Owned by the
/// caller — free with sando_free_string.
pub export fn sando_stream_push(
    s: *CStream,
    samples: [*]const f32,
    frames: usize,
    sample_rate: u32,
    channels: u8,
) ?[*:0]const u8 {
    const alloc = std.heap.c_allocator;
    var pump = streaming.StreamPump{ .session = &s.session };
    const events = pump.push(alloc, samples[0 .. frames * @as(usize, channels)], sample_rate, channels, s.pushed_samples) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    defer {
        for (events) |*ev| ev.deinit(alloc);
        alloc.free(events);
    }
    s.pushed_samples += @intCast(frames);
    // Newest event carrying text wins.
    var i = events.len;
    while (i > 0) {
        i -= 1;
        if (events[i].text) |t| return dupeCString(t);
    }
    return null;
}

/// Finish the stream and return the final text. Owned by the caller
/// — free with sando_free_string. NULL on failure.
pub export fn sando_stream_finish(s: *CStream) ?[*:0]const u8 {
    var resp = s.session.streamFinish() catch |err| {
        setErrorFromErr(err);
        return null;
    };
    defer resp.deinit();
    const t = resp.text() catch |err| {
        setErrorFromErr(err);
        return null;
    };
    return dupeCString(t.text);
}

// ---------------------------------------------------------------------------
// Conversation entry points (Phase 3).
//
// A conversation is one session (bounded history, in-memory only)
// plus a brain. Two brains are exposed: the scripted mock brain
// (no network, no keys) and an agent brain driven by a host C
// callback. `ask` is text in, reply text out; no ASR/TTS session is
// attached here, so the TTS leg reports skipped — the CLI
// `converse` command is where the full audio pipeline lives. A
// conversation borrows the engine's Io: destroy it before the
// engine. Returned strings are owned by the caller; free them with
// sando_free_string.
// ---------------------------------------------------------------------------

/// Host brain callback: answer `prompt` (NUL-terminated) and return
/// a NUL-terminated reply, or NULL on failure. The library copies
/// the reply, so the host keeps ownership of its string.
pub const AgentReplyFn = *const fn (ctx: ?*anyopaque, prompt: [*:0]const u8) callconv(.c) ?[*:0]const u8;

const AgentHolder = struct {
    ctx: ?*anyopaque,
    cb: AgentReplyFn,
};

/// Adapt the C callback to the Zig AgentCallback: the whole reply
/// arrives as one chunk, then the owned reply is returned.
fn agentReplyAdapter(
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    prompt: []const u8,
    chunk_ctx: *anyopaque,
    on_chunk: brain.ChunkFn,
) anyerror![]const u8 {
    const holder: *AgentHolder = @ptrCast(@alignCast(ctx));
    const prompt_z = try alloc.allocSentinel(u8, prompt.len, 0);
    defer alloc.free(prompt_z);
    @memcpy(prompt_z[0..prompt.len], prompt);
    const reply_z = holder.cb(holder.ctx, prompt_z.ptr) orelse return error.AgentReplyFailed;
    const reply = std.mem.span(reply_z);
    try on_chunk(chunk_ctx, reply);
    return try alloc.dupe(u8, reply);
}

const CConversation = struct {
    eng: *CEngine,
    conv: conversation.Conversation,
    mock: brain.MockBrain = .{},
    agent_holder: AgentHolder = undefined,
    agent_brain: brain.AgentBrain = undefined,
};

fn conversationCreate(
    e: ?*CEngine,
    voice: ?[*:0]const u8,
    language: ?[*:0]const u8,
    agent: ?AgentHolder,
) ?*CConversation {
    const eng = e orelse {
        setError("NullEngine");
        return null;
    };
    const alloc = std.heap.c_allocator;
    const io = eng.threaded.io();
    const out = alloc.create(CConversation) catch {
        setError("OutOfMemory");
        return null;
    };
    // Heap-stable before the conversation borrows the brain fields.
    out.* = .{
        .eng = eng,
        .conv = undefined,
        .mock = .{},
        .agent_holder = undefined,
        .agent_brain = undefined,
    };
    errdefer alloc.destroy(out);
    const v = if (voice) |p| std.mem.span(p) else "v1";
    const l = if (language) |p| std.mem.span(p) else "en";
    if (agent) |a| {
        out.agent_holder = a;
        out.agent_brain = .{ .ctx = &out.agent_holder, .callback = agentReplyAdapter };
        out.conv = conversation.Conversation.init(alloc, io, out.agent_brain.asBrain(), v, l) catch |err| {
            setErrorFromErr(err);
            return null;
        };
    } else {
        out.conv = conversation.Conversation.init(alloc, io, out.mock.asBrain(), v, l) catch |err| {
            setErrorFromErr(err);
            return null;
        };
    }
    return out;
}

/// Create a conversation with the scripted mock brain (no network,
/// no keys). `voice`/`language` may be NULL for the defaults
/// ("v1"/"en"). NULL on failure — see sando_last_error(). Destroy
/// with sando_conversation_destroy().
pub export fn sando_conversation_create_mock(
    e: ?*CEngine,
    voice: ?[*:0]const u8,
    language: ?[*:0]const u8,
) ?*CConversation {
    return conversationCreate(e, voice, language, null);
}

/// Create a conversation whose brain is a host callback (`cb`).
/// `ctx` is passed through to every call. `cb` must not be NULL.
/// `voice`/`language` may be NULL for the defaults. NULL on
/// failure — see sando_last_error(). Destroy with
/// sando_conversation_destroy().
pub export fn sando_conversation_create_agent(
    e: ?*CEngine,
    ctx: ?*anyopaque,
    cb: ?AgentReplyFn,
    voice: ?[*:0]const u8,
    language: ?[*:0]const u8,
) ?*CConversation {
    const callback = cb orelse {
        setError("NullAgentCallback");
        return null;
    };
    return conversationCreate(e, voice, language, .{ .ctx = ctx, .cb = callback });
}

/// Ask one text turn and return the reply. Owned by the caller —
/// free with sando_free_string. NULL on failure.
pub export fn sando_conversation_ask(c: ?*CConversation, text: [*:0]const u8) ?[*:0]const u8 {
    const conv = c orelse {
        setError("NullConversation");
        return null;
    };
    const alloc = std.heap.c_allocator;
    var result = conv.conv.processText(std.mem.span(text)) catch |err| {
        setErrorFromErr(err);
        return null;
    };
    defer result.deinit(alloc);
    return dupeCString(result.reply);
}

/// Number of turns in the session history (2 per ask: user +
/// assistant). 0 for a NULL conversation.
pub export fn sando_conversation_history_count(c: ?*CConversation) usize {
    const conv = c orelse return 0;
    return conv.conv.session.history.items.len;
}

pub export fn sando_conversation_destroy(c: ?*CConversation) void {
    const conv = c orelse return;
    conv.conv.deinit();
    std.heap.c_allocator.destroy(conv);
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
    try std.testing.expectEqualStrings("0.3.0", std.mem.span(sando_version()));
    try std.testing.expectEqual(@as(c_int, -1), sando_config_validate("config/does-not-exist.toml"));
}

test "c api inference fails honestly without a model in the config" {
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

    // No models in the config at all: every inference entry point
    // fails cleanly instead of crashing.
    const wav_z: [:0]const u8 = "does-not-exist.wav";
    const ghost: [:0]const u8 = "ghost-model";
    const asr: [:0]const u8 = "asr";
    try std.testing.expect(sando_engine_infer_text(e, ghost.ptr, asr.ptr, wav_z.ptr) == null);
    try std.testing.expect(!std.mem.eql(u8, std.mem.span(sando_last_error()), "no error"));
    const tts_text: [:0]const u8 = "hello";
    try std.testing.expectEqual(@as(c_int, -1), sando_engine_infer_tts(e, ghost.ptr, tts_text.ptr, null, "out.wav"));
    try std.testing.expect(sando_stream_create(e, ghost.ptr, asr.ptr) == null);
    const bad_task: [:0]const u8 = "telepathy";
    try std.testing.expect(sando_stream_create(e, ghost.ptr, bad_task.ptr) == null);
    // Freeing NULL is a no-op.
    sando_free_string(null);
}

fn testAgentReply(ctx: ?*anyopaque, prompt: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    _ = ctx;
    _ = prompt;
    return "agent says hi";
}

test "c api conversation mock asks and remembers history" {
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

    const voice: [:0]const u8 = "v1";
    const lang: [:0]const u8 = "en";
    const c = sando_conversation_create_mock(e, voice.ptr, lang.ptr) orelse {
        std.debug.print("conversation create failed: {s}\n", .{std.mem.span(sando_last_error())});
        return error.ConversationCreateFailed;
    };
    defer sando_conversation_destroy(c);
    try std.testing.expectEqual(@as(usize, 0), sando_conversation_history_count(c));

    const hello: [:0]const u8 = "hello there";
    const reply = sando_conversation_ask(c, hello.ptr) orelse {
        std.debug.print("ask failed: {s}\n", .{std.mem.span(sando_last_error())});
        return error.ConversationAskFailed;
    };
    defer sando_free_string(@constCast(reply));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(reply), "Hello") != null);
    // One ask = one user turn + one assistant turn in history.
    try std.testing.expectEqual(@as(usize, 2), sando_conversation_history_count(c));

    // A second ask keeps growing history; NULL inputs fail cleanly.
    const thanks: [:0]const u8 = "thank you";
    const reply2 = sando_conversation_ask(c, thanks.ptr) orelse return error.ConversationAskFailed;
    defer sando_free_string(@constCast(reply2));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(reply2), "welcome") != null);
    try std.testing.expectEqual(@as(usize, 4), sando_conversation_history_count(c));
    try std.testing.expect(sando_conversation_ask(null, hello.ptr) == null);
    try std.testing.expectEqual(@as(usize, 0), sando_conversation_history_count(null));
    sando_conversation_destroy(null);
}

test "c api conversation agent callback answers" {
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

    // NULL voice/language fall back to the defaults.
    const c = sando_conversation_create_agent(e, null, testAgentReply, null, null) orelse {
        std.debug.print("conversation create failed: {s}\n", .{std.mem.span(sando_last_error())});
        return error.ConversationCreateFailed;
    };
    defer sando_conversation_destroy(c);
    const q: [:0]const u8 = "what is the time?";
    const reply = sando_conversation_ask(c, q.ptr) orelse {
        std.debug.print("ask failed: {s}\n", .{std.mem.span(sando_last_error())});
        return error.ConversationAskFailed;
    };
    defer sando_free_string(@constCast(reply));
    try std.testing.expectEqualStrings("agent says hi", std.mem.span(reply));
    try std.testing.expectEqual(@as(usize, 2), sando_conversation_history_count(c));
}

test "c api conversation create fails honestly" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expect(sando_conversation_create_mock(null, null, null) == null);
    try std.testing.expect(sando_conversation_create_agent(null, null, testAgentReply, null, null) == null);

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
    const rel = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/sando.toml", .{tmp.sub_path});
    defer alloc.free(rel);
    const rel_buf = try alloc.allocSentinel(u8, rel.len, 0);
    defer alloc.free(rel_buf);
    @memcpy(rel_buf[0..rel.len], rel);
    const rel_z = rel_buf[0..rel.len :0];
    const e = sando_engine_create(rel_z.ptr) orelse return error.EngineCreateFailed;
    defer sando_engine_destroy(e);

    // A NULL agent callback is a creation failure, not a crash.
    try std.testing.expect(sando_conversation_create_agent(e, null, null, null, null) == null);
    try std.testing.expect(!std.mem.eql(u8, std.mem.span(sando_last_error()), "no error"));
}
