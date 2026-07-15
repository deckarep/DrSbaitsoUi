const std = @import("std");

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

// A few hundred of the most common English function/chat words, plus internet
// slang and a handful of domain words this app's own conversation loves to
// use (its own name included). This is intentionally small: it exists to give
// everyday replies a fast, certain "not gibberish" exit before the statistical
// heuristics -- which are noisy on short text -- ever get a vote. Anything
// missing here just falls through to those heuristics, it isn't rejected.
const commonWords = std.StaticStringMap(void).initComptime(.{
    // Pronouns / function words
    .{ "i", {} },         .{ "me", {} },         .{ "my", {} },           .{ "mine", {} },
    .{ "you", {} },       .{ "your", {} },       .{ "yours", {} },        .{ "he", {} },
    .{ "him", {} },       .{ "his", {} },        .{ "she", {} },          .{ "her", {} },
    .{ "hers", {} },      .{ "it", {} },         .{ "its", {} },          .{ "we", {} },
    .{ "us", {} },        .{ "our", {} },        .{ "ours", {} },         .{ "they", {} },
    .{ "them", {} },      .{ "their", {} },      .{ "theirs", {} },       .{ "this", {} },
    .{ "that", {} },      .{ "these", {} },      .{ "those", {} },        .{ "who", {} },
    .{ "whom", {} },      .{ "whose", {} },      .{ "what", {} },         .{ "which", {} },
    .{ "the", {} },       .{ "a", {} },          .{ "an", {} },           .{ "and", {} },
    .{ "or", {} },        .{ "but", {} },        .{ "if", {} },           .{ "then", {} },
    .{ "because", {} },   .{ "so", {} },         .{ "to", {} },           .{ "of", {} },
    .{ "in", {} },        .{ "on", {} },         .{ "at", {} },           .{ "for", {} },
    .{ "with", {} },      .{ "about", {} },      .{ "as", {} },           .{ "by", {} },
    .{ "from", {} },      .{ "up", {} },         .{ "down", {} },         .{ "out", {} },
    .{ "over", {} },      .{ "under", {} },      .{ "again", {} },        .{ "once", {} },
    .{ "here", {} },      .{ "there", {} },      .{ "when", {} },         .{ "where", {} },
    .{ "why", {} },       .{ "how", {} },        .{ "all", {} },          .{ "any", {} },
    .{ "both", {} },      .{ "each", {} },       .{ "few", {} },          .{ "more", {} },
    .{ "most", {} },      .{ "other", {} },      .{ "some", {} },         .{ "such", {} },
    .{ "no", {} },        .{ "nor", {} },        .{ "not", {} },          .{ "only", {} },
    .{ "own", {} },       .{ "same", {} },       .{ "than", {} },         .{ "too", {} },
    .{ "very", {} },      .{ "just", {} },       .{ "now", {} },          .{ "is", {} },
    .{ "am", {} },        .{ "are", {} },        .{ "was", {} },          .{ "were", {} },
    .{ "be", {} },        .{ "been", {} },       .{ "being", {} },        .{ "have", {} },
    .{ "has", {} },       .{ "had", {} },        .{ "do", {} },           .{ "does", {} },
    .{ "did", {} },       .{ "will", {} },       .{ "would", {} },        .{ "should", {} },
    .{ "could", {} },     .{ "can", {} },        .{ "may", {} },          .{ "might", {} },
    .{ "must", {} },

    // Contractions, spelled without the apostrophe (tokens are normalized
    // that way before lookup -- see normalizeWord).
         .{ "dont", {} },       .{ "cant", {} },         .{ "wont", {} },
    .{ "im", {} },        .{ "ive", {} },        .{ "youre", {} },        .{ "theyre", {} },
    .{ "its", {} },       .{ "thats", {} },      .{ "whats", {} },        .{ "lets", {} },
    .{ "didnt", {} },     .{ "isnt", {} },       .{ "arent", {} },        .{ "wasnt", {} },
    .{ "werent", {} },    .{ "couldnt", {} },    .{ "wouldnt", {} },      .{ "shouldnt", {} },
    .{ "hes", {} },       .{ "shes", {} },       .{ "were", {} },         .{ "id", {} },
    .{ "ill", {} },       .{ "youve", {} },      .{ "theyve", {} },       .{ "weve", {} },

    // Common chat replies / slang / abbreviations
    .{ "yes", {} },       .{ "yeah", {} },       .{ "yep", {} },          .{ "yup", {} },
    .{ "nope", {} },      .{ "nah", {} },        .{ "ok", {} },           .{ "okay", {} },
    .{ "hi", {} },        .{ "hey", {} },        .{ "hello", {} },        .{ "bye", {} },
    .{ "thanks", {} },    .{ "thx", {} },        .{ "ty", {} },           .{ "please", {} },
    .{ "sorry", {} },     .{ "sup", {} },        .{ "lol", {} },          .{ "lmao", {} },
    .{ "omg", {} },       .{ "wtf", {} },        .{ "brb", {} },          .{ "u", {} },
    .{ "r", {} },         .{ "ur", {} },         .{ "k", {} },            .{ "wht", {} },
    .{ "dong", {} },

    // Common conversational / emotional vocabulary (this app is a
    // psychiatrist-themed chatbot, so its own domain words are common input)
         .{ "help", {} },       .{ "feel", {} },         .{ "feeling", {} },
    .{ "feelings", {} },  .{ "sad", {} },        .{ "happy", {} },        .{ "angry", {} },
    .{ "mad", {} },       .{ "fine", {} },       .{ "good", {} },         .{ "bad", {} },
    .{ "love", {} },      .{ "hate", {} },       .{ "life", {} },         .{ "death", {} },
    .{ "mom", {} },       .{ "dad", {} },        .{ "mother", {} },       .{ "father", {} },
    .{ "work", {} },      .{ "job", {} },        .{ "stress", {} },       .{ "stressed", {} },
    .{ "anxious", {} },   .{ "anxiety", {} },    .{ "depressed", {} },    .{ "depression", {} },
    .{ "lonely", {} },    .{ "tired", {} },      .{ "scared", {} },       .{ "afraid", {} },
    .{ "worried", {} },   .{ "worry", {} },      .{ "think", {} },        .{ "thought", {} },
    .{ "thoughts", {} },  .{ "know", {} },       .{ "want", {} },         .{ "need", {} },
    .{ "like", {} },      .{ "mind", {} },       .{ "mean", {} },         .{ "understand", {} },
    .{ "tell", {} },      .{ "talk", {} },       .{ "say", {} },          .{ "said", {} },
    .{ "really", {} },    .{ "maybe", {} },      .{ "sometimes", {} },    .{ "always", {} },
    .{ "never", {} },     .{ "psychology", {} }, .{ "psychiatrist", {} }, .{ "therapy", {} },
    .{ "therapist", {} }, .{ "rhythm", {} },     .{ "strengths", {} },    .{ "weaknesses", {} },
    .{ "sbaitso", {} },   .{ "eliza", {} },
});

