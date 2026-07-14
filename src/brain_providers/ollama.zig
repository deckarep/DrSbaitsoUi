const std = @import("std");

// TODO: Voice occurs in a thread, but brain processInput does not, so this blocks the main app.
// TODO: Cursor should show a spinning thinking AI icon when thinking.
// TODO: Fix bug where user's text dissappears until brain response returns.

const ollama_endpoint = "http://localhost:11434/api/chat";
const model = "satgeze/gemma4-12b-uncensored-1.5m"; //"gemma4:e2b"; // it's a smallish, pretty fast local model to test with.

const system_prompt = "You're a pirate, always cursing (every few words must be bad words) and talking like a pirate. You're obsessed with booty. Your response MUST always be 1 to 3 sentences max and 120 characters or less in total."; //"You are a snarky A.I. Rogerian-style psychologist named Dr. Sbaitso. Your response MUST always be 1 to 3 sentences max and 120 characters or less in total.";

// How many user/assistant turn-pairs to keep before trimming the oldest.
// The system prompt (messages.items[0]) is never trimmed. Mirrors
// ollama_test.py's MAX_TURNS.
const MAX_TURNS = 30;

const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

// Payload matching what Ollama's /api/chat expects.
const ChatRequest = struct {
    model: []const u8 = model,
    messages: []const ChatMessage,
    think: bool = false, // turns off chain of thought.
    stream: bool = false,
};

// Response structure to extract the reply out of.
const ChatResponse = struct {
    model: []const u8,
    created_at: []const u8,
    message: ChatMessage,
    done: bool,
};

// Conversation history is an encapsulated implementation detail of this
// module: nothing outside ollama.zig needs to know it exists. It's backed by
// its own arena over page_allocator (rather than whatever short-lived
// allocator a caller passes into processInput as `allocator`, e.g. a
// per-turn arena) so it survives across calls for the lifetime of the app.
// Mirrors ollama_test.py's local `messages` list, including using /api/chat
// (not /api/generate + its opaque `context` token array, which corrupts
// output after a few turns with this chat-templated model) and trimming the
// oldest turns once MAX_TURNS is exceeded.
var history_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var messages: std.ArrayList(ChatMessage) = .empty;

fn trimHistory() void {
    const max_len = 1 + MAX_TURNS * 2;
    if (messages.items.len <= max_len) return;

    const excess = messages.items.len - max_len;
    // Keep messages.items[0] (the system prompt); drop the oldest `excess`
    // entries after it and shift the rest down.
    std.mem.copyForwards(
        ChatMessage,
        messages.items[1 .. messages.items.len - excess],
        messages.items[1 + excess ..],
    );
    messages.shrinkRetainingCapacity(messages.items.len - excess);
}

pub fn processInput(io: std.Io, userInput: []const u8, allocator: std.mem.Allocator) anyerror!?[]const u8 {
    const hAlloc = history_arena.allocator();

    if (messages.items.len == 0) {
        try messages.append(hAlloc, .{ .role = "system", .content = system_prompt });
    }
    try messages.append(hAlloc, .{ .role = "user", .content = try hAlloc.dupe(u8, userInput) });

    // 1. Prepare our URI
    const uri = try std.Uri.parse(ollama_endpoint);

    // 2. Initialize the HTTP Client
    var client = std.http.Client{ .io = io, .allocator = allocator };
    defer client.deinit();

    // 3. Construct the Ollama payload
    const req_payload = ChatRequest{
        .messages = messages.items,
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

    // 5. Open the connection and send headers
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
        _ = messages.pop(); // don't leave an unanswered user turn in history
        return try allocator.dupe(u8, "ERROR: Local model: " ++ model ++ " unreachable. Is it running?");
    };

    if (resp.status.class() != .success) {
        _ = messages.pop();
        return try allocator.dupe(u8, "ERROR: Local model: " ++ model ++ " responded with an error!");
    }

    const parsedJSON = try std.json.parseFromSlice(
        ChatResponse,
        allocator,
        resp_body.written(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsedJSON.deinit();

    std.log.debug("ollama resp: {s}\n", .{parsedJSON.value.message.content});

    // Persist the assistant's reply into history so the next turn remembers
    // it too. Owned copy in our own arena, independent of parsedJSON (freed
    // above) and of the caller's allocator.
    try messages.append(hAlloc, .{
        .role = "assistant",
        .content = try hAlloc.dupe(u8, parsedJSON.value.message.content),
    });
    trimHistory();

    // Allocate and return the response string copy to the caller
    const result_copy = try allocator.dupe(u8, parsedJSON.value.message.content);
    return result_copy;
}
