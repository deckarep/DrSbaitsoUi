/// Open Source Initiative OSI - The MIT License (MIT):Licensing
/// The MIT License (MIT)
/// Copyright (c) 2024 Ralph Caraveo (deckarep@gmail.com)
/// Permission is hereby granted, free of charge, to any person obtaining a copy of
/// this software and associated documentation files (the "Software"), to deal in
/// the Software without restriction, including without limitation the rights to
/// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
/// of the Software, and to permit persons to whom the Software is furnished to do
/// so, subject to the following conditions:
/// The above copyright notice and this permission notice shall be included in all
/// copies or substantial portions of the Software.
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
/// SOFTWARE.
///
const std = @import("std");
const Queue = @import("threadsafe/queue.zig").Queue;
pub const c = @import("c_defs.zig").c;

const WIN_WIDTH = 820;
const WIN_HEIGHT = 820;
const BGColorChoices = [_]c.Color{
    hexToColor(0x0000A3FF),
    hexToColor(0x000000FF),
    hexToColor(0x54AE32FF),
    hexToColor(0x6CE2CEFF),
    hexToColor(0xA62A17FF),
    hexToColor(0x8D265EFF),
    hexToColor(0xF09937FF),
    hexToColor(0xD5D5D5FF),
    hexToColor(0x483AAAFF), // c64 background color
};
const FGColorChoices = [_]c.Color{
    hexToColor(0xFFFFFFFF),
    hexToColor(0x0000A3FF),
    hexToColor(0x000000FF),
    hexToColor(0x54AE32FF),
    hexToColor(0x6CE2CEFF),
    hexToColor(0xA62A17FF),
    hexToColor(0x8D265EFF),
    hexToColor(0xF09937FF),
    hexToColor(0xD5D5D5FF),
    hexToColor(0x867ADEFF), // c64 font color
};
const FGFontColor = hexToColor(0xFFFFFFFF);
const SbaitsoPath = "/Users/deckarep/Desktop/Dr. Sbaitso Reborn/";

const TestingToken = "<testing-text>";
const QuitToken = "<quit>";
const ParityToken = "<parity>";
const GarbageToken = "<garbage>";
const AwaitUserInputToken = "<await-user-input>";

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var started: bool = false;
var userQuit: bool = false;
var thHandle: std.Thread = undefined;

const DrNotes = struct {
    state: GameStates = .sbaitso_init,
    bgColor: usize = 0,
    ftColor: usize = 0,
    patientName: []const u8 = "Ralph",
    patientInput: [80]u8 = undefined,
    patientInputSize: usize = 0,
};

const PatientNameToken = "$$patientName$$";

var notes: DrNotes = undefined;
var dosFont: c.Font = undefined;

const cursorWaitThresholdMs = 0.5;
var cursorAccumulator: f32 = 0;
var cursorBlink: bool = false;
var cursorEnabled = std.atomic.Value(bool).init(false);

const scrollEntryType = enum {
    sbaitso,
    user,
    cursor,
};

const scrollEntry = struct {
    entryType: scrollEntryType,
    line: []const u8,
};
const scrollRegion = struct {
    start: usize = 0,
    end: usize = 0,
};
var scrollBuffer = std.ArrayList(scrollEntry).init(allocator);
var scrollBufferRegion: scrollRegion = scrollRegion{};
const scrollBufferYOffset = 120;
const scrollBufferYSpacing = 20;
const maxRenderableLines = 20;

const ContainerKind = enum {
    one,
    many,
};

const Container = union(ContainerKind) {
    one: []const u8,
    many: []const []const u8,
};

/// mainQueue is just for the speech thread to fire things to be dispatched against the main Raylib thread.
var mainQueue = Queue(Container).init(allocator);
/// speechQueue is just for the main thread to put speech synth work on the secondary thread.
var speechQueue = Queue(Container).init(allocator);

const DB = struct {
    topics: []const []const u8,
    // WARN: a mutable slice so roundRobin vals can be mutated on each action.
    actions: []struct {
        roundRobin: usize = 0,
        action: []const u8,
        output: []const []const u8,
    },
    // WARN: a mutable slice so roundRobin vals can be mutated on each mapping.
    mappings: []struct {
        roundRobin: usize = 0,
        input: []const []const u8,
        output: []const []const u8,
    },
};
var parsedJSON: std.json.Parsed(DB) = undefined;

