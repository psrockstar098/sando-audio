//! VoiceDNA: voice cloning + identity, with a hard consent rule.
//!
//! CONSENT RULE: no real person's voice recordings are ever enrolled.
//! The only reference-audio sources are:
//!   .synthetic    — generated here (a sine sweep), clearly labelled;
//!   .bundled_test — a WAV shipped in this repo under examples/
//!                    (test-fixture audio, no person behind it).
//! `enrollFromPath` refuses any other path with
//! error.RealVoiceNotAllowed. A profile records its source, whether
//! consent applies (synthetic audio involves no person; bundled test
//! audio is fixture data), who owns it and when it was created.
//! Deleting a profile removes its reference audio and its record.
//!
//! Style controls (emotion, rate, pitch, energy, language) are
//! applied to a request with `VoiceStyle.applyToRequest` — they ride
//! on the audio.cpp request setters bound in Phase 2. Speaker
//! identification reads the speaker turns a result already carries
//! (`identify`); no identification is ever invented.

const std = @import("std");
const audiocpp = @import("audiocpp.zig");
const audio = @import("audio.zig");

pub const VoiceError = error{
    RealVoiceNotAllowed,
    ProfileExists,
    ProfileNotFound,
    InvalidId,
    OutOfMemory,
    FileNotFound,
    InvalidProfile,
};

/// Where reference audio may come from. There is deliberately no
/// `.real_person_recording` variant.
pub const VoiceSource = enum {
    synthetic,
    bundled_test,

    pub fn name(self: VoiceSource) []const u8 {
        return switch (self) {
            .synthetic => "synthetic",
            .bundled_test => "bundled_test",
        };
    }
};

/// Expressive controls for a TTS/clone request. Every field is
/// optional; unset fields leave the model default alone.
pub const VoiceStyle = struct {
    emotion: ?[]const u8 = null,
    speaking_rate: ?f32 = null,
    pitch_shift: ?f32 = null,
    energy_scale: ?f32 = null,
    language: ?[]const u8 = null,

    pub fn applyToRequest(self: *const VoiceStyle, req: *audiocpp.Request, alloc: std.mem.Allocator) !void {
        if (self.emotion) |e| try req.setEmotion(alloc, e);
        if (self.speaking_rate) |r| try req.setSpeakingRate(r);
        if (self.pitch_shift) |p| try req.setPitchShift(p);
        if (self.energy_scale) |s| try req.setEnergyScale(s);
        if (self.language) |l| try req.setStyleLanguage(alloc, l);
    }
};

/// One enrolled voice. All strings are owned; free with deinit().
pub const VoiceProfile = struct {
    id: []const u8,
    name: []const u8,
    language: []const u8,
    source: VoiceSource,
    /// True when the reference audio may be used for cloning. Always
    /// true for the two allowed sources (neither involves a person).
    consent: bool = true,
    owner: []const u8 = "local",
    created_unix: i64 = 0,
    /// Path to the reference WAV, relative to the working directory.
    reference_wav: []const u8,

    pub fn deinit(self: *VoiceProfile, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.language);
        alloc.free(self.owner);
        alloc.free(self.reference_wav);
        self.* = undefined;
    }
};

