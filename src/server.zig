//! OneAPI REST server (Phase 5): `sando-audio serve`.
//!
//! A Zig HTTP server over `std.http` (the same transport the HTTP
//! brain already uses — no new framework) exposing the OneAPI over
//! JSON on 127.0.0.1 by default. Single-threaded, sequential accept
//! loop: one request at a time, which is honest about what this
//! machine can do (ASR inference takes seconds; concurrent
//! inference would OOM it anyway).
//!
//! Security, enforced here, not in docs:
//!   - binds 127.0.0.1 by default; 0.0.0.0 only with an explicit
//!     `--host 0.0.0.0` and a loud warning,
//!   - API key from the environment only (`SANDO_API_KEY`, see
//!     oneapi.zig); missing/wrong key on any /v1/* route = 401,
//!   - request bodies size-capped (JSON 64 KiB, WAV 8 MiB by
//!     default); over-cap = 413,
//!   - no key is ever logged or written to a file,
//!   - TTS and Koloqua ASR report as unavailable, never simulated.
//!
//! The engine is optional: a server started without one still
//! serves health, version, languages, text conversations (mock
//! brain), and metrics. Inference (`/v1/infer`) and model
//! management need the engine and answer 503 without it.

const std = @import("std");
const root = @import("root.zig");
const oneapi = @import("oneapi.zig");
const engine = @import("engine.zig");
const runtime = @import("runtime.zig");
const config = @import("config.zig");
const models = @import("models.zig");
const audio = @import("audio.zig");
const brain = @import("brain.zig");
const conversation = @import("conversation.zig");
const pulse = @import("pulse.zig");
const language = @import("language.zig");
const vocabulary = @import("vocabulary.zig");
const pronunciation = @import("pronunciation.zig");
const adaptive_ear = @import("adaptive_ear.zig");
const vad = @import("vad.zig");

pub const default_port: u16 = 8080;
pub const default_max_sessions: usize = 32;
pub const default_max_body_bytes: usize = 8 << 20;
pub const max_json_bytes: usize = 64 << 10;

pub const ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,
    max_sessions: usize = default_max_sessions,
    max_body_bytes: usize = default_max_body_bytes,
    config_path: []const u8 = engine.default_config_path,
    models_dir: []const u8 = "models",
    /// Borrowed (process environment). Null = open dev mode.
    api_key: ?[]const u8 = null,
};

/// One live conversation session: a heap-allocated MockBrain (the
/// Conversation's brain vtable points at it, so it must outlive the
/// Conversation) plus the Conversation itself. The Pulse client
/// also lives here: it borrows the entry's own sender and the
/// engine config's Pulse URL, and the Conversation borrows the
/// client — all three outlive the session because the entry is
/// heap-allocated and stable until eviction or deletion.
const SessionEntry = struct {
    mock: *brain.MockBrain,
    conv: conversation.Conversation,
    created_ms: i64,
    pulse_sender: pulse.StdHttpSender,
    pulse_client: pulse.PulseClient,

    fn deinit(self: *SessionEntry, alloc: std.mem.Allocator) void {
        self.conv.deinit();
        alloc.destroy(self.mock);
        self.* = undefined;
    }
};

/// JSON shapes for the OneAPI responses. Named so they can be
/// collected in typed lists and serialized with valueAlloc.
const ModelEntryJson = struct {
    name: []const u8,
    kind: []const u8,
    file: []const u8,
    loaded: bool,
    size_bytes: u64,
};

const LanguageEntryJson = struct {
    code: []const u8,
    name: []const u8,
    status: []const u8,
    script: []const u8,
    asr_model: ?[]const u8,
    tts_available: bool,
};

const VocabMatchJson = struct {
    id: []const u8,
    side: []const u8,
    input: []const u8,
    response: []const u8,
    standard_english: []const u8,
    source: []const u8,
};

const SessionSummaryJson = struct {
    id: []const u8,
    language: []const u8,
    voice: []const u8,
    turns: usize,
};

const VadSegmentJson = struct {
    start_s: f64,
    end_s: f64,
};

