//! sando-audio CLI entry point (temporary stub — replaced by cli.zig in chunk 3).

const std = @import("std");
const root = @import("sando");

pub fn main() !void {
    std.debug.print("{s}\n", .{root.version_string});
}
