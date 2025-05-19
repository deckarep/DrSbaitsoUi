const std = @import("std");

// This is path to the speech engine, not yet public.
const SbaitsoPath = "/Users/deckarep/Desktop/Dr. Sbaitso Reborn/";

/// speakMany is for speaking multiple messages, synchronously.
/// This means, as soon as the last message finishes, the next will
/// be spoken.
pub fn speakMany(msgs: []const []const u8, allocator: std.mem.Allocator) !void {
    try std.posix.chdir(SbaitsoPath);

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

    var cp = std.process.Child.init(items, allocator);

    try std.process.Child.spawn(&cp);
    _ = try std.process.Child.wait(&cp);
}
