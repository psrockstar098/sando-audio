//! Pulse client: SANDO Audio talks to Sando Pulse for knowledge.
//!
//! The engine does not know things on its own — it hears, it speaks,
//! and a brain talks through it. When a turn needs knowledge (a
//! question about the world, the news, what happened), the
//! conversation asks Pulse FIRST and the returned context rides in
//! the prompt the brain sees. Pulse is the knowledge; the brain is
//! the talker.
//!
//! This module is deliberately a clean, reusable boundary: it knows
//! nothing about ASR, TTS, or the conversation engine beyond the
//! `Knowledge` it returns. Dominic's Sando backend gets this same
//! piece afterwards — the HTTP is plain std.http only (the same rule
//! as Pulse itself: no httpz, no external HTTP framework), and there
//! are no keys anywhere: Pulse runs open in dev mode, so the client
//! sends no Authorization header. If Pulse ever needs a key, it
//! comes from the environment, never from a file or from this code.
//!
//! Honesty rules, enforced here, not just documented:
//! - An unreachable Pulse is an error the caller turns into
//!   "answered without knowledge" — never a faked answer.
//! - A response with no usable knowledge (no results and no
//!   sufficient answer) is reported as nothing, not dressed up.
//! - Only the fields Pulse actually returns are read. Unknown
//!   fields are ignored so a Pulse upgrade does not break parsing.
//!
//! Endpoints (read from ~/workspace/pulse/src/api/ — these are the
//! real shapes, not guesses):
//! - POST /v1/query   body {"query": "..."} (max 1000 chars) ->
//!   {answer, sufficient, confidence, results: [{title, summary,
//!   url, source: {name, url}, published_at, score, ...}],
//!   meta: {results_count, sources_checked}}
//! - GET  /v1/briefing -> {briefing: {top_stories, breaking,
//!   latest_liberia, ...}, cached, stale}
//! - GET  /v1/trends?window=24h|7d|30d&limit=N ->
//!   {trends: [{topic, category, recent_count, prior_count,
//!   velocity, score}], geo, ...}

const std = @import("std");

/// Default Pulse base URL (the local server). No trailing slash.
pub const default_url = "http://127.0.0.1:9000";
/// Pulse is on out of the box.
pub const default_enabled = true;

/// How many sources the rendered knowledge block carries at most,
/// and how long one summary may be. The prompt stays bounded.
pub const max_knowledge_sources = 3;
pub const max_summary_chars = 200;
/// Responses bigger than this are rejected, not buffered forever.
pub const max_body_bytes = 1 << 20;
/// Pulse rejects query bodies over 1000 chars.
pub const max_query_chars = 1000;

pub const PulseError = error{
    InvalidQuestion,
    PulseHttpError,
    PulseBadResponse,
    PulseDisabled,
    BodyTooLarge,
    OutOfMemory,
};

/// One Pulse result: a real document Pulse found.
pub const Source = struct {
    title: []const u8,
    summary: []const u8,
    url: []const u8,
    source_name: []const u8,

    pub fn deinit(self: *Source, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.summary);
        alloc.free(self.url);
        alloc.free(self.source_name);
        self.* = undefined;
    }
};

/// What Pulse knew about a question. All strings are owned;
/// free with `deinit`.
pub const Knowledge = struct {
    answer: []const u8 = "",
    sufficient: bool = false,
    confidence: f64 = 0,
    sources: []Source = &.{},
    sources_checked: usize = 0,

    pub fn deinit(self: *Knowledge, alloc: std.mem.Allocator) void {
        alloc.free(self.answer);
        for (self.sources) |*s| s.deinit(alloc);
        alloc.free(self.sources);
        self.* = undefined;
    }

    /// Usable means the brain can honestly say something from it:
    /// at least one source document, or a sufficient answer.
    /// A non-empty answer marked insufficient is a refusal, not
    /// knowledge — it does not count.
    pub fn usable(self: *const Knowledge) bool {
        if (self.sources.len > 0) return true;
        return self.sufficient and self.answer.len > 0;
    }
};

/// One top story in a briefing.
pub const BriefingStory = struct {
    title: []const u8,
    topic: []const u8,
    doc_count: usize,

    pub fn deinit(self: *BriefingStory, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.topic);
        self.* = undefined;
    }
};

/// One latest document in a briefing.
pub const BriefingDoc = struct {
    title: []const u8,
    source_id: []const u8,

    pub fn deinit(self: *BriefingDoc, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.source_id);
        self.* = undefined;
    }
};

/// A daily briefing: the top stories, breaking items, and latest
/// Liberian documents. All strings are owned; free with `deinit`.
pub const Briefing = struct {
    top_stories: []BriefingStory = &.{},
    breaking: []BriefingStory = &.{},
    latest: []BriefingDoc = &.{},
    cached: bool = false,
    stale: bool = false,

    pub fn deinit(self: *Briefing, alloc: std.mem.Allocator) void {
        for (self.top_stories) |*s| s.deinit(alloc);
        alloc.free(self.top_stories);
        for (self.breaking) |*s| s.deinit(alloc);
        alloc.free(self.breaking);
        for (self.latest) |*d| d.deinit(alloc);
        alloc.free(self.latest);
        self.* = undefined;
    }
};

