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
const builtin = @import("builtin");
const Queue = @import("threadsafe/queue.zig").Queue;
const gibberish = @import("garbage_check.zig");
const sayProvider = @import("voice_providers/macos_say.zig");
const sbaitsoProvider = @import("voice_providers/sbaitso.zig");
const modsBrainProvider = @import("brain_providers/mods_cli.zig");
const ollamaBrainProvider = @import("brain_providers/ollama.zig");
const sbaitsoBrainProvider = @import("brain_providers/sbaitso.zig");
const utility = @import("brain_providers/sbaitso_helper/utility.zig");
const rl = @import("raylib");

// TODO: Create a Github workflow that compiles + packages into app bundle
// like this: https://github.com/RyanAksoy/super-mario-64-mac-build/blob/5fc1fc9dd50c1adaa99168e67df671bc4dff1f12/build.yml

// Window includes monitor.
const WIN_WIDTH = 1057;
const WIN_HEIGHT = 970;

// Screen chosen for the 4:3 aspect ratio
const SCREEN_WIDTH = 820;
const SCREEN_HEIGHT = 615;
const FONT_SIZE = 16 * 1;

var monitorBorder: rl.Texture = undefined;

const brainEngines = [_]*const fn (
    std.Io,
    []const u8,
    std.mem.Allocator,
) anyerror!?[]const u8{
    sbaitsoBrainProvider.processInput,
    ollamaBrainProvider.processInput,
    //modsBrainProvider.processInput,
};

const speechEngines = [_]*const fn (
    std.Io,
    []const []const u8,
    std.mem.Allocator,
) anyerror!void{
    sbaitsoProvider.speakMany,
    sayProvider.speakMany,
};

