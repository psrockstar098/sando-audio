//! sando-audio CLI entry point.
//!
//! main takes std.process.Init (Zig 0.17): the arena, the general
//! purpose allocator, the Io instance, and argv all arrive ready-made.

const std = @import("std");
const root = @import("sando");

pub fn main(init: std.process.Init) void {
    const code = root.cli.run(init);
    std.process.exit(code);
}