/// One trending topic.
pub const Trend = struct {
    topic: []const u8,
    category: []const u8,
    recent_count: usize,
    score: f64,

    pub fn deinit(self: *Trend, alloc: std.mem.Allocator) void {
        alloc.free(self.topic);
        alloc.free(self.category);
        self.* = undefined;
    }
};

/// One county trend.
pub const GeoTrend = struct {
    county: []const u8,
    doc_count: usize,
    top_topic: []const u8,

    pub fn deinit(self: *GeoTrend, alloc: std.mem.Allocator) void {
        alloc.free(self.county);
        alloc.free(self.top_topic);
        self.* = undefined;
    }
};

/// Trending topics + counties. All strings are owned.
pub const Trends = struct {
    topics: []Trend = &.{},
    geo: []GeoTrend = &.{},

    pub fn deinit(self: *Trends, alloc: std.mem.Allocator) void {
        for (self.topics) |*t| t.deinit(alloc);
        alloc.free(self.topics);
        for (self.geo) |*g| g.deinit(alloc);
        alloc.free(self.geo);
        self.* = undefined;
    }
};

/// Trends window: the only values Pulse accepts.
pub const TrendWindow = enum {
    day_24h,
    week_7d,
    month_30d,

    pub fn queryValue(self: TrendWindow) []const u8 {
        return switch (self) {
            .day_24h => "24h",
            .week_7d => "7d",
            .month_30d => "30d",
        };
    }
};

/// The base URL with trailing slashes stripped, so
/// "http://127.0.0.1:9000/" and "...:9000" build the same URLs.
pub fn baseUrl(url: []const u8) []const u8 {
    return std.mem.trimEnd(u8, url, "/");
}

/// POST {base}/v1/query — the knowledge lookup.
pub fn queryUrl(alloc: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/query", .{baseUrl(base)});
}

/// GET {base}/v1/briefing — the daily briefing.
pub fn briefingUrl(alloc: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/briefing", .{baseUrl(base)});
}

/// GET {base}/v1/trends?window=..&limit=.. — trending topics.
pub fn trendsUrl(alloc: std.mem.Allocator, base: []const u8, window: TrendWindow, limit: usize) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1/trends?window={s}&limit={d}", .{ baseUrl(base), window.queryValue(), limit });
}

/// Build the POST /v1/query body for `question`. The JSON
/// stringifier escapes the question, so quotes and newlines in it
/// cannot break the body.
pub fn buildQueryBody(alloc: std.mem.Allocator, question: []const u8) ![]const u8 {
    const body = struct { query: []const u8 }{ .query = question };
    return std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(body, .{})});
}

/// Does this turn ask something Pulse could know? Heuristic, and
/// labelled as one: a "?" anywhere, or a question word / news word
/// among the turn's words. "Hello" and "I de go" do not need
/// knowledge; "What happened in Monrovia?" does.
pub fn needsKnowledge(alloc: std.mem.Allocator, text: []const u8) !bool {
    if (std.mem.indexOfScalar(u8, text, '?') != null) return true;
    const lower = try std.ascii.allocLowerString(alloc, text);
    defer alloc.free(lower);
    // "Tell me about X" is a knowledge ask even without a "?".
    // Bare "tell" is not: "tell me a joke" needs no Pulse.
    if (std.mem.indexOf(u8, lower, "tell me about") != null or
        std.mem.indexOf(u8, lower, "tell us about") != null) return true;
    const question_words = [_][]const u8{
        "what", "when",   "where",    "who",       "whom",   "whose", "why", "how", "which",
        "news", "latest", "happened", "happening", "update",
    };
    var it = std.mem.tokenizeAny(u8, lower, " \t\n\r.,;:!?\"'()[]");
    while (it.next()) |word| {
        for (question_words) |q| {
            if (std.mem.eql(u8, word, q)) return true;
        }
    }
    return false;
}

/// Render `knowledge` as the context block the brain sees. Bounded:
/// at most `max_knowledge_sources` sources, each summary cut to
/// `max_summary_chars`. The Pulse answer, when present, comes first
/// so the brain reads what Pulse concluded before the evidence.
pub fn formatKnowledge(alloc: std.mem.Allocator, k: *const Knowledge) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const shown = @min(k.sources.len, max_knowledge_sources);
    const plural: []const u8 = if (k.sources.len == 1) "" else "s";
    try out.print(alloc, "Knowledge from Sando Pulse ({d} source{s}, confidence {d:.2}):\n", .{ k.sources.len, plural, k.confidence });
    if (k.answer.len > 0) {
        try out.print(alloc, "Pulse says: {s}\n", .{k.answer});
    }
    for (k.sources[0..shown]) |s| {
        const summary = truncateSummary(s.summary);
        try out.print(alloc, "- {s} ({s}): {s}\n", .{ s.title, s.source_name, summary });
    }
    if (k.sources.len > shown) {
        const more = k.sources.len - shown;
        const more_plural: []const u8 = if (more == 1) "" else "s";
        try out.print(alloc, "(+{d} more source{s} not shown)\n", .{ more, more_plural });
    }
    return out.toOwnedSlice(alloc);
}

