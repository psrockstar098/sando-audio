//! AdaptiveEar: accent/dialect-aware ASR routing + a correction
//! lexicon (SANDO AdaptiveEar, text side).
//!
//! Routing is a decision, not a model: given a detected language
//! it says which ASR path the engine would take and WHY, and it is
//! honest about what does not exist. On this VM the only live ASR
//! is Moonshine-Streaming-small (English, proven with real speech
//! in Phase 2). Koloqua has NO ASR model yet, so its route is
//! "no model — Moonshine as a best-effort fallback, transcript
//! will be partial"; the other indigenous languages have no route
//! at all. A route never claims a model exists when it does not.
//!
//! The correction lexicon is the personalization half: a small
//! in-memory map of words the user has corrected
//! (mishearing -> right form), applied to transcripts before the
//! brain sees them. In-memory only in this phase (like a
//! conversation Session); nothing is retained across processes,
//! and nothing is learned without an explicit correction.

const std = @import("std");
const language = @import("language.zig");

/// One routing decision.
pub const AsrRoute = struct {
    language: []const u8,
    /// The ASR model for this language, or null when none exists.
    model: ?[]const u8,
    /// Best-effort fallback model, or null when there is none.
    fallback: ?[]const u8,
    /// True only when `model` is set (a real model exists).
    available: bool,
    /// Why this route was chosen, in plain words.
    reason: []const u8,
};

/// Route the ASR leg for a detected language code (any accepted
/// spelling — see language.normalizeCode).
pub fn routeFor(code: []const u8) AsrRoute {
    const norm = language.normalizeCode(code) orelse "und";
    if (std.mem.eql(u8, norm, "en-lr")) {
        return .{
            .language = norm,
            .model = "moonshine-small",
            .fallback = null,
            .available = true,
            .reason = "Moonshine-Streaming-small is the live English ASR model on this machine (proven with real speech in Phase 2).",
        };
    }
    if (std.mem.eql(u8, norm, "kq")) {
        return .{
            .language = norm,
            .model = null,
            .fallback = "moonshine-small",
            .available = false,
            .reason = "No Koloqua ASR model exists yet. Moonshine (English) is the best-effort fallback — it transcribes English words and misses Koloqua ones, so treat the transcript as partial.",
        };
    }
    if (language.find(norm)) |lang| {
        _ = lang;
        return .{
            .language = norm,
            .model = null,
            .fallback = null,
            .available = false,
            .reason = "No ASR model exists for this language yet.",
        };
    }
    return .{
        .language = "und",
        .model = null,
        .fallback = null,
        .available = false,
        .reason = "Language not identified — no ASR route can be chosen.",
    };
}

/// One-line routing report for the CLI / converse output.
pub fn report(alloc: std.mem.Allocator, route: *const AsrRoute) ![]const u8 {
    const lang = language.find(route.language);
    const name = if (lang) |l| l.name else "Unknown";
    if (route.model) |m| {
        return std.fmt.allocPrint(alloc, "language: {s} ({s}) — asr: {s} ({s})", .{ route.language, name, m, route.reason });
    }
    if (route.fallback) |f| {
        return std.fmt.allocPrint(alloc, "language: {s} ({s}) — asr: none, fallback {s} ({s})", .{ route.language, name, f, route.reason });
    }
    return std.fmt.allocPrint(alloc, "language: {s} ({s}) — asr: none ({s})", .{ route.language, name, route.reason });
}

