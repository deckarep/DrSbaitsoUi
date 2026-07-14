const std = @import("std");

// TODO: Voice occurs in a thread, but brain processInput does not, so this blocks the main app.
// TODO: Cursor should show a spinning thinking AI icon when thinking.
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
    context: ?[]const i64 = null,
};

// Response structure to extract the text output
const OllamaResponse = struct {
    model: []const u8,
    created_at: []const u8,
    response: []const u8,
    done: bool,
    context: ?[]const i64 = null,
};

/// Persists Ollama's conversation state (the token context array it hands
/// back each turn) across calls. The caller owns one of these for the
/// lifetime of a conversation and passes it in as `data`; it keeps its own
/// arena so the tokens survive independently of whatever short-lived
/// allocator the caller passes as `allocator` (e.g. a per-turn arena).
pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    tokens: []const i64 = &.{},

    pub fn init(backing_allocator: std.mem.Allocator) Context {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
    }
};

pub fn processInput(io: std.Io, userInput: []const u8, allocator: std.mem.Allocator, data: ?*anyopaque) anyerror!?[]const u8 {
    const ctx: ?*Context = if (data) |d| @ptrCast(@alignCast(d)) else null;

    // 1. Prepare our URI
    const uri = try std.Uri.parse(ollama_endpoint);

    // 2. Initialize the HTTP Client
    var client = std.http.Client{ .io = io, .allocator = allocator };
    defer client.deinit();

    // 3. Construct the Ollama payload
    const req_payload = OllamaRequest{
        .prompt = userInput,
        .context = if (ctx) |c| (if (c.tokens.len == 0) null else c.tokens) else null,
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

    // Persist the returned context tokens (if any) so the next turn can
    // carry the conversation forward. Stored in ctx's own arena since it
    // must outlive the caller's per-turn allocator.
    if (ctx) |c| {
        if (parsedJSON.value.context) |newTokens| {
            _ = c.arena.reset(.retain_capacity);
            c.tokens = try c.arena.allocator().dupe(i64, newTokens);
        }
    }

    // Allocate and return the response string copy to the caller
    const result_copy = try allocator.dupe(u8, parsedJSON.value.response);
    return result_copy;
}
