const std = @import("std");

// Optional post-processing of Sbaitso's speech (the .bass/.stereo/.reverb
// commands). The synthesizer outputs mono 16-bit PCM at ~8.5 kHz; with every
// effect off it is played untouched, exactly as the original sounded.

/// Each level is 0 (off) .. 9.
pub const Settings = struct {
    bass: u8 = 0,
    stereo: u8 = 0,
    reverb: u8 = 0,

    pub fn allOff(self: Settings) bool {
        return self.bass == 0 and self.stereo == 0 and self.reverb == 0;
    }
};

pub const Rendered = struct {
    /// Interleaved when channels == 2. Free with the allocator given to render.
    samples: []i16,
    channels: u8,

    pub fn frames(self: Rendered) usize {
        return self.samples.len / self.channels;
    }
};

/// Applies the effects to `mono`: bass first (it shapes the voice itself),
/// then reverb (fed the shaped voice; its tail lengthens the clip), then stereo
/// widening of the voice (the reverb already has its own left/right tails). Output is stereo only when
/// `s.stereo` > 0. If the result would clip, it's scaled down as a whole to
/// fit. Returns null when every effect is off: play `mono` as is.
pub fn render(alloc: std.mem.Allocator, mono: []const i16, rate: u32, s: Settings) !?Rendered {
    if (s.allOff() or mono.len == 0) return null;

    const tail = reverbTail(rate, s.reverb);
    const n = mono.len + tail;

    const dry = try alloc.alloc(f32, n);
    defer alloc.free(dry);
    for (dry[0..mono.len], mono) |*d, m| d.* = @floatFromInt(m);
    @memset(dry[mono.len..], 0);

    bassBoost(dry, rate, s.bass);

    // Reverb, one tail per channel (slightly different rooms, for width).
    const wet_l = try alloc.alloc(f32, n);
    defer alloc.free(wet_l);
    const wet_r = try alloc.alloc(f32, n);
    defer alloc.free(wet_r);
    reverb(dry, wet_l, wet_r, rate, s.reverb);

    const channels: u8 = if (s.stereo > 0) 2 else 1;
    const out = try alloc.alloc(f32, n * channels);
    defer alloc.free(out);
    if (channels == 2) {
        widen(dry, out, rate, s.stereo);
        for (0..n) |i| {
            out[2 * i] += wet_l[i];
            out[2 * i + 1] += wet_r[i];
        }
    } else {
        for (out, dry, wet_l, wet_r) |*o, d, l, r| o.* = d + 0.5 * (l + r);
    }

    var peak: f32 = 0;
    for (out) |v| peak = @max(peak, @abs(v));
    const scale: f32 = if (peak > 32767.0) 32767.0 / peak else 1.0;

    const samples = try alloc.alloc(i16, out.len);
    for (samples, out) |*o, v| o.* = @intFromFloat(std.math.clamp(@round(v * scale), -32768.0, 32767.0));
    return .{ .samples = samples, .channels = channels };
}

/// Bass boost (`.bass n`): a low-shelf filter (RBJ biquad) adding 1.5 dB per
/// level below ~200 Hz, where the thin 8 kHz voice gains body; deeper than
/// that there is little but rumble. Level 0 leaves the samples alone.
fn bassBoost(x: []f32, rate: u32, level: u8) void {
    if (level == 0) return;

    const shelf_hz = 200.0;
    const gain_db = 1.5 * @as(f64, @floatFromInt(level));
    const A = std.math.pow(f64, 10.0, gain_db / 40.0);
    const w0 = 2.0 * std.math.pi * shelf_hz / @as(f64, @floatFromInt(rate));
    const cos_w0 = @cos(w0);
    const alpha = @sin(w0) / 2.0 * std.math.sqrt2; // shelf slope S = 1
    const two_sqrt_a_alpha = 2.0 * @sqrt(A) * alpha;

    const a0 = (A + 1) + (A - 1) * cos_w0 + two_sqrt_a_alpha;
    const b0 = A * ((A + 1) - (A - 1) * cos_w0 + two_sqrt_a_alpha) / a0;
    const b1 = 2 * A * ((A - 1) - (A + 1) * cos_w0) / a0;
    const b2 = A * ((A + 1) - (A - 1) * cos_w0 - two_sqrt_a_alpha) / a0;
    const a1 = -2 * ((A - 1) + (A + 1) * cos_w0) / a0;
    const a2 = ((A + 1) + (A - 1) * cos_w0 - two_sqrt_a_alpha) / a0;

    var x1: f64 = 0;
    var x2: f64 = 0;
    var y1: f64 = 0;
    var y2: f64 = 0;
    for (x) |*sample| {
        const in: f64 = sample.*;
        const y = b0 * in + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = in;
        y2 = y1;
        y1 = y;
        sample.* = @floatCast(y);
    }
}