const RouteCountJson = struct {
    route: []const u8,
    count: u64,
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    opts: ServerOptions,
    /// Null when started without an engine (health/version/text
    /// conversation still work; inference answers 503).
    eng: ?engine.Engine,
    vocab: ?vocabulary.Vocabulary,
    listener: std.Io.net.Server,
    metrics: oneapi.Metrics,
    sessions: std.StringHashMap(*SessionEntry),
    /// Session ids in creation order (oldest first) for eviction.
    session_order: std.ArrayList([]const u8),
    asr: ?runtime.Session = null,
    asr_failed: bool = false,
    asr_error: []const u8 = "",
    listener_open: bool = true,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        opts: ServerOptions,
        eng: ?engine.Engine,
        vocab: ?vocabulary.Vocabulary,
    ) !Server {
        const addr = try std.Io.net.IpAddress.parse(opts.host, opts.port);
        var listener = try addr.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        return .{
            .alloc = alloc,
            .io = io,
            .opts = opts,
            .eng = eng,
            .vocab = vocab,
            .listener = listener,
            .metrics = oneapi.Metrics.init(alloc, models.nowMs(io)),
            .sessions = std.StringHashMap(*SessionEntry).init(alloc),
            .session_order = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop.store(true, .release);
        if (self.listener_open) {
            self.listener.deinit(self.io);
            self.listener_open = false;
        }
        var it = self.sessions.valueIterator();
        while (it.next()) |entry| {
            entry.*.deinit(self.alloc);
            self.alloc.destroy(entry.*);
        }
        self.sessions.deinit();
        self.session_order.deinit(self.alloc);
        if (self.asr) |*s| s.deinit(self.alloc);
        if (self.vocab) |*v| v.deinit();
        if (self.eng) |*e| e.deinit();
        self.metrics.deinit();
        self.* = undefined;
    }

    /// Bound port (useful when started on port 0 in tests).
    pub fn boundPort(self: *const Server) u16 {
        return self.listener.socket.address.getPort();
    }

    /// Ask the accept loop to stop. Safe to call from another
    /// thread: closing the listener unblocks a pending accept.
    pub fn shutdown(self: *Server) void {
        self.stop.store(true, .release);
        // Wake the accept loop with a loopback connection: closing
        // the listener from another thread does NOT unblock a
        // blocked accept() on Linux, so this dummy connection is
        // what makes accept return (the loop sees the stop flag and
        // exits without answering it). The listener itself is closed
        // by deinit, after the accept thread has joined.
        if (self.listener_open) {
            if (std.Io.net.IpAddress.parse(self.opts.host, self.boundPort())) |addr| {
                if (addr.connect(self.io, .{ .mode = .stream })) |s| {
                    var stream = s;
                    stream.close(self.io);
                } else |_| {}
            } else |_| {}
        }
    }

    /// Accept loop. Returns when `shutdown` is called or the
    /// listener dies. One request per connection, then close.
    pub fn run(self: *Server) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch |err| {
                if (err == error.SocketNotListening) break;
                if (self.stop.load(.acquire)) break;
                continue;
            };
            if (self.stop.load(.acquire)) {
                stream.close(self.io);
                break;
            }
            self.handleConnection(stream) catch {};
            stream.close(self.io);
        }
    }

    fn handleConnection(self: *Server, stream: std.Io.net.Stream) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        var in_buf: [8192]u8 = undefined;
        var out_buf: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var req = http.receiveHead() catch return;
        self.handleRequest(alloc, &req) catch {
            // Last-resort: the handler already tried to answer.
            return;
        };
    }

    /// Route one request. `alloc` is a per-connection arena.
    fn handleRequest(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const method = req.head.method;
        const raw_target = try alloc.dupe(u8, req.head.target);
        const target = splitQuery(raw_target);
        const auth_header = try self.authHeader(alloc, req);
        self.metrics.record(routePattern(method, target));

        // The WebUI is public (it has its own key box); every /v1/*
        // route requires the key when one is configured.
        if (std.mem.startsWith(u8, target, "/v1/")) {
            if (!oneapi.checkAuth(self.opts.api_key, auth_header)) {
                return self.respondError(alloc, req, .unauthorized, "missing or wrong API key (Authorization: Bearer <key>)");
            }
        }

        switch (method) {
            .GET => {
                if (std.mem.eql(u8, target, "/")) return self.respondWebUi(req);
                if (std.mem.eql(u8, target, "/v1/health")) return self.handleHealth(alloc, req);
                if (std.mem.eql(u8, target, "/v1/version")) return self.handleVersion(alloc, req);
                if (std.mem.eql(u8, target, "/v1/models")) return self.handleModelsList(alloc, req);
                if (std.mem.eql(u8, target, "/v1/languages")) return self.handleLanguages(alloc, req);
                if (std.mem.eql(u8, target, "/v1/conversations")) return self.handleConversationsList(alloc, req);
                if (std.mem.eql(u8, target, "/v1/metrics")) return self.handleMetrics(alloc, req);
                if (std.mem.startsWith(u8, target, "/v1/conversation/")) {
                    const id = target["/v1/conversation/".len..];
                    if (std.mem.indexOfScalar(u8, id, '/') == null and id.len > 0) {
                        return self.handleConversationGet(alloc, req, id);
                    }
                }
                return self.respondError(alloc, req, .not_found, "unknown route");
            },
            .POST => {
                if (std.mem.eql(u8, target, "/v1/language/identify")) return self.handleIdentify(alloc, req);
                if (std.mem.eql(u8, target, "/v1/language/vocab")) return self.handleVocab(alloc, req);
                if (std.mem.eql(u8, target, "/v1/language/pronounce")) return self.handlePronounce(alloc, req);
                if (std.mem.eql(u8, target, "/v1/language/route")) return self.handleRoute(alloc, req);
                if (std.mem.eql(u8, target, "/v1/conversation")) return self.handleConversationCreate(alloc, req);
                if (std.mem.eql(u8, target, "/v1/models/install")) return self.handleModelInstall(alloc, req);
                if (std.mem.eql(u8, target, "/v1/infer")) return self.handleInfer(alloc, req, raw_target);
                if (std.mem.startsWith(u8, target, "/v1/conversation/") and std.mem.endsWith(u8, target, "/ask")) {
                    const id = target["/v1/conversation/".len .. target.len - "/ask".len];
                    if (id.len > 0) return self.handleConversationAsk(alloc, req, id);
                }
                return self.respondError(alloc, req, .not_found, "unknown route");
            },
            .DELETE => {
                if (std.mem.startsWith(u8, target, "/v1/models/")) {
                    const name = target["/v1/models/".len..];
                    if (name.len > 0) return self.handleModelRemove(alloc, req, name);
                }
                if (std.mem.startsWith(u8, target, "/v1/conversation/")) {
                    const id = target["/v1/conversation/".len..];
                    if (std.mem.indexOfScalar(u8, id, '/') == null and id.len > 0) {
                        return self.handleConversationDelete(alloc, req, id);
                    }
                }
                return self.respondError(alloc, req, .not_found, "unknown route");
            },
            else => return self.respondError(alloc, req, .method_not_allowed, "method not supported by this API"),
        }
    }

    /// Route pattern for metrics (ids collapsed, so cardinality
    /// stays bounded).
    fn routePattern(method: std.http.Method, target: []const u8) []const u8 {
        if (std.mem.startsWith(u8, target, "/v1/conversation/")) {
            if (std.mem.endsWith(u8, target, "/ask")) return switch (method) {
                .POST => "POST /v1/conversation/:id/ask",
                else => "OTHER /v1/conversation/:id/ask",
            };
            return switch (method) {
                .GET => "GET /v1/conversation/:id",
                .DELETE => "DELETE /v1/conversation/:id",
                else => "OTHER /v1/conversation/:id",
            };
        }
        if (std.mem.startsWith(u8, target, "/v1/models/")) return "DELETE /v1/models/:name";
        return switch (method) {
            .GET => switch (target.len) {
                else => blk: {
                    if (std.mem.eql(u8, target, "/")) break :blk "GET /";
                    if (std.mem.eql(u8, target, "/v1/health")) break :blk "GET /v1/health";
                    if (std.mem.eql(u8, target, "/v1/version")) break :blk "GET /v1/version";
                    if (std.mem.eql(u8, target, "/v1/models")) break :blk "GET /v1/models";
                    if (std.mem.eql(u8, target, "/v1/languages")) break :blk "GET /v1/languages";
                    if (std.mem.eql(u8, target, "/v1/conversations")) break :blk "GET /v1/conversations";
                    if (std.mem.eql(u8, target, "/v1/metrics")) break :blk "GET /v1/metrics";
                    break :blk "GET unknown";
                },
            },
            .POST => blk: {
                if (std.mem.eql(u8, target, "/v1/language/identify")) break :blk "POST /v1/language/identify";
                if (std.mem.eql(u8, target, "/v1/language/vocab")) break :blk "POST /v1/language/vocab";
                if (std.mem.eql(u8, target, "/v1/language/pronounce")) break :blk "POST /v1/language/pronounce";
                if (std.mem.eql(u8, target, "/v1/language/route")) break :blk "POST /v1/language/route";
                if (std.mem.eql(u8, target, "/v1/conversation")) break :blk "POST /v1/conversation";
                if (std.mem.eql(u8, target, "/v1/models/install")) break :blk "POST /v1/models/install";
                if (std.mem.eql(u8, target, "/v1/infer")) break :blk "POST /v1/infer";
                break :blk "POST unknown";
            },
            else => "OTHER unknown",
        };
    }

    fn splitQuery(target: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, target, '?')) |i| return target[0..i];
        return target;
    }

    fn queryValue(target: []const u8, key: []const u8) ?[]const u8 {
        const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
        var pairs = std.mem.splitScalar(u8, target[q + 1 ..], '&');
        while (pairs.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
            }
        }
        return null;
    }

    /// The Authorization header value, if present. Case-insensitive
    /// name match; the value is copied (head strings are invalidated
    /// once the body is read).
    fn authHeader(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !?[]const u8 {
        _ = self;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                return try alloc.dupe(u8, h.value);
            }
        }
        return null;
    }

    /// Read the request body, capped. Returns null when there is no
    /// body. Over-cap returns error.TooLarge (the caller answers
    /// 413). Expects a Content-Length; chunked bodies are read the
    /// same way through the body reader.
    fn readBody(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, cap: usize) !?[]u8 {
        _ = self;
        const len = req.head.content_length orelse return null;
        if (len == 0) return null;
        if (len > cap) return error.TooLarge;
        var buf: [4096]u8 = undefined;
        const body_reader = req.readerExpectContinue(&buf) catch |err| switch (err) {
            error.HttpExpectationFailed => return error.BadExpectation,
            else => |e| return e,
        };
        const body = try body_reader.readAllocShort(alloc, cap);
        return body;
    }

    fn respondJson(self: *Server, req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
        _ = self;
        try req.respond(body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    fn respondError(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, err_code: oneapi.ApiErrorCode, message: []const u8) !void {
        self.metrics.last_error = err_code.code();
        const body = try oneapi.errorJson(alloc, err_code, message);
        return self.respondJson(req, err_code.httpStatus(), body);
    }

    /// Serialize `value` to JSON and answer with it.
    fn json(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, status: std.http.Status, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(alloc, value, .{});
        return self.respondJson(req, status, body);
    }

    // --- handlers ---

    fn handleHealth(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const body = try std.fmt.allocPrint(alloc, "{{\"status\":\"ok\",\"version\":\"{s}\",\"phase\":5,\"auth\":{s}}}", .{
            root.version,
            if (self.opts.api_key != null) "true" else "false",
        });
        return self.respondJson(req, .ok, body);
    }

    fn handleVersion(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        var tasks = std.ArrayList([]const u8).empty;
        if (self.eng) |*e| {
            const n = e.rt.taskCount();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try tasks.append(alloc, e.rt.taskName(i) orelse "?");
            }
        }
        const linked = self.eng != null and self.eng.?.isLinked();
        return self.json(alloc, req, .ok, .{
            .version = root.version,
            .audio_cpp_linked = linked,
            .tasks = tasks.items,
        });
    }

    fn handleModelsList(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        var list = std.ArrayList(ModelEntryJson).empty;
        if (self.eng) |*e| {
            for (e.cfg.models) |m| {
                const rec = e.registry.lookup(m.name);
                try list.append(alloc, .{
                    .name = m.name,
                    .kind = @tagName(m.kind),
                    .file = m.file,
                    .loaded = rec != null and rec.?.loaded,
                    .size_bytes = if (rec) |r| r.size_bytes else models.fileSize(self.io, m.file) catch 0,
                });
            }
        }
        return self.json(alloc, req, .ok, .{ .models = list.items });
    }

    fn handleLanguages(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        var list = std.ArrayList(LanguageEntryJson).empty;
        for (&language.registry) |l| {
            try list.append(alloc, .{
                .code = l.code,
                .name = l.name,
                .status = @tagName(l.status),
                .script = l.script,
                .asr_model = l.asr_model,
                .tts_available = l.tts_available,
            });
        }
        return self.json(alloc, req, .ok, .{ .languages = list.items });
    }

    fn handleIdentify(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const body = try self.readJsonBody(alloc, req) orelse return self.respondError(alloc, req, .bad_request, "missing or empty JSON body");
        var parsed = oneapi.parseJsonBody(oneapi.IdentifyRequest, alloc, body) orelse
            return self.respondError(alloc, req, .bad_request, "body is not a valid identify request ({\"text\": \"...\"})");
        defer parsed.deinit();
        const text = parsed.value.text orelse
            return self.respondError(alloc, req, .bad_request, "identify needs a \"text\" field");
        const vptr: ?*const vocabulary.Vocabulary = if (self.vocab) |*v| v else null;
        const id = language.identify(alloc, text, vptr) catch |err|
            return self.respondError(alloc, req, .internal, @errorName(err));
        const lang_name = if (language.find(id.language)) |l| l.name else "Unknown";
        return self.json(alloc, req, .ok, .{
            .language = id.language,
            .name = lang_name,
            .confidence = id.confidence,
            .scored = id.scored,
            .tokens = id.tokens,
            .scores = id.scores,
        });
    }

    fn handleVocab(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const body = try self.readJsonBody(alloc, req) orelse return self.respondError(alloc, req, .bad_request, "missing or empty JSON body");
        var parsed = oneapi.parseJsonBody(oneapi.VocabRequest, alloc, body) orelse
            return self.respondError(alloc, req, .bad_request, "body is not a valid vocab request ({\"word\": \"...\"})");
        defer parsed.deinit();
        const word = parsed.value.word orelse
            return self.respondError(alloc, req, .bad_request, "vocab needs a \"word\" field");
        const code = parsed.value.language orelse "kq";
        const vocab = self.vocab orelse
            return self.respondError(alloc, req, .asr_unavailable, "no dataset loaded — start the server with --data-dir <datasets>");
        const ds = vocab.dataset(code) orelse
            return self.respondError(alloc, req, .not_found, "no dataset for that language");
        const matches = ds.lookup(alloc, word, 8) catch |err|
            return self.respondError(alloc, req, .internal, @errorName(err));
        var list = std.ArrayList(VocabMatchJson).empty;
        for (matches) |m| {
            const e = m.entry;
            try list.append(alloc, .{
                .id = e.id,
                .side = m.side,
                .input = e.input,
                .response = e.response,
                .standard_english = e.standard_english,
                .source = e.source,
            });
        }
        return self.json(alloc, req, .ok, .{ .word = word, .language = code, .matches = list.items });
    }

    fn handlePronounce(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const body = try self.readJsonBody(alloc, req) orelse return self.respondError(alloc, req, .bad_request, "missing or empty JSON body");
        var parsed = oneapi.parseJsonBody(oneapi.VocabRequest, alloc, body) orelse
            return self.respondError(alloc, req, .bad_request, "body is not a valid pronounce request ({\"word\": \"...\"})");
        defer parsed.deinit();
        const word = parsed.value.word orelse
            return self.respondError(alloc, req, .bad_request, "pronounce needs a \"word\" field");
        const code = parsed.value.language orelse "kq";
        const vocab = self.vocab orelse
            return self.respondError(alloc, req, .asr_unavailable, "no dataset loaded — start the server with --data-dir <datasets>");
        const ds = vocab.dataset(code) orelse
            return self.respondError(alloc, req, .not_found, "no dataset for that language");
        const pron = pronunciation.lookup(alloc, ds, word) catch |err|
            return self.respondError(alloc, req, .internal, @errorName(err));
        if (pron == null) {
            return self.respondError(alloc, req, .not_found, "no attested pronunciation for that word");
        }
        const p = pron.?;
        return self.json(alloc, req, .ok, .{
            .word = word,
            .language = code,
            .form = p.attested_form,
            .meaning = p.meaning,
            .id = p.id,
            .syllables = p.syllables,
            .heuristic = p.syllables_heuristic,
            .source = p.source,
        });
    }

    fn handleRoute(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const body = try self.readJsonBody(alloc, req) orelse return self.respondError(alloc, req, .bad_request, "missing or empty JSON body");
        var parsed = oneapi.parseJsonBody(oneapi.RouteRequest, alloc, body) orelse
            return self.respondError(alloc, req, .bad_request, "body is not a valid route request ({\"text\": \"...\"})");
        defer parsed.deinit();
        const text = parsed.value.text orelse
            return self.respondError(alloc, req, .bad_request, "route needs a \"text\" field");
        const vptr: ?*const vocabulary.Vocabulary = if (self.vocab) |*v| v else null;
        const id = language.identify(alloc, text, vptr) catch |err|
            return self.respondError(alloc, req, .internal, @errorName(err));
        const route = adaptive_ear.routeFor(id.language);
        const report = try adaptive_ear.report(alloc, &route);
        return self.json(alloc, req, .ok, .{
            .language = id.language,
            .confidence = id.confidence,
            .asr = route.model orelse "none",
            .report = report,
        });
    }

    /// Read a JSON request body (capped at max_json_bytes). Answers
    /// 413 itself when over cap; returns null when there is no body.
    fn readJsonBody(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !?[]u8 {
        const body = self.readBody(alloc, req, max_json_bytes) catch |err| switch (err) {
            error.TooLarge => {
                try self.respondError(alloc, req, .too_large, "JSON body over the 64 KiB cap");
                return null;
            },
            error.BadExpectation => {
                try self.respondError(alloc, req, .bad_request, "unsupported Expect header (only 100-continue)");
                return null;
            },
            else => {
                try self.respondError(alloc, req, .bad_request, "could not read the request body");
                return null;
            },
        };
        return body;
    }

    fn handleConversationCreate(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        var lang_code: []const u8 = "en";
        var voice: []const u8 = "v1";
        if (try self.readJsonBody(alloc, req)) |body| {
            if (oneapi.parseJsonBody(oneapi.ConversationCreateRequest, alloc, body)) |parsed| {
                defer parsed.deinit();
                if (parsed.value.language) |l| lang_code = l;
                if (parsed.value.voice) |v| voice = v;
            }
        }
        // "en" is the legacy code for Liberian English ("en-lr").
        lang_code = language.normalizeCode(lang_code) orelse
            return self.respondError(alloc, req, .bad_request, "unknown language code");
        // Evict the oldest session when at the cap.
        if (self.sessions.count() >= self.opts.max_sessions) {
            if (self.session_order.items.len > 0) {
                const oldest = self.session_order.orderedRemove(0);
                if (self.sessions.fetchRemove(oldest)) |kv| {
                    kv.value.deinit(self.alloc);
                    self.alloc.destroy(kv.value);
                }
            }
        }
        const mock = try self.alloc.create(brain.MockBrain);
        mock.* = .{};
        errdefer self.alloc.destroy(mock);
        const conv = conversation.Conversation.init(self.alloc, self.io, mock.asBrain(), voice, lang_code) catch |err|
            return self.respondError(alloc, req, .internal, @errorName(err));
        var conv_mut = conv;
        // Operator persona override from the server config;
        // otherwise the built-in Sando persona is the default.
        if (self.eng) |*eng| {
            if (eng.cfg.persona_prompt) |p| conv_mut.session.system_prompt = p;
        }
        const entry = try self.alloc.create(SessionEntry);
        entry.* = .{
            .mock = mock,
            .conv = conv_mut,
            .created_ms = models.nowMs(self.io),
            .pulse_sender = .{},
            // Set below, once the entry exists: the client borrows
            // the entry's own sender.
            .pulse_client = undefined,
        };
        // Pulse knowledge for this session: the [pulse] config
        // section when the server has an engine, off otherwise
        // (health/version/text conversation still work without
        // one). The client is disabled by default here and only
        // enabled from the config, so a server started without an
        // engine never tries to reach Pulse.
        entry.pulse_client = pulse.PulseClient.init("http://127.0.0.1:9000", false, entry.pulse_sender.asSender());
        if (self.eng) |*eng| {
            entry.pulse_client = pulse.PulseClient.init(eng.cfg.pulse.url, eng.cfg.pulse.enabled, entry.pulse_sender.asSender());
        }
        entry.conv.pulse = &entry.pulse_client;
        const id = entry.conv.session.id;
        try self.sessions.put(id, entry);
        try self.session_order.append(self.alloc, id);
        const body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"language\":\"{s}\",\"voice\":\"{s}\",\"turns\":0}}", .{ id, lang_code, voice });
        return self.respondJson(req, .created, body);
    }

    fn handleConversationsList(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        var list = std.ArrayList(SessionSummaryJson).empty;
        for (self.session_order.items) |id| {
            const entry = self.sessions.get(id) orelse continue;
            try list.append(alloc, .{
                .id = id,
                .language = entry.conv.session.language,
                .voice = entry.conv.session.voice,
                .turns = entry.conv.session.turnCount(),
            });
        }
        return self.json(alloc, req, .ok, .{ .sessions = list.items });
    }

    fn handleConversationGet(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, id: []const u8) !void {
        const entry = self.sessions.get(id) orelse
            return self.respondError(alloc, req, .session_not_found, "no conversation with that id");
        const body = try self.conversationJson(alloc, entry);
        return self.respondJson(req, .ok, body);
    }

    fn conversationJson(self: *Server, alloc: std.mem.Allocator, entry: *SessionEntry) ![]u8 {
        _ = self;
        const conv = &entry.conv;
        return std.json.Stringify.valueAlloc(alloc, .{
            .id = conv.session.id,
            .language = conv.session.language,
            .voice = conv.session.voice,
            .turns = conv.session.history.items,
        }, .{});
    }

    fn handleConversationAsk(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, id: []const u8) !void {
        const entry = self.sessions.get(id) orelse
            return self.respondError(alloc, req, .session_not_found, "no conversation with that id");
        const body = try self.readJsonBody(alloc, req) orelse return self.respondError(alloc, req, .bad_request, "missing or empty JSON body");
        var parsed = oneapi.parseJsonBody(oneapi.AskRequest, alloc, body) orelse
            return self.respondError(alloc, req, .bad_request, "body is not a valid ask request ({\"text\": \"...\"})");
        defer parsed.deinit();
        const text = parsed.value.text orelse
            return self.respondError(alloc, req, .bad_request, "ask needs a \"text\" field");
        var result = entry.conv.processText(text) catch |err|
            return self.respondError(alloc, req, .internal, @errorName(err));
        defer result.deinit(self.alloc);
        return self.json(alloc, req, .ok, .{
            .id = id,
            .transcript = result.transcript,
            .reply = result.reply,
            .asr = @tagName(result.asr),
            .brain = @tagName(result.brain),
            .tts = @tagName(result.tts),
            .pulse = @tagName(result.pulse),
            .pulse_note = result.pulse_note,
            .pulse_context = result.pulse_context,
            .barged_in = result.barged_in,
            .turns = entry.conv.session.turnCount(),
            .partial_reply = result.partial_reply,
            .interrupt_text = result.interrupt_text,
        });
    }

    fn handleConversationDelete(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, id: []const u8) !void {
        const kv = self.sessions.fetchRemove(id) orelse
            return self.respondError(alloc, req, .session_not_found, "no conversation with that id");
        // Remove from the eviction order too.
        for (self.session_order.items, 0..) |oid, i| {
            if (std.mem.eql(u8, oid, id)) {
                _ = self.session_order.orderedRemove(i);
                break;
            }
        }
        kv.value.deinit(self.alloc);
        self.alloc.destroy(kv.value);
        return self.respondJson(req, .ok, "{\"deleted\":true}");
    }

    fn handleModelInstall(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        if (self.eng == null)
            return self.respondError(alloc, req, .engine_unavailable, "no engine configured — start the server with a config file");
        const eng = &self.eng.?;
        const body = try self.readJsonBody(alloc, req) orelse return self.respondError(alloc, req, .bad_request, "missing or empty JSON body");
        var parsed = oneapi.parseJsonBody(oneapi.ModelInstallRequest, alloc, body) orelse
            return self.respondError(alloc, req, .bad_request, "body is not a valid install request ({\"path\": \"...\", \"name\": \"...\", \"kind\": \"stt|tts|vad\"})");
        defer parsed.deinit();
        const src_path = parsed.value.path orelse
            return self.respondError(alloc, req, .bad_request, "install needs a \"path\" field (local file — the engine never downloads weights)");
        const name = parsed.value.name orelse std.Io.Dir.path.basename(src_path);
        const kind_name = parsed.value.kind orelse "stt";
        const kind = config.ModelKind.fromName(kind_name) orelse
            return self.respondError(alloc, req, .bad_request, "kind must be one of stt, tts, vad");
        const rec = models.installModel(alloc, self.io, &eng.registry, src_path, name, kind, self.opts.models_dir) catch |err| switch (err) {
            error.InvalidExtension => return self.respondError(alloc, req, .bad_request, "model file must end .gguf or .onnx"),
            error.ModelKindMismatch => return self.respondError(alloc, req, .bad_request, "kind does not match the file extension (.onnx is vad only, .gguf is stt/tts)"),
            error.ModelLoaded => return self.respondError(alloc, req, .model_loaded, "a loaded model with that name already exists"),
            error.RegistryFull => return self.respondError(alloc, req, .registry_full, "model registry is full"),
            error.FileNotFound => return self.respondError(alloc, req, .model_not_found, "no such file at the given path"),
            else => return self.respondError(alloc, req, .internal, @errorName(err)),
        };
        const body_out = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"kind\":\"{s}\",\"file\":\"{s}\",\"size_bytes\":{d},\"loaded\":false}}", .{
            try oneapi.jsonEscape(alloc, rec.name),
            @tagName(rec.kind),
            try oneapi.jsonEscape(alloc, rec.path),
            rec.size_bytes,
        });
        return self.respondJson(req, .created, body_out);
    }

    fn handleModelRemove(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, name: []const u8) !void {
        if (self.eng == null)
            return self.respondError(alloc, req, .engine_unavailable, "no engine configured — start the server with a config file");
        const eng = &self.eng.?;
        models.removeModel(alloc, self.io, &eng.registry, name, self.opts.models_dir) catch |err| switch (err) {
            error.ModelNotFound => return self.respondError(alloc, req, .model_not_found, "no model with that name"),
            error.ModelLoaded => return self.respondError(alloc, req, .model_loaded, "refusing to remove a loaded model — unload it via the runtime first"),
            else => return self.respondError(alloc, req, .internal, @errorName(err)),
        };
        return self.respondJson(req, .ok, "{\"deleted\":true}");
    }

    /// Load the ASR model + session on first use. The failure is
    /// sticky: a model that cannot load will not load on retry, so
    /// the error is recorded once and returned as 503 afterwards.
    fn ensureAsr(self: *Server) !*runtime.Session {
        if (self.asr) |*s| return s;
        if (self.asr_failed) return error.AsrUnavailable;
        if (self.eng == null) {
            self.asr_failed = true;
            self.asr_error = "no engine configured";
            return error.AsrUnavailable;
        }
        const eng = &self.eng.?;
        eng.loadModelsForTask(.asr) catch |err| {
            self.asr_failed = true;
            self.asr_error = @errorName(err);
            return error.AsrUnavailable;
        };
        const model = pickAsrModel(&eng.cfg) orelse {
            self.asr_failed = true;
            self.asr_error = "no asr model in config";
            return error.AsrUnavailable;
        };
        const session = eng.createSession(model.name, .asr, .offline) catch |err| {
            self.asr_failed = true;
            self.asr_error = @errorName(err);
            return error.AsrUnavailable;
        };
        self.asr = session;
        return &self.asr.?;
    }

    fn handleInfer(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, raw_target: []const u8) !void {
        const task = queryValue(raw_target, "task") orelse "asr";
        if (std.mem.eql(u8, task, "vad")) return self.handleInferVad(alloc, req);
        if (std.mem.eql(u8, task, "tts")) return self.handleInferTts(alloc, req, raw_target);
        if (!std.mem.eql(u8, task, "asr")) {
            return self.respondError(alloc, req, .bad_request, "task must be one of asr, tts, vad");
        }
        if (self.eng == null)
            return self.respondError(alloc, req, .engine_unavailable, "no engine configured — start the server with a config file");
        const body = self.readBody(alloc, req, self.opts.max_body_bytes) catch |err| switch (err) {
            error.TooLarge => return self.respondError(alloc, req, .too_large, "WAV body over the 8 MiB cap"),
            error.BadExpectation => return self.respondError(alloc, req, .bad_request, "unsupported Expect header (only 100-continue)"),
            else => return self.respondError(alloc, req, .internal, @errorName(err)),
        } orelse return self.respondError(alloc, req, .bad_request, "infer needs a WAV body");
        var wav = audio.parseWav(alloc, body) catch
            return self.respondError(alloc, req, .bad_request, "body is not a valid WAV file");
        defer wav.deinit(alloc);
        const lang = queryValue(raw_target, "language") orelse "en";
        const started_ms = models.nowMs(self.io);
        const asr = self.ensureAsr() catch {
            const msg = try std.fmt.allocPrint(alloc, "ASR unavailable: {s}", .{self.asr_error});
            return self.respondError(alloc, req, .asr_unavailable, msg);
        };
        const request = runtime.Request{
            .task = .asr,
            .mode = .offline,
            .audio = wav.samples,
            .sample_rate = wav.sample_rate,
            .channels = wav.channels,
            .language = lang,
        };
        var resp = asr.run(self.io, alloc, request) catch |err|
            return self.respondError(alloc, req, .internal, @errorName(err));
        defer resp.deinit();
        const text = resp.text() catch |err|
            return self.respondError(alloc, req, .internal, @errorName(err));
        const latency_ms: f64 = @floatFromInt(models.nowMs(self.io) - started_ms);
        self.metrics.recordAsrLatency(latency_ms);
        return self.json(alloc, req, .ok, .{
            .task = "asr",
            .model = asr.family(),
            .text = text.text,
            .language = text.language,
            .latency_ms = latency_ms,
        });
    }

    fn handleInferVad(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const body = self.readBody(alloc, req, self.opts.max_body_bytes) catch |err| switch (err) {
            error.TooLarge => return self.respondError(alloc, req, .too_large, "WAV body over the 8 MiB cap"),
            error.BadExpectation => return self.respondError(alloc, req, .bad_request, "unsupported Expect header (only 100-continue)"),
            else => return self.respondError(alloc, req, .internal, @errorName(err)),
        } orelse return self.respondError(alloc, req, .bad_request, "infer needs a WAV body");
        var wav = audio.parseWav(alloc, body) catch
            return self.respondError(alloc, req, .bad_request, "body is not a valid WAV file");
        defer wav.deinit(alloc);
        // Energy VAD (no model weights): feed in 20 ms frames and
        // turn start/end activity into segments.
        var detector = vad.EnergyVad.init(wav.sample_rate);
        var segments = std.ArrayList(VadSegmentJson).empty;
        const frame: usize = @max(1, wav.sample_rate / 50);
        var i: usize = 0;
        var open: ?i64 = null;
        while (i < wav.samples.len) : (i += frame) {
            const end = @min(i + frame, wav.samples.len);
            if (detector.feed(wav.samples[i..end])) |act| {
                switch (act.kind) {
                    .speech_start => open = act.sample,
                    .speech_end => {
                        if (open) |start| {
                            try segments.append(alloc, .{
                                .start_s = @as(f64, @floatFromInt(start)) / @as(f64, @floatFromInt(wav.sample_rate)),
                                .end_s = @as(f64, @floatFromInt(act.sample)) / @as(f64, @floatFromInt(wav.sample_rate)),
                            });
                            open = null;
                        }
                    },
                    .speech_segment => {},
                }
            }
        }
        if (open) |start| {
            try segments.append(alloc, .{
                .start_s = @as(f64, @floatFromInt(start)) / @as(f64, @floatFromInt(wav.sample_rate)),
                .end_s = wav.durationSeconds(),
            });
        }
        return self.json(alloc, req, .ok, .{ .task = "vad", .source = "energy", .segments = segments.items });
    }

    fn handleInferTts(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request, raw_target: []const u8) !void {
        if (self.eng == null)
            return self.respondError(alloc, req, .engine_unavailable, "no engine configured — start the server with a config file");
        const eng = &self.eng.?;
        var text: ?[]const u8 = queryValue(raw_target, "text");
        if (text == null) {
            if (try self.readJsonBody(alloc, req)) |body| {
                if (oneapi.parseJsonBody(oneapi.AskRequest, alloc, body)) |parsed| {
                    defer parsed.deinit();
                    text = parsed.value.text;
                }
            }
        }
        const speak = text orelse
            return self.respondError(alloc, req, .bad_request, "tts needs text (JSON {\"text\": \"...\"} or ?text=...)");
        const lang = queryValue(raw_target, "language") orelse "en";
        const tts_model = pickModel(&eng.cfg, null, .tts) orelse
            return self.respondError(alloc, req, .tts_unavailable, "no tts model configured");
        const size = models.fileSize(self.io, tts_model.file) catch 0;
        switch (oneapi.FitCheck.check(alloc, self.io, size)) {
            .too_big => |free| {
                const msg = try std.fmt.allocPrint(alloc, "tts model {s} is {d} MB but only {d} MB is free — this machine cannot load it", .{
                    tts_model.name, size >> 20, free >> 20,
                });
                return self.respondError(alloc, req, .tts_unavailable, msg);
            },
            .unknown => {},
            .fits => {},
        }
        eng.loadModelsForTask(.tts) catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "cannot load tts model {s} ({t})", .{ tts_model.name, err });
            return self.respondError(alloc, req, .tts_unavailable, msg);
        };
        var tts_session = eng.createSession(tts_model.name, .tts, .offline) catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "cannot create tts session ({t})", .{err});
            return self.respondError(alloc, req, .tts_unavailable, msg);
        };
        defer tts_session.deinit(alloc);
        var ref_wav = runtime.loadReferenceWav(alloc, self.io, tts_model.reference_wav);
        defer if (ref_wav) |*w| w.deinit(alloc);
        const request = runtime.Request{
            .task = .tts,
            .mode = .offline,
            .text = speak,
            .language = lang,
            .voice = tts_model.voice,
            .reference_audio = if (ref_wav) |w| w.samples else null,
            .reference_rate = if (ref_wav) |w| w.sample_rate else 24000,
            .reference_channels = if (ref_wav) |w| w.channels else 1,
            .reference_text = tts_model.reference_text,
        };
        var resp = tts_session.run(self.io, alloc, request) catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "tts inference failed ({t})", .{err});
            return self.respondError(alloc, req, .tts_unavailable, msg);
        };
        defer resp.deinit();
        const a = resp.audio() catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "tts produced no audio ({t})", .{err});
            return self.respondError(alloc, req, .tts_unavailable, msg);
        };
        const wav_bytes = try audio.writeWav(alloc, a.samples, a.sample_rate, a.channels, .pcm16);
        try req.respond(wav_bytes, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "audio/wav" }},
        });
    }

    fn handleMetrics(self: *Server, alloc: std.mem.Allocator, req: *std.http.Server.Request) !void {
        const now_ms = models.nowMs(self.io);
        var lat_buf: [64]f64 = undefined;
        const pct = self.metrics.asrPercentiles(&lat_buf);
        var routes = std.ArrayList(RouteCountJson).empty;
        var it = self.metrics.counts.iterator();
        while (it.next()) |kv| {
            try routes.append(alloc, .{ .route = kv.key_ptr.*, .count = kv.value_ptr.* });
        }
        return self.json(alloc, req, .ok, .{
            .uptime_ms = self.metrics.uptimeMs(now_ms),
            .total_requests = self.metrics.total_requests,
            .sessions = self.sessions.count(),
            .asr = .{
                .count = self.metrics.asr_latency_count,
                .p50_ms = if (pct) |p| p.p50 else null,
                .p95_ms = if (pct) |p| p.p95 else null,
            },
            .last_error = self.metrics.last_error,
            .routes = routes.items,
        });
    }

    fn respondWebUi(self: *Server, req: *std.http.Server.Request) !void {
        _ = self;
        try req.respond(web_ui_html, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }
};

