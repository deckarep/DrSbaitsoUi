const std = @import("std");

// The original Dr. Sbaitso could "CALCulate simple Mathematics", either with
// the CALC command or by asking "WHAT IS 2 + 3". This is a small recursive
// descent evaluator for + - * / ^ and parentheses, plus a helper that phrases
// the answer the way Sbaitso says it: "2 PLUS 3 EQUALS TO 5".

pub const Error = error{
    /// Brackets nested deeper than the Dr. can handle.
    BracketsTooComplex,
    /// Anything malformed: stray characters, missing operands, division by zero...
    BadEquation,
};

/// Deepest bracket nesting the Dr. will put up with.
const MaxBracketDepth = 3;

const Token = union(enum) {
    number: f64,
    op: u8, // + - * / ^
    lparen,
    rparen,
};

const MaxTokens = 64;

const Tokens = struct {
    items: [MaxTokens]Token = undefined,
    len: usize = 0,
};

/// Strips whitespace and trailing question marks / equals signs, so
/// "2 + 2 = ?" and "2+2?" both work.
fn trimExpression(expr: []const u8) []const u8 {
    return std.mem.trim(u8, expr, " \t?=");
}

fn tokenize(expr: []const u8) Error!Tokens {
    var toks: Tokens = .{};
    var i: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        const tok: Token = switch (c) {
            ' ', '\t' => {
                i += 1;
                continue;
            },
            '0'...'9', '.' => blk: {
                const start = i;
                while (i < expr.len and (std.ascii.isDigit(expr[i]) or expr[i] == '.')) i += 1;
                const n = std.fmt.parseFloat(f64, expr[start..i]) catch return error.BadEquation;
                break :blk .{ .number = n };
            },
            '+', '-', '*', '/', '^' => .{ .op = c },
            'x', 'X' => .{ .op = '*' },
            '(' => .lparen,
            ')' => .rparen,
            else => return error.BadEquation,
        };
        if (tok != .number) i += 1;
        if (toks.len == MaxTokens) return error.BadEquation;
        toks.items[toks.len] = tok;
        toks.len += 1;
    }
    return toks;
}

const Parser = struct {
    toks: []const Token,
    pos: usize = 0,
    depth: usize = 0,

    fn peek(self: *Parser) ?Token {
        return if (self.pos < self.toks.len) self.toks[self.pos] else null;
    }

    fn peekOp(self: *Parser, ops: []const u8) ?u8 {
        const t = self.peek() orelse return null;
        if (t == .op and std.mem.indexOfScalar(u8, ops, t.op) != null) return t.op;
        return null;
    }

    // expr := term (('+' | '-') term)*
    fn expr(self: *Parser) Error!f64 {
        var v = try self.term();
        while (self.peekOp("+-")) |op| {
            self.pos += 1;
            const rhs = try self.term();
            v = if (op == '+') v + rhs else v - rhs;
        }
        return v;
    }

    // term := unary (('*' | '/') unary)*
    fn term(self: *Parser) Error!f64 {
        var v = try self.unary();
        while (self.peekOp("*/")) |op| {
            self.pos += 1;
            const rhs = try self.unary();
            if (op == '/' and rhs == 0) return error.BadEquation;
            v = if (op == '*') v * rhs else v / rhs;
        }
        return v;
    }

    // unary := ('-' | '+') unary | power
    fn unary(self: *Parser) Error!f64 {
        if (self.peekOp("+-")) |op| {
            self.pos += 1;
            const v = try self.unary();
            return if (op == '-') -v else v;
        }
        return self.power();
    }

    // power := primary ('^' unary)?   (right associative)
    fn power(self: *Parser) Error!f64 {
        const base = try self.primary();
        if (self.peekOp("^") != null) {
            self.pos += 1;
            return std.math.pow(f64, base, try self.unary());
        }
        return base;
    }

    // primary := number | '(' expr ')'
    fn primary(self: *Parser) Error!f64 {
        const t = self.peek() orelse return error.BadEquation;
        self.pos += 1;
        switch (t) {
            .number => |n| return n,
            .lparen => {
                self.depth += 1;
                if (self.depth > MaxBracketDepth) return error.BracketsTooComplex;
                const v = try self.expr();
                const close = self.peek() orelse return error.BadEquation;
                if (close != .rparen) return error.BadEquation;
                self.pos += 1;
                self.depth -= 1;
                return v;
            },
            else => return error.BadEquation,
        }
    }
};

/// Evaluates a simple arithmetic expression.
pub fn evaluate(expression: []const u8) Error!f64 {
    const toks = try tokenize(trimExpression(expression));
    if (toks.len == 0) return error.BadEquation;

    var p: Parser = .{ .toks = toks.items[0..toks.len] };
    const v = try p.expr();
    // Leftover tokens, e.g. "2 3" or "(2))".
    if (p.pos != toks.len) return error.BadEquation;
    if (!std.math.isFinite(v)) return error.BadEquation;
    return v;
}

