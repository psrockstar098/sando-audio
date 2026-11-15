//! Plugin system: loadable audio processing plugins (.so).
//!
//! A plugin is a shared library exporting one symbol, `sando_plugin`,
//! pointing at a PluginDescriptor — a plain C struct with an API version
//! the loader validates before calling anything. Plugins never get
//! engine internals: they receive a sample buffer and a sample rate, and
//! process in place.

const std = @import("std");

pub const plugin_api_version: u32 = 1;
pub const plugin_symbol_name: [:0]const u8 = "sando_plugin";

pub const PluginKind = enum {
    vad,
    stt,
    tts,
    effect,
    other,

    pub fn fromName(s: []const u8) ?PluginKind {
        if (std.mem.eql(u8, s, "vad")) return .vad;
        if (std.mem.eql(u8, s, "stt")) return .stt;
        if (std.mem.eql(u8, s, "tts")) return .tts;
        if (std.mem.eql(u8, s, "effect")) return .effect;
        if (std.mem.eql(u8, s, "other")) return .other;
        return null;
    }
};

/// The C ABI a plugin exports. `name`, `version` and `kind` are static
/// strings owned by the plugin library. `kind` is one of "vad", "stt",
/// "tts", "effect", "other".
pub const PluginDescriptor = extern struct {
    api_version: u32,
    name: [*:0]const u8,
    version: [*:0]const u8,
    kind: [*:0]const u8,
    /// Optional. Called once at load; return 0 on success.
    init: ?*const fn () callconv(.c) c_int = null,
    /// Optional. Called once at unload.
    deinit: ?*const fn () callconv(.c) void = null,
    /// Optional. Process interleaved float PCM in place. Returns 0 on
    /// success. `frames` is per channel.
    process_f32: ?*const fn (
        samples: [*]f32,
        frames: usize,
        sample_rate: c_uint,
        channels: c_uint,
    ) callconv(.c) c_int = null,
};

pub const PluginError = error{
    FileNotFound,
    NotALibrary,
    MissingSymbol,
    UnsupportedApiVersion,
    UnknownKind,
    InitFailed,
    ProcessFailed,
    AlreadyLoaded,
    NotLoaded,
    ManifestInvalid,
    ManifestMismatch,
    OutOfMemory,
};

/// A plugin manifest (`manifest.toml` next to the .so), the
/// model-hub-style registry format:
///
///   [plugin]
///   name = "noop"
///   version = "0.1.0"
///   kind = "effect"
///   file = "libsando-plugin-noop.so"
///   description = "Passthrough plugin proving the loader works."
///
/// All strings are owned; free with deinit().
pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8,
    kind: []const u8,
    file: []const u8,
    description: []const u8 = "",

    pub fn deinit(self: *PluginManifest, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.kind);
        alloc.free(self.file);
        alloc.free(self.description);
        self.* = undefined;
    }
};

/// Parse a manifest file. Strict: the `[plugin]` section is required,
/// name/version/kind/file are required, description is optional, and
/// unknown keys are an error.
pub fn readManifest(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !PluginManifest {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch
        return error.FileNotFound;
    defer alloc.free(text);

    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var description: []const u8 = "";
    var seen_section = false;
    // Frees partial allocations on ANY error return below (the loop
    // returns directly, so this must be armed before it).
    errdefer {
        if (name) |n| alloc.free(n);
        if (version) |v| alloc.free(v);
        if (kind) |k| alloc.free(k);
        if (file) |f| alloc.free(f);
        if (description.len != 0) alloc.free(description);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripManifestComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "[")) {
            if (!std.mem.eql(u8, trimmed, "[plugin]")) return error.ManifestInvalid;
            seen_section = true;
            continue;
        }
        if (!seen_section) return error.ManifestInvalid;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.ManifestInvalid;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const raw_value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') {
            return error.ManifestInvalid;
        }
        const value = raw_value[1 .. raw_value.len - 1];
        if (std.mem.eql(u8, key, "name")) {
            if (name != null) return error.ManifestInvalid;
            name = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "version")) {
            if (version != null) return error.ManifestInvalid;
            version = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "kind")) {
            if (kind != null) return error.ManifestInvalid;
            kind = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "file")) {
            if (file != null) return error.ManifestInvalid;
            file = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "description")) {
            if (description.len != 0) return error.ManifestInvalid;
            description = try alloc.dupe(u8, value);
        } else {
            return error.ManifestInvalid;
        }
    }
    if (!seen_section or name == null or version == null or kind == null or file == null) {
        return error.ManifestInvalid;
    }
    return .{
        .name = name.?,
        .version = version.?,
        .kind = kind.?,
        .file = file.?,
        .description = description,
    };
}

