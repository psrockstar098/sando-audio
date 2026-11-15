//! Hardware detection and backend selection.
//!
//! All detection is real, against this host: CPU info comes from
//! /proc/cpuinfo, GPU backends are probed by device nodes and dynamic
//! library presence. Nothing is hardcoded to "available" — on a host
//! without a GPU, every GPU backend reports unavailable with a reason.
//! Metal is macOS-only by construction; WebGPU is a browser/WASM target
//! and is never available to the native engine.

const std = @import("std");

/// The backends SANDO knows about, in selection priority order.
pub const BackendKind = enum {
    cuda,
    hip,
    vulkan,
    metal,
    sycl,
    webgpu,
    cpu,

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .cuda => "cuda",
            .hip => "hip",
            .vulkan => "vulkan",
            .metal => "metal",
            .sycl => "sycl",
            .webgpu => "webgpu",
            .cpu => "cpu",
        };
    }

    pub fn fromName(s: []const u8) ?BackendKind {
        const map = std.StaticStringMap(BackendKind).initComptime(.{
            .{ "cuda", .cuda },
            .{ "hip", .hip },
            .{ "vulkan", .vulkan },
            .{ "metal", .metal },
            .{ "sycl", .sycl },
            .{ "webgpu", .webgpu },
            .{ "cpu", .cpu },
        });
        return map.get(s);
    }
};

pub const Backend = struct {
    kind: BackendKind,
    available: bool,
    reason: []const u8,
};

pub const CpuInfo = struct {
    model_name: []const u8,
    vendor: []const u8,
    cores: usize,
    /// Raw feature flags from /proc/cpuinfo (e.g. "avx2", "avx512f").
    flags: []const []const u8,

    pub fn hasFlag(self: CpuInfo, flag: []const u8) bool {
        for (self.flags) |f| {
            if (std.mem.eql(u8, f, flag)) return true;
        }
        return false;
    }

    /// Short SIMD summary: the highest vector extension the host reports.
    pub fn simdLevel(self: CpuInfo) []const u8 {
        if (self.hasFlag("avx512f")) return "avx512";
        if (self.hasFlag("avx2")) return "avx2";
        if (self.hasFlag("avx")) return "avx";
        if (self.hasFlag("sse4_2")) return "sse4.2";
        if (self.hasFlag("sse2")) return "sse2";
        return "scalar";
    }
};

/// Read /proc/cpuinfo. Returns owned data in `alloc`.
pub fn detectCpu(alloc: std.mem.Allocator, io: std.Io) !CpuInfo {
    var file = std.Io.Dir.openFileAbsolute(io, "/proc/cpuinfo", .{}) catch return error.CpuInfoUnavailable;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const text = reader.interface.readAllocShort(alloc, 1 << 20) catch return error.CpuInfoUnavailable;
    defer alloc.free(text);

    var model_name: []const u8 = "unknown";
    var vendor: []const u8 = "unknown";
    var cores: usize = 0;
    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                model_name = std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        } else if (std.mem.startsWith(u8, line, "vendor_id")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                vendor = std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        } else if (std.mem.startsWith(u8, line, "processor")) {
            cores += 1;
        } else if (std.mem.startsWith(u8, line, "flags")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), ' ');
                while (it.next()) |flag| try flags.append(alloc, flag);
            }
        }
    }
    if (cores == 0) cores = std.Thread.getCpuCount() catch 1;

    // Flags parsed above point into `text`, which is freed below, so
    // duplicate them into owned memory before returning.
    const owned_flags = try alloc.alloc([]const u8, flags.items.len);
    for (flags.items, 0..) |f, i| {
        owned_flags[i] = try alloc.dupe(u8, f);
    }

    return .{
        .model_name = try alloc.dupe(u8, model_name),
        .vendor = try alloc.dupe(u8, vendor),
        .cores = cores,
        .flags = owned_flags,
    };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn libExists(name: []const u8) bool {
    var lib = std.DynLib.open(name) catch return false;
    lib.close();
    return true;
}

