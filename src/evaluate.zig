//! Language quality evaluation (Phase 4, item 9).
//!
//! Scores identification and code-switch detection on REAL labeled
//! examples drawn from the loaded dataset — numbers, not vibes.
//! The eval sets are built deterministically (first N entries of a
//! given kind, in file order), so a re-run reproduces the numbers:
//!
//! - Identification: Koloqua examples are the first N non-expansion
//!   `response` strings (attested Koloqua); the English examples are
//!   the `standard_english` of those SAME entries (paired, real
//!   English). Wordlist languages contribute their first N
//!   `response` words. An example counts as correct when the
//!   identified language equals the expected code.
//! - Code-switch: a mixed utterance is built by joining a real
//!   Koloqua `response` with the `standard_english` of a DIFFERENT
//!   real entry. The construction is documented and the switch
//!   boundary is known by construction (the word count of the
//!   first part). A prediction counts as correct when it finds
//!   exactly one switch whose boundary is within one word of the
//!   true boundary (shared words such as "go" may shift it by one).
//!
//! The evaluator never trains, never invents text, and never
//! touches the dataset files.

const std = @import("std");
const language = @import("language.zig");
const vocabulary = @import("vocabulary.zig");

/// Per-language identification tally.
pub const PerLanguage = struct {
    code: []const u8,
    correct: usize,
    total: usize,
};

pub const IdentificationEval = struct {
    correct: usize,
    total: usize,
    per_language: []PerLanguage,

    pub fn accuracy(self: *const IdentificationEval) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.correct)) / @as(f64, @floatFromInt(self.total));
    }
};

pub const CodeSwitchEval = struct {
    /// Examples where exactly one switch was found at the right place.
    correct: usize,
    total: usize,
    /// Total switches predicted across all examples.
    predicted_switches: usize,
    /// True switches (one per example).
    true_switches: usize,

    pub fn precision(self: *const CodeSwitchEval) f64 {
        if (self.predicted_switches == 0) return 0;
        return @as(f64, @floatFromInt(self.correct)) / @as(f64, @floatFromInt(self.predicted_switches));
    }

    pub fn recall(self: *const CodeSwitchEval) f64 {
        if (self.true_switches == 0) return 0;
        return @as(f64, @floatFromInt(self.correct)) / @as(f64, @floatFromInt(self.true_switches));
    }
};

/// Non-expansion Koloqua entries (the attested ones — the
/// `expansion_*` types are pattern-derived). Skips entries whose
/// response is empty.
fn isAttestedKoloqua(e: *const vocabulary.Entry) bool {
    if (e.response.len == 0) return false;
    return !std.mem.startsWith(u8, e.kind, "expansion_");
}

/// Evaluate identification over the loaded vocabulary. `limit` is
/// the per-language example cap. Languages without a loaded
/// dataset are skipped (and reported as total 0).
pub fn evaluateIdentification(
    alloc: std.mem.Allocator,
    vocab: *const vocabulary.Vocabulary,
    limit: usize,
) !IdentificationEval {
    var per = std.ArrayList(PerLanguage).empty;
    errdefer per.deinit(alloc);
    var correct: usize = 0;
    var total: usize = 0;

    // Koloqua: attested responses; English: the paired
    // standard_english of the same entries.
    if (vocab.dataset("kq")) |kq| {
        var kq_correct: usize = 0;
        var kq_total: usize = 0;
        var en_correct: usize = 0;
        var en_total: usize = 0;
        for (kq.entries) |*e| {
            if (kq_total >= limit and en_total >= limit) break;
            if (!isAttestedKoloqua(e)) continue;
            if (kq_total < limit) {
                const id = try language.identify(alloc, e.response, vocab);
                if (std.mem.eql(u8, id.language, "kq")) kq_correct += 1;
                kq_total += 1;
            }
            if (en_total < limit and e.standard_english.len > 0) {
                const id = try language.identify(alloc, e.standard_english, vocab);
                if (std.mem.eql(u8, id.language, "en-lr")) en_correct += 1;
                en_total += 1;
            }
        }
        try per.append(alloc, .{ .code = "kq", .correct = kq_correct, .total = kq_total });
        try per.append(alloc, .{ .code = "en-lr", .correct = en_correct, .total = en_total });
        correct += kq_correct + en_correct;
        total += kq_total + en_total;
    }

    // Wordlist languages: first `limit` response words each.
    for (&language.registry) |l| {
        if (std.mem.eql(u8, l.code, "en-lr") or std.mem.eql(u8, l.code, "kq")) continue;
        const ds = vocab.dataset(l.code) orelse continue;
        var c: usize = 0;
        var t: usize = 0;
        for (ds.entries) |*e| {
            if (t >= limit) break;
            if (e.response.len == 0) continue;
            const id = try language.identify(alloc, e.response, vocab);
            if (std.mem.eql(u8, id.language, l.code)) c += 1;
            t += 1;
        }
        try per.append(alloc, .{ .code = l.code, .correct = c, .total = t });
        correct += c;
        total += t;
    }

    return .{
        .correct = correct,
        .total = total,
        .per_language = try per.toOwnedSlice(alloc),
    };
}

