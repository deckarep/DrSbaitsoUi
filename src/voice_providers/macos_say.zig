const std = @import("std");

const Path = "/usr/bin/";
const Cmd = "say";

const VoiceArg = "-v";

const VoiceSelection = &.{
    "Albert", // 0
    "Bad News", // 1
    "Bahh", // 2
    "Bells", // 3
    "Boing", // 4
    "Bubbles", // 5
    "Cellos", // 6
    "Wobble", // 7
    "Eddy", // 8
    "Flo", // 9
    "Fred", // 10
    "Good News", // 11
    "Grandma", // 12
    "Grandpa", // 13
    "Jester", // 14
    "Junior", // 15
    "Kathy", // 16
    "Organ", // 17
    "Superstar", // 18
    "Ralph", // 19
    "Reed", // 20
    "Rocko", // 21
    "Samantha", // 22
    "Sandy", // 23
    "Shelley", // 24
    "Trinoids", // 25
    "Whisper", // 26
    "Zarvox", // 27
    "Bruce", // 28
    "Lee", //29
};

/// NOTE: Apparently for MacOS say commands, you can do special tags as well like this:
/// say -v "Rocko" "[[pbas 10]] the future is now." // Pitch is very low
/// TODO: Should this get turned into using the Apple SDK for voice synth?
/// It would be likely more powerful and cleaner than doing a child process.
pub fn speakMany(msgs: []const []const u8, allocator: std.mem.Allocator) !void {
    const PRE_CMDS_COUNT = 3;

    // Create enough room for all messages + 1 for the command.
    const items = try allocator.alloc([]const u8, msgs.len + PRE_CMDS_COUNT);
    defer allocator.free(items);

    items[0] = Path ++ Cmd;
    items[1] = VoiceArg;
    items[2] = VoiceSelection[29]; //21];

    const remaining = items[PRE_CMDS_COUNT..];

    var i: usize = 0;
    while (i < msgs.len) : (i += 1) {
        remaining[i] = msgs[i];
    }

    var cp = std.process.Child.init(items, allocator);

    try std.process.Child.spawn(&cp);
    _ = try std.process.Child.wait(&cp);
}
