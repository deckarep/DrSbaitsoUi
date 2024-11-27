const std = @import("std");

/// Straight from ziglang.org, but made to be threadsafe using a mutex.
/// Additionally, a condition variable is added to have
/// dequeue be blocked while it's waiting for work to do
/// this way it is not a needlessly busy spin loop.
pub fn Queue(comptime Child: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            data: Child,
            next: ?*Node,
        };

        mu: std.Thread.Mutex,
        cond: std.Thread.Condition,

        gpa: std.mem.Allocator,
        start: ?*Node,
        end: ?*Node,

        pub fn init(gpa: std.mem.Allocator) Self {
            return Self{
                .mu = std.Thread.Mutex{},
                .cond = std.Thread.Condition{},
                .gpa = gpa,
                .start = null,
                .end = null,
            };
        }

        pub fn enqueue(self: *Self, value: Child) !void {
            self.mu.lock();
            defer self.mu.unlock();

            const node = try self.gpa.create(Node);
            node.* = .{ .data = value, .next = null };
            if (self.end) |end| end.next = node //
            else self.start = node;
            self.end = node;

            // Signal the condition variable if the queue was previously empty
            // Awaken sleeping thread!
            self.cond.signal();
        }

        pub fn dequeue(self: *Self) Child {
            self.mu.lock();
            defer self.mu.unlock();

            // Block until there is work available
            while (self.start == null) {
                // Effectively puts the thread to sleep.
                self.cond.wait(&self.mu);
            }

            const start = self.start orelse unreachable;
            defer self.gpa.destroy(start);
            if (start.next) |next|
                self.start = next
            else {
                self.start = null;
                self.end = null;
            }
            return start.data;
        }
    };
}

test "queue" {
    var int_queue = Queue(i32).init(std.testing.allocator);

    try int_queue.enqueue(25);
    try int_queue.enqueue(50);
    try int_queue.enqueue(75);
    try int_queue.enqueue(100);

    try std.testing.expectEqual(int_queue.dequeue(), 25);
    try std.testing.expectEqual(int_queue.dequeue(), 50);
    try std.testing.expectEqual(int_queue.dequeue(), 75);
    try std.testing.expectEqual(int_queue.dequeue(), 100);
    try std.testing.expectEqual(int_queue.dequeue(), null);

    try int_queue.enqueue(5);
    try std.testing.expectEqual(int_queue.dequeue(), 5);
    try std.testing.expectEqual(int_queue.dequeue(), null);
}