// The ~120 most frequent English letter bigrams. A real English word is
// almost entirely built from bigrams in this set; random keysmash text
// typically is not. This is what lets us catch reordered/anagram-style
// nonsense that has an otherwise-plausible unigram letter distribution, and
// what the whole-string-only unigram χ² check below structurally cannot see.
const commonBigrams = std.StaticStringMap(void).initComptime(.{
    .{ "th", {} },  .{ "he", {} }, .{ "in", {} },  .{ "er", {} }, .{ "an", {} },
    .{ "re", {} },  .{ "on", {} }, .{ "at", {} },  .{ "en", {} }, .{ "nd", {} },
    .{ "ti", {} },  .{ "es", {} }, .{ "or", {} },  .{ "te", {} }, .{ "of", {} },
    .{ "ed", {} },  .{ "is", {} }, .{ "it", {} },  .{ "al", {} }, .{ "ar", {} },
    .{ "st", {} },  .{ "to", {} }, .{ "nt", {} },  .{ "ng", {} }, .{ "se", {} },
    .{ "ha", {} },  .{ "as", {} }, .{ "ou", {} },  .{ "io", {} }, .{ "le", {} },
    .{ "ve", {} },  .{ "co", {} }, .{ "me", {} },  .{ "de", {} }, .{ "hi", {} },
    .{ "ri", {} },  .{ "ro", {} }, .{ "ic", {} },  .{ "ne", {} }, .{ "ea", {} },
    .{ "ra", {} },  .{ "ce", {} }, .{ "li", {} },  .{ "ch", {} }, .{ "ll", {} },
    .{ "be", {} },  .{ "ma", {} }, .{ "si", {} },  .{ "om", {} }, .{ "ur", {} },
    .{ "ca", {} },  .{ "el", {} }, .{ "ta", {} },  .{ "la", {} }, .{ "ns", {} },
    .{ "di", {} },  .{ "fo", {} }, .{ "ho", {} },  .{ "pe", {} }, .{ "ec", {} },
    .{ "pr", {} },  .{ "no", {} }, .{ "ct", {} },  .{ "us", {} }, .{ "ac", {} },
    .{ "ot", {} },  .{ "il", {} }, .{ "ly", {} },  .{ "nc", {} }, .{ "et", {} },
    .{ "ut", {} },  .{ "ss", {} }, .{ "so", {} },  .{ "rs", {} }, .{ "un", {} },
    .{ "lo", {} },  .{ "wa", {} }, .{ "ge", {} },  .{ "ie", {} }, .{ "wi", {} },
    .{ "id", {} },  .{ "ow", {} }, .{ "ent", {} }, .{ "wh", {} }, .{ "ke", {} },
    .{ "ver", {} }, .{ "sa", {} }, .{ "op", {} },  .{ "ni", {} }, .{ "oo", {} },
    .{ "af", {} },  .{ "pl", {} }, .{ "gh", {} },  .{ "sh", {} }, .{ "tr", {} },
    .{ "am", {} },  .{ "ap", {} }, .{ "do", {} },  .{ "ei", {} }, .{ "au", {} },
    .{ "bo", {} },  .{ "ol", {} }, .{ "up", {} },  .{ "ci", {} }, .{ "vi", {} },
    .{ "yo", {} },  .{ "fi", {} }, .{ "ee", {} },  .{ "ff", {} }, .{ "pa", {} },
    .{ "mi", {} },  .{ "ki", {} }, .{ "po", {} },  .{ "og", {} }, .{ "iv", {} },
    .{ "go", {} },  .{ "sp", {} }, .{ "gr", {} },  .{ "fr", {} }, .{ "pp", {} },
    .{ "ur", {} },  .{ "im", {} }, .{ "kn", {} },  .{ "gi", {} }, .{ "ir", {} },
});

