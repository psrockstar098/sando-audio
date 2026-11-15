//! Language registry, identification, and code-switch detection
//! (SANDO Polyglot / NativeTongue, text side).
//!
//! The registry is the 11 languages of the Phase 4 roadmap:
//! Liberian English, Koloqua, Bassa, Kpelle, Vai, Grebo, Kru,
//! Lorma, Mano, Gola, Dan (Gio). Status is honest: Liberian English
//! is "supported" because the live ASR model (Moonshine, English)
//! covers it; Koloqua and the indigenous languages are "partial"
//! (real dataset text exists, but no ASR or TTS model exists for
//! them yet). No language claims a model it does not have.
//!
//! Identification is a transparent word-score, never a black box:
//!   - Koloqua: a weighted marker set drawn from the dataset's own
//!     attested entries (progressive "de", completive "fini",
//!     perfect "nohn", habitual "dor", plural "dem", "pekin",
//!     "yah", "ain't", "sor", "self").
//!   - English: a common-word marker set ("the", "and", "is", ...).
//!   - Bassa, Kpelle, Vai, Grebo, Kru, Lorma, Mano, Gola, Dan:
//!     wordlist membership in the loaded dataset (a token that
//!     appears in that language's wordlist scores for it). The
//!     Koloqua dataset is NOT used this way — its responses contain
//!     ordinary English words ("man", "house") that would inflate
//!     Koloqua on any English sentence.
//! The winning language is the highest score; ties break in
//! registry order. Nothing matches at all -> "und" (unknown),
//! confidence 0. Scores are reported, so a caller can see WHY a
//! language was picked.
//!
//! Code-switch detection tags each word (marker or wordlist hit;
//! untagged words inherit the current run) and groups runs into
//! segments. A switch is a change of language between segments.

const std = @import("std");
const vocabulary = @import("vocabulary.zig");

pub const Status = enum { supported, partial, planned };

/// One registry entry. `dataset_file` is the file name in the
/// dataset directory (null when the language has no dataset file).
pub const Language = struct {
    code: [:0]const u8,
    name: [:0]const u8,
    dataset_file: ?[]const u8,
    script: []const u8,
    status: Status,
    /// ASR model that covers this language, or null when none exists.
    asr_model: ?[]const u8,
    /// True when a TTS voice exists for this language. False for
    /// every language in this phase: Qwen3-TTS has no Liberian
    /// voice and cannot run on this VM anyway.
    tts_available: bool,
};

