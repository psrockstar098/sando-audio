//! ReflexEngine: speculative scheduling for the LiveStream Engine.
//!
//! - Probable turn-end detection: a 0..1 probability from the VAD
//!   silence fraction plus the partial transcript (terminal
//!   punctuation and a stable last word raise it). This is a
//!   HEURISTIC, labelled as one — it is not a model score unless the
//!   smart_turn family is linked (see `smartTurnAvailable`).
//! - Speculative TTS prep: given the brain's likely next utterances,
//!   look them up in the SmartCache and report which are already
//!   cached (ready to speak with zero inference). Nothing is generated
//!   speculatively — only cache hits are prepared.
//! - Cancel on interruption: a barge-in discards every pending
//!   speculation and counts it.
//! - Fastest-viable-model selection: pick the smallest loaded model of
//!   a kind from the registry (smallest weights file first). "Fastest"
//!   is a proxy — file size correlates with load time and memory, and
//!   on this hardware with latency too; measured numbers belong in the
//!   bench, not here.

const std = @import("std");
const config = @import("config.zig");
const models = @import("models.zig");
const cache = @import("cache.zig");

/// Whether the smart_turn turn-end family is in the linked set.
/// When false, turn-end comes from the heuristic below.
pub fn smartTurnAvailable(families: []const []const u8) bool {
    for (families) |f| {
        if (std.mem.eql(u8, f, "smart_turn")) return true;
    }
    return false;
}

/// Probable turn-end probability, 0..1 (heuristic).
///
/// `silence_ms` is how long the user has been quiet; `threshold_ms`
/// is the endpoint threshold (VadTracker silence_ms). `partial_text`
/// is the current ASR partial; `last_word_stable` is true when the
/// partial's last word has not changed across the last two events.
pub fn turnEndProbability(
    silence_ms: u32,
    threshold_ms: u32,
    partial_text: []const u8,
    last_word_stable: bool,
) f32 {
    if (threshold_ms == 0) return 1.0;
    var p: f32 = @min(1.0, @as(f32, @floatFromInt(silence_ms)) / @as(f32, @floatFromInt(threshold_ms)));
    const trimmed = std.mem.trim(u8, partial_text, " \t\n\r");
    if (trimmed.len > 0) {
        const last = trimmed[trimmed.len - 1];
        if ((last == '.' or last == '?' or last == '!') and silence_ms >= 200) {
            p = @max(p, 0.7);
        }
        if (last_word_stable and silence_ms >= 200) p = @min(1.0, p + 0.1);
    }
    return p;
}

/// Speculative TTS prep: check the brain's likely next utterances
/// against the SmartCache. `prepared` counts cache hits (ready to
/// speak with zero inference); `cancelled` counts candidates dropped
/// by a barge-in. Candidates are borrowed; nothing is copied.
pub const SpeculativePlanner = struct {
    candidates: []const []const u8 = &.{},
    prepared: u64 = 0,
    cancelled: u64 = 0,

    pub fn setCandidates(self: *SpeculativePlanner, candidates: []const []const u8) void {
        self.candidates = candidates;
    }

    /// Look every candidate up in the cache. Returns the number of
    /// cache hits (utterances ready to speak without inference).
    pub fn prepare(
        self: *SpeculativePlanner,
        tts_cache: *cache.SmartCache,
        voice: []const u8,
        language: []const u8,
        context: []const u8,
    ) !u64 {
        var hits: u64 = 0;
        for (self.candidates) |text| {
            if (try tts_cache.getTts(voice, language, context, text)) |_| {
                hits += 1;
            }
        }
        self.prepared += hits;
        return hits;
    }

    /// Barge-in: drop every pending speculation.
    pub fn cancel(self: *SpeculativePlanner) void {
        self.cancelled += @as(u64, @intCast(self.candidates.len));
        self.candidates = &.{};
    }
};

/// Pick the smallest LOADED model of `kind` from the registry — the
/// fastest viable one by the size proxy. Returns the model name, or
/// null when none of that kind is loaded.
pub fn pickFastestViable(registry: *models.ModelRegistry, kind: config.ModelKind) ?[]const u8 {
    var best: ?*models.ModelRecord = null;
    var it = registry.records.valueIterator();
    while (it.next()) |r| {
        const rec = r.*;
        if (rec.kind != kind or !rec.loaded) continue;
        if (best == null or rec.size_bytes < best.?.size_bytes) best = rec;
    }
    return if (best) |b| b.name else null;
}

test "turn-end probability ramps with silence" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), turnEndProbability(0, 600, "", false), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), turnEndProbability(300, 600, "", false), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), turnEndProbability(900, 600, "", false), 0.001);
}

test "turn-end probability: punctuation and stability boost" {
    // Short silence, complete sentence: at least 0.7.
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), turnEndProbability(200, 600, "hello world.", false), 0.001);
    // Same silence, no punctuation: stays at the silence fraction.
    try std.testing.expectApproxEqAbs(@as(f32, 0.333), turnEndProbability(200, 600, "hello world", false), 0.002);
    // Stable last word adds 0.1.
    try std.testing.expectApproxEqAbs(@as(f32, 0.433), turnEndProbability(200, 600, "hello world", true), 0.002);
    // Empty partial, no boost.
    try std.testing.expectApproxEqAbs(@as(f32, 0.333), turnEndProbability(200, 600, "", true), 0.002);
}

test "speculative planner prepares cache hits and cancels on barge-in" {
    const alloc = std.testing.allocator;
    var tts_cache = cache.SmartCache.init(alloc, 1 << 20);
    defer tts_cache.deinit();
    const samples = [_]f32{ 0.1, 0.2 };
    try tts_cache.putTts("v", "en", "chat", "yes, go ahead", &samples, 24000, 1);
    var planner = SpeculativePlanner{};
    planner.setCandidates(&.{ "yes, go ahead", "let me think", "no, stop" });
    const hits = try planner.prepare(&tts_cache, "v", "en", "chat");
    try std.testing.expectEqual(@as(u64, 1), hits);
    try std.testing.expectEqual(@as(u64, 1), planner.prepared);
    planner.cancel();
    try std.testing.expectEqual(@as(u64, 3), planner.cancelled);
    try std.testing.expectEqual(@as(usize, 0), planner.candidates.len);
}

test "fastest-viable picks the smallest loaded model of the kind" {
    const alloc = std.testing.allocator;
    var registry = models.ModelRegistry.init(alloc, 8, 1 << 34);
    defer registry.deinit();
    _ = try registry.register("big-tts", .tts, "models/big.gguf", 2_000_000_000);
    _ = try registry.register("small-tts", .tts, "models/small.gguf", 300_000_000);
    _ = try registry.register("stt-one", .stt, "models/stt.gguf", 100_000_000);
    try registry.markLoaded("big-tts", true);
    try registry.markLoaded("small-tts", true);
    try std.testing.expectEqualStrings("small-tts", pickFastestViable(&registry, .tts).?);
    try std.testing.expect(pickFastestViable(&registry, .stt) == null); // not loaded
    try registry.markLoaded("stt-one", true);
    try std.testing.expectEqualStrings("stt-one", pickFastestViable(&registry, .stt).?);
    try std.testing.expect(pickFastestViable(&registry, .vad) == null); // none registered
}

test "smart turn availability is a family-list lookup" {
    try std.testing.expect(smartTurnAvailable(&.{ "qwen3_tts", "smart_turn" }));
    try std.testing.expect(!smartTurnAvailable(&.{ "qwen3_tts", "moonshine_asr" }));
}