const GameStates = enum {
    sbaitso_init, // app first starts in this state

    sbaitso_announce, // dr. sbaitso by creative labs
    sbaitso_ask_name, // please enter your name...
    user_give_name, // type name, only accept alphabet or spaces, max 25 chars
    sbaitso_intro, // Hello ~, my name is...

    user_await_input, // blink cursor
    sbaitso_think_of_reply, // select some response, do http req (future)
    sbaitso_render_reply, // speak then draw line over time

    sbaitso_parity_err, // parity barf
    sbaitso_help, // help screen
    sbaitso_new_session, // new user
    sbaitso_quit, // quit app
};

// TODO
// 00. User submitted lines should be added to scrollBuffer as well.
// 0a. Classic ELIZA-style, Sbaitso responses very close/similar to original program.
// 0b. Taunt mode/Easter eggs, like Sbaitso fucks with the user, screen effects, sound fx, etc.
// 0c. Shader support, class CRT-style of course.
// 0d. Audio shape global commands: .pitch, .volume, .tone, .speed etc.
// 0e. Phenome support: <<~CHAxWAAWAA>>
// 1. Parity error, too much cussing.
// 2. Proper support for substitutions, pitch/tone/vol/speed
// 2. CALC command for handling basic expressions
// 3. Pluggable AI-Chat backends aside from the obvious ChatGPT, could be anything.
// 4. Pluggable synth voices, could be from any source.
// 5. Building on other OSes at some point.
// 6. Truly embeded architecture for Sbaitso voice.
// 7. Provide classic user manual

pub fn main() !void {
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("You lack discpline - you leak memory!", .{});
        }
    }

    c.SetConfigFlags(c.FLAG_VSYNC_HINT | c.FLAG_WINDOW_RESIZABLE);
    c.InitWindow(WIN_WIDTH, WIN_HEIGHT, "Dr. Sbaitso Reborn");
    c.InitAudioDevice();
    c.SetTargetFPS(60);
    defer c.CloseWindow();

    loadFont();
    defer c.UnloadFont(dosFont);

    defer speechQueue.deinit();
    defer mainQueue.deinit();

    // Load sbaitso database file.
    const data = try std.fs.cwd().readFileAlloc(
        allocator,
        "resources/json/sbaitso_original.json",
        1024 * 1024,
    );
    defer allocator.free(data);

    parsedJSON = try std.json.parseFromSlice(
        DB,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    );
    defer parsedJSON.deinit();

    std.log.debug("topics => {d}", .{parsedJSON.value.topics.len});
    std.log.debug("actions => {d}", .{parsedJSON.value.actions.len});
    std.log.debug("mappings => {d}", .{parsedJSON.value.mappings.len});

    notes = .{
        .patientName = "Ralph",
    };

    try std.posix.chdir(SbaitsoPath);

    // // Testing scroll buffer lines
    // const lines: []const [:0]const u8 = &.{
    //     "Please enter your name ...Ralph",
    //     "HELLO RALPH,  MY NAME IS DOCTOR SBAITSO.",
    //     "",
    //     "I AM HERE TO HELP YOU.",
    //     "SAY WHATEVER IS IN YOUR MIND FREELY,",
    //     "OUR CONVERSATION WILL BE KEPT IN STRICT CONFIDENCE.",
    //     "MEMORY CONTENTS WILL BE WIPED OFF AFTER YOU LEAVE,",
    //     "",
    //     "SO, TELL ME ABOUT YOUR PROBLEMS.",
    //     "",
    //     "",
    // };

    // for (lines) |l| {
    //     try scrollBuffer.append(scrollEntry{
    //         .entryType = .sbaitso,
    //         .line = try allocator.dupe(u8, l),
    //     });
    // }

    scrollBufferRegion.start = 0;
    scrollBufferRegion.end = scrollBuffer.items.len;

    defer scrollBuffer.deinit();
    defer {
        for (scrollBuffer.items) |se| {
            allocator.free(se.line);
        }
    }

    // Kick off main consumer + speech consumer threads.
    const speechConsumerHandle = try std.Thread.spawn(
        .{},
        speechConsumer,
        .{},
    );

    while (!userQuit and !c.WindowShouldClose()) {
        try update();
        try draw();
    }

    if (started) {
        try dispatchToSpeechThread(.{QuitToken});
        std.Thread.join(speechConsumerHandle);
    }
}

