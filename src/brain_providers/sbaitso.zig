const std = @import("std");
const utility = @import("sbaitso_helper/utility.zig");

// The original Dr. Sbaitso / ELIZA-style brain: loads
// resources/json/sbaitso_speech_pack.json into a keyword -> response map and
// answers by longest-match keyword lookup with reassembly-template
// substitution. This is the built-in default brain (no external process or
// network calls), and also backs the app's canned responses (timeout,
// repeat, too-short, catch-all) via chooseAction, regardless of which brain
// is currently selected for conversational replies.

pub const DBRule = struct {
    // I believe that a lower rank (starting at 0) will be scanned first, so that's how
    // I'll be sorting the DB.
    // Actions have a ranking as well...but how they are searched is really just hardcoded.
    rank: usize,
    roundRobin: usize = 0,
    keywords: []const []const u8,
    reassemblies: []const []const u8,
};

pub const DB = struct {
    // Topics of interest, recognition.
    topics: []const []const u8,

    // Opposites for use in reassemblies.
    opposites: []const []const u8,

    // WARN: a mutable slice so roundRobin vals can be mutated on each action.
    actions: []DBRule,
    // WARN: a mutable slice so roundRobin vals can be mutated on each mapping.
    mappings: []DBRule,
};

pub var parsedJSON: std.json.Parsed(DB) = undefined;

pub var map: std.StringHashMapUnmanaged(*DBRule) = .empty;

pub fn loadDatabaseFiles(io: std.Io, alloc: std.mem.Allocator) ![]const u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "resources/json/sbaitso_speech_pack.json",
        alloc,
        .limited(1024 * 1024),
    );

    // NOTE: These will all get defer destroyed by the caller immediately after load.

    parsedJSON = try std.json.parseFromSlice(
        DB,
        alloc,
        data,
        .{ .ignore_unknown_fields = true },
    );

    // Populate the map, which is basically a reverse lookup of map input tokens to possible outputs.
    // 1. Add all actions.
    for (parsedJSON.value.actions) |*r| {
        for (r.keywords) |token| {
            try map.put(alloc, token, r);
        }
    }

    // 2. Add all mappings.
    for (parsedJSON.value.mappings) |*r| {
        // A mapping could have one or more inputs defined.
        for (r.keywords) |token| {
            //std.debug.print("mapping token => {s}\n", .{token});
            try map.put(alloc, token, r);
        }
    }

    std.log.debug("topics => {d}", .{parsedJSON.value.topics.len});
    std.log.debug("actions => {d}", .{parsedJSON.value.actions.len});
    std.log.debug("mappings => {d}", .{parsedJSON.value.mappings.len});

    return data;
}

// chooseAction simply returns the next round-robin reassembly line for the provided action key.
pub fn chooseAction(actionKey: []const u8) []const u8 {
    if (map.get(actionKey)) |r| {
        defer r.roundRobin = (r.roundRobin + 1) % r.reassemblies.len;
        const newVal = r.roundRobin;
        const selectedActionLine = r.reassemblies[newVal];
        return selectedActionLine;
    }
    unreachable;
}

