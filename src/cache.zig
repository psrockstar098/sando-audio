//! SmartCache: voice-, language- and context-aware caches.
//!
//! Two caches share one byte budget and one stats block:
//! - TTS audio cache: key = voice + language + context + text. The key
//!   includes ALL FOUR by construction, so a cached phrase is never
//!   reused in the wrong voice, language, or context.
//! - ASR text cache: key = language + hash of the audio samples.
//!
//! Both are LRU with a byte cap. Cached audio is an owned copy; `get`
//! returns a borrowed slice valid until the next mutating call.
//! Stats count hits, misses and evictions so the CLI can report them
//! honestly. The cache is in-process only — it never writes to disk.

const std = @import("std");

pub const CacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    entries: usize = 0,
    bytes: u64 = 0,
};

const EntryKind = enum { tts_audio, asr_text };

const Entry = struct {
    key: []const u8, // owned composite key
    kind: EntryKind,
    audio: ?[]f32 = null, // owned, tts_audio only
    text: ?[]const u8 = null, // owned, asr_text only
    bytes: u64 = 0,
    last_used: u64 = 0,
};

pub const SmartCache = struct {
    alloc: std.mem.Allocator,
    cap_bytes: u64,
    entries: std.ArrayList(Entry) = .empty,
    tick: u64 = 0,
    stats: CacheStats = .{},

    pub fn init(alloc: std.mem.Allocator, cap_bytes: u64) SmartCache {
        return .{ .alloc = alloc, .cap_bytes = cap_bytes };
    }

    pub fn deinit(self: *SmartCache) void {
        for (self.entries.items) |*e| {
            self.alloc.free(e.key);
            if (e.audio) |a| self.alloc.free(a);
            if (e.text) |t| self.alloc.free(t);
        }
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn totalBytes(self: *const SmartCache) u64 {
        return self.stats.bytes;
    }

    fn find(self: *SmartCache, key: []const u8, kind: EntryKind) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.kind == kind and std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }

    fn evictLru(self: *SmartCache) void {
        var oldest: ?usize = null;
        for (self.entries.items, 0..) |e, i| {
            if (oldest == null or e.last_used < self.entries.items[oldest.?].last_used) {
                oldest = i;
            }
        }
        if (oldest) |i| {
            const e = self.entries.items[i];
            self.stats.bytes -= e.bytes;
            self.stats.evictions += 1;
            self.alloc.free(e.key);
            if (e.audio) |a| self.alloc.free(a);
            if (e.text) |t| self.alloc.free(t);
            _ = self.entries.orderedRemove(i);
        }
    }

    fn store(self: *SmartCache, key: []const u8, kind: EntryKind, audio: ?[]const f32, text: ?[]const u8) !void {
        // Replace in place when the key already exists.
        if (self.find(key, kind)) |e| {
            if (e.audio) |a| self.alloc.free(a);
            if (e.text) |t| self.alloc.free(t);
            self.stats.bytes -= e.bytes;
            e.audio = if (audio) |a| try self.alloc.dupe(f32, a) else null;
            e.text = if (text) |t| try self.alloc.dupe(u8, t) else null;
            e.bytes = entryBytes(e.audio, e.text);
            e.last_used = self.tick;
            self.stats.bytes += e.bytes;
            return;
        }
        const audio_copy = if (audio) |a| try self.alloc.dupe(f32, a) else null;
        errdefer if (audio_copy) |a| self.alloc.free(a);
        const text_copy = if (text) |t| try self.alloc.dupe(u8, t) else null;
        errdefer if (text_copy) |t| self.alloc.free(t);
        const bytes = entryBytes(audio_copy, text_copy);
        if (bytes > self.cap_bytes) return; // never fits: do not store
        while (self.stats.bytes + bytes > self.cap_bytes and self.entries.items.len > 0) {
            self.evictLru();
        }
        try self.entries.append(self.alloc, .{
            .key = try self.alloc.dupe(u8, key),
            .kind = kind,
            .audio = audio_copy,
            .text = text_copy,
            .bytes = bytes,
            .last_used = self.tick,
        });
        self.stats.bytes += bytes;
        self.stats.entries = self.entries.items.len;
    }

    /// Look up cached TTS audio. Returns a borrowed slice, or null.
    pub fn getTts(self: *SmartCache, voice: []const u8, language: []const u8, context: []const u8, text: []const u8) !?[]const f32 {
        const key = try ttsKey(self.alloc, voice, language, context, text);
        defer self.alloc.free(key);
        self.tick += 1;
        if (self.find(key, .tts_audio)) |e| {
            e.last_used = self.tick;
            self.stats.hits += 1;
            return e.audio;
        }
        self.stats.misses += 1;
        return null;
    }

    /// Store TTS audio under the voice/language/context/text key.
    pub fn putTts(self: *SmartCache, voice: []const u8, language: []const u8, context: []const u8, text: []const u8, audio: []const f32) !void {
        const key = try ttsKey(self.alloc, voice, language, context, text);
        defer self.alloc.free(key);
        self.tick += 1;
        try self.store(key, .tts_audio, audio, null);
    }

    /// Look up cached ASR text for audio. Returns a borrowed slice, or null.
    pub fn getAsr(self: *SmartCache, language: []const u8, samples: []const f32) !?[]const u8 {
        const key = try asrKey(self.alloc, language, samples);
        defer self.alloc.free(key);
        self.tick += 1;
        if (self.find(key, .asr_text)) |e| {
            e.last_used = self.tick;
            self.stats.hits += 1;
            return e.text;
        }
        self.stats.misses += 1;
        return null;
    }

    /// Store ASR text for audio under the language/audio-hash key.
    pub fn putAsr(self: *SmartCache, language: []const u8, samples: []const f32, text: []const u8) !void {
        const key = try asrKey(self.alloc, language, samples);
        defer self.alloc.free(key);
        self.tick += 1;
        try self.store(key, .asr_text, null, text);
    }
};