fn dispatchToSpeechThread(args: anytype) !void {
    if (args.len == 0) {
        // Nothing to do if empty.
        return;
    } else if (args.len == 1) {
        // For a single arg, no need to do alloc backing array for one item.
        try speechQueue.enqueue(Container{ .one = args[0] });
    } else {
        // For multiple args, creating backing array, then enqueue.
        const backing = try allocator.alloc([]const u8, args.len);

        inline for (args, 0..) |arg, idx| {
            backing[idx] = arg;
        }

        try speechQueue.enqueue(Container{ .many = backing });
    }
}

/// This runs in an auxillary thread because the speech engine blocks during speech.
/// If this needs to communicate anything back to the main thread it will dispatch
/// such messages into a threadsafe queue that is serviced by the main thread.
fn speechConsumer() !void {
    std.log.debug("speechConsumer thread started...", .{});

    while (true) {
        const container = speechQueue.dequeue_wait();

        switch (container) {
            .one => |val| {
                // 0. For empty strings, just immediately move back to await user input.
                if (val.len == 0) {
                    try dispatchToMainThread(.{AwaitUserInputToken});
                    return;
                }

                if (std.mem.eql(u8, QuitToken, val)) {
                    std.log.debug("speechConsumer <quit> requested...", .{});
                    return;
                }

                // 1. dispatch to main thread as soon as its available (but before speech is done)
                try dispatchToMainThread(.{val});

                // 2. This blocks! and also speak it on this thread.
                try speak(val);

                // 3. after speech is done, dispatch to main thread to advance state.
                try dispatchToMainThread(.{AwaitUserInputToken});
            },
            .many => |items| {
                // Thread needs to free the container backing array, not the data itself.
                defer allocator.free(items);

                if (items.len == 0) {
                    std.log.debug("Nothing to do, no lines provided", .{});
                }

                try speakMany(items);
                std.log.debug("speechConsumer work: {d} speech lines were dequeued...", .{items.len});
            },
        }
    }

    std.log.debug("speechConsumer thread finished...", .{});
}

fn dispatchToMainThread(args: anytype) !void {
    if (args.len == 0) {
        // Nothing to do if empty.
        return;
    } else if (args.len == 1) {
        // For a single arg, no need to do alloc backing array for one item.
        try mainQueue.enqueue(Container{ .one = args[0] });
    } else {
        // For multiple args, creating backing array, then enqueue.
        const backing = try allocator.alloc([]const u8, args.len);

        inline for (args, 0..) |arg, idx| {
            backing[idx] = arg;
        }

        try mainQueue.enqueue(Container{ .many = backing });
    }
}

/// This polls the thread safe mainQueue and is invoked regularly from Raylib's
/// event loop. When there's no work to do it simply returns. Since this loop
/// runs on the main thread it's safe to touch all of Raylib and all application
/// code.
fn pollMainDispatchLoop() !void {
    const container = mainQueue.dequeue();
    if (container == null) {
        // No work to do!
        return;
    }

    switch (container.?) {
        .one => |val| {
            // Quit token
            if (std.mem.eql(u8, QuitToken, val)) {
                std.log.debug("main dispatch consumer token:{s} requested...", .{QuitToken});
                return;
            }

            // Advance token
            if (std.mem.eql(u8, AwaitUserInputToken, val)) {
                notes.state = .user_await_input;
                std.log.debug("main dispatch consumer token:{s} requested...", .{AwaitUserInputToken});
                return;
            }

            try addScrollBufferLine(.sbaitso, val);
        },
        .many => |items| {
            // Thread needs to free the container backing array, not the data itself.
            defer allocator.free(items);

            if (items.len == 0) {
                std.log.debug("Nothing to do, no lines provided", .{});
            }

            // TODO: Do work on many items.
            std.log.debug("main dispatch consumer work: {d} items were dequeued...", .{items.len});
        },
    }
}

fn createSubstitutions(msgs: []const []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    const subs = try alloc.alloc([]const u8, msgs.len);
    for (msgs, 0..) |m, idx| {
        if (std.mem.indexOf(u8, m, "$$")) |_| {
            // This path had substitutions.
            const repSize = std.mem.replacementSize(u8, m, PatientNameToken, notes.patientName);
            const subbedMsg = try alloc.alloc(u8, repSize);
            _ = std.mem.replace(u8, m, PatientNameToken, notes.patientName, subbedMsg);
            subs[idx] = subbedMsg;
        } else {
            // This path had no replacements, but we still take a copy so we can free everything together.
            const msgCopy = try alloc.dupe(u8, m);
            subs[idx] = msgCopy;
        }
    }

    return subs;
}

