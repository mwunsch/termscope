const std = @import("std");
const terminal_mod = @import("terminal.zig");
const gt = terminal_mod.c;

pub const ParseError = error{
    InvalidKey,
    InvalidModifier,
    EmptyInput,
};

/// Result of parsing an Emacs key notation string.
/// Contains the raw bytes to send to the PTY.
pub const KeySequence = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn bytes(self: *const KeySequence) []const u8 {
        return self.buf[0..self.len];
    }

    fn append(self: *KeySequence, data: []const u8) void {
        for (data) |byte| {
            if (self.len < self.buf.len) {
                self.buf[self.len] = byte;
                self.len += 1;
            }
        }
    }

    fn appendByte(self: *KeySequence, byte: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = byte;
            self.len += 1;
        }
    }
};

/// Parse an Emacs key notation string and return the bytes to send to a PTY.
///
/// Supports:
/// - `C-c` → Ctrl+C (0x03)
/// - `M-x` → Alt+X (ESC + x)
/// - `C-M-a` → Ctrl+Alt+A (ESC + 0x01)
/// - `RET` → Enter (\r)
/// - `TAB` → Tab (\t)
/// - `ESC` → Escape (\x1b)
/// - `SPC` → Space
/// - `DEL` → Backspace (\x7f)
/// - `<delete>` → Forward delete
/// - `<up>`, `<down>`, `<left>`, `<right>` → Arrow keys
/// - `<home>`, `<end>` → Home/End
/// - `<prior>`, `<next>` → Page Up/Down
/// - `<f1>` … `<f12>` → Function keys
/// - `a`, `z`, `1`, `/` → Literal characters
/// - `C-x C-s` → Key sequence (space-separated)
pub fn parse(notation: []const u8) ParseError!KeySequence {
    if (notation.len == 0) return ParseError.EmptyInput;

    var result = KeySequence{};

    // Split on spaces for key sequences like "C-x C-s"
    var iter = std.mem.splitScalar(u8, notation, ' ');
    while (iter.next()) |part| {
        if (part.len == 0) continue;
        const single = try parseSingleKey(part);
        result.append(single.bytes());
    }

    if (result.len == 0) return ParseError.EmptyInput;
    return result;
}

fn parseSingleKey(key: []const u8) ParseError!KeySequence {
    var result = KeySequence{};
    var remaining = key;
    var ctrl = false;
    var meta = false;

    // Parse modifier prefixes
    while (remaining.len > 2) {
        if (std.mem.startsWith(u8, remaining, "C-")) {
            ctrl = true;
            remaining = remaining[2..];
        } else if (std.mem.startsWith(u8, remaining, "M-")) {
            meta = true;
            remaining = remaining[2..];
        } else {
            break;
        }
    }

    // Meta sends ESC prefix
    if (meta) {
        result.appendByte(0x1b);
    }

    // Check for special key names
    if (resolveSpecialKey(remaining)) |seq| {
        if (ctrl) {
            // Ctrl doesn't apply to most special keys, but for single-char
            // results we can apply it
            if (seq.len == 1 and seq[0] >= 0x40 and seq[0] <= 0x7f) {
                result.appendByte(seq[0] & 0x1f);
            } else {
                result.append(seq);
            }
        } else {
            result.append(seq);
        }
        return result;
    }

    // Check for bracketed keys like <up>, <f1>
    if (remaining.len > 2 and remaining[0] == '<' and remaining[remaining.len - 1] == '>') {
        const inner = remaining[1 .. remaining.len - 1];
        if (resolveBracketedKey(inner)) |seq| {
            result.append(seq);
            return result;
        }
        return ParseError.InvalidKey;
    }

    // Single character
    if (remaining.len == 1) {
        var ch = remaining[0];
        if (ctrl) {
            // Ctrl+letter: char & 0x1f
            if (ch >= 'a' and ch <= 'z') {
                ch = ch - 'a' + 1;
            } else if (ch >= 'A' and ch <= 'Z') {
                ch = ch - 'A' + 1;
            } else if (ch >= '@' and ch <= '_') {
                ch = ch & 0x1f;
            } else if (ch == '?') {
                ch = 0x7f; // C-? is DEL
            } else {
                return ParseError.InvalidKey;
            }
            result.appendByte(ch);
        } else {
            result.appendByte(ch);
        }
        return result;
    }

    return ParseError.InvalidKey;
}

fn resolveSpecialKey(name: []const u8) ?[]const u8 {
    const map = .{
        .{ "RET", "\r" },
        .{ "TAB", "\t" },
        .{ "ESC", "\x1b" },
        .{ "SPC", " " },
        .{ "DEL", "\x7f" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn resolveBracketedKey(name: []const u8) ?[]const u8 {
    const map = .{
        .{ "up", "\x1b[A" },
        .{ "down", "\x1b[B" },
        .{ "right", "\x1b[C" },
        .{ "left", "\x1b[D" },
        .{ "home", "\x1b[H" },
        .{ "end", "\x1b[F" },
        .{ "prior", "\x1b[5~" },
        .{ "next", "\x1b[6~" },
        .{ "delete", "\x1b[3~" },
        .{ "insert", "\x1b[2~" },
        .{ "f1", "\x1bOP" },
        .{ "f2", "\x1bOQ" },
        .{ "f3", "\x1bOR" },
        .{ "f4", "\x1bOS" },
        .{ "f5", "\x1b[15~" },
        .{ "f6", "\x1b[17~" },
        .{ "f7", "\x1b[18~" },
        .{ "f8", "\x1b[19~" },
        .{ "f9", "\x1b[20~" },
        .{ "f10", "\x1b[21~" },
        .{ "f11", "\x1b[23~" },
        .{ "f12", "\x1b[24~" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

test "parse C-c" {
    const seq = try parse("C-c");
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, 0x03), seq.buf[0]);
}

test "parse RET" {
    const seq = try parse("RET");
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, '\r'), seq.buf[0]);
}

test "parse ESC" {
    const seq = try parse("ESC");
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, 0x1b), seq.buf[0]);
}

test "parse arrow up" {
    const seq = try parse("<up>");
    try std.testing.expectEqualStrings("\x1b[A", seq.bytes());
}

test "parse C-x C-s" {
    const seq = try parse("C-x C-s");
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqual(@as(u8, 0x18), seq.buf[0]); // C-x
    try std.testing.expectEqual(@as(u8, 0x13), seq.buf[1]); // C-s
}

test "parse M-x" {
    const seq = try parse("M-x");
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqual(@as(u8, 0x1b), seq.buf[0]); // ESC
    try std.testing.expectEqual(@as(u8, 'x'), seq.buf[1]);
}

test "parse literal char" {
    const seq = try parse("a");
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, 'a'), seq.buf[0]);
}

test "parse f5" {
    const seq = try parse("<f5>");
    try std.testing.expectEqualStrings("\x1b[15~", seq.bytes());
}

test "parse SPC" {
    const seq = try parse("SPC");
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, ' '), seq.buf[0]);
}

test "parse DEL" {
    const seq = try parse("DEL");
    try std.testing.expectEqual(@as(usize, 1), seq.len);
    try std.testing.expectEqual(@as(u8, 0x7f), seq.buf[0]);
}

test "parse <delete>" {
    const seq = try parse("<delete>");
    try std.testing.expectEqualStrings("\x1b[3~", seq.bytes());
}

test "parse C-M-a" {
    const seq = try parse("C-M-a");
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqual(@as(u8, 0x1b), seq.buf[0]); // ESC (meta)
    try std.testing.expectEqual(@as(u8, 0x01), seq.buf[1]); // C-a
}
