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
