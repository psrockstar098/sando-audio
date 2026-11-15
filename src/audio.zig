//! Audio I/O for Phase 1: WAV file reading/writing (offline mode) and a
//! null device (silence) for smoke tests.
//!
//! Live capture/playback (microphone/speaker) is NOT in Phase 1: no
//! PortAudio/ALSA backend is vendored, and this VM has no /dev/snd.
//! Real device I/O lands in Phase 2. The engine never pretends a
//! device exists — `live_audio_status` says so plainly.

const std = @import("std");

/// Plain-words status for live device I/O.
pub const live_audio_status = "unavailable: no audio device backend in Phase 1 (use --wav input for offline mode)";

pub const WavFormat = enum { pcm16, float32 };

pub const WavError = error{
    InvalidWav,
    UnsupportedFormat,
    Truncated,
    OutOfMemory,
};

pub const WavData = struct {
    samples: []f32, // interleaved, owned
    sample_rate: u32,
    channels: u8,

    pub fn deinit(self: *WavData, alloc: std.mem.Allocator) void {
        alloc.free(self.samples);
        self.* = undefined;
    }

    pub fn frames(self: *const WavData) usize {
        return self.samples.len / self.channels;
    }

    /// Duration in seconds.
    pub fn durationSeconds(self: *const WavData) f64 {
        return @as(f64, @floatFromInt(self.frames())) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// Encode interleaved float PCM as a complete WAV file in memory.
/// Caller owns the returned bytes.
pub fn writeWav(alloc: std.mem.Allocator, samples: []const f32, sample_rate: u32, channels: u8, format: WavFormat) ![]u8 {
    if (channels == 0) return error.InvalidWav;
    if (samples.len % channels != 0) return error.InvalidWav; // partial frame
    const bytes_per_sample: usize = switch (format) {
        .pcm16 => 2,
        .float32 => 4,
    };
    const data_bytes = samples.len * bytes_per_sample;
    const total = 44 + data_bytes;
    const out = try alloc.alloc(u8, total);
    errdefer alloc.free(out);

    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(36 + data_bytes), .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], switch (format) {
        .pcm16 => 1,
        .float32 => 3,
    }, .little);
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], @intCast(sample_rate * @as(u32, channels) * @as(u32, @intCast(bytes_per_sample))), .little);
    std.mem.writeInt(u16, out[32..34], @intCast(channels * bytes_per_sample), .little);
    std.mem.writeInt(u16, out[34..36], @intCast(bytes_per_sample * 8), .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], @intCast(data_bytes), .little);

    switch (format) {
        .pcm16 => {
            for (samples, 0..) |s, i| {
                const clamped = @max(-1.0, @min(1.0, s));
                const v: i16 = @intFromFloat(@round(clamped * 32767.0));
                std.mem.writeInt(i16, out[44 + i * 2 ..][0..2], v, .little);
            }
        },
        .float32 => {
            for (samples, 0..) |s, i| {
                std.mem.writeInt(u32, out[44 + i * 4 ..][0..4], @bitCast(s), .little);
            }
        },
    }
    return out;
}