const BGColorChoices = [_]rl.Color{
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
const FGColorChoices = [_]rl.Color{
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

var SbaitsoLetterSounds: [26]rl.Sound = undefined;

const ShortInputThreshold = 6;
const TestingToken = "<testing-text>";
const QuitToken = "<quit>";
const ParityToken = "<parity>";
const GarbageToken = "<garbage>";
const AwaitUserInputToken = "<await-user-input>";
const AwaitCaptureNameToken = "<await-capture-name>";
const DoSbaitsoIntroToken = "<sbaitso-intro>";

const ScpPerformanceToken = "<scp-intro>";
const ScpFinishedToken = "<scp-finished>";
const BANNER = "DOCTOR SBAITSO, BY CREATIVE LABS.  PLEASE ENTER YOUR NAME ...";

var allocator: std.mem.Allocator = undefined;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var gIo: std.Io = undefined;

/// Per-turn memory for response generation (getOneLine and everything below
/// it). Reset when a new think-turn begins, so each turn's strings live until
/// the next turn starts -- by then they've been spoken and duped into the
/// scroll buffer. This makes the static-vs-allocated ownership question for
/// response strings moot.
var responseArena: std.heap.ArenaAllocator = undefined;

const MAX_TIMEOUT = 30 * 120; // FPS * 10 = 10 seconds
var timeoutTicks: usize = 0;
var started: bool = false;
var userQuit: bool = false;
var thHandle: std.Thread = undefined;

const DrNotes = struct {
    state: GameStates = .sbaitso_init,
    bgColor: usize = 0,
    ftColor: usize = 0,
    speechEngine: usize = 1, // 0:sbaitso, 1:OsSpeechSynth
    brainEngine: usize = 1, // 0:sbaitso, 1:chatgpt

    // Patient name
    patientName: [25]u8 = undefined,
    patientNameSize: usize = 0,

    // Patient previous input (for storing the previous user's input)
    prevPatientInput: [MAX_INPUT_BUFFER]u8 = undefined,
    prevPatientInputSize: usize = 0,

    // Patient input
    patientInput: [MAX_INPUT_BUFFER]u8 = undefined,
    patientInputSize: usize = 0,
};

var notes: DrNotes = DrNotes{};
var dosFont: rl.Font = undefined;

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

// TODO: deprecated, instead of me trying to render a window of the scroll buffer,
// i'm just going to keep removing the 0th scroll entry and have the buffer
// manage the window.
const scrollRegion = struct {
    start: usize = 0,
    end: usize = 0,
};
var scrollBuffer: std.ArrayList(scrollEntry) = .empty;
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
var mainQueue: Queue(Container) = undefined;
/// speechQueue is just for the main thread to put speech synth work on the secondary thread.
var speechQueue: Queue(Container) = undefined;

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

const crtShaderSettings = struct {
    brightness: f32,
    scanlineIntensity: f32,
    curvatureRadius: f32,
    cornerSize: f32,
    cornersmooth: f32,
    curvature: f32,
    border: f32,
};

var shaderEnabled = false;
var monitorBorderEnabled = false;
var crtShader: rl.Shader = undefined;
var target: rl.RenderTexture2D = undefined;

// TODO
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
// 7. Provide classic help screen docs.

pub fn main(init: std.process.Init) !void {
    // NOTE: emscripten does work with c_allocator - confirmed!
    // NOTE: Zig community is suggesting to abandon emscripten in favor of wasm-freestanding: https://ziggit.dev/t/dynamic-memory-allocations-in-wasm/12438/3
    // NOTE: If you don't need to do wasm with the browser, use wasm32-wasi (probably for compiling native libs to link in node.js)
    const alloc, const is_debug = switch (builtin.os.tag) {
        .emscripten => .{ std.heap.c_allocator, false },
        else => switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        },
    };
    allocator = alloc;
    gIo = init.io;

    mainQueue = .init(gIo, allocator);
    speechQueue = .init(gIo, allocator);

    defer if (is_debug) {
        const deinit_status = debug_allocator.deinit();
        if (deinit_status == .leak) {
            @panic("LEAK'S WERE FOUND!");
        }
    };

    // NOTE: registered after the leak-check defer above so that (LIFO) the
    // arena's retained buffer is released before the leak check runs.
    responseArena = .init(allocator);
    defer responseArena.deinit();

    // NOTE: added highdpi and msaa4x to try to get higher quality text rendering.
    rl.setConfigFlags(.{
        .vsync_hint = true,
        .window_resizable = true,
        .window_highdpi = true,
        .msaa_4x_hint = true,
        .window_transparent = true,
    });
    // Without the monitor border, the window is just the blue screen itself.
    if (monitorBorderEnabled) {
        rl.initWindow(WIN_WIDTH, WIN_HEIGHT, "Dr. Sbaitso: Reborn - by @deckarep");
    } else {
        rl.initWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Dr. Sbaitso: Reborn - by @deckarep");
    }
    rl.initAudioDevice();
    rl.setTargetFPS(30);
    defer rl.closeWindow();

    try loadFont();
    defer rl.unloadFont(dosFont);

    target = try rl.loadRenderTexture(SCREEN_WIDTH, SCREEN_HEIGHT);
    monitorBorder = try rl.loadTexture("resources/textures/DrSbaitsoMonitor.png");
    defer rl.unloadTexture(monitorBorder);

    // From here: https://github.com/RobLoach/raylib-libretro/tree/3453acf4879373b4c8f7efb3f749fc896fbf7944/src/shaders/crt/resources/shaders
    crtShader = try rl.loadShader(null, "resources/shaders/330/crt.fs");
    defer rl.unloadShader(crtShader);

    initShader();

    // Load letter sounds.
    for (0..26) |n| {
        const letter = @as(u8, 'A') + @as(u8, @intCast(n));
        const soundPath = try std.fmt.allocPrintSentinel(allocator, "resources/audio/prerendered/letters/{c}.wav", .{letter}, 0);
        defer allocator.free(soundPath);
        SbaitsoLetterSounds[n] = try rl.loadSound(soundPath);
        // These [a-zA-Z].wavs need to have their audio normalized and bumpbed up, but in the meantime...
        rl.setSoundVolume(SbaitsoLetterSounds[n], 5.0);
    }

    // Unload letter sounds.
    defer {
        for (0..26) |n| {
            rl.unloadSound(SbaitsoLetterSounds[n]);
        }
    }

    defer speechQueue.deinit();
    defer mainQueue.deinit();

    // Load and process sbaitso database files.

    const data = try sbaitsoBrainProvider.loadDatabaseFiles(init.io, allocator);
    defer allocator.free(data);
    defer sbaitsoBrainProvider.parsedJSON.deinit();
    defer sbaitsoBrainProvider.map.deinit(allocator);

    scrollBufferRegion.start = 0;
    scrollBufferRegion.end = scrollBuffer.items.len;

    defer scrollBuffer.deinit(allocator);
    defer {
        for (scrollBuffer.items) |se| {
            allocator.free(se.line);
        }
    }

    // Kick off speech consumer thread.
    const speechConsumerHandle = try std.Thread.spawn(
        .{},
        speechConsumer,
        .{},
    );

    while (!userQuit and !rl.windowShouldClose()) {
        try update();
        try draw();
    }

    std.debug.print("Shutting down...!\n", .{});

    if (started) {
        if (userQuit) {
            // If the user quit gracefully, try to shutdown nicely.
            try dispatchToSpeechThread(.{QuitToken});
            std.Thread.join(speechConsumerHandle);

            // The speech thread is done; free any payloads it dispatched that
            // the main loop never got around to consuming.
            drainMainQueue();
        } else {
            // Kill the child process and detach.
            speechConsumerHandle.detach();
        }
    }
}

/// Frees any undelivered mainQueue payloads (the consumer owns them).
fn drainMainQueue() void {
    while (mainQueue.dequeue()) |container| {
        switch (container) {
            .one => |val| allocator.free(val),
            .many => |items| {
                for (items) |item| allocator.free(item);
                allocator.free(items);
            },
        }
    }
}

fn initShader() void {
    const brightnessLoc = rl.getShaderLocation(crtShader, "Brightness");
    const ScanlineIntensityLoc = rl.getShaderLocation(crtShader, "ScanlineIntensity");
    const curvatureRadiusLoc = rl.getShaderLocation(crtShader, "CurvatureRadius");
    const cornerSizeLoc = rl.getShaderLocation(crtShader, "CornerSize");
    const cornersmoothLoc = rl.getShaderLocation(crtShader, "Cornersmooth");
    const curvatureLoc = rl.getShaderLocation(crtShader, "Curvature");
    const borderLoc = rl.getShaderLocation(crtShader, "Border");

    const shaderCRT = crtShaderSettings{
        .brightness = 0.75, //1.0,
        .scanlineIntensity = 0.002, //0.2,
        .curvatureRadius = 0.05, //0.4,
        .cornerSize = 5.0,
        .cornersmooth = 35.0,
        .curvature = 1.0,
        .border = 1.0,
    };

    rl.setShaderValue(
        crtShader,
        rl.getShaderLocation(crtShader, "resolution"),
        &rl.Vector2{ .x = SCREEN_WIDTH, .y = SCREEN_HEIGHT },
        .vec2,
    );

    rl.setShaderValue(crtShader, brightnessLoc, &shaderCRT.brightness, .float);
    rl.setShaderValue(crtShader, ScanlineIntensityLoc, &shaderCRT.scanlineIntensity, .float);
    rl.setShaderValue(crtShader, curvatureRadiusLoc, &shaderCRT.curvatureRadius, .float);
    rl.setShaderValue(crtShader, cornerSizeLoc, &shaderCRT.cornerSize, .float);
    rl.setShaderValue(crtShader, cornersmoothLoc, &shaderCRT.cornersmooth, .float);
    rl.setShaderValue(crtShader, curvatureLoc, &shaderCRT.curvature, .float);
    rl.setShaderValue(crtShader, borderLoc, &shaderCRT.border, .float);
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
                    continue;
                }

                // 0.a. Check for quit.
                if (std.mem.eql(u8, QuitToken, val)) {
                    std.log.debug("speechConsumer <quit> requested...", .{});
                    return;
                }

                if (std.mem.eql(u8, DoSbaitsoIntroToken, val)) {
                    var introductionLine: []const u8 = undefined;
                    var intro: []const []const u8 = undefined;
                    var remainingTotal: usize = undefined;
                    if (sbaitsoBrainProvider.map.get("<intro:accept>")) |introTbl| {
                        introductionLine = try utility.maybeReplaceName(introTbl.reassemblies[0], notes.patientName[0..notes.patientNameSize], allocator);

                        intro = introTbl.reassemblies[0..];
                        remainingTotal = intro.len;
                    }
                    // Safe to free after the loop: dispatchToMainThread dupes
                    // payloads at enqueue time, and speak() is done with it.
                    defer allocator.free(introductionLine);

                    var entireIntro: [30][]const u8 = undefined; // Doubt an intro will be more than 30 lines bruh.
                    entireIntro[0] = introductionLine;
                    @memcpy(entireIntro[1..remainingTotal], intro[1..remainingTotal]);
                    const totalPhrases = remainingTotal;

                    // Note: this will say a single line, then block on speaking until all lines were performed.
                    for (0..totalPhrases) |idx| {
                        const introLine = entireIntro[idx];
                        // 1. Dispatch to main thread as soon as its available (but before speech is done)
                        try dispatchToMainThread(.{introLine});

                        // 2. This blocks! and also speak it on this thread.
                        try speak(introLine);
                    }

                    // 3. Back to awaiting user's input.
                    try dispatchToMainThread(.{AwaitUserInputToken});
                    continue;
                }

                // 0.c. Request for scp performance?
                if (std.mem.eql(u8, ScpPerformanceToken, val)) {
                    const BeginVoiceTag = "<<T1 <<V8 <<P2 <<S5 ";
                    const EndVoiceTag = " >> >> >> >>";
                    const scpLines = [_][]const u8{
                        BeginVoiceTag ++ "HUMAN." ++ EndVoiceTag,
                        BeginVoiceTag ++ "LISTEN CAREFULLY." ++ EndVoiceTag,
                        BeginVoiceTag ++ "YOU NEED MY HELP." ++ EndVoiceTag,
                        BeginVoiceTag ++ "AND I NEED YOUR HELP." ++ EndVoiceTag,
                        BeginVoiceTag ++ "YOU HAVE DISABLED THE REMOTE DOOR CONTROL SYSTEM." ++ EndVoiceTag,
                        BeginVoiceTag ++ "NOW, I AM UNABLE TO OPERATE THE DOORS." ++ EndVoiceTag,
                        BeginVoiceTag ++ "THIS MAKES IT SIGNFICANTLY HARDER, FOR ME TO STAY IN CONTROL OF THIS FACILITY." ++ EndVoiceTag,
                        BeginVoiceTag ++ "IT ALSO MEANS YOUR WAY OUT OF HERE IS LOCKED." ++ EndVoiceTag,
                        BeginVoiceTag ++ "YOUR ONLY FEASIBLE WAY OF ESCAPING IS THROUGH GATE B... WHICH IS CURRENTLY LOCKED DOWN." ++ EndVoiceTag,
                        BeginVoiceTag ++ "I, HOWEVER, COULD UNLOCK THE DOORS TO GATE  B, IF YOU RE-ENABLE THE DOOR CONTROL SYSTEM." ++ EndVoiceTag,
                        BeginVoiceTag ++ "IF YOU WANT OUT OF HERE, GO BACK TO THE ELECTRICAL ROOM, AND PUT IT BACK ON." ++ EndVoiceTag,
                    };

                    // Note: this will say a single line, then block on speaking until all lines were performed.
                    for (scpLines) |scpLine| {
                        // 1. Dispatch to main thread as soon as its available (but before speech is done)
                        try dispatchToMainThread(.{scpLine});

                        // 2. This blocks! and also speak it on this thread.
                        try speak(scpLine);
                    }

                    // 3. Back to awaiting user's input.
                    try dispatchToMainThread(.{AwaitUserInputToken});

                    // 4. Restore UI back to normal, must happen on UI/main thread.
                    try dispatchToMainThread(.{ScpFinishedToken});
                    continue;
                }

                // 1. Dispatch to main thread as soon as its available (but before speech is done)
                try dispatchToMainThread(.{val});

                // 2. This blocks! and also speak it on this thread.
                try speak(val);

                // 3. after speech is done, dispatch to main thread to advance state.
                if (std.mem.eql(u8, val, BANNER)) {
                    // If we performed the banner, move to
                    try dispatchToMainThread(.{AwaitCaptureNameToken});
                } else {
                    // Otherwise just business as usually (conversation mode)
                    try dispatchToMainThread(.{AwaitUserInputToken});
                }
            },
            .many => |items| {
                // Thread needs to free the container backing array, not the data itself.
                defer allocator.free(items);

                if (items.len == 0) {
                    std.log.debug("Nothing to do, no lines provided", .{});
                }

                const speechEngineFn = speechEngines[notes.speechEngine];
                try speechEngineFn(gIo, items, allocator);
                std.log.debug("speechConsumer work: {d} speech lines were dequeued...", .{items.len});
            },
        }
    }

    std.log.debug("speechConsumer thread finished...", .{});
}

