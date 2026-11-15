//! BrainLink: one interface any LLM or AI agent plugs into.
//!
//! The conversation engine never knows which brain is behind the
//! interface — local LLM, cloud LLM over HTTP, or a custom in-process
//! agent all speak the same `Brain` vtable: a prompt in, streamed
//! reply chunks out (via `on_chunk`), full reply text returned.
//!
//! Transports:
//! - `MockBrain` — scripted replies for tests and demos. No network.
//! - `HttpBrain` — OpenAI-compatible chat completions (`POST
//!   /v1/chat/completions`, `stream: true`, SSE `data:` deltas).
//!   The HTTP sender is pluggable (`Sender`): the real one is
//!   `StdHttpSender` (std.http over a real socket); tests use
//!   `TestSender` (canned bytes) or a real loopback server. There
//!   are NO API keys anywhere in this phase and none may be added:
//!   `HttpBrain` sends no Authorization header, so it only talks to
//!   a local or otherwise unauthenticated OpenAI-compatible
//!   endpoint. A real cloud provider needs keys, which is a Phase 5
//!   (or operator) concern, not this module's.
//! - `AgentBrain` — an in-process host callback. The host owns
//!   cancellation and streaming: it may call `on_chunk` as it
//!   produces text and returns the full reply.
//!
//! Cancellation: `reply` takes an optional `*const bool` flag. A
//! brain checks it between chunks and returns `error.Cancelled`
//! when set — that is how a barge-in stops a reply mid-stream.
//! The caller owns the returned reply slice (allocated with the
//! `alloc` passed to `reply`).

const std = @import("std");

/// One streamed reply chunk. The chunk is borrowed: a handler that
/// keeps it must copy it before returning.
pub const ChunkFn = *const fn (ctx: *anyopaque, chunk: []const u8) anyerror!void;

/// Raw response bytes, delivered incrementally as they arrive from
/// the transport. Used by `Sender` so the SSE parser sees the body
/// in network-sized pieces, not one buffered blob.
pub const BytesFn = *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void;

/// A brain: any LLM or agent behind one interface.
pub const Brain = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Stream the reply for `prompt`. Chunks arrive via
        /// `on_chunk` as they are produced; the full reply text is
        /// returned (owned by the caller, allocated with `alloc`).
        /// `cancel`, when non-null, is polled between chunks: when
        /// it becomes true the brain stops and returns
        /// `error.Cancelled`.
        reply: *const fn (
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            io: std.Io,
            prompt: []const u8,
            cancel: ?*const bool,
            chunk_ctx: *anyopaque,
            on_chunk: ChunkFn,
        ) anyerror![]const u8,
        name: *const fn (ptr: *anyopaque) []const u8,
        /// Free internal allocations only — never the brain struct
        /// itself (the caller owns it).
        deinit: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) void,
    };

    pub fn reply(
        self: Brain,
        alloc: std.mem.Allocator,
        io: std.Io,
        prompt: []const u8,
        cancel: ?*const bool,
        chunk_ctx: *anyopaque,
        on_chunk: ChunkFn,
    ) anyerror![]const u8 {
        return self.vtable.reply(self.ptr, alloc, io, prompt, cancel, chunk_ctx, on_chunk);
    }

    pub fn brainName(self: Brain) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn deinit(self: Brain, alloc: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, alloc);
    }
};

/// Accumulates streamed chunks into one owned reply while forwarding
/// each chunk to the outer callback. Used by brains whose transport
/// delivers chunks but whose caller also wants the full text.
pub const Collector = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    outer_ctx: ?*anyopaque = null,
    outer_fn: ?ChunkFn = null,

    pub fn init(alloc: std.mem.Allocator, outer_ctx: ?*anyopaque, outer_fn: ?ChunkFn) Collector {
        return .{ .alloc = alloc, .outer_ctx = outer_ctx, .outer_fn = outer_fn };
    }

    pub fn deinit(self: *Collector) void {
        self.list.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn collect(self: *Collector, chunk: []const u8) !void {
        try self.list.appendSlice(self.alloc, chunk);
        if (self.outer_fn) |f| try f(self.outer_ctx.?, chunk);
    }

    pub fn toOwned(self: *Collector) ![]const u8 {
        return self.list.toOwnedSlice(self.alloc);
    }
};

/// `Collector.collect` as a `ChunkFn`.
pub fn collectorChunk(ctx: *anyopaque, chunk: []const u8) anyerror!void {
    const c: *Collector = @ptrCast(@alignCast(ctx));
    try c.collect(chunk);
}