fn isVowel(b: u8) bool {
    return switch (std.ascii.toLower(b)) {
        // 'y' is treated as a vowel: it very often functions as one in
        // English (gym, sync, myth, rhythm, crypt, glyph) and excluding it
        // makes a whole class of real, if consonant-looking, words come back
        // with a vowel ratio of 0 -- a false "gibberish" tell.
        'a', 'e', 'i', 'o', 'u', 'y' => true,
        else => false,
    };
}

/// Computes a χ² goodness-of-fit score of `text` against English letter
/// frequencies. Lower ⇒ more English-like; higher ⇒ more random/gibberish.
///
/// Returns `null` when there are fewer than 10 letters to work with -- a
/// goodness-of-fit test needs a reasonable sample size to mean anything, and
/// with short chat replies being the common case here, callers MUST treat
/// `null` as "inconclusive" rather than picking a sentinel number and
/// comparing it against the threshold (a previous version of this function
/// returned +infinity for this case, which made every short reply compare as
/// "definitely gibberish" -- the opposite of the intent).
fn chiSquaredScore(text: []const u8) ?f64 {
    var counts: [26]usize = undefined;
    @memset(counts[0..], 0);
    var total: usize = 0;

    for (text) |b| {
        if (std.ascii.isAlphabetic(b)) {
            const u = std.ascii.toUpper(b);
            counts[@intCast(u - 'A')] += 1;
            total += 1;
        }
    }

    if (total < 10) return null;

    var chi2: f64 = 0;
    for (englishFreq, 0..) |freq, i| {
        const observed: f64 = @floatFromInt(counts[i]);
        const expected = freq * @as(f64, @floatFromInt(total));
        const diff = observed - expected;
        chi2 += diff * diff / (expected + 1e-6);
    }
    return chi2;
}

