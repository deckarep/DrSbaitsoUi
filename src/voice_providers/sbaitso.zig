const std = @import("std");
const rl = @import("raylib");

// The speech engine lives in libsbaitso_native.a (the native Zig synthesizer,
// no emulator), built by the separate (private) DrSbaitsoLib project and linked
// in by build.zig -- it is never checked into this repo. Its C API is
// synchronous (see DrSbaitsoLib/zig-out/include/sbaitso_native.h), which suits
// the web build since it has no threads.
const Engine = opaque {};
const MODE_FIXED: c_int = 0; // <<codes>> stay in effect in long text.
extern fn sbaitso_native_create(mode: c_int) ?*Engine;
extern fn sbaitso_native_say(
    s: *Engine,
    text: [*]const u8,
    len: usize,
    out_samples: *?[*]i16,
    out_count: *usize,
    out_rate: *u32,
) c_int;
extern fn sbaitso_native_free_samples(samples: [*]i16, count: usize) void;

const EngineSettings = extern struct {
    gender: c_int, // accepted, but has no audible effect (single voice).
    tone: c_int, // 0 = bass, 1 = treble
    volume: c_int, // 0..9
    pitch: c_int, // 0..9
    speed: c_int, // 0..9
};
extern fn sbaitso_native_set_settings(s: *Engine, settings: *const EngineSettings) c_int;

/// Voice parameters, as set by the .tone/.volume/.pitch/.speed/.param commands.
pub const VoiceParams = struct {
    tone: u8 = 0,
    volume: u8 = 5,
    pitch: u8 = 5,
    speed: u8 = 5,

    fn pack(self: VoiceParams) u32 {
        return @as(u32, self.tone) | @as(u32, self.volume) << 8 | @as(u32, self.pitch) << 16 | @as(u32, self.speed) << 24;
    }

    fn unpack(v: u32) VoiceParams {
        return .{
            .tone = @truncate(v),
            .volume = @truncate(v >> 8),
            .pitch = @truncate(v >> 16),
            .speed = @truncate(v >> 24),
        };
    }
};

// Written by the main thread, applied by whichever thread speaks (the speech
// thread natively, the main thread on the web), so it's packed into one atomic.
var params = std.atomic.Value(u32).init((VoiceParams{}).pack());
// What the engine was last configured with; only touched by the speaking thread.
var appliedParams: ?u32 = null;

pub fn getParams() VoiceParams {
    return VoiceParams.unpack(params.load(.acquire));
}

/// Takes effect from the next spoken line.
pub fn setParams(p: VoiceParams) void {
    params.store(p.pack(), .release);
}

// Booted lazily on first use, then reused for the life of the app.
var engine: ?*Engine = null;

/// Invoked repeatedly while waiting on playback to finish. The web build has
/// no speech thread, so main.zig sets this to keep frames rendering (and the
/// browser event loop running) while Sbaitso talks. When null, just sleep.
pub var waitHook: ?*const fn () void = null;

fn ensureEngine(e: *?*Engine) !*Engine {
    if (e.* == null) {
        e.* = sbaitso_native_create(MODE_FIXED) orelse return error.SbaitsoEngineCreateFailed;
    }
    return e.*.?;
}

/// Configures `e` with the current voice params unless it already has them.
fn applyParams(e: *Engine, applied: *?u32) !void {
    const wanted = params.load(.acquire);
    if (applied.* == wanted) return;
    const p = VoiceParams.unpack(wanted);
    const settings: EngineSettings = .{
        .gender = 0,
        .tone = p.tone,
        .volume = p.volume,
        .pitch = p.pitch,
        .speed = p.speed,
    };
    if (sbaitso_native_set_settings(e, &settings) != 0) {
        return error.SbaitsoSetSettingsFailed;
    }
    applied.* = wanted;
}

/// Synthesizes `msg` (blocking, but only for the synthesis, not playback).
/// Returns null when there's nothing to play. The caller unloads the sound.
fn synthesize(e: *Engine, msg: []const u8) !?rl.Sound {
    var samples: ?[*]i16 = null;
    var count: usize = 0;
    var rate: u32 = 0;
    if (sbaitso_native_say(e, msg.ptr, msg.len, &samples, &count, &rate) != 0) {
        return error.SbaitsoSayFailed;
    }
    const pcm = samples orelse return null;
    defer sbaitso_native_free_samples(pcm, count);
    if (count == 0) return null;

    // Mono, signed 16-bit PCM; raylib copies the samples.
    return rl.loadSoundFromWave(.{
        .frameCount = @intCast(count),
        .sampleRate = rate,
        .sampleSize = 16,
        .channels = 1,
        .data = @ptrCast(pcm),
    });
}

// sayLetter's own synthesizer: `engine` may be busy on the speech thread, and
// a synthesizer must only be used from one thread.
var letterEngine: ?*Engine = null;
var letterAppliedParams: ?u32 = null;
var letterSound: ?rl.Sound = null;

/// Speaks one typed character without blocking, as the original echoes each
/// letter of the patient's name. A new letter cuts off the previous one.
/// Main thread only.
pub fn sayLetter(ch: u8) !void {
    const e = try ensureEngine(&letterEngine);
    try applyParams(e, &letterAppliedParams);
    stopLetter();
    letterSound = try synthesize(e, &.{ch});
    if (letterSound) |sound| rl.playSound(sound);
}

/// Stops and frees the last sayLetter sound; call before closing the audio device.
pub fn stopLetter() void {
    if (letterSound) |sound| {
        rl.stopSound(sound);
        rl.unloadSound(sound);
        letterSound = null;
    }
}

/// speakMany is for speaking multiple messages, synchronously.
/// This means, as soon as the last message finishes, the next will
/// be spoken.
pub fn speakMany(io: std.Io, msgs: []const []const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;

    const e = try ensureEngine(&engine);
    try applyParams(e, &appliedParams);

    for (msgs) |msg| {
        // Blocks while the speech is synthesized (not played).
        const sound = try synthesize(e, msg) orelse continue;
        defer rl.unloadSound(sound);

        // Block until playback is done.
        rl.playSound(sound);
        while (rl.isSoundPlaying(sound)) {
            if (waitHook) |hook| {
                hook();
            } else {
                try io.sleep(.fromMilliseconds(10), .awake);
            }
        }
    }
}