// ---------------------------------------------------------------------------
// MockBrain — scripted replies, no network.
// ---------------------------------------------------------------------------

/// Scripted replies for tests and demos. Keyword matching runs
/// against the LAST user turn in the prompt (history never hijacks
/// the match). Replies stream word by word so the streaming path is
/// exercised exactly like a real brain's.
pub const MockBrain = struct {
    rules: []const Rule = &default_rules,
    default_reply: []const u8 = default_reply_text,

    pub const Rule = struct { needle: []const u8, reply: []const u8 };

    pub const default_reply_text = "I heard you. I am Sando, your voice assistant. Ask me anything and I will answer in speech.";

    pub const default_rules = [_]Rule{
        .{ .needle = "joke", .reply = "Why did the developer go broke? Because he used up all his cache." },
        .{ .needle = "what can you do", .reply = "I can listen to your voice, understand what you say, and answer back in speech. I speak English and I am learning Koloqua." },
        .{ .needle = "hello", .reply = "Hello! I am Sando. Speak to me and I will answer." },
        .{ .needle = "thank", .reply = "You are welcome. I am here whenever you want to talk." },
        // Koloqua replies (Phase 4): each reply is a VERBATIM
        // dataset response, cited by id. The mock brain has no
        // Koloqua generative ability — outside these scripted
        // replies it answers in English. Rules are checked in
        // order, after the English rules above.
        .{ .needle = "de go", .reply = "I de go." }, // koloqua_00043
        .{ .needle = "fini", .reply = "They fini fool we pekin them." }, // koloqua_00005
        .{ .needle = "give me", .reply = "Give me, yah." }, // koloqua_00110
        .{ .needle = "that man", .reply = "That man na come o." }, // koloqua_00109
        .{ .needle = "proverb", .reply = "Your house won't sell you, the street can't buy you." }, // koloqua_00150
    };

    pub fn asBrain(self: *MockBrain) Brain {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Brain.VTable{
        .reply = replyImpl,
        .name = nameImpl,
        .deinit = deinitImpl,
    };

    fn nameImpl(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    fn replyImpl(
        ptr: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        prompt: []const u8,
        cancel: ?*const bool,
        chunk_ctx: *anyopaque,
        on_chunk: ChunkFn,
    ) anyerror![]const u8 {
        _ = io;
        const self: *MockBrain = @ptrCast(@alignCast(ptr));
        const reply = self.pickReply(alloc, prompt) catch |err| return err;
        defer alloc.free(reply);
        // Stream word by word; the joined chunks equal the reply.
        var it = std.mem.splitScalar(u8, reply, ' ');
        var first = true;
        while (it.next()) |word| {
            if (cancel) |c| {
                if (c.*) return error.Cancelled;
            }
            if (first) {
                try on_chunk(chunk_ctx, word);
                first = false;
            } else {
                // The space belongs to the chunk that follows it, so
                // concatenating every chunk reproduces the reply.
                const piece = try std.fmt.allocPrint(alloc, " {s}", .{word});
                defer alloc.free(piece);
                try on_chunk(chunk_ctx, piece);
            }
        }
        return try alloc.dupe(u8, reply);
    }

    /// Pick the reply for a prompt: first rule whose needle appears
    /// (case-insensitive) in the last user turn, else the default.
    fn pickReply(self: *const MockBrain, alloc: std.mem.Allocator, prompt: []const u8) ![]const u8 {
        const last_user = lastUserTurn(prompt);
        const lower = try std.ascii.allocLowerString(alloc, last_user);
        defer alloc.free(lower);
        for (self.rules) |rule| {
            if (std.mem.indexOf(u8, lower, rule.needle) != null) {
                return try alloc.dupe(u8, rule.reply);
            }
        }
        return try alloc.dupe(u8, self.default_reply);
    }
};

/// The text of the last "User: ..." line in a rendered prompt
/// (everything after the final "User: " marker, up to the next
/// newline). Falls back to the whole prompt when there is no marker
/// (a bare prompt is one user turn).
fn lastUserTurn(prompt: []const u8) []const u8 {
    var last: ?usize = null;
    var i: usize = 0;
    while (i + 6 <= prompt.len) : (i += 1) {
        if (std.mem.eql(u8, prompt[i .. i + 6], "User: ")) last = i + 6;
    }
    const start = last orelse return prompt;
    const rest = prompt[start..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return rest[0..end];
}

// ---------------------------------------------------------------------------
// AgentBrain — an in-process host callback.
// ---------------------------------------------------------------------------

/// Host callback: produce the reply for `prompt`. It may stream by
/// calling `on_chunk` as it produces text (the chunks it emits are
/// what the conversation speaks sentence by sentence); it returns
/// the full reply (owned by the caller, allocated with `alloc`).
pub const AgentCallback = *const fn (
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    prompt: []const u8,
    chunk_ctx: *anyopaque,
    on_chunk: ChunkFn,
) anyerror![]const u8;

pub const AgentBrain = struct {
    ctx: *anyopaque,
    callback: AgentCallback,
    label: []const u8 = "agent",

    pub fn asBrain(self: *AgentBrain) Brain {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Brain.VTable{
        .reply = replyImpl,
        .name = nameImpl,
        .deinit = deinitImpl,
    };

    fn nameImpl(ptr: *anyopaque) []const u8 {
        const self: *AgentBrain = @ptrCast(@alignCast(ptr));
        return self.label;
    }

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    fn replyImpl(
        ptr: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        prompt: []const u8,
        cancel: ?*const bool,
        chunk_ctx: *anyopaque,
        on_chunk: ChunkFn,
    ) anyerror![]const u8 {
        _ = io;
        _ = cancel; // the host callback owns cancellation
        const self: *AgentBrain = @ptrCast(@alignCast(ptr));
        return self.callback(self.ctx, alloc, prompt, chunk_ctx, on_chunk);
    }
};

// ---------------------------------------------------------------------------
// HttpBrain — OpenAI-compatible chat completions over HTTP, SSE.
// ---------------------------------------------------------------------------

/// A transport for `HttpBrain`: POST `body` to `url` and deliver the
/// response body incrementally through `on_bytes`. The real one is
/// `StdHttpSender`; tests use `TestSender` or a loopback server.
pub const Sender = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (
            ptr: *anyopaque,
            alloc: std.mem.Allocator,
            io: std.Io,
            url: []const u8,
            body: []const u8,
            bytes_ctx: *anyopaque,
            on_bytes: BytesFn,
        ) anyerror!void,
    };

    pub fn send(
        self: Sender,
        alloc: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        body: []const u8,
        bytes_ctx: *anyopaque,
        on_bytes: BytesFn,
    ) anyerror!void {
        return self.vtable.send(self.ptr, alloc, io, url, body, bytes_ctx, on_bytes);
    }
};

/// The real HTTP sender: `std.http.Client`, one POST, response body
/// streamed through `on_bytes` as it arrives. No Authorization
/// header is ever sent — this talks only to a local or otherwise
/// unauthenticated OpenAI-compatible endpoint.
pub const StdHttpSender = struct {
    pub fn asSender(self: *StdHttpSender) Sender {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Sender.VTable{ .send = sendImpl };

    fn sendImpl(
        _: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        body: []const u8,
        bytes_ctx: *anyopaque,
        on_bytes: BytesFn,
    ) anyerror!void {
        const uri = try std.Uri.parse(url);
        var client = std.http.Client{ .allocator = alloc, .io = io };
        defer client.deinit();
        var req = try client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "text/event-stream" },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        var body_w = try req.sendBodyUnflushed(&.{});
        try body_w.writer.writeAll(body);
        try body_w.end();
        try req.connection.?.flush();
        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (response.head.status != .ok) return error.BrainHttpError;
        var transfer_buf: [64]u8 = undefined;
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

/// One chat-completions choice, streaming (`delta`) or not
/// (`message`). Unknown fields are ignored so provider extensions
/// do not break parsing.
const SseChoice = struct {
    delta: ?struct { content: ?[]const u8 = null } = null,
    message: ?struct { content: ?[]const u8 = null } = null,
};

const SseChunkJson = struct {
    choices: []SseChoice = &.{},
};

/// Incremental SSE parser. Feed it raw body bytes in any chunking;
/// complete `data:` lines are parsed as JSON and their content
/// delivered via `on_chunk`. Handles lines split across feeds,
/// `data: [DONE]`, `:ping` keepalives, and a plain (non-streaming)
/// JSON completion body (a line starting with `{`).
pub const SseParser = struct {
    alloc: std.mem.Allocator,
    line_buf: std.ArrayList(u8) = .empty,
    done: bool = false,

    pub fn init(alloc: std.mem.Allocator) SseParser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *SseParser) void {
        self.line_buf.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn feed(self: *SseParser, bytes: []const u8, chunk_ctx: *anyopaque, on_chunk: ChunkFn) !void {
        for (bytes) |b| {
            if (self.done) return;
            if (b == '\n') {
                const line = self.line_buf.items;
                try self.handleLine(line, chunk_ctx, on_chunk);
                self.line_buf.clearRetainingCapacity();
            } else if (b != '\r') {
                try self.line_buf.append(self.alloc, b);
            }
        }
    }

    /// Flush a final line that had no trailing newline.
    pub fn finish(self: *SseParser, chunk_ctx: *anyopaque, on_chunk: ChunkFn) !void {
        if (self.done) return;
        if (self.line_buf.items.len > 0) {
            try self.handleLine(self.line_buf.items, chunk_ctx, on_chunk);
            self.line_buf.clearRetainingCapacity();
        }
    }

    fn handleLine(self: *SseParser, line: []const u8, chunk_ctx: *anyopaque, on_chunk: ChunkFn) !void {
        if (line.len == 0) return;
        if (std.mem.startsWith(u8, line, "data:")) {
            const payload = std.mem.trim(u8, line["data:".len..], " ");
            if (payload.len == 0) return;
            if (std.mem.eql(u8, payload, "[DONE]")) {
                self.done = true;
                return;
            }
            try self.emitJson(payload, chunk_ctx, on_chunk);
        } else if (line[0] == '{') {
            try self.emitJson(line, chunk_ctx, on_chunk);
        }
        // Anything else (":ping", "event:", ...) is ignored.
    }

    fn emitJson(self: *SseParser, json_text: []const u8, chunk_ctx: *anyopaque, on_chunk: ChunkFn) !void {
        const parsed = std.json.parseFromSlice(SseChunkJson, self.alloc, json_text, .{ .ignore_unknown_fields = true }) catch return error.InvalidSseData;
        defer parsed.deinit();
        const content: ?[]const u8 = blk: {
            if (parsed.value.choices.len == 0) break :blk null;
            const c = parsed.value.choices[0];
            if (c.delta) |d| {
                if (d.content) |t| break :blk t;
            }
            if (c.message) |m| {
                if (m.content) |t| break :blk t;
            }
            break :blk null;
        };
        if (content) |t| {
            if (t.len == 0) return;
            // The parsed content may borrow from the parse result's
            // arena: copy it before deinit so the chunk is safe to use.
            const owned = try self.alloc.dupe(u8, t);
            defer self.alloc.free(owned);
            try on_chunk(chunk_ctx, owned);
        }
    }
};

const ChatMessage = struct { role: []const u8, content: []const u8 };
const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    stream: bool,
    temperature: f32,
};

/// Build the OpenAI-compatible chat-completions request body.
pub fn buildChatRequest(alloc: std.mem.Allocator, model: []const u8, prompt: []const u8) ![]const u8 {
    const req = ChatRequest{
        .model = model,
        .messages = &.{.{ .role = "user", .content = prompt }},
        .stream = true,
        .temperature = 0.7,
    };
    return std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(req, .{})});
}

/// OpenAI-compatible chat-completions brain over `sender`.
/// `url` and `model` are borrowed (caller-owned).
pub const HttpBrain = struct {
    url: []const u8,
    model: []const u8,
    sender: Sender,

    pub fn init(url: []const u8, model: []const u8, sender: Sender) HttpBrain {
        return .{ .url = url, .model = model, .sender = sender };
    }

    pub fn asBrain(self: *HttpBrain) Brain {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Brain.VTable{
        .reply = replyImpl,
        .name = nameImpl,
        .deinit = deinitImpl,
    };

    fn nameImpl(_: *anyopaque) []const u8 {
        return "http";
    }

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    fn replyImpl(
        ptr: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        prompt: []const u8,
        cancel: ?*const bool,
        chunk_ctx: *anyopaque,
        on_chunk: ChunkFn,
    ) anyerror![]const u8 {
        const self: *HttpBrain = @ptrCast(@alignCast(ptr));
        if (cancel) |c| {
            if (c.*) return error.Cancelled;
        }
        const body = try buildChatRequest(alloc, self.model, prompt);
        defer alloc.free(body);
        var collector = Collector.init(alloc, chunk_ctx, on_chunk);
        defer collector.deinit();
        var parser = SseParser.init(alloc);
        defer parser.deinit();
        var ctx = SendCtx{ .parser = &parser, .collector = &collector, .cancel = cancel };
        try self.sender.send(alloc, io, self.url, body, &ctx, httpBytesChunk);
        try parser.finish(&collector, collectorChunk);
        return collector.toOwned();
    }
};

const SendCtx = struct {
    parser: *SseParser,
    collector: *Collector,
    cancel: ?*const bool,
};

/// `Sender` byte callback: check the cancel flag, then feed the SSE
/// parser (which forwards content chunks to the collector).
fn httpBytesChunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const c: *SendCtx = @ptrCast(@alignCast(ctx));
    if (c.cancel) |flag| {
        if (flag.*) return error.Cancelled;
    }
    try c.parser.feed(bytes, c.collector, collectorChunk);
}

// ---------------------------------------------------------------------------
// TestSender — canned bytes for tests (no network).
// ---------------------------------------------------------------------------

/// A sender that replays canned response bytes in order and records
/// the request it received. Test-only.
pub const TestSender = struct {
    chunks: []const []const u8,
    url_seen: ?[]const u8 = null,
    body_seen: ?[]const u8 = null,
    body_alloc: ?std.mem.Allocator = null,

    pub fn asSender(self: *TestSender) Sender {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Sender.VTable{ .send = sendImpl };

    fn sendImpl(
        ptr: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        body: []const u8,
        bytes_ctx: *anyopaque,
        on_bytes: BytesFn,
    ) anyerror!void {
        _ = io;
        const self: *TestSender = @ptrCast(@alignCast(ptr));
        self.url_seen = url;
        self.body_seen = try alloc.dupe(u8, body);
        self.body_alloc = alloc;
        for (self.chunks) |c| try on_bytes(bytes_ctx, c);
    }

    /// Free the recorded request body (call at the end of the test).
    pub fn deinit(self: *TestSender) void {
        if (self.body_seen) |b| {
            if (self.body_alloc) |a| a.free(b);
        }
        self.body_seen = null;
        self.body_alloc = null;
    }
};

test "mock brain streams scripted replies word by word" {
    const alloc = std.testing.allocator;
    var mock = MockBrain{};
    const b = mock.asBrain();
    try std.testing.expectEqualStrings("mock", b.brainName());

    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();
    const reply = try b.reply(alloc, std.testing.io, "User: tell me a joke\nAssistant:", null, &collector, collectorChunk);
    defer alloc.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "cache") != null);
    // The joined chunks equal the reply exactly.
    try std.testing.expectEqualStrings(reply, collector.list.items);

    // Default reply for an unmatched prompt.
    var collector2 = Collector.init(alloc, null, null);
    defer collector2.deinit();
    const reply2 = try b.reply(alloc, std.testing.io, "User: zqxj vbnm\nAssistant:", null, &collector2, collectorChunk);
    defer alloc.free(reply2);
    try std.testing.expectEqualStrings(MockBrain.default_reply_text, reply2);
}