/// JSON-backed store under `dir` (e.g. "voices", gitignored).
/// Profiles are `<id>.json`, reference audio `<id>.wav`.
pub const VoiceStore = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) VoiceStore {
        return .{ .alloc = alloc, .io = io, .dir = dir };
    }

    fn ensureDir(self: *const VoiceStore) void {
        // Best effort: writes fail honestly later if the dir is missing.
        std.Io.Dir.cwd().createDirPath(self.io, self.dir) catch {};
    }

    /// Wall-clock seconds since the Unix epoch.
    fn nowUnix(io: std.Io) i64 {
        const ts = std.Io.Clock.Timestamp.now(io, .real);
        return @intCast(@divFloor(ts.raw.nanoseconds, 1_000_000_000));
    }

    fn jsonPath(self: *const VoiceStore, alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ self.dir, id });
    }

    fn wavPath(self: *const VoiceStore, alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}.wav", .{ self.dir, id });
    }

    fn validId(id: []const u8) bool {
        if (id.len == 0 or id.len > 64) return false;
        for (id) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
        }
        return true;
    }

    /// Enroll a synthetic voice: generates a 2 s sine-sweep reference
    /// (220 → 440 Hz, 24 kHz mono) and stores the profile. No person
    /// is involved, so consent is recorded as true.
    pub fn enrollSynthetic(self: *const VoiceStore, id: []const u8, name: []const u8, language: []const u8) !VoiceProfile {
        if (!validId(id)) return error.InvalidId;
        self.ensureDir();
        const jp = try self.jsonPath(self.alloc, id);
        defer self.alloc.free(jp);
        if (std.Io.Dir.cwd().access(self.io, jp, .{})) |_| return error.ProfileExists else |_| {}

        const samples = try self.alloc.alloc(f32, 48000);
        defer self.alloc.free(samples);
        for (0..samples.len) |i| {
            const t = @as(f32, @floatFromInt(i)) / 24000.0;
            const freq = 220.0 + 220.0 * t / 2.0;
            const env = @min(1.0, @min(t * 100.0, (2.0 - t) * 100.0));
            samples[i] = 0.5 * env * @sin(2.0 * std.math.pi * freq * t);
        }
        const wav_bytes = try audio.writeWav(self.alloc, samples, 24000, 1, .pcm16);
        defer self.alloc.free(wav_bytes);
        const wp = try self.wavPath(self.alloc, id);
        defer self.alloc.free(wp);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = wp, .data = wav_bytes });

        var profile = VoiceProfile{
            .id = try self.alloc.dupe(u8, id),
            .name = try self.alloc.dupe(u8, name),
            .language = try self.alloc.dupe(u8, language),
            .source = .synthetic,
            .consent = true,
            .owner = try self.alloc.dupe(u8, "local"),
            .created_unix = nowUnix(self.io),
            .reference_wav = try self.alloc.dupe(u8, wp),
        };
        errdefer profile.deinit(self.alloc);
        const json = try std.fmt.allocPrint(self.alloc, "{f}", .{std.json.fmt(profile, .{})});
        defer self.alloc.free(json);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = jp, .data = json });
        return profile;
    }

    /// Enroll from a bundled test WAV. Only paths under `examples/`
    /// are accepted; anything else is refused as a real-person
    /// recording (see the consent rule above).
    pub fn enrollFromPath(self: *const VoiceStore, path: []const u8, id: []const u8, name: []const u8, language: []const u8) !VoiceProfile {
        if (!std.mem.startsWith(u8, path, "examples/")) return error.RealVoiceNotAllowed;
        if (!validId(id)) return error.InvalidId;
        self.ensureDir();
        const jp = try self.jsonPath(self.alloc, id);
        defer self.alloc.free(jp);
        if (std.Io.Dir.cwd().access(self.io, jp, .{})) |_| return error.ProfileExists else |_| {}

        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(1 << 24)) catch
            return error.FileNotFound;
        defer self.alloc.free(bytes);
        const wp = try self.wavPath(self.alloc, id);
        defer self.alloc.free(wp);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = wp, .data = bytes });

        var profile = VoiceProfile{
            .id = try self.alloc.dupe(u8, id),
            .name = try self.alloc.dupe(u8, name),
            .language = try self.alloc.dupe(u8, language),
            .source = .bundled_test,
            .consent = true,
            .owner = try self.alloc.dupe(u8, "local"),
            .created_unix = nowUnix(self.io),
            .reference_wav = try self.alloc.dupe(u8, wp),
        };
        errdefer profile.deinit(self.alloc);
        const json = try std.fmt.allocPrint(self.alloc, "{f}", .{std.json.fmt(profile, .{})});
        defer self.alloc.free(json);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = jp, .data = json });
        return profile;
    }

    /// Read one profile by id. Returns null when it does not exist.
    pub fn get(self: *const VoiceStore, id: []const u8) !?VoiceProfile {
        if (!validId(id)) return error.InvalidId;
        const jp = try self.jsonPath(self.alloc, id);
        defer self.alloc.free(jp);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, jp, self.alloc, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.alloc.free(bytes);
        return try parseProfile(self.alloc, bytes);
    }

    /// List every profile in the store, sorted by id.
    pub fn list(self: *const VoiceStore) ![]VoiceProfile {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer dir.close(self.io);
        var out: std.ArrayList(VoiceProfile) = .empty;
        errdefer {
            for (out.items) |*p| p.deinit(self.alloc);
            out.deinit(self.alloc);
        }
        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const id = entry.name[0 .. entry.name.len - 5];
            if (try self.get(id)) |p| try out.append(self.alloc, p);
        }
        std.mem.sort(VoiceProfile, out.items, {}, struct {
            fn lt(_: void, a: VoiceProfile, b: VoiceProfile) bool {
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.lt);
        return out.toOwnedSlice(self.alloc);
    }

    /// Delete a profile and its reference audio. Missing files are
    /// tolerated; a missing profile record is an error.
    pub fn delete(self: *const VoiceStore, id: []const u8) !void {
        if (!validId(id)) return error.InvalidId;
        const jp = try self.jsonPath(self.alloc, id);
        defer self.alloc.free(jp);
        const wp = try self.wavPath(self.alloc, id);
        defer self.alloc.free(wp);
        std.Io.Dir.cwd().deleteFile(self.io, jp) catch |err| {
            if (err == error.FileNotFound) return error.ProfileNotFound;
            return err;
        };
        std.Io.Dir.cwd().deleteFile(self.io, wp) catch {};
    }
};