fn stripManifestComment(line: []const u8) []const u8 {
    var in_quotes = false;
    for (line, 0..) |c, i| {
        if (c == '"' and (i == 0 or line[i - 1] != '\\')) in_quotes = !in_quotes;
        if (c == '#' and !in_quotes) return line[0..i];
    }
    return line;
}

/// Resolve a manifest's `file` entry: absolute values are used
/// as-is, relative values resolve against the manifest's directory.
fn resolveManifestFile(alloc: std.mem.Allocator, manifest_path: []const u8, file: []const u8) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(file)) return alloc.dupe(u8, file);
    const slash = std.mem.lastIndexOfScalar(u8, manifest_path, '/') orelse {
        return alloc.dupe(u8, file);
    };
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ manifest_path[0..slash], file });
}

/// Validate a descriptor without loading anything. Returns the plugin
/// kind on success.
pub fn validateDescriptor(d: *const PluginDescriptor) PluginError!PluginKind {
    if (d.api_version != plugin_api_version) return error.UnsupportedApiVersion;
    const kind = std.mem.span(d.kind);
    if (std.mem.eql(u8, kind, "vad")) return .vad;
    if (std.mem.eql(u8, kind, "stt")) return .stt;
    if (std.mem.eql(u8, kind, "tts")) return .tts;
    if (std.mem.eql(u8, kind, "effect")) return .effect;
    if (std.mem.eql(u8, kind, "other")) return .other;
    return error.UnknownKind;
}

pub const LoadedPlugin = struct {
    lib: std.DynLib,
    descriptor: *const PluginDescriptor,
    kind: PluginKind,
    /// Borrowed from the descriptor (static in the plugin library).
    name: []const u8,
    /// Owned copy of the path it was loaded from.
    path: []const u8,
    /// The manifest it was loaded from, if any (owned by the manager
    /// arena — freed with the manager).
    manifest: ?PluginManifest = null,
};

/// Owns every loaded plugin library. Unloading calls the plugin's
/// deinit (when present) and closes the library.
pub const PluginManager = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    plugins: std.StringHashMap(*LoadedPlugin),

    pub fn init(alloc: std.mem.Allocator) PluginManager {
        return .{
            .alloc = alloc,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .plugins = std.StringHashMap(*LoadedPlugin).init(alloc),
        };
    }

    pub fn deinit(self: *PluginManager) void {
        var it = self.plugins.valueIterator();
        while (it.next()) |p| self.unloadOne(p.*);
        self.plugins.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const PluginManager) usize {
        return self.plugins.count();
    }

    pub fn lookup(self: *PluginManager, name: []const u8) ?*LoadedPlugin {
        return self.plugins.get(name);
    }

    /// Load a plugin from `path`. Validates the descriptor and runs the
    /// plugin's init before registering it.
    pub fn load(self: *PluginManager, path: []const u8) !*LoadedPlugin {
        var lib = std.DynLib.open(path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return error.NotALibrary,
        };
        errdefer lib.close();

        const descriptor = lib.lookup(*const PluginDescriptor, plugin_symbol_name) orelse
            return error.MissingSymbol;
        const kind = try validateDescriptor(descriptor);
        const name = std.mem.span(descriptor.name);
        if (self.plugins.contains(name)) return error.AlreadyLoaded;

        if (descriptor.init) |init_fn| {
            if (init_fn() != 0) return error.InitFailed;
        }

        const owned_path = try self.arena.allocator().dupe(u8, path);
        const plugin = try self.arena.allocator().create(LoadedPlugin);
        plugin.* = .{
            .lib = lib,
            .descriptor = descriptor,
            .kind = kind,
            .name = name,
            .path = owned_path,
            .manifest = null,
        };
        try self.plugins.put(name, plugin);
        return plugin;
    }

    /// Load a plugin via its manifest: read `manifest.toml`, resolve
    /// its `file` relative to the manifest's directory (absolute
    /// values used as-is), load the library, and cross-check the
    /// descriptor against the manifest (name, kind, version). On a
    /// mismatch the library is unloaded and ManifestMismatch is
    /// returned — the manifest is authoritative, not the .so.
    pub fn loadWithManifest(self: *PluginManager, io: std.Io, manifest_path: []const u8) !*LoadedPlugin {
        const arena_alloc = self.arena.allocator();
        var manifest = try readManifest(arena_alloc, io, manifest_path);
        errdefer manifest.deinit(arena_alloc);
        const lib_path = try resolveManifestFile(arena_alloc, manifest_path, manifest.file);
        defer arena_alloc.free(lib_path);
        const loaded = try self.load(lib_path);
        const descriptor_name = std.mem.span(loaded.descriptor.name);
        const descriptor_version = std.mem.span(loaded.descriptor.version);
        const manifest_kind = PluginKind.fromName(manifest.kind) orelse {
            self.unload(loaded.name) catch {};
            return error.ManifestMismatch;
        };
        if (!std.mem.eql(u8, descriptor_name, manifest.name) or
            !std.mem.eql(u8, descriptor_version, manifest.version) or
            loaded.kind != manifest_kind)
        {
            // Remove from the map AND close the library: unloadOne
            // alone would leave a closed lib in the map and double
            // -close it at manager teardown.
            self.unload(loaded.name) catch {};
            return error.ManifestMismatch;
        }
        loaded.manifest = manifest;
        return loaded;
    }

    /// Unload by name. Calls the plugin's deinit and closes the library.
    pub fn unload(self: *PluginManager, name: []const u8) PluginError!void {
        const plugin = self.plugins.fetchRemove(name) orelse return error.NotLoaded;
        self.unloadOne(plugin.value);
    }

    fn unloadOne(self: *PluginManager, plugin: *LoadedPlugin) void {
        _ = self;
        if (plugin.descriptor.deinit) |deinit_fn| deinit_fn();
        plugin.lib.close();
    }

    /// Run a plugin's process function over interleaved float PCM.
    pub fn process(
        self: *PluginManager,
        name: []const u8,
        samples: []f32,
        sample_rate: u32,
        channels: u8,
    ) PluginError!void {
        const plugin = self.plugins.get(name) orelse return error.NotLoaded;
        const process_fn = plugin.descriptor.process_f32 orelse return error.ProcessFailed;
        const frames = samples.len / @as(usize, channels);
        if (process_fn(samples.ptr, frames, sample_rate, channels) != 0) {
            return error.ProcessFailed;
        }
    }
};

