const std = @import("std");
pub const c = @import("c_defs.zig").c;

pub fn maybeReplaceName(input: []const u8, patientName: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const patientNameToken = "~";
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

pub fn maybeReplaceSubject(input: []const u8, topics: []const []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const topicToken = "#";

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
