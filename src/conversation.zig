//! Conversation orchestration: the speech-to-brain-to-speech
//! pipeline and real-time conversation state.
//!
//! One `Conversation` owns a `Session` (bounded in-memory history,
//! voice, language), a `Brain` (any transport — see brain.zig), and
//! optional ASR/TTS sessions borrowed from the engine. The pipeline
//! is ASR → brain → TTS, with the SmartCache consulted at each leg:
//!
//! - ASR leg: cache hit returns the transcript without inference.
//! - Brain leg: the reply streams chunk by chunk; each complete
//!   sentence goes to TTS as soon as it arrives (incremental TTS
//!   generation) instead of waiting for the whole reply.
//! - TTS leg: cache hit speaks without a model; otherwise the TTS
//!   session synthesizes the sentence (offline, one request per
//!   sentence) and the audio is cached and delivered through
//!   `on_tts_audio`. When there is no TTS session and no cache hit,
//!   the sentence is counted as skipped — never faked.
//!
//! Turn-taking: `shouldReply` builds on ReflexEngine's
//! turn-end probability (silence + partial transcript). Barge-in
//! (VoiceContinuum): an interrupt provider is polled after each
//! spoken sentence; when it returns text, the reply is cancelled
//! mid-stream, the partial reply is kept in history, the
//! interruption becomes a new user turn, and the brain answers it
//! — the conversation survives without losing context. A
//! non-streaming brain (one that never calls `on_chunk`) still
//! works: its returned text is fed through the sentence chunker
//! after `reply` returns.

const std = @import("std");
const brain = @import("brain.zig");
const cache = @import("cache.zig");
const lang = @import("language.zig");
const persona = @import("persona.zig");
const pulse = @import("pulse.zig");
const reflex = @import("reflex.zig");
const runtime = @import("runtime.zig");

/// A sentence longer than this without a terminator is cut at the
/// last space before the cap (streaming brains can ramble).
pub const max_sentence_chars = 200;

pub const TurnRole = enum { user, assistant };

/// One history turn. `text` is owned.
pub const Turn = struct {
    role: TurnRole,
    text: []const u8,

    pub fn deinit(self: *Turn, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

/// Per-session conversation state: bounded history, voice,
/// language. In-memory only in this phase (no DB).
pub const Session = struct {
    alloc: std.mem.Allocator,
    id: []const u8,
    voice: []const u8,
    language: []const u8,
    /// Speaker reference clip for the TTS leg (Qwen3-TTS Base needs
    /// one to speak). Borrowed — set from the TTS model entry after
    /// init, like `system_prompt`. Null = no reference clip.
    reference_wav: ?[]const u8 = null,
    reference_text: ?[]const u8 = null,
    history: std.ArrayList(Turn) = .empty,
    /// System prompt override (borrowed — caller-owned). When null
    /// the default Sando persona (persona.default_persona_prompt)
    /// is used. Set from [persona] system_prompt in the config.
    system_prompt: ?[]const u8 = null,
    /// Knowledge fetched from Sando Pulse for the current turn
    /// (owned — set by the Conversation before renderPrompt,
    /// cleared when the turn ends). Rendered between the system
    /// prompt and the history so the brain sees it as context,
    /// clearly labelled as Pulse knowledge, not settled fact.
    knowledge_context: ?[]const u8 = null,
    /// Maximum turns kept; the oldest turn is evicted first.
    max_turns: usize = 20,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, voice: []const u8, language: []const u8) !Session {
        var rand_bytes: [8]u8 = undefined;
        io.random(&rand_bytes);
        const hex = std.fmt.bytesToHex(rand_bytes, .lower);
        return .{
            .alloc = alloc,
            .id = try alloc.dupe(u8, &hex),
            .voice = try alloc.dupe(u8, voice),
            .language = try alloc.dupe(u8, language),
        };
    }

    pub fn deinit(self: *Session) void {
        for (self.history.items) |*t| t.deinit(self.alloc);
        self.history.deinit(self.alloc);
        if (self.knowledge_context) |kc| self.alloc.free(kc);
        self.alloc.free(self.id);
        self.alloc.free(self.voice);
        self.alloc.free(self.language);
        self.* = undefined;
    }

    /// Set the Pulse knowledge for the current turn (owned copy).
    /// Pass null to clear it. Replacing frees the old context.
    pub fn setKnowledgeContext(self: *Session, text: ?[]const u8) !void {
        if (self.knowledge_context) |kc| self.alloc.free(kc);
        self.knowledge_context = null;
        if (text) |t| {
            if (t.len == 0) return;
            self.knowledge_context = try self.alloc.dupe(u8, t);
        }
    }

    /// Clear the turn's Pulse knowledge (called when the turn ends
    /// so it never leaks into a later turn's prompt).
    pub fn clearKnowledgeContext(self: *Session) void {
        if (self.knowledge_context) |kc| self.alloc.free(kc);
        self.knowledge_context = null;
    }

    pub fn turnCount(self: *const Session) usize {
        return self.history.items.len;
    }

    /// Append a turn, evicting the oldest first when over the cap.
    pub fn appendTurn(self: *Session, role: TurnRole, text: []const u8) !void {
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        try self.history.append(self.alloc, .{ .role = role, .text = owned });
        while (self.history.items.len > self.max_turns) {
            var oldest = self.history.orderedRemove(0);
            oldest.deinit(self.alloc);
        }
    }

    /// Render the prompt the brain sees: the system prompt (the
    /// operator's override, else the default Sando persona), the
    /// Pulse knowledge for this turn when there is any, the
    /// history, and the trailing "Assistant:" cue. The last history
    /// turn is the current user text. Every brain path (mock, agent,
    /// HTTP) receives this prompt, so the persona rides on every
    /// turn — including the follow-up after a barge-in, which
    /// re-renders it.
    pub fn renderPrompt(self: *const Session, alloc: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, self.system_prompt orelse persona.default_persona_prompt);
        try out.append(alloc, '\n');
        // Phase 4: the session language shapes the instruction.
        // Unregistered codes add nothing (the prompt stays exactly
        // as Phase 3 wrote it).
        const lang_line = lang.promptFor(self.language);
        if (lang_line.len > 0) {
            try out.appendSlice(alloc, lang_line);
            try out.append(alloc, '\n');
        }
        // Pulse knowledge for this turn, when the conversation
        // fetched any. Labelled as context that may be incomplete,
        // so the brain treats it as leads, not settled fact.
        if (self.knowledge_context) |kc| {
            if (kc.len > 0) {
                try out.appendSlice(alloc, "Knowledge from Sando Pulse (may be incomplete — use it as context, not as settled fact):\n");
                try out.appendSlice(alloc, kc);
                try out.append(alloc, '\n');
            }
        }
        for (self.history.items) |t| {
            try out.appendSlice(alloc, switch (t.role) {
                .user => "User: ",
                .assistant => "Assistant: ",
            });
            try out.appendSlice(alloc, t.text);
            try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, "Assistant:");
        return out.toOwnedSlice(alloc);
    }
};

