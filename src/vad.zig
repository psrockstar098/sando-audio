//! Voice activity detection.
//!
//! Two layers, kept strictly separate so a caller can never mistake one
//! for the other:
//!
//! 1. `VadTracker` — a pure state machine over the VAD activity events a
//!    streaming session emits (speech_start / speech_end / speech_segment
//!    with sample offsets and probabilities). It turns the event stream
//!    into speech segments and answers "has the speaker stopped?"
//!    (endpoint detection) with a configurable silence threshold.
//!    This is the layer the LiveStream Engine uses with a real vad
//!    session (silero-vad) whenever a vad model is loaded.
//!
//! 2. `EnergyVad` — an honest, labelled fallback: RMS energy + hysteresis
//!    over short frames. It is NOT silero-vad and is always reported as
//!    "energy" (see `source()`), so offline WAV analysis and the
//!    null-device path can still find speech boundaries when no VAD
//!    model weights are present. It is a real detector (adaptive noise
//!    floor, onset/offset hysteresis, minimum speech duration), not a
//!    stub — but it must never be presented as a model result.

const std = @import("std");
const audiocpp = @import("audiocpp.zig");

/// One detected speech segment, in samples at the stream's sample rate.
pub const VadSegment = struct {
    start_sample: i64,
    end_sample: i64,
    /// Highest VAD probability seen inside the segment (0..1).
    peak_probability: f32,
};

/// Pure VAD event state machine. Owns its segment list.
pub const VadTracker = struct {
    alloc: std.mem.Allocator,
    sample_rate: u32,
    /// Silence (ms) after the last speech activity before the speaker
    /// counts as finished. Adaptive endpoint detection in the
    /// LiveStream Engine shortens this when the partial transcript
    /// looks complete; see streaming.zig.
    silence_ms: u32 = 600,
    in_speech: bool = false,
    speech_start_sample: i64 = 0,
    last_activity_sample: i64 = 0,
    peak_probability: f32 = 0,
    segments: std.ArrayList(VadSegment) = .empty,

    pub fn init(alloc: std.mem.Allocator, sample_rate: u32) VadTracker {
        return .{ .alloc = alloc, .sample_rate = sample_rate };
    }

    pub fn deinit(self: *VadTracker) void {
        self.segments.deinit(self.alloc);
        self.* = undefined;
    }

    fn silenceSamples(self: *const VadTracker) i64 {
        return @intCast(@as(u64, self.sample_rate) * self.silence_ms / 1000);
    }

    /// Feed one VAD activity event from the stream.
    pub fn feed(self: *VadTracker, activity: audiocpp.VadActivity) !void {
        switch (activity.kind) {
            .speech_start => {
                if (!self.in_speech) {
                    self.in_speech = true;
                    self.speech_start_sample = activity.sample;
                    self.peak_probability = activity.probability;
                }
                self.last_activity_sample = activity.sample;
            },
            .speech_segment => {
                if (self.in_speech) {
                    self.last_activity_sample = activity.sample;
                    self.peak_probability = @max(self.peak_probability, activity.probability);
                }
            },
            .speech_end => {
                if (self.in_speech) {
                    try self.closeSegment(activity.sample);
                }
                self.last_activity_sample = activity.sample;
            },
        }
    }

    fn closeSegment(self: *VadTracker, end_sample: i64) !void {
        try self.segments.append(self.alloc, .{
            .start_sample = self.speech_start_sample,
            .end_sample = end_sample,
            .peak_probability = self.peak_probability,
        });
        self.in_speech = false;
        self.peak_probability = 0;
    }

    /// True when the speaker has been silent for at least `silence_ms`
    /// after speech started. `now_sample` is the current stream offset.
    pub fn endpointDetected(self: *const VadTracker, now_sample: i64) bool {
        if (!self.in_speech) return false;
        return now_sample - self.last_activity_sample >= self.silenceSamples();
    }

    /// Force-close an open segment at `end_sample` (end of stream).
    pub fn finish(self: *VadTracker, end_sample: i64) !void {
        if (self.in_speech) try self.closeSegment(end_sample);
    }

    pub fn segmentCount(self: *const VadTracker) usize {
        return self.segments.items.len;
    }
};