/// The registry, in tie-break order (Liberian English first).
pub const registry = [_]Language{
    .{ .code = "en-lr", .name = "Liberian English", .dataset_file = null, .script = "Latin", .status = .supported, .asr_model = "moonshine-small", .tts_available = false },
    .{ .code = "kq", .name = "Koloqua", .dataset_file = "koloqua.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "bsq", .name = "Bassa", .dataset_file = "bassa.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "kpe", .name = "Kpelle", .dataset_file = "kpelle.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "vai", .name = "Vai", .dataset_file = "vai.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "grb", .name = "Grebo", .dataset_file = "grebo.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "kro", .name = "Kru", .dataset_file = "kru.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "lom", .name = "Lorma", .dataset_file = "lorma.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "mnk", .name = "Mano", .dataset_file = "mano.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "gol", .name = "Gola", .dataset_file = "gola.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
    .{ .code = "dnj", .name = "Dan (Gio)", .dataset_file = "gio.json", .script = "Latin", .status = .partial, .asr_model = null, .tts_available = false },
};

pub fn find(code: []const u8) ?*const Language {
    for (&registry) |*l| {
        if (std.mem.eql(u8, l.code, code)) return l;
    }
    return null;
}

/// Accept codes, names, and the legacy "en": "kq"/"koloqua" ->
/// "kq", "en"/"en-lr"/"liberian english" -> "en-lr", "bassa" ->
/// "bsq", "dan"/"gio" -> "dnj", and so on. Case-insensitive.
/// Null when the input names no registered language.
pub fn normalizeCode(input: []const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    if (input.len > buf.len) return null;
    for (input, 0..) |c, i| {
        var l = c;
        if (l >= 'A' and l <= 'Z') l += 'a' - 'A';
        if (l == ' ') l = '-';
        buf[i] = l;
    }
    const s = buf[0..input.len];
    if (std.mem.eql(u8, s, "en") or std.mem.eql(u8, s, "en-lr") or std.mem.eql(u8, s, "liberian-english")) return "en-lr";
    if (std.mem.eql(u8, s, "kq") or std.mem.eql(u8, s, "koloqua")) return "kq";
    if (std.mem.eql(u8, s, "bsq") or std.mem.eql(u8, s, "bassa")) return "bsq";
    if (std.mem.eql(u8, s, "kpe") or std.mem.eql(u8, s, "kpelle")) return "kpe";
    if (std.mem.eql(u8, s, "vai")) return "vai";
    if (std.mem.eql(u8, s, "grb") or std.mem.eql(u8, s, "grebo")) return "grb";
    if (std.mem.eql(u8, s, "kro") or std.mem.eql(u8, s, "kru")) return "kro";
    if (std.mem.eql(u8, s, "lom") or std.mem.eql(u8, s, "lorma")) return "lom";
    if (std.mem.eql(u8, s, "mnk") or std.mem.eql(u8, s, "mano")) return "mnk";
    if (std.mem.eql(u8, s, "gol") or std.mem.eql(u8, s, "gola")) return "gol";
    if (std.mem.eql(u8, s, "dnj") or std.mem.eql(u8, s, "dan") or std.mem.eql(u8, s, "gio")) return "dnj";
    return null;
}

/// The language instruction added to a conversation prompt for a
/// session in `code`. Empty when the code is unregistered (the
/// prompt stays exactly as Phase 3 wrote it).
pub fn promptFor(code: []const u8) []const u8 {
    const norm = normalizeCode(code) orelse return "";
    if (std.mem.eql(u8, norm, "kq")) {
        return "Answer in Liberian Koloqua (Liberian Vernacular English) when the user speaks Koloqua. Use short spoken sentences and the local expressions the user uses. Do not translate into standard English unless asked.";
    }
    if (std.mem.eql(u8, norm, "en-lr")) {
        return "Answer in plain spoken English, briefly.";
    }
    const lang = find(norm) orelse return "";
    _ = lang;
    return "No speech model exists for this language yet — answer briefly in plain spoken English.";
}

/// A weighted marker word. Weights: 3 = distinctive (rarely
/// appears in the other language), 2 = strong, 1 = shared.
const Marker = struct { word: []const u8, weight: f32 };

/// Koloqua markers, drawn from the dataset's attested entries:
/// "de" (progressive, koloqua_00043), "fini" (completive,
/// koloqua_00062), "nohn" (perfect, koloqua_00069), "dor"
/// (habitual), "dem" (plural, koloqua_00167), "pekin"
/// (koloqua_00005), "yah" (koloqua_00110), "ain't" (negation,
/// koloqua_00082), "sor" (copula, koloqua_00078), "self"
/// (emphasis, koloqua_00016), "na" (perfect, koloqua_00108).
const koloqua_markers = [_]Marker{
    .{ .word = "fini", .weight = 3 },
    .{ .word = "nohn", .weight = 3 },
    .{ .word = "dor", .weight = 3 },
    .{ .word = "pekin", .weight = 3 },
    .{ .word = "ain't", .weight = 3 },
    .{ .word = "de", .weight = 2 },
    .{ .word = "na", .weight = 2 },
    .{ .word = "dem", .weight = 2 },
    .{ .word = "yah", .weight = 2 },
    .{ .word = "sor", .weight = 2 },
    .{ .word = "self", .weight = 2 },
    .{ .word = "go", .weight = 1 },
    .{ .word = "them", .weight = 1 },
};

/// Common English words. "go" and "them" also score for Koloqua
/// (weight 1 there) — shared words are weak evidence either way.
const english_markers = [_]Marker{
    .{ .word = "the", .weight = 2 },
    .{ .word = "and", .weight = 1 },
    .{ .word = "is", .weight = 1 },
    .{ .word = "are", .weight = 1 },
    .{ .word = "you", .weight = 1 },
    .{ .word = "your", .weight = 1 },
    .{ .word = "have", .weight = 1 },
    .{ .word = "has", .weight = 1 },
    .{ .word = "will", .weight = 1 },
    .{ .word = "this", .weight = 1 },
    .{ .word = "that", .weight = 1 },
    .{ .word = "with", .weight = 1 },
    .{ .word = "for", .weight = 1 },
    .{ .word = "from", .weight = 1 },
    .{ .word = "when", .weight = 1 },
    .{ .word = "what", .weight = 1 },
    .{ .word = "how", .weight = 1 },
    .{ .word = "not", .weight = 1 },
    .{ .word = "but", .weight = 1 },
    .{ .word = "was", .weight = 1 },
    .{ .word = "were", .weight = 1 },
    .{ .word = "been", .weight = 1 },
    .{ .word = "there", .weight = 1 },
    .{ .word = "their", .weight = 1 },
    .{ .word = "about", .weight = 1 },
    .{ .word = "into", .weight = 1 },
    .{ .word = "than", .weight = 1 },
    .{ .word = "then", .weight = 1 },
    .{ .word = "go", .weight = 1 },
    .{ .word = "them", .weight = 1 },
};

fn markerWeight(markers: []const Marker, word: []const u8) f32 {
    for (markers) |m| {
        if (std.mem.eql(u8, m.word, word)) return m.weight;
    }
    return 0;
}

/// One identification outcome. `scores` is indexed like
/// `registry`; `tokens` is the token count; `scored` is how many
/// tokens matched any evidence at all.
pub const Identification = struct {
    language: []const u8,
    confidence: f32,
    scores: [registry.len]f32,
    tokens: usize,
    scored: usize,

    pub fn scoreFor(self: *const Identification, code: []const u8) f32 {
        for (&registry, 0..) |l, i| {
            if (std.mem.eql(u8, l.code, code)) return self.scores[i];
        }
        return 0;
    }
};

/// Identify the language of `text`. `vocab` is optional: when
/// present, wordlist-backed languages (Bassa, Kpelle, ...) score
/// 2 per wordlist hit; when absent, only the marker sets run and
/// indigenous languages cannot win (the result says so in the
/// scores — all zero). Never returns an error for empty text:
/// empty input identifies as "und" with confidence 0.
pub fn identify(alloc: std.mem.Allocator, text: []const u8, vocab: ?*const vocabulary.Vocabulary) !Identification {
    const words = try vocabulary.Dataset.tokenize(alloc, text);
    defer {
        for (words) |w| alloc.free(w);
        alloc.free(words);
    }
    var scores = std.mem.zeroes([registry.len]f32);
    var scored: usize = 0;
    // Presence of a STRONG Koloqua marker (weight >= 2: de, fini,
    // na, nohn, dor, pekin, ain't, yah, sor, self) decides Koloqua
    // outright. Koloqua shares English's lexicon, so count-based
    // scoring loses to English common words on most real Koloqua
    // sentences ("The Minister them coming." has "the" + "them"
    // against a single weak marker). A strong marker is essentially
    // never plain English, so its presence is the signal — not the
    // count. Measured effect on the real dataset is recorded in
    // STATUS.md (Phase 4 evaluation section).
    var kq_strong = false;
    for (words) |w| {
        var hit = false;
        const kw = markerWeight(&koloqua_markers, w);
        if (kw > 0) {
            scores[1] += kw;
            if (kw >= 2) kq_strong = true;
            hit = true;
        }
        const ew = markerWeight(&english_markers, w);
        if (ew > 0) {
            scores[0] += ew;
            hit = true;
        }
        if (vocab) |v| {
            // Wordlist-backed languages only (index 2..). Koloqua
            // is marker-only: its responses contain ordinary
            // English words that would inflate it on English text.
            for (&registry, 0..) |l, i| {
                if (i < 2) continue;
                if (v.dataset(l.code)) |ds| {
                    if (try ds.containsWord(w)) {
                        scores[i] += 2;
                        hit = true;
                    }
                }
            }
        }
        if (hit) scored += 1;
    }
    var best: usize = 0;
    var best_score: f32 = 0;
    for (scores, 0..) |s, i| {
        if (s > best_score) {
            best_score = s;
            best = i;
        }
    }
    if (kq_strong) {
        best = 1;
        best_score = scores[1];
    } else if (best >= 2 and scores[0] > 0 and best_score - scores[0] < 2) {
        // Wordlist evidence must CLEARLY beat English. The
        // wordlists contain English-looking tokens (a dirty gloss
        // entry, lorma_02152, puts "read book" in the Lorma set;
        // a grammar note, lorma_00593, puts "the" there), so a
        // 1-point edge is noise, not a language. Measured: without
        // this rule "The book is on the table and I have read it."
        // scores lom 8 vs en 7 and is called Lorma. With it,
        // English wins unless a wordlist language leads by a full
        // word (>= 2 points). Single-word wordlist examples still
        // win (their English score is 0). See STATUS.md.
        best = 0;
        best_score = scores[0];
    }
    if (best_score == 0) {
        return .{
            .language = "und",
            .confidence = 0,
            .scores = scores,
            .tokens = words.len,
            .scored = 0,
        };
    }
    return .{
        .language = registry[best].code,
        .confidence = @min(1, best_score / @as(f32, @floatFromInt(@max(1, words.len)))),
        .scores = scores,
        .tokens = words.len,
        .scored = scored,
    };
}

/// The language a single word belongs to, or null when it carries
/// no signal. Distinctive Koloqua markers (weight 3) and English
/// markers win first; wordlist hits follow.
pub fn tagWord(word: []const u8, vocab: ?*const vocabulary.Vocabulary) !?[]const u8 {
    if (markerWeight(&koloqua_markers, word) >= 2) return "kq";
    if (markerWeight(&english_markers, word) >= 1) return "en-lr";
    if (vocab) |v| {
        for (&registry, 0..) |l, i| {
            if (i < 2) continue;
            if (v.dataset(l.code)) |ds| {
                if (try ds.containsWord(word)) return l.code;
            }
        }
    }
    if (markerWeight(&koloqua_markers, word) > 0) return "kq";
    return null;
}

/// One run of same-language words.
pub const Segment = struct {
    language: []const u8,
    /// First word index (inclusive), last word index (exclusive).
    start_word: usize,
    end_word: usize,
};

/// Code-switch detection: segments of `text` by language.
/// Untagged words inherit the current run (they do not break it);
/// leading untagged words start an "und" segment that is dropped
/// when a tagged word follows. `switches` is segments.len - 1.
pub const SwitchResult = struct {
    segments: []Segment,
    switches: usize,
};

pub fn detectSwitches(alloc: std.mem.Allocator, text: []const u8, vocab: ?*const vocabulary.Vocabulary) !SwitchResult {
    const words = try vocabulary.Dataset.tokenize(alloc, text);
    defer {
        for (words) |w| alloc.free(w);
        alloc.free(words);
    }
    var segments = std.ArrayList(Segment).empty;
    errdefer segments.deinit(alloc);
    var current: ?[]const u8 = null;
    var start: usize = 0;
    for (words, 0..) |w, i| {
        const tag = try tagWord(w, vocab);
        if (tag) |t| {
            if (current == null) {
                // Leading untagged words belonged to no run yet:
                // they join this first segment.
                current = t;
                start = 0;
            } else if (!std.mem.eql(u8, t, current.?)) {
                // Shared words ("go", "them" score for both
                // Koloqua and English) do not switch a run: they
                // stay with the language already in progress.
                const stays = (std.mem.eql(u8, current.?, "kq") and markerWeight(&koloqua_markers, w) > 0) or
                    (std.mem.eql(u8, current.?, "en-lr") and markerWeight(&english_markers, w) > 0);
                if (!stays) {
                    try segments.append(alloc, .{ .language = current.?, .start_word = start, .end_word = i });
                    current = t;
                    start = i;
                }
            }
        }
    }
    if (current) |c| {
        try segments.append(alloc, .{ .language = c, .start_word = start, .end_word = words.len });
    }
    // Count switches BEFORE toOwnedSlice: it empties the list.
    const n = segments.items.len;
    return .{
        .segments = try segments.toOwnedSlice(alloc),
        .switches = if (n == 0) 0 else n - 1,
    };
}

test "registry has 11 languages, honest statuses" {
    try std.testing.expectEqual(@as(usize, 11), registry.len);
    try std.testing.expect(registry[0].status == .supported);
    try std.testing.expectEqualStrings("moonshine-small", registry[0].asr_model.?);
    for (registry[1..]) |l| {
        try std.testing.expect(l.status == .partial);
        try std.testing.expect(l.asr_model == null);
        try std.testing.expect(!l.tts_available);
        try std.testing.expect(l.dataset_file != null);
    }
}

test "normalizeCode accepts names and legacy en" {
    try std.testing.expectEqualStrings("kq", normalizeCode("koloqua").?);
    try std.testing.expectEqualStrings("kq", normalizeCode("KQ").?);
    try std.testing.expectEqualStrings("en-lr", normalizeCode("en").?);
    try std.testing.expectEqualStrings("en-lr", normalizeCode("Liberian English").?);
    try std.testing.expectEqualStrings("dnj", normalizeCode("gio").?);
    try std.testing.expect(normalizeCode("klingon") == null);
}

test "identify distinguishes Koloqua from English on real phrases" {
    const alloc = std.testing.allocator;
    // Real attested Koloqua (koloqua.json): "I de go." (koloqua_00043),
    // "They fini fool we pekin them." (koloqua_00005),
    // "That man na come o." (koloqua_00109).
    const kq1 = try identify(alloc, "I de go.", null);
    try std.testing.expectEqualStrings("kq", kq1.language);
    const kq2 = try identify(alloc, "They fini fool we pekin them.", null);
    try std.testing.expectEqualStrings("kq", kq2.language);
    const kq3 = try identify(alloc, "That man na come o.", null);
    try std.testing.expectEqualStrings("kq", kq3.language);
    // Plain English: no Koloqua markers at all.
    const en = try identify(alloc, "The book is on the table and I have read it.", null);
    try std.testing.expectEqualStrings("en-lr", en.language);
    // Nothing recognizable: unknown, confidence 0.
    const und = try identify(alloc, "zxqv wjbl", null);
    try std.testing.expectEqualStrings("und", und.language);
    try std.testing.expectEqual(@as(f32, 0), und.confidence);
    // Empty text: unknown, no crash.
    const empty = try identify(alloc, "", null);
    try std.testing.expectEqualStrings("und", empty.language);
}

test "identify uses wordlists for indigenous languages" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Verbatim from datasets/bassa.json (bassa_00001): "one" -> "dō".
    const json =
        \\[{"id": "bassa_00001", "types": "wordlist", "input": "one", "response": "dō", "standard_english": "one", "source": "lexibank/polyglottaafricana"}]
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "bassa.json", .data = json });
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/bassa.json", .{tmp.sub_path});
    defer alloc.free(path);
    var vocab = vocabulary.Vocabulary.init(alloc);
    defer vocab.deinit();
    try vocab.load(io, "bsq", path);
    const hit = try identify(alloc, "dō", &vocab);
    try std.testing.expectEqualStrings("bsq", hit.language);
}

test "code-switch detection finds the switch" {
    const alloc = std.testing.allocator;
    // Koloqua first half ("I de go", koloqua_00043), English second.
    const r = try detectSwitches(alloc, "I de go to the market today.", null);
    defer alloc.free(r.segments);
    try std.testing.expectEqual(@as(usize, 1), r.switches);
    try std.testing.expectEqualStrings("kq", r.segments[0].language);
    try std.testing.expectEqualStrings("en-lr", r.segments[1].language);
    // Single language: no switch.
    const single = try detectSwitches(alloc, "The book is on the table.", null);
    defer alloc.free(single.segments);
    try std.testing.expectEqual(@as(usize, 0), single.switches);
}

test "promptFor is language-aware" {
    try std.testing.expect(std.mem.indexOf(u8, promptFor("kq"), "Koloqua") != null);
    try std.testing.expect(std.mem.indexOf(u8, promptFor("en"), "English") != null);
    try std.testing.expectEqualStrings("", promptFor("klingon"));
}
