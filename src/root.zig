//! SANDO Audio library root.
//!
//! Phase 1 modules. The engine is assembled in engine.zig; the CLI in
//! main.zig drives it. audio.cpp bindings live in audiocpp.zig and are
//! compiled against the prebuilt C ABI when linked (see build.zig).

pub const hardware = @import("hardware.zig");
pub const memory = @import("memory.zig");
pub const config = @import("config.zig");
pub const audiocpp = @import("audiocpp.zig");
pub const runtime = @import("runtime.zig");
pub const models = @import("models.zig");
pub const plugin = @import("plugin.zig");
pub const engine = @import("engine.zig");
pub const audio = @import("audio.zig");
pub const c_api = @import("c_api.zig");
pub const cli = @import("cli.zig");
pub const doctor = @import("doctor.zig");
pub const bench = @import("bench.zig");
pub const vad = @import("vad.zig");
pub const streaming = @import("streaming.zig");
pub const audiosense = @import("audiosense.zig");
pub const voicedna = @import("voicedna.zig");
pub const cache = @import("cache.zig");
pub const reflex = @import("reflex.zig");
pub const brain = @import("brain.zig");
pub const conversation = @import("conversation.zig");

pub const version = "0.3.0";
pub const version_string = "sando-audio 0.3.0 (Phase 3: Intelligence & Conversational AI)";

test {
    // Zig 0.17 only collects test blocks from files referenced inside a
    // test block, not from plain re-exports above.
    _ = @import("hardware.zig");
    _ = @import("memory.zig");
    _ = @import("config.zig");
    _ = @import("audiocpp.zig");
    _ = @import("runtime.zig");
    _ = @import("models.zig");
    _ = @import("plugin.zig");
    _ = @import("engine.zig");
    _ = @import("audio.zig");
    _ = @import("c_api.zig");
    _ = @import("cli.zig");
    _ = @import("doctor.zig");
    _ = @import("bench.zig");
    _ = @import("vad.zig");
    _ = @import("streaming.zig");
    _ = @import("audiosense.zig");
    _ = @import("voicedna.zig");
    _ = @import("cache.zig");
    _ = @import("reflex.zig");
    _ = @import("brain.zig");
    _ = @import("conversation.zig");
}