/// True when the text is plausibly an equation (only math characters, with
/// at least one digit), so "WHAT IS 2 + 2" is calculated while "WHAT IS LOVE"
/// is left for the conversation.
pub fn looksLikeMath(text: []const u8) bool {
    const t = trimExpression(text);
    var sawDigit = false;
    for (t) |c| {
        switch (c) {
            '0'...'9' => sawDigit = true,
            '.', ' ', '\t', '+', '-', '*', '/', '^', 'x', 'X', '(', ')' => {},
            else => return false,
        }
    }
    return sawDigit;
}

fn writeNumber(w: *std.Io.Writer, n: f64) !void {
    const r = @round(n);
    if (n == r and @abs(n) < 1e15) {
        try w.print("{d}", .{@as(i64, @intFromFloat(r))});
        return;
    }

    // Up to 4 decimal places, without trailing zeros.
    var buf: [64]u8 = undefined;
    var s: []const u8 = try std.fmt.bufPrint(&buf, "{d:.4}", .{n});
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = std.mem.trimEnd(u8, s, "0");
        s = std.mem.trimEnd(u8, s, ".");
    }
    try w.writeAll(s);
}

/// Phrases the equation and its result the way Sbaitso says it, e.g.
/// "12 DIVIDED BY 4 EQUALS TO 3". Caller owns the returned slice.
pub fn describe(alloc: std.mem.Allocator, expression: []const u8, result: f64) ![]u8 {
    const toks = try tokenize(trimExpression(expression));

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    for (toks.items[0..toks.len], 0..) |t, i| {
        // Brackets hug their contents; everything else is space separated.
        const prevWasLParen = i > 0 and toks.items[i - 1] == .lparen;
        if (i > 0 and t != .rparen and !prevWasLParen) try w.writeByte(' ');
        switch (t) {
            .number => |n| try writeNumber(w, n),
            .op => |op| try w.writeAll(switch (op) {
                '+' => "PLUS",
                '-' => "MINUS",
                '*' => "TIMES",
                '/' => "DIVIDED BY",
                '^' => "TO THE POWER OF",
                else => unreachable,
            }),
            .lparen => try w.writeByte('('),
            .rparen => try w.writeByte(')'),
        }
    }

    try w.writeAll(" EQUALS TO ");
    if (result < 0) {
        try w.writeAll("MINUS ");
        try writeNumber(w, -result);
    } else {
        try writeNumber(w, result);
    }

    return out.toOwnedSlice();
}

test "evaluate: precedence and brackets" {
    try std.testing.expectEqual(@as(f64, 14), try evaluate("2 + 3 * 4"));
    try std.testing.expectEqual(@as(f64, 20), try evaluate("(2 + 3) * 4"));
    try std.testing.expectEqual(@as(f64, 3), try evaluate("12 / 4"));
    try std.testing.expectEqual(@as(f64, -1), try evaluate("-3 + 2"));
    try std.testing.expectEqual(@as(f64, 512), try evaluate("2 ^ 3 ^ 2"));
    try std.testing.expectEqual(@as(f64, 6), try evaluate("2 x 3?"));
    try std.testing.expectEqual(@as(f64, 2.5), try evaluate("5/2 ="));
}

test "evaluate: errors" {
    try std.testing.expectError(error.BadEquation, evaluate("2 +"));
    try std.testing.expectError(error.BadEquation, evaluate("2 3"));
    try std.testing.expectError(error.BadEquation, evaluate("1 / 0"));
    try std.testing.expectError(error.BadEquation, evaluate("(2 + 3"));
    try std.testing.expectError(error.BadEquation, evaluate("two plus two"));
    try std.testing.expectError(error.BadEquation, evaluate(""));
    try std.testing.expectError(error.BracketsTooComplex, evaluate("((((1))))"));
}

test "looksLikeMath" {
    try std.testing.expect(looksLikeMath("2 + 2?"));
    try std.testing.expect(looksLikeMath("(3x4)"));
    try std.testing.expect(!looksLikeMath("love"));
    try std.testing.expect(!looksLikeMath("5 dollars"));
    try std.testing.expect(!looksLikeMath("+ -"));
}

test "describe: phrased like Sbaitso" {
    const a = std.testing.allocator;

    const s1 = try describe(a, "12/4", 3);
    defer a.free(s1);
    try std.testing.expectEqualStrings("12 DIVIDED BY 4 EQUALS TO 3", s1);

    const s2 = try describe(a, "(2+3)*4", 20);
    defer a.free(s2);
    try std.testing.expectEqualStrings("(2 PLUS 3) TIMES 4 EQUALS TO 20", s2);

    const s3 = try describe(a, "1 - 3.5", -2.5);
    defer a.free(s3);
    try std.testing.expectEqualStrings("1 MINUS 3.5 EQUALS TO MINUS 2.5", s3);

    const s4 = try describe(a, "10/3", 10.0 / 3.0);
    defer a.free(s4);
    try std.testing.expectEqualStrings("10 DIVIDED BY 3 EQUALS TO 3.3333", s4);
}
