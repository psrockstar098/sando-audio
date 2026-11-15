//! SANDO Audio library root.
//!
//! Phase 1 modules. The engine is assembled in engine.zig; the CLI in
//! main.zig drives it. audio.cpp bindings live in audiocpp.zig and are
//! compiled against the prebuilt C ABI when linked (see build.zig).

pub const hardware = @import("hardware.zig");
pub const memory = @import("memory.zig");
pub const config = @import("config.zig");
pub const audiocpp = @import("audiocpp.zig");

pub const version = "0.1.0";
pub const version_string = "sando-audio 0.1.0 (Phase 1: Core Engine & Universal Runtime)";

test {
    // Zig 0.17 only collects test blocks from files referenced inside a
    // test block, not from plain re-exports above.
    _ = @import("hardware.zig");
    _ = @import("memory.zig");
    _ = @import("config.zig");
    _ = @import("audiocpp.zig");
}