test "mock brain matches the last user turn, not history" {
    const alloc = std.testing.allocator;
    var mock = MockBrain{};
    const b = mock.asBrain();
    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();
    // History mentions a joke; the current turn does not.
    const prompt = "You are Sando.\nUser: tell me a joke\nAssistant: Why did the developer go broke? Because he used up all his cache.\nUser: what can you do\nAssistant:";
    const reply = try b.reply(alloc, std.testing.io, prompt, null, &collector, collectorChunk);
    defer alloc.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "listen to your voice") != null);
}

test "mock brain stops on cancel" {
    const alloc = std.testing.allocator;
    var mock = MockBrain{};
    const b = mock.asBrain();
    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();
    const cancelled = true;
    try std.testing.expectError(error.Cancelled, b.reply(alloc, std.testing.io, "User: hello\nAssistant:", &cancelled, &collector, collectorChunk));
}

test "sse parser handles split feeds, done marker and keepalives" {
    const alloc = std.testing.allocator;
    var parser = SseParser.init(alloc);
    defer parser.deinit();
    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();

    // One event split mid-JSON across two feeds, a keepalive, then [DONE].
    try parser.feed("data: {\"choices\":[{\"delta\":{\"con", &collector, collectorChunk);
    try parser.feed("tent\":\"Hel", &collector, collectorChunk);
    try parser.feed("lo\"}}]}\n\n:ping\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\ndata: [DONE]\n\n", &collector, collectorChunk);
    try parser.finish(&collector, collectorChunk);
    try std.testing.expectEqualStrings("Hello world", collector.list.items);
    try std.testing.expect(parser.done);
}

