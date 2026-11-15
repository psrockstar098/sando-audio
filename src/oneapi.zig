//! OneAPI — the single unified API surface for SANDO Audio
//! (Phase 5).
//!
//! One contract, one set of error codes, one auth model, shared by
//! the REST server (`serve`), the SDKs, and the C API. This module
//! owns:
//!   - the error-code table (machine-readable `code` + HTTP status),
//!   - JSON escaping / small request parsing (std.json, no new deps),
//!   - API-key auth (environment only, never a file, never logged),
//!   - the server metrics counters (uptime, per-endpoint counts,
//!     ASR latency percentiles),
//!   - the free-RAM guard shared by the CLI and the server: a model
//!     that does not fit in free RAM is refused honestly, never
//!     loaded into an OOM.
//!
//! Nothing here touches the network or the engine: `server.zig`
//! owns the socket, the routes, and the sessions.

const std = @import("std");

/// Machine-readable error codes. Every API error response is
/// `{"error":{"code":"<code>","message":"<human text>"}}`.
pub const ApiErrorCode = enum {
    bad_request,
    unauthorized,
    not_found,
    method_not_allowed,
    too_large,
    model_not_found,
    model_loaded,
    registry_full,
    asr_unavailable,
    tts_unavailable,
    engine_unavailable,
    session_not_found,
    session_full,
    internal,

    pub fn code(self: ApiErrorCode) []const u8 {
        return switch (self) {
            .bad_request => "bad_request",
            .unauthorized => "unauthorized",
            .not_found => "not_found",
            .method_not_allowed => "method_not_allowed",
            .too_large => "too_large",
            .model_not_found => "model_not_found",
            .model_loaded => "model_loaded",
            .registry_full => "registry_full",
            .asr_unavailable => "asr_unavailable",
            .tts_unavailable => "tts_unavailable",
            .engine_unavailable => "engine_unavailable",
            .session_not_found => "session_not_found",
            .session_full => "session_full",
            .internal => "internal",
        };
    }

    pub fn httpStatus(self: ApiErrorCode) std.http.Status {
        return switch (self) {
            .bad_request => .bad_request,
            .unauthorized => .unauthorized,
            .not_found => .not_found,
            .method_not_allowed => .method_not_allowed,
            .too_large => .payload_too_large,
            .model_not_found => .not_found,
            .model_loaded => .conflict,
            .registry_full => .conflict,
            .asr_unavailable => .service_unavailable,
            .tts_unavailable => .service_unavailable,
            .engine_unavailable => .service_unavailable,
            .session_not_found => .not_found,
            .session_full => .service_unavailable,
            .internal => .internal_server_error,
        };
    }
};

