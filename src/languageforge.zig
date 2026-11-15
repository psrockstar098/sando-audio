//! LanguageForge groundwork (SANDO LanguageForge, schema only).
//!
//! This is the SHAPE of a community contribution — what a
//! contributed recording + transcript looks like — and the
//! validation that decides whether it may enter a language pack.
//! NO recordings are collected in this phase, no files are written
//! here, and no real person's voice is involved anywhere: the
//! tests use synthetic contributor ids, and the CLI only validates
//! a JSON file the operator hands it.
//!
//! Consent rules (from VoiceDNA, applied to every recording):
//! a contribution is valid only with a consent record naming the
//! contributor, the date, the allowed uses (scope), and stating
//! that consent is revocable. A missing or non-revocable consent
//! record is a validation failure, never a warning.

const std = @import("std");
const language = @import("language.zig");

/// One validation problem: which field, and why.
pub const Problem = struct {
    field: []const u8,
    message: []const u8,
};

/// Consent for one contributed recording. All strings are owned
/// by the Contribution's allocator (the parsed JSON).
pub const ConsentRecord = struct {
    /// Who granted consent (contributor id or name).
    granted_by: []const u8,
    /// ISO date, e.g. "2026-11-15".
    granted_at: []const u8,
    /// Comma-separated allowed uses, e.g. "asr,training".
    /// Must include at least one of "asr" or "training".
    scope: []const u8,
    /// Contributors must be able to withdraw: false is invalid.
    revocable: bool,
    /// The consent text the contributor agreed to.
    text: []const u8,
};

/// A contributed recording + transcript, as it would arrive from
/// the community. `audio_sha256` is the hash of the audio file
/// (the audio itself is never stored here); `transcript` is what
/// was said, in `language`.
pub const Contribution = struct {
    id: []const u8,
    language: []const u8,
    transcript: []const u8,
    /// 64 lowercase hex chars (SHA-256 of the audio file).
    audio_sha256: []const u8,
    /// "wav" | "flac" | "mp3" | "ogg".
    audio_format: []const u8,
    duration_ms: u64,
    speaker_id: []const u8,
    consent: ConsentRecord,

    /// Validate against the language registry. Returns the list of
    /// problems (owned; free the slice). Empty means valid.
    pub fn validate(self: *const Contribution, alloc: std.mem.Allocator) ![]Problem {
        var out = std.ArrayList(Problem).empty;
        errdefer out.deinit(alloc);
        if (self.id.len == 0) try out.append(alloc, .{ .field = "id", .message = "id is empty" });
        if (language.normalizeCode(self.language) == null) {
            try out.append(alloc, .{ .field = "language", .message = "language is not in the registry" });
        }
        if (self.transcript.len == 0) try out.append(alloc, .{ .field = "transcript", .message = "transcript is empty" });
        if (!isSha256(self.audio_sha256)) {
            try out.append(alloc, .{ .field = "audio_sha256", .message = "must be 64 lowercase hex characters" });
        }
        const fmt_ok = std.mem.eql(u8, self.audio_format, "wav") or
            std.mem.eql(u8, self.audio_format, "flac") or
            std.mem.eql(u8, self.audio_format, "mp3") or
            std.mem.eql(u8, self.audio_format, "ogg");
        if (!fmt_ok) try out.append(alloc, .{ .field = "audio_format", .message = "must be wav, flac, mp3 or ogg" });
        if (self.duration_ms == 0) try out.append(alloc, .{ .field = "duration_ms", .message = "duration must be over 0 ms" });
        if (self.speaker_id.len == 0) try out.append(alloc, .{ .field = "speaker_id", .message = "speaker_id is empty" });
        if (self.consent.granted_by.len == 0) try out.append(alloc, .{ .field = "consent.granted_by", .message = "consent must name who granted it" });
        if (self.consent.granted_at.len == 0) try out.append(alloc, .{ .field = "consent.granted_at", .message = "consent must carry a date" });
        if (!scopeHasUse(self.consent.scope)) {
            try out.append(alloc, .{ .field = "consent.scope", .message = "scope must allow asr or training" });
        }
        if (!self.consent.revocable) {
            try out.append(alloc, .{ .field = "consent.revocable", .message = "consent must be revocable" });
        }
        if (self.consent.text.len == 0) try out.append(alloc, .{ .field = "consent.text", .message = "consent text is empty" });
        return out.toOwnedSlice(alloc);
    }
};

fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return false;
    }
    return true;
}

fn scopeHasUse(scope: []const u8) bool {
    var it = std.mem.splitScalar(u8, scope, ',');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, p, "asr") or std.mem.eql(u8, p, "training")) return true;
    }
    return false;
}

const ContributionJson = struct {
    id: []const u8 = "",
    language: []const u8 = "",
    transcript: []const u8 = "",
    audio_sha256: []const u8 = "",
    audio_format: []const u8 = "",
    duration_ms: u64 = 0,
    speaker_id: []const u8 = "",
    consent: struct {
        granted_by: []const u8 = "",
        granted_at: []const u8 = "",
        scope: []const u8 = "",
        revocable: bool = false,
        text: []const u8 = "",
    } = .{},
};