test "sse parser accepts a plain json completion body" {
    const alloc = std.testing.allocator;
    var parser = SseParser.init(alloc);
    defer parser.deinit();
    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();
    try parser.feed("{\"choices\":[{\"message\":{\"content\":\"plain reply\"}}]}", &collector, collectorChunk);
    try parser.finish(&collector, collectorChunk);
    try std.testing.expectEqualStrings("plain reply", collector.list.items);
}

test "sse parser rejects a malformed data line" {
    const alloc = std.testing.allocator;
    var parser = SseParser.init(alloc);
    defer parser.deinit();
    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();
    try std.testing.expectError(error.InvalidSseData, parser.feed("data: not json at all\n", &collector, collectorChunk));
}

test "http brain sends an openai-compatible request and streams the reply" {
    const alloc = std.testing.allocator;
    var sender = TestSender{
        .chunks = &.{
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: [DONE]\n\n",
        },
    };
    defer sender.deinit();
    var http = HttpBrain.init("http://127.0.0.1:18099/v1/chat/completions", "local-model", sender.asSender());
    const b = http.asBrain();
    try std.testing.expectEqualStrings("http", b.brainName());

    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();
    const reply = try b.reply(alloc, std.testing.io, "User: hello\nAssistant:", null, &collector, collectorChunk);
    defer alloc.free(reply);
    try std.testing.expectEqualStrings("Hello", reply);
    try std.testing.expectEqualStrings("Hello", collector.list.items);

    // The request it sent is OpenAI-compatible JSON.
    try std.testing.expectEqualStrings("http://127.0.0.1:18099/v1/chat/completions", sender.url_seen.?);
    const body = sender.body_seen.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"local-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
}