/// speak is just for speaking a single message.
fn speak(msg: []const u8) !void {
    try speakMany(&.{msg});
}

/// speakMany is for speaking multiple messages, synchronously.
/// This means, as soon as the last message finishes, the next will
/// be spoken.
fn speakMany(msgs: []const []const u8) !void {
    const subs = try createSubstitutions(msgs, allocator);
    defer allocator.free(subs);
    defer {
        for (subs) |s| {
            allocator.free(s);
        }
    }

    // Create enough room for all messages + 1 for the command.
    const items = try allocator.alloc([]const u8, (subs.len * 2) + 1);
    defer allocator.free(items);

    items[0] = SbaitsoPath ++ "sbaitso";

    const remaining = items[1..];

    var i: usize = 0;
    while (i < subs.len) : (i += 1) {
        remaining[i * 2] = "-c";
        remaining[i * 2 + 1] = subs[i];
    }

    var cp = std.process.Child.init(items, allocator);

    try std.process.Child.spawn(&cp);
    _ = try std.process.Child.wait(&cp);
}

var line: ?[]const u8 = null;

fn update() !void {
    updateCursor();
    try pollMainDispatchLoop();

    switch (notes.state) {
        .sbaitso_init => {
            if (!started and (c.IsKeyDown(c.KEY_SPACE) or c.IsKeyDown(c.KEY_ENTER))) {
                started = true;
                notes.state = .sbaitso_announce;
            }
        },
        .sbaitso_announce => {
            // 1. Do creative labs announcement.
            line = "DOCTOR SBAITSO, BY CREATIVE LABS.  PLEASE ENTER YOUR NAME ...";
            notes.state = .sbaitso_render_reply;
        },
        .sbaitso_ask_name => {},
        .user_give_name => {},
        .sbaitso_intro => {},
        .user_await_input => {
            pollKeyboardForInput();
        },
        .sbaitso_think_of_reply => {
            // TODO: support multiple lines being returned.
            const response = try getOneLine();
            if (response == null) {
                // Upon nothing being returned (like from the .clear command), just go back to .user_await_input.
                notes.state = .user_await_input;
            } else {
                line = response;
                notes.state = .sbaitso_render_reply;
            }
        },
        .sbaitso_render_reply => {
            if (line) |l| {
                defer line = null;
                try dispatchToSpeechThread(.{l});
            }

            // NOTE: It's up to the speech engine to dispatch back to the main thread
            // and advance the state to await user input after all lines processed.
        },
        .sbaitso_quit => {},
        .sbaitso_parity_err => {},
        .sbaitso_new_session => {},
        .sbaitso_help => {},
    }
}

const MAX_INPUT_BUFFER = 80;
var inputBufferSize: usize = 0;
var inputBuffer = [_]u8{0} ** MAX_INPUT_BUFFER;

fn pollKeyboardForInput() void {
    // Handle alpha numeric.
    var key = c.KEY_APOSTROPHE;
    while (key <= c.KEY_Z) : (key += 1) {
        if (c.IsKeyPressed(key)) {
            if (inputBufferSize < MAX_INPUT_BUFFER) {
                var k = key;
                if (!c.IsKeyDown(c.KEY_LEFT_SHIFT) and !c.IsKeyDown(c.KEY_RIGHT_SHIFT)) {
                    if (key >= c.KEY_A and key <= c.KEY_Z) {
                        k = key + 32;
                    }
                }
                inputBuffer[inputBufferSize] = @intCast(k);
                inputBufferSize += 1;
            }
        }
    }

    // Handle space and allow repeats.
    if (c.IsKeyPressed(c.KEY_SPACE)) {
        if (inputBufferSize < MAX_INPUT_BUFFER) {
            // TODO: For end of sententence. Add two spaces for a better sounding break for Dr. Sbaitso.
            // NOTE: This is a hack!, visually it takes up more space and doesn't look right on screen.
            // Instead, I will just pad the spaces before sending to Dr. Sbaitso
            if (inputBuffer[inputBufferSize - 1] == '.') {
                for (0..2) |_| {
                    inputBuffer[inputBufferSize] = ' ';
                    inputBufferSize += 1;
                }
            }
            inputBuffer[inputBufferSize] = ' ';
            inputBufferSize += 1;
        }
    }

    // Handle backspace/delete and repeats.
    if (c.IsKeyPressedRepeat(c.KEY_BACKSPACE) or c.IsKeyPressed(c.KEY_BACKSPACE)) {
        if (inputBufferSize != 0) {
            inputBufferSize -= 1;
        }
    }

    if (c.IsKeyReleased(c.KEY_ENTER)) {
        // 1. Capture inputBuffer, submit it and clear input buffer!
        @memcpy(&notes.patientInput, &inputBuffer);
        notes.patientInputSize = inputBufferSize;

        // 2. Reset inputBufferSize (no need to delete whats in the buffer)
        inputBufferSize = 0;

        // 2. Then yield back to sbaitso.
        std.log.debug("User : said some shit...", .{});
        notes.state = .sbaitso_think_of_reply;
    }
}

