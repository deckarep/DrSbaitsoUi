const std = @import("std");

// TODO: Voice occurs in a thread, but brain processInput does not, so this blocks the main app.
// TODO: Cursor should show a spinning thinking AI icon when thinking.
// TODO: Context is supported here and should be woven through and through.
// TODO: When ollama isn't running this thing crashes like a piece of garbage.
// TODO: Allow for longer setence responses!
// TODO: Fix bug where user's text dissappears until brain response returns.

const ollama_endpoint = "http://localhost:11434/api/generate";
const model = "satgeze/gemma4-12b-uncensored-1.5m"; //"gemma4:e2b"; // it's a smallish, pretty fast local model to test with.

// Payload matching what Ollama expects
const OllamaRequest = struct {
    model: []const u8 = model,
    prompt: []const u8,
    system: []const u8 = "You are a snarky A.I. Rogerian-style psychologist named Dr. Sbaitso. Your response MUST always be 1 to 3 sentences max and 120 characters or less in total.",
    think: bool = false, // turns off chain of thought.
    stream: bool = false,
    // TODO: track context array one day
};

// Response structure to extract the text output
const OllamaResponse = struct {
    model: []const u8,
    created_at: []const u8,
    response: []const u8,
    done: bool,
};

pub fn processInput(io: std.Io, userInput: []const u8, allocator: std.mem.Allocator) anyerror!?[]const u8 {
    // Avoid unused variable warning for io if it's reserved for future use

    // 1. Prepare our URI
    const uri = try std.Uri.parse(ollama_endpoint);

    // 2. Initialize the HTTP Client
    var client = std.http.Client{ .io = io, .allocator = allocator };
    defer client.deinit();

    // 3. Construct the Ollama payload
    const req_payload = OllamaRequest{
        .prompt = userInput,
    };

    // 4. Ollama request to json
    var json_string = std.Io.Writer.Allocating.init(allocator);
    defer json_string.deinit();

    // Serialize directly into the .interface field
    try std.json.Stringify.value(req_payload, .{}, &json_string.writer);

    var resp_body = std.Io.Writer.Allocating.init(allocator);
    defer resp_body.deinit();

    // Retrieve the final string slice using .written()
    const payload_bytes = json_string.written();

    // 4. Open the connection and send headers
    var resp = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .payload = payload_bytes,
        .response_writer = &resp_body.writer,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
    }) catch |err| {
        std.log.err("ollama: failed to reach {s}: {s}", .{ ollama_endpoint, @errorName(err) });
        return try allocator.dupe(u8, "ERROR: Local model: " ++ model ++ " unreachable. Is it running?");
    };

    if (resp.status.class() != .success) {
        return try allocator.dupe(u8, "ERROR: Local model: " ++ model ++ " responded with an error!");
    }

    const parsedJSON = try std.json.parseFromSlice(
        OllamaResponse,
        allocator,
        resp_body.written(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsedJSON.deinit();

    // Allocate and return the response string copy to the caller
    const result_copy = try allocator.dupe(u8, parsedJSON.value.response);
    return result_copy;
}
