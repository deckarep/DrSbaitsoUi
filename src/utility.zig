const std = @import("std");
//pub const c = @import("c_defs.zig").c;
const rl = @import("raylib");

const reassemblyToken = "*";
const patientNameToken = "~";
const topicToken = "#";
const historyToken = "@";

/// Matches a string against a pattern with wildcards.
/// '*' matches one or more characters (not zero characters)
/// Returns true if the string matches the pattern, false otherwise
pub fn matchesPattern(in: []const u8, matchKeyword: []const u8, allocator: std.mem.Allocator) !bool {
    const input = try std.ascii.allocLowerString(allocator, in);
    defer allocator.free(input);
    const pattern = try std.ascii.allocLowerString(allocator, matchKeyword);
    defer allocator.free(pattern);

    var input_idx: usize = 0;
    var pattern_idx: usize = 0;

    while (pattern_idx < pattern.len) {
        if (pattern[pattern_idx] == '*') {
            // Wildcard found - it must match at least one character
            pattern_idx += 1; // Move past the '*'

            // If '*' is at the end of pattern, we need at least one more character in input
            if (pattern_idx == pattern.len) {
                return input_idx < input.len; // True if there's at least one char left
            }

            // Find the next non-wildcard character in pattern
            const next_char = pattern[pattern_idx];

            // Look for this character in the remaining input
            while (input_idx < input.len) {
                if (input[input_idx] == next_char) {
                    // Found potential match, recursively check the rest
                    if (try matchesPattern(input[input_idx..], pattern[pattern_idx..], allocator)) {
                        return true;
                    }
                }
                input_idx += 1;
            }
            return false;
        } else {
            // Regular character matching
            if (input_idx >= input.len or input[input_idx] != pattern[pattern_idx]) {
                return false;
            }
            input_idx += 1;
            pattern_idx += 1;
        }
    }

    // Pattern exhausted - input should also be exhausted for exact match
    return input_idx == input.len;
}

/// When there is no match against the keyword, null is returned.
/// When the '*' would capture nothing, null is returned. "I WANT TO" should NOT match "I WANT TO *"
/// When there is a match a reassembled response string is returned and the caller must eventually free this memory.
/// The keyword may appear anywhere in the user's input (Eliza decomposes as "* KEYWORD *");
/// everything after the keyword is captured, pronoun-reflected via the opposites
/// table, and substituted for the '*' in the chosen response template.
pub fn reassemble(
    userInput: []const u8,
    keyword: []const u8,
    chosenResp: []const u8,
    oppTable: []const []const u8,
    inAllocator: std.mem.Allocator,
) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(inAllocator);
    defer arena.deinit();

    const tAlloc = arena.allocator();

    // 0. Lowercase all strings involved.
    const userLC = try std.ascii.allocLowerString(tAlloc, userInput);
    const keywordLC = try std.ascii.allocLowerString(tAlloc, keyword);
    const sbRespLC = try std.ascii.allocLowerString(tAlloc, chosenResp);

    // 1. Strip the '*' from the keyword but keep the keyword's own spacing:
    // space-padded keywords (' HOW ARE YOUR ') encode word boundaries.
    const keywordBodySize = std.mem.replacementSize(u8, keywordLC, reassemblyToken, "");
    const keywordBody = try tAlloc.alloc(u8, keywordBodySize);
    _ = std.mem.replace(u8, keywordLC, reassemblyToken, "", keywordBody);

    // 2. Pad the user's input with spaces (like the original) so padded
    // keywords can match at the very start/end of the input.
    const paddedUser = try std.fmt.allocPrint(tAlloc, " {s} ", .{userLC});

    // 3. The keyword may appear anywhere in the input, not just at the start.
    const idx = std.mem.indexOf(u8, paddedUser, keywordBody) orelse return null;

    // 4. Capture everything after the keyword, dropping surrounding spaces
    // and the user's punctuation. The '*' must capture at least one word.
    const rawCapture = paddedUser[idx + keywordBody.len ..];
    const capture = std.mem.trim(u8, rawCapture, " ,.!?;:");
    if (capture.len == 0) {
        return null;
    }

    // 5. Reflect pronouns word-by-word (I -> YOU, MY -> YOUR, etc.).
    const reflected = try reflectOpposites(capture, oppTable, tAlloc);

    // 6. Substitute the capture into the chosen response template. The
    // template's own punctuation is left untouched.
    const finalRepSize = std.mem.replacementSize(u8, sbRespLC, reassemblyToken, reflected);
    const finalBuf = try tAlloc.alloc(u8, finalRepSize);
    _ = std.mem.replace(u8, sbRespLC, reassemblyToken, reflected, finalBuf);

    return try std.ascii.allocUpperString(inAllocator, finalBuf);
}