/// Which detector produced a result. Never report "energy" as a model.
pub const VadSource = enum { model, energy };

/// RMS-energy VAD with an adaptive noise floor and hysteresis.
///
/// Frames are 10 ms by default. Speech starts after 2 consecutive
/// frames above the onset threshold and ends after 30 consecutive
/// frames below the offset threshold; segments shorter than 100 ms
/// are discarded as noise bursts. Probabilities are the RMS-to-floor
/// ratio clamped to 0..1 — a confidence proxy, not a model score.
pub const EnergyVad = struct {
    sample_rate: u32,
    frame_samples: usize,
    /// Absolute RMS floor: anything below this is silence regardless
    /// of the adaptive estimate (guards against a floor of 0).
    absolute_floor: f32 = 0.0005,
    /// Onset when RMS > floor * onset_ratio for `onset_frames` in a row.
    onset_ratio: f32 = 4.0,
    onset_frames: u32 = 2,
    /// Offset when RMS < floor * offset_ratio for `offset_frames` in a row.
    offset_ratio: f32 = 2.0,
    offset_frames: u32 = 30,
    /// Segments shorter than this are discarded.
    min_speech_ms: u32 = 100,

    noise_floor: f32 = 0.001,
    above: u32 = 0,
    below: u32 = 0,
    in_speech: bool = false,
    speech_start_sample: i64 = 0,
    /// End of the last frame that was loud enough to count as speech.
    /// The minimum-speech check uses this, not the offset-trigger frame,
    /// so the 300 ms offset hangover cannot rescue a short noise blip.
    last_speech_sample: i64 = 0,
    sample_offset: i64 = 0,

    pub fn init(sample_rate: u32) EnergyVad {
        return .{
            .sample_rate = sample_rate,
            .frame_samples = sample_rate / 100,
        };
    }

    pub fn source(_: *const EnergyVad) VadSource {
        return .energy;
    }

    /// Feed interleaved mono float PCM. Returns a VAD activity event
    /// when a speech boundary is crossed, or null. At most one event
    /// per call (the first boundary); the frame clock always advances
    /// over the whole input either way. The caller owns the returned
    /// event value (plain data, no allocation).
    pub fn feed(self: *EnergyVad, samples: []const f32) ?audiocpp.VadActivity {
        var first_event: ?audiocpp.VadActivity = null;
        var i: usize = 0;
        while (i < samples.len) {
            const end = @min(i + self.frame_samples, samples.len);
            const frame = samples[i..end];
            const rms = frameRms(frame);
            const frame_start = self.sample_offset + @as(i64, @intCast(i));
            if (first_event == null) {
                if (self.stepFrame(rms, frame_start)) |ev| first_event = ev;
            } else {
                _ = self.stepFrame(rms, frame_start);
            }
            i = end;
        }
        self.sample_offset += @intCast(samples.len);
        return first_event;
    }

    fn stepFrame(self: *EnergyVad, rms: f32, frame_start: i64) ?audiocpp.VadActivity {
        // Adapt the noise floor slowly while not in speech; freeze it
        // during speech so loud speech cannot raise its own bar.
        if (!self.in_speech) {
            self.noise_floor = self.noise_floor * 0.95 + rms * 0.05;
            if (self.noise_floor < self.absolute_floor) self.noise_floor = self.absolute_floor;
        }
        const prob = @min(1.0, rms / @max(self.noise_floor * self.onset_ratio, 1e-6));
        if (!self.in_speech) {
            if (rms > self.noise_floor * self.onset_ratio) {
                self.above += 1;
                if (self.above >= self.onset_frames) {
                    self.in_speech = true;
                    self.speech_start_sample = frame_start - @as(i64, @intCast((self.above - 1) * self.frame_samples));
                    self.last_speech_sample = frame_start + @as(i64, @intCast(self.frame_samples));
                    self.below = 0;
                    return .{ .kind = .speech_start, .sample = self.speech_start_sample, .probability = prob };
                }
            } else {
                self.above = 0;
            }
            return null;
        }
        // In speech.
        if (rms < self.noise_floor * self.offset_ratio) {
            self.below += 1;
            if (self.below >= self.offset_frames) {
                self.in_speech = false;
                self.above = 0;
                const end = frame_start + @as(i64, @intCast(self.frame_samples));
                const dur_ms = @divTrunc(@as(i64, @intCast((self.last_speech_sample - self.speech_start_sample) * 1000)), @as(i64, @intCast(self.sample_rate)));
                if (dur_ms < self.min_speech_ms) return null; // noise burst: swallow the segment
                return .{ .kind = .speech_end, .sample = end, .probability = prob };
            }
        } else {
            self.below = 0;
            self.last_speech_sample = frame_start + @as(i64, @intCast(self.frame_samples));
        }
        return null;
    }
};

