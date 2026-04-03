const std = @import("std");
const posix = std.posix;
const terminal_mod = @import("terminal.zig");
const Terminal = terminal_mod.Terminal;
const pty_mod = @import("pty.zig");
const Pty = pty_mod.Pty;

pub const WaitResult = struct {
    found: bool = false,
    row: ?u16 = null,
    col: ?u16 = null,
};

pub const WaitError = error{
    Timeout,
    PtyReadError,
};

/// Feed any available PTY data into the terminal (non-blocking).
pub fn drainPty(pty: *Pty, term: *Terminal) void {
    var buf: [8192]u8 = undefined;
    var iterations: u32 = 0;
    while (iterations < 100) : (iterations += 1) {
        const n = pty.read(&buf) catch break;
        if (n) |bytes_read| {
            term.feed(buf[0..bytes_read]);
        } else {
            break;
        }
    }
}

/// Wait until `pattern` appears on any line of the terminal.
/// Returns the position where it was found, or error.Timeout.
pub fn waitForText(
    pty: *Pty,
    term: *Terminal,
    pattern: []const u8,
    timeout_ms: u32,
    allocator: std.mem.Allocator,
) !WaitResult {
    const deadline = std.time.milliTimestamp() + @as(i64, timeout_ms);

    while (std.time.milliTimestamp() < deadline) {
        // Feed available PTY data
        if (pty.pollRead(50)) {
            drainPty(pty, term);
        }

        // Check terminal content
        const text = term.formatPlainText(allocator) catch continue;
        defer allocator.free(text);

        var row: u16 = 0;
        var line_iter = std.mem.splitScalar(u8, text, '\n');
        while (line_iter.next()) |line| : (row += 1) {
            if (std.mem.indexOf(u8, line, pattern)) |col_idx| {
                return WaitResult{
                    .found = true,
                    .row = row,
                    .col = @intCast(col_idx),
                };
            }
        }
    }

    return WaitError.Timeout;
}

/// Wait until the terminal has been idle (no new PTY output) for `duration_ms`.
pub fn waitForIdle(
    pty: *Pty,
    term: *Terminal,
    duration_ms: u32,
) !void {
    var last_activity = std.time.milliTimestamp();
    const overall_timeout: i64 = 60000; // 60s max
    const start = std.time.milliTimestamp();

    while (std.time.milliTimestamp() - start < overall_timeout) {
        // Check if child has exited
        if (pty.checkChildExit() != null) {
            // Drain any remaining output
            drainPty(pty, term);
            return;
        }

        if (pty.pollRead(@intCast(@min(duration_ms, 100)))) {
            drainPty(pty, term);
            last_activity = std.time.milliTimestamp();
        }

        const idle_time = std.time.milliTimestamp() - last_activity;
        if (idle_time >= @as(i64, duration_ms)) {
            return; // Idle long enough
        }
    }

    return WaitError.Timeout;
}

/// Wait until the cursor is at the specified position.
pub fn waitForCursor(
    pty: *Pty,
    term: *Terminal,
    target_row: u16,
    target_col: u16,
    timeout_ms: u32,
) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, timeout_ms);

    while (std.time.milliTimestamp() < deadline) {
        if (pty.pollRead(50)) {
            drainPty(pty, term);
        }

        const cursor = term.getCursor();
        if (cursor.row == target_row and cursor.col == target_col) {
            return;
        }
    }

    return WaitError.Timeout;
}
