//! `doctor`: a system report that never fails hard. Every section
//! reports what it found or why it could not — a missing model file, an
//! unavailable backend, or an unlinked library is a line in the report,
//! not an error.

const std = @import("std");
const builtin = @import("builtin");
const hardware = @import("hardware.zig");
const audiocpp = @import("audiocpp.zig");
const config = @import("config.zig");
const engine = @import("engine.zig");
const audio = @import("audio.zig");

pub const DoctorReport = struct {
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu_model: []const u8,
    cpu_cores: usize,
    cpu_simd: []const u8,
    backends: []hardware.Backend,
    audiocpp_linked: bool,
    audiocpp_abi: u32,
    audiocpp_build: []const u8,
    audiocpp_tasks: usize,
    audiocpp_families: usize,
    config_present: bool,
    config_valid: bool,
    config_error: ?[]const u8,
    model_files: usize,
    live_audio: []const u8,

    pub fn deinit(self: *DoctorReport, alloc: std.mem.Allocator) void {
        alloc.free(self.backends);
        alloc.free(self.cpu_model);
        if (self.config_error) |e| alloc.free(e);
        self.* = undefined;
    }
};

/// Collect the report. Allocates; call `deinit` when done. Sections that
/// cannot be probed report empty/zero with a reason in the printed
/// output, never an error return (except OutOfMemory).
pub fn collect(alloc: std.mem.Allocator, io: std.Io) !DoctorReport {
    var cpu_model: []const u8 = try alloc.dupe(u8, "unknown");
    errdefer alloc.free(cpu_model);
    var cpu_cores: usize = 1;
    var cpu_simd: []const u8 = "unknown";
    var backends: []hardware.Backend = &.{};
    if (hardware.detectCpu(alloc, io)) |cpu| {
        alloc.free(cpu_model);
        cpu_model = cpu.model_name;
        cpu_cores = cpu.cores;
        cpu_simd = cpu.simdLevel();
        alloc.free(cpu.vendor);
        for (cpu.flags) |f| alloc.free(f);
        alloc.free(cpu.flags);
    } else |_| {}
    backends = hardware.detectBackends(alloc, io) catch &.{};

    var families: usize = 0;
    var tasks: usize = 0;
    if (audiocpp.has_link) {
        tasks = audiocpp.taskCount();
        if (audiocpp.Registry.create(alloc, null)) |*reg| {
            var r = reg.*;
            families = r.familyCount();
            r.deinit();
        } else |_| {}
    }

    var config_present = false;
    var config_valid = false;
    var config_error: ?[]const u8 = null;
    if (std.Io.Dir.cwd().access(io, engine.default_config_path, .{})) |_| {
        config_present = true;
        if (config.loadFromFile(alloc, io, engine.default_config_path)) |*c| {
            var owned = c.*;
            owned.deinit();
            config_valid = true;
        } else |err| {
            config_error = try alloc.dupe(u8, @errorName(err));
        }
    } else |_| {}

    var model_files: usize = 0;
    if (std.Io.Dir.cwd().openDir(io, "models", .{})) |*dir| {
        var d = dir.*;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            const name = entry.name;
            if (std.mem.endsWith(u8, name, ".gguf") or std.mem.endsWith(u8, name, ".onnx")) {
                model_files += 1;
            }
        }
    } else |_| {}

    return .{
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .cpu_model = cpu_model,
        .cpu_cores = cpu_cores,
        .cpu_simd = cpu_simd,
        .backends = backends,
        .audiocpp_linked = audiocpp.has_link,
        .audiocpp_abi = audiocpp.abiVersion(),
        .audiocpp_build = audiocpp.buildVersion(),
        .audiocpp_tasks = tasks,
        .audiocpp_families = families,
        .config_present = config_present,
        .config_valid = config_valid,
        .config_error = config_error,
        .model_files = model_files,
        .live_audio = audio.live_audio_status,
    };
}

/// Print the report to `writer`. Never fails on missing data.
pub fn print(writer: *std.Io.Writer, report: *const DoctorReport) !void {
    try writer.print("sando-audio doctor\n", .{});
    try writer.print("  zig {s} | {s}/{s}\n", .{ report.zig_version, report.os, report.arch });
    try writer.print("  cpu: {s} ({d} cores, simd {s})\n", .{ report.cpu_model, report.cpu_cores, report.cpu_simd });
    try writer.print("  backends:\n", .{});
    for (report.backends) |b| {
        if (b.available) {
            try writer.print("    {s}: available\n", .{b.kind.name()});
        } else {
            try writer.print("    {s}: unavailable ({s})\n", .{ b.kind.name(), b.reason });
        }
    }
    if (report.audiocpp_linked) {
        try writer.print("  audio.cpp: linked (abi 0x{x}, build {s}, {d} tasks, {d} families)\n", .{
            report.audiocpp_abi,
            report.audiocpp_build,
            report.audiocpp_tasks,
            report.audiocpp_families,
        });
    } else {
        try writer.print("  audio.cpp: NOT linked (null inference backend)\n", .{});
    }
    if (report.config_present) {
        if (report.config_valid) {
            try writer.print("  config: {s} (valid)\n", .{engine.default_config_path});
        } else {
            try writer.print("  config: {s} (INVALID: {s})\n", .{ engine.default_config_path, report.config_error orelse "unknown" });
        }
    } else {
        try writer.print("  config: {s} (missing — copy config/sando.example.toml)\n", .{engine.default_config_path});
    }
    try writer.print("  models: {d} model file(s) in models/\n", .{report.model_files});
    try writer.print("  live audio: {s}\n", .{report.live_audio});
    if (report.model_files == 0) {
        try writer.print("  next: place GGUF/ONNX weights in models/ and list them in {s}\n", .{engine.default_config_path});
    }
}

test "doctor collects on this machine" {
    const alloc = std.testing.allocator;
    var report = try collect(alloc, std.testing.io);
    defer report.deinit(alloc);
    try std.testing.expect(report.cpu_cores >= 1);
    try std.testing.expect(report.backends.len > 0);
    var cpu_seen = false;
    for (report.backends) |b| {
        if (b.kind == .cpu) {
            cpu_seen = true;
            try std.testing.expect(b.available);
        }
    }
    try std.testing.expect(cpu_seen);
    if (audiocpp.has_link) {
        try std.testing.expect(report.audiocpp_linked);
        try std.testing.expectEqual(@as(usize, 17), report.audiocpp_tasks);
        try std.testing.expect(report.audiocpp_families > 0);
    }
}