/// First config model matching a task (same rule as the CLI).
fn pickModel(cfg: *const config.Config, wanted: ?[]const u8, task: runtime.TaskKind) ?*const config.ModelEntry {
    if (wanted) |name| return cfg.findModel(name);
    for (cfg.models) |*m| {
        const kind_matches = switch (task) {
            .asr => m.kind == .stt,
            .tts => m.kind == .tts,
            .vad => m.kind == .vad,
        };
        if (kind_matches) return m;
    }
    return null;
}

fn pickAsrModel(cfg: *const config.Config) ?*const config.ModelEntry {
    return pickModel(cfg, null, .asr);
}

const web_ui_html =
    \\<!DOCTYPE html>
    \\<html lang="en"><head><meta charset="utf-8"><title>SANDO Audio — Developer Console</title>
    \\<style>body{font-family:system-ui,sans-serif;max-width:720px;margin:2em auto;padding:0 1em}input,textarea{width:100%;padding:.4em;margin:.3em 0}button{padding:.5em 1em}pre{background:#111;color:#eee;padding:1em;overflow:auto}</style>
    \\</head><body>
    \\<h1>SANDO Audio — Developer Console</h1>
    \\<p>OneAPI developer console (Phase 5). The server is a local dev server, not production infrastructure.</p>
    \\<label>API key (only needed when SANDO_API_KEY is set): <input id="key" type="password" placeholder="Bearer key"></label>
    \\<h2>Health</h2><button onclick="call('/v1/health')">Check health</button>
    \\<h2>Identify language</h2><input id="text" value="They fini fool we pekin them."><button onclick="post('/v1/language/identify',{text:val('text')})">Identify</button>
    \\<h2>Conversation</h2><button onclick="newConv()">New conversation</button>
    \\<input id="ask" placeholder="Say something to Sando…"><button onclick="ask()">Ask</button>
    \\<h2>Models</h2><button onclick="call('/v1/models')">List models</button>
    \\<h2>Metrics</h2><button onclick="call('/v1/metrics')">Show metrics</button>
    \\<pre id="out">Ready.</pre>
    \\<script>
    \\let convId=null;
    \\function val(id){return document.getElementById(id).value;}
    \\function headers(){const h={'Content-Type':'application/json'};const k=val('key');if(k)h['Authorization']='Bearer '+k;return h;}
    \\async function show(r){document.getElementById('out').textContent=await r.text();}
    \\async function call(p){show(await fetch(p,{headers:headers()}));}
    \\async function post(p,b){show(await fetch(p,{method:'POST',headers:headers(),body:JSON.stringify(b)}));}
    \\async function newConv(){const r=await fetch('/v1/conversation',{method:'POST',headers:headers(),body:JSON.stringify({language:'en'})});const j=await r.json();convId=j.id;show({ok:true,id:convId});}
    \\async function ask(){if(!convId){alert('Create a conversation first.');return;}post('/v1/conversation/'+convId+'/ask',{text:val('ask')});}
    \\</script></body></html>
;

test "routePattern collapses ids for metrics" {
    try std.testing.expectEqualStrings("GET /v1/health", Server.routePattern(.GET, "/v1/health"));
    try std.testing.expectEqualStrings("POST /v1/conversation/:id/ask", Server.routePattern(.POST, "/v1/conversation/abcdef0123456789/ask"));
    try std.testing.expectEqualStrings("GET /v1/conversation/:id", Server.routePattern(.GET, "/v1/conversation/abcdef0123456789"));
    try std.testing.expectEqualStrings("DELETE /v1/models/:name", Server.routePattern(.DELETE, "/v1/models/moonshine-small"));
    try std.testing.expectEqualStrings("GET /", Server.routePattern(.GET, "/"));
}

test "splitQuery and queryValue" {
    try std.testing.expectEqualStrings("/v1/infer", Server.splitQuery("/v1/infer?task=asr&language=kq"));
    try std.testing.expectEqualStrings("/v1/health", Server.splitQuery("/v1/health"));
    try std.testing.expectEqualStrings("asr", Server.queryValue("/v1/infer?task=asr&language=kq", "task").?);
    try std.testing.expectEqualStrings("kq", Server.queryValue("/v1/infer?task=asr&language=kq", "language").?);
    try std.testing.expect(Server.queryValue("/v1/infer?task=asr", "language") == null);
    try std.testing.expect(Server.queryValue("/v1/health", "task") == null);
}

/// Raw HTTP client for the integration test: one request, read to
/// EOF (the server closes every connection), split status + body.
const TestResponse = struct {
    status: u16,
    body: []const u8,
};

fn testRequest(alloc: std.mem.Allocator, io: std.Io, port: u16, request: []const u8) !TestResponse {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var rbuf: [8192]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const raw = try reader.interface.readAllocShort(alloc, 1 << 20);
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    const head = raw[0..head_end];
    const first_line_end = std.mem.indexOfScalar(u8, head, '\r') orelse return error.BadResponse;
    const first_line = head[0..first_line_end];
    // "HTTP/1.1 200 OK"
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next(); // HTTP/1.1
    const code_str = parts.next() orelse return error.BadResponse;
    const status = try std.fmt.parseInt(u16, code_str, 10);
    const body = try alloc.dupe(u8, raw[head_end + 4 ..]);
    alloc.free(raw);
    return .{ .status = status, .body = body };
}

fn testRequestRetry(alloc: std.mem.Allocator, io: std.Io, port: u16, request: []const u8) !TestResponse {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        return testRequest(alloc, io, port, request) catch |err| {
            if (err == error.ConnectionRefused) continue;
            return err;
        };
    }
    return error.ConnectionRefused;
}