/// Applies the opposites table word-by-word in a single pass so a swapped word
/// can never be swapped back again (YOUR -> MY -> YOUR). Pairs apply in both
/// directions: (' YOU ', ' I ') reflects YOU -> I as well as I -> YOU, which is
/// how the original Eliza reflected the missing first-person directions.
fn reflectOpposites(input: []const u8, oppTable: []const []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var it = std.mem.tokenizeScalar(u8, input, ' ');
    while (it.next()) |word| {
        if (out.items.len != 0) try out.append(alloc, ' ');

        // Compare the bare word; punctuation stuck to it is carried over.
        const core = std.mem.trimEnd(u8, word, ",.!?;:");
        const tail = word[core.len..];

        try out.appendSlice(alloc, lookupOpposite(core, oppTable) orelse core);
        try out.appendSlice(alloc, tail);
    }

    return out.toOwnedSlice(alloc);
}

fn lookupOpposite(word: []const u8, oppTable: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < oppTable.len) : (i += 2) {
        const a = std.mem.trim(u8, oppTable[i], " ");
        const b = std.mem.trim(u8, oppTable[i + 1], " ");
        if (std.ascii.eqlIgnoreCase(word, a)) return b;
        if (std.ascii.eqlIgnoreCase(word, b)) return a;
    }
    return null;
}

// Mirrors the "opposites" table in resources/json/sbaitso_speech_pack.json.
const testOpposites: []const []const u8 = &.{
    " ARE ",  " AM ",
    " WERE ", " WAS ",
    " YOU ",  " I ",
    " YOUR ", " MY ",
    " MY ",   " YOUR ",
    " I'VE ", " YOU'VE ",
    " I'M ",  " YOU'RE ",
    " YOU ",  " ME ",
    " ME ",   " YOU ",
    " MINE ", " YOURS ",
    "MYSELF", "YOURSELF",
};

fn expectReassembly(
    userInput: []const u8,
    keyword: []const u8,
    chosenResp: []const u8,
    expected: []const u8,
) !void {
    const resp = (try reassemble(
        userInput,
        keyword,
        chosenResp,
        testOpposites,
        std.testing.allocator,
    )) orelse return error.TestExpectedReassembly;
    defer std.testing.allocator.free(resp);

    try std.testing.expectEqualStrings(expected, resp);
}

pub fn maybeReplaceName(input: []const u8, patientName: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    if (std.mem.indexOf(u8, input, patientNameToken)) |_| {
        // Always allocates in this path.
        const newSize = std.mem.replacementSize(u8, input, patientNameToken, patientName);
        const outputBuf = try alloc.alloc(u8, newSize);
        _ = std.mem.replace(u8, input, patientNameToken, patientName, outputBuf);
        return outputBuf;
    }

    // Leaks on purpose, to always guarantee allocation!
    return alloc.dupe(u8, input);
}