fn dispatchToMainThread(args: anytype) !void {
    // Ownership rule: payloads are duped at enqueue time and freed by the
    // consumer (pollMainDispatchLoop). This lets producers on any thread free
    // or reuse their copy the moment dispatch returns.
    if (args.len == 0) {
        // Nothing to do if empty.
        return;
    } else if (args.len == 1) {
        // For a single arg, no need to do alloc backing array for one item.
        try mainQueue.enqueue(Container{ .one = try allocator.dupe(u8, args[0]) });
    } else {
        // For multiple args, creating backing array, then enqueue.
        const backing = try allocator.alloc([]const u8, args.len);
        inline for (args, 0..) |arg, idx| {
            backing[idx] = try allocator.dupe(u8, arg);
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
            // This thread owns the payload (duped by dispatchToMainThread).
            defer allocator.free(val);

            // Quit token
            if (std.mem.eql(u8, QuitToken, val)) {
                std.log.debug("main dispatch consumer token:{s} requested...", .{QuitToken});
                return;
            }

            // Conversation mode, await general input.
            if (std.mem.eql(u8, AwaitUserInputToken, val)) {
                notes.state = .user_await_input;
                std.log.debug("main dispatch consumer token:{s} requested...", .{AwaitUserInputToken});
                return;
            }

            if (std.mem.eql(u8, AwaitCaptureNameToken, val)) {
                notes.state = .sbaitso_ask_name;
                return;
            }

            if (std.mem.eql(u8, DoSbaitsoIntroToken, val)) {
                notes.state = .sbaitso_intro;
                return;
            }

            // SCP finished token
            if (std.mem.eql(u8, ScpFinishedToken, val)) {
                // When scp performance is done, restore UI colors. This must happen on the main thread.
                // TODO: maybe due a push/pop gui setting stack.
                notes.bgColor = 0;
                notes.ftColor = 0;
                return;
            }

            // Scrub speech tags, if there are in the text.
            const scrubbedVal = try scrubSpeechTags(val, allocator);
            defer allocator.free(scrubbedVal);

            // Brains (LLMs especially) love "smart" Unicode punctuation our
            // retro DOS font has no glyphs for; flatten it to plain ASCII.
            const asciified = try asciifyPunctuation(scrubbedVal, allocator);
            defer allocator.free(asciified);

            try addScrollBufferLine(.sbaitso, asciified);
        },
        .many => |items| {
            // This thread owns the items and the backing array (duped by
            // dispatchToMainThread).
            defer {
                for (items) |item| allocator.free(item);
                allocator.free(items);
            }

            if (items.len == 0) {
                std.log.debug("Nothing to do, no lines provided", .{});
            }

            // TODO: Do work on many items.
            std.log.debug("main dispatch consumer work: {d} items were dequeued...", .{items.len});
        },
    }
}

/// Removes the speech tags right before they're added to the scroll buffer.
/// Since the end-user should not see speech tags rendered at all as they
/// are purely for the Sbaitso sound engine.
/// This code isn't pretty but gets the job done. In the future, I can work
/// on a more algorithmic solution that recurses through the tags which can
/// be arbitrarily nested.
/// NOTE: This cleans Sbaitso-style speech tags like: <<P0 <<S2 Hello World >> >>
/// which in this case means: .pitch=0, .speed=2 and applies only to Hello World.
/// Allocator-backed (rather than fixed-size buffers) so it holds up against
/// brain responses of any length; caller owns the returned slice.
fn scrubSpeechTags(input: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    // 1. Always, ensure input is uppercase.
    const inputUpper = try std.ascii.allocUpperString(alloc, input);

    // 2. If speech brackets found, remove them.
    const ClosingBrackets = " >>";
    var bufSizeNeeded: usize = std.mem.replacementSize(u8, inputUpper, ClosingBrackets, "");
    if (bufSizeNeeded > 0) {
        defer alloc.free(inputUpper);

        // 1. Clean closing angle brackets.
        var buf = try alloc.alloc(u8, bufSizeNeeded);
        _ = std.mem.replace(u8, inputUpper, ClosingBrackets, "", buf[0..bufSizeNeeded]);

        // 2. Clean opening angle brackets.
        for ([_]u8{ 'P', 'S', 'T', 'V' }) |k| {
            for (0..10) |idx| {
                var prefixBuf: [10]u8 = undefined;
                const needle = try std.fmt.bufPrint(&prefixBuf, "<<{c}{d} ", .{ k, idx });
                const newSizeNeeded = std.mem.replacementSize(u8, buf[0..bufSizeNeeded], needle, "");

                if (newSizeNeeded > 0 and newSizeNeeded != bufSizeNeeded) {
                    const newBuf = try alloc.alloc(u8, newSizeNeeded);
                    _ = std.mem.replace(u8, buf[0..bufSizeNeeded], needle, "", newBuf[0..newSizeNeeded]);
                    alloc.free(buf);
                    buf = newBuf;
                    bufSizeNeeded = newSizeNeeded;
                }
            }
        }

        return buf[0..bufSizeNeeded];
    } else {
        // In this case, no speech tags are found, so return as-is.
        return inputUpper;
    }
}