pub fn processInput(_: std.Io, userInput: []const u8, alloc: std.mem.Allocator) anyerror!?[]const u8 {
    // 2. Iterate the ENTIRE map (reverse lookup by keywords), and do indexOf checks.
    // 2a. Find the longest matching key within the user's input.
    // 2. Iterate the ENTIRE map (reverse lookup by keywords), and do indexOf checks.
    // 2a. Find the longest matching key within the user's input.
    var longestKeyLen: usize = 0;
    var currentRank: ?usize = null;
    var longestMatch: ?*DBRule = null;
    var matchedKey: ?[]const u8 = null;
    var matchedKeyIdx: ?usize = null;
    var foundMatchInCurrentRank = false;

    // Pad the input with spaces (like the original) so that space-padded
    // keywords (' HOW ARE YOUR ') can match at the start/end of the input.
    // Allocated (rather than a fixed buffer) since this brain has no opinion
    // on how long a caller's input is allowed to be.
    const paddedInput = try std.fmt.allocPrint(alloc, " {s} ", .{userInput});
    defer alloc.free(paddedInput);

    // NOTE: it's VERY important to iterate the original DB file which has the entries
    // ordered by their ranking in ascending form.
    const orderedTable = parsedJSON.value.mappings;
    var orderedTableIdx: usize = 0;
    while (orderedTableIdx < orderedTable.len) : (orderedTableIdx += 1) {
        const r = &orderedTable[orderedTableIdx];
        const rank = r.rank;

        // Check if we've moved to a new rank
        if (currentRank == null) {
            currentRank = rank;
            foundMatchInCurrentRank = false;
            longestKeyLen = 0; // Reset for new rank
        } else if (rank != currentRank.?) {
            // We've moved to a higher rank
            if (foundMatchInCurrentRank) {
                // We found something in a lower rank, so we're done
                break;
            }
            // Move to the new rank and reset
            currentRank = rank;
            foundMatchInCurrentRank = false;
            longestKeyLen = 0; // Reset for new rank
        }

        for (r.keywords) |key| {
            var mappingTokenBuffer: [128]u8 = undefined;
            const mappingLC = std.ascii.lowerString(&mappingTokenBuffer, key);
            std.log.debug("rank: {d}, currentRank: {d}, key => {s}", .{ rank, currentRank.?, key });

            if (std.mem.indexOf(u8, mappingLC, "*") != null) {
                // Keyword with "*"
                // These keywords need the "*" removed in order to match; the
                // space that preceded the '*' stays and acts as a boundary.
                var buf: [128]u8 = undefined;
                const repSize = std.mem.replacementSize(u8, mappingLC, "*", "");
                _ = std.mem.replace(u8, mappingLC, "*", "", buf[0..repSize]);
                if (std.mem.indexOf(u8, paddedInput, buf[0..repSize])) |_| {
                    if (key.len > longestKeyLen) {
                        longestKeyLen = key.len;
                        longestMatch = r;
                        matchedKey = key;
                        foundMatchInCurrentRank = true;
                    }
                }
            } else {
                // Normal keyword without "*"
                if (std.mem.indexOf(u8, paddedInput, mappingLC)) |_| {
                    if (key.len > longestKeyLen) {
                        longestKeyLen = key.len;
                        longestMatch = r;
                        matchedKey = key;
                        foundMatchInCurrentRank = true;
                    }
                }
            }
        }
    }

    // 3. If a match was found, and it should be the longest as in: "YOU ARE" vs "YOU"
    // 3a. Pick a response round-robin (like the original does)
    if (longestMatch) |m| {
        // Figure out which key index was used
        for (m.keywords, 0..) |k, idx| {
            if (std.mem.eql(u8, matchedKey.?, k)) {
                matchedKeyIdx = idx;
            }
        }

        defer m.roundRobin = (m.roundRobin + 1) % m.reassemblies.len;
        const newVal = m.roundRobin;
        const speechLine = m.reassemblies[@intCast(newVal)];
        // Reassembly is driven by the chosen template: starless keywords
        // (I CAN'T) still capture the text after the keyword whenever the
        // template contains a '*' (Eliza's implicit "KEYWORD *").
        if (std.mem.indexOf(u8, speechLine, "*") == null) {
            // 1. TODO: Replace token ~ with user's name
            // 2. TODO: Ensure all replacements are finished!
            return speechLine;
        } else {
            // TODO: integrate the reassemble function here...but remember it returns an allocated string.
            // 1. TODO: Replace token ~ with user's name
            // 2. DONE: Replace token * with partial of user's input.
            // 3. TODO: Apply opposites: input=>I don't like you reassembly=>why don't you like me?
            //    Notice how "you" was remapped to "me"
            // 4. TODO: # should be replaced with a topic or perhaps topic in history.
            // 5. TODO: What else are we missing?

            const rebuiltReassembly = utility.reassemble(
                userInput,
                m.keywords[matchedKeyIdx.?],
                speechLine,
                parsedJSON.value.opposites,
                alloc,
            ) catch return null;

            if (rebuiltReassembly) |rr| {
                std.log.info("reassemble => input:{s}, reassembly:{s}", .{ userInput, rr });
            } else {
                std.log.info("reassemble => input:{s}, reassembly:null", .{userInput});
                // Fallback
                return chooseAction("<catch-all>");
            }
            return rebuiltReassembly;
        }
    }

    return null;
}

/// Loads the speech pack against std.testing.allocator; pair with testUnloadDatabase.
fn testLoadDatabase(io: std.Io) ![]const u8 {
    return loadDatabaseFiles(io, std.testing.allocator);
}

fn testUnloadDatabase(data: []const u8) void {
    std.testing.allocator.free(data);
    parsedJSON.deinit();
    map.deinit(std.testing.allocator);
    map = .empty;
}

test "wildcard line" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    // Test case 1
    {
        const resp = (try utility.reassemble(
            "are you always this fucking dumb?",
            "ARE YOU *",
            "WOULD YOU BE GLAD IF I WERE NOT *?",
            parsedJSON.value.opposites,
            std.testing.allocator,
        )) orelse return error.TestExpectedReassembly;
        defer std.testing.allocator.free(resp);

        try std.testing.expectEqualStrings(
            "WOULD YOU BE GLAD IF I WERE NOT ALWAYS THIS FUCKING DUMB?",
            resp,
        );
    }

    // Test case 2 (with opposite substitution applied)
    {
        const resp = (try utility.reassemble(
            "I feel like i'm dumb.",
            "I FEEL *",
            "WHY DO YOU FEEL *?",
            parsedJSON.value.opposites,
            std.testing.allocator,
        )) orelse return error.TestExpectedReassembly;
        defer std.testing.allocator.free(resp);

        // NOTE: the template's own '?' ends the response; the user's trailing
        // '.' is stripped along with the rest of their punctuation.
        try std.testing.expectEqualStrings(
            "WHY DO YOU FEEL LIKE YOU'RE DUMB?",
            resp,
        );
    }
}

test "processInput: starless keyword with starred reassembly captures remainder" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    // Rule "I CAN'T" has no '*' in its keyword, but its first reassembly is
    // "HAVE YOU EVER TRIED TO *" -- the text after the keyword is the capture.
    const resp = (try processInput(threaded.io(), "i can't sleep at night", std.testing.allocator)) orelse
        return error.TestExpectedResponse;
    defer std.testing.allocator.free(resp);

    try std.testing.expectEqualStrings("HAVE YOU EVER TRIED TO SLEEP AT NIGHT", resp);
}

test "processInput: space-padded keywords match at input boundaries" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const data = try testLoadDatabase(threaded.io());
    defer testUnloadDatabase(data);

    // ' HOW ARE YOUR ' is space-padded in the DB; it must match even though
    // the input has no leading space. It must also win over the shorter
    // greeting keyword 'HOW ARE YOU' within the same rank.
    const resp = (try processInput(threaded.io(), "how are your kids", std.testing.allocator)) orelse
        return error.TestExpectedResponse;
    // NOTE: no free here -- starless reassembly templates are returned
    // directly out of the parsed DB, not allocated.

    try std.testing.expectEqualStrings("THEY ARE FINE, HOW ABOUT YOURS?", resp);
}
