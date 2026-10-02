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
const calc = @import("calc.zig");
const sayProvider = @import("voice_providers/macos_say.zig");
const sbaitsoProvider = @import("voice_providers/sbaitso.zig");
const ollamaBrainProvider = @import("brain_providers/ollama.zig");
const sbaitsoBrainProvider = @import("brain_providers/sbaitso.zig");
const utility = @import("brain_providers/sbaitso_helper/utility.zig");
const rl = @import("raylib");

const is_web = builtin.os.tag == .emscripten;

// Zig 0.16's default panic handler does not build for wasm32-emscripten.
pub const panic = if (is_web) std.debug.FullPanic(wasmPanic) else std.debug.FullPanic(std.debug.defaultPanic);
fn wasmPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    std.debug.print("panic: {s}\n", .{msg});
    @trap();
}

// TODO: Create a Github workflow that compiles + packages into app bundle
// like this: https://github.com/RyanAksoy/super-mario-64-mac-build/blob/5fc1fc9dd50c1adaa99168e67df671bc4dff1f12/build.yml

// Window includes monitor.
const WIN_TITLE = "Dr. Sbaitso: Reborn - by @deckarep";
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
};

const speechEngines = [_]*const fn (
    std.Io,
    []const []const u8,
    std.mem.Allocator,
) anyerror!void{
    sbaitsoProvider.speakMany,
} ++ if (builtin.os.tag == .macos) .{
    // Spawns macOS's `say`: not in the browser, and not on Windows/Linux.
    sayProvider.speakMany,
} else .{};

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

const ShortInputThreshold = 6;
const TestingToken = "<testing-text>";
const QuitToken = "<quit>";
const ParityToken = "<parity>";
const ParitySpeakToken = "<parity-speak>";
const HelpToken = "<help-screen>";
const RestartToken = "<restart>";
const GarbageToken = "<garbage>";
const AwaitUserInputToken = "<await-user-input>";
const AwaitCaptureNameToken = "<await-capture-name>";
const DoSbaitsoIntroToken = "<sbaitso-intro>";

const ScpPerformanceToken = "<scp-intro>";
const ScpFinishedToken = "<scp-finished>";
// Spoken while typing the patient's name; neither prints nor changes state.
const NameTooLongToken = "<name-too-long>";
const AlphabetsOnlyToken = "<alphabets-only>";
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
    speechEngine: usize = 0, // 0:sbaitso, 1:OsSpeechSynth (macOS only)
    brainEngine: usize = 0, // 0:sbaitso, 1:chatgpt

    // Patient name
    patientName: [MAX_NAME_LEN]u8 = undefined,
    patientNameSize: usize = 0,

    // Patient previous input (for storing the previous user's input)
    prevPatientInput: [MAX_INPUT_BUFFER]u8 = undefined,
    prevPatientInputSize: usize = 0,

    // Patient input
    patientInput: [MAX_INPUT_BUFFER]u8 = undefined,
    patientInputSize: usize = 0,

    // Sbaitso asked "HOW OLD ARE YOU?", so the next reply is read as an age.
    awaitingAge: bool = false,
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
    user_give_name, // type name, only accept alphabet or spaces, max MAX_NAME_LEN chars
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
// 0e. Phenome support: <<~CHAxWAAWAA>>
// 3. Pluggable AI-Chat backends aside from the obvious ChatGPT, could be anything.
// 4. Pluggable synth voices, could be from any source.
// 5. Building on other OSes at some point.
// 6. Truly embeded architecture for Sbaitso voice.

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

    // Launched from a macOS .app bundle the working directory is "/", so load
    // resources/ from the bundle's Contents/Resources (see `make macos-app`).
    if (builtin.os.tag == .macos) {
        const exeDir = rl.getApplicationDirectory();
        if (std.mem.endsWith(u8, exeDir, ".app/Contents/MacOS/")) {
            const resDir = try std.fmt.allocPrintSentinel(allocator, "{s}../Resources", .{exeDir}, 0);
            defer allocator.free(resDir);
            _ = rl.changeDirectory(resDir);
        }
    }
    // The Windows release ships resources/ next to the .exe, but a shortcut or
    // command prompt may start it from anywhere (see `make windows-app`).
    if (builtin.os.tag == .windows) {
        _ = rl.changeDirectory(rl.getApplicationDirectory());
    }

    // NOTE: added highdpi and msaa4x to try to get higher quality text rendering.
    rl.setConfigFlags(.{
        .vsync_hint = true,
        // On the web these make raylib resize the canvas to the browser window.
        .window_resizable = !is_web,
        .window_highdpi = !is_web,
        .msaa_4x_hint = true,
        .window_transparent = true,
    });
    // Without the monitor border, the window is just the blue screen itself.
    if (monitorBorderEnabled) {
        rl.initWindow(WIN_WIDTH, WIN_HEIGHT, WIN_TITLE);
    } else {
        rl.initWindow(SCREEN_WIDTH, SCREEN_HEIGHT, WIN_TITLE);
    }
    rl.initAudioDevice();
    rl.setTargetFPS(30);
    defer rl.closeWindow();

    try loadFont();
    defer rl.unloadFont(dosFont);

    target = try rl.loadRenderTexture(SCREEN_WIDTH, SCREEN_HEIGHT);
    defer rl.unloadRenderTexture(target);
    monitorBorder = try rl.loadTexture("resources/textures/DrSbaitsoMonitor.png");
    defer rl.unloadTexture(monitorBorder);

    // From here: https://github.com/RobLoach/raylib-libretro/tree/3453acf4879373b4c8f7efb3f749fc896fbf7944/src/shaders/crt/resources/shaders
    // NOTE: this is GLSL 330 which WebGL can't compile, so on the web fall back
    // to raylib's default shader (i.e. the .crt command has no visible effect).
    crtShader = rl.loadShader(null, "resources/shaders/330/crt.fs") catch |err| blk: {
        if (!is_web) return err;
        break :blk .{ .id = rl.gl.rlGetShaderIdDefault(), .locs = rl.gl.rlGetShaderLocsDefault() };
    };
    defer rl.unloadShader(crtShader);

    initShader();

    // The name prompt speaks each typed letter (see playSbaitsoLetterSound).
    defer sbaitsoProvider.stopLetter();

    parityTone = try makeParityTone();
    defer rl.unloadSound(parityTone);

    defer speechQueue.deinit();
    defer {
        // Free payloads the main loop never consumed (e.g. the window was
        // closed mid-speech, or the web loop exited).
        drainMainQueue();
        mainQueue.deinit();
    }

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

    // The web build has no threads: speech is processed on the main thread
    // below, with the voice provider rendering frames while audio plays.
    if (is_web) {
        sbaitsoProvider.waitHook = webSpeechWaitFrame;
        while (!userQuit and !rl.windowShouldClose()) {
            try update();
            try draw();
            while (speechQueue.dequeue()) |container| {
                if (!try processSpeechItem(container)) break;
            }
        }
        return;
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
        errdefer allocator.free(backing);

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
        if (!try processSpeechItem(container)) return;
    }
}

