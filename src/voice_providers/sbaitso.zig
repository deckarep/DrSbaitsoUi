const std = @import("std");

// This is path to the speech engine, not yet public...don't ask for it either.
const SbaitsoPath = "/Users/deckarep/Desktop/Dr. Sbaitso Reborn/";

/// speakMany is for speaking multiple messages, synchronously.
/// This means, as soon as the last message finishes, the next will
/// be spoken.
pub fn speakMany(io: std.Io, msgs: []const []const u8, allocator: std.mem.Allocator) !void {
    try std.process.setCurrentPath(io, SbaitsoPath);

    // Create enough room for all messages + 1 for the command.
    const items = try allocator.alloc([]const u8, (msgs.len * 2) + 1);
    defer allocator.free(items);

    items[0] = SbaitsoPath ++ "sbaitso";

    const remaining = items[1..];

    var i: usize = 0;
    while (i < msgs.len) : (i += 1) {
        remaining[i * 2] = "-c";
        remaining[i * 2 + 1] = msgs[i];
    }

    var cp = try std.process.spawn(io, .{ .argv = items });
    _ = try cp.wait(io);
}