fn truncateSummary(summary: []const u8) []const u8 {
    if (summary.len <= max_summary_chars) return summary;
    const cut = summary[0..max_summary_chars];
    const last_space = std.mem.lastIndexOfScalar(u8, cut, ' ') orelse max_summary_chars;
    return summary[0..last_space];
}

// ---------------------------------------------------------------------------
// Transport: a Sender vtable, like brain.zig. The real one is
// StdHttpSender (std.http over a real socket); tests use TestSender
// (canned bytes) or a real loopback server.
// ---------------------------------------------------------------------------

/// Raw response bytes, delivered incrementally. Used by `Sender`
/// so the body is collected with a size cap, not buffered blindly.
pub const BytesFn = *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void;

/// A transport for `PulseClient`: one request, response body
/// delivered through `on_bytes`. `body` is null for GET.
pub const Sender = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            io: std.Io,
            method: std.http.Method,
            url: []const u8,
            body: ?[]const u8,
            bytes_ctx: *anyopaque,
            on_bytes: BytesFn,
        ) anyerror!void,
    };

    pub fn send(
        self: Sender,
        alloc: std.mem.Allocator,
        io: std.Io,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
        bytes_ctx: *anyopaque,
        on_bytes: BytesFn,
    ) anyerror!void {
        return self.vtable.send(self.ptr, alloc, io, method, url, body, bytes_ctx, on_bytes);
    }
};

/// The real HTTP sender: `std.http.Client`, one request, response
/// body streamed through `on_bytes` as it arrives. No Authorization
/// header is ever sent — Pulse runs open in dev mode, so this talks
/// only to an unauthenticated Pulse. A non-200 status is
/// `error.PulseHttpError`, reported before any body is read.
pub const StdHttpSender = struct {
    pub fn asSender(self: *StdHttpSender) Sender {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Sender.VTable{ .send = sendImpl };

    fn sendImpl(
        _: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
        bytes_ctx: *anyopaque,
        on_bytes: BytesFn,
    ) anyerror!void {
        const uri = try std.Uri.parse(url);
        var client = std.http.Client{ .allocator = alloc, .io = io };
        defer client.deinit();
        // A hung Pulse must not hang the turn forever: the TCP connect
        // gets a 10s cap, and a timeout surfaces as error.Timeout,
        // which the caller reports as "Pulse unreachable" and answers
        // without knowledge. `connectTcpOptions` is plain-TCP only, so
        // https keeps the old path (no timeout) rather than breaking
        // TLS. The client is built without a proxy, so the direct
        // connect matches what `request` would have done internally.
        // Honest limit: this caps the CONNECT only. Zig 0.17.1's
        // http client exposes no read/response timeout (the only
        // `timeout` in std/http/Client.zig is the connect one), so a
        // server that accepts and then stays silent still hangs the
        // read — verified live 2026-11-15 with a black-hole listener.
        // The realistic failure (Pulse down/unreachable) fails fast;
        // the silent-server case needs a read timeout the stdlib
        // does not offer.
        const plain = std.http.Client.Protocol.fromUri(uri) == .plain;
        var req = if (plain) blk: {
            var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
            const host = try std.Io.net.HostName.fromUri(uri, &host_buf);
            const conn = try client.connectTcpOptions(.{
                .host = host,
                .port = uri.port orelse 80,
                .protocol = .plain,
                .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .real } },
            });
            break :blk try client.request(method, uri, .{
                .connection = conn,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "Accept", .value = "application/json" },
                },
            });
        } else try client.request(method, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
        });
        defer req.deinit();
        if (body) |b| {
            // Same send pattern as brain.zig's StdHttpSender: the
            // body writer takes a mutable scratch buffer; the
            // request body itself is written through it.
            req.transfer_encoding = .{ .content_length = b.len };
            var body_w = try req.sendBodyUnflushed(&.{});
            try body_w.writer.writeAll(b);
            try body_w.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (response.head.status != .ok) return error.PulseHttpError;
        var transfer_buf: [4096]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        var chunk_buf: [4096]u8 = undefined;
        var vecs = [_][]u8{&chunk_buf};
        while (true) {
            const n = body_reader.readVec(&vecs) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            if (n == 0) break;
            try on_bytes(bytes_ctx, chunk_buf[0..n]);
        }
    }
};