/// End index (exclusive) of the first complete sentence in `text`
/// starting at or after `from`, or null when no boundary is present.
/// A sentence ends at '.', '?' or '!' followed by whitespace or
/// end of input, or at the last space before `max_sentence_chars`
/// when the run has no terminator. (Abbreviations such as "Dr."
/// split early — this is a heuristic, documented, not a model.)
fn nextSentenceEnd(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '.' or c == '?' or c == '!') {
            if (i + 1 >= text.len) return i + 1;
            const n = text[i + 1];
            if (n == ' ' or n == '\t' or n == '\n' or n == '\r') return i + 1;
        }
        if (i - from >= max_sentence_chars) {
            var cut = i;
            while (cut > from and text[cut] != ' ') : (cut -= 1) {}
            if (cut > from) return cut + 1;
            return i + 1;
        }
    }
    return null;
}

/// Split `text` into sentences. Owned slices; free each with the
/// allocator, then the slice.
pub fn splitSentences(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    var start: usize = 0;
    while (nextSentenceEnd(text, start)) |end| {
        const sentence = std.mem.trim(u8, text[start..end], " \t\n\r");
        if (sentence.len > 0) try out.append(alloc, try alloc.dupe(u8, sentence));
        start = end;
        while (start < text.len and (text[start] == ' ' or text[start] == '\t' or text[start] == '\n' or text[start] == '\r')) : (start += 1) {}
    }
    const rest = std.mem.trim(u8, text[start..], " \t\n\r");
    if (rest.len > 0) try out.append(alloc, try alloc.dupe(u8, rest));
    return out.toOwnedSlice(alloc);
}

/// Incremental sentence splitter for streamed brain text: feed
/// chunks, complete sentences are delivered to `on_sentence` as
/// they close, `finish` flushes the remainder.
pub const SentenceChunker = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) SentenceChunker {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *SentenceChunker) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn feed(
        self: *SentenceChunker,
        text: []const u8,
        ctx: *anyopaque,
        on_sentence: *const fn (ctx: *anyopaque, sentence: []const u8) anyerror!void,
    ) !void {
        try self.buf.appendSlice(self.alloc, text);
        while (nextSentenceEnd(self.buf.items, 0)) |end| {
            const sentence = std.mem.trim(u8, self.buf.items[0..end], " \t\n\r");
            // Dupe first: the sentence slice points into buf, and the
            // shift below overwrites its bytes before the handler runs.
            const owned = if (sentence.len > 0) try self.alloc.dupe(u8, sentence) else null;
            // Remove the emitted prefix before calling out: the
            // handler may feed back in (it does not here, but the
            // buffer must already be consistent if it errors).
            const remaining = self.buf.items.len - end;
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[end..]);
            self.buf.items.len = remaining;
            if (owned) |s| {
                defer self.alloc.free(s);
                try on_sentence(ctx, s);
            }
        }
    }

    pub fn finish(
        self: *SentenceChunker,
        ctx: *anyopaque,
        on_sentence: *const fn (ctx: *anyopaque, sentence: []const u8) anyerror!void,
    ) !void {
        const rest = std.mem.trim(u8, self.buf.items, " \t\n\r");
        if (rest.len > 0) try on_sentence(ctx, rest);
        self.buf.clearRetainingCapacity();
    }
};

pub const LegStatus = enum { ran, cached, unavailable, skipped };

