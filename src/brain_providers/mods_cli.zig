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

pub fn processInput(io: std.Io, userInput: []const u8, allocator: std.mem.Allocator, _: ?*anyopaque) anyerror!?[]const u8 {
    const start = std.Io.Timestamp.now(io, .awake);
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

    var cp = try std.process.spawn(io, .{
        .argv = &args,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    var rbuf: [4096]u8 = undefined;
    var stdout_reader = cp.stdout.?.reader(io, &rbuf);
    const output = try stdout_reader.interface.allocRemaining(allocator, .limited(1024 * 32));

    _ = try cp.wait(io);

    const end = std.Io.Timestamp.now(io, .awake);
    const elapsed: f64 = @floatFromInt(start.durationTo(end).toNanoseconds());
    const elapsed_secs = elapsed / std.time.ns_per_ms;
    std.debug.print("mods ({d:.3}ms): output => {s}, output.len => {d}\n", .{ elapsed_secs, output, output.len });
    return output;
}