/// Web only: one frame of the main loop, run while speech audio is playing
/// (the main loop itself is blocked in the speech call at that point).
fn webSpeechWaitFrame() void {
    updateCursor();
    pollMainDispatchLoop() catch |err| std.log.err("pollMainDispatchLoop: {t}", .{err});
    draw() catch |err| std.log.err("draw: {t}", .{err});
    // Yields to the browser (asyncify) so the audio keeps playing.
    _ = rl.windowShouldClose();
}

/// Handles a single speechQueue item, blocking while it is spoken.
/// Returns false when the quit token was received.
fn processSpeechItem(container: Container) !bool {
    switch (container) {
        .one => |val| {
            // 0. For empty strings, just immediately move back to await user input.
            if (val.len == 0) {
                try dispatchToMainThread(.{AwaitUserInputToken});
                return true;
            }

            // 0.a. Check for quit.
            if (std.mem.eql(u8, QuitToken, val)) {
                std.log.debug("speechConsumer <quit> requested...", .{});
                return false;
            }

            if (std.mem.eql(u8, DoSbaitsoIntroToken, val)) {
                // The speech pack always has this table.
                const introTbl = sbaitsoBrainProvider.map.get("<intro:accept>") orelse unreachable;
                const introductionLine = try utility.maybeReplaceName(introTbl.reassemblies[0], notes.patientName[0..notes.patientNameSize], allocator);
                const intro: []const []const u8 = introTbl.reassemblies[0..];
                const remainingTotal = intro.len;
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
                return true;
            }

            // 0.b. The parity error is over: say "PARITY" while the falling
            // tone finishes, then hand the cursor back.
            if (std.mem.eql(u8, ParitySpeakToken, val)) {
                try dispatchToMainThread(.{"PARITY"});
                try speak("PARITY");
                while (rl.isSoundPlaying(parityTone)) {
                    if (sbaitsoProvider.waitHook) |hook| {
                        hook();
                    } else {
                        try gIo.sleep(.fromMilliseconds(10), .awake);
                    }
                }
                try dispatchToMainThread(.{AwaitUserInputToken});
                return true;
            }

            // 0.c. A rejected keypress while typing the name: just say why. The
            // patient keeps typing, so there's no line to print or state to change.
            if (std.mem.eql(u8, NameTooLongToken, val) or std.mem.eql(u8, AlphabetsOnlyToken, val)) {
                defer nameWarningPending.store(false, .release);
                try speak(if (std.mem.eql(u8, NameTooLongToken, val)) "NAME TOO LONG" else "ENTER ALPHABETS ONLY");
                return true;
            }

            // 0.d. Request for scp performance?
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
                return true;
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

    return true;
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
        const val = try allocator.dupe(u8, args[0]);
        errdefer allocator.free(val);
        try mainQueue.enqueue(Container{ .one = val });
    } else {
        // For multiple args, creating backing array, then enqueue.
        const backing = try allocator.alloc([]const u8, args.len);
        errdefer allocator.free(backing);
        var duped: usize = 0;
        errdefer for (backing[0..duped]) |item| allocator.free(item);
        inline for (args, 0..) |arg, idx| {
            backing[idx] = try allocator.dupe(u8, arg);
            duped += 1;
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
        errdefer alloc.free(buf);
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
    // Check for timeout. Only while awaiting input: forcing a new turn while
    // Sbaitso is still speaking would reset responseArena out from under the
    // speech thread, which is reading `line` from it.
    if (notes.state == .user_await_input and timeoutTicks > MAX_TIMEOUT) {
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
            // Like the original, the keyboard is ignored until Sbaitso has fully
            // said the typed letter. Frames keep rendering meanwhile.
            if (!sbaitsoProvider.isLetterPlaying()) {
                try pollKeyboardForInput(.sbaitso_intro);
            }
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
            try pollKeyboardForInput(.sbaitso_think_of_reply);
            timeoutTicks += 1;
        },
        .sbaitso_think_of_reply => {
            // A new turn begins: the previous turn's response strings have
            // been spoken and duped into the scroll buffer by now, so their
            // memory can be released wholesale.
            _ = responseArena.reset(.retain_capacity);

            // TODO: support multiple lines being returned.
            const response = try getOneLine();
            if (response) |r| {
                if (std.mem.eql(u8, r, ParityToken)) {
                    startParity();
                    notes.state = .sbaitso_parity_err;
                } else if (std.mem.eql(u8, r, RestartToken)) {
                    // Start over from the banner, which asks for a name.
                    notes.state = .sbaitso_announce;
                } else if (std.mem.eql(u8, r, HelpToken)) {
                    helpPage = 0;
                    notes.state = .sbaitso_help;
                } else {
                    line = r;
                    notes.state = .sbaitso_render_reply;
                }
            } else {
                // Upon nothing being returned (like from the .clear command), just go back to .user_await_input.
                notes.state = .user_await_input;
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
        .sbaitso_parity_err => try updateParity(),
        .sbaitso_new_session => {},
        .sbaitso_help => updateHelp(),
    }
}

// ---- Parity error ----
// Sbaitso "goes haywire" when overexposed to bad language: a falling tone
// plays while pages of PARITY ERR lines scroll by, then he recovers and says
// "PARITY". The whole thing lasts ParityToneSecs.

const ParityToneSecs = 4.5;
const ParityScrollSecs = 3.6;
const ParityLinesPerSec = 110.0;
const ParityTotalLines: usize = @intFromFloat(ParityScrollSecs * ParityLinesPerSec);

var parityTone: rl.Sound = undefined;
var parityStart: f64 = 0;
var parityLines: usize = 0;

/// Synthesizes the parity tone the way a DOS program would have: a square
/// wave whose pitch drops in steps, once per PC timer tick (~18.2 Hz), with
/// each step snapped to what the 8253 timer chip can produce (1193182 Hz /
/// an integer divisor). Rendered as 8-bit audio at 11 kHz, and cut off
/// abruptly at the end.
fn makeParityTone() !rl.Sound {
    const rate = 11025;
    const count: usize = @intFromFloat(ParityToneSecs * rate);
    const startHz = 1600.0;
    const endHz = 150.0;
    const pitClock = 1193182.0;
    const ticksPerSec = 18.2;
    const amplitude = 40; // around the 8-bit midpoint of 128

    const samples = try allocator.alloc(u8, count);
    defer allocator.free(samples);

    var phase: f64 = 0;
    for (samples, 0..) |*sample, i| {
        const secs = @as(f64, @floatFromInt(i)) / rate;
        // Hold each pitch for a whole timer tick, falling linearly in Hz.
        const tick = @floor(secs * ticksPerSec);
        const t = @min(1.0, tick / (ParityToneSecs * ticksPerSec));
        const wantHz = startHz + (endHz - startHz) * t;
        const hz = pitClock / @round(pitClock / wantHz);

        phase += hz / rate;
        phase -= @floor(phase);
        sample.* = if (phase < 0.5) 128 + amplitude else 128 - amplitude;
    }

    // raylib copies the samples.
    return rl.loadSoundFromWave(.{
        .frameCount = @intCast(count),
        .sampleRate = rate,
        .sampleSize = 8,
        .channels = 1,
        .data = @ptrCast(samples.ptr),
    });
}

fn startParity() void {
    parityStart = rl.getTime();
    parityLines = 0;
    rl.playSound(parityTone);
}

fn updateParity() !void {
    const elapsed = rl.getTime() - parityStart;
    const due: usize = @intFromFloat(@min(elapsed, ParityScrollSecs) * ParityLinesPerSec);

    // Several lines per frame, so it rips through pages and pages of them.
    while (parityLines < due) : (parityLines += 1) {
        var buf: [64]u8 = undefined;
        const lateHalf = parityLines >= ParityTotalLines / 2;
        const errLine = try std.fmt.bufPrint(&buf, "PARITY ERR ... {d}{s}", .{
            rl.getRandomValue(1, 65535),
            if (lateHalf) "  ???" else "",
        });
        try addScrollBufferLine(.sbaitso, errLine);
    }

    if (elapsed >= ParityScrollSecs) {
        try addScrollBufferLine(.sbaitso, "PARITY ERR ... RECOVERED");
        // The speech thread says "PARITY" and returns control to the user
        // once the tone has finished.
        line = ParitySpeakToken;
        notes.state = .sbaitso_render_reply;
    }
}

// ---- Help screen ----
// Modeled on the original's HELP pages. <M> pages forward, any other key
// returns to the conversation.

const HelpPage = []const [:0]const u8;

const helpPages = [_]HelpPage{
    &.{
        "Sound Blaster Acting Intelligent Text to Speech Operator",
        "",
        "Dr SBAITSO is a program that attempts to fake intelligence.",
        "Text to speech capability is added to give him more life.",
        "You may ask him any kind of questions. He will try his best to satisfy you.",
        "He performs best when you talk about your problems and in complete sentences.",
        "",
        "Dot Commands are preceded with a dot on the first column. They are listed below:",
        "QUIT             - to quit this program",
        ".COLOR c         - where c is a background color number from 0 - 8",
        ".TONE t          - where t is a digit of 0 or 1.  0=Bass  and  1=Treble tone",
        ".VOLUME v        - where v is a digit from 0 - 9. 0 for lowest volume",
        ".PITCH p         - where p is a digit from 0 - 9. 0 for lowest pitch",
        ".SPEED s         - where s is a digit from 0 - 9. 0 for lowest speed",
        ".PARAM tvps      - tvps are 4 digits representing: Tone/Volume/Pitch/Speed",
        "                   .PARAM D restores the default settings",
    },
    &.{
        "Reborn Commands, new since 1992:",
        "",
        ".FONTCOLOR c     - where c is a font color number from 0 - 9",
        ".CRT n           - 1 turns the CRT effect on, 0 turns it off",
        ".ENGINE n        - speech engine, 0=Sbaitso  1=Operating system voice",
        ".BASS b          - bass boost, b is a digit from 0 - 9. 0=off (the original)",
        ".STEREO w        - stereo width, w is a digit from 0 - 9. 0=mono (the original)",
        ".REVERB r        - room reverb, r is a digit from 0 - 9. 0=off (the original)",
        ".BRAIN n         - brain, 0=Sbaitso  1=Ollama",
        ".CLEAR           - clear the screen",
        ".RESET           - reset the colors, the voice and his memory",
        ".RESTART         - start over as a new patient, clearing everything",
        ".NAME            - be reminded of who you are",
        ".REV text        - say the text in reverse",
        ".MD5 text        - say the MD5 hash of the text",
        ".SHA1 text       - say the SHA1 hash of the text",
    },
    &.{
        "Topics such as friends, schools, family, love, money, dreams and emotions",
        "may arouse his special interest.",
        "",
        "He can CALCulate simple Mathematics.  Try:  CALC (2+3)*4  or  WHAT IS 12/4",
        "",
        "Try to phrase your sentences in different formats for more varied responses.",
        "",
        "He hates bad languages and can go haywire if he is overexposed to them.",
        "",
        "You may ask him to SAY anything you want.",
        "",
        "Have fun.",
    },
    &.{
        "Here are some of the keywords which DR SBAITSO recognizes.",
        "If you use them in the appropriate manner,",
        "more intelligent responses will be generated.",
    },
};

// The page listing keywords appends them (from the speech pack) as a grid.
const helpKeywordPage = helpPages.len - 1;

var helpPage: usize = 0;

fn updateHelp() void {
    const key = rl.getKeyPressed();
    if (key != .null) {
        if (key == .m and helpPage + 1 < helpPages.len) {
            helpPage += 1;
        } else {
            notes.state = .user_await_input;
        }
    }
    // Don't let keys pressed here leak into the next typed line.
    while (rl.getCharPressed() != 0) {}
}

fn drawHelp() !void {
    const color = FGColorChoices[notes.ftColor];
    const top = 110;
    var row: usize = 0;

    for (helpPages[helpPage]) |helpLine| {
        rl.drawTextEx(dosFont, helpLine, .{ .x = 10, .y = @floatFromInt(top + row * scrollBufferYSpacing) }, FONT_SIZE, 0, color);
        row += 1;
    }

    if (helpPage == helpKeywordPage) {
        // Every rule with a remembered topic, 5 to a row.
        row += 1;
        const columns = 5;
        const columnWidth = 160;
        var col: usize = 0;
        for (sbaitsoBrainProvider.parsedJSON.value.mappings) |rule| {
            if (rule.memory == null) continue;

            var buf: [64]u8 = undefined;
            const kw = std.mem.trim(u8, rule.keywords[0], " *");
            const cStr = try std.fmt.bufPrintZ(&buf, "{s}", .{kw});
            rl.drawTextEx(dosFont, cStr, .{
                .x = @floatFromInt(10 + col * columnWidth),
                .y = @floatFromInt(top + row * scrollBufferYSpacing),
            }, FONT_SIZE, 0, color);

            col += 1;
            if (col == columns) {
                col = 0;
                row += 1;
            }
        }
    }

    const footer: [:0]const u8 = switch (helpPage) {
        0 => "Hit <M> now for More HELPs. However, you get more fun exploring them yourself.",
        helpPages.len - 2 => "Hit <M> now for More Hints, but you will miss the fun.",
        helpKeywordPage => "Hit any key to return.",
        else => "Hit <M> now for More HELPs, or any other key to return.",
    };
    rl.drawTextEx(dosFont, footer, .{ .x = 10, .y = SCREEN_HEIGHT - 35 }, FONT_SIZE, 0, .yellow);
}

// A line is capped at roughly the on-screen row width (~80 monospace
// characters); typed input may span up to MAX_INPUT_LINES of those before
// being rejected, wrapping visually as the user types.
const MAX_INPUT_LINE_CHARS = 80;
const MAX_INPUT_LINES = 5;
const MAX_INPUT_BUFFER = MAX_INPUT_LINE_CHARS * MAX_INPUT_LINES;
var inputBufferSize: usize = 0;
var inputBuffer = [_]u8{0} ** MAX_INPUT_BUFFER;

// Name entry rules from the original SBAITSO2.EXE: only letters and spaces are
// accepted, at most 25 of them. A rejected key is ignored and Sbaitso says
// "ENTER ALPHABETS ONLY" or "NAME TOO LONG".
const MAX_NAME_LEN = 25;
// Set while a name warning is queued or being spoken, so mashing keys doesn't
// pile up a backlog of them (cleared by the speech side).
var nameWarningPending = std.atomic.Value(bool).init(false);

fn sayNameWarning(token: []const u8) !void {
    if (nameWarningPending.swap(true, .acq_rel)) return;
    try dispatchToSpeechThread(.{token});
}

fn pollKeyboardForInput(targetState: GameStates) !void {
    // Handle submit (enter).
    if (rl.isKeyReleased(.enter)) {
        if (targetState == .sbaitso_think_of_reply) {
            // 1. Capture inputBuffer, submit it and clear input buffer!
            @memcpy(&notes.patientInput, &inputBuffer);
            notes.patientInputSize = inputBufferSize;
        } else if (targetState == .sbaitso_intro) {
            // 1. Capture name; typing already stops at MAX_NAME_LEN, but up-arrow history could be longer.
            notes.patientNameSize = @min(inputBufferSize, MAX_NAME_LEN);
            @memcpy(notes.patientName[0..notes.patientNameSize], inputBuffer[0..notes.patientNameSize]);

            // 2. Uppercase the name, otherwise the sbaitso speech engine will sometimes read sentences as
            // letters instead of words.
            // NOTE: this is doing an in-place upperString, seems to work fine. :shrug:
            _ = std.ascii.upperString(notes.patientName[0..notes.patientNameSize], notes.patientName[0..notes.patientNameSize]);
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
            // Take the char even when rejecting the key: several keys can land
            // in one frame and each must line up with its own char.
            const k = rl.getCharPressed();

            // Typing the patient's name: letters only, up to MAX_NAME_LEN.
            if (targetState == .sbaitso_intro) {
                timeoutTicks = 0;
                if (keyVal < @intFromEnum(rl.KeyboardKey.a)) {
                    try sayNameWarning(AlphabetsOnlyToken);
                    continue;
                }
                if (inputBufferSize >= MAX_NAME_LEN) {
                    try sayNameWarning(NameTooLongToken);
                    continue;
                }
            }

            if (inputBufferSize < MAX_INPUT_BUFFER) {
                inputBuffer[inputBufferSize] = @intCast(k);
                inputBufferSize += 1;
            }

            // When the target is intro, we know we're asking the user for their name.
            // So this will play audio of every alphabetic character as they type.
            if (targetState == .sbaitso_intro) {
                playSbaitsoLetterSound(@intCast(keyVal));
                // One letter at a time: anything else this frame is dropped,
                // and the keyboard is ignored until the letter has been said.
                timeoutTicks = 0;
                return;
            }

            // Reset timeout ticks.
            timeoutTicks = 0;
        }
    }

    // Typing the name: these keys sit outside the range above but get the same warning.
    if (targetState == .sbaitso_intro) {
        for ([_]rl.KeyboardKey{ .left_bracket, .backslash, .right_bracket, .grave }) |key| {
            if (rl.isKeyPressed(key)) {
                _ = rl.getCharPressed();
                try sayNameWarning(AlphabetsOnlyToken);
                timeoutTicks = 0;
            }
        }
    }

    // Handle space and allow repeats.
    if (rl.isKeyPressed(.space)) {
        if (targetState == .sbaitso_intro and inputBufferSize >= MAX_NAME_LEN) {
            try sayNameWarning(NameTooLongToken);
        } else if (inputBufferSize < MAX_INPUT_BUFFER) {
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
/// inputLine may be of any length: it's word-wrapped to at most
/// MAX_INPUT_LINE_CHARS per visual row, never splitting a word/punctuation
/// token mid-way (no hyphenation -- a single token longer than a row just
/// overflows its own row), so brains replying with any amount of text still
/// render correctly instead of overflowing a single row or breaking words.
fn addScrollBufferLine(kind: scrollEntryType, inputLine: []const u8) !void {
    var words = std.mem.tokenizeScalar(u8, inputLine, ' ');

    var lineBuf: [MAX_INPUT_LINE_CHARS]u8 = undefined;
    var lineLen: usize = 0;
    var wroteAny = false;

    while (words.next()) |word| {
        wroteAny = true;

        // Would this word (plus a separating space, if the row isn't empty)
        // overflow the current row? Flush what we have first.
        const sep: usize = if (lineLen > 0) 1 else 0;
        if (lineLen > 0 and lineLen + sep + word.len > MAX_INPUT_LINE_CHARS) {
            try appendScrollLine(kind, lineBuf[0..lineLen]);
            lineLen = 0;
        }

        if (word.len > MAX_INPUT_LINE_CHARS) {
            // Can't fit even alone on a row without hyphenating; let it
            // overflow rather than splitting the word.
            try appendScrollLine(kind, word);
            continue;
        }

        if (lineLen > 0) {
            lineBuf[lineLen] = ' ';
            lineLen += 1;
        }
        @memcpy(lineBuf[lineLen .. lineLen + word.len], word);
        lineLen += word.len;
    }

    // Flush the final partial row, or emit a single blank entry for empty
    // (or all-whitespace) input -- matches the previous chunking behavior.
    if (lineLen > 0 or !wroteAny) {
        try appendScrollLine(kind, lineBuf[0..lineLen]);
    }
}

/// Appends a single already-wrapped row to the scroll buffer, evicting the
/// oldest row first if we're at capacity.
fn appendScrollLine(kind: scrollEntryType, rowText: []const u8) !void {
    if (scrollBuffer.items.len > maxRenderableLines) {
        const oldEntry = scrollBuffer.orderedRemove(0);
        allocator.free(oldEntry.line);
    }

    try scrollBuffer.append(
        allocator,
        scrollEntry{
            .entryType = kind,
            .line = try allocator.dupe(u8, rowText),
        },
    );
    scrollBufferRegion.end += 1;
}

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

    // TODO: These should be in the file.
    // Example of a hardcoded response with "prosody" applied.
    // if (std.mem.indexOf(u8, inputLC, "fuck")) |_| {
    //     return "<<P0 STOP CUSSING OR I'LL DELETE YOUR HARD DRIVE.  FUCKER. >>";
    // }

    // Note working: "why don't you just eat a fat fucking cock!"

    const thoughtLine = try thinkOneLine(inputLC);
    if (thoughtLine) |thought| {
        // Some lines carry one of the original's action codes: `3 (change
        // colors) or `4 (ask the patient's age). Apply it, then drop it.
        var resp = thought;
        if (resp.len >= 2 and resp[0] == '`') {
            applyActionCode(resp[1]);
            resp = resp[2..];
        }

        // Too much bad language: Sbaitso goes haywire.
        if (std.mem.eql(u8, std.mem.trim(u8, resp, " "), "PARITY")) {
            return ParityToken;
        }

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

        // 3. Finally, maybe recall a topic from the memory stack. Only pop
        // when the response actually asks for one.
        if (std.mem.indexOf(u8, topicOutput, utility.historyToken) != null) {
            if (sbaitsoBrainProvider.memory.pop()) |recalled| {
                return try utility.maybeReplaceHistory(topicOutput, recalled, rAlloc);
            }
        }

        return topicOutput;
    }

    // Technically we should never get here anymore.
    // In the future I might make this `unreachable`.
    return "ERROR:  NO ADEQUATE RESPONSE FOUND.";
}

/// Clears everything about the current patient for .restart. The chosen
/// speech/brain engines and the CRT setting are app preferences, so they stay.
fn restartSession() void {
    clearScrollBuffer();

    notes.bgColor = 0;
    notes.ftColor = 0;
    notes.awaitingAge = false;
    notes.patientNameSize = 0;
    // Also keeps the new patient's first line from counting as a repeat.
    notes.prevPatientInputSize = 0;
    timeoutTicks = 0;

    sbaitsoBrainProvider.resetSession();
    sbaitsoProvider.setParams(.{});
}

/// Performs one of the original's in-response action codes.
fn applyActionCode(code: u8) void {
    switch (code) {
        // "I AM CONFUSED, LET'S CHANGE COLOR": a random new background, chosen
        // from the dark ones so the white text stays readable.
        '3' => {
            const darkBackgrounds = [_]usize{ 0, 1, 2, 4, 5, 8 };
            var pick = notes.bgColor;
            while (pick == notes.bgColor) {
                pick = darkBackgrounds[@intCast(rl.getRandomValue(0, darkBackgrounds.len - 1))];
            }
            notes.bgColor = pick;
        },
        // "HOW OLD ARE YOU?": the next reply is taken as the patient's age.
        '4' => notes.awaitingAge = true,
        else => {},
    }
}

// Age brackets for judging the patient's answer to "HOW OLD ARE YOU?".
const MinAdultAge = 18;
const MaxFavoredAge = 39;
const MaxPlausibleAge = 120;

/// Picks the reaction table for the patient's claimed age. Like the
/// original, a reply with no number at all is treated as coming from a kid.
fn ageReaction(inputLC: []const u8) []const u8 {
    const start = std.mem.indexOfAny(u8, inputLC, "0123456789") orelse return "<age:young>";
    var end = start;
    while (end < inputLC.len and std.ascii.isDigit(inputLC[end])) end += 1;

    const age = std.fmt.parseInt(u32, inputLC[start..end], 10) catch return "<age:nonsense>";
    if (age == 0 or age > MaxPlausibleAge) return "<age:nonsense>";
    if (age < MinAdultAge) return "<age:young>";
    if (age <= MaxFavoredAge) return "<age:ok>";
    return "<age:old>";
}

/// Parses a single-digit argument (e.g. the "7" of ".pitch 7"), at most `max`.
fn parseDigitArg(arg: []const u8, max: u8) ?u8 {
    const a = std.mem.trim(u8, arg, " ");
    if (a.len != 1 or !std.ascii.isDigit(a[0])) return null;
    const d = a[0] - '0';
    return if (d <= max) d else null;
}

/// Handles .tone, .volume, .pitch, .speed and .param. With no argument, the
/// current value is reported instead.
fn handleVoiceCommand(inputLC: []const u8, handled: *bool) !?[]const u8 {
    const VoiceCmd = struct { name: []const u8, label: []const u8, max: u8 };
    const cmds = [_]VoiceCmd{
        .{ .name = ".tone", .label = "TONE", .max = 1 },
        .{ .name = ".volume", .label = "VOLUME", .max = 9 },
        .{ .name = ".pitch", .label = "PITCH", .max = 9 },
        .{ .name = ".speed", .label = "SPEED", .max = 9 },
        .{ .name = ".bass", .label = "BASS", .max = 9 },
        .{ .name = ".stereo", .label = "STEREO", .max = 9 },
        .{ .name = ".reverb", .label = "REVERB", .max = 9 },
    };
    const rAlloc = responseArena.allocator();
    var p = sbaitsoProvider.getParams();

    for (cmds, 0..) |cmd, idx| {
        if (!std.mem.startsWith(u8, inputLC, cmd.name)) continue;
        const arg = std.mem.trim(u8, inputLC[cmd.name.len..], " ");
        const field: *u8 = switch (idx) {
            0 => &p.tone,
            1 => &p.volume,
            2 => &p.pitch,
            3 => &p.speed,
            4 => &p.bass,
            5 => &p.stereo,
            else => &p.reverb,
        };
        handled.* = true;

        if (arg.len == 0) {
            return try std.fmt.allocPrint(rAlloc, "{s} IS {d}.", .{ cmd.label, field.* });
        }
        const value = parseDigitArg(arg, cmd.max) orelse {
            if (idx == 0) return "TONE MUST BE 1 OR 0.";
            return try std.fmt.allocPrint(rAlloc, "{s} MUST BE A DIGIT FROM 0 TO 9.", .{cmd.label});
        };
        field.* = value;
        sbaitsoProvider.setParams(p);

        if (idx == 0) return if (value == 0) "O K, BASS TONE IT IS." else "O K, TREBLE TONE IT IS.";
        if (value == 0) switch (idx) {
            4 => return "O K, BASS BOOST IS OFF.",
            5 => return "O K, BACK TO MONO.",
            6 => return "O K, REVERB IS OFF.",
            else => {},
        };
        return try std.fmt.allocPrint(rAlloc, "O K, {s} IS NOW {d}.", .{ cmd.label, value });
    }

    // ".param tvps": all four at once, or ".param d" for the defaults.
    if (std.mem.startsWith(u8, inputLC, ".param")) {
        handled.* = true;
        const arg = std.mem.trim(u8, inputLC[".param".len..], " ");

        if (std.mem.eql(u8, arg, "d")) {
            p = .{};
        } else if (arg.len == 0) {
            return try std.fmt.allocPrint(rAlloc, "TONE {d}, VOLUME {d}, PITCH {d}, SPEED {d}.", .{ p.tone, p.volume, p.pitch, p.speed });
        } else {
            if (arg.len != 4) return "NEED TO ENTER 4 DIGITS, TRY AGAIN.";
            for (arg) |c| if (!std.ascii.isDigit(c)) return "NEED TO ENTER 4 DIGITS, TRY AGAIN.";
            if (arg[0] > '1') return "TONE MUST BE 1 OR 0.";
            p = .{ .tone = arg[0] - '0', .volume = arg[1] - '0', .pitch = arg[2] - '0', .speed = arg[3] - '0', .bass = p.bass, .stereo = p.stereo, .reverb = p.reverb };
        }

        sbaitsoProvider.setParams(p);
        return try std.fmt.allocPrint(rAlloc, "O K. TONE {d}, VOLUME {d}, PITCH {d}, SPEED {d}.", .{ p.tone, p.volume, p.pitch, p.speed });
    }

    return null;
}

/// Handles "CALC <equation>" and "WHAT IS <equation>".
fn handleCalc(inputLC: []const u8, handled: *bool) !?[]const u8 {
    var equation: []const u8 = undefined;
    if (std.mem.startsWith(u8, inputLC, "calc ") or std.mem.eql(u8, inputLC, "calc")) {
        equation = inputLC["calc".len..];
    } else if (std.mem.startsWith(u8, inputLC, "what is ") and calc.looksLikeMath(inputLC["what is ".len..])) {
        // Only when it's actually math; "WHAT IS LOVE" is conversation.
        equation = inputLC["what is ".len..];
    } else {
        return null;
    }

    handled.* = true;
    const result = calc.evaluate(equation) catch |err| return switch (err) {
        error.BracketsTooComplex => "CANNOT COMPUTE, BRACKETS ARE TOO COMPLEX FOR ME.",
        error.BadEquation => "DOESN'T COMPUTE, I THINK THERE IS A BUG IN YOUR EQUATION.",
    };
    return try calc.describe(responseArena.allocator(), equation, result);
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
        const result = try std.fmt.allocPrint(
            responseArena.allocator(),
            "YOU ARE SIMPLY KNOWN AS: {s}.",
            .{
                notes.patientName[0..notes.patientNameSize],
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

    // ".restart" command: a new patient. Everything is cleared (as with
    // .reset, plus the screen, the name and the conversation so far), then
    // Sbaitso does his banner and asks for a name again.
    if (std.mem.startsWith(u8, inputLC, ".restart")) {
        restartSession();
        handled.* = true;
        return RestartToken;
    }

    // ".reset" command: resets the entire sbaitso environment.
    if (std.mem.startsWith(u8, inputLC, ".reset")) {
        notes.bgColor = 0;
        notes.ftColor = 0;
        notes.awaitingAge = false;
        sbaitsoBrainProvider.memory.clear();
        sbaitsoProvider.setParams(.{});
        handled.* = true;
        return null;
    }

    // "help" command: shows the help screen. Only the bare word, so that
    // "HELP ME" is still conversation.
    const trimmedLC = std.mem.trim(u8, inputLC, " ");
    if (std.mem.eql(u8, trimmedLC, "help") or std.mem.eql(u8, trimmedLC, ".help")) {
        handled.* = true;
        return HelpToken;
    }

    // Voice commands: .tone, .volume, .pitch, .speed, .param
    if (try handleVoiceCommand(inputLC, handled)) |resp| return resp;

    // "calc" command, or "what is" followed by an equation.
    if (try handleCalc(inputLC, handled)) |resp| return resp;

    // "say" command: sbaitso will say whatever, and I mean whatever you tell him to say.
    if (std.mem.startsWith(u8, inputLC, "say")) {
        handled.* = true;
        if (is_web) return "The say command isn't available on the web";
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

        // Convert to a hexademical string. hexResult lives on this block's
        // stack, so copy it out before the block ends.
        const hexResult = std.fmt.bytesToHex(out[0..], .lower);
        hashed_hex_output = try responseArena.allocator().dupe(u8, &hexResult);
    }

    // ".sha1" command: sbaitso will compute the sha1 of anything and then say the result.
    if (std.mem.startsWith(u8, inputLC, ".sha1 ")) {
        const sha1 = std.crypto.hash.Sha1;
        var h = sha1.init(.{});

        var out: [sha1.digest_length]u8 = undefined;
        h.update(notes.patientInput[5..notes.patientInputSize]);
        h.final(out[0..]);

        // Convert to a hexademical string. hexResult lives on this block's
        // stack, so copy it out before the block ends.
        const hexResult = std.fmt.bytesToHex(out[0..], .lower);
        hashed_hex_output = try responseArena.allocator().dupe(u8, &hexResult);
    }

    if (hashed_hex_output) |out| {
        handled.* = true;
        return out;
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

    // 0.c Sbaitso asked for the patient's age; this reply is the answer.
    if (notes.awaitingAge) {
        notes.awaitingAge = false;
        return sbaitsoBrainProvider.chooseAction(ageReaction(inputLC));
    }

    // 1.a Check for repeated inputs
    if (std.mem.eql(u8, inputLC, notes.prevPatientInput[0..notes.prevPatientInputSize])) {
        // Randomly select from both repeat tables...it don't matter much here.
        return sbaitsoBrainProvider.chooseAction(if (rl.getRandomValue(0, 100) > 50) "<repeat>" else "<repeat-2x>");
    }

    // 2. Brain processing is here. Short input goes to the brain too, so
    // one-word keywords (HELLO, YES, MAYBE, WHY...) still get their answers.
    const brainEngineFn = brainEngines[notes.brainEngine];
    if (try brainEngineFn(gIo, inputLC, responseArena.allocator())) |result| {
        return result;
    }

    // 3. Too short responses, when the brain had nothing to say about it.
    if (inputLC.len <= ShortInputThreshold) {
        return sbaitsoBrainProvider.chooseAction("<too-short>");
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
            if (notes.state == .sbaitso_help) {
                try drawHelp();
            } else {
                try drawScrollBuffer();

                // Calculate cursor/input buffer yOffset based on scrollBuffer.
                const inputYOffset = scrollBufferYOffset + (scrollBuffer.items.len * scrollBufferYSpacing);
                const loc: rl.Vector2 = .{ .x = 0, .y = @floatFromInt(inputYOffset) };
                try drawInputBuffer(.{ .x = loc.x + 10, .y = loc.y });
                try drawCursor(loc);
            }

            // Debug drawing when LEFT SHIT IS HELD DOWN only (never on the web).
            if (!is_web and rl.isKeyDown(.left_shift)) {
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
        drawPowerButton();
    }
}

/// Procedurally draws a large power symbol in the middle of the window (shown
/// until the user powers on the app), gently pulsing to invite a click.
fn drawPowerButton() void {
    const w: f32 = @floatFromInt(rl.getScreenWidth());
    const h: f32 = @floatFromInt(rl.getScreenHeight());
    const center: rl.Vector2 = .{ .x = w / 2, .y = h / 2 };

    // Roughly 1/10 the size of the screen.
    const outer = @min(w, h) / 10 / 2;
    const thick = outer * 0.18;
    const inner = outer - thick;
    const mid = outer - thick / 2;

    const pulse: f32 = 0.7 + 0.3 * @as(f32, @floatCast(@sin(rl.getTime() * 2.5)));
    const color = hexToColor(0xD5D5D5FF).fade(pulse);

    // The ring, open at the top (raylib angles: 270 degrees points straight up).
    const gapHalf = 35.0;
    const startAngle = 270.0 + gapHalf;
    const endAngle = 270.0 + 360.0 - gapHalf;
    rl.drawRing(center, inner, outer, startAngle, endAngle, 64, color);

    // Round caps on both ends of the ring.
    for ([_]f32{ startAngle, endAngle }) |deg| {
        const rad = std.math.degreesToRadians(deg);
        rl.drawCircleV(.{ .x = center.x + @cos(rad) * mid, .y = center.y + @sin(rad) * mid }, thick / 2, color);
    }

    // The vertical bar through the gap, with rounded ends.
    const barTop = center.y - outer - thick * 0.4;
    const barBottom = center.y - thick * 0.6;
    rl.drawRectangleRounded(
        .{ .x = center.x - thick / 2, .y = barTop, .width = thick, .height = barBottom - barTop },
        1.0,
        16,
        color,
    );
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

/// Speaks a letter of the patient's name as it's typed, as the original does.
fn playSbaitsoLetterSound(letter: u8) void {
    if (notes.speechEngine != 0) {
        // NOTE: as of right now, we should only be playing this for Sbaitso's original voice.
        // We're not yet doing this correctly for all voices universally.
        return;
    }

    if (std.ascii.isAlphabetic(letter)) {
        sbaitsoProvider.sayLetter(allocator, letter) catch |err| std.log.err("sayLetter: {t}", .{err});
    }
}

fn loadFont() !void {

    // Just add more symbols, order does not matter.
    const cp = try rl.loadCodepoints(" 0123456789!@#$%^&*()/<>\\:;.,\"'?_~+-=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ║╔═╗─╚═╝╟╢");
    // loadFontEx copies what it needs out of cp.
    defer rl.unloadCodepoints(cp);

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

test "addScrollBufferLine: wraps long text at word boundaries" {
    allocator = std.testing.allocator;
    defer clearScrollBuffer();

    const longLine = "Booty be the damn lifeblood of a pirate, ye bloody fool! And yes, I'd lick any damn shiny gold for more booty!";
    try addScrollBufferLine(.sbaitso, longLine);

    for (scrollBuffer.items) |entry| {
        try std.testing.expect(entry.line.len <= MAX_INPUT_LINE_CHARS);
        // No row should start with a space -- i.e. every row must be
        // entirely whole words, never a broken partial word.
        try std.testing.expect(entry.line.len == 0 or entry.line[0] != ' ');
    }

    // Rebuilding the wrapped rows (space-joined) must reproduce the exact
    // original words in order -- proof nothing was split mid-word.
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(std.testing.allocator);
    for (scrollBuffer.items, 0..) |entry, i| {
        if (i != 0) try rebuilt.append(std.testing.allocator, ' ');
        try rebuilt.appendSlice(std.testing.allocator, entry.line);
    }
    try std.testing.expectEqualStrings(longLine, rebuilt.items);
}

test "addScrollBufferLine: unsplittable overlong word overflows its own row" {
    allocator = std.testing.allocator;
    defer clearScrollBuffer();

    const hugeWord = "x" ** 200;
    const inputLine = "short words then " ++ hugeWord ++ " then more short words";
    try addScrollBufferLine(.sbaitso, inputLine);

    var found = false;
    for (scrollBuffer.items) |entry| {
        if (std.mem.eql(u8, entry.line, hugeWord)) found = true;
    }
    try std.testing.expect(found);
}

/// Runs one conversation turn with the Eliza brain and returns the response.
fn testTurn(input: []const u8) !?[]const u8 {
    @memcpy(notes.patientInput[0..input.len], input);
    notes.patientInputSize = input.len;
    _ = responseArena.reset(.retain_capacity);
    return getOneLine();
}

fn testBeginConversation() void {
    responseArena = .init(std.testing.allocator);
    notes = DrNotes{};
    notes.brainEngine = 0;
    timeoutTicks = 0;
    const name = "TESTER";
    @memcpy(notes.patientName[0..name.len], name);
    notes.patientNameSize = name.len;
}

test "short input still matches one-word keywords" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    testBeginConversation();
    defer responseArena.deinit();
    defer clearScrollBuffer();

    try std.testing.expectEqualStrings("HELLO TESTER, I AM DOCTOR SBAITSO, WHAT IS YOUR PROBLEM?", (try testTurn("hello")).?);

    // No keyword at all: still too short.
    const tooShort = sbaitsoBrainProvider.map.get("<too-short>").?;
    const resp = (try testTurn("zzq")).?;
    var found = false;
    for (tooShort.reassemblies) |r| {
        if (std.mem.eql(u8, r, resp)) found = true;
    }
    try std.testing.expect(found);
}

test "age question: the next reply is judged as an age" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    testBeginConversation();
    defer responseArena.deinit();
    defer clearScrollBuffer();

    // BASTARD's third line asks the patient's age (`4).
    _ = try testTurn("you bastard");
    _ = try testTurn("you are a bastard");
    try std.testing.expectEqualStrings("O K, HOW OLD ARE YOU?", (try testTurn("what a bastard")).?);
    try std.testing.expect(notes.awaitingAge);

    try std.testing.expectEqualStrings("OH! YOU ARE JUST MY TYPE", (try testTurn("i am 25")).?);
    try std.testing.expect(!notes.awaitingAge);

    try std.testing.expectEqualStrings("<age:young>", ageReaction("12"));
    try std.testing.expectEqualStrings("<age:old>", ageReaction("i'm 64 years old"));
    try std.testing.expectEqualStrings("<age:young>", ageReaction("none of your business"));
    try std.testing.expectEqualStrings("<age:nonsense>", ageReaction("999"));
}

test "bad language eventually causes a parity error" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    testBeginConversation();
    defer responseArena.deinit();
    defer clearScrollBuffer();

    // The BASTARD table ends in PARITY; alternate wording to dodge the repeat
    // check. One extra turn, since one of its lines asks for an age and the
    // next reply is taken as the answer.
    const inputs = [_][]const u8{ "you bastard", "you are a bastard" };
    var sawParity = false;
    for (0..sbaitsoBrainProvider.map.get("BASTARD").?.reassemblies.len + 1) |i| {
        const resp = (try testTurn(inputs[i % 2])).?;
        if (std.mem.eql(u8, resp, ParityToken)) sawParity = true;
        // Action codes never reach the screen.
        try std.testing.expect(resp[0] != '`');
    }
    try std.testing.expect(sawParity);
}

test "calc and voice commands" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    testBeginConversation();
    defer responseArena.deinit();
    defer clearScrollBuffer();
    defer sbaitsoProvider.setParams(.{});

    try std.testing.expectEqualStrings("2 PLUS 3 EQUALS TO 5", (try testTurn("what is 2 + 3?")).?);
    try std.testing.expectEqualStrings("(2 PLUS 3) TIMES 4 EQUALS TO 20", (try testTurn("calc (2+3)*4")).?);
    try std.testing.expectEqualStrings("DOESN'T COMPUTE, I THINK THERE IS A BUG IN YOUR EQUATION.", (try testTurn("calc 2 +")).?);

    try std.testing.expectEqualStrings("O K, PITCH IS NOW 7.", (try testTurn(".pitch 7")).?);
    try std.testing.expectEqual(@as(u8, 7), sbaitsoProvider.getParams().pitch);
    try std.testing.expectEqualStrings("TONE MUST BE 1 OR 0.", (try testTurn(".tone 5")).?);
    try std.testing.expectEqualStrings("BASS IS 5.", (try testTurn(".bass")).?); // the default
    try std.testing.expectEqualStrings("O K, BASS IS NOW 4.", (try testTurn(".bass 4")).?);
    try std.testing.expectEqualStrings("O K. TONE 1, VOLUME 8, PITCH 5, SPEED 0.", (try testTurn(".param 1850")).?);
    try std.testing.expectEqual(@as(u8, 4), sbaitsoProvider.getParams().bass); // .param leaves bass alone
    try std.testing.expectEqualStrings("O K, BASS BOOST IS OFF.", (try testTurn(".bass 0")).?);
    try std.testing.expectEqualStrings("O K, STEREO IS NOW 6.", (try testTurn(".stereo 6")).?);
    try std.testing.expectEqualStrings("O K, REVERB IS NOW 3.", (try testTurn(".reverb 3")).?);
    try std.testing.expectEqualStrings("O K. TONE 0, VOLUME 5, PITCH 5, SPEED 5.", (try testTurn(".param 0555")).?);
    try std.testing.expectEqual(@as(u8, 6), sbaitsoProvider.getParams().stereo); // .param leaves effects alone
    try std.testing.expectEqual(@as(u8, 3), sbaitsoProvider.getParams().reverb);
    try std.testing.expectEqualStrings("O K, BACK TO MONO.", (try testTurn(".stereo 0")).?);
    try std.testing.expectEqualStrings("O K, REVERB IS OFF.", (try testTurn(".reverb 0")).?);
    _ = try testTurn(".param d");
    const defaults = sbaitsoProvider.getParams();
    try std.testing.expectEqual(@as(u8, 5), defaults.bass);
    try std.testing.expectEqual(@as(u8, 4), defaults.stereo);
    try std.testing.expectEqual(@as(u8, 1), defaults.reverb);
    try std.testing.expectEqualStrings("NEED TO ENTER 4 DIGITS, TRY AGAIN.", (try testTurn(".param 12")).?);

    try std.testing.expectEqualStrings(HelpToken, (try testTurn("help")).?);
}

test ".restart clears the patient and starts over" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    testBeginConversation();
    defer responseArena.deinit();
    defer clearScrollBuffer();
    defer sbaitsoProvider.setParams(.{});

    _ = try testTurn("i had a strange dream");
    _ = try testTurn(".pitch 2");
    notes.bgColor = 3;
    notes.awaitingAge = true;
    try std.testing.expect(scrollBuffer.items.len > 0);

    try std.testing.expectEqualStrings(RestartToken, (try testTurn(".restart")).?);
    try std.testing.expectEqual(@as(usize, 0), scrollBuffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), notes.patientNameSize);
    try std.testing.expectEqual(@as(usize, 0), notes.bgColor);
    try std.testing.expect(!notes.awaitingAge);
    try std.testing.expect(sbaitsoBrainProvider.memory.isEmpty());
    try std.testing.expectEqual(@as(u8, 5), sbaitsoProvider.getParams().pitch);
    try std.testing.expectEqual(@as(usize, 0), sbaitsoBrainProvider.map.get("DREAM").?.roundRobin);
}

test ".md5 and .sha1 say the hash of the text" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    testBeginConversation();
    defer responseArena.deinit();
    defer clearScrollBuffer();

    try std.testing.expectEqualStrings("5d41402abc4b2a76b9719d911017c592", (try testTurn(".md5 hello")).?);
    // NOTE: .sha1 currently hashes " hello" (the space after the command is included).
    try std.testing.expectEqual(@as(usize, 40), (try testTurn(".sha1 hello")).?.len);
}

test "repeat one time" {}

test "repeat 2x" {}
