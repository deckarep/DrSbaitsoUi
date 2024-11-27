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
const BGBlueColor = hexToColor(0x0000AAFF);
const SbaitsoPath = "/Users/deckarep/Desktop/Dr. Sbaitso Reborn/";

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var started: bool = false;
var thHandle: std.Thread = undefined;

const DrNotes = struct {
    state: GameStates = .sbaitso_init,
    bgColor: c.Color = BGBlueColor,
    patientName: []const u8 = "Ralph",
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
    line: [:0]const u8,
};
const scrollRegion = struct {
    start: usize = 0,
    end: usize = 0,
};
var scrollBuffer = std.ArrayList(scrollEntry).init(allocator);
var scrollBufferRegion: scrollRegion = scrollRegion{};

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
    actions: []const struct {
        action: []const u8,
        output: []const []const u8,
    },
    mappings: []const struct {
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
// 00. Text input - obviously.
// 0a. Classic ELIZA-style, Sbaitso responses very close/similar to original program.
// 0b. Change BG color.
// 0c. Taunt mode/Easter eggs, like Sbaitso fucks with the user, screen effects, sound fx, etc.
// 0d. Shader support, class CRT-style of course.
// 0e. Audio shape global commands: .pitch, .volume, .tone, .speed etc.
// 0f. Phenome support: <<~CHAxWAAWAA>>
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
            @panic("You leak memory!");
        }
    }

    c.SetConfigFlags(c.FLAG_VSYNC_HINT | c.FLAG_WINDOW_RESIZABLE);
    c.InitWindow(WIN_WIDTH, WIN_HEIGHT, "Dr. Sbaitso Reborn");
    c.InitAudioDevice();
    c.SetTargetFPS(60);
    defer c.CloseWindow();

    loadFont();
    defer c.UnloadFont(dosFont);

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

    // Testing scroll buffer lines
    const lines: []const [:0]const u8 = &.{
        "Please enter your name ...Ralph",
        "HELLO RALPH,  MY NAME IS DOCTOR SBAITSO.",
        "",
        "I AM HERE TO HELP YOU.",
        "SAY WHATEVER IS IN YOUR MIND FREELY,",
        "OUR CONVERSATION WILL BE KEPT IN STRICT CONFIDENCE.",
        "MEMORY CONTENTS WILL BE WIPED OFF AFTER YOU LEAVE,",
        "",
        "SO, TELL ME ABOUT YOUR PROBLEMS.",
        "",
        "",
    };

    for (lines) |l| {
        try scrollBuffer.append(scrollEntry{
            .entryType = .sbaitso,
            .line = l,
        });
    }

    scrollBufferRegion.start = 0;
    scrollBufferRegion.end = scrollBuffer.items.len - 1;

    defer scrollBuffer.deinit();

    // Kick off main consumer + speech consumer threads.
    const mainDispatchConsumerHandle = try std.Thread.spawn(
        .{},
        mainConsumer,
        .{},
    );
    const speechConsumerHandle = try std.Thread.spawn(
        .{},
        speechConsumer,
        .{},
    );

    while (!c.WindowShouldClose()) {
        try update();
        draw();
    }

    if (started) {
        // Ask consumer threads nicely to shut down.
        // TODO: request shut down of main dispatch consumer.
        // Currently it will hang.
        std.Thread.join(mainDispatchConsumerHandle);
        try dispatchToSpeechThread(.{"<quit>"});
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

fn speechConsumer() !void {
    std.log.debug("speechConsumer thread started...", .{});

    while (true) {
        const container = speechQueue.dequeue();

        switch (container) {
            .one => |val| {
                if (std.mem.eql(u8, "<quit>", val)) {
                    std.log.debug("speechConsumer <quit> requested...", .{});
                    break;
                }
                try speak(val);
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

fn mainConsumer() !void {
    std.log.debug("main dispatch consumer thread started...", .{});

    while (true) {
        const container = mainQueue.dequeue();

        switch (container) {
            .one => |val| {
                if (std.mem.eql(u8, "<quit>", val)) {
                    std.log.debug("main dispatch consumer <quit> requested...", .{});
                    break;
                }
                // TODO: Do work on one item.
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

    std.log.debug("main dispatch consumer thread finished...", .{});
}

// fn start() !void {
//     // Currently this just spawns a thread.
//     // TODO: spawn a dedicated thread that is listening for speak commands as a queue.
//     // just keep consuming off the queue as needed.
//     thHandle = try std.Thread.spawn(std.Thread.SpawnConfig{
//         .allocator = allocator,
//     }, asyncChat, .{});
// }

// fn asyncChat() !void {
//     try speak("Doctor Sbaitso, by <<P0<<S0 Creative Fucken Labs >>>>. <<D1 Please enter your name.>>");

//     // Single line.
//     try speak("Hello " ++ PatientNameToken ++ ", my name is Doctor Sbaitso.");

//     // Collection of lines.
//     try speakMany(&.{
//         "I am here to help you.",
//         "Say whatever is in your mind freely,",
//         "Our conversation will be kept in strict confidence.",
//         "Memory contents will be wiped off after you leave,",
//         "So, tell me about your problems.",
//     });

//     cursorEnabled.store(true, .seq_cst);

//     try speakMany(&.{
//         "<<P0 you little bitch>>",
//     });
// }

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

fn update() !void {
    updateCursor();

    switch (notes.state) {
        .sbaitso_init => {
            if (!started and c.IsKeyDown(c.KEY_SPACE)) {
                started = true;
                notes.state = .sbaitso_announce;
            }
        },
        .sbaitso_announce => {
            //try start();
            notes.state = .sbaitso_render_reply;
        },
        .sbaitso_ask_name => {},
        .user_give_name => {},
        .sbaitso_intro => {},
        .user_await_input => {},
        .sbaitso_think_of_reply => {},
        .sbaitso_render_reply => {
            if (c.IsKeyReleased(c.KEY_SPACE)) {
                try sendOneLine();
            }
        },
        .sbaitso_quit => {},
        .sbaitso_parity_err => {},
        .sbaitso_new_session => {},
        .sbaitso_help => {},
    }
}

fn sendOneLine() !void {
    std.log.debug("ptr => {*}", .{parsedJSON.value.actions[7].output[0]});
    const actions = parsedJSON.value.actions;
    for (actions) |a| {
        if (std.mem.eql(u8, a.action, "<enter>")) {
            const r = c.GetRandomValue(0, @intCast(a.output.len - 1));
            const speechLine = a.output[@intCast(r)];

            try dispatchToSpeechThread(.{speechLine});
            break;
        }
    }
}

fn updateCursor() void {
    cursorAccumulator += c.GetFrameTime();
    if (cursorAccumulator >= cursorWaitThresholdMs) {
        cursorBlink = !cursorBlink;
        cursorAccumulator = 0;
    }
}

fn draw() void {
    c.BeginDrawing();
    defer c.EndDrawing();

    if (started) {
        c.ClearBackground(notes.bgColor);
        drawBanner();
        //drawConversation();
        drawScrollBuffer();
        drawCursor();

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

fn drawScrollBuffer() void {
    const ySpacing = 20;
    const maxRenderableLines = 20;

    const reg = scrollBufferRegion;
    var i: usize = reg.start;
    var linesRendered: usize = 0;

    while (i < reg.end and linesRendered <= maxRenderableLines) : (i += 1) {
        const entry = &scrollBuffer.items[i];
        switch (entry.entryType) {
            .sbaitso => {
                c.DrawTextEx(dosFont, entry.line, .{ .x = 10, .y = @floatFromInt(150 + (linesRendered * ySpacing)) }, 18, 0, c.WHITE);
                linesRendered += 1;
            },
            .user => {
                c.DrawTextEx(dosFont, entry.line, .{ .x = 10, .y = @floatFromInt(150 + (linesRendered * ySpacing)) }, 18, 0, c.YELLOW);
                linesRendered += 1;
            },
            else => {},
        }
    }

    // TODO: always draw cursor at the last possible line.
}

fn drawCursor() void {
    const isEnabled = cursorEnabled.load(.seq_cst);

    if (isEnabled) {
        c.DrawTextEx(dosFont, ">", .{ .x = 2, .y = 450 }, 18, 0, c.WHITE);
    }
    if (isEnabled and cursorBlink) {
        c.DrawTextEx(dosFont, "_", .{ .x = 2 + 18, .y = 450 }, 18, 0, c.WHITE);
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
        " 0123456789!@#$%^&*()/<>\\:.,_+-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ║╔═╗─╚═╝╟╢",
        &cpCnt,
    );

    // Load Font from TTF font file with generation parameters
    // NOTE: You can pass an array with desired characters, those characters should be available in the font
    // if array is NULL, default char set is selected 32..126
    dosFont = c.LoadFontEx("resources/fonts/MorePerfectDOSVGA.ttf", 18, cp, cpCnt);
}