/// Accumulates response bytes with a hard cap. The cap keeps a
/// misbehaving server from growing memory without bound.
const BodyCollector = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn collect(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *BodyCollector = @ptrCast(@alignCast(ctx));
        if (self.list.items.len + bytes.len > max_body_bytes) return error.BodyTooLarge;
        try self.list.appendSlice(self.alloc, bytes);
    }
};

/// One request through `sender`, collecting the whole body (capped).
/// Returns the owned body; the caller frees it. A non-200 status
/// surfaces as `error.PulseHttpError` from the sender itself.
fn fetchBody(
    sender: Sender,
    alloc: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
) ![]const u8 {
    var collector = BodyCollector{ .alloc = alloc };
    errdefer collector.list.deinit(alloc);
    try sender.send(alloc, io, method, url, body, &collector, BodyCollector.collect);
    return collector.list.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Response parsing: only the fields the client uses, unknown fields
// ignored so a Pulse upgrade does not break this client.
// ---------------------------------------------------------------------------

const QueryResultJson = struct {
    title: []const u8 = "",
    summary: []const u8 = "",
    url: []const u8 = "",
    source: struct { name: []const u8 = "", url: []const u8 = "" } = .{},
};

const QueryResponseJson = struct {
    answer: []const u8 = "",
    sufficient: bool = false,
    confidence: f64 = 0,
    results: []QueryResultJson = &.{},
    meta: struct { results_count: usize = 0, sources_checked: usize = 0 } = .{},
};

/// Parse a POST /v1/query body into owned Knowledge. A malformed
/// body is `error.PulseBadResponse` — never a half-filled answer.
pub fn parseQueryResponse(alloc: std.mem.Allocator, body: []const u8) !Knowledge {
    const parsed = std.json.parseFromSlice(QueryResponseJson, alloc, body, .{ .ignore_unknown_fields = true }) catch return error.PulseBadResponse;
    defer parsed.deinit();
    const v = parsed.value;
    var out = Knowledge{
        .answer = try alloc.dupe(u8, v.answer),
        .sufficient = v.sufficient,
        .confidence = v.confidence,
        .sources_checked = v.meta.sources_checked,
    };
    errdefer out.deinit(alloc);
    var sources = std.ArrayList(Source).empty;
    errdefer {
        for (sources.items) |*s| s.deinit(alloc);
        sources.deinit(alloc);
    }
    for (v.results) |r| {
        try sources.append(alloc, .{
            .title = try alloc.dupe(u8, r.title),
            .summary = try alloc.dupe(u8, r.summary),
            .url = try alloc.dupe(u8, r.url),
            .source_name = try alloc.dupe(u8, r.source.name),
        });
    }
    out.sources = try sources.toOwnedSlice(alloc);
    return out;
}

const BriefingStoryJson = struct {
    title: []const u8 = "",
    topic: []const u8 = "",
    doc_count: usize = 0,
};

const BriefingDocJson = struct {
    title: []const u8 = "",
    source_id: []const u8 = "",
};

const BriefingResponseJson = struct {
    briefing: struct {
        top_stories: []BriefingStoryJson = &.{},
        breaking: []BriefingStoryJson = &.{},
        latest_liberia: []BriefingDocJson = &.{},
    } = .{},
    cached: bool = false,
    stale: bool = false,
};

/// Parse a GET /v1/briefing body into an owned Briefing.
pub fn parseBriefingResponse(alloc: std.mem.Allocator, body: []const u8) !Briefing {
    const parsed = std.json.parseFromSlice(BriefingResponseJson, alloc, body, .{ .ignore_unknown_fields = true }) catch return error.PulseBadResponse;
    defer parsed.deinit();
    const v = parsed.value;
    var out = Briefing{ .cached = v.cached, .stale = v.stale };
    errdefer out.deinit(alloc);
    var stories = std.ArrayList(BriefingStory).empty;
    errdefer {
        for (stories.items) |*s| s.deinit(alloc);
        stories.deinit(alloc);
    }
    for (v.briefing.top_stories) |s| {
        try stories.append(alloc, .{
            .title = try alloc.dupe(u8, s.title),
            .topic = try alloc.dupe(u8, s.topic),
            .doc_count = s.doc_count,
        });
    }
    out.top_stories = try stories.toOwnedSlice(alloc);
    var breaking = std.ArrayList(BriefingStory).empty;
    errdefer {
        for (breaking.items) |*s| s.deinit(alloc);
        breaking.deinit(alloc);
    }
    for (v.briefing.breaking) |s| {
        try breaking.append(alloc, .{
            .title = try alloc.dupe(u8, s.title),
            .topic = try alloc.dupe(u8, s.topic),
            .doc_count = s.doc_count,
        });
    }
    out.breaking = try breaking.toOwnedSlice(alloc);
    var latest = std.ArrayList(BriefingDoc).empty;
    errdefer {
        for (latest.items) |*d| d.deinit(alloc);
        latest.deinit(alloc);
    }
    for (v.briefing.latest_liberia) |d| {
        try latest.append(alloc, .{
            .title = try alloc.dupe(u8, d.title),
            .source_id = try alloc.dupe(u8, d.source_id),
        });
    }
    out.latest = try latest.toOwnedSlice(alloc);
    return out;
}

const TrendJson = struct {
    topic: []const u8 = "",
    category: []const u8 = "",
    recent_count: usize = 0,
    score: f64 = 0,
};

const GeoTrendJson = struct {
    county: []const u8 = "",
    doc_count: usize = 0,
    top_topic: []const u8 = "",
};

const TrendsResponseJson = struct {
    trends: []TrendJson = &.{},
    geo: []GeoTrendJson = &.{},
};

/// Parse a GET /v1/trends body into owned Trends.
pub fn parseTrendsResponse(alloc: std.mem.Allocator, body: []const u8) !Trends {
    const parsed = std.json.parseFromSlice(TrendsResponseJson, alloc, body, .{ .ignore_unknown_fields = true }) catch return error.PulseBadResponse;
    defer parsed.deinit();
    const v = parsed.value;
    var out = Trends{};
    errdefer out.deinit(alloc);
    var topics = std.ArrayList(Trend).empty;
    errdefer {
        for (topics.items) |*t| t.deinit(alloc);
        topics.deinit(alloc);
    }
    for (v.trends) |t| {
        try topics.append(alloc, .{
            .topic = try alloc.dupe(u8, t.topic),
            .category = try alloc.dupe(u8, t.category),
            .recent_count = t.recent_count,
            .score = t.score,
        });
    }
    out.topics = try topics.toOwnedSlice(alloc);
    var geo = std.ArrayList(GeoTrend).empty;
    errdefer {
        for (geo.items) |*g| g.deinit(alloc);
        geo.deinit(alloc);
    }
    for (v.geo) |g| {
        try geo.append(alloc, .{
            .county = try alloc.dupe(u8, g.county),
            .doc_count = g.doc_count,
            .top_topic = try alloc.dupe(u8, g.top_topic),
        });
    }
    out.geo = try geo.toOwnedSlice(alloc);
    return out;
}

// ---------------------------------------------------------------------------
// PulseClient — the reusable piece. `url` is borrowed (config- or
// CLI-owned); the client holds no state beyond it and the sender.
// ---------------------------------------------------------------------------

/// The Pulse client. `url` is the base URL (borrowed — the caller
/// owns it); `sender` is the transport (real std.http, or a test
/// double). Nothing here is ever written to disk, and no key is
/// ever sent.
pub const PulseClient = struct {
    url: []const u8 = default_url,
    enabled: bool = default_enabled,
    sender: Sender,

    pub fn init(url: []const u8, enabled: bool, sender: Sender) PulseClient {
        return .{ .url = url, .enabled = enabled, .sender = sender };
    }

    /// Ask Pulse about `question`. Returns null when the client is
    /// disabled — the caller treats that as "no Pulse", not an
    /// error. A network failure or a bad response is an error the
    /// caller turns into "answered without knowledge".
    pub fn query(self: *const PulseClient, alloc: std.mem.Allocator, io: std.Io, question: []const u8) anyerror!?Knowledge {
        if (!self.enabled) return null;
        const trimmed = std.mem.trim(u8, question, " \t\n\r");
        if (trimmed.len == 0) return error.InvalidQuestion;
        if (trimmed.len > max_query_chars) return error.InvalidQuestion;
        const url = try queryUrl(alloc, self.url);
        defer alloc.free(url);
        const body = try buildQueryBody(alloc, trimmed);
        defer alloc.free(body);
        const resp_body = try fetchBody(self.sender, alloc, io, .POST, url, body);
        defer alloc.free(resp_body);
        return try parseQueryResponse(alloc, resp_body);
    }

    /// Fetch the daily briefing. Returns null when disabled.
    pub fn briefing(self: *const PulseClient, alloc: std.mem.Allocator, io: std.Io) anyerror!?Briefing {
        if (!self.enabled) return null;
        const url = try briefingUrl(alloc, self.url);
        defer alloc.free(url);
        const resp_body = try fetchBody(self.sender, alloc, io, .GET, url, null);
        defer alloc.free(resp_body);
        return try parseBriefingResponse(alloc, resp_body);
    }

    /// Fetch trending topics for `window`. Returns null when disabled.
    pub fn trends(self: *const PulseClient, alloc: std.mem.Allocator, io: std.Io, window: TrendWindow) anyerror!?Trends {
        if (!self.enabled) return null;
        const url = try trendsUrl(alloc, self.url, window, 10);
        defer alloc.free(url);
        const resp_body = try fetchBody(self.sender, alloc, io, .GET, url, null);
        defer alloc.free(resp_body);
        return try parseTrendsResponse(alloc, resp_body);
    }
};

// ---------------------------------------------------------------------------
// TestSender — canned bytes for tests (no network).
// ---------------------------------------------------------------------------

/// A sender that replays canned response bytes and records the
/// request it received. Test-only.
pub const TestSender = struct {
    chunks: []const []const u8,
    fail: ?anyerror = null,
    method_seen: ?std.http.Method = null,
    url_seen: ?[]const u8 = null,
    body_seen: ?[]const u8 = null,

    pub fn asSender(self: *TestSender) Sender {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Sender.VTable{ .send = sendImpl };

    fn sendImpl(
        ptr: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
        bytes_ctx: *anyopaque,
        on_bytes: BytesFn,
    ) anyerror!void {
        _ = io;
        const self: *TestSender = @ptrCast(@alignCast(ptr));
        self.method_seen = method;
        // Own the copies: the caller frees `url`/`body` after the
        // call returns, so borrowing them would hand the test
        // freed memory. Free with deinit when the test is done.
        self.url_seen = try alloc.dupe(u8, url);
        self.body_seen = if (body) |b| try alloc.dupe(u8, b) else null;
        if (self.fail) |e| return e;
        for (self.chunks) |c| try on_bytes(bytes_ctx, c);
    }

    /// Free the owned url/body copies from the last send.
    pub fn deinit(self: *TestSender, alloc: std.mem.Allocator) void {
        if (self.url_seen) |u| alloc.free(u);
        if (self.body_seen) |b| alloc.free(b);
        self.url_seen = null;
        self.body_seen = null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pulse urls build from the base, trailing slash tolerated" {
    const alloc = std.testing.allocator;
    const q = try queryUrl(alloc, "http://127.0.0.1:9000");
    defer alloc.free(q);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/query", q);
    const q2 = try queryUrl(alloc, "http://127.0.0.1:9000/");
    defer alloc.free(q2);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/query", q2);
    const b = try briefingUrl(alloc, "http://127.0.0.1:9000///");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/briefing", b);
    const t = try trendsUrl(alloc, "http://127.0.0.1:9000", .week_7d, 10);
    defer alloc.free(t);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/trends?window=7d&limit=10", t);
    try std.testing.expectEqualStrings("24h", TrendWindow.day_24h.queryValue());
    try std.testing.expectEqualStrings("30d", TrendWindow.month_30d.queryValue());
}

test "pulse query body is json with the question escaped" {
    const alloc = std.testing.allocator;
    const body = try buildQueryBody(alloc, "What \"happened\" in Monrovia?");
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"query\":\"What \\\"happened\\\" in Monrovia?\"}", body);
}

/// A real Pulse /v1/query response shape (fixture — labelled,
/// modelled on the shape Pulse's buildQueryResponse emits).
const query_fixture =
    \\{"query":"roads in Monrovia","answer":"Several reports describe road closures in Monrovia.","sufficient":true,"confidence":0.82,"results":[{"title":"Road blocked in Sinkor","summary":"A road in Sinkor has been blocked since this morning, vehicles cannot pass.","url":"https://example.com/road","source":{"name":"FrontPage Africa","url":"https://example.com"},"published_at":"2026-11-15T08:00:00Z","score":0.91},{"title":"Traffic jam on Tubman Boulevard","summary":"Heavy traffic reported on Tubman Boulevard.","url":"https://example.com/traffic","source":{"name":"Daily Observer","url":"https://example.com"},"published_at":"2026-11-14T17:00:00Z","score":0.77}],"events":[],"timeline":[],"meta":{"request_id":"r1","results_count":2,"sources_checked":9},"extra_future_field":{"nested":true}}
;

test "pulse query parses a real response shape, ignores unknown fields" {
    const alloc = std.testing.allocator;
    var k = try parseQueryResponse(alloc, query_fixture);
    defer k.deinit(alloc);
    try std.testing.expect(k.usable());
    try std.testing.expect(k.sufficient);
    try std.testing.expectApproxEqAbs(@as(f64, 0.82), k.confidence, 0.001);
    try std.testing.expectEqual(@as(usize, 2), k.sources.len);
    try std.testing.expectEqual(@as(usize, 9), k.sources_checked);
    try std.testing.expectEqualStrings("Road blocked in Sinkor", k.sources[0].title);
    try std.testing.expectEqualStrings("FrontPage Africa", k.sources[0].source_name);
    try std.testing.expect(std.mem.indexOf(u8, k.answer, "road closures") != null);
}

test "pulse query with no results and an insufficient answer is not usable" {
    const alloc = std.testing.allocator;
    const body =
        \\{"query":"zqxj","answer":"I do not have enough information.","sufficient":false,"confidence":0.1,"results":[],"meta":{"request_id":"r2","results_count":0,"sources_checked":9}}
    ;
    var k = try parseQueryResponse(alloc, body);
    defer k.deinit(alloc);
    try std.testing.expect(!k.usable());
    try std.testing.expectEqual(@as(usize, 0), k.sources.len);
}

test "pulse query rejects malformed json" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.PulseBadResponse, parseQueryResponse(alloc, "not json at all"));
    try std.testing.expectError(error.PulseBadResponse, parseQueryResponse(alloc, "{\"answer\": 42}"));
}