/// Stereo widening (`.stereo n`), mid/side style: left = voice + side,
/// right = voice - side, where side is a ~12 ms delayed copy of the voice with
/// its lows removed (so the bass stays centered and solid). Left + right is
/// exactly twice the voice, so on a mono speaker nothing changes.
/// `out` is interleaved stereo, twice the length of `x`.
fn widen(x: []const f32, out: []f32, rate: u32, level: u8) void {
    const width: f32 = 0.07 * @as(f32, @floatFromInt(level)); // up to 0.63
    const delay = @max(1, rate * 12 / 1000);
    var hp = HighPass.init(300, rate);
    for (x, 0..) |mid, i| {
        const delayed = if (i >= delay) x[i - delay] else 0;
        const side = width * hp.process(delayed);
        out[2 * i] = mid + side;
        out[2 * i + 1] = mid - side;
    }
}

/// One-pole high-pass filter.
const HighPass = struct {
    a: f32,
    prev_in: f32 = 0,
    prev_out: f32 = 0,

    fn init(cutoff_hz: f32, rate: u32) HighPass {
        const rc = 1.0 / (2.0 * std.math.pi * cutoff_hz);
        const dt = 1.0 / @as(f32, @floatFromInt(rate));
        return .{ .a = rc / (rc + dt) };
    }

    fn process(f: *HighPass, in: f32) f32 {
        const out = f.a * (f.prev_out + in - f.prev_in);
        f.prev_in = in;
        f.prev_out = out;
        return out;
    }
};

// Reverb (`.reverb n`): a small Freeverb-style room, 4 damped comb filters in
// parallel into 2 all-passes, per channel. The delay lengths are Freeverb's
// (tuned for 44.1 kHz) scaled to the synth's rate; the right channel's are a
// little longer so the two tails differ.
const comb_tunings = [_]u32{ 1116, 1188, 1277, 1356 };
const allpass_tunings = [_]u32{ 556, 441 };
const stereo_spread = 23;
const freeverb_rate = 44100;
// Big enough for the longest delay at rates up to 48 kHz.
const max_delay = (1356 + stereo_spread) * 48000 / freeverb_rate + 1;

/// How many samples of silence to append so the reverb tail can ring out.
fn reverbTail(rate: u32, level: u8) usize {
    if (level == 0) return 0;
    // 0.3 s at level 1 up to 1.5 s at level 9.
    return @as(usize, rate) * (150 + 150 * @as(usize, level)) / 1000;
}

const Comb = struct {
    buf: [max_delay]f32 = undefined,
    len: usize,
    idx: usize = 0,
    store: f32 = 0,

    fn init(len: usize) Comb {
        var c: Comb = .{ .len = len };
        @memset(c.buf[0..len], 0);
        return c;
    }

    fn process(c: *Comb, in: f32, feedback: f32, damp: f32) f32 {
        const out = c.buf[c.idx];
        c.store = out * (1 - damp) + c.store * damp;
        c.buf[c.idx] = in + c.store * feedback;
        c.idx = (c.idx + 1) % c.len;
        return out;
    }
};

const Allpass = struct {
    buf: [max_delay]f32 = undefined,
    len: usize,
    idx: usize = 0,

    fn init(len: usize) Allpass {
        var a: Allpass = .{ .len = len };
        @memset(a.buf[0..len], 0);
        return a;
    }

    fn process(a: *Allpass, in: f32) f32 {
        const buffered = a.buf[a.idx];
        a.buf[a.idx] = in + buffered * 0.5;
        a.idx = (a.idx + 1) % a.len;
        return buffered - in;
    }
};