/// Escape `text` for inclusion inside a JSON string. Returns an
/// owned slice (the caller frees it). Control characters become
/// `\u00XX`; `"` and `\` are backslash-escaped. Anything else —
/// including multi-byte UTF-8 — passes through unchanged.
pub fn jsonEscape(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x08 => try out.appendSlice(alloc, "\\b"),
            0x0c => try out.appendSlice(alloc, "\\f"),
            else => {
                if (c < 0x20) {
                    try out.print(alloc, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Build an error body: `{"error":{"code":"...","message":"..."}}`.
/// Owned; the caller frees it.
pub fn errorJson(alloc: std.mem.Allocator, err_code: ApiErrorCode, message: []const u8) ![]u8 {
    const escaped = try jsonEscape(alloc, message);
    defer alloc.free(escaped);
    return std.fmt.allocPrint(alloc, "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ err_code.code(), escaped });
}

/// The API key, from the environment only (`SANDO_API_KEY`). Never
/// read from a file, never given a default, never logged. Returns
/// null when unset (open dev mode — the server must warn loudly).
/// The returned slice is borrowed from the process environment.
pub fn readApiKey() ?[]const u8 {
    const raw = std.c.getenv("SANDO_API_KEY") orelse return null;
    const key = std.mem.span(raw);
    if (key.len == 0) return null;
    return key;
}

/// Compare a presented `Authorization: Bearer <key>` header value
/// against the configured key. Timing-safe enough for a dev server:
/// a fixed-length comparison with no early exit on the value.
/// Returns false when no key is configured (open dev mode accepts
/// everything) — the caller decides whether that mode is allowed.
pub fn checkAuth(configured_key: ?[]const u8, auth_header: ?[]const u8) bool {
    const key = configured_key orelse return true;
    const header = auth_header orelse return false;
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, header, prefix)) return false;
    const presented = header[prefix.len..];
    if (presented.len != key.len) return false;
    var diff: u8 = 0;
    for (presented, key) |a, b| diff |= a ^ b;
    return diff == 0;
}

/// Free RAM in bytes, from /proc/meminfo (MemAvailable). Null when
/// the file cannot be read (non-Linux) — callers must then load
/// without a guard and say so.
pub fn memAvailableBytes(alloc: std.mem.Allocator, io: std.Io) ?u64 {
    var file = std.Io.Dir.openFileAbsolute(io, "/proc/meminfo", .{}) catch return null;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const text = reader.interface.readAllocShort(alloc, 1 << 20) catch return null;
    defer alloc.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            const rest = std.mem.trim(u8, line["MemAvailable:".len..], " \t");
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const num = it.next() orelse return null;
            const kb = std.fmt.parseInt(u64, num, 10) catch return null;
            return kb * 1024;
        }
    }
    return null;
}

/// Does a model file of `size_bytes` fit in free RAM right now?
/// Returns `.fits`, `.too_big` (with the measured free bytes), or
/// `.unknown` (meminfo unreadable — the caller loads without a
/// guard and says so). Never loads a model that does not fit.
pub const FitCheck = union(enum) {
    fits,
    too_big: u64, // free bytes measured
    unknown,

    pub fn check(alloc: std.mem.Allocator, io: std.Io, size_bytes: u64) FitCheck {
        const free = memAvailableBytes(alloc, io) orelse return .unknown;
        if (size_bytes > free) return .{ .too_big = free };
        return .fits;
    }
};

/// Server metrics: uptime, total requests, per-endpoint counts, and
/// ASR latency samples (last 64, p50/p95 computed on demand). The
/// server is single-threaded (sequential accept loop), so plain
/// fields are safe — no atomics needed.
pub const Metrics = struct {
    started_ms: i64,
    total_requests: u64 = 0,
    /// Counts keyed by route pattern, e.g. "GET /v1/health".
    /// Owned keys live in the metrics' arena.
    counts: std.StringHashMap(u64),
    /// Last 64 ASR latencies in milliseconds (ring).
    asr_latencies_ms: [64]f64 = std.mem.zeroes([64]f64),
    asr_latency_count: usize = 0,
    asr_latency_next: usize = 0,
    /// Last error code seen (for the metrics page), if any.
    last_error: ?[]const u8 = null,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, now_ms: i64) Metrics {
        return .{
            .started_ms = now_ms,
            .counts = std.StringHashMap(u64).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Metrics) void {
        self.counts.deinit();
        self.* = undefined;
    }

    pub fn record(self: *Metrics, route: []const u8) void {
        self.total_requests += 1;
        const entry = self.counts.getOrPut(route) catch return;
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    pub fn recordAsrLatency(self: *Metrics, ms: f64) void {
        self.asr_latencies_ms[self.asr_latency_next] = ms;
        self.asr_latency_next = (self.asr_latency_next + 1) % self.asr_latencies_ms.len;
        if (self.asr_latency_count < self.asr_latencies_ms.len) self.asr_latency_count += 1;
    }

    fn sortedLatencies(self: *const Metrics, buf: []f64) []f64 {
        const n = self.asr_latency_count;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // Ring order: oldest first.
            const idx = (self.asr_latency_next + self.asr_latencies_ms.len - n + i) % self.asr_latencies_ms.len;
            buf[i] = self.asr_latencies_ms[idx];
        }
        std.mem.sort(f64, buf[0..n], {}, std.sort.asc(f64));
        return buf[0..n];
    }

    /// p50/p95 of the ASR latencies seen so far. Null when no ASR
    /// inference has run yet.
    pub fn asrPercentiles(self: *const Metrics, buf: []f64) ?struct { p50: f64, p95: f64 } {
        if (self.asr_latency_count == 0) return null;
        const sorted = self.sortedLatencies(buf);
        const p50 = sorted[(sorted.len - 1) / 2];
        const p95 = sorted[(sorted.len * 95 / 100) -| 1];
        return .{ .p50 = p50, .p95 = p95 };
    }

    pub fn uptimeMs(self: *const Metrics, now_ms: i64) i64 {
        return now_ms - self.started_ms;
    }
};

/// Parse a small JSON request body into `T`. `T` must be a struct
/// of optional string fields (the request shapes below). Unknown
/// fields are ignored. Returns null when the body is not valid JSON
/// for `T` — the caller turns that into `bad_request`.
pub fn parseJsonBody(comptime T: type, alloc: std.mem.Allocator, body: []const u8) ?std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, body, .{ .ignore_unknown_fields = true }) catch null;
}