/// Fraction of adjacent letter-pairs in `word` that are common English
/// bigrams. Returns 1.0 (i.e. "looks fine") when there are fewer than 2
/// letters to pair up, since there's nothing to judge.
fn bigramFamiliarity(word: []const u8) f64 {
    var buf: [2]u8 = undefined;
    var pairs: usize = 0;
    var common: usize = 0;
    var prev: ?u8 = null;

    for (word) |b| {
        if (!std.ascii.isAlphabetic(b)) continue;
        const lower = std.ascii.toLower(b);
        if (prev) |p| {
            buf[0] = p;
            buf[1] = lower;
            pairs += 1;
            if (commonBigrams.has(buf[0..2])) common += 1;
        }
        prev = lower;
    }

    if (pairs == 0) return 1.0;
    return @as(f64, @floatFromInt(common)) / @as(f64, @floatFromInt(pairs));
}

fn allDigits(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |b| {
        if (!std.ascii.isDigit(b)) return false;
    }
    return true;
}

/// Lowercases `raw` and strips anything that isn't a letter or digit (spaces
/// are already the tokenizer's job; this handles punctuation like "why?",
/// "don't" -> "dont", "@als02" -> "als02"). Truncates to `buf`'s capacity,
/// which is generously sized for chat input.
fn normalizeWord(raw: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    for (raw) |b| {
        if (len >= buf.len) break;
        if (std.ascii.isAlphanumeric(b)) {
            buf[len] = std.ascii.toLower(b);
            len += 1;
        }
    }
    return buf[0..len];
}

/// Judges a single normalized (lowercased, punctuation-stripped) word as
/// suspicious using several weak, independent-ish signals, requiring at
/// least two to agree before condemning it. Any one of these heuristics is
/// too noisy on its own at chat-message lengths -- that was the core problem
/// with the previous single-check design.
fn isSuspiciousWord(word: []const u8) bool {
    if (word.len == 0) return false;
    if (word.len == 1) return false; // "i", "a", digits, etc.
    if (allDigits(word)) return false; // plain numbers are legitimate answers
    if (commonWords.has(word)) return false;

    var letters: usize = 0;
    var vowels: usize = 0;
    var hasDigit = false;
    for (word) |b| {
        if (std.ascii.isDigit(b)) hasDigit = true;
        if (std.ascii.isAlphabetic(b)) {
            letters += 1;
            if (isVowel(b)) vowels += 1;
        }
    }

    // Letters mixed with digits never occurs in real English words -- an
    // immediate, reliable tell independent of any frequency statistics.
    if (hasDigit and letters > 0) return true;
    if (letters == 0) return false; // pure digits handled above; nothing else to judge

    const vowelRatio = @as(f64, @floatFromInt(vowels)) / @as(f64, @floatFromInt(letters));
    const badVowelRatio = letters >= 3 and (vowelRatio < 0.15 or vowelRatio > 0.85);

    const bigramScore = bigramFamiliarity(word);
    const badBigrams = letters >= 4 and bigramScore < 0.5;

    // Only meaningful with enough letters -- see chiSquaredScore's doc comment.
    const badChi2 = if (letters >= 10) (chiSquaredScore(word) orelse 0) > 150.0 else false;

    const votes = @as(u8, @intFromBool(badVowelRatio)) +
        @as(u8, @intFromBool(badBigrams)) +
        @as(u8, @intFromBool(badChi2));
    return votes >= 2;
}

/// Combines both heuristics for a fast "probably gibberish" check.
///
/// Operates per-word rather than on the whole input blob: each
/// whitespace-separated token is judged independently, and the input is
/// flagged only when a strict majority of its words look suspicious. This
/// means a single odd word in an otherwise normal sentence won't condemn the
/// whole reply, while a single garbled token typed on its own (the common
/// case for this app -- someone mashing the keyboard) is still caught.
pub fn probablyGibberish(text: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var total: usize = 0;
    var suspicious: usize = 0;
    var buf: [64]u8 = undefined;

    while (words.next()) |raw| {
        const word = normalizeWord(raw, &buf);
        if (word.len == 0) continue;
        total += 1;
        if (isSuspiciousWord(word)) suspicious += 1;
    }

    if (total == 0) return false;
    return suspicious * 2 > total;
}

test "probablyGibberish: empty and whitespace-only input is not gibberish" {
    // main.zig's own too-short/empty checks run before this one, but the
    // function should still be safe to call directly on nothing to judge.
    try std.testing.expect(!probablyGibberish(""));
    try std.testing.expect(!probablyGibberish("   "));
}