test "validateDescriptor accepts known kinds, rejects the rest" {
    const good = PluginDescriptor{
        .api_version = 1,
        .name = "noop",
        .version = "0.1.0",
        .kind = "effect",
    };
    try std.testing.expect(try validateDescriptor(&good) == .effect);

    const bad_version = PluginDescriptor{
        .api_version = 99,
        .name = "noop",
        .version = "0.1.0",
        .kind = "effect",
    };
    try std.testing.expectError(error.UnsupportedApiVersion, validateDescriptor(&bad_version));

    const bad_kind = PluginDescriptor{
        .api_version = 1,
        .name = "noop",
        .version = "0.1.0",
        .kind = "telepathy",
    };
    try std.testing.expectError(error.UnknownKind, validateDescriptor(&bad_kind));
}

test "load fails honestly on a missing file" {
    const alloc = std.testing.allocator;
    var mgr = PluginManager.init(alloc);
    defer mgr.deinit();
    try std.testing.expectError(error.FileNotFound, mgr.load("plugins/does-not-exist.so"));
}

test "load rejects a library without the plugin symbol" {
    // The vendored audio.cpp library is a real .so with no sando_plugin
    // symbol — a good stand-in for a non-plugin library. Skipped when
    // the prebuilt is not vendored on this machine.
    const path = "third-party/audiocpp/lib/libaudiocpp.so.0";
    if (std.Io.Dir.cwd().access(std.testing.io, path, .{})) |_| {} else |_| return;
    const alloc = std.testing.allocator;
    var mgr = PluginManager.init(alloc);
    defer mgr.deinit();
    try std.testing.expectError(error.MissingSymbol, mgr.load(path));
}

test "process on an unloaded plugin fails honestly" {
    const alloc = std.testing.allocator;
    var mgr = PluginManager.init(alloc);
    defer mgr.deinit();
    var samples = [_]f32{ 0.0, 0.0 };
    try std.testing.expectError(error.NotLoaded, mgr.process("ghost", &samples, 24000, 1));
    try std.testing.expectError(error.NotLoaded, mgr.unload("ghost"));
}

