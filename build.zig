//! SANDO Audio — build script.
//!
//! Zig 0.17.1. Build with:
//!   zig build -j1 -Dcpu=baseline
//!   zig build -j1 -Dcpu=baseline -Daudiocpp-dir=third-party/audiocpp
//!
//! audio.cpp is OPTIONAL at build time. When `-Daudiocpp-dir` points at a
//! prebuilt audio.cpp directory (include/ + lib/ with libaudiocpp.so), the
//! engine links it and the live backend is available. When it is absent, the
//! engine still builds and runs with a null inference backend, and `doctor`
//! reports audio.cpp as unavailable — honestly, not as a silent stub.
//! The prebuilt under third-party/ is NOT committed (see .gitignore); the
//! version in use is recorded in STATUS.md.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve the audio.cpp prebuilt directory. Explicit option wins; else
    // fall back to the conventional vendored path when it exists.
    const opt_dir = b.option([]const u8, "audiocpp-dir", "Path to audio.cpp prebuilt dir (include/ + lib/)");
    var audiocpp_dir: ?[]const u8 = opt_dir;
    if (audiocpp_dir == null) {
        const default_dir = "third-party/audiocpp";
        if (std.Io.Dir.cwd().access(b.graph.io, default_dir, .{})) |_| {
            audiocpp_dir = default_dir;
        } else |_| {}
    }

    const options = b.addOptions();
    options.addOption(bool, "has_audiocpp", audiocpp_dir != null);
    options.addOption([]const u8, "audiocpp_dir", audiocpp_dir orelse "");

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", options);
    // The C API uses the C allocator; libc is always linked.
    lib_mod.link_libc = true;
    linkAudiocpp(b, lib_mod, audiocpp_dir);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sando",
        .root_module = lib_mod,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);
    exe_mod.addImport("sando", lib_mod);
    exe_mod.linkLibrary(lib);
    linkAudiocpp(b, exe_mod, audiocpp_dir);

    const exe = b.addExecutable(.{
        .name = "sando-audio",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);
    b.installArtifact(lib);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", options);
    linkAudiocpp(b, test_mod, audiocpp_dir);

    const lib_tests = b.addTest(.{ .root_module = test_mod });

    const run_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Link the audio.cpp prebuilt shared library when a directory is given.
/// Adds the include path, the library path, the link, and an absolute rpath
/// so the built binary finds libaudiocpp.so at runtime (its own RUNPATH of
/// $ORIGIN then resolves the bundled libggml*.so from the same directory).
fn linkAudiocpp(b: *std.Build, mod: *std.Build.Module, dir: ?[]const u8) void {
    const d = dir orelse return;
    const include_path = b.pathJoin(&.{ d, "include" });
    const lib_path = b.pathJoin(&.{ d, "lib" });
    mod.addIncludePath(.{ .cwd_relative = include_path });
    mod.addLibraryPath(.{ .cwd_relative = lib_path });
    mod.linkSystemLibrary("audiocpp", .{});
    mod.link_libc = true;
    // Absolute rpath so the binary runs without LD_LIBRARY_PATH.
    const abs = b.root.joinString(b.allocator, lib_path) catch return;
    mod.addRPath(.{ .cwd_relative = abs });
}
