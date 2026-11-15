//! Pronunciation modeling (NativeTongue, text side).
//!
//! A pronunciation entry is the dataset's own attested spelling of
//! a word, with its meaning and source — the dataset's orthography
//! is phonetic in practice (tone-marked forms such as Bassa "dō"),
//! so the attested form IS the pronunciation hint the TTS leg will
//! consume when it can run. Nothing here is invented: a word with
//! no dataset entry has no pronunciation, and the lookup says so.
//!
//! `syllables` is a mechanical vowel-group split of the attested
//! form (each syllable is leading consonants + a vowel group, with
//! a single consonant before the next vowel group attaching to the
//! following syllable). It is labelled heuristic everywhere it
//! appears (`syllables_heuristic = true`) — it is a counting aid,
//! not an attested pronunciation.

const std = @import("std");
const vocabulary = @import("vocabulary.zig");

/// One pronunciation. `word` and `attested_form` are borrowed from
/// the Dataset; `syllables` is owned by the caller (free each
/// string, then the slice).
pub const Pronunciation = struct {
    word: []const u8,
    /// The dataset's attested spelling of the word.
    attested_form: []const u8,
    /// English meaning (the entry's input / standard_english).
    meaning: []const u8,
    /// Dataset entry id, for citation.
    id: []const u8,
    source: []const u8,
    syllables: [][]const u8,
    syllables_heuristic: bool = true,
};

/// Split a word into syllables by vowel group. A syllable is its
/// leading consonants plus one vowel group; a single consonant
/// sitting between two vowel groups starts the next syllable
/// ("kúli" -> "kú", "li"; "dō" -> "dō"; "fini" -> "fi", "ni").
/// Vowels are aeiou plus the dataset's tone-marked and extended
/// vowels (ɛ ɔ àáâãäå èéêë ìíîï òóôõö ùúûü). Mechanical only.
pub fn syllabify(alloc: std.mem.Allocator, word: []const u8) ![][]const u8 {
    // Decode into codepoints first (a vowel may be multi-byte).
    var cps = std.ArrayList(u21).empty;
    defer cps.deinit(alloc);
    var it = std.unicode.Utf8View.init(word) catch return error.InvalidUtf8;
    var iter = it.iterator();
    while (iter.nextCodepoint()) |cp| try cps.append(alloc, cp);

    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    // Byte offset of each codepoint, for slicing.
    var offsets = std.ArrayList(usize).empty;
    defer offsets.deinit(alloc);
    {
        var view = std.unicode.Utf8View.init(word) catch unreachable;
        var it2 = view.iterator();
        var off: usize = 0;
        while (it2.nextCodepointSlice()) |slice| {
            try offsets.append(alloc, off);
            off += slice.len;
        }
        try offsets.append(alloc, word.len);
    }

    var start: usize = 0; // codepoint index of current syllable
    var i: usize = 0;
    while (i < cps.items.len) {
        if (!isVowel(cps.items[i])) {
            i += 1;
            continue;
        }
        // End of a vowel group.
        var j = i;
        while (j < cps.items.len and isVowel(cps.items[j])) : (j += 1) {}
        // j is the first consonant after the vowel group (or end).
        // If another vowel group follows, a single consonant between
        // the groups starts the next syllable; two or more consonants
        // split after the first.
        var cut = j;
        if (j < cps.items.len) {
            var k = j;
            while (k < cps.items.len and !isVowel(cps.items[k])) : (k += 1) {}
            if (k < cps.items.len) {
                // Another vowel group follows at k.
                if (k - j == 1) {
                    cut = j; // the one consonant starts the next syllable
                } else {
                    cut = j + 1; // first consonant closes this syllable
                }
            } else {
                cut = cps.items.len; // trailing consonants close it
            }
        }
        const slice = word[offsets.items[start]..offsets.items[cut]];
        try out.append(alloc, try alloc.dupe(u8, slice));
        start = cut;
        i = cut;
    }
    // Any trailing consonants with no vowel (e.g. a word with no
    // vowel at all) form one final syllable.
    if (start < cps.items.len) {
        try out.append(alloc, try alloc.dupe(u8, word[offsets.items[start]..]));
    }
    return out.toOwnedSlice(alloc);
}

fn isVowel(cp: u21) bool {
    return switch (cp) {
        'a', 'e', 'i', 'o', 'u', 'A', 'E', 'I', 'O', 'U',
        0x025B, // ɛ
        0x0254, // ɔ
        0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, // à-å
        0x00E8, 0x00E9, 0x00EA, 0x00EB, // è-ë
        0x00EC, 0x00ED, 0x00EE, 0x00EF, // ì-ï
        0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, // ò-ö
        0x00F9, 0x00FA, 0x00FB, 0x00FC, // ù-ü
        0x00FD, 0x00FF, // ý ÿ
        0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5,
        0x00C8, 0x00C9, 0x00CA, 0x00CB,
        0x00CC, 0x00CD, 0x00CE, 0x00CF,
        0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6,
        0x00D9, 0x00DA, 0x00DB, 0x00DC,
        => true,
        else => false,
    };
}

/// Look a word up in a Dataset's wordlist side: the first entry
/// whose `response` contains the word as a whole word. Returns null
/// when the dataset has no such entry — never an invented form.
pub fn lookup(alloc: std.mem.Allocator, ds: *const vocabulary.Dataset, word: []const u8) !?Pronunciation {
    const hits = try ds.lookup(alloc, word, 1);
    defer alloc.free(hits);
    if (hits.len == 0) return null;
    const e = hits[0].entry;
    const meaning = if (e.input.len > 0) e.input else e.standard_english;
    const syllables = try syllabify(alloc, e.response);
    return .{
        .word = word,
        .attested_form = e.response,
        .meaning = meaning,
        .id = e.id,
        .source = e.source,
        .syllables = syllables,
    };
}

test "syllabify splits on vowel groups" {
    const alloc = std.testing.allocator;
    const a = try syllabify(alloc, "kúli");
    defer {
        for (a) |s| alloc.free(s);
        alloc.free(a);
    }
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings("kú", a[0]);
    try std.testing.expectEqualStrings("li", a[1]);

    const b = try syllabify(alloc, "dō");
    defer {
        for (b) |s| alloc.free(s);
        alloc.free(b);
    }
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try std.testing.expectEqualStrings("dō", b[0]);

    const c = try syllabify(alloc, "fini");
    defer {
        for (c) |s| alloc.free(s);
        alloc.free(c);
    }
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqualStrings("fi", c[0]);
    try std.testing.expectEqualStrings("ni", c[1]);
}

test "pronunciation lookup returns the attested form, or nothing" {
    const alloc = std.testing.allocator;
    // Verbatim from datasets/bassa.json (bassa_00001): "one" -> "dō".
    const json =
        \\[{"id": "bassa_00001", "types": "wordlist", "input": "one", "response": "dō", "standard_english": "one", "source": "lexibank/polyglottaafricana"}]
    ;
    var ds = try vocabulary.Dataset.loadJson(alloc, "bsq", json);
    defer ds.deinit();
    const p = (try lookup(alloc, &ds, "dō")) orelse return error.TestUnexpectedResult;
    defer {
        for (p.syllables) |s| alloc.free(s);
        alloc.free(p.syllables);
    }
    try std.testing.expectEqualStrings("dō", p.attested_form);
    try std.testing.expectEqualStrings("one", p.meaning);
    try std.testing.expectEqualStrings("bassa_00001", p.id);
    try std.testing.expect(p.syllables_heuristic);
    try std.testing.expect(try lookup(alloc, &ds, "zebra") == null);
}