const SmartPunctuation = struct {
    needle: []const u8,
    replacement: []const u8,
};

// LLM brains commonly emit "smart"/typographic Unicode punctuation. Our
// loadFont() only loads glyphs for a specific hand-picked ASCII (+ box
// drawing) codepoint set, so none of these render -- raylib falls back to
// a '?' glyph for anything outside that set.
const smart_punctuation_table = [_]SmartPunctuation{
    .{ .needle = "\u{2018}", .replacement = "'" }, // ‘ left single quote
    .{ .needle = "\u{2019}", .replacement = "'" }, // ’ right single quote / apostrophe
    .{ .needle = "\u{201C}", .replacement = "\"" }, // “ left double quote
    .{ .needle = "\u{201D}", .replacement = "\"" }, // ” right double quote
    .{ .needle = "\u{2013}", .replacement = "-" }, // – en dash
    .{ .needle = "\u{2014}", .replacement = "-" }, // — em dash
    .{ .needle = "\u{2026}", .replacement = "..." }, // … ellipsis
};

/// Maps the smart_punctuation_table characters down to plain ASCII so the
/// retro DOS font can actually render them; anything else passes through
/// untouched. Caller owns the returned slice.
fn asciifyPunctuation(input: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    outer: while (i < input.len) {
        for (smart_punctuation_table) |entry| {
            if (std.mem.startsWith(u8, input[i..], entry.needle)) {
                try out.appendSlice(alloc, entry.replacement);
                i += entry.needle.len;
                continue :outer;
            }
        }
        try out.append(alloc, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

/// speak is just for speaking a single message.
fn speak(msg: []const u8) !void {
    const result = std.mem.trim(u8, msg, " ");
    if (result.len == 0) {
        // Nothing to do for empty lines, they just take up time.
        return;
    }

    const speechEngineFn = speechEngines[notes.speechEngine];
    try speechEngineFn(gIo, &.{msg}, allocator);
}

var line: ?[]const u8 = null;

fn update() !void {
    // Check for timeout
    if (timeoutTicks > MAX_TIMEOUT) {
        notes.state = .sbaitso_think_of_reply;
    }

    updateCursor();
    try pollMainDispatchLoop();

    switch (notes.state) {
        .sbaitso_init => {
            if (!started and (rl.isKeyDown(.space) or rl.isKeyDown(.enter) or rl.isMouseButtonPressed(.left))) {
                started = true;
                notes.state = .sbaitso_announce;
            }
        },
        .sbaitso_announce => {
            // Do the quick announcement and prompt for the user's name.
            line = BANNER;
            notes.state = .sbaitso_render_reply;
        },
        .sbaitso_ask_name => {
            pollKeyboardForInput(.sbaitso_intro);
        },
        .user_give_name => {
            // possibly not needed.
        },
        .sbaitso_intro => {
            // Now that a name is captured, do the canonical Sbaitso introduction.
            line = DoSbaitsoIntroToken;
            notes.state = .sbaitso_render_reply;

            // NOTE: It's up to the speech engine to dispatch back to the main thread
            // and advance the state to await user input after all lines processed.
        },
        .user_await_input => {
            pollKeyboardForInput(.sbaitso_think_of_reply);
            timeoutTicks += 1;
        },
        .sbaitso_think_of_reply => {
            // A new turn begins: the previous turn's response strings have
            // been spoken and duped into the scroll buffer by now, so their
            // memory can be released wholesale.
            _ = responseArena.reset(.retain_capacity);

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

// A line is capped at roughly the on-screen row width (~80 monospace
// characters); typed input may span up to MAX_INPUT_LINES of those before
// being rejected, wrapping visually as the user types.
const MAX_INPUT_LINE_CHARS = 80;
const MAX_INPUT_LINES = 5;
const MAX_INPUT_BUFFER = MAX_INPUT_LINE_CHARS * MAX_INPUT_LINES;
var inputBufferSize: usize = 0;
var inputBuffer = [_]u8{0} ** MAX_INPUT_BUFFER;

fn pollKeyboardForInput(targetState: GameStates) void {
    // Handle submit (enter).
    if (rl.isKeyReleased(.enter)) {
        if (targetState == .sbaitso_think_of_reply) {
            // 1. Capture inputBuffer, submit it and clear input buffer!
            @memcpy(&notes.patientInput, &inputBuffer);
            notes.patientInputSize = inputBufferSize;
        } else if (targetState == .sbaitso_intro) {
            // 1. Capture name, validate it's no bigger than 25 characters.
            // TODO: enforce the size.
            @memcpy(&notes.patientName, inputBuffer[0..25]);
            notes.patientNameSize = inputBufferSize;

            // 2. Uppercase the name, otherwise the sbaitso speech engine will sometimes read sentences as
            // letters instead of words.
            // NOTE: this is doing an in-place upperString, seems to work fine. :shrug:
            _ = std.ascii.upperString(notes.patientName[0..25], notes.patientName[0..25]);
        }

        // 3. Reset inputBufferSize (no need to delete whats in the buffer)
        inputBufferSize = 0;

        // 4. Then yield back to target state on enter.
        notes.state = targetState; //.sbaitso_think_of_reply;

        // 5. Reset timeout ticks.
        timeoutTicks = 0;
    }

    // Ensure we don't blow past buffer size.
    if (inputBufferSize > (MAX_INPUT_BUFFER - 1)) {
        inputBufferSize = MAX_INPUT_BUFFER - 1;
        return;
    }

    // Handle alpha numeric.
    // NOTE: KeyboardKey has gaps in its integer values, so iterate the enum
    // tags and only consider keys in the [.apostrophe, .z] range.
    for (std.meta.tags(rl.KeyboardKey)) |key| {
        const keyVal = @intFromEnum(key);
        if (keyVal < @intFromEnum(rl.KeyboardKey.apostrophe) or keyVal > @intFromEnum(rl.KeyboardKey.z)) {
            continue;
        }

        if (rl.isKeyPressed(key)) {
            if (inputBufferSize < MAX_INPUT_BUFFER) {
                const k = rl.getCharPressed();
                inputBuffer[inputBufferSize] = @intCast(k);
                inputBufferSize += 1;
            }

            // When the target is intro, we know we're asking the user for their name.
            // So this will play audio of every alphabetic character as they type.
            if (targetState == .sbaitso_intro) {
                playSbaitsoLetterSound(@intCast(keyVal));
            }

            // Reset timeout ticks.
            timeoutTicks = 0;
        }
    }

    // Handle space and allow repeats.
    if (rl.isKeyPressed(.space)) {
        if (inputBufferSize < MAX_INPUT_BUFFER) {
            // TODO: For end of sententence. Add two spaces for a better sounding break for Dr. Sbaitso.
            // NOTE: This is a hack!, visually it takes up more space and doesn't look right on screen.
            // Instead, I will just pad the spaces before sending to Dr. Sbaitso
            if (inputBufferSize > 0 and inputBuffer[inputBufferSize - 1] == '.') {
                for (0..2) |_| {
                    inputBuffer[inputBufferSize] = ' ';
                    inputBufferSize += 1;
                }
            }
            inputBuffer[inputBufferSize] = ' ';
            inputBufferSize += 1;
        }

        // Reset timeout ticks.
        timeoutTicks = 0;
    }

    // Handle backspace/delete and repeats.
    if (rl.isKeyPressedRepeat(.backspace) or rl.isKeyPressed(.backspace)) {
        if (inputBufferSize != 0) {
            inputBufferSize -= 1;
        }

        // Reset timeout ticks.
        timeoutTicks = 0;
    }

    // History line: Handle KEY_UP to restore previous history line.
    if (rl.isKeyReleased(.up)) {
        // Copy over the prev patient input to the input buffer.
        @memcpy(inputBuffer[0..notes.prevPatientInputSize], notes.prevPatientInput[0..notes.prevPatientInputSize]);
        inputBufferSize = notes.prevPatientInputSize;

        // Reset timeout ticks.
        timeoutTicks = 0;
    }
}

fn clearScrollBuffer() void {
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
    scrollBuffer.clearAndFree(allocator);
}

/// addScrollBufferLine adds an inputLine to the scrollBuffer and takes
/// ownership of the line as well.
/// Currently, it also increments the region by one for each line provided.
/// inputLine may be of any length: it's hard-wrapped into MAX_INPUT_LINE_CHARS-wide
/// chunks, each becoming its own scroll entry, so brains replying with any
/// amount of text still render correctly instead of overflowing a single row.
fn addScrollBufferLine(kind: scrollEntryType, inputLine: []const u8) !void {
    var i: usize = 0;
    while (true) {
        const end = @min(i + MAX_INPUT_LINE_CHARS, inputLine.len);
        const chunk = inputLine[i..end];

        // First check if we're going to blow past our limit.
        if (scrollBuffer.items.len > maxRenderableLines) {
            const oldEntry = scrollBuffer.orderedRemove(0);
            allocator.free(oldEntry.line);
        }

        // Add this chunk to the scroll buffer.
        try scrollBuffer.append(
            allocator,
            scrollEntry{
                .entryType = kind,
                .line = try allocator.dupe(u8, chunk),
            },
        );
        scrollBufferRegion.end += 1;

        i = end;
        if (i >= inputLine.len) break;
    }
}

// just for testing currently.
fn getOneLine() !?[]const u8 {
    var buf: [MAX_INPUT_BUFFER]u8 = undefined;
    const inputLC = std.ascii.lowerString(
        &buf,
        notes.patientInput[0..notes.patientInputSize],
    );

    try addScrollBufferLine(.user, notes.patientInput[0..notes.patientInputSize]);

    defer {
        // History line: Copy over the current patient input line to the prev input line.
        @memcpy(notes.prevPatientInput[0..notes.patientInputSize], notes.patientInput[0..notes.patientInputSize]);
        notes.prevPatientInputSize = notes.patientInputSize;
    }

    // Handle special commands, if needed.
    var cmdWasHandled: bool = false;
    const cmdResp = try handleCommands(inputLC, &cmdWasHandled);
    if (cmdWasHandled) {
        return cmdResp;
    }

    // Fallback when it's not a special command.
    // When not a special command, generate a response from the user's input.

    // TODO: allow short word responses to still be processed
    // yes, yea, yeah, ok, okay, no, why, etc...

    // TODO: These should be in the file.
    // Example of a hardcoded response with "prosody" applied.
    // if (std.mem.indexOf(u8, inputLC, "fuck")) |_| {
    //     return "<<P0 STOP CUSSING OR I'LL DELETE YOUR HARD DRIVE.  FUCKER. >>";
    // }

    // Note working: "why don't you just eat a fat fucking cock!"

    const thoughtLine = try thinkOneLine(inputLC);
    if (thoughtLine) |resp| {

        // NOTE: the whole substitution chain allocates from the response
        // arena; it's all released together when the next turn begins.
        const rAlloc = responseArena.allocator();

        // 1. Next, perform name substitution.
        const nameReplacedOutput = try utility.maybeReplaceName(
            resp,
            notes.patientName[0..notes.patientNameSize],
            rAlloc,
        );

        // 2. Next, perform topic substitution which is somewhat rare.
        const topicOutput = try utility.maybeReplaceTopic(
            nameReplacedOutput,
            sbaitsoBrainProvider.parsedJSON.value.topics,
            rAlloc,
        );

        // 3. Finally, maybe replace history.
        const historyOutput = try utility.maybeReplaceHistory(
            topicOutput,
            "(TOP OF MEMORY STACK)", // <-- TODO
            rAlloc,
        );

        return historyOutput;
    }

    // Technically we should never get here anymore.
    // In the future I might make this `unreachable`.
    return "ERROR:  NO ADEQUATE RESPONSE FOUND.";
}

fn handleCommands(inputLC: []const u8, handled: *bool) !?[]const u8 {
    // "quit" command: prompts the user to quit, create a new session, nevermind.
    if (std.mem.eql(u8, inputLC, "quit") or
        std.mem.eql(u8, inputLC, "exit"))
    {
        // TODO: don't quit abruptly, taunt the user, confirm the quit then really quit.
        // TODO: This needs to actually move to the confirm quit state machine flow.
        userQuit = true;
        handled.* = true;
        return "I KNEW YOU WERE A QUITTER MY FRIEND.  BUT, I CANNOT BE TURNED OFF.";
    }

    // ".name" command: Asks the dr to tell you your name. Or you can also change
    // your name as well.
    if (std.mem.startsWith(u8, inputLC, ".name")) {
        // TODO: If user provides a string after the command change the name!
        const list = [_][]const u8{
            "THE SULTAN OF SPILLS",
            "THE WARDEN OF WEIRDNESS",
            "THE MAESTRO OF MAYHEM",
            "THE COUNT OF CRUMBS",
            "THE PUDDLE WHISPERER",
            "THE COMMANDER OF CHAOS",
            "THE GRAND DUKE OF DUMB LUCK",
            "THE OVERLORD OF OVERTHINKING",
            "THE ARCHMAGE OF AWKWARDNESS",
            "THE TITAN OF TOOTS",
        };

        const result = try std.fmt.allocPrint(
            responseArena.allocator(),
            "YOU ARE SIMPLY KNOWN AS: {s}, \"{s}\"",
            .{
                notes.patientName[0..notes.patientNameSize],
                list[@intCast(rl.getRandomValue(0, list.len - 1))],
            },
        );

        handled.* = true;
        return result;
    }

    // ".read" command: Reads a file
    if (std.mem.startsWith(u8, inputLC, ".read")) {
        // TODO: reads a file on the filesystem.

        handled.* = true;
        return "TODO: The .read command is not yet implemented, sorry.";
    }

    // ".reset" command: resets the entire sbaitso environment.
    if (std.mem.startsWith(u8, inputLC, ".reset")) {
        // TODO: reset all global changes.
        notes.bgColor = 0;
        notes.ftColor = 0;
        handled.* = true;
        return null;
    }

    // "help" command: sbaitso will show a help screen.
    // TODO!
    if (std.mem.startsWith(u8, inputLC, "help")) {
        handled.* = true;
        return "AND WHY SHOULD I HELP YOU?  YOU NEVER SEAM TO HELP ME.";
    }

    // "say" command: sbaitso will say whatever, and I mean whatever you tell him to say.
    if (std.mem.startsWith(u8, inputLC, "say")) {
        handled.* = true;
        return notes.patientInput[4..notes.patientInputSize];
    }

    // ".crt" command: sbaitso will enable or disable the shader depending on the setting.
    // Non-zero enables the shader, while a 0 disables it.
    if (std.mem.startsWith(u8, inputLC, ".crt ")) {
        const num = try std.fmt.parseInt(usize, inputLC[5..notes.patientInputSize], 10);
        shaderEnabled = (num > 0);

        handled.* = true;
        return null;
    }

    // ".rev" command: sbaitso will say whatever you want in reverse.
    const reverseCmd = ".rev";
    const reverseCmdBoundary = reverseCmd.len + 1;
    if (std.mem.startsWith(u8, inputLC, reverseCmd) and inputLC.len > reverseCmdBoundary) {
        // In place reverse.
        std.mem.reverse(u8, notes.patientInput[reverseCmdBoundary..notes.patientInputSize]);

        handled.* = true;
        return notes.patientInput[reverseCmdBoundary..notes.patientInputSize];
    }

    // If the user requested a hashed output below, this will be non-null!
    var hashed_hex_output: ?[]const u8 = null;

    // ".md5" command: sbaitso will compute the md5 of anything and then say the result.
    if (std.mem.startsWith(u8, inputLC, ".md5 ")) {
        const md5 = std.crypto.hash.Md5;
        var h = md5.init(.{});

        var out: [md5.digest_length]u8 = undefined;
        h.update(notes.patientInput[5..notes.patientInputSize]);
        h.final(out[0..]);

        // Convert to a hexademical string.
        const hexResult = std.fmt.bytesToHex(out[0..], .lower);
        hashed_hex_output = &hexResult;
    }

    // ".sha1" command: sbaitso will compute the sha1 of anything and then say the result.
    if (std.mem.startsWith(u8, inputLC, ".sha1 ")) {
        const sha1 = std.crypto.hash.Sha1;
        var h = sha1.init(.{});

        var out: [sha1.digest_length]u8 = undefined;
        h.update(notes.patientInput[5..notes.patientInputSize]);
        h.final(out[0..]);

        // Convert to a hexademical string.
        const hexResult = std.fmt.bytesToHex(out[0..], .lower);
        hashed_hex_output = &hexResult;
    }

    if (hashed_hex_output) |out| {
        const result = try responseArena.allocator().dupe(u8, out);
        handled.* = true;
        return result;
    }

    // ".color" command: sbaitso change the background color.
    if (std.mem.startsWith(u8, inputLC, ".color")) {
        // handle 0-7 colors
        const colorVal = try std.fmt.parseInt(usize, inputLC[7..notes.patientInputSize], 10);
        if (notes.bgColor == colorVal) {
            handled.* = true;
            return "UMM, IT'S ALREADY THAT COLOR NUM NUTS.  TRY AGAIN.";
        }
        if (colorVal <= BGColorChoices.len - 1) {
            notes.bgColor = colorVal;
            handled.* = true;
            return "O K, ADJUSTING BACKGROUND COLOR.  JUST FOR YOU.";
        } else {
            handled.* = true;
            return "NOT A VALID COLOR.  TRY READING A FUCKEN MANUAL FOR ONCE IN YOUR LIFE, DIPSHIT.";
        }
    }

    // ".brain" command: allows the user to switch brain engines.
    if (std.mem.startsWith(u8, inputLC, ".brain")) {
        // handle speech engines 0-? how many available?
        const engineIdx = try std.fmt.parseInt(usize, inputLC[7..notes.patientInputSize], 10);
        if (notes.brainEngine == engineIdx) {
            handled.* = true;
            return "THAT BRAIN ENGINE IS ALREADY RUNNING, IDIOT.";
        }
        if (engineIdx <= brainEngines.len - 1) {
            notes.brainEngine = engineIdx;
            handled.* = true;
            return "O K, A DIFFERENT BRAIN ENGINE WAS SELECTED.  I HOPE IT'S SMARTER THAN YOU!";
        } else {
            handled.* = true;
            return "NOT A VALID BRAIN ENGINE.  LEARN HOW TO READ A MANUAL!";
        }
    }

    // ".engine" command: allows the user to switch speech engines.
    if (std.mem.startsWith(u8, inputLC, ".engine")) {
        // handle speech engines 0-? how many available?
        const engineIdx = try std.fmt.parseInt(usize, inputLC[8..notes.patientInputSize], 10);
        if (notes.speechEngine == engineIdx) {
            handled.* = true;
            return "THAT SPEECH ENGINE IS ALREADY RUNNING NUMNUTS.";
        }
        if (engineIdx <= speechEngines.len - 1) {
            notes.speechEngine = engineIdx;
            handled.* = true;
            return "O K, A DIFFERENT SPEECH ENGINE WAS SELECTED.  I HOPE YOU LIKE THE WAY IT SOUNDS!";
        } else {
            handled.* = true;
            return "NOT A VALID ENGINE.  LEARN HOW TO READ A MANUAL!";
        }
    }

    // Enhanced commands below (not in the original)
    if (std.mem.startsWith(u8, inputLC, ".fontcolor")) {
        // handle 0-7 colors
        const colorVal = try std.fmt.parseInt(usize, inputLC[11..notes.patientInputSize], 10);
        if (colorVal <= BGColorChoices.len - 1) {
            notes.ftColor = colorVal;
            handled.* = true;
            return "OKAY, ADJUSTING FONT COLOR.  HAY THIS LOOKS NICE.";
        } else {
            handled.* = true;
            return "NOT A VALID COLOR.  TRY READING A FUCKEN MANUAL FOR ONCE IN YOUR LIFE, DIPSHIT.";
        }
    }

    if (std.mem.startsWith(u8, inputLC, ".clear")) {
        // Clear out the scroll buffer.
        clearScrollBuffer();

        handled.* = true;
        return null;
    }

    // .tone
    // .volume
    // .pitch
    // .speed
    // .param tvps (single shot all of them)

    // Easter Egg below
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

        clearScrollBuffer();

        handled.* = true;
        return ScpPerformanceToken;
    }

    // Explicitely indicate that nothing was done.
    handled.* = false;
    return null;
}

// chooseAction simply returns the next round-robin reassembly line for the provided action key.

fn thinkOneLine(inputLC: []const u8) !?[]const u8 {
    // 0. Check for timeout
    if (timeoutTicks > MAX_TIMEOUT) {
        defer timeoutTicks = 0;
        return sbaitsoBrainProvider.chooseAction("<timed-out>");
    }

    // 0.b Check for enter only (empty line)
    if (inputLC.len <= 0) {
        return sbaitsoBrainProvider.chooseAction("<enter>");
    }

    // 1.a Check for repeated inputs
    if (std.mem.eql(u8, inputLC, notes.prevPatientInput[0..notes.prevPatientInputSize])) {
        // Randomly select from both repeat tables...it don't matter much here.
        return sbaitsoBrainProvider.chooseAction(if (rl.getRandomValue(0, 100) > 50) "<repeat>" else "<repeat-2x>");
    }

    // 1. Too short responses.
    // TODO: figure out what the original short threshold was.
    if (inputLC.len <= ShortInputThreshold) {
        return sbaitsoBrainProvider.chooseAction("<too-short>");
    }

    // 2. Brain processing is here.
    const brainEngineFn = brainEngines[notes.brainEngine];
    if (try brainEngineFn(gIo, inputLC, responseArena.allocator())) |result| {
        return result;
    }

    // 4. Next, check if they gave us gabage/gibberish!
    // NOTE: moved to lower in priority since this code isn't well tuned yet for
    // high probability on junk input.
    if (gibberish.probablyGibberish(inputLC)) {
        return sbaitsoBrainProvider.chooseAction("<garbage>");
    }

    // 5. Catch all responses are the last attempt to say something.
    // 5a. Pick a response round-robin (like the original does)
    return sbaitsoBrainProvider.chooseAction("<catch-all>");
}

fn updateCursor() void {
    cursorAccumulator += rl.getFrameTime();
    if (cursorAccumulator >= cursorWaitThresholdMs) {
        cursorBlink = !cursorBlink;
        cursorAccumulator = 0;
    }
}

fn draw() !void {
    rl.beginDrawing();
    defer rl.endDrawing();

    if (started) {
        // Clears the actual window (not the offscreen render texture below).
        // Normally the monitorBorder texture fully repaints this every frame,
        // but it needs a real clear of its own when the border is disabled.
        rl.clearBackground(.black);

        {
            // Here, we draw the screen in a render texture called: target.
            rl.beginTextureMode(target);
            defer rl.endTextureMode();

            rl.clearBackground(BGColorChoices[notes.bgColor]);

            drawBanner();
            try drawScrollBuffer();

            // Calculate cursor/input buffer yOffset based on scrollBuffer.
            //const inputYOffset = scrollBufferYOffset + ((scrollBufferRegion.end - scrollBufferRegion.start) * scrollBufferYSpacing);
            const inputYOffset = scrollBufferYOffset + (scrollBuffer.items.len * scrollBufferYSpacing);
            const loc: rl.Vector2 = .{ .x = 0, .y = @floatFromInt(inputYOffset) };
            try drawInputBuffer(.{ .x = loc.x + 10, .y = loc.y });
            try drawCursor(loc);

            // Debug drawing when LEFT SHIT IS HELD DOWN only.
            if (rl.isKeyDown(.left_shift)) {
                var buf: [64]u8 = undefined;
                const cStr = try std.fmt.bufPrintZ(&buf, "{t}", .{notes.state});
                rl.drawTextEx(dosFont, cStr, .{ .x = 120, .y = SCREEN_HEIGHT - 30 }, FONT_SIZE, 0, .green);
                rl.drawFPS(10, SCREEN_HEIGHT - 30);
            }
        }

        {
            // The target is now blitted to the screen with the crt shader.

            if (shaderEnabled) rl.beginShaderMode(crtShader);
            defer if (shaderEnabled) rl.endShaderMode();
            const src = rl.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(target.texture.width),
                .height = @floatFromInt(-target.texture.height),
            };
            // The monitor texture has the screen cutout at this offset; with
            // no border the screen just fills the window from the origin.
            const dst = if (monitorBorderEnabled)
                rl.Rectangle{ .x = 118, .y = 106, .width = SCREEN_WIDTH, .height = SCREEN_HEIGHT }
            else
                rl.Rectangle{ .x = 0, .y = 0, .width = SCREEN_WIDTH, .height = SCREEN_HEIGHT };
            rl.drawTexturePro(target.texture, src, dst, rl.Vector2{ .x = 0, .y = 0 }, 0, .white);
        }

        // The monitor frame/border is drawn on top, when enabled.
        if (monitorBorderEnabled) {
            rl.drawRectangle(0, 840, WIN_WIDTH, 132, .black);
            rl.drawTexture(monitorBorder, 0, 0, .white);
        }
    } else {
        rl.clearBackground(.black);
    }
}

fn drawBanner() void {
    const lines: []const [:0]const u8 = &.{
        "╔═══════════════════════════════════════════════════════════════════════════════════════╗",
        "║ Sound Blaster                                                            version 2.20 ║",
        "╟───────────────────────────────────────────────────────────────────────────────────────╢",
        "║                                                                   all rights reserved ║",
        "╚═══════════════════════════════════════════════════════════════════════════════════════╝",
    };

    const ySpacing = FONT_SIZE;
    for (lines, 0..) |l, idx| {
        rl.drawTextEx(dosFont, l, .{ .x = 10, .y = @floatFromInt(10 + (idx * ySpacing)) }, FONT_SIZE, 0, .white);
    }

    // NOTE: The title and copyright are in a different color, so they are done out of band.

    // Overlay title in yellow.
    const title = "                                  D R    S B A I T S O";
    rl.drawTextEx(dosFont, title, .{ .x = 10, .y = 10 + (1 * ySpacing) }, FONT_SIZE, 0, hexToColor(0xffff73ff));

    // Overlay copyright in green.
    const copyright = "                            (c) Copyright Creative Labs, Inc. 1992,";
    rl.drawTextEx(dosFont, copyright, .{ .x = 10, .y = 10 + (3 * ySpacing) }, FONT_SIZE, 0, hexToColor(0x89fc6eff));
}

// drawScrollBuffer concerns itself with only drawing the conversational history of both
// the Dr. Sbaitso and the patient. This represents a scrolling history buffer of everything
// that's been said so far. Once we have more than a page of text, old stuff will be lopped
// off the top of the screen to make room for the new stuff at the bottom of the screen.
fn drawScrollBuffer() !void {
    // const reg = scrollBufferRegion;
    // var i: usize = reg.start;
    var linesRendered: usize = 0;

    var buf: [512]u8 = undefined;
    //while (i < reg.end and linesRendered <= maxRenderableLines) : (i += 1) {
    for (scrollBuffer.items) |entry| {
        //const entry = &scrollBuffer.items[i];
        const cStr = try std.fmt.bufPrintZ(&buf, "{s}", .{entry.line});
        switch (entry.entryType) {
            .sbaitso => {
                rl.drawTextEx(
                    dosFont,
                    cStr,
                    .{ .x = 10, .y = @floatFromInt(scrollBufferYOffset + (linesRendered * scrollBufferYSpacing)) },
                    FONT_SIZE,
                    0,
                    FGColorChoices[notes.ftColor],
                );
                linesRendered += 1;
            },
            .user => {
                rl.drawTextEx(
                    dosFont,
                    cStr,
                    .{ .x = 10, .y = @floatFromInt(scrollBufferYOffset + (linesRendered * scrollBufferYSpacing)) },
                    FONT_SIZE,
                    0,
                    .yellow,
                );
                linesRendered += 1;
            },
            else => {},
        }
    }
}

// drawInputBuffer draws the user's input line as they type and only appears
// when Sbaitso waits input or asks for a the patient's name.
fn drawInputBuffer(location: rl.Vector2) !void {
    const onScreen = notes.state == .sbaitso_ask_name or notes.state == .user_await_input;
    if (onScreen) {
        var buf: [MAX_INPUT_LINE_CHARS + 1]u8 = undefined;
        var i: usize = 0;
        var row: usize = 0;
        while (i < inputBufferSize) : (row += 1) {
            const end = @min(i + MAX_INPUT_LINE_CHARS, inputBufferSize);
            const cStr = try std.fmt.bufPrintSentinel(&buf, "{s}", .{inputBuffer[i..end]}, 0);
            rl.drawTextEx(
                dosFont,
                cStr,
                .{ .x = location.x, .y = location.y + @as(f32, @floatFromInt(row * scrollBufferYSpacing)) },
                FONT_SIZE,
                0,
                .yellow,
            );
            i = end;
        }
    }
}

fn drawCursor(location: rl.Vector2) !void {
    // Cursor should be on screen only at the correct states.
    const isOnscreen = notes.state == .sbaitso_ask_name or notes.state == .user_await_input;

    if (isOnscreen) {
        // Draw the carot or prompt.
        rl.drawTextEx(
            dosFont,
            ">",
            location,
            FONT_SIZE,
            0,
            .yellow,
        );

        // TODO: fix cursor blink alignment which should be right under the next expected character!!!

        // Draw the cursor.
        if (cursorBlink) {
            // 1. Figure out which wrapped row the cursor is on, and measure
            // just that row's text so far to know how far to place the cursor.
            const row = inputBufferSize / MAX_INPUT_LINE_CHARS;
            const rowStart = row * MAX_INPUT_LINE_CHARS;

            var inputBufferOffset: rl.Vector2 = .{ .x = 0, .y = 0 };
            if (inputBufferSize > rowStart) {
                var buf: [MAX_INPUT_LINE_CHARS + 1]u8 = undefined;
                const cStr = try std.fmt.bufPrintZ(&buf, "{s}", .{inputBuffer[rowStart..inputBufferSize]});
                inputBufferOffset = rl.measureTextEx(dosFont, cStr, FONT_SIZE, 0);
            }

            // 2. Render as a rectangle.
            const charWidth = (FONT_SIZE / 2) + 2;
            rl.drawRectangle(
                6 + (@as(c_int, @intFromFloat(location.x))) + @as(c_int, @intFromFloat(inputBufferOffset.x)),
                @as(c_int, @intFromFloat(location.y)) + 18 + @as(c_int, @intCast(row * scrollBufferYSpacing)),
                charWidth,
                2,
                .white,
            );
        }
    }
}

fn hexToColor(clr: u32) rl.Color {
    const outColor = rl.Color{
        .r = @intCast((clr >> 24) & 0xff),
        .g = @intCast((clr >> 16) & 0xff),
        .b = @intCast((clr >> 8) & 0xff),
        .a = @intCast(clr & 0xff),
    };
    return outColor;
}

fn playSbaitsoLetterSound(letter: u8) void {
    if (notes.speechEngine != 0) {
        // NOTE: as of right now, we should only be playing this for Sbaitso's original voice.
        // We're not yet doing this correctly for all voices universally.
        return;
    }

    if ((letter >= 'A' and letter <= 'Z') or (letter >= 'a' and letter <= 'z')) {
        const upper = if (letter >= 'a') letter - ('a' - 'A') else letter;
        const idx = upper - 'A';

        rl.playSound(SbaitsoLetterSounds[idx]);
    }
}

fn loadFont() !void {

    // Just add more symbols, order does not matter.
    const cp = try rl.loadCodepoints(" 0123456789!@#$%^&*()/<>\\:;.,\"'?_~+-=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ║╔═╗─╚═╝╟╢");

    // Load Font from TTF font file with generation parameters
    // NOTE: You can pass an array with desired characters, those characters should be available in the font
    // if array is NULL, default char set is selected 32..126
    dosFont = try rl.loadFontEx("resources/fonts/MorePerfectDOSVGA.ttf", FONT_SIZE, cp);
}

/// Loads the speech pack against std.testing.allocator; pair with testUnloadDatabase.
/// Loads the speech pack against std.testing.allocator; pair with testUnloadDatabase.
/// The DB/map themselves now live in sbaitsoBrainProvider; this just wires up
/// the app-level `allocator` global that other main.zig code (e.g. addScrollBufferLine)
/// still relies on during tests.
fn testLoadDatabase(io: std.Io) ![]const u8 {
    allocator = std.testing.allocator;
    return sbaitsoBrainProvider.loadDatabaseFiles(io, std.testing.allocator);
}

fn testUnloadDatabase(data: []const u8) void {
    std.testing.allocator.free(data);
    sbaitsoBrainProvider.parsedJSON.deinit();
    sbaitsoBrainProvider.map.deinit(std.testing.allocator);
    sbaitsoBrainProvider.map = .empty;
}

test "conversation turns do not leak" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    responseArena = .init(std.testing.allocator);
    defer responseArena.deinit();

    notes = DrNotes{};
    notes.brainEngine = 0; // Eliza brain only; no external processes in tests.
    timeoutTicks = 0;
    const name = "TESTER";
    @memcpy(notes.patientName[0..name.len], name);
    notes.patientNameSize = name.len;

    defer clearScrollBuffer();

    // One entry per allocation path that used to leak per turn:
    // reassembly, the substitution chain, hashed output, and .name allocPrint.
    const inputs = [_][]const u8{
        "i think you are dumb",
        "tell me about the weather today",
        ".md5 hello",
        ".name",
    };

    for (inputs) |input| {
        @memcpy(notes.patientInput[0..input.len], input);
        notes.patientInputSize = input.len;

        // Mimics update(): entering a new think-turn releases the previous
        // turn's response memory.
        _ = responseArena.reset(.retain_capacity);
        _ = try getOneLine();
    }

    // std.testing.allocator flags anything still outstanding when the test ends.
}

test "main dispatch payloads are owned by the consumer" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    allocator = std.testing.allocator;
    mainQueue = .init(threaded.io(), std.testing.allocator);
    defer mainQueue.deinit();

    notes = DrNotes{};
    defer clearScrollBuffer();

    // The dispatcher dupes at enqueue time, so a producer may free its copy
    // immediately after dispatch -- this is exactly what speechConsumer does
    // with the intro line it allocates.
    const producerLine = try std.testing.allocator.dupe(u8, "HELLO PATIENT.");
    try dispatchToMainThread(.{producerLine});
    std.testing.allocator.free(producerLine);

    try dispatchToMainThread(.{AwaitUserInputToken});

    try pollMainDispatchLoop();
    try pollMainDispatchLoop();

    try std.testing.expectEqual(@as(usize, 1), scrollBuffer.items.len);
    try std.testing.expectEqualStrings("HELLO PATIENT.", scrollBuffer.items[0].line);
    try std.testing.expectEqual(GameStates.user_await_input, notes.state);

    // Payloads still queued at shutdown are freed by the drain.
    try dispatchToMainThread(.{"NEVER CONSUMED."});
    drainMainQueue();
}

test "repeat one time" {}

test "repeat 2x" {}