pub fn maybeReplaceTopic(input: []const u8, topics: []const []const u8, alloc: std.mem.Allocator) ![]const u8 {
    if (std.mem.indexOf(u8, input, topicToken)) |_| {
        const r: usize = @intCast(rl.getRandomValue(0, @as(c_int, @intCast(topics.len)) - 1));

        const topic = topics[r];

        // Always allocates in this path.
        const newSize = std.mem.replacementSize(u8, input, topicToken, topic);
        const outputBuf = try alloc.alloc(u8, newSize);
        _ = std.mem.replace(u8, input, topicToken, topic, outputBuf);
        return outputBuf;
    }

    // Leaks on purpose, to always guarantee allocation!
    return alloc.dupe(u8, input);
}

pub fn maybeReplaceHistory(input: []const u8, historyItem: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    if (std.mem.indexOf(u8, input, historyToken)) |_| {
        // Always allocates in this path.
        const newSize = std.mem.replacementSize(u8, input, historyToken, historyItem);
        const outputBuf = try alloc.alloc(u8, newSize);
        _ = std.mem.replace(u8, input, historyToken, historyItem, outputBuf);
        return outputBuf;
    }

    // Leaks on purpose, to always guarantee allocation!
    return alloc.dupe(u8, input);
}

test "reassemble: keyword mid-sentence still reassembles" {
    // The keyword does not need to be at the very start of the input.
    try expectReassembly(
        "i think you are dumb",
        "YOU ARE *",
        "YOU ARE * TOO, I SUPPOSE",
        "YOU ARE DUMB TOO, I SUPPOSE",
    );
}

test "reassemble: first person reflects to second person" {
    // I -> YOU, AM -> ARE must reflect even though the JSON table only
    // lists the YOU -> I and ARE -> AM directions.
    try expectReassembly(
        "i feel like i am dumb",
        "I FEEL *",
        "WHY DO YOU FEEL *?",
        "WHY DO YOU FEEL LIKE YOU ARE DUMB?",
    );
}

test "reassemble: opposites match at start of captured fragment" {
    // "my friend" begins the captured fragment; MY must still become YOUR
    // even with no surrounding spaces in the fragment.
    try expectReassembly(
        "you are my friend",
        "YOU ARE *",
        "WHAT MAKES YOU THINK THAT I AM *",
        "WHAT MAKES YOU THINK THAT I AM YOUR FRIEND",
    );
}

test "reassemble: template punctuation is preserved" {
    // User typed no punctuation; the template's own '?' must survive.
    try expectReassembly(
        "are you dumb",
        "ARE YOU *",
        "WOULD YOU BE GLAD IF I WERE NOT *?",
        "WOULD YOU BE GLAD IF I WERE NOT DUMB?",
    );
}

test "reassemble: user punctuation is stripped from the captured fragment" {
    // The '*' sits mid-template here, so the user's '?' must not leak
    // into the middle of the response.
    try expectReassembly(
        "who is santa?",
        "WHO IS *",
        "* MUST BE AN EXCITING PERSON",
        "SANTA MUST BE AN EXCITING PERSON",
    );
}

test "reassemble: keyword without star captures the remainder" {
    // Rules like I CAN'T have starless keywords but starred reassemblies;
    // the text after the keyword is the implicit capture.
    try expectReassembly(
        "i can't sleep at night",
        "I CAN'T",
        "HAVE YOU EVER TRIED TO *",
        "HAVE YOU EVER TRIED TO SLEEP AT NIGHT",
    );
}

test "reassemble: me and my both reflect" {
    try expectReassembly(
        "you hate me and my dog",
        "YOU *",
        "SO YOU BELIEVE I *?",
        "SO YOU BELIEVE I HATE YOU AND YOUR DOG?",
    );
}

test "reassemble: nothing after the keyword returns null" {
    // "I WANT TO" alone must NOT match "I WANT TO *".
    const resp = try reassemble(
        "i want to",
        "I WANT TO *",
        "WHY DO YOU WANT TO *?",
        testOpposites,
        std.testing.allocator,
    );
    try std.testing.expectEqual(null, resp);
}