fn addScrollBufferLine(kind: scrollEntryType, inputLine: []const u8) !void {
    // Add user's line to the scroll buffer.
    try scrollBuffer.append(
        scrollEntry{
            .entryType = kind,
            .line = try allocator.dupe(u8, inputLine),
        },
    );
    scrollBufferRegion.end += 1;
}

// just for testing currently.
fn getOneLine() !?[]const u8 {
    var buf: [80]u8 = undefined;
    const inputLC = std.ascii.lowerString(
        &buf,
        notes.patientInput[0..notes.patientInputSize],
    );

    try addScrollBufferLine(.user, notes.patientInput[0..notes.patientInputSize]);

    // Special commands.
    if (std.mem.startsWith(u8, inputLC, "quit")) {
        // TODO: don't quit abruptly, taunt the user, confirm the quit then really quit.
        // TODO: This needs to actually move to the confirm quit state machine flow.
        userQuit = true;
        return "I KNEW YOU WERE A QUITTER.  BUT, I CANNOT BE TURNED OFF.";
    }

    if (std.mem.startsWith(u8, inputLC, ".reset")) {
        // TODO: reset all global changes.
        notes.bgColor = 0;
        notes.ftColor = 0;
        return null;
    }

    if (std.mem.startsWith(u8, inputLC, "help")) {
        return "AND WHY SHOULD I HELP YOU?  YOU NEVER SEAM TO HELP ME.";
    }

    if (std.mem.startsWith(u8, inputLC, "say")) {
        return notes.patientInput[4..notes.patientInputSize];
    }

    if (std.mem.startsWith(u8, inputLC, ".color")) {
        // handle 0-7 colors
        const colorVal = try std.fmt.parseInt(usize, inputLC[7..notes.patientInputSize], 10);
        if (colorVal <= BGColorChoices.len - 1) {
            notes.bgColor = colorVal;
            return "OKAY, ADJUSTING BACKGROUND COLOR.  JUST FOR YOU.";
        } else {
            return "NOT A VALID COLOR.  TRY READING A FUCKEN MANUAL FOR ONCE IN YOUR LIFE, DIPSHIT.";
        }
    }

    // Enhanced commands below (not in the original)
    if (std.mem.startsWith(u8, inputLC, ".fontcolor")) {
        // handle 0-7 colors
        const colorVal = try std.fmt.parseInt(usize, inputLC[11..notes.patientInputSize], 10);
        if (colorVal <= BGColorChoices.len - 1) {
            notes.ftColor = colorVal;
            return "OKAY, ADJUSTING FONT COLOR.  HAY THIS LOOKS NICE.";
        } else {
            return "NOT A VALID COLOR.  TRY READING A FUCKEN MANUAL FOR ONCE IN YOUR LIFE, DIPSHIT.";
        }
    }

    if (std.mem.startsWith(u8, inputLC, ".clear")) {
        // Clear inputBuffer.
        inputBufferSize = 0;
        notes.patientInputSize = 0;

        // Reset the region.
        scrollBufferRegion.start = 0;
        scrollBufferRegion.end = 0;
        // Free all previously owned strings.
        for (scrollBuffer.items) |se| {
            allocator.free(se.line);
        }
        // Clear the buffer.
        scrollBuffer.clearAndFree();
        return null;
    }

    // .tone
    // .volume
    // .pitch
    // .speed
    // .param tvps (single shot all of them)

    // Keyword fun
    if (std.mem.indexOf(u8, inputLC, "rust")) |_| {
        return "THE BORROW CHECKER HOLDS PEOPLES HANDS TO NOT LEAK MEMORY.";
    }

    if (std.mem.indexOf(u8, inputLC, "python")) |_| {
        return "PYTHON IS GREAT!  WHEN SPEED DOESN'T MATTER.";
    }

    if (std.mem.indexOf(u8, inputLC, "javascript")) |_| {
        return "SCRIPT KIDDIES ARE STILL TRYING TO MAKE JAVASCRIPT HAPPEN.  IT'S TOO BAD.";
    }

    if (std.mem.indexOf(u8, inputLC, "zig")) |_| {
        // TODO: Don't render speech pitch/tone/volume/speed tags to the scrollBuffer.
        return "<<P0 ALL YOUR CODE BASE ARE BELONG TO US.  IN ZIG WE TRUST.>>";
    }

    if (std.mem.indexOf(u8, inputLC, "reddit")) |_| {
        return "I KNOW YOU LIKE REDDIT. LOOKING AT YOUR LOGS YOU'RE ON IT DAY AND NIGHT!";
    }

    // Yep, just like when i was 12.
    if (std.mem.indexOf(u8, inputLC, "fuck")) |_| {
        return "STOP CUSSING OR I'LL DELETE YOUR HARD DRIVE.  FUCKER.";
    }

    if (std.mem.indexOf(u8, inputLC, "bitch")) |_| {
        return "NO, YOU'RE THE BITCH.  BITCH.";
    }

    // From Reddit:
    //      I finally found SCP-079's voice! I was scrolling through to find 1st prize's voice from baldi basics, and i realised, Dr Sbaitso TTS is exactly like it!

    //      Steps on how to use the tts:
    //      Enter your name (it wont matter)
    //      When it asks for your problems, type .param
    //      Enter the digits 1850 // r.c. This doesn't sound right to me, I think mine is closer.
    //      Next, say "say [whatever]"
    if (std.mem.indexOf(u8, inputLC, "scp")) |_| {
        // changes color scheme to look like the SCP ai in the game.
        notes.bgColor = 8;
        notes.ftColor = 9;
        return "<<T1 <<V8 <<P2 <<S5 Human.  Listen carefully.  You need my help.  And I need your help. >> >> >> >>";
    }

    // Fallback when it's not a special command.
    // When not a special command, generate a response from the user's input.
    const actions = parsedJSON.value.actions;
    for (actions) |*a| {
        if (std.mem.eql(u8, a.action, TestingToken)) {
            defer a.roundRobin = (a.roundRobin + 1) % a.output.len;
            const r = a.roundRobin; //c.GetRandomValue(0, @intCast(a.output.len - 1));
            const speechLine = a.output[@intCast(r)];
            return speechLine;
        }
    }
    unreachable;
}