test "pulse formatKnowledge caps sources and summaries" {
    const alloc = std.testing.allocator;
    const long_summary = comptime blk: {
        var s: [300]u8 = undefined;
        for (0..60) |i| @memcpy(s[i * 5 ..][0..5], "word ");
        break :blk s;
    }; // 300 chars
    var k = Knowledge{
        .answer = try alloc.dupe(u8, "Roads are blocked."),
        .sufficient = true,
        .confidence = 0.9,
        .sources_checked = 9,
    };
    var srcs: [4]Source = undefined;
    for (&srcs, 0..) |*s, i| {
        s.* = .{
            .title = try std.fmt.allocPrint(alloc, "Story {d}", .{i}),
            .summary = try alloc.dupe(u8, &long_summary),
            .url = try alloc.dupe(u8, "https://example.com"),
            .source_name = try alloc.dupe(u8, "Paper"),
        };
    }
    k.sources = &srcs;
    defer {
        alloc.free(k.answer);
        for (&srcs) |*s| s.deinit(alloc);
    }
    const text = try formatKnowledge(alloc, &k);
    defer alloc.free(text);
    // Only 3 of 4 sources shown, plus the overflow note.
    try std.testing.expect(std.mem.indexOf(u8, text, "Story 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Story 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Story 3") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(+1 more source") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Pulse says: Roads are blocked.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "confidence 0.90") != null);
    // No single summary line runs past the cap.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "- ")) {
            try std.testing.expect(line.len <= max_summary_chars + 40);
        }
    }
}