/// The outcome of one conversation turn. All strings are owned;
/// free with `deinit`.
pub const TurnResult = struct {
    transcript: []const u8,
    reply: []const u8,
    /// The reply cut short by a barge-in, if any.
    partial_reply: ?[]const u8 = null,
    /// What the user said to interrupt, if any.
    interrupt_text: ?[]const u8 = null,
    asr: LegStatus = .skipped,
    brain: LegStatus = .skipped,
    tts: LegStatus = .skipped,
    /// Pulse knowledge leg: .ran = knowledge fetched and injected
    /// into the prompt; .unavailable = Pulse unreachable or had
    /// nothing on the question (the turn still ran, without
    /// knowledge); .skipped = Pulse disabled, or the turn did not
    /// ask anything knowledge-needing.
    pulse: LegStatus = .skipped,
    /// Short note about the Pulse leg, when there is one to tell:
    /// e.g. "Pulse: 2 sources, confidence 0.82", or the reason
    /// knowledge was not used.
    pulse_note: ?[]const u8 = null,
    /// The Pulse context injected into this turn's prompt (owned),
    /// when there was one. Kept so the caller can show or log what
    /// the brain actually saw.
    pulse_context: ?[]const u8 = null,
    sentences_spoken: u32 = 0,
    sentences_from_cache: u32 = 0,
    sentences_skipped: u32 = 0,
    /// TTS audio deliveries that failed (e.g. the WAV writer).
    tts_out_errors: u32 = 0,
    barged_in: bool = false,

    pub fn deinit(self: *TurnResult, alloc: std.mem.Allocator) void {
        alloc.free(self.transcript);
        alloc.free(self.reply);
        if (self.partial_reply) |p| alloc.free(p);
        if (self.interrupt_text) |t| alloc.free(t);
        if (self.pulse_note) |n| alloc.free(n);
        if (self.pulse_context) |c| alloc.free(c);
        self.* = undefined;
    }
};

/// Poll for an interruption. Returns the interrupting user text
/// (borrowed — the conversation copies it at once) or null when
/// nobody spoke. Called after each spoken sentence while a reply
/// is streaming; at most one interruption is consumed per turn.
pub const InterruptFn = *const fn (ctx: *anyopaque) ?[]const u8;

/// Delivered TTS audio for one sentence (from cache or a live
/// session). The handler owns the file/buffer decision; an error
/// is recorded, never fatal to the turn.
pub const TtsAudioFn = *const fn (
    ctx: *anyopaque,
    sentence: []const u8,
    samples: []const f32,
    sample_rate: u32,
    channels: u8,
) anyerror!void;

pub const Stats = struct {
    turns: u64 = 0,
    barge_ins: u64 = 0,
};