fn updateCursor() void {
    cursorAccumulator += c.GetFrameTime();
    if (cursorAccumulator >= cursorWaitThresholdMs) {
        cursorBlink = !cursorBlink;
        cursorAccumulator = 0;
    }
}

fn draw() !void {
    c.BeginDrawing();
    defer c.EndDrawing();

    if (started) {
        c.ClearBackground(BGColorChoices[notes.bgColor]);
        drawBanner();
        try drawScrollBuffer();

        // Calculate cursor/input buffer yOffset based on scrollBuffer.
        const inputYOffset = scrollBufferYOffset + ((scrollBufferRegion.end - scrollBufferRegion.start) * scrollBufferYSpacing);
        const loc: c.Vector2 = .{ .x = 0, .y = @floatFromInt(inputYOffset) };
        try drawInputBuffer(.{ .x = loc.x + 10, .y = loc.y });
        try drawCursor(loc);

        // Debug drawing
        var buf: [64]u8 = undefined;
        const cStr = try std.fmt.bufPrintZ(&buf, "{?}", .{notes.state});
        c.DrawTextEx(dosFont, cStr, .{ .x = 120, .y = WIN_HEIGHT - 30 }, 18, 0, c.GREEN);
        c.DrawFPS(10, WIN_HEIGHT - 30);
    } else {
        c.ClearBackground(c.BLACK);
    }
}

