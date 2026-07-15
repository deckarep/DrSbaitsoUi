const std = @import("std");

const Path = "/usr/bin/";
const Cmd = "say";

const VoiceArg = "-v";

// Tags are spelled exactly as the macOS `say -v` command expects them
// (capitalization and spacing included) so @tagName() can hand that string
// back directly, with no manual enum -> string conversion needed.
const Voice = enum {
    Albert,
    @"Bad News",
    Bahh,
    Bells,
    Boing,
    Bubbles,
    Cellos,
    Wobble,
    Eddy,
    Flo,
    Fred,
    @"Good News",
    Grandma,
    Grandpa,
    Jester,
    Junior,
    Kathy,
    Organ,
    Superstar,
    Ralph,
    Reed,
    Rocko,
    Samantha,
    Sandy,
    Shelley,
    Trinoids,
    Whisper,
    Zarvox,
    Bruce,
    Lee,
};

const selectedVoice: Voice = .Rocko; //.Lee;

/// NOTE: Apparently for MacOS say commands, you can do special tags as well like this:
/// say -v "Rocko" "[[pbas 10]] the future is now." // Pitch is very low
/// TODO: Should this get turned into using the Apple SDK for voice synth?
/// It would be likely more powerful and cleaner than doing a child process.
pub fn speakMany(io: std.Io, msgs: []const []const u8, allocator: std.mem.Allocator) !void {
    const PRE_CMDS_COUNT = 3;

    // Create enough room for all messages + 1 for the command.
    const items = try allocator.alloc([]const u8, msgs.len + PRE_CMDS_COUNT);
    defer allocator.free(items);

    items[0] = Path ++ Cmd;
    items[1] = VoiceArg;
    items[2] = @tagName(selectedVoice);

    const remaining = items[PRE_CMDS_COUNT..];

    var i: usize = 0;
    while (i < msgs.len) : (i += 1) {
        remaining[i] = msgs[i];
    }

    var cp = try std.process.spawn(io, .{ .argv = items });
    _ = try cp.wait(io);
}