/// A real Pulse /v1/briefing response shape (fixture).
const briefing_fixture =
    \\{"briefing":{"top_stories":[{"id":"e1","title":"Road closures in Monrovia","topic":"roads","kind":"general","doc_count":5,"distinct_sources":3,"status":"active","importance":0.9}],"breaking":[],"latest_liberia":[{"id":"d1","title":"Market day in Red Light","source_id":"daily-observer","published_at":1763100000}]},"cached":false,"stale":false,"request_id":"r3"}
;

test "pulse briefing parses top stories and latest docs" {
    const alloc = std.testing.allocator;
    var b = try parseBriefingResponse(alloc, briefing_fixture);
    defer b.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), b.top_stories.len);
    try std.testing.expectEqualStrings("Road closures in Monrovia", b.top_stories[0].title);
    try std.testing.expectEqual(@as(usize, 5), b.top_stories[0].doc_count);
    try std.testing.expectEqual(@as(usize, 0), b.breaking.len);
    try std.testing.expectEqual(@as(usize, 1), b.latest.len);
    try std.testing.expectEqualStrings("daily-observer", b.latest[0].source_id);
    try std.testing.expect(!b.cached);
}

/// A real Pulse /v1/trends response shape (fixture).
const trends_fixture =
    \\{"trends":[{"topic":"roads","category":"general","recent_count":12,"prior_count":3,"velocity":3.0,"score":9.5},{"topic":"electricity","category":"general","recent_count":8,"prior_count":6,"velocity":0.33,"score":4.1}],"geo":[{"county":"Montserrado","doc_count":40,"top_topic":"roads"}],"snapshots":[],"forecast":[],"social":[],"computed_at":1763100000,"stale":false,"request_id":"r4"}
