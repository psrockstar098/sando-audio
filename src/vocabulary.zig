//! Dataset-backed vocabulary, slang and expression lookup.
//!
//! The real language data lives OUTSIDE this repo, read-only, at a
//! dataset directory the operator passes with `--data-dir` (one JSON
//! file per language, e.g. `koloqua.json`). This module loads those
//! files at runtime and answers lookups from them; it NEVER embeds
//! bulk dataset content in the binary and NEVER modifies the files.
//!
//! Dataset entry shape (all fields are strings):
//!   id, types, region, register, input, response,
//!   standard_english, notes, source, license.
//! For wordlist entries `input` is the English gloss and `response`
//! is the word in the language. For parallel entries `input` is the
//! English sentence and `response` is the same sentence in the
//! language. `standard_english` is the plain-English meaning.
//!
//! Lookup is case-insensitive and word-based: `lookup` finds entries
//! whose `response` contains the word (the word in the language) or
//! whose `input` contains it (the English gloss); `lookupEnglish`
//! finds entries whose English side contains the word and returns
//! the language-side response. Every match carries its dataset id
//! and source so a caller can cite it.

const std = @import("std");

pub const VocabError = error{
    FileNotFound,
    InvalidJson,
    OutOfMemory,
};

/// One dataset entry. All slices are owned by the Dataset's arena.
pub const Entry = struct {
    id: []const u8,
    kind: []const u8,
    input: []const u8,
    response: []const u8,
    standard_english: []const u8,
    source: []const u8,
};

const EntryJson = struct {
    id: []const u8 = "",
    types: []const u8 = "",
    input: []const u8 = "",
    response: []const u8 = "",
    standard_english: []const u8 = "",
    source: []const u8 = "",
};

/// One match: the entry (borrowed from the Dataset) plus which side
/// matched, so callers can say what the word means.
pub const Match = struct {
    entry: *const Entry,
    /// "response" when the word was found on the language side,
    /// "input" when it was found on the English side.
    side: []const u8,
};