test "agent brain calls the host callback" {
    const alloc = std.testing.allocator;
    const Ctx = struct {
        fn cb(ctx: *anyopaque, cb_alloc: std.mem.Allocator, prompt: []const u8, chunk_ctx: *anyopaque, on_chunk: ChunkFn) anyerror![]const u8 {
            _ = ctx;
            try std.testing.expect(std.mem.indexOf(u8, prompt, "hello") != null);
            try on_chunk(chunk_ctx, "host ");
            try on_chunk(chunk_ctx, "reply");
            return try cb_alloc.dupe(u8, "host reply");
        }
    };
    var ctx: u8 = 0;
    var agent = AgentBrain{ .ctx = &ctx, .callback = Ctx.cb };
    const b = agent.asBrain();
    try std.testing.expectEqualStrings("agent", b.brainName());
    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();
    const reply = try b.reply(alloc, std.testing.io, "User: hello\nAssistant:", null, &collector, collectorChunk);
    defer alloc.free(reply);
    try std.testing.expectEqualStrings("host reply", reply);
    try std.testing.expectEqualStrings("host reply", collector.list.items);
}

// ---------------------------------------------------------------------------
// Loopback test: the real StdHttpSender against a real local server.
// ---------------------------------------------------------------------------

const LoopbackState = struct {
    port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn loopbackServerThread(state: *LoopbackState, io: std.Io) void {
    // Bind a fixed port in a small range (no getsockname API for an
    // ephemeral port in this Zig version).
    var port: u16 = 18131;
    var server: std.Io.net.Server = undefined;
    while (port < 18145) : (port += 1) {
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
    const sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: [DONE]\n\n";
    req.respond(sse, .{ .status = .ok, .extra_headers = &.{.{ .name = "Content-Type", .value = "text/event-stream" }} }) catch return;
}

test "http brain streams from a real local server" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var state = LoopbackState{};
    const t = try std.Thread.spawn(.{}, loopbackServerThread, .{ &state, io });
    // Do not join: if the client never connects the thread stays
    // blocked in accept() and the process exit ends it. The test
    // itself waits for the ready flag below.
    _ = t;

    // Wait for the server to be listening. The server thread binds in
    // milliseconds; a plain spin with a generous bound is enough here.
    var waited: u32 = 0;
    while (!state.ready.load(.acquire)) : (waited += 1) {
        if (waited > 50_000_000) return error.TestFailed;
    }
    const port = state.port.load(.acquire);
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/v1/chat/completions", .{port});
    defer alloc.free(url);

    var sender = StdHttpSender{};
    var http = HttpBrain.init(url, "local-model", sender.asSender());
    const b = http.asBrain();
    var collector = Collector.init(alloc, null, null);
    defer collector.deinit();
    const reply = try b.reply(alloc, io, "User: hello\nAssistant:", null, &collector, collectorChunk);
    defer alloc.free(reply);
    try std.testing.expectEqualStrings("Hello", reply);
}