/// Parse a contribution JSON document. The returned Contribution
/// owns its strings (allocated with `alloc`); free with `free`.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Contribution {
    const parsed = std.json.parseFromSlice(ContributionJson, alloc, bytes, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const j = parsed.value;
    return .{
        .id = try alloc.dupe(u8, j.id),
        .language = try alloc.dupe(u8, j.language),
        .transcript = try alloc.dupe(u8, j.transcript),
        .audio_sha256 = try alloc.dupe(u8, j.audio_sha256),
        .audio_format = try alloc.dupe(u8, j.audio_format),
        .duration_ms = j.duration_ms,
        .speaker_id = try alloc.dupe(u8, j.speaker_id),
        .consent = .{
            .granted_by = try alloc.dupe(u8, j.consent.granted_by),
            .granted_at = try alloc.dupe(u8, j.consent.granted_at),
            .scope = try alloc.dupe(u8, j.consent.scope),
            .revocable = j.consent.revocable,
            .text = try alloc.dupe(u8, j.consent.text),
        },
    };
}

pub fn freeContribution(alloc: std.mem.Allocator, c: *Contribution) void {
    alloc.free(c.id);
    alloc.free(c.language);
    alloc.free(c.transcript);
    alloc.free(c.audio_sha256);
    alloc.free(c.audio_format);
    alloc.free(c.speaker_id);
    alloc.free(c.consent.granted_by);
    alloc.free(c.consent.granted_at);
    alloc.free(c.consent.scope);
    alloc.free(c.consent.text);
    c.* = undefined;
}

/// Serialize a contribution to JSON (owned).
pub fn stringify(alloc: std.mem.Allocator, c: *const Contribution) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .id = c.id,
        .language = c.language,
        .transcript = c.transcript,
        .audio_sha256 = c.audio_sha256,
        .audio_format = c.audio_format,
        .duration_ms = c.duration_ms,
        .speaker_id = c.speaker_id,
        .consent = .{
            .granted_by = c.consent.granted_by,
            .granted_at = c.consent.granted_at,
            .scope = c.consent.scope,
            .revocable = c.consent.revocable,
            .text = c.consent.text,
        },
    }, .{});
}

test "a complete contribution with consent validates" {
    const alloc = std.testing.allocator;
    const json =
        \\{"id": "lf-test-001", "language": "kq", "transcript": "I de go.", "audio_sha256": "0000000000000000000000000000000000000000000000000000000000000000", "audio_format": "wav", "duration_ms": 1200, "speaker_id": "synthetic-test-speaker", "consent": {"granted_by": "synthetic-test-speaker", "granted_at": "2026-11-15", "scope": "asr,training", "revocable": true, "text": "I agree my recording may train Sando speech models."}}
    ;
    var c = try parse(alloc, json);
    defer freeContribution(alloc, &c);
    const problems = try c.validate(alloc);
    defer alloc.free(problems);
    try std.testing.expectEqual(@as(usize, 0), problems.len);

    // Round-trip: stringify then parse again, still valid.
    const out = try stringify(alloc, &c);
    defer alloc.free(out);
    var c2 = try parse(alloc, out);
    defer freeContribution(alloc, &c2);
    try std.testing.expectEqualStrings("I de go.", c2.transcript);
    const p2 = try c2.validate(alloc);
    defer alloc.free(p2);
    try std.testing.expectEqual(@as(usize, 0), p2.len);
}

test "missing consent fails validation" {
    const alloc = std.testing.allocator;
    var c = Contribution{
        .id = "lf-test-002",
        .language = "kq",
        .transcript = "I de go.",
        .audio_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        .audio_format = "wav",
        .duration_ms = 1200,
        .speaker_id = "synthetic-test-speaker",
        .consent = .{
            .granted_by = "",
            .granted_at = "",
            .scope = "display-only",
            .revocable = false,
            .text = "",
        },
    };
    const problems = try c.validate(alloc);
    defer alloc.free(problems);
    // granted_by, granted_at, scope, revocable, text = 5 problems.
    try std.testing.expectEqual(@as(usize, 5), problems.len);
}

test "bad hash, format and language fail validation" {
    const alloc = std.testing.allocator;
    var c = Contribution{
        .id = "lf-test-003",
        .language = "klingon",
        .transcript = "x",
        .audio_sha256 = "not-a-hash",
        .audio_format = "aiff",
        .duration_ms = 0,
        .speaker_id = "s",
        .consent = .{
            .granted_by = "s",
            .granted_at = "2026-11-15",
            .scope = "asr",
            .revocable = true,
            .text = "ok",
        },
    };
    const problems = try c.validate(alloc);
    defer alloc.free(problems);
    try std.testing.expectEqual(@as(usize, 4), problems.len);
}