/// The conversation: session + brain + optional ASR/TTS sessions
/// and cache. ASR/TTS sessions and the cache are borrowed (the
/// engine owns them); the brain is borrowed too (the caller owns
/// the concrete brain struct and calls its `deinit`).
pub const Conversation = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    session: Session,
    brain: brain.Brain,
    asr: ?*runtime.Session = null,
    tts: ?*runtime.Session = null,
    cache: ?*cache.SmartCache = null,
    /// Optional Pulse client for knowledge. Borrowed (the caller
    /// owns it); null = no Pulse integration for this
    /// conversation. When set and enabled, a turn that asks
    /// something knowledge-needing consults Pulse first.
    pulse: ?*pulse.PulseClient = null,
    sample_rate: u32 = 24000,
    /// Turn-end probability at or above this counts as "reply now".
    turn_end_threshold: f32 = 0.6,
    /// Brain chunks are echoed here as they arrive (CLI live view).
    echo: ?*std.Io.Writer = null,
    interrupt_fn: ?InterruptFn = null,
    interrupt_ctx: ?*anyopaque = null,
    on_tts_audio: ?TtsAudioFn = null,
    tts_audio_ctx: ?*anyopaque = null,
    stats: Stats = .{},

    // Per-turn working state.
    reply_buf: std.ArrayList(u8) = .empty,
    chunker: SentenceChunker,
    streaming: bool = false,
    cancel_requested: bool = false,
    interrupt_consumed: bool = false,
    interrupt_text_owned: ?[]const u8 = null,
    turn_spoken: u32 = 0,
    turn_from_cache: u32 = 0,
    turn_skipped: u32 = 0,
    turn_tts_errors: u32 = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        brain_value: brain.Brain,
        voice: []const u8,
        language: []const u8,
    ) !Conversation {
        return .{
            .alloc = alloc,
            .io = io,
            .session = try Session.init(alloc, io, voice, language),
            .brain = brain_value,
            .chunker = SentenceChunker.init(alloc),
        };
    }

    pub fn deinit(self: *Conversation) void {
        self.chunker.deinit();
        self.reply_buf.deinit(self.alloc);
        if (self.interrupt_text_owned) |t| self.alloc.free(t);
        self.session.deinit();
        self.* = undefined;
    }

    /// Turn-taking decision: ReflexEngine's turn-end probability
    /// against this conversation's threshold.
    pub fn shouldReply(
        self: *const Conversation,
        silence_ms: u32,
        threshold_ms: u32,
        partial_text: []const u8,
        last_word_stable: bool,
    ) bool {
        return reflex.turnEndProbability(silence_ms, threshold_ms, partial_text, last_word_stable) >= self.turn_end_threshold;
    }

    fn resetTurnState(self: *Conversation) void {
        self.cancel_requested = false;
        self.interrupt_consumed = false;
        if (self.interrupt_text_owned) |t| {
            self.alloc.free(t);
            self.interrupt_text_owned = null;
        }
        self.turn_spoken = 0;
        self.turn_from_cache = 0;
        self.turn_skipped = 0;
        self.turn_tts_errors = 0;
    }

    /// Reset only the interruption state for a follow-up brain call
    /// after a barge-in. The sentence counters keep accumulating:
    /// the result reports the whole turn, interrupted leg included.
    fn resetForFollowUp(self: *Conversation) void {
        self.cancel_requested = false;
        self.interrupt_consumed = false;
        if (self.interrupt_text_owned) |t| {
            self.alloc.free(t);
            self.interrupt_text_owned = null;
        }
    }

    fn finishTurnStats(self: *const Conversation, result: *TurnResult) void {
        result.sentences_spoken = self.turn_spoken;
        result.sentences_from_cache = self.turn_from_cache;
        result.sentences_skipped = self.turn_skipped;
        result.tts_out_errors = self.turn_tts_errors;
        result.tts = if (self.turn_spoken == 0 and self.turn_skipped == 0)
            .skipped
        else if (self.turn_skipped > 0 and self.turn_spoken == 0)
            .unavailable
        else if (self.turn_from_cache > 0 and self.turn_from_cache == self.turn_spoken)
            .cached
        else
            .ran;
    }

    /// Speak one sentence: cache first (no model needed), else the
    /// TTS session, else count it as skipped. Audio is delivered
    /// through `on_tts_audio` when set.
    fn speakSentence(self: *Conversation, sentence: []const u8) !void {
        if (self.cache) |c| {
            if (try c.getTts(self.session.voice, self.session.language, "conversation", sentence)) |hit| {
                self.turn_spoken += 1;
                self.turn_from_cache += 1;
                if (self.on_tts_audio) |f| {
                    f(self.tts_audio_ctx.?, sentence, hit.samples, hit.sample_rate, hit.channels) catch {
                        self.turn_tts_errors += 1;
                    };
                }
                return;
            }
        }
        const tts = self.tts orelse {
            self.turn_skipped += 1;
            return;
        };
        var ref_wav = runtime.loadReferenceWav(self.alloc, self.io, self.session.reference_wav);
        defer if (ref_wav) |*w| w.deinit(self.alloc);
        const req = runtime.Request{
            .task = .tts,
            .mode = .offline,
            .text = sentence,
            .language = self.session.language,
            .voice = self.session.voice,
            .reference_audio = if (ref_wav) |w| w.samples else null,
            .reference_rate = if (ref_wav) |w| w.sample_rate else 24000,
            .reference_channels = if (ref_wav) |w| w.channels else 1,
            .reference_text = self.session.reference_text,
        };
        var resp = try tts.run(self.io, self.alloc, req);
        defer resp.deinit();
        const a = try resp.audio();
        if (self.cache) |c| {
            try c.putTts(self.session.voice, self.session.language, "conversation", sentence, a.samples, a.sample_rate, a.channels);
        }
        if (self.on_tts_audio) |f| {
            f(self.tts_audio_ctx.?, sentence, a.samples, a.sample_rate, a.channels) catch {
                self.turn_tts_errors += 1;
            };
        }
        self.turn_spoken += 1;
    }

    /// One sentence closed while the brain streams: speak it, then
    /// poll for an interruption. The poll runs only while the brain
    /// is still streaming (never on the final flush), so an
    /// interruption can only fire mid-reply.
    fn onSentence(ctx: *anyopaque, sentence: []const u8) anyerror!void {
        const self: *Conversation = @ptrCast(@alignCast(ctx));
        try self.speakSentence(sentence);
        if (!self.streaming) return;
        if (self.interrupt_fn) |f| {
            if (!self.interrupt_consumed) {
                if (f(self.interrupt_ctx.?)) |text| {
                    self.interrupt_consumed = true;
                    self.interrupt_text_owned = try self.alloc.dupe(u8, text);
                    self.cancel_requested = true;
                    return error.Cancelled;
                }
            }
        }
    }

    /// One brain chunk: accumulate it, echo it, feed the sentence
    /// chunker. Returns `error.Cancelled` when a barge-in fired.
    fn onBrainChunk(ctx: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *Conversation = @ptrCast(@alignCast(ctx));
        if (self.cancel_requested) return error.Cancelled;
        try self.reply_buf.appendSlice(self.alloc, chunk);
        if (self.echo) |w| {
            try w.writeAll(chunk);
            try w.flush();
        }
        try self.chunker.feed(chunk, self, onSentence);
    }

    /// Stream the brain's reply for `prompt` and speak its
    /// sentences as they arrive. Returns the full reply text
    /// (owned). `error.Cancelled` leaves the partial reply in
    /// `reply_buf` for the caller to keep.
    fn runBrain(self: *Conversation, prompt: []const u8) ![]const u8 {
        self.reply_buf.clearRetainingCapacity();
        self.chunker.deinit();
        self.chunker = SentenceChunker.init(self.alloc);
        self.streaming = true;
        defer self.streaming = false;
        const returned = try self.brain.reply(
            self.alloc,
            self.io,
            prompt,
            &self.cancel_requested,
            self,
            onBrainChunk,
        );
        // The brain is done: the final flush must not poll for an
        // interruption (the reply is already complete).
        self.streaming = false;
        defer self.alloc.free(returned);
        // A non-streaming brain never called on_chunk: run its whole
        // reply through the chunker so its sentences still speak, and
        // keep the text — without this the caller records an empty
        // reply even though the brain answered.
        if (self.reply_buf.items.len == 0 and returned.len > 0) {
            try self.chunker.feed(returned, self, onSentence);
            try self.reply_buf.appendSlice(self.alloc, returned);
        }
        try self.chunker.finish(self, onSentence);
        return try self.alloc.dupe(u8, self.reply_buf.items);
    }

    /// Consult Pulse for the current turn when it asks something
    /// knowledge-needing. On success with usable knowledge the
    /// context is set on the session (so renderPrompt carries it)
    /// and recorded on the result; on any failure the turn
    /// proceeds without knowledge and the result says so plainly.
    /// Never blocks the conversation on Pulse, never fakes an
    /// answer.
    fn fetchPulseKnowledge(self: *Conversation, result: *TurnResult, trimmed: []const u8) !void {
        const client = self.pulse orelse return;
        if (!client.enabled) return;
        const needs = pulse.needsKnowledge(self.alloc, trimmed) catch return;
        if (!needs) return;
        const maybe_knowledge = client.query(self.alloc, self.io, trimmed) catch |err| {
            result.pulse = .unavailable;
            result.pulse_note = try std.fmt.allocPrint(self.alloc, "Pulse unreachable ({t}) — answered without knowledge", .{err});
            return;
        };
        var k = maybe_knowledge orelse return; // disabled between checks
        defer k.deinit(self.alloc);
        if (!k.usable()) {
            result.pulse = .unavailable;
            result.pulse_note = try self.alloc.dupe(u8, "Pulse had nothing on that — answered without knowledge");
            return;
        }
        const context = try pulse.formatKnowledge(self.alloc, &k);
        defer self.alloc.free(context);
        try self.session.setKnowledgeContext(context);
        result.pulse = .ran;
        const plural: []const u8 = if (k.sources.len == 1) "" else "s";
        result.pulse_note = try std.fmt.allocPrint(self.alloc, "Pulse: {d} source{s}, confidence {d:.2}", .{ k.sources.len, plural, k.confidence });
        result.pulse_context = try self.alloc.dupe(u8, context);
    }

    /// One text turn: user text in, brain reply out, sentences
    /// spoken (or honestly skipped) as the reply streams. A
    /// barge-in mid-reply cancels the remaining sentences, keeps
    /// the partial reply in history, and answers the interruption
    /// as a new turn — context is preserved.
    pub fn processText(self: *Conversation, user_text: []const u8) !TurnResult {
        const trimmed = std.mem.trim(u8, user_text, " \t\n\r");
        var result = TurnResult{
            .transcript = try self.alloc.dupe(u8, user_text),
            .reply = try self.alloc.dupe(u8, ""),
        };
        errdefer result.deinit(self.alloc);
        if (trimmed.len == 0) return result;

        try self.session.appendTurn(.user, trimmed);
        // Pulse knowledge, consulted FIRST when the turn asks
        // something knowledge-needing. The context is cleared when
        // the turn ends (the defer below) so it never leaks into a
        // later turn — but it stays set for the barge-in follow-up,
        // which re-renders the prompt before this returns.
        defer self.session.clearKnowledgeContext();
        try self.fetchPulseKnowledge(&result, trimmed);
        const prompt = try self.session.renderPrompt(self.alloc);
        defer self.alloc.free(prompt);
        self.resetTurnState();
        const reply = self.runBrain(prompt) catch |err| {
            if (err != error.Cancelled) return err;
            // Interrupted mid-reply.
            const partial = try self.alloc.dupe(u8, self.reply_buf.items);
            result.partial_reply = partial;
            result.barged_in = true;
            result.brain = .ran;
            self.stats.barge_ins += 1;
            if (self.interrupt_text_owned) |it| {
                result.interrupt_text = try self.alloc.dupe(u8, it);
            }
            if (partial.len > 0) try self.session.appendTurn(.assistant, partial);
            if (result.interrupt_text) |it| {
                try self.session.appendTurn(.user, it);
                const follow_prompt = try self.session.renderPrompt(self.alloc);
                defer self.alloc.free(follow_prompt);
                self.resetForFollowUp();
                // Mark the follow-up in the live echo: without this the
                // follow-up's chunks stream onto the same line as the
                // cut-off reply ("Hello!Why did...").
                if (self.echo) |w| w.print("\n[Sando, after interruption] ", .{}) catch {};
                const follow = try self.runBrain(follow_prompt);
                try self.session.appendTurn(.assistant, follow);
                self.alloc.free(result.reply);
                result.reply = follow;
                result.brain = .ran;
            }
            self.finishTurnStats(&result);
            self.stats.turns += 1;
            return result;
        };
        try self.session.appendTurn(.assistant, reply);
        self.alloc.free(result.reply);
        result.reply = reply;
        result.brain = .ran;
        self.finishTurnStats(&result);
        self.stats.turns += 1;
        return result;
    }

    /// One audio turn: transcribe (cache first, else the ASR
    /// session), then run the text turn. Empty audio yields an
    /// empty transcript and no brain call.
    pub fn processAudio(
        self: *Conversation,
        samples: []const f32,
        sample_rate: u32,
        channels: u8,
    ) !TurnResult {
        var owned: ?[]const u8 = null;
        var asr_status: LegStatus = .skipped;
        if (self.cache) |c| {
            if (try c.getAsr(self.session.language, samples)) |cached| {
                owned = try self.alloc.dupe(u8, cached);
                asr_status = .cached;
            }
        }
        if (owned == null) {
            const asr = self.asr orelse {
                return TurnResult{
                    .transcript = try self.alloc.dupe(u8, ""),
                    .reply = try self.alloc.dupe(u8, ""),
                    .asr = .unavailable,
                };
            };
            const req = runtime.Request{
                .task = .asr,
                .mode = .offline,
                .audio = samples,
                .sample_rate = sample_rate,
                .channels = channels,
                .language = self.session.language,
            };
            var resp = try asr.run(self.io, self.alloc, req);
            defer resp.deinit();
            const t = try resp.text();
            owned = try self.alloc.dupe(u8, t.text);
            asr_status = .ran;
            if (self.cache) |c| {
                try c.putAsr(self.session.language, samples, owned.?);
            }
        }
        const transcript = owned.?;
        defer self.alloc.free(transcript);
        var result = try self.processText(transcript);
        result.asr = asr_status;
        return result;
    }
};