/// Probe every backend on this host. Returns owned data in `alloc`.
/// A GPU backend counts as available only when a device can actually
/// be used: CUDA/HIP need their device nodes, Vulkan needs a DRI
/// render node (the loader alone is NOT enough — this VM ships
/// libvulkan.so.1 with no GPU behind it, and audio.cpp session
/// creation on such a "vulkan" backend fails with Runtime; Phase 2
/// fix, found by the moonshine ASR smoke test).
pub fn detectBackends(alloc: std.mem.Allocator, io: std.Io) ![]Backend {
    const vulkan_device = fileExists(io, "/dev/dri/renderD128") or fileExists(io, "/dev/dri/card0");
    const vulkan_available = libExists("libvulkan.so.1") and vulkan_device;
    // Static table: the `available` flags below are computed live.
    const backends = [_]Backend{
        .{ .kind = .cuda, .available = fileExists(io, "/dev/nvidiactl") or fileExists(io, "/dev/nvidia0"), .reason = "no NVIDIA device node (/dev/nvidiactl)" },
        .{ .kind = .hip, .available = fileExists(io, "/dev/kfd"), .reason = "no AMD KFD device node (/dev/kfd)" },
        .{ .kind = .vulkan, .available = vulkan_available, .reason = "no Vulkan device node (/dev/dri/renderD128)" },
        .{ .kind = .metal, .available = false, .reason = "Metal is macOS-only" },
        .{ .kind = .sycl, .available = libExists("libsycl.so"), .reason = "libsycl.so not loadable" },
        .{ .kind = .webgpu, .available = false, .reason = "WebGPU is a browser/WASM target, not a native backend" },
        .{ .kind = .cpu, .available = true, .reason = "always available" },
    };
    const out = try alloc.dupe(Backend, &backends);
    return out;
}

/// Select a backend. `wanted` is "auto" or a backend name.
/// Returns the selected backend, or an error naming why the request
/// cannot be satisfied on this host.
pub fn selectBackend(backends: []const Backend, wanted: []const u8) !Backend {
    if (std.mem.eql(u8, wanted, "auto")) {
        // Priority order is the order of the table: first available wins.
        for (backends) |b| {
            if (b.available) return b;
        }
        return error.NoBackendAvailable;
    }
    const kind = BackendKind.fromName(wanted) orelse return error.UnknownBackend;
    for (backends) |b| {
        if (b.kind == kind) {
            if (!b.available) return error.BackendUnavailable;
            return b;
        }
    }
    return error.UnknownBackend;
}

test "cpu detection is real" {
    const alloc = std.testing.allocator;
    const cpu = try detectCpu(alloc, std.testing.io);
    defer {
        alloc.free(cpu.model_name);
        alloc.free(cpu.vendor);
        for (cpu.flags) |f| alloc.free(f);
        alloc.free(cpu.flags);
    }
    try std.testing.expect(cpu.cores >= 1);
    try std.testing.expect(cpu.model_name.len > 0);
    // This VM reports its flags; at minimum the list must be non-empty.
    try std.testing.expect(cpu.flags.len > 0);
    try std.testing.expect(cpu.simdLevel().len > 0);
}

test "backend detection reports cpu available" {
    const alloc = std.testing.allocator;
    const backends = try detectBackends(alloc, std.testing.io);
    defer alloc.free(backends);
    var cpu_seen = false;
    for (backends) |b| {
        if (b.kind == .cpu) {
            cpu_seen = true;
            try std.testing.expect(b.available);
        }
        if (b.kind == .metal) try std.testing.expect(!b.available);
        if (b.kind == .webgpu) try std.testing.expect(!b.available);
    }
    try std.testing.expect(cpu_seen);
}

test "vulkan availability needs a device node, not just the loader" {
    // Invariant, true on any host: vulkan is available exactly when
    // the loader loads AND a DRI device node exists. On this VM the
    // loader exists but /dev/dri does not, so vulkan must be
    // unavailable — otherwise auto-selection hands audio.cpp a
    // backend with no device behind it and session creation fails
    // with Runtime (moonshine ASR smoke, Phase 2).
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const backends = try detectBackends(alloc, io);
    defer alloc.free(backends);
    const dri = fileExists(io, "/dev/dri/renderD128") or fileExists(io, "/dev/dri/card0");
    for (backends) |b| {
        if (b.kind == .vulkan) {
            try std.testing.expectEqual(libExists("libvulkan.so.1") and dri, b.available);
            if (!dri) try std.testing.expect(!b.available);
        }
    }
}

test "selectBackend auto picks an available backend" {
    const alloc = std.testing.allocator;
    const backends = try detectBackends(alloc, std.testing.io);
    defer alloc.free(backends);
    const sel = try selectBackend(backends, "auto");
    try std.testing.expect(sel.available);
}

test "selectBackend rejects unknown and unavailable names" {
    const backends = [_]Backend{
        .{ .kind = .cpu, .available = true, .reason = "always available" },
        .{ .kind = .cuda, .available = false, .reason = "no device" },
    };
    try std.testing.expectError(error.UnknownBackend, selectBackend(&backends, "quantum"));
    try std.testing.expectError(error.BackendUnavailable, selectBackend(&backends, "cuda"));
    const sel = try selectBackend(&backends, "cpu");
    try std.testing.expect(sel.kind == .cpu);
}