fn runServerThread(s: *Server) void {
    s.run();
}

test "integration: live loopback server, no engine, no key" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var server = try Server.init(alloc, io, .{ .host = "127.0.0.1", .port = 0 }, null, null);
    defer server.deinit();
    const port = server.boundPort();
    try std.testing.expect(port != 0);
    const thread = try std.Thread.spawn(.{}, runServerThread, .{&server});
    defer thread.join();
    defer server.shutdown();

    // WebUI is public and serves HTML.
    {
        const r = try testRequestRetry(alloc, io, port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "Developer Console") != null);
    }
    // Health + version.
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"status\":\"ok\"") != null);
    }
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/version HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"version\":\"0.5.0\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"audio_cpp_linked\":false") != null);
    }
    // Languages: all 11, Koloqua partial.
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/languages HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"kq\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"dnj\"") != null);
    }
    // Identify (marker-only, no dataset loaded): Koloqua markers win.
    {
        const payload = "{\"text\":\"They fini fool we pekin them.\"}";
        const req = try std.fmt.allocPrint(alloc, "POST /v1/language/identify HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ payload.len, payload });
        defer alloc.free(req);
        const r = try testRequestRetry(alloc, io, port, req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"language\":\"kq\"") != null);
    }
    // Identify with no text field -> 400.
    {
        const payload = "{}";
        const req = try std.fmt.allocPrint(alloc, "POST /v1/language/identify HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ payload.len, payload });
        defer alloc.free(req);
        const r = try testRequestRetry(alloc, io, port, req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 400), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"bad_request\"") != null);
    }
    // Conversation lifecycle: create -> ask -> get -> list -> delete -> 404.
    var conv_id: []u8 = undefined;
    {
        const payload = "{\"language\":\"en\"}";
        const req = try std.fmt.allocPrint(alloc, "POST /v1/conversation HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ payload.len, payload });
        defer alloc.free(req);
        const r = try testRequestRetry(alloc, io, port, req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 201), r.status);
        // Pull the id out of {"id":"...","language":"en",...}.
        const id_start = std.mem.indexOf(u8, r.body, "\"id\":\"").? + 6;
        const id_end = std.mem.indexOfScalarPos(u8, r.body, id_start, '"').?;
        conv_id = try alloc.dupe(u8, r.body[id_start..id_end]);
    }
    defer alloc.free(conv_id);
    {
        const payload = "{\"text\":\"hello\"}";
        const req = try std.fmt.allocPrint(alloc, "POST /v1/conversation/{s}/ask HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ conv_id, payload.len, payload });
        defer alloc.free(req);
        const r = try testRequestRetry(alloc, io, port, req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "Good to hear you") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"tts\":\"unavailable\"") != null);
    }
    {
        const req = try std.fmt.allocPrint(alloc, "GET /v1/conversation/{s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{conv_id});
        defer alloc.free(req);
        const r = try testRequestRetry(alloc, io, port, req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"role\":\"user\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"role\":\"assistant\"") != null);
    }
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/conversations HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, conv_id) != null);
    }
    {
        const req = try std.fmt.allocPrint(alloc, "DELETE /v1/conversation/{s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{conv_id});
        defer alloc.free(req);
        const r = try testRequestRetry(alloc, io, port, req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
    {
        const req = try std.fmt.allocPrint(alloc, "GET /v1/conversation/{s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{conv_id});
        defer alloc.free(req);
        const r = try testRequestRetry(alloc, io, port, req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 404), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"session_not_found\"") != null);
    }
    // Infer without an engine -> 503 engine_unavailable.
    {
        const r = try testRequestRetry(alloc, io, port, "POST /v1/infer?task=asr HTTP/1.1\r\nHost: x\r\nContent-Type: audio/wav\r\nContent-Length: 4\r\nConnection: close\r\n\r\nRIFF");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 503), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"engine_unavailable\"") != null);
    }
    // Unknown route -> 404.
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 404), r.status);
    }
    // Metrics: requests were counted.
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"total_requests\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "GET /v1/health") != null);
    }
}