/// A single language's dataset file, parsed once and held in an
/// arena. `word_set` is the set of lowercase words appearing in
/// `response` (built lazily) — used by language identification for
/// wordlist-backed languages.
pub const Dataset = struct {
    arena: std.heap.ArenaAllocator,
    language: []const u8,
    entries: []Entry,
    word_set: ?std.StringHashMap(void) = null,

    pub fn deinit(self: *Dataset) void {
        if (self.word_set) |*ws| ws.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Parse dataset JSON bytes. The bytes are copied into the
    /// arena's ownership (the caller may free `bytes` after).
    pub fn loadJson(alloc: std.mem.Allocator, language: []const u8, bytes: []const u8) VocabError!Dataset {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        // parseFromSliceLeaky + alloc_always: every string is COPIED
        // into this Dataset's arena, so the entries stay valid after
        // the caller frees `bytes`. (parseFromSlice's default
        // .alloc_if_needed would leave the Entry slices pointing
        // INTO `bytes` — a use-after-free once loadFile frees it.)
        // ignore_unknown_fields: real files carry region/register/
        // notes/license fields this module does not need.
        const parsed = std.json.parseFromSliceLeaky([]EntryJson, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return error.InvalidJson;
        var entries = try a.alloc(Entry, parsed.len);
        for (parsed, 0..) |e, i| {
            entries[i] = .{
                .id = e.id,
                .kind = e.types,
                .input = e.input,
                .response = e.response,
                .standard_english = e.standard_english,
                .source = e.source,
            };
        }
        return .{
            .arena = arena,
            .language = try a.dupe(u8, language),
            .entries = entries,
        };
    }

    /// Load one dataset file from disk.
    pub fn loadFile(alloc: std.mem.Allocator, io: std.Io, language: []const u8, path: []const u8) VocabError!Dataset {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 << 20)) catch return error.FileNotFound;
        defer alloc.free(bytes);
        return loadJson(alloc, language, bytes);
    }

    pub fn count(self: *const Dataset) usize {
        return self.entries.len;
    }

    /// Lowercase a word (ASCII only; non-ASCII bytes pass through
    /// unchanged — the dataset's tone marks are significant).
    pub fn lowerWord(alloc: std.mem.Allocator, word: []const u8) ![]const u8 {
        const out = try alloc.dupe(u8, word);
        for (out) |*c| {
            if (c.* >= 'A' and c.* <= 'Z') c.* += 'a' - 'A';
        }
        return out;
    }

    /// Split text into lowercase words. A word is a run of ASCII
    /// letters, apostrophes, or bytes >= 0x80 (UTF-8 letters and
    /// tone marks stay attached to their word). Owned slices.
    pub fn tokenize(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |w| alloc.free(w);
            out.deinit(alloc);
        }
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and !isWordByte(text[i])) : (i += 1) {}
            if (i >= text.len) break;
            const start = i;
            while (i < text.len and isWordByte(text[i])) : (i += 1) {}
            try out.append(alloc, try lowerWord(alloc, text[start..i]));
        }
        return out.toOwnedSlice(alloc);
    }

    fn isWordByte(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '\'' or c >= 0x80;
    }

    /// True for a 1-2 byte token made only of ASCII: too short to
    /// be language evidence (see ensureWordSet).
    fn isShortAscii(word: []const u8) bool {
        if (word.len >= 3) return false;
        for (word) |c| {
            if (c >= 0x80) return false;
        }
        return true;
    }

    /// Build the response-word set on first use.
    fn ensureWordSet(self: *Dataset) !void {
        if (self.word_set != null) return;
        var set = std.StringHashMap(void).init(self.arena.allocator());
        for (self.entries) |*e| {
            const words = try tokenize(self.arena.allocator(), e.response);
            for (words) |w| {
                // Short ALL-ASCII words are not evidence: a 1-2
                // letter ASCII token collides across languages and
                // with English ("a", "is", "to", "na", "go" appear in
                // many wordlists and in plain English). Measured
                // before this rule: a plain English sentence scored
                // lom=10 on five such collisions. Accented short
                // words still count ("dō" is 3 bytes; "à" is
                // non-ASCII) — the collisions are an ASCII
                // phenomenon. See STATUS.md.
                if (isShortAscii(w)) continue;
                _ = set.getOrPut(w) catch continue;
            }
        }
        self.word_set = set;
    }

    /// True when `word` appears as a word in any entry's `response`.
    /// Case-insensitive. Builds the word set on first call. Short
    /// all-ASCII words never count (see ensureWordSet).
    pub fn containsWord(self: *Dataset, word: []const u8) !bool {
        if (isShortAscii(word)) return false;
        try self.ensureWordSet();
        const lower = try lowerWord(self.arena.allocator(), word);
        return self.word_set.?.contains(lower);
    }

    /// Find up to `max` entries matching `word` on either side.
    /// A match is a whole-word hit in `response` (the word in the
    /// language) or in `input` (the English gloss). Owned slice;
    /// the entries themselves stay owned by the Dataset.
    pub fn lookup(self: *const Dataset, alloc: std.mem.Allocator, word: []const u8, max: usize) ![]Match {
        const lower = try lowerWord(alloc, word);
        defer alloc.free(lower);
        var out = std.ArrayList(Match).empty;
        errdefer out.deinit(alloc);
        for (self.entries) |*e| {
            if (out.items.len >= max) break;
            if (wordInText(lower, e.response)) {
                try out.append(alloc, .{ .entry = e, .side = "response" });
            } else if (wordInText(lower, e.input)) {
                try out.append(alloc, .{ .entry = e, .side = "input" });
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// English -> language: entries whose English side
    /// (`input`, else `standard_english`) contains `word`.
    pub fn lookupEnglish(self: *const Dataset, alloc: std.mem.Allocator, word: []const u8, max: usize) ![]Match {
        const lower = try lowerWord(alloc, word);
        defer alloc.free(lower);
        var out = std.ArrayList(Match).empty;
        errdefer out.deinit(alloc);
        for (self.entries) |*e| {
            if (out.items.len >= max) break;
            const english = if (e.input.len > 0) e.input else e.standard_english;
            if (wordInText(lower, english)) {
                try out.append(alloc, .{ .entry = e, .side = "input" });
            }
        }
        return out.toOwnedSlice(alloc);
    }
};

/// Whole-word, case-insensitive hit of `word` (already lowercase)
/// in `text`. Tokenizes `text` on the fly; no allocation.
fn wordInText(word: []const u8, text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !Dataset.isWordByte(text[i])) : (i += 1) {}
        if (i >= text.len) break;
        const start = i;
        while (i < text.len and Dataset.isWordByte(text[i])) : (i += 1) {}
        const token = text[start..i];
        if (token.len == word.len) {
            var same = true;
            for (token, word) |a, b| {
                var la = a;
                if (la >= 'A' and la <= 'Z') la += 'a' - 'A';
                if (la != b) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
    }
    return false;
}

/// All loaded language datasets, keyed by language code.
pub const Vocabulary = struct {
    alloc: std.mem.Allocator,
    datasets: std.StringHashMap(*Dataset),

    pub fn init(alloc: std.mem.Allocator) Vocabulary {
        return .{ .alloc = alloc, .datasets = std.StringHashMap(*Dataset).init(alloc) };
    }

    pub fn deinit(self: *Vocabulary) void {
        var it = self.datasets.valueIterator();
        while (it.next()) |d| {
            d.*.deinit();
            self.alloc.destroy(d.*);
        }
        self.datasets.deinit();
    }

    /// Load one language file and register it under `code`.
    pub fn load(self: *Vocabulary, io: std.Io, code: []const u8, path: []const u8) VocabError!void {
        const ds = try self.alloc.create(Dataset);
        errdefer self.alloc.destroy(ds);
        ds.* = try Dataset.loadFile(self.alloc, io, code, path);
        errdefer ds.deinit();
        try self.datasets.put(code, ds);
    }

    pub fn dataset(self: *const Vocabulary, code: []const u8) ?*Dataset {
        return self.datasets.get(code);
    }

    pub fn languageCount(self: *const Vocabulary) usize {
        return self.datasets.count();
    }
};

test "tokenize keeps apostrophes and tone marks" {
    const alloc = std.testing.allocator;
    const words = try Dataset.tokenize(alloc, "He ain't do it. Dō pā.");
    defer {
        for (words) |w| alloc.free(w);
        alloc.free(words);
    }
    try std.testing.expectEqual(@as(usize, 6), words.len);
    try std.testing.expectEqualStrings("ain't", words[1]);
    try std.testing.expectEqualStrings("dō", words[4]);
    try std.testing.expectEqualStrings("pā", words[5]);
}

test "dataset parses and looks up real entries" {
    const alloc = std.testing.allocator;
    // Two real entries, verbatim from datasets/koloqua.json and
    // datasets/bassa.json, cited by id.
    const json =
        \\[
        \\  {"id": "koloqua_00043", "types": "tense_progressive", "input": "I'm going.", "response": "I de go.", "standard_english": "I'm going.", "source": "Singler (1981)"},
        \\  {"id": "koloqua_00062", "types": "tense_completive", "input": "I have forgotten your name.", "response": "I fini forget/forgetting your name.", "standard_english": "I have forgotten your name.", "source": "Singler (1981)"}
        \\]
    ;
    var ds = try Dataset.loadJson(alloc, "kq", json);
    defer ds.deinit();
    try std.testing.expectEqual(@as(usize, 2), ds.count());

    // "fini" is a Koloqua completive marker (koloqua_00062).
    const hits = try ds.lookup(alloc, "fini", 8);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("koloqua_00062", hits[0].entry.id);
    try std.testing.expectEqualStrings("response", hits[0].side);

    // English -> Koloqua: "going" finds "I de go." (koloqua_00043).
    const en = try ds.lookupEnglish(alloc, "going", 8);
    defer alloc.free(en);
    try std.testing.expectEqual(@as(usize, 1), en.len);
    try std.testing.expectEqualStrings("I de go.", en[0].entry.response);

    try std.testing.expect(try ds.containsWord("fini"));
    // Short all-ASCII words are not wordlist evidence (see
    // ensureWordSet): "de" is a real Koloqua marker, but it scores
    // through the marker path in language.identify, not here.
    try std.testing.expect(!try ds.containsWord("de"));
    try std.testing.expect(!try ds.containsWord("zebra"));
}

test "bassa wordlist entry is found by its word" {
    const alloc = std.testing.allocator;
    // Verbatim from datasets/bassa.json (bassa_00001): "one" -> "dō".
    const json =
        \\[{"id": "bassa_00001", "types": "wordlist", "input": "one", "response": "dō", "standard_english": "one", "source": "lexibank/polyglottaafricana"}]
    ;
    var ds = try Dataset.loadJson(alloc, "bsq", json);
    defer ds.deinit();
    const hits = try ds.lookup(alloc, "dō", 8);
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("one", hits[0].entry.input);
    try std.testing.expect(try ds.containsWord("dō"));
}
