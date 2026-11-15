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

pub const PluginKind = enum { vad, stt, tts, effect, other };

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
    OutOfMemory,
};

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
        };
        try self.plugins.put(name, plugin);
        return plugin;
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
