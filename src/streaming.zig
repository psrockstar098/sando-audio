//! LiveStream Engine: full-duplex streaming speech.
//!
//! Two simultaneous independent streams: incoming audio (ASR) and
//! outgoing generated audio (TTS). The engine owns the turn state
//! machine (`TurnState`, pure and fully testable) and a `VadTracker`;
//! sessions are owned by the caller and borrowed here, so the engine
//! never outlives the runtime that loaded its models.
//!
//! Barge-in: when the user starts speaking while the engine is
//! speaking, `pushMic` resets the TTS session (output stops at once)
//! and flips the turn back to listening — no session restart.
//! Endpoint detection is adaptive: the base silence threshold comes
//! from the VadTracker; ReflexEngine (reflex.zig) shortens it when
//! the partial transcript looks complete.
//!
//! Live audio devices do not exist on this VM: the engine runs against
//! WAV input + the null device, and the live-device path stays
//! UNVERIFIED (needs Dominic's laptop). A null-device run is never
//! presented as a live-mic run.

const std = @import("std");
const audiocpp = @import("audiocpp.zig");
const runtime = @import("runtime.zig");
const vad = @import("vad.zig");

/// Whose turn it is. Pure — no I/O, no sessions.
pub const TurnState = struct {
    state: enum { listening, speaking } = .listening,
    /// How many times the user has interrupted the engine.
    barge_ins: u64 = 0,
    /// Set by the most recent barge-in; cleared by startSpeaking().
    interrupted: bool = false,

    pub fn isSpeaking(self: *const TurnState) bool {
        return self.state == .speaking;
    }

    pub fn startSpeaking(self: *TurnState) void {
        self.state = .speaking;
        self.interrupted = false;
    }

    pub fn finishSpeaking(self: *TurnState) void {
        self.state = .listening;
    }

    /// The user started speaking. Returns true when that interrupted
    /// the engine's speech (a barge-in); false when already listening.
    pub fn onSpeechStart(self: *TurnState) bool {
        if (self.state != .speaking) return false;
        self.state = .listening;
        self.interrupted = true;
        self.barge_ins += 1;
        return true;
    }

    /// Manual interruption (Stop button, timeout): same as a barge-in
    /// but without a speech event behind it.
    pub fn interrupt(self: *TurnState) bool {
        return self.onSpeechStart();
    }
};

/// One drained stream event, in owned form. Text is the partial (or
/// final) transcript when the event carries one; vad holds the VAD
/// activity events that arrived with it. Free with deinit().
pub const PumpedEvent = struct {
    text: ?[]const u8 = null,
    vad: []audiocpp.VadActivity = &.{},
    is_final: bool = false,

    pub fn deinit(self: *PumpedEvent, alloc: std.mem.Allocator) void {
        if (self.text) |t| alloc.free(t);
        alloc.free(self.vad);
        self.* = undefined;
    }
};

/// Pushes audio chunks through one streaming session and drains its
/// event queue into owned PumpedEvents.
pub const StreamPump = struct {
    session: *runtime.Session,

    /// Push one chunk; returns the events the backend produced for
    /// it (possibly empty). The caller frees every event and the
    /// returned slice.
    pub fn push(
        self: *StreamPump,
        alloc: std.mem.Allocator,
        samples: []const f32,
        sample_rate: u32,
        channels: u8,
        start_sample: i64,
    ) ![]PumpedEvent {
        var out: std.ArrayList(PumpedEvent) = .empty;
        errdefer {
            for (out.items) |*ev| ev.deinit(alloc);
            out.deinit(alloc);
        }
        const first = try self.session.streamPush(samples, sample_rate, channels, start_sample);
        if (first) |ev| try out.append(alloc, try fromEvent(alloc, ev));
        while (try self.session.streamNextEvent()) |ev| {
            try out.append(alloc, try fromEvent(alloc, ev));
        }
        return out.toOwnedSlice(alloc);
    }

    /// The chunk schedule the family wants (chunk_samples <= 0 means
    /// the family did not specify one).
    pub fn policy(self: *StreamPump) !audiocpp.StreamPolicy {
        return self.session.streamPolicy();
    }
};

/// Convert one backend event into an owned PumpedEvent, freeing the
/// backend event. Text and VAD activity are copied out first: both
/// borrow from the event/result and die with it.
fn fromEvent(alloc: std.mem.Allocator, event: *audiocpp.EventHandle) !PumpedEvent {
    var pumped = PumpedEvent{ .is_final = audiocpp.eventIsFinal(event) };
    errdefer pumped.deinit(alloc);
    const result = audiocpp.eventAsResult(event);
    if (audiocpp.textOf(result)) |t| {
        pumped.text = try alloc.dupe(u8, t.text);
    } else |_| {}
    const acts = try audiocpp.eventVoiceActivity(event, alloc);
    defer alloc.free(acts);
    pumped.vad = try alloc.dupe(audiocpp.VadActivity, acts);
    audiocpp.eventFree(event);
    return pumped;
}