fn frameRms(frame: []const f32) f32 {
    if (frame.len == 0) return 0;
    var sum: f64 = 0;
    for (frame) |s| sum += @as(f64, s) * @as(f64, s);
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(frame.len))));
}

test "tracker builds segments from activity events" {
    const alloc = std.testing.allocator;
    var t = VadTracker.init(alloc, 24000);
    defer t.deinit();
    try t.feed(.{ .kind = .speech_start, .sample = 2400, .probability = 0.9 });
    try t.feed(.{ .kind = .speech_segment, .sample = 12000, .probability = 0.95 });
    try std.testing.expect(!t.endpointDetected(20000));
    try std.testing.expect(t.endpointDetected(12000 + 14400)); // 600 ms of silence
    try t.feed(.{ .kind = .speech_end, .sample = 26400, .probability = 0.8 });
    try std.testing.expectEqual(@as(usize, 1), t.segmentCount());
    const seg = t.segments.items[0];
    try std.testing.expectEqual(@as(i64, 2400), seg.start_sample);
    try std.testing.expectEqual(@as(i64, 26400), seg.end_sample);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), seg.peak_probability, 0.001);
    try std.testing.expect(!t.endpointDetected(100000));
}

test "tracker finish closes an open segment" {
    const alloc = std.testing.allocator;
    var t = VadTracker.init(alloc, 16000);
    defer t.deinit();
    try t.feed(.{ .kind = .speech_start, .sample = 0, .probability = 0.7 });
    try t.finish(16000);
    try std.testing.expectEqual(@as(usize, 1), t.segmentCount());
    try std.testing.expectEqual(@as(i64, 16000), t.segments.items[0].end_sample);
}

test "energy vad finds a loud burst and ignores silence" {
    var vad = EnergyVad.init(24000);
    try std.testing.expect(vad.source() == .energy);
    // 1 s of silence: no events.
    var silence: [24000]f32 = undefined;
    @memset(&silence, 0);
    try std.testing.expect(vad.feed(&silence) == null);
    // 0.5 s of loud sine (speech-like energy), then 1 s of silence.
    var burst: [12000]f32 = undefined;
    for (0..burst.len) |i| {
        burst[i] = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.05);
    }
    var saw_start = false;
    var chunk: usize = 0;
    while (chunk < burst.len) : (chunk += 2400) {
        if (vad.feed(burst[chunk..@min(chunk + 2400, burst.len)])) |ev| {
            if (ev.kind == .speech_start) saw_start = true;
        }
    }
    try std.testing.expect(saw_start);
    var saw_end = false;
    chunk = 0;
    while (chunk < silence.len) : (chunk += 2400) {
        if (vad.feed(silence[chunk..@min(chunk + 2400, silence.len)])) |ev| {
            if (ev.kind == .speech_end) saw_end = true;
        }
    }
    try std.testing.expect(saw_end);
}

test "energy vad ignores a sub-100ms noise blip" {
    var vad = EnergyVad.init(24000);
    var blip: [1200]f32 = undefined; // 50 ms
    for (0..blip.len) |i| blip[i] = 0.8 * @sin(@as(f32, @floatFromInt(i)) * 0.2);
    _ = vad.feed(&blip);
    var silence: [24000]f32 = undefined;
    @memset(&silence, 0);
    var got_end = false;
    var chunk: usize = 0;
    while (chunk < silence.len) : (chunk += 2400) {
        if (vad.feed(silence[chunk..@min(chunk + 2400, silence.len)])) |ev| {
            if (ev.kind == .speech_end) got_end = true;
        }
    }
    try std.testing.expect(!got_end);
}
