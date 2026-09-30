const std = @import("std");
const rl = @import("raylib");

// The speech engine lives in libsbaitso.a, built by the separate (private)
// DrSbaitsoLib project and linked in by build.zig -- it is never checked into
// this repo. Only the synchronous sbaitso_engine_* C API is used (see
// DrSbaitsoLib/include/sbaitso.h) since the web build has no threads.
const Engine = opaque {};
extern fn sbaitso_engine_create() ?*Engine;
extern fn sbaitso_engine_say(
    e: *Engine,
    text: [*]const u8,
    len: usize,
    out_samples: *?[*]i16,
    out_count: *usize,
    out_rate: *u32,
) c_int;
extern fn sbaitso_free_samples(samples: [*]i16, count: usize) void;

const EngineSettings = extern struct {
    gender: c_int, // accepted, but SBTALKER only ships a male voice.
    tone: c_int, // 0 = bass, 1 = treble
    volume: c_int, // 0..9
    pitch: c_int, // 0..9
    speed: c_int, // 0..9
};
extern fn sbaitso_engine_set_settings(e: *Engine, settings: *const EngineSettings) c_int;

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

/// speakMany is for speaking multiple messages, synchronously.
/// This means, as soon as the last message finishes, the next will
/// be spoken.
pub fn speakMany(io: std.Io, msgs: []const []const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;

    if (engine == null) {
        engine = sbaitso_engine_create() orelse return error.SbaitsoEngineCreateFailed;
    }

    const wanted = params.load(.acquire);
    if (appliedParams != wanted) {
        const p = VoiceParams.unpack(wanted);
        const settings: EngineSettings = .{
            .gender = 0,
            .tone = p.tone,
            .volume = p.volume,
            .pitch = p.pitch,
            .speed = p.speed,
        };
        if (sbaitso_engine_set_settings(engine.?, &settings) != 0) {
            return error.SbaitsoSetSettingsFailed;
        }
        appliedParams = wanted;
    }

    for (msgs) |msg| {
        var samples: ?[*]i16 = null;
        var count: usize = 0;
        var rate: u32 = 0;

        // Blocks while the speech is synthesized (not played).
        if (sbaitso_engine_say(engine.?, msg.ptr, msg.len, &samples, &count, &rate) != 0) {
            return error.SbaitsoSayFailed;
        }
        const pcm = samples orelse continue;
        defer sbaitso_free_samples(pcm, count);
        if (count == 0) continue;

        // Mono, signed 16-bit PCM; raylib copies the samples.
        const sound = rl.loadSoundFromWave(.{
            .frameCount = @intCast(count),
            .sampleRate = rate,
            .sampleSize = 16,
            .channels = 1,
            .data = @ptrCast(pcm),
        });
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
