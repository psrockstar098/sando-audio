//! AudioSense: noise / echo / enhancement / separation / diarization.
//!
//! The module is a capability-first interface over audio.cpp. What it
//! can do depends entirely on which families are linked into the
//! library in use — `Capabilities.fromFamilies` reads the live family
//! list and reports honestly. Families that are not linked are
//! reported as unavailable, never stubbed:
//!
//! - Separation (`sep` task): htdemucs, bs_roformer, mel_band_roformer,
//!   tf_gridnet, mossformer2, mulacover.
//! - Diarization (speaker turns on a result): sortformer_diar,
//!   nemotron_3_diar, moss_transcribe_diarize — plus any ASR result
//!   that already carries speaker turns.
//! - VAD: the silero/marblenet VAD built into the runtime, firered_vad,
//!   pulsevad.
//! - Enhancement / echo cancellation: no dedicated family is linked in
//!   the current build, so `enhancement` is false and enhancement
//!   requests fail honestly with error.NotAvailable. This is a real
//!   gap, not a silent pass-through.
//!
//! Diarization never needs a separate model: `speakerTurns` reads the
//! turns an ASR/diarization result already carries.

const std = @import("std");
const audiocpp = @import("audiocpp.zig");
const runtime = @import("runtime.zig");

/// What the linked library can actually do, derived from its family
/// list. `family_count` is the raw registry size for the report.
pub const Capabilities = struct {
    separation: bool = false,
    diarization: bool = false,
    enhancement: bool = false,
    vad: bool = false,
    family_count: usize = 0,

    const separation_families = [_][]const u8{
        "htdemucs", "htdemucs_6stems", "bs_roformer",
        "mel_band_roformer", "tf_gridnet", "mossformer2",
        "mulacover",
    };
    const diarization_families = [_][]const u8{
        "sortformer_diar", "sortformer_diar_v2",
        "nemotron_3_diar", "moss_transcribe_diarize",
    };
    const vad_families = [_][]const u8{
        "firered_vad", "pulsevad",
    };

    /// Pure: compute capabilities from a family name list.
    pub fn fromFamilies(families: []const []const u8) Capabilities {
        var caps = Capabilities{ .family_count = families.len };
        for (families) |fam| {
            for (separation_families) |known| {
                if (std.mem.eql(u8, fam, known)) caps.separation = true;
            }
            for (diarization_families) |known| {
                if (std.mem.eql(u8, fam, known)) caps.diarization = true;
            }
            for (vad_families) |known| {
                if (std.mem.eql(u8, fam, known)) caps.vad = true;
            }
            // silero/marblenet VAD are built into the runtime objects,
            // so the `vad` task is available whenever the library is
            // linked at all (the task list proves it).
            if (std.mem.eql(u8, fam, "silero_vad") or std.mem.eql(u8, fam, "marblenet_vad")) {
                caps.vad = true;
            }
        }
        return caps;
    }

    /// Live: compute capabilities from a registry.
    pub fn fromRegistry(alloc: std.mem.Allocator, registry: *audiocpp.Registry) !Capabilities {
        const n = registry.familyCount();
        var names = try alloc.alloc([]const u8, n);
        defer alloc.free(names);
        for (0..n) |i| names[i] = try registry.family(i);
        var caps = fromFamilies(names);
        // The task list is the ground truth for VAD: if the library
        // exposes a `vad` task, VAD works even when no vad family is
        // named in the registry (builtin silero).
        var ti: usize = 0;
        while (ti < audiocpp.taskCount()) : (ti += 1) {
            if (audiocpp.taskName(ti)) |t| {
                if (std.mem.eql(u8, t, "vad")) caps.vad = true;
            }
        }
        return caps;
    }
};

/// Speaker turns carried by a result (diarization). Borrowed from
/// the result; valid until the result is freed.
pub fn speakerTurns(result: *const audiocpp.Result, alloc: std.mem.Allocator) ![]audiocpp.SpeakerTurn {
    return result.speakerTurns(alloc);
}

/// Separate one audio buffer into its stems with a `sep` session.
/// Returns the named audio outputs (one per stem) plus the response
/// that owns them — keep the response alive while using the stems,
/// then deinit it. The session already carries its task ("sep"), so
/// the request is audio-only.
pub fn separateWithSession(
    session: *runtime.Session,
    alloc: std.mem.Allocator,
    samples: []const f32,
    sample_rate: u32,
    channels: u8,
) !struct { response: runtime.Response, stems: []audiocpp.NamedAudio } {
    var request = try audiocpp.Request.create();
    defer request.deinit();
    try request.setAudio(samples, sample_rate, channels);
    const result = try session.inner.run(&request);
    var response = runtime.Response{ .result = result, .latency_ns = 0 };
    errdefer response.deinit();
    const stems = try response.result.namedAudio(alloc);
    return .{ .response = response, .stems = stems };
}

test "capabilities from a family list" {
    const caps = Capabilities.fromFamilies(&.{ "qwen3_tts", "moonshine_asr", "htdemucs", "sortformer_diar" });
    try std.testing.expect(caps.separation);
    try std.testing.expect(caps.diarization);
    try std.testing.expect(!caps.enhancement);
    try std.testing.expect(!caps.vad);
    try std.testing.expectEqual(@as(usize, 4), caps.family_count);

    const bare = Capabilities.fromFamilies(&.{ "qwen3_tts", "moonshine_asr" });
    try std.testing.expect(!bare.separation);
    try std.testing.expect(!bare.diarization);
    try std.testing.expect(!bare.enhancement);
    try std.testing.expect(!bare.vad);
}

test "capabilities: builtin vad families count" {
    const caps = Capabilities.fromFamilies(&.{ "silero_vad", "marblenet_vad" });
    try std.testing.expect(caps.vad);
    try std.testing.expect(!caps.separation);
}