test "integration: auth enforced when a key is configured" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var server = try Server.init(alloc, io, .{ .host = "127.0.0.1", .port = 0, .api_key = "test-key-123" }, null, null);
    defer server.deinit();
    const port = server.boundPort();
    const thread = try std.Thread.spawn(.{}, runServerThread, .{&server});
    defer thread.join();
    defer server.shutdown();

    // No key -> 401.
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 401), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"unauthorized\"") != null);
    }
    // Wrong key -> 401.
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/health HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer nope\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 401), r.status);
    }
    // Right key -> 200.
    {
        const r = try testRequestRetry(alloc, io, port, "GET /v1/health HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer test-key-123\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
    // The WebUI itself stays public (it has its own key box).
    {
        const r = try testRequestRetry(alloc, io, port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
}

test "sessions evict the oldest at the cap" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var server = try Server.init(alloc, io, .{ .host = "127.0.0.1", .port = 0, .max_sessions = 2 }, null, null);
    defer server.deinit();
    const port = server.boundPort();
    const thread = try std.Thread.spawn(.{}, runServerThread, .{&server});
    defer thread.join();
    defer server.shutdown();

    const create_req = "POST /v1/conversation HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 17\r\nConnection: close\r\n\r\n{\"language\":\"en\"}";
    var ids: [3][]const u8 = undefined;
    for (0..3) |i| {
        const r = try testRequestRetry(alloc, io, port, create_req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 201), r.status);
        const id_start = std.mem.indexOf(u8, r.body, "\"id\":\"").? + 6;
        const id_end = std.mem.indexOfScalarPos(u8, r.body, id_start, '"').?;
        ids[i] = try alloc.dupe(u8, r.body[id_start..id_end]);
    }
    defer for (ids) |id| alloc.free(id);
    // The first session was evicted when the third was created.
    const get_first = try std.fmt.allocPrint(alloc, "GET /v1/conversation/{s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{ids[0]});
    defer alloc.free(get_first);
    const r1 = try testRequestRetry(alloc, io, port, get_first);
    defer alloc.free(r1.body);
    try std.testing.expectEqual(@as(u16, 404), r1.status);
    // The second and third are still alive.
    for (ids[1..]) |id| {
        const req = try std.fmt.allocPrint(alloc, "GET /v1/conversation/{s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{id});
        defer alloc.free(req);
        const r = try testRequestRetry(alloc, io, port, req);
        defer alloc.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
}