test "session history evicts the oldest turn first" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, std.testing.io, "v1", "en");
    defer session.deinit();
    session.max_turns = 4;
    try session.appendTurn(.user, "one");
    try session.appendTurn(.assistant, "two");
    try session.appendTurn(.user, "three");
    try session.appendTurn(.assistant, "four");
    try session.appendTurn(.user, "five");
    try std.testing.expectEqual(@as(usize, 4), session.turnCount());
    try std.testing.expectEqualStrings("two", session.history.items[0].text);
    try std.testing.expectEqualStrings("five", session.history.items[3].text);
    try std.testing.expectEqual(@as(usize, 16), session.id.len);
}

test "session prompt carries the persona by default" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, std.testing.io, "v1", "en");
    defer session.deinit();
    try session.appendTurn(.user, "hello");
    const prompt = try session.renderPrompt(alloc);
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Talk like a real person") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Liberian English") != null);
    try std.testing.expect(!persona.containsBannedPhrase(prompt));
}

test "session prompt override replaces the persona" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, std.testing.io, "v1", "en");
    defer session.deinit();
    session.system_prompt = "You are a pirate. Answer like a pirate.";
    try session.appendTurn(.user, "hello");
    const prompt = try session.renderPrompt(alloc);
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "You are a pirate") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Talk like a real person") == null);
}