test "load and run the noop sample plugin" {
    // The build installs the sample plugin to zig-out/lib before the
    // test binary runs. Skipped when it is not there (plain `zig test`).
    const path = "zig-out/lib/libsando-plugin-noop.so";
    if (std.Io.Dir.cwd().access(std.testing.io, path, .{})) |_| {} else |_| return;
    const alloc = std.testing.allocator;
    var mgr = PluginManager.init(alloc);
    defer mgr.deinit();
    const loaded = try mgr.load(path);
    try std.testing.expectEqualStrings("noop", loaded.name);
    try std.testing.expect(loaded.kind == .effect);
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(loaded.descriptor.version));
    var samples = [_]f32{ 0.5, -0.5, 0.25 };
    try mgr.process("noop", &samples, 24000, 1);
    // Passthrough: samples unchanged.
    try std.testing.expectEqual(@as(f32, 0.5), samples[0]);
    try std.testing.expectEqual(@as(f32, -0.5), samples[1]);
    try mgr.unload("noop");
    try std.testing.expectEqual(@as(usize, 0), mgr.count());
}

test "readManifest parses the example manifest" {
    const alloc = std.testing.allocator;
    var manifest = try readManifest(alloc, std.testing.io, "examples/plugins/noop/manifest.toml");
    defer manifest.deinit(alloc);
    try std.testing.expectEqualStrings("noop", manifest.name);
    try std.testing.expectEqualStrings("0.1.0", manifest.version);
    try std.testing.expectEqualStrings("effect", manifest.kind);
    try std.testing.expectEqualStrings("libsando-plugin-noop.so", manifest.file);
    try std.testing.expect(manifest.description.len > 0);
}

test "readManifest rejects malformed manifests" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Missing file field.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.toml", .data = "[plugin]\nname = \"x\"\nversion = \"1\"\nkind = \"effect\"\n" });
    const bad_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/bad.toml", .{tmp.sub_path});
    defer alloc.free(bad_path);
    try std.testing.expectError(error.ManifestInvalid, readManifest(alloc, io, bad_path));
    // Unknown key.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad2.toml", .data = "[plugin]\nname = \"x\"\nversion = \"1\"\nkind = \"effect\"\nfile = \"x.so\"\ntelepathy = \"yes\"\n" });
    const bad2_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/bad2.toml", .{tmp.sub_path});
    defer alloc.free(bad2_path);
    try std.testing.expectError(error.ManifestInvalid, readManifest(alloc, io, bad2_path));
    // Missing file on disk.
    try std.testing.expectError(error.FileNotFound, readManifest(alloc, io, ".zig-cache/tmp/does-not-exist.toml"));
}

test "loadWithManifest cross-checks the descriptor, rejects mismatch" {
    // Needs the built sample plugin. Skipped when it is not there.
    const so_path = "zig-out/lib/libsando-plugin-noop.so";
    if (std.Io.Dir.cwd().access(std.testing.io, so_path, .{})) |_| {} else |_| return;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_rel = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(tmp_rel);
    // Absolute .so path (the manifest lives in a tmp dir, the .so in zig-out).
    const abs_so = try std.fmt.allocPrint(alloc, "/home/hatch/workspace/sando-audio/{s}", .{so_path});
    defer alloc.free(abs_so);
    const good_text = try std.fmt.allocPrint(alloc, "[plugin]\nname = \"noop\"\nversion = \"0.1.0\"\nkind = \"effect\"\nfile = \"{s}\"\ndescription = \"test\"\n", .{abs_so});
    defer alloc.free(good_text);
    try tmp.dir.writeFile(io, .{ .sub_path = "good.toml", .data = good_text });
    const good_path = try std.fmt.allocPrint(alloc, "{s}/good.toml", .{tmp_rel});
    defer alloc.free(good_path);
    var mgr = PluginManager.init(alloc);
    defer mgr.deinit();
    const loaded = try mgr.loadWithManifest(io, good_path);
    try std.testing.expect(loaded.manifest != null);
    try std.testing.expectEqualStrings("noop", loaded.manifest.?.name);
    try mgr.unload("noop");

    // Wrong name in the manifest: the .so loads, then the mismatch
    // unloads it and fails.
    const bad_text = try std.fmt.allocPrint(alloc, "[plugin]\nname = \"impostor\"\nversion = \"0.1.0\"\nkind = \"effect\"\nfile = \"{s}\"\n", .{abs_so});
    defer alloc.free(bad_text);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.toml", .data = bad_text });
    const bad_path = try std.fmt.allocPrint(alloc, "{s}/bad.toml", .{tmp_rel});
    defer alloc.free(bad_path);
    try std.testing.expectError(error.ManifestMismatch, mgr.loadWithManifest(io, bad_path));
    try std.testing.expectEqual(@as(usize, 0), mgr.count());
}
