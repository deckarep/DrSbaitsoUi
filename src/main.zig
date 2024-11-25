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
pub const c = @import("c_defs.zig").c;

const WIN_WIDTH = 1280;
const WIN_HEIGHT = 786;
const BGColor = hexToColor(0x0000AAFF);
const SbaitsoPath = "/Users/deckarep/Desktop/Dr. Sbaitso Reborn/";

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const DrNotes = struct {
    patientName: []const u8 = "Ralph",
};

const PatientNameToken = "$$patientName$$";

var notes: DrNotes = undefined;

pub fn main() !void {
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            @panic("You leak memory!");
        }
    }
    std.log.debug("clr => {any}", .{BGColor});

    c.SetConfigFlags(c.FLAG_VSYNC_HINT | c.FLAG_WINDOW_RESIZABLE);
    c.InitWindow(WIN_WIDTH, WIN_HEIGHT, "Dr. Sbaitso Reborn");
    c.InitAudioDevice();
    c.SetTargetFPS(60);

    notes = .{};

    try std.posix.chdir(SbaitsoPath);

    // Single line.
    try speak("Hello $$patientName$$, my name is Doctor Sbaitso.");

    // Collection of lines.
    try speakMany(&.{
        "I am here to help you.",
        "Say whatever is in your mind freely,",
        "Our conversation will be kept in strict confidence.",
        "Memory contents will be wiped off after you leave,",
        "So, tell me about your problems.",
    });

    while (!c.WindowShouldClose()) {
        update();
        draw();
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

fn speak(msg: []const u8) !void {
    try speakMany(&.{msg});
}

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

fn update() void {}

fn draw() void {
    c.BeginDrawing();
    defer c.EndDrawing();
    c.ClearBackground(BGColor);

    c.DrawFPS(10, 10);
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

//   .write('╔══════════════════════════════════════════════════════════════════════════════╗\n')
//     .write('║ Sound Blaster              ').yellow().write('D R    S B A I T S O').white().write('                 version 2.20 ║\n')
//     .write('╟──────────────────────────────────────────────────────────────────────────────╢\n')
//     .write('║                 ').green().write('(c) Copyright Creative Labs, Inc. 1992,').white().write('  all rights reserved ║\n')
//     .write('╚══════════════════════════════════════════════════════════════════════════════╝\n');
// }

//    await say(` HELLO ${name},  MY NAME IS DOCTOR SBAITSO.\n`);
//     ansi.write('\n');
//     await say(' I AM HERE TO HELP YOU.\n');
//     await say(' SAY WHATEVER IS IN YOUR MIND FREELY,\n');
//     await say(' OUR CONVERSATION WILL BE KEPT IN STRICT CONFIDENCE.\n');
//     await say(' MEMORY CONTENTS WILL BE WIPED OFF AFTER YOU LEAVE,\n');
//     ansi.write('\n');
//     await say(' SO, TELL ME ABOUT YOUR PROBLEMS.');
//     ansi.write('\n\n');