/// A user's corrections: misheard word -> right form. Keys and
/// values are owned by the lexicon's allocator.
pub const CorrectionLexicon = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(alloc: std.mem.Allocator) CorrectionLexicon {
        return .{ .alloc = alloc, .map = std.StringHashMap([]const u8).init(alloc) };
    }

    pub fn deinit(self: *CorrectionLexicon) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Record a correction. Both strings are copied.
    pub fn add(self: *CorrectionLexicon, wrong: []const u8, right: []const u8) !void {
        const key = try self.alloc.dupe(u8, wrong);
        errdefer self.alloc.free(key);
        const value = try self.alloc.dupe(u8, right);
        errdefer self.alloc.free(value);
        if (try self.map.fetchPut(key, value)) |old| {
            // The map kept the ORIGINAL key (getOrPut does not
            // replace it); the new key was not stored, and the old
            // value was replaced. Free the new key and old value.
            self.alloc.free(key);
            self.alloc.free(old.value);
        }
    }

    pub fn count(self: *const CorrectionLexicon) usize {
        return self.map.count();
    }

    /// Apply corrections to `text`, whole words, case-insensitive
    /// match. A capitalized original keeps its capital on the
    /// replacement. Returns the corrected text (owned) and how many
    /// words were corrected.
    pub fn apply(self: *const CorrectionLexicon, alloc: std.mem.Allocator, text: []const u8) !struct { text: []const u8, corrected: usize } {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        var corrected: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            const is_word = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '\'' or c >= 0x80;
            if (!is_word) {
                try out.append(alloc, c);
                i += 1;
                continue;
            }
            const start = i;
            while (i < text.len) {
                const d = text[i];
                const w = (d >= 'a' and d <= 'z') or (d >= 'A' and d <= 'Z') or d == '\'' or d >= 0x80;
                if (!w) break;
                i += 1;
            }
            const word = text[start..i];
            var lower_buf: [64]u8 = undefined;
            const lower = if (word.len <= lower_buf.len) blk: {
                for (word, 0..) |ch, j| {
                    var l = ch;
                    if (l >= 'A' and l <= 'Z') l += 'a' - 'A';
                    lower_buf[j] = l;
                }
                break :blk lower_buf[0..word.len];
            } else word;
            if (self.map.get(lower)) |fix| {
                // Capitalized original -> capitalize the fix.
                if (word[0] >= 'A' and word[0] <= 'Z' and fix.len > 0 and fix[0] >= 'a' and fix[0] <= 'z') {
                    try out.append(alloc, fix[0] - ('a' - 'A'));
                    try out.appendSlice(alloc, fix[1..]);
                } else {
                    try out.appendSlice(alloc, fix);
                }
                corrected += 1;
            } else {
                try out.appendSlice(alloc, word);
            }
        }
        return .{ .text = try out.toOwnedSlice(alloc), .corrected = corrected };
    }
};

test "routing is honest about what exists" {
    const en = routeFor("en");
    try std.testing.expect(en.available);
    try std.testing.expectEqualStrings("moonshine-small", en.model.?);

    const kq = routeFor("koloqua");
    try std.testing.expect(!kq.available);
    try std.testing.expect(kq.model == null);
    try std.testing.expectEqualStrings("moonshine-small", kq.fallback.?);

    const bsq = routeFor("bassa");
    try std.testing.expect(!bsq.available);
    try std.testing.expect(bsq.fallback == null);

    const und = routeFor("klingon");
    try std.testing.expectEqualStrings("und", und.language);
}

test "correction lexicon fixes a common mishearing" {
    const alloc = std.testing.allocator;
    var lex = CorrectionLexicon.init(alloc);
    defer lex.deinit();
    // Moonshine (English) hears Koloqua "de" as "the": the user
    // corrects it once, and later transcripts get the fix.
    try lex.add("the", "de");
    try std.testing.expectEqual(@as(usize, 1), lex.count());
    const fixed = try lex.apply(alloc, "I the go to the market.");
    defer alloc.free(fixed.text);
    try std.testing.expectEqualStrings("I de go to de market.", fixed.text);
    try std.testing.expectEqual(@as(usize, 2), fixed.corrected);
    // Capitalized original keeps its capital.
    const cap = try lex.apply(alloc, "The man is here.");
    defer alloc.free(cap.text);
    try std.testing.expectEqualStrings("De man is here.", cap.text);
    // Re-adding the same word replaces the correction.
    try lex.add("the", "dey");
    try std.testing.expectEqual(@as(usize, 1), lex.count());
}