/// Writes the wet (reverb only) signal for each channel; zeros when level is 0.
/// The room is fed the voice minus its lows (below ~250 Hz), so a boosted bass
/// stays punchy in the voice instead of booming around the room.
fn reverb(x: []const f32, wet_l: []f32, wet_r: []f32, rate: u32, level: u8) void {
    @memset(wet_l, 0);
    @memset(wet_r, 0);
    if (level == 0) return;

    const lvl: f32 = @floatFromInt(level);
    const feedback = 0.70 + 0.02 * lvl; // room size: 0.72 .. 0.88
    const damp = 0.4;
    const mix = 0.06 * lvl; // wet level relative to the voice: 0.06 .. 0.54

    for ([_][]f32{ wet_l, wet_r }, 0..) |wet, ch| {
        const spread: u32 = if (ch == 0) 0 else stereo_spread;
        var combs: [comb_tunings.len]Comb = undefined;
        for (&combs, comb_tunings) |*c, t| c.* = .init(scaled(t + spread, rate));
        var allpasses: [allpass_tunings.len]Allpass = undefined;
        for (&allpasses, allpass_tunings) |*a, t| a.* = .init(scaled(t + spread, rate));

        var hp = HighPass.init(250, rate);
        for (x, wet) |in, *o| {
            const fed = hp.process(in);
            var sum: f32 = 0;
            for (&combs) |*c| sum += c.process(fed, feedback, damp);
            for (&allpasses) |*a| sum = a.process(sum);
            o.* = sum;
        }

        // Combs ring at very different gains depending on the room size, so
        // set the wet level by loudness: its RMS is `mix` times the voice's.
        const dry_rms = rms(x);
        const wet_rms = rms(wet);
        if (wet_rms > 0) {
            const gain = mix * dry_rms / wet_rms;
            for (wet) |*o| o.* *= gain;
        }
    }
}

fn scaled(len_at_44k: u32, rate: u32) usize {
    return @max(1, @min(max_delay, @as(usize, len_at_44k) * rate / freeverb_rate));
}

fn rms(x: []const f32) f32 {
    var sum: f64 = 0;
    for (x) |v| sum += @as(f64, v) * v;
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(@max(1, x.len)))));
}

// ---- tests -------------------------------------------------------------------

const test_rate = 8474;

fn testTone(comptime n: usize, hz: f64, amp: f64) [n]i16 {
    var out: [n]i16 = undefined;
    for (&out, 0..) |*o, i| {
        const t = @as(f64, @floatFromInt(i)) / test_rate;
        o.* = @intFromFloat(@round(amp * @sin(2.0 * std.math.pi * hz * t)));
    }
    return out;
}

fn peakOf(pcm: []const i16) i32 {
    var m: i32 = 0;
    for (pcm) |v| m = @max(m, @as(i32, @intCast(@abs(v))));
    return m;
}

test "effects: all off plays the synth's samples untouched" {
    const tone = testTone(1000, 440, 10000);
    try std.testing.expectEqual(null, try render(std.testing.allocator, &tone, test_rate, .{}));
}

test "effects: bass lifts lows more than highs and never clips" {
    const alloc = std.testing.allocator;
    const high = testTone(test_rate, 2000, 8000);
    const h = (try render(alloc, &high, test_rate, .{ .bass = 9 })).?;
    defer alloc.free(h.samples);
    try std.testing.expect(peakOf(h.samples[h.samples.len / 2 ..]) < 9000); // 2 kHz is (nearly) untouched

    const low = testTone(test_rate, 100, 20000);
    const l = (try render(alloc, &low, test_rate, .{ .bass = 9 })).?;
    defer alloc.free(l.samples);
    // +13.5 dB on 20000 would be ~95000: scaled to fit instead of clipping.
    const p = peakOf(l.samples[l.samples.len / 2 ..]);
    try std.testing.expect(p > 30000 and p <= 32767);
}

test "effects: stereo widening sums back to the original voice" {
    const alloc = std.testing.allocator;
    const tone = testTone(2000, 700, 8000);
    const r = (try render(alloc, &tone, test_rate, .{ .stereo = 9 })).?;
    defer alloc.free(r.samples);
    try std.testing.expectEqual(2, r.channels);
    try std.testing.expectEqual(tone.len, r.frames());

    var differs = false;
    for (tone, 0..) |m, i| {
        const left: i32 = r.samples[2 * i];
        const right: i32 = r.samples[2 * i + 1];
        try std.testing.expect(@abs(left + right - 2 * @as(i32, m)) <= 1); // rounding only
        if (left != right) differs = true;
    }
    try std.testing.expect(differs);
}

test "effects: reverb adds a tail that rings out, mono unless stereo is on" {
    const alloc = std.testing.allocator;
    const tone = testTone(2000, 300, 10000);

    const mono = (try render(alloc, &tone, test_rate, .{ .reverb = 5 })).?;
    defer alloc.free(mono.samples);
    try std.testing.expectEqual(1, mono.channels);
    try std.testing.expectEqual(tone.len + reverbTail(test_rate, 5), mono.frames());
    // Still sounding just after the voice stops...
    try std.testing.expect(peakOf(mono.samples[tone.len .. tone.len + 200]) > 100);

    const stereo = (try render(alloc, &tone, test_rate, .{ .reverb = 5, .stereo = 1 })).?;
    defer alloc.free(stereo.samples);
    try std.testing.expectEqual(2, stereo.channels);
}