test "session prompt renders history with roles" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, std.testing.io, "v1", "en");
    defer session.deinit();
    try session.appendTurn(.user, "hello");
    try session.appendTurn(.assistant, "hi there");
    try session.appendTurn(.user, "what can you do");
    const prompt = try session.renderPrompt(alloc);
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "User: hello\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Assistant: hi there\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "User: what can you do\nAssistant:"));
}

test "split sentences at terminators, long runs, and the tail" {
    const alloc = std.testing.allocator;
    const parts = try splitSentences(alloc, "Hello world. How are you? Fine!");
    defer {
        for (parts) |p| alloc.free(p);
        alloc.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("Hello world.", parts[0]);
    try std.testing.expectEqualStrings("How are you?", parts[1]);
    try std.testing.expectEqualStrings("Fine!", parts[2]);

    const tail = try splitSentences(alloc, "No terminator here");
    defer {
        for (tail) |p| alloc.free(p);
        alloc.free(tail);
    }
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqualStrings("No terminator here", tail[0]);

    // A 250-char run without a terminator splits at a space.
    var long_buf: [260]u8 = undefined;
    @memset(&long_buf, 'a');
    long_buf[100] = ' ';
    long_buf[201] = ' ';
    const long_parts = try splitSentences(alloc, long_buf[0..250]);
    defer {
        for (long_parts) |p| alloc.free(p);
        alloc.free(long_parts);
    }
    try std.testing.expect(long_parts.len >= 2);
    try std.testing.expect(long_parts[0].len <= max_sentence_chars + 1);
}

test "sentence chunker emits sentences incrementally" {
    const alloc = std.testing.allocator;
    var chunker = SentenceChunker.init(alloc);
    defer chunker.deinit();
    const Ctx = struct {
        alloc: std.mem.Allocator,
        got: std.ArrayList([]const u8),
        fn onSentence(ctx: *anyopaque, sentence: []const u8) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            try c.got.append(c.alloc, try c.alloc.dupe(u8, sentence));
        }
    };
    var ctx = Ctx{ .alloc = alloc, .got = std.ArrayList([]const u8).empty };
    defer {
        for (ctx.got.items) |s| alloc.free(s);
        ctx.got.deinit(alloc);
    }
    // Split mid-word across feeds: no sentence until the terminator.
    try chunker.feed("Hello wo", &ctx, Ctx.onSentence);
    try std.testing.expectEqual(@as(usize, 0), ctx.got.items.len);
    try chunker.feed("rld. How are", &ctx, Ctx.onSentence);
    try std.testing.expectEqual(@as(usize, 1), ctx.got.items.len);
    try std.testing.expectEqualStrings("Hello world.", ctx.got.items[0]);
    try chunker.feed(" you?", &ctx, Ctx.onSentence);
    try chunker.finish(&ctx, Ctx.onSentence);
    try std.testing.expectEqual(@as(usize, 2), ctx.got.items.len);
    try std.testing.expectEqualStrings("How are you?", ctx.got.items[1]);
}

test "text turn: mock brain replies, history grows, tts honestly skipped" {
    const alloc = std.testing.allocator;
    var mock = brain.MockBrain{};
    var conv = try Conversation.init(alloc, std.testing.io, mock.asBrain(), "v1", "en");
    defer conv.deinit();
    var result = try conv.processText("hello");
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, result.reply, "Good to hear you") != null);
    try std.testing.expect(result.brain == .ran);
    // The greeting is 3 sentences; with no TTS session every one
    // is honestly skipped, never faked.
    try std.testing.expect(result.tts == .unavailable);
    try std.testing.expectEqual(@as(u32, 3), result.sentences_skipped);
    try std.testing.expectEqual(@as(usize, 2), conv.session.turnCount());
    try std.testing.expectEqual(@as(u64, 1), conv.stats.turns);
}

test "empty text turn calls no brain" {
    const alloc = std.testing.allocator;
    var mock = brain.MockBrain{};
    var conv = try Conversation.init(alloc, std.testing.io, mock.asBrain(), "v1", "en");
    defer conv.deinit();
    var result = try conv.processText("   ");
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("", result.reply);
    try std.testing.expect(result.brain == .skipped);
    try std.testing.expectEqual(@as(usize, 0), conv.session.turnCount());
}