;

test "pulse trends parse topics and counties" {
    const alloc = std.testing.allocator;
    var t = try parseTrendsResponse(alloc, trends_fixture);
    defer t.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), t.topics.len);
    try std.testing.expectEqualStrings("roads", t.topics[0].topic);
    try std.testing.expectEqual(@as(usize, 12), t.topics[0].recent_count);
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), t.topics[0].score, 0.001);
    try std.testing.expectEqual(@as(usize, 1), t.geo.len);
    try std.testing.expectEqualStrings("Montserrado", t.geo[0].county);
}

test "pulse client posts the query and parses the reply (test sender)" {
    const alloc = std.testing.allocator;
    var sender = TestSender{ .chunks = &.{query_fixture} };
    defer sender.deinit(alloc);
    var client = PulseClient.init("http://127.0.0.1:9000", true, sender.asSender());
    var k = (try client.query(alloc, std.testing.io, "roads in Monrovia")).?;
    defer k.deinit(alloc);
    try std.testing.expectEqual(std.http.Method.POST, sender.method_seen.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/query", sender.url_seen.?);
    try std.testing.expect(std.mem.indexOf(u8, sender.body_seen.?, "\"query\":\"roads in Monrovia\"") != null);
    try std.testing.expect(k.usable());
    try std.testing.expectEqual(@as(usize, 2), k.sources.len);
}

test "pulse client gets briefing and trends (test sender)" {
    const alloc = std.testing.allocator;
    var sender = TestSender{ .chunks = &.{briefing_fixture} };
    defer sender.deinit(alloc);
    var client = PulseClient.init("http://127.0.0.1:9000", true, sender.asSender());
    var b = (try client.briefing(alloc, std.testing.io)).?;
    defer b.deinit(alloc);
    try std.testing.expectEqual(std.http.Method.GET, sender.method_seen.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/briefing", sender.url_seen.?);
    try std.testing.expect(sender.body_seen == null);
    try std.testing.expectEqual(@as(usize, 1), b.top_stories.len);

    var sender2 = TestSender{ .chunks = &.{trends_fixture} };
    defer sender2.deinit(alloc);
    var client2 = PulseClient.init("http://127.0.0.1:9000", true, sender2.asSender());
    var t = (try client2.trends(alloc, std.testing.io, .week_7d)).?;
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/trends?window=7d&limit=10", sender2.url_seen.?);
    try std.testing.expectEqual(@as(usize, 2), t.topics.len);
}

test "pulse client surfaces transport failure and bad json as errors" {
    const alloc = std.testing.allocator;
    var failing = TestSender{ .chunks = &.{}, .fail = error.ConnectionRefused };
    defer failing.deinit(alloc);
    var client = PulseClient.init("http://127.0.0.1:9000", true, failing.asSender());
    try std.testing.expectError(error.ConnectionRefused, client.query(alloc, std.testing.io, "roads?"));

    var bad = TestSender{ .chunks = &.{"{broken"} };
    defer bad.deinit(alloc);
    var client2 = PulseClient.init("http://127.0.0.1:9000", true, bad.asSender());
    try std.testing.expectError(error.PulseBadResponse, client2.query(alloc, std.testing.io, "roads?"));
}

test "pulse client returns null when disabled, rejects empty questions" {
    const alloc = std.testing.allocator;
    var sender = TestSender{ .chunks = &.{query_fixture} };
    defer sender.deinit(alloc);
    var client = PulseClient.init("http://127.0.0.1:9000", false, sender.asSender());
    try std.testing.expect((try client.query(alloc, std.testing.io, "roads?")) == null);
    try std.testing.expect((try client.briefing(alloc, std.testing.io)) == null);
    try std.testing.expect(sender.url_seen == null);

    var enabled = PulseClient.init("http://127.0.0.1:9000", true, sender.asSender());
    try std.testing.expectError(error.InvalidQuestion, enabled.query(alloc, std.testing.io, "   "));
}

test "needsKnowledge flags questions, not greetings" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try needsKnowledge(alloc, "What happened in Monrovia?"));
    try std.testing.expect(try needsKnowledge(alloc, "what is the latest news about roads"));
    try std.testing.expect(try needsKnowledge(alloc, "Tell me about the electricity situation"));
    try std.testing.expect(try needsKnowledge(alloc, "How are the roads today"));
    try std.testing.expect(!(try needsKnowledge(alloc, "hello")));
    try std.testing.expect(!(try needsKnowledge(alloc, "I de go.")));
    try std.testing.expect(!(try needsKnowledge(alloc, "thank you")));
    try std.testing.expect(!(try needsKnowledge(alloc, "tell me a joke")));
}