/// Evaluate code-switch detection on composed mixed utterances
/// (real Koloqua response + real English sentence, boundary known
/// by construction). `limit` caps the example count.
pub fn evaluateCodeSwitch(
    alloc: std.mem.Allocator,
    vocab: *const vocabulary.Vocabulary,
    limit: usize,
) !CodeSwitchEval {
    const kq = vocab.dataset("kq") orelse return .{
        .correct = 0,
        .total = 0,
        .predicted_switches = 0,
        .true_switches = 0,
    };
    var correct: usize = 0;
    var total: usize = 0;
    var predicted: usize = 0;
    // Collect attested entries first (two passes over the file
    // would re-scan; the list is small — at most `limit` pairs).
    var attested = std.ArrayList(*const vocabulary.Entry).empty;
    defer attested.deinit(alloc);
    for (kq.entries) |*e| {
        if (attested.items.len >= limit * 2) break;
        if (isAttestedKoloqua(e) and e.standard_english.len > 0) {
            try attested.append(alloc, e);
        }
    }
    var i: usize = 0;
    while (i + 1 < attested.items.len and total < limit) : (i += 2) {
        const kq_part = attested.items[i].response;
        const en_part = attested.items[i + 1].standard_english;
        const mixed = try std.fmt.allocPrint(alloc, "{s} {s}", .{ kq_part, en_part });
        defer alloc.free(mixed);
        const kq_words = try vocabulary.Dataset.tokenize(alloc, kq_part);
        defer {
            for (kq_words) |w| alloc.free(w);
            alloc.free(kq_words);
        }
        const boundary = kq_words.len; // first English word index
        const r = try language.detectSwitches(alloc, mixed, vocab);
        defer alloc.free(r.segments);
        predicted += r.switches;
        total += 1;
        if (r.switches == 1 and r.segments.len == 2) {
            const found = r.segments[1].start_word;
            const diff = if (found > boundary) found - boundary else boundary - found;
            if (diff <= 1) correct += 1;
        }
    }
    return .{
        .correct = correct,
        .total = total,
        .predicted_switches = predicted,
        .true_switches = total,
    };
}

/// Print both evaluations as a short report.
pub fn printReport(
    out: *std.Io.Writer,
    ident: *const IdentificationEval,
    cs: *const CodeSwitchEval,
) !void {
    try out.print("identification: {d}/{d} correct ({d:.1}%)\n", .{ ident.correct, ident.total, ident.accuracy() * 100 });
    for (ident.per_language) |p| {
        const pct: f64 = if (p.total == 0) 0 else @as(f64, @floatFromInt(p.correct)) / @as(f64, @floatFromInt(p.total)) * 100;
        try out.print("  {s}: {d}/{d} ({d:.1}%)\n", .{ p.code, p.correct, p.total, pct });
    }
    try out.print("code-switch: {d}/{d} boundaries correct, precision {d:.2}, recall {d:.2} ({d} predicted switches)\n", .{
        cs.correct,
        cs.total,
        cs.precision(),
        cs.recall(),
        cs.predicted_switches,
    });
}

test "evaluator measures real accuracy on a tiny fixture" {
    const alloc = std.testing.allocator;
    // Real attested Koloqua (koloqua.json) + their real English.
    const json =
        \\[
        \\  {"id": "koloqua_00043", "types": "tense_progressive", "input": "I'm going.", "response": "I de go.", "standard_english": "I'm going.", "source": "Singler (1981)"},
        \\  {"id": "koloqua_00062", "types": "tense_completive", "input": "I have forgotten your name.", "response": "I fini forget/forgetting your name.", "standard_english": "I have forgotten your name.", "source": "Singler (1981)"},
        \\  {"id": "koloqua_00108", "types": "parallel_sentence", "input": "That man has come.", "response": "That man na tome.", "standard_english": "That man has come.", "source": "Singler (1981)"},
        \\  {"id": "koloqua_00109", "types": "parallel_sentence", "input": "That man has come o.", "response": "That man na come o.", "standard_english": "That man has come o.", "source": "Singler (1981)"}
        \\]
    ;
    var vocab = vocabulary.Vocabulary.init(alloc);
    defer vocab.deinit();
    // Load through the real loader path via a temp file so
    // ownership is real.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "koloqua.json", .data = json });
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/koloqua.json", .{tmp.sub_path});
    defer alloc.free(path);
    try vocab.load(io, "kq", path);

    const ident = try evaluateIdentification(alloc, &vocab, 4);
    defer alloc.free(ident.per_language);
    // 4 Koloqua responses + 4 English translations.
    try std.testing.expectEqual(@as(usize, 8), ident.total);
    try std.testing.expect(ident.accuracy() >= 0.75);

    const cs = try evaluateCodeSwitch(alloc, &vocab, 2);
    try std.testing.expectEqual(@as(usize, 2), cs.total);
}
