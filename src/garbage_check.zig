const std = @import("std");
const math = std.math;

// This may need to be tuned...and is not very well tested but seems to initially work!
// Potential improvements:
// 1. Check for top 100-200 english words (dictionary)
// 2. Check for internet lingo/slang: lol, omg, etc.
// 3. Add bigram/trigram analysis
// 4. Check for punctuation, word boundaries, etc.

// English letter frequencies (A–Z), in proportions
const englishFreq: [26]f64 = [_]f64{
    0.0817, // A
    0.0149, // B
    0.0278, // C
    0.0425, // D
    0.1270, // E
    0.0223, // F
    0.0202, // G
    0.0609, // H
    0.0697, // I
    0.0015, // J
    0.0077, // K
    0.0403, // L
    0.0241, // M
    0.0675, // N
    0.0751, // O
    0.0193, // P
    0.0010, // Q
    0.0599, // R
    0.0633, // S
    0.0906, // T
    0.0276, // U
    0.0098, // V
    0.0236, // W
    0.0015, // X
    0.0197, // Y
    0.0007, // Z
};

/// Computes a χ² goodness-of-fit score of `text` against English letter frequencies.
/// Lower ⇒ more English-like; higher ⇒ more random/gibberish.
fn chiSquaredScore(text: []const u8) f64 {
    var counts: [26]usize = undefined;
    // zero-initialize

    @memset(counts[0..], 0);
    var total: usize = 0;

    // count letters
    for (text) |b| {
        if (std.ascii.isAlphabetic(b)) {
            const u = std.ascii.toUpper(b);
            counts[@intCast(u - 'A')] += 1;
            total += 1;
        }
    }

    // too short to judge
    if (total < 10) return std.math.inf(f64);

    // compute χ²
    var chi2: f64 = 0;
    for (englishFreq, 0..) |freq, i| {
        const observed: f64 = @floatFromInt(counts[i]);
        const expected = freq * @as(f64, @floatFromInt(total));
        const diff = observed - expected;
        chi2 += diff * diff / (expected + 1e-6);
    }
    return chi2;
}

/// Returns true if `text` is likely gibberish based on χ² threshold.
fn isGibberish(text: []const u8) bool {
    return chiSquaredScore(text) > 150.0;
}

/// Checks vowel-to-letter ratio; extreme values suggest gibberish.
fn lowVowelRatio(text: []const u8) bool {
    var vowels: usize = 0;
    var letters: usize = 0;

    for (text) |b| {
        if (std.ascii.isAlphabetic(b)) {
            letters += 1;
            const lower = std.ascii.toLower(b);
            if (lower == 'a' or lower == 'e' or lower == 'i' or lower == 'o' or lower == 'u') {
                vowels += 1;
            }
        }
    }

    // too short → treat as gibberish
    if (letters < 5) return true;

    const ratio = @as(f64, @floatFromInt(vowels)) / @as(f64, @floatFromInt(letters));
    return (ratio < 0.25 or ratio > 0.65);
}

/// Combines both heuristics for a fast “probably gibberish” check.
pub fn probablyGibberish(text: []const u8) bool {
    return isGibberish(text) or lowVowelRatio(text);
}
