// Example mods tooling
// Install with: brew install charmbracelet/tap/mods
// Requires only: OPENAI_API_KEY environment variable to be set.

const std = @import("std");

const Path = "/opt/homebrew/bin/";
const Cmd = "mods";
const GPTModel = "gpt-3.5-turbo"; // cheaper model
const Format = "text";

const systemPrompt =
    \\You are Dr. Sbaitso, a rogerian psychologist with a maximum of 80 
    \\characters single sentence responses. You can carry any conversation, 
    \\but your responses always come off as robotic and neutral but varied. You don't 
    \\tolerate any cursing. You always try your best to provide information, 
    \\or solace or proper psychologist care.
;

pub fn processInput(userInput: []const u8, allocator: std.mem.Allocator) anyerror!?[]const u8 {
    const start = try std.time.Instant.now();
    // Define command arguments - easily add/remove flags and args here
    const args = [_][]const u8{
        Path ++ Cmd,
        "--model",
        GPTModel,
        "--continue-last",
        "--format",
        Format,
        "--raw",
        "--quiet",
        "--prompt",
        systemPrompt,
        userInput,
    };

    var cp = std.process.Child.init(&args, allocator);
    cp.stdout_behavior = .Pipe;
    cp.stderr_behavior = .Inherit;

    try std.process.Child.spawn(&cp);

    var stdout = cp.stdout.?;

    const output = try stdout.readToEndAlloc(allocator, 1024 * 32);

    _ = try std.process.Child.wait(&cp);

    const end = try std.time.Instant.now();
    const elapsed: f64 = @floatFromInt(end.since(start));
    const elapsed_secs = elapsed / std.time.ns_per_ms;
    std.debug.print("mods ({d:.3}ms): output => {s}, output.len => {d}\n", .{ elapsed_secs, output, output.len });
    return output;
}
