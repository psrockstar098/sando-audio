//! zig-talk — Zig SDK example: identify a Koloqua sentence, then
//! hold a two-turn mock-brain conversation. No model weights, no
//! network, no keys.
//!
//!   cd examples/zig && zig build -j1 -Dcpu=baseline && ./zig-out/bin/zig-talk

const std = @import("std");
const sando = @import("sando");

pub fn main(init: std.process.Init) void {
    const alloc = init.gpa;
    const io = init.io;

    std.debug.print("sando-audio {s}\n", .{sando.version});

    const id = sando.language.identify(alloc, "They fini fool we pekin them.", null) catch |err| {
        std.debug.print("identify failed: {t}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("identify: {s} (confidence {d:.2})\n", .{ id.language, id.confidence });

    var mock = sando.brain.MockBrain{};
    var conv = sando.conversation.Conversation.init(alloc, io, mock.asBrain(), "v1", "en-lr") catch |err| {
        std.debug.print("conversation failed: {t}\n", .{err});
        std.process.exit(1);
    };
    defer conv.deinit();

    for ([_][]const u8{ "hello", "tell me a joke" }) |text| {
        var result = conv.processText(text) catch |err| {
            std.debug.print("ask failed: {t}\n", .{err});
            std.process.exit(1);
        };
        defer result.deinit(alloc);
        std.debug.print("you: {s}\nsando: {s}\n", .{ text, result.reply });
    }
    std.debug.print("history turns: {d}\n", .{conv.session.turnCount()});
}