/// Decode a WAV file from memory. Supports 16-bit PCM and 32-bit float.
/// Caller owns the returned samples.
pub fn parseWav(alloc: std.mem.Allocator, bytes: []const u8) !WavData {
    if (bytes.len < 44) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return error.InvalidWav;
    if (!std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWav;

    var pos: usize = 12;
    var audio_format: u16 = 0;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var data_start: ?usize = null;
    var data_len: usize = 0;
    var saw_fmt = false;

    while (pos + 8 <= bytes.len) {
        const id = bytes[pos .. pos + 4];
        const size = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        const chunk_start = pos + 8;
        if (chunk_start + size > bytes.len) return error.Truncated;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return error.InvalidWav;
            audio_format = std.mem.readInt(u16, bytes[chunk_start..][0..2], .little);
            channels = std.mem.readInt(u16, bytes[chunk_start + 2 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, bytes[chunk_start + 4 ..][0..4], .little);
            bits_per_sample = std.mem.readInt(u16, bytes[chunk_start + 14 ..][0..2], .little);
            saw_fmt = true;
        } else if (std.mem.eql(u8, id, "data")) {
            data_start = chunk_start;
            data_len = size;
            break; // data is conventionally last; stop here
        }
        // Chunks are word-aligned: odd sizes have a pad byte.
        pos = chunk_start + size + (size & 1);
    }

    if (!saw_fmt) return error.InvalidWav;
    const start = data_start orelse return error.InvalidWav;
    if (channels == 0 or channels > 2) return error.UnsupportedFormat;
    if (sample_rate == 0) return error.InvalidWav;

    const format: WavFormat = switch (audio_format) {
        1 => blk: {
            if (bits_per_sample != 16) return error.UnsupportedFormat;
            break :blk .pcm16;
        },
        3 => blk: {
            if (bits_per_sample != 32) return error.UnsupportedFormat;
            break :blk .float32;
        },
        else => return error.UnsupportedFormat,
    };

    const bytes_per_sample: usize = switch (format) {
        .pcm16 => 2,
        .float32 => 4,
    };
    const frame_bytes = @as(usize, channels) * bytes_per_sample;
    if (data_len % frame_bytes != 0) return error.InvalidWav;
    const count = data_len / bytes_per_sample;

    const samples = try alloc.alloc(f32, count);
    errdefer alloc.free(samples);
    switch (format) {
        .pcm16 => {
            for (0..count) |i| {
                const v = std.mem.readInt(i16, bytes[start + i * 2 ..][0..2], .little);
                samples[i] = @as(f32, @floatFromInt(v)) / 32768.0;
            }
        },
        .float32 => {
            for (0..count) |i| {
                const bits = std.mem.readInt(u32, bytes[start + i * 4 ..][0..4], .little);
                samples[i] = @bitCast(bits);
            }
        },
    }
    return .{
        .samples = samples,
        .sample_rate = sample_rate,
        .channels = @intCast(channels),
    };
}

/// Read a WAV file from disk (relative to the working directory).
pub fn readWavFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !WavData {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 28));
    defer alloc.free(bytes);
    return parseWav(alloc, bytes);
}

/// Write a WAV file to disk (relative to the working directory).
pub fn writeWavFile(io: std.Io, path: []const u8, samples: []const f32, sample_rate: u32, channels: u8, format: WavFormat) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const bytes = try writeWav(arena.allocator(), samples, sample_rate, channels, format);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Null device: fills a buffer with silence. For smoke tests without
/// hardware — never presented as a real capture device.
pub fn readSilence(samples: []f32) void {
    @memset(samples, 0);
}

test "float32 wav roundtrip" {
    const alloc = std.testing.allocator;
    var samples: [480]f32 = undefined;
    for (&samples, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1);
    }
    const bytes = try writeWav(alloc, &samples, 24000, 1, .float32);
    defer alloc.free(bytes);
    var wav = try parseWav(alloc, bytes);
    defer wav.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 24000), wav.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), wav.channels);
    try std.testing.expectEqual(@as(usize, 480), wav.frames());
    for (samples, wav.samples) |a, b| {
        try std.testing.expectEqual(a, b);
    }
}

test "pcm16 wav roundtrip within quantization" {
    const alloc = std.testing.allocator;
    const samples = [_]f32{ 0.0, 0.5, -0.5, 1.0, -1.0, 0.25, -0.25, 0.75 };
    const bytes = try writeWav(alloc, &samples, 48000, 2, .pcm16);
    defer alloc.free(bytes);
    var wav = try parseWav(alloc, bytes);
    defer wav.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 48000), wav.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), wav.channels);
    for (samples, wav.samples) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 1.0 / 32768.0 + 1e-6);
    }
}

test "malformed wav rejected" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.Truncated, parseWav(alloc, "RIFF"));
    var bad: [44]u8 = undefined;
    @memset(&bad, 0);
    @memcpy(bad[0..4], "NOPE");
    try std.testing.expectError(error.InvalidWav, parseWav(alloc, &bad));
    // Valid header shape but unsupported format (6 = a-law).
    var bytes = try writeWav(alloc, &[_]f32{0.0}, 24000, 1, .pcm16);
    defer alloc.free(bytes);
    std.mem.writeInt(u16, bytes[20..22], 6, .little);
    try std.testing.expectError(error.UnsupportedFormat, parseWav(alloc, bytes));
}

test "wav file roundtrip through a temp dir" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const samples = [_]f32{ 0.1, -0.2, 0.3, -0.4 };
    const bytes = try writeWav(alloc, &samples, 24000, 1, .float32);
    defer alloc.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "tone.wav", .data = bytes });
    const raw = try tmp.dir.readFileAlloc(io, "tone.wav", alloc, .limited(1 << 20));
    defer alloc.free(raw);
    var wav = try parseWav(alloc, raw);
    defer wav.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), wav.samples.len);
    try std.testing.expectEqual(@as(f32, 0.1), wav.samples[0]);
    try std.testing.expectApproxEqAbs(4.0 / 24000.0, wav.durationSeconds(), 1e-9);
}