test "tts cache hit speaks without any session" {
    const alloc = std.testing.allocator;
    var smart_cache = cache.SmartCache.init(alloc, 1 << 20);
    defer smart_cache.deinit();
    const samples = [_]f32{ 0.1, 0.2, 0.3 };
    // Pre-populate all three sentences of the mock greeting.
    try smart_cache.putTts("v1", "en", "conversation", "Hey!", &samples, 24000, 1);
    try smart_cache.putTts("v1", "en", "conversation", "Good to hear you.", &samples, 24000, 1);
    try smart_cache.putTts("v1", "en", "conversation", "What's going on?", &samples, 24000, 1);

    var mock = brain.MockBrain{};
    var conv = try Conversation.init(alloc, std.testing.io, mock.asBrain(), "v1", "en");
    defer conv.deinit();
    conv.cache = &smart_cache;
    var result = try conv.processText("hello");
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 3), result.sentences_spoken);
    try std.testing.expectEqual(@as(u32, 3), result.sentences_from_cache);
    try std.testing.expectEqual(@as(u32, 0), result.sentences_skipped);
    try std.testing.expect(result.tts == .cached);
}

test "barge-in cancels the reply and answers the interruption" {
    const alloc = std.testing.allocator;
    // A brain with a long multi-sentence reply.
    const LongBrain = struct {
        fn replyFn(
            ptr: *anyopaque,
            cb_alloc: std.mem.Allocator,
            prompt: []const u8,
            chunk_ctx: *anyopaque,
            on_chunk: brain.ChunkFn,
        ) anyerror![]const u8 {
            _ = ptr;
            _ = prompt;
            const text = "First sentence here. Second sentence here. Third sentence here. Fourth sentence here.";
            var it = std.mem.splitScalar(u8, text, ' ');
            var first = true;
            while (it.next()) |word| {
                if (first) {
                    try on_chunk(chunk_ctx, word);
                    first = false;
                } else {
                    const piece = try std.fmt.allocPrint(cb_alloc, " {s}", .{word});
                    defer cb_alloc.free(piece);
                    try on_chunk(chunk_ctx, piece);
                }
            }
            return try cb_alloc.dupe(u8, text);
        }
    };
    var dummy: u8 = 0;
    var long_agent = brain.AgentBrain{ .ctx = &dummy, .callback = LongBrain.replyFn };
    // Interrupt provider: returns text on the first poll, null after.
    const Provider = struct {
        polls: u32 = 0,
        fn poll(ctx: *anyopaque) ?[]const u8 {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.polls += 1;
            if (p.polls == 1) return "tell me a joke instead";
            return null;
        }
    };
    var provider = Provider{};
    var conv = try Conversation.init(alloc, std.testing.io, long_agent.asBrain(), "v1", "en");
    defer conv.deinit();
    conv.interrupt_fn = Provider.poll;
    conv.interrupt_ctx = &provider;
    var result = try conv.processText("what can you do");
    defer result.deinit(alloc);
    try std.testing.expect(result.barged_in);
    try std.testing.expectEqualStrings("tell me a joke instead", result.interrupt_text.?);
    try std.testing.expect(result.partial_reply != null);
    try std.testing.expect(std.mem.indexOf(u8, result.partial_reply.?, "First sentence") != null);
    // The follow-up reply is the brain's answer to the interruption.
    try std.testing.expect(result.reply.len > 0);
    // Context survived: user turn, partial assistant, interrupt user, follow-up assistant.
    try std.testing.expectEqual(@as(usize, 4), conv.session.turnCount());
    try std.testing.expectEqualStrings("tell me a joke instead", conv.session.history.items[2].text);
    try std.testing.expectEqual(@as(u64, 1), conv.stats.barge_ins);
}

test "shouldReply follows the reflex turn-end probability" {
    const alloc = std.testing.allocator;
    var mock = brain.MockBrain{};
    var conv = try Conversation.init(alloc, std.testing.io, mock.asBrain(), "v1", "en");
    defer conv.deinit();
    try std.testing.expect(!conv.shouldReply(0, 600, "", false));
    try std.testing.expect(conv.shouldReply(600, 600, "", false));
    try std.testing.expect(conv.shouldReply(200, 600, "hello world.", false));
}

test "audio turn without an asr session reports unavailable" {
    const alloc = std.testing.allocator;
    var mock = brain.MockBrain{};
    var conv = try Conversation.init(alloc, std.testing.io, mock.asBrain(), "v1", "en");
    defer conv.deinit();
    const samples = blk: {
        var s: [100]f32 = undefined;
        @memset(&s, 0);
        break :blk s;
    };
    var result = try conv.processAudio(&samples, 24000, 1);
    defer result.deinit(alloc);
    try std.testing.expect(result.asr == .unavailable);
    try std.testing.expectEqualStrings("", result.reply);
}

test "session prompt carries pulse knowledge when set, clears after" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, std.testing.io, "v1", "en");
    defer session.deinit();
    try session.appendTurn(.user, "hello");
    const plain = try session.renderPrompt(alloc);
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Sando Pulse") == null);

    try session.setKnowledgeContext("Knowledge from Sando Pulse (2 sources, confidence 0.82):\n- Road blocked (Paper): ...");
    const with_knowledge = try session.renderPrompt(alloc);
    defer alloc.free(with_knowledge);
    try std.testing.expect(std.mem.indexOf(u8, with_knowledge, "Knowledge from Sando Pulse (may be incomplete") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_knowledge, "Road blocked") != null);
    // Knowledge sits between the persona and the history.
    const kb_pos = std.mem.indexOf(u8, with_knowledge, "Road blocked").?;
    const user_pos = std.mem.indexOf(u8, with_knowledge, "User: hello").?;
    try std.testing.expect(kb_pos < user_pos);

    session.clearKnowledgeContext();
    const cleared = try session.renderPrompt(alloc);
    defer alloc.free(cleared);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "Road blocked") == null);
}