// ---------------------------------------------------------------------------
// Loopback test: the real StdHttpSender against a real local server
// serving a canned Pulse query response.
// ---------------------------------------------------------------------------

const LoopbackState = struct {
    port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn loopbackServerThread(state: *LoopbackState, io: std.Io) void {
    var port: u16 = 18151;
    var server: std.Io.net.Server = undefined;
    while (port < 18165) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        server = std.Io.net.IpAddress.listen(&addr, io, .{}) catch continue;
        break;
    } else return;
    state.port.store(port, .release);
    state.ready.store(true, .release);

    var stream = server.accept(io) catch return;
    defer stream.close(io);
    var in_buf: [8192]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var req = http_server.receiveHead() catch return;
    // `respond` discards the request body itself when the
    // connection is reused — no manual drain needed.
    req.respond(query_fixture, .{ .status = .ok, .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }} }) catch return;
}

test "pulse client queries a real local server over std.http" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var state = LoopbackState{};
    const t = try std.Thread.spawn(.{}, loopbackServerThread, .{ &state, io });
    _ = t;

    var waited: u32 = 0;
    while (!state.ready.load(.acquire)) : (waited += 1) {
        if (waited > 50_000_000) return error.TestFailed;
    }
    const port = state.port.load(.acquire);
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
    defer alloc.free(url);

    var sender = StdHttpSender{};
    var client = PulseClient.init(url, true, sender.asSender());
    var k = (try client.query(alloc, io, "roads in Monrovia")).?;
    defer k.deinit(alloc);
    try std.testing.expect(k.usable());
    try std.testing.expectEqual(@as(usize, 2), k.sources.len);
    try std.testing.expectEqualStrings("FrontPage Africa", k.sources[0].source_name);
}