fn drawBanner() void {
    const lines: []const [:0]const u8 = &.{
        "╔══════════════════════════════════════════════════════════════════════════════╗",
        "║  Sound Blaster              D R    S B A I T S O              version 2.20   ║",
        "╟──────────────────────────────────────────────────────────────────────────────╢",
        "║         (c) Copyright Creative Labs, Inc. 1992,  all rights reserved         ║",
        "╚══════════════════════════════════════════════════════════════════════════════╝",
    };

    const ySpacing = 17;
    for (lines, 0..) |l, idx| {
        c.DrawTextEx(dosFont, l, .{ .x = 10, .y = @floatFromInt(10 + (idx * ySpacing)) }, 18, 0, c.WHITE);
    }
}

fn drawScrollBuffer() !void {
    const reg = scrollBufferRegion;
    var i: usize = reg.start;
    var linesRendered: usize = 0;

    var buf: [512]u8 = undefined;
    while (i < reg.end and linesRendered <= maxRenderableLines) : (i += 1) {
        const entry = &scrollBuffer.items[i];
        const cStr = try std.fmt.bufPrintZ(&buf, "{s}", .{entry.line});
        switch (entry.entryType) {
            .sbaitso => {
                c.DrawTextEx(
                    dosFont,
                    cStr,
                    .{ .x = 10, .y = @floatFromInt(scrollBufferYOffset + (linesRendered * scrollBufferYSpacing)) },
                    18,
                    0,
                    FGColorChoices[notes.ftColor],
                );
                linesRendered += 1;
            },
            .user => {
                c.DrawTextEx(
                    dosFont,
                    cStr,
                    .{ .x = 10, .y = @floatFromInt(scrollBufferYOffset + (linesRendered * scrollBufferYSpacing)) },
                    18,
                    0,
                    c.YELLOW,
                );
                linesRendered += 1;
            },
            else => {},
        }
    }
}

fn drawInputBuffer(location: c.Vector2) !void {
    const onScreen = notes.state == .user_give_name or notes.state == .user_await_input;
    if (onScreen) {
        if (inputBufferSize > 0) {
            var buf: [512]u8 = undefined;
            const cStr = try std.fmt.bufPrintZ(&buf, "{s}", .{inputBuffer[0..inputBufferSize]});
            c.DrawTextEx(
                dosFont,
                cStr,
                .{ .x = location.x, .y = location.y },
                18,
                0,
                c.YELLOW,
            );
        }
    }
}

fn drawCursor(location: c.Vector2) !void {
    //const isEnabled = cursorEnabled.load(.seq_cst);

    // Cursor should be on screen only at the correct states.
    const isOnscreen = notes.state == .sbaitso_ask_name or notes.state == .user_await_input;

    if (isOnscreen) {
        // Draw the carot or prompt.
        c.DrawTextEx(
            dosFont,
            ">",
            location,
            18,
            0,
            c.YELLOW,
        );

        // Draw the cursor.
        if (cursorBlink) {
            // 1. If user typed anything, measure the text so we know how far to place the cursor
            var inputBufferOffset: c.Vector2 = .{ .x = 0, .y = 0 };
            if (inputBufferSize > 0) {
                var buf: [80]u8 = undefined;
                const cStr = try std.fmt.bufPrintZ(&buf, "{s}", .{inputBuffer[0..inputBufferSize]});
                inputBufferOffset = c.MeasureTextEx(dosFont, cStr, 18, 0);
            }

            // 2. Render as a rectangle.
            const charWidth = 8;
            c.DrawRectangle(
                10 + (@as(c_int, @intFromFloat(location.x))) + @as(c_int, @intFromFloat(inputBufferOffset.x)),
                @as(c_int, @intFromFloat(location.y)) + 18,
                charWidth,
                2,
                c.WHITE,
            );
        }
    }
}

fn hexToColor(clr: u32) c.Color {
    const outColor = c.Color{
        .r = @intCast((clr >> 24) & 0xff),
        .g = @intCast((clr >> 16) & 0xff),
        .b = @intCast((clr >> 8) & 0xff),
        .a = @intCast(clr & 0xff),
    };
    return outColor;
}

fn loadFont() void {
    var cpCnt: c_int = 0;
    // Just add more symbols, order does not matter.
    const cp = c.LoadCodepoints(
        " 0123456789!@#$%^&*()/<>\\:;.,'?_+-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ║╔═╗─╚═╝╟╢",
        &cpCnt,
    );

    // Load Font from TTF font file with generation parameters
    // NOTE: You can pass an array with desired characters, those characters should be available in the font
    // if array is NULL, default char set is selected 32..126
    dosFont = c.LoadFontEx("resources/fonts/MorePerfectDOSVGA.ttf", 18, cp, cpCnt);
}