/// Minimal Pulse /v1/query body for the conversation tests.
const pulse_query_fixture =
    \\{"query":"roads","answer":"Several reports describe road closures.","sufficient":true,"confidence":0.82,"results":[{"title":"Road blocked in Sinkor","summary":"A road in Sinkor has been blocked since this morning.","url":"https://example.com/road","source":{"name":"FrontPage Africa","url":"https://example.com"},"published_at":"2026-11-15T08:00:00Z","score":0.91}],"events":[],"meta":{"request_id":"r1","results_count":1,"sources_checked":9}}
;

/// A brain that captures the prompt it received and answers "noted."
const CaptureBrain = struct {
    prompt_seen: ?[]const u8 = null,
    alloc: std.mem.Allocator,

    fn callback(ctx: *anyopaque, cb_alloc: std.mem.Allocator, prompt: []const u8, chunk_ctx: *anyopaque, on_chunk: brain.ChunkFn) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.prompt_seen) |p| cb_alloc.free(p);
        self.prompt_seen = try cb_alloc.dupe(u8, prompt);
        // Stream the reply the way a real host brain does: the
        // chunks are what the conversation records and speaks.
        try on_chunk(chunk_ctx, "noted.");
        return try cb_alloc.dupe(u8, "noted.");
    }
};

test "text turn injects pulse knowledge into the brain prompt" {
    const alloc = std.testing.allocator;
    var sender = pulse.TestSender{ .chunks = &.{pulse_query_fixture} };
    defer sender.deinit(alloc);
    var client = pulse.PulseClient.init("http://127.0.0.1:9000", true, sender.asSender());
    var capture = CaptureBrain{ .alloc = alloc };
    defer if (capture.prompt_seen) |p| alloc.free(p);
    var agent = brain.AgentBrain{ .ctx = &capture, .callback = CaptureBrain.callback };
    var conv = try Conversation.init(alloc, std.testing.io, agent.asBrain(), "v1", "en");
    defer conv.deinit();
    conv.pulse = &client;

    var result = try conv.processText("What happened with the roads in Monrovia?");
    defer result.deinit(alloc);
    try std.testing.expect(result.pulse == .ran);
    try std.testing.expect(result.pulse_note != null);
    try std.testing.expect(std.mem.indexOf(u8, result.pulse_note.?, "1 source") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.pulse_note.?, "0.82") != null);
    try std.testing.expect(result.pulse_context != null);
    try std.testing.expect(std.mem.indexOf(u8, result.pulse_context.?, "Road blocked in Sinkor") != null);
    // The brain saw the context: it is in the captured prompt.
    const prompt = capture.prompt_seen.?;
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Knowledge from Sando Pulse") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Road blocked in Sinkor") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "FrontPage Africa") != null);
    try std.testing.expectEqualStrings("noted.", result.reply);
    // The turn is over: the knowledge does not leak into the next prompt.
    const next = try conv.session.renderPrompt(alloc);
    defer alloc.free(next);
    try std.testing.expect(std.mem.indexOf(u8, next, "Road blocked in Sinkor") == null);
}

test "text turn proceeds without knowledge when pulse is unreachable" {
    const alloc = std.testing.allocator;
    var sender = pulse.TestSender{ .chunks = &.{}, .fail = error.ConnectionRefused };
    defer sender.deinit(alloc);
    var client = pulse.PulseClient.init("http://127.0.0.1:9000", true, sender.asSender());
    var capture = CaptureBrain{ .alloc = alloc };
    defer if (capture.prompt_seen) |p| alloc.free(p);
    var agent = brain.AgentBrain{ .ctx = &capture, .callback = CaptureBrain.callback };
    var conv = try Conversation.init(alloc, std.testing.io, agent.asBrain(), "v1", "en");
    defer conv.deinit();
    conv.pulse = &client;

    var result = try conv.processText("What is the latest news?");
    defer result.deinit(alloc);
    // The turn still ran: the brain answered, nothing was faked.
    try std.testing.expectEqualStrings("noted.", result.reply);
    try std.testing.expect(result.pulse == .unavailable);
    try std.testing.expect(result.pulse_note != null);
    try std.testing.expect(std.mem.indexOf(u8, result.pulse_note.?, "unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.prompt_seen.?, "Sando Pulse") == null);
}

test "text turn skips pulse when disabled or not a question" {
    const alloc = std.testing.allocator;
    // Disabled: the sender is never called.
    var sender = pulse.TestSender{ .chunks = &.{pulse_query_fixture} };
    defer sender.deinit(alloc);
    var client = pulse.PulseClient.init("http://127.0.0.1:9000", false, sender.asSender());
    var mock = brain.MockBrain{};
    var conv = try Conversation.init(alloc, std.testing.io, mock.asBrain(), "v1", "en");
    defer conv.deinit();
    conv.pulse = &client;
    var result = try conv.processText("What happened with the roads?");
    defer result.deinit(alloc);
    try std.testing.expect(result.pulse == .skipped);
    try std.testing.expect(sender.url_seen == null);

    // Enabled but a greeting: no knowledge-needing question.
    var sender2 = pulse.TestSender{ .chunks = &.{pulse_query_fixture} };
    defer sender2.deinit(alloc);
    var client2 = pulse.PulseClient.init("http://127.0.0.1:9000", true, sender2.asSender());
    var conv2 = try Conversation.init(alloc, std.testing.io, mock.asBrain(), "v1", "en");
    defer conv2.deinit();
    conv2.pulse = &client2;
    var result2 = try conv2.processText("hello");
    defer result2.deinit(alloc);
    try std.testing.expect(result2.pulse == .skipped);
    try std.testing.expect(sender2.url_seen == null);
}
