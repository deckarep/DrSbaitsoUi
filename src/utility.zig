const std = @import("std");
pub const c = @import("c_defs.zig").c;

const reassemblyToken = "*";
const patientNameToken = "~";
const topicToken = "#";
const historyToken = "@";

/// When there is no match against the keyword, null is returned.
/// When there is a match a reassembled response string is returned and the caller must eventually free this memory.
pub fn reassemble(
    userInput: []const u8,
    keyword: []const u8,
    chosenResp: []const u8,
    oppTable: []const []const u8,
    inAllocator: std.mem.Allocator,
) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(inAllocator);
    defer arena.deinit();

    // TODO: use the opposites table!

    const tAlloc = arena.allocator();

    std.debug.print("userInput => {s}\n, keyword => {s}, chosenResp => {s}\n", .{ userInput, keyword, chosenResp });

    // 0. Lowercase all strings involved.
    const userLC = try std.ascii.allocLowerString(tAlloc, userInput);
    const keywordLC = try std.ascii.allocLowerString(tAlloc, keyword);
    const sbRespLC = try std.ascii.allocLowerString(tAlloc, chosenResp);

    // 2. Strip the * from the keyword, and trim the keyword.
    const keywordNewSize = std.mem.replacementSize(u8, keywordLC, reassemblyToken, "");
    const newKeyWordBuf = try tAlloc.alloc(u8, keywordNewSize);
    _ = std.mem.replace(u8, keywordLC, reassemblyToken, "", newKeyWordBuf);

    // 3. Trim the keyword buf if needed.
    const trimmedKeyWordBuf = std.mem.trim(u8, newKeyWordBuf, " ");

    // 4. Do keyword match against userLine
    if (std.mem.indexOf(u8, userLC, trimmedKeyWordBuf)) |idx| {
        // 5. If match, reassemble user's input with resp.
        const startIdx = idx + trimmedKeyWordBuf.len + 1;

        var usersPartTweaked = userLC[startIdx..];

        // Apply opposites if needed on usersPartTweaked.
        // NOTE: Currently, this just iterates down the oppTable in order of how their defined within the JSON file.
        // NOTE: This doesn't yet handle the ambiguous difference in YOU -> ME, or YOU -> I.
        // WIP!
        var i: usize = 0;
        while (i < oppTable.len) : (i += 2) {
            const oppLC = try std.ascii.allocLowerString(tAlloc, oppTable[i]);
            //std.debug.print("oppTable[i] => {s}, usersPartTweaked => {s}\n", .{ oppLC, usersPartTweaked });
            if (std.mem.indexOf(u8, usersPartTweaked, oppLC)) |_| {
                const needle = oppLC;
                const needleOpp = oppTable[i + 1];
                const oppRepSize = std.mem.replacementSize(u8, usersPartTweaked, needle, needleOpp);
                const oppBuf = try tAlloc.alloc(u8, oppRepSize);

                _ = std.mem.replace(u8, usersPartTweaked, needle, needleOpp, oppBuf);
                usersPartTweaked = oppBuf;
            }
        }

        const finalRepSize = std.mem.replacementSize(u8, sbRespLC, reassemblyToken, usersPartTweaked);
        const finalBuf = try tAlloc.alloc(u8, finalRepSize);

        _ = std.mem.replace(u8, sbRespLC, reassemblyToken, usersPartTweaked, finalBuf);

        if (std.mem.endsWith(u8, finalBuf, "?") or
            std.mem.endsWith(u8, finalBuf, "!") or
            std.mem.endsWith(u8, finalBuf, "."))
        {
            return try std.ascii.allocUpperString(inAllocator, finalBuf[0 .. finalBuf.len - 1]);
        } else {
            return try std.ascii.allocUpperString(inAllocator, finalBuf);
        }
    }

    return null;
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
        const r: usize = @intCast(c.GetRandomValue(0, @as(c_int, @intCast(topics.len)) - 1));

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