fn parseProfile(alloc: std.mem.Allocator, bytes: []const u8) !VoiceProfile {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(VoiceProfile, arena.allocator(), bytes, .{}) catch
        return error.InvalidProfile;
    const p = parsed.value;
    return .{
        .id = try alloc.dupe(u8, p.id),
        .name = try alloc.dupe(u8, p.name),
        .language = try alloc.dupe(u8, p.language),
        .source = p.source,
        .consent = p.consent,
        .owner = try alloc.dupe(u8, p.owner),
        .created_unix = p.created_unix,
        .reference_wav = try alloc.dupe(u8, p.reference_wav),
    };
}

/// Speaker identification from a result's speaker turns. Returns the
/// turns the model actually produced — never invented.
pub fn identify(result: *const audiocpp.Result, alloc: std.mem.Allocator) ![]audiocpp.SpeakerTurn {
    return result.speakerTurns(alloc);
}

test "synthetic enrollment roundtrips through the store" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/voices", .{tmp.sub_path});
    defer alloc.free(dir);
    const store = VoiceStore.init(alloc, io, dir);
    var profile = try store.enrollSynthetic("test-voice-01", "Test Voice", "en");
    defer profile.deinit(alloc);
    try std.testing.expectEqual(VoiceSource.synthetic, profile.source);
    try std.testing.expect(profile.consent);
    // Reference WAV exists and parses as a 2 s mono WAV.
    var wav = try audio.readWavFile(alloc, io, profile.reference_wav);
    defer wav.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 24000), wav.sample_rate);
    try std.testing.expectEqual(@as(usize, 48000), wav.samples.len);

    const got = (try store.get("test-voice-01")).?;
    defer {
        var g = got;
        g.deinit(alloc);
    }
    try std.testing.expectEqualStrings("Test Voice", got.name);
    try std.testing.expectEqualStrings("en", got.language);

    const listed = try store.list();
    defer {
        for (listed) |*p| p.deinit(alloc);
        alloc.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("test-voice-01", listed[0].id);

    try std.testing.expectError(error.ProfileExists, store.enrollSynthetic("test-voice-01", "Again", "en"));
    try store.delete("test-voice-01");
    try std.testing.expect((try store.get("test-voice-01")) == null);
    try std.testing.expectError(error.ProfileNotFound, store.delete("test-voice-01"));
}

test "enrollFromPath refuses real-person audio paths" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/voices", .{tmp.sub_path});
    defer alloc.free(dir);
    const store = VoiceStore.init(alloc, io, dir);
    try std.testing.expectError(error.RealVoiceNotAllowed, store.enrollFromPath("/home/dominic/voice.wav", "v1", "Mine", "en"));
    try std.testing.expectError(error.RealVoiceNotAllowed, store.enrollFromPath("models/someone.wav", "v1", "Mine", "en"));
    try std.testing.expectError(error.InvalidId, store.enrollSynthetic("bad id!", "x", "en"));
}

test "voice style applies to a live request" {
    if (!audiocpp.has_link) return; // needs the linked library
    const alloc = std.testing.allocator;
    var req = try audiocpp.Request.create();
    defer req.deinit();
    const style = VoiceStyle{
        .emotion = "happy",
        .speaking_rate = 1.1,
        .pitch_shift = 2.0,
        .energy_scale = 0.9,
        .language = "en",
    };
    try style.applyToRequest(&req, alloc);
}