/// Request shapes (all fields optional; missing means "default").
pub const IdentifyRequest = struct {
    text: ?[]const u8 = null,
};

pub const VocabRequest = struct {
    word: ?[]const u8 = null,
    language: ?[]const u8 = null,
};

pub const RouteRequest = struct {
    text: ?[]const u8 = null,
};

pub const ConversationCreateRequest = struct {
    language: ?[]const u8 = null,
    voice: ?[]const u8 = null,
};

pub const AskRequest = struct {
    text: ?[]const u8 = null,
};

pub const ModelInstallRequest = struct {
    path: ?[]const u8 = null,
    name: ?[]const u8 = null,
    kind: ?[]const u8 = null,
};

test "jsonEscape escapes quotes, backslash, and control chars" {
    const alloc = std.testing.allocator;
    const out = try jsonEscape(alloc, "say \"hi\"\nback\\slash\x01");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("say \\\"hi\\\"\\nback\\\\slash\\u0001", out);
}

test "errorJson shape" {
    const alloc = std.testing.allocator;
    const body = try errorJson(alloc, .unauthorized, "missing key");
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"unauthorized\",\"message\":\"missing key\"}}", body);
}

test "checkAuth: no configured key accepts everything (open dev mode)" {
    try std.testing.expect(checkAuth(null, null));
    try std.testing.expect(checkAuth(null, "Bearer anything"));
}

test "checkAuth: bearer compare" {
    try std.testing.expect(checkAuth("s3cret", "Bearer s3cret"));
    try std.testing.expect(!checkAuth("s3cret", "Bearer s3creT"));
    try std.testing.expect(!checkAuth("s3cret", "Bearer s3cret-extra"));
    try std.testing.expect(!checkAuth("s3cret", "Basic s3cret"));
    try std.testing.expect(!checkAuth("s3cret", null));
    try std.testing.expect(!checkAuth("s3cret", "Bearer "));
}

test "metrics percentiles over a known set" {
    const alloc = std.testing.allocator;
    var m = Metrics.init(alloc, 0);
    defer m.deinit();
    // 10 samples: 10..100 ms.
    var i: usize = 0;
    while (i < 10) : (i += 1) m.recordAsrLatency(@floatFromInt((i + 1) * 10));
    var buf: [64]f64 = undefined;
    const p = m.asrPercentiles(&buf).?;
    try std.testing.expectEqual(@as(f64, 50), p.p50);
    try std.testing.expectEqual(@as(f64, 90), p.p95);
    try std.testing.expectEqual(@as(u64, 0), m.total_requests);
    m.record("GET /v1/health");
    m.record("GET /v1/health");
    m.record("POST /v1/infer");
    try std.testing.expectEqual(@as(u64, 3), m.total_requests);
    try std.testing.expectEqual(@as(u64, 2), m.counts.get("GET /v1/health").?);
}

test "metrics percentiles empty" {
    const alloc = std.testing.allocator;
    var m = Metrics.init(alloc, 0);
    defer m.deinit();
    var buf: [64]f64 = undefined;
    try std.testing.expect(m.asrPercentiles(&buf) == null);
}

test "parseJsonBody ignores unknown fields, rejects garbage" {
    const alloc = std.testing.allocator;
    var parsed = parseJsonBody(IdentifyRequest, alloc, "{\"text\":\"hello\",\"extra\":1}").?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello", parsed.value.text.?);
    try std.testing.expect(parseJsonBody(IdentifyRequest, alloc, "not json") == null);
    var empty = parseJsonBody(IdentifyRequest, alloc, "{}").?;
    defer empty.deinit();
    try std.testing.expect(empty.value.text == null);
}

test "memAvailableBytes reads a number on this machine" {
    const alloc = std.testing.allocator;
    const free = memAvailableBytes(alloc, std.testing.io);
    // /proc/meminfo exists on Linux; on other platforms this is null.
    if (free) |f| try std.testing.expect(f > 0);
}

test "error codes map to the right HTTP status" {
    try std.testing.expectEqual(std.http.Status.unauthorized, ApiErrorCode.unauthorized.httpStatus());
    try std.testing.expectEqual(std.http.Status.service_unavailable, ApiErrorCode.tts_unavailable.httpStatus());
    try std.testing.expectEqual(std.http.Status.conflict, ApiErrorCode.model_loaded.httpStatus());
    try std.testing.expectEqual(std.http.Status.not_found, ApiErrorCode.session_not_found.httpStatus());
}