test "probablyGibberish: common short replies are not flagged" {
    // These were false positives under the previous implementation: the
    // chi-squared check returned +infinity for anything under 10 letters
    // (its "not enough data" sentinel), and +infinity compared as
    // "definitely gibberish" against the threshold instead of "inconclusive".
    const replies = [_][]const u8{
        "no thanks",
        "i dont know",
        "why",
        "sup",
        "sbaitso",
        "rhythm",
        "strengths",
        "psychology",
        "help me please",
        "im sad",
        "wht r u dong",
    };
    for (replies) |reply| {
        try std.testing.expect(!probablyGibberish(reply));
    }
}

test "probablyGibberish: ordinary sentences are not flagged" {
    const sentences = [_][]const u8{
        "hello there how are you",
        "what is the meaning of life",
        "i am feeling sad today",
        "the quick brown fox jumps over the lazy dog",
        "i really dont know why",
        "this makes no sense to me",
    };
    for (sentences) |sentence| {
        try std.testing.expect(!probablyGibberish(sentence));
    }
}

test "probablyGibberish: real words that look consonant-heavy are not flagged" {
    // 'y' counts as a vowel for exactly this reason -- without it, words
    // like these come back with a vowel ratio of 0 and get misread as
    // gibberish.
    const words = [_][]const u8{
        "nymph", "sync", "lynx", "crypt", "glyph", "psych", "myth",
    };
    for (words) |word| {
        try std.testing.expect(!probablyGibberish(word));
    }
}

test "probablyGibberish: letters mixed with digits are flagged" {
    // Real English words never mix digits into the middle of a token, so
    // this is a reliable, statistics-free tell -- this is how the app's own
    // motivating examples ("lsowi20", "@als02") get caught.
    const inputs = [_][]const u8{ "lsowi20", "@als02", "test123test" };
    for (inputs) |input| {
        try std.testing.expect(probablyGibberish(input));
    }
}

test "probablyGibberish: consonant-cluster keysmash is flagged" {
    const inputs = [_][]const u8{ "bcdfgbcdfg", "zxcvb", "mnbvcx", "kjhgf", "vbnmq", "fghjkl" };
    for (inputs) |input| {
        try std.testing.expect(probablyGibberish(input));
    }
}

test "probablyGibberish: extreme repetition is flagged" {
    try std.testing.expect(probablyGibberish("aaaaaaaaaa"));
}

test "probablyGibberish: a single odd word doesn't condemn an otherwise normal sentence" {
    // Only a minority of the words are suspicious, so the sentence as a
    // whole reads as a typo/aside rather than the user typing nonsense.
    try std.testing.expect(!probablyGibberish("keyboard mashing jkasdhf"));
}

test "probablyGibberish: a majority of suspicious words flags the whole input" {
    try std.testing.expect(probablyGibberish("jkasdhf asdkjfh mnbvcx"));
}

test "probablyGibberish: known limitation -- short invented words that happen to look statistically English still slip through" {
    // "alahsowh" is one of the original motivating examples for this file.
    // Its vowel ratio (0.375) and bigram familiarity (~0.71) both land
    // comfortably inside "looks like English" territory purely by chance --
    // no letter-frequency or bigram heuristic can distinguish it from a real
    // but uncommon word without an actual dictionary to check it against.
    // This test documents the known gap rather than hides it: if it starts
    // failing, something got *more* conservative, not less.
    try std.testing.expect(!probablyGibberish("alahsowh"));
}

test "chiSquaredScore: too little data returns null, not a sentinel gibberish score" {
    try std.testing.expect(chiSquaredScore("hi") == null);
    try std.testing.expect(chiSquaredScore("sad") == null);
}

test "chiSquaredScore: a long real-English passage scores low" {
    const score = chiSquaredScore("the quick brown fox jumps over the lazy dog") orelse
        return error.UnexpectedNull;
    try std.testing.expect(score < 150.0);
}

test "bigramFamiliarity: real word has mostly-common bigrams, keysmash does not" {
    try std.testing.expect(bigramFamiliarity("hello") > 0.5);
    try std.testing.expect(bigramFamiliarity("mnbvcx") < 0.5);
}

test "isVowel: treats y as a vowel alongside aeiou" {
    try std.testing.expect(isVowel('y'));
    try std.testing.expect(isVowel('Y'));
    try std.testing.expect(isVowel('a'));
    try std.testing.expect(!isVowel('b'));
}
