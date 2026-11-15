//! Build the Zig SDK example.
//!
//!   cd examples/zig && zig build -j1 -Dcpu=baseline && ./zig-out/bin/zig-talk
//!
//! The example links the SANDO Audio library (src/root.zig) the same
//! way the repo's own test module does: same build_options, same
//! optional audio.cpp link. No model weights are needed — the example
//! only identifies a Koloqua sentence and holds a mock-brain
//! conversation, both of which run without any model.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opt_dir = b.option([]const u8, "audiocpp-dir", "Path to audio.cpp prebuilt dir (include/ + lib/)");
    var audiocpp_dir: ?[]const u8 = opt_dir;
    if (audiocpp_dir == null) {
        const default_dir = "../../third-party/audiocpp";
        if (std.Io.Dir.cwd().access(b.graph.io, default_dir, .{})) |_| {
            audiocpp_dir = default_dir;
        } else |_| {}
    }

    const options = b.addOptions();
    options.addOption(bool, "has_audiocpp", audiocpp_dir != null);
    options.addOption([]const u8, "audiocpp_dir", audiocpp_dir orelse "");

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", options);
    lib_mod.link_libc = true;
    if (audiocpp_dir) |dir| {
        lib_mod.addIncludePath(b.path(b.pathJoin(&.{ dir, "include" })));
        lib_mod.addLibraryPath(b.path(b.pathJoin(&.{ dir, "lib" })));
        lib_mod.linkSystemLibrary("audiocpp", .{});
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("sando", lib_mod);

    const exe = b.addExecutable(.{
        .name = "zig-talk",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
