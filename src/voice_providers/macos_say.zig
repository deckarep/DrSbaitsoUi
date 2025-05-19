const std = @import("std");

const Path = "";
const Cmd = "say";

const VoiceArg = "-v";

const VoiceSelection = &.{
    "Albert",
    "Bad News",
    "Bahh",
    "Bells",
    "Boing",
    "Bubbles",
    "Cellos",
    "Wobble",
    "Eddy",
    "Flo",
    "Fred",
    "Good News",
    "Grandma",
    "Grandpa",
    "Jester",
    "Junior",
    "Kathy",
    "Organ",
    "Superstar",
    "Ralph",
    "Reed",
    "Rocko",
    "Samantha",
    "Sandy",
    "Shelley",
    "Trinoids",
    "Whisper",
    "Zarvox",
};

pub fn speakMany(msgs: []const []const u8, allocator: std.mem.Allocator) !void {
    const PRE_CMDS_COUNT = 3;

    // Create enough room for all messages + 1 for the command.
    const items = try allocator.alloc([]const u8, msgs.len + PRE_CMDS_COUNT);
    defer allocator.free(items);

    items[0] = Path ++ Cmd;
    items[1] = VoiceArg;
    items[2] = VoiceSelection[12];

    const remaining = items[PRE_CMDS_COUNT..];

    var i: usize = 0;
    while (i < msgs.len) : (i += 1) {
        remaining[i] = msgs[i];
    }

    var cp = std.process.Child.init(items, allocator);

    try std.process.Child.spawn(&cp);
    _ = try std.process.Child.wait(&cp);
}
