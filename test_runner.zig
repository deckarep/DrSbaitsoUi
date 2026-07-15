//! Custom test runner wired in via build.zig's `.test_runner` option.
//!
//! Zig's default test runner only prints a scrolling line per test when
//! stderr isn't a real TTY; attached to a terminal it just shows a live
//! progress spinner and stays silent on passes. This runner always prints
//! "i/N name...OK/FAIL/SKIP" as it goes, so `make test` shows every test
//! scrolling by. Modeled closely on the relevant parts of Zig's own
//! lib/compiler/test_runner.zig (mainTerminal).
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init.Minimal) void {
    const test_fns = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;

    for (test_fns, 0..) |test_fn, i| {
        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            std.testing.io_instance.deinit();
            if (std.testing.allocator_instance.deinit() == .leak) leaks += 1;
        }
        std.testing.log_level = .warn;
        std.testing.environ = init.environ;

        std.debug.print("{d}/{d} {s}...", .{ i + 1, test_fns.len, test_fn.name });
        if (test_fn.func()) |_| {
            ok_count += 1;
            std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                fail_count += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }
    }

    if (ok_count == test_fns.len) {
        std.debug.print("All {d} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    if (leaks != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}