/// The full-duplex engine: one ASR stream in, one TTS stream out.
pub const LiveStream = struct {
    alloc: std.mem.Allocator,
    asr: *runtime.Session,
    tts: ?*runtime.Session,
    tracker: vad.VadTracker,
    turn: TurnState = .{},
    sample_rate: u32,
    /// Stream offset in samples (mono frames) pushed so far.
    pushed_samples: i64 = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        asr: *runtime.Session,
        tts: ?*runtime.Session,
        sample_rate: u32,
    ) LiveStream {
        return .{
            .alloc = alloc,
            .asr = asr,
            .tts = tts,
            .tracker = vad.VadTracker.init(alloc, sample_rate),
            .sample_rate = sample_rate,
        };
    }

    pub fn deinit(self: *LiveStream) void {
        self.tracker.deinit();
        self.* = undefined;
    }

    pub fn bargeInCount(self: *const LiveStream) u64 {
        return self.turn.barge_ins;
    }

    /// Push microphone audio. Feeds VAD activity into the tracker and
    /// barges in (stops TTS output at once) when the user speaks over
    /// the engine. Returns the drained events; the caller frees them.
    pub fn pushMic(
        self: *LiveStream,
        samples: []const f32,
        sample_rate: u32,
        channels: u8,
    ) ![]PumpedEvent {
        var pump = StreamPump{ .session = self.asr };
        const events = try pump.push(self.alloc, samples, sample_rate, channels, self.pushed_samples);
        self.pushed_samples += @intCast(samples.len / @as(usize, channels));
        errdefer {
            for (events) |*ev| ev.deinit(self.alloc);
            self.alloc.free(events);
        }
        for (events) |ev| {
            for (ev.vad) |act| {
                const was_speaking = self.turn.isSpeaking();
                try self.tracker.feed(act);
                if (act.kind == .speech_start and was_speaking) {
                    if (self.turn.onSpeechStart()) {
                        // Barge-in: stop TTS output immediately.
                        if (self.tts) |tts| {
                            tts.streamReset() catch {};
                        }
                    }
                }
            }
        }
        return events;
    }

    /// Start speaking `text` on the TTS stream. No-op when no TTS
    /// session is attached (ASR-only engine).
    pub fn speak(self: *LiveStream, text: []const u8, language: ?[]const u8) !void {
        const tts = self.tts orelse return;
        const req = runtime.Request{
            .task = .tts,
            .mode = .streaming,
            .text = text,
            .language = language,
        };
        try tts.streamStart(self.alloc, req);
        self.turn.startSpeaking();
    }

    /// Stop speaking (manual interrupt). Resets the TTS stream.
    pub fn stopSpeaking(self: *LiveStream) !void {
        if (self.tts) |tts| try tts.streamReset();
        self.turn.finishSpeaking();
    }

    /// True when the user has been silent long enough to count the
    /// turn as ended. `now_sample` is the current stream offset.
    pub fn endpointDetected(self: *const LiveStream, now_sample: i64) bool {
        return self.tracker.endpointDetected(now_sample);
    }
};

test "turn state: barge-in only while speaking" {
    var turn = TurnState{};
    try std.testing.expect(!turn.isSpeaking());
    try std.testing.expect(!turn.onSpeechStart()); // listening: no barge-in
    try std.testing.expectEqual(@as(u64, 0), turn.barge_ins);
    turn.startSpeaking();
    try std.testing.expect(turn.isSpeaking());
    try std.testing.expect(turn.onSpeechStart()); // barge-in
    try std.testing.expect(!turn.isSpeaking());
    try std.testing.expect(turn.interrupted);
    try std.testing.expectEqual(@as(u64, 1), turn.barge_ins);
    // Second speech start while listening is not a barge-in.
    try std.testing.expect(!turn.onSpeechStart());
    try std.testing.expectEqual(@as(u64, 1), turn.barge_ins);
    turn.startSpeaking();
    try std.testing.expect(!turn.interrupted);
    try std.testing.expect(turn.interrupt());
    try std.testing.expectEqual(@as(u64, 2), turn.barge_ins);
    turn.finishSpeaking();
    try std.testing.expect(!turn.isSpeaking());
}

test "pumped event deinit frees owned fields" {
    const alloc = std.testing.allocator;
    var ev = PumpedEvent{
        .text = try alloc.dupe(u8, "hello"),
        .vad = try alloc.alloc(audiocpp.VadActivity, 1),
        .is_final = true,
    };
    ev.vad[0] = .{ .kind = .speech_start, .sample = 0, .probability = 0.9 };
    ev.deinit(alloc);
}
