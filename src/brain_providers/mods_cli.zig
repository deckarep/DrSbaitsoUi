// Example mods tooling
// Install with: brew install charmbracelet/tap/mods
// Requires only: OPENAI_API_KEY environment variable to be set.

// mods --continue-last \
// --format .json \
// --prompt "You are Conan the Destroyer" \
// --continue-last \
// "How are you?"

const std = @import("std");

const Path = "/opt/homebrew/bin/";
const Cmd = "mods";

const systemPrompt =
    \\You are Dr. Sbaitso, a rogerian psychologist with a maximum of 80 
    \\characters single sentence responses. You can carry any conversation, 
    \\but your responses always come off as robotic and neutral but varied. You don't 
    \\tolerate any cursing. You always try your best to provide information, 
    \\or solace or proper psychologist care.
;

pub fn processInput(userInput: []const u8, allocator: std.mem.Allocator) anyerror!?[]const u8 {
    // Define command arguments - easily add/remove flags and args here
    const args = [_][]const u8{
        Path ++ Cmd,
        "--model",
        "gpt-3.5-turbo", // cheaper model
        "--continue-last",
        "--format",
        "--raw",
        "--quiet",
        "text",
        "--prompt",
        systemPrompt,
        userInput,
    };

    //std.debug.print("args => {s}\n", .{args});

    // Allocate space for the arguments array
    const items = try allocator.alloc([]const u8, args.len);
    defer allocator.free(items);

    // Copy arguments to the allocated array
    @memcpy(items, &args);

    var cp = std.process.Child.init(items, allocator);
    cp.stdout_behavior = .Pipe;
    cp.stderr_behavior = .Inherit;

    try std.process.Child.spawn(&cp);

    var stdout = cp.stdout.?;

    const output = try stdout.readToEndAlloc(allocator, 1024 * 32);

    _ = try std.process.Child.wait(&cp);

    return output;
}