fn entryBytes(audio: ?[]const f32, text: ?[]const u8) u64 {
    var n: u64 = 0;
    if (audio) |a| n += @as(u64, a.len) * @sizeOf(f32);
    if (text) |t| n += t.len;
    return n;
}

/// Composite TTS key: voice NUL language NUL context NUL text.
/// NUL separators make the four fields unambiguous.
pub fn ttsKey(alloc: std.mem.Allocator, voice: []const u8, language: []const u8, context: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{s}\x00{s}\x00{s}", .{ voice, language, context, text });
}

/// ASR key: language NUL Wyhash of the raw sample bytes.
pub fn asrKey(alloc: std.mem.Allocator, language: []const u8, samples: []const f32) ![]const u8 {
    const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(samples));
    return std.fmt.allocPrint(alloc, "{s}\x00{x:0>16}", .{ language, hash });
}

test "tts cache: hit on same key, miss on different voice/language/context" {
    const alloc = std.testing.allocator;
    var cache = SmartCache.init(alloc, 1 << 20);
    defer cache.deinit();
    const audio_samples = [_]f32{ 0.1, 0.2, 0.3 };
    try cache.putTts("voice-a", "en", "chat", "hello", &audio_samples);
    const hit = (try cache.getTts("voice-a", "en", "chat", "hello")).?;
    try std.testing.expectEqual(@as(usize, 3), hit.len);
    try std.testing.expect((try cache.getTts("voice-b", "en", "chat", "hello")) == null);
    try std.testing.expect((try cache.getTts("voice-a", "kq", "chat", "hello")) == null);
    try std.testing.expect((try cache.getTts("voice-a", "en", "alerts", "hello")) == null);
    try std.testing.expect((try cache.getTts("voice-a", "en", "chat", "goodbye")) == null);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 4), cache.stats.misses);
}

test "asr cache keys on audio content, not identity" {
    const alloc = std.testing.allocator;
    var cache = SmartCache.init(alloc, 1 << 20);
    defer cache.deinit();
    const a = [_]f32{ 0.5, -0.5, 0.25 };
    const b = [_]f32{ 0.5, -0.5, 0.25 }; // same content, different slice
    const c = [_]f32{ 0.5, -0.5, 0.26 }; // different content
    try cache.putAsr("en", &a, "hello world");
    try std.testing.expectEqualStrings("hello world", (try cache.getAsr("en", &b)).?);
    try std.testing.expect((try cache.getAsr("en", &c)) == null);
    try std.testing.expect((try cache.getAsr("kq", &a)) == null);
}

test "lru eviction drops the least recently used entry" {
    const alloc = std.testing.allocator;
    // Cap fits exactly two 12-byte entries (3 floats each).
    var cache = SmartCache.init(alloc, 24);
    defer cache.deinit();
    const one = [_]f32{ 1, 1, 1 };
    const two = [_]f32{ 2, 2, 2 };
    const three = [_]f32{ 3, 3, 3 };
    try cache.putTts("v", "en", "c", "one", &one);
    try cache.putTts("v", "en", "c", "two", &two);
    _ = try cache.getTts("v", "en", "c", "one"); // "one" is now most recent
    try cache.putTts("v", "en", "c", "three", &three);
    try std.testing.expect((try cache.getTts("v", "en", "c", "one")) != null);
    try std.testing.expect((try cache.getTts("v", "en", "c", "two")) == null); // evicted
    try std.testing.expect((try cache.getTts("v", "en", "c", "three")) != null);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.evictions);
}
