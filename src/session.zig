const std = @import("std");
const posix = std.posix;
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const pty_mod = @import("pty.zig");
const Pty = pty_mod.Pty;
const terminal_mod = @import("terminal.zig");
const Terminal = terminal_mod.Terminal;
const input_mod = @import("input.zig");
const snapshot_mod = @import("snapshot.zig");
const wait_mod = @import("wait.zig");

/// Run a session: read JSON-line requests from stdin, dispatch, write responses to stdout.
pub fn run(
    cmd_args: []const []const u8,
    cfg: *Config,
    allocator: std.mem.Allocator,
) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buf);

    // Spawn child
    var pty = Pty.spawn(cmd_args, cfg, allocator) catch |err| {
        try stderr.interface.print("termscope session: failed to spawn: {}\n", .{err});
        try stderr.interface.flush();
        std.process.exit(1);
    };

    // Create terminal
    var term = Terminal.init(cfg.resolvedCols(), cfg.resolvedRows()) catch |err| {
        try stderr.interface.print("termscope session: failed to create terminal: {}\n", .{err});
        try stderr.interface.flush();
        std.process.exit(1);
    };
    defer term.deinit();

    // Set up write_pty callback
    const PtyWriter = struct {
        pty_ref: *Pty,
        fn write(ctx: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.pty_ref.write(data) catch {};
        }
    };
    var pty_writer = PtyWriter{ .pty_ref = &pty };
    term.setWriteCallback(@ptrCast(&pty_writer), &PtyWriter.write);

    // Initial idle wait
    wait_mod.waitForIdle(&pty, &term, 100) catch {};

    // Read stdin line by line, process JSON requests
    const stdin_fd = posix.STDIN_FILENO;
    var line_buf: [65536]u8 = undefined;
    var line_len: usize = 0;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    while (true) {
        // Check if child exited
        if (pty.checkChildExit()) |exit_code| {
            // Write child_exit event
            try stdout.interface.print("{{\"event\":\"child_exit\",\"exit_code\":{d}}}\n", .{exit_code});
            try stdout.interface.flush();
            return;
        }

        // Poll stdin for input
        var fds = [_]posix.pollfd{
            .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = pty.master_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        const nready = posix.poll(&fds, 100) catch 0;
        _ = nready;

        // Drain PTY output
        if (fds[1].revents & posix.POLL.IN != 0) {
            wait_mod.drainPty(&pty, &term);
        }

        // Check for PTY EOF/error
        if (fds[1].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            wait_mod.drainPty(&pty, &term);
            if (pty.checkChildExit()) |exit_code| {
                try stdout.interface.print("{{\"event\":\"child_exit\",\"exit_code\":{d}}}\n", .{exit_code});
                try stdout.interface.flush();
                return;
            }
        }

        // Read stdin
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(stdin_fd, line_buf[line_len..]) catch break;
            if (n == 0) break; // EOF on stdin
            line_len += n;

            // Process complete lines
            while (std.mem.indexOf(u8, line_buf[0..line_len], "\n")) |newline_pos| {
                const line = line_buf[0..newline_pos];
                if (line.len > 0) {
                    processRequest(line, &pty, &term, cfg, allocator, &stdout.interface) catch |err| {
                        try stderr.interface.print("termscope session: error processing request: {}\n", .{err});
                        try stderr.interface.flush();
                    };
                }
                // Shift remaining data
                const remaining = line_len - newline_pos - 1;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, &line_buf, line_buf[newline_pos + 1 .. line_len]);
                }
                line_len = remaining;
            }
        }

        // Check stdin EOF/HUP
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            break;
        }
    }

    _ = pty.close();
}

fn processRequest(
    line: []const u8,
    pty: *Pty,
    term: *Terminal,
    cfg: *Config,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
) !void {
    // Parse the JSON request
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        try stdout.print("{{\"error\":{{\"code\":\"parse_error\",\"message\":\"invalid JSON\"}}}}\n", .{});
        try stdout.flush();
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try stdout.print("{{\"error\":{{\"code\":\"parse_error\",\"message\":\"expected object\"}}}}\n", .{});
        try stdout.flush();
        return;
    }

    const obj = root.object;

    // Get id
    const id_val = obj.get("id") orelse {
        try stdout.print("{{\"error\":{{\"code\":\"parse_error\",\"message\":\"missing id\"}}}}\n", .{});
        try stdout.flush();
        return;
    };
    const id: i64 = switch (id_val) {
        .integer => id_val.integer,
        else => 0,
    };

    // Get method
    const method_val = obj.get("method") orelse {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"parse_error\",\"message\":\"missing method\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    const method = switch (method_val) {
        .string => method_val.string,
        else => {
            try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"parse_error\",\"message\":\"method must be string\"}}}}\n", .{id});
            try stdout.flush();
            return;
        },
    };

    const params = obj.get("params");

    // Dispatch
    if (std.mem.eql(u8, method, "snapshot")) {
        try handleSnapshot(id, params, pty, term, allocator, stdout);
    } else if (std.mem.eql(u8, method, "type")) {
        try handleType(id, params, pty, stdout);
    } else if (std.mem.eql(u8, method, "press")) {
        try handlePress(id, params, pty, stdout);
    } else if (std.mem.eql(u8, method, "wait_for_text")) {
        try handleWaitForText(id, params, pty, term, cfg, allocator, stdout);
    } else if (std.mem.eql(u8, method, "wait_for_idle")) {
        try handleWaitForIdle(id, params, pty, term, cfg, stdout);
    } else if (std.mem.eql(u8, method, "wait_for_cursor")) {
        try handleWaitForCursor(id, params, pty, term, cfg, stdout);
    } else if (std.mem.eql(u8, method, "query")) {
        try handleQuery(id, term, stdout);
    } else if (std.mem.eql(u8, method, "resize")) {
        try handleResize(id, params, term, pty, stdout);
    } else if (std.mem.eql(u8, method, "close")) {
        try handleClose(id, pty, stdout);
    } else {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"unknown_method\",\"message\":\"unknown method: {s}\"}}}}\n", .{ id, method });
        try stdout.flush();
    }
}

fn handleSnapshot(id: i64, params: ?std.json.Value, pty: *Pty, term: *Terminal, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    wait_mod.drainPty(pty, term);

    var format_str: []const u8 = "text";
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("format")) |f| {
                if (f == .string) format_str = f.string;
            }
        }
    }

    var snap = try snapshot_mod.capture(term, allocator);
    defer snap.deinit();

    if (std.mem.eql(u8, format_str, "json")) {
        const json_out = try snapshot_mod.renderJson(&snap, allocator);
        defer allocator.free(json_out);
        try stdout.print("{{\"id\":{d},\"result\":{s}}}\n", .{ id, json_out });
    } else {
        const text = try snapshot_mod.renderText(&snap, allocator);
        defer allocator.free(text);
        // Escape the text for JSON
        var escaped: std.ArrayList(u8) = .{};
        defer escaped.deinit(allocator);
        const ew = escaped.writer(allocator);
        for (text) |ch| {
            switch (ch) {
                '"' => try ew.writeAll("\\\""),
                '\\' => try ew.writeAll("\\\\"),
                '\n' => try ew.writeAll("\\n"),
                '\r' => try ew.writeAll("\\r"),
                '\t' => try ew.writeAll("\\t"),
                else => {
                    if (ch < 0x20) {
                        try ew.print("\\u{x:0>4}", .{ch});
                    } else {
                        try ew.writeByte(ch);
                    }
                },
            }
        }
        try stdout.print("{{\"id\":{d},\"result\":{{\"cols\":{d},\"rows\":{d},\"cursor\":[{d},{d}],\"screen\":\"{s}\",\"title\":\"{s}\",\"text\":\"{s}\"}}}}\n", .{
            id, snap.cols, snap.rows, snap.cursor_row, snap.cursor_col, snap.screen, snap.title, escaped.items,
        });
    }
    try stdout.flush();
}

fn handleType(id: i64, params: ?std.json.Value, pty: *Pty, stdout: *std.Io.Writer) !void {
    const text = getStringParam(params, "text") orelse {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"invalid_params\",\"message\":\"missing text param\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    pty.write(text) catch {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"pty_error\",\"message\":\"write failed\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    try stdout.print("{{\"id\":{d},\"result\":{{}}}}\n", .{id});
    try stdout.flush();
}

fn handlePress(id: i64, params: ?std.json.Value, pty: *Pty, stdout: *std.Io.Writer) !void {
    const key = getStringParam(params, "key") orelse {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"invalid_params\",\"message\":\"missing key param\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    const seq = input_mod.parse(key) catch {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"invalid_key\",\"message\":\"invalid key notation\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    pty.write(seq.bytes()) catch {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"pty_error\",\"message\":\"write failed\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    try stdout.print("{{\"id\":{d},\"result\":{{}}}}\n", .{id});
    try stdout.flush();
}

fn handleWaitForText(id: i64, params: ?std.json.Value, pty: *Pty, term: *Terminal, cfg: *Config, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    const pattern = getStringParam(params, "pattern") orelse {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"invalid_params\",\"message\":\"missing pattern param\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    const timeout_ms = getIntParam(params, "timeout") orelse cfg.timeout_ms;

    const result = wait_mod.waitForText(pty, term, pattern, timeout_ms, allocator) catch {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"timeout\",\"message\":\"timed out after {d}ms\"}}}}\n", .{ id, timeout_ms });
        try stdout.flush();
        return;
    };

    try stdout.print("{{\"id\":{d},\"result\":{{\"found\":{},\"row\":{d},\"col\":{d}}}}}\n", .{ id, result.found, result.row orelse 0, result.col orelse 0 });
    try stdout.flush();
}

fn handleWaitForIdle(id: i64, params: ?std.json.Value, pty: *Pty, term: *Terminal, cfg: *Config, stdout: *std.Io.Writer) !void {
    const duration = getIntParam(params, "duration") orelse cfg.wait_idle_ms;
    wait_mod.waitForIdle(pty, term, duration) catch {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"timeout\",\"message\":\"idle wait timed out\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    try stdout.print("{{\"id\":{d},\"result\":{{}}}}\n", .{id});
    try stdout.flush();
}

fn handleWaitForCursor(id: i64, params: ?std.json.Value, pty: *Pty, term: *Terminal, cfg: *Config, stdout: *std.Io.Writer) !void {
    const row = getIntParam(params, "row") orelse 0;
    const col = getIntParam(params, "col") orelse 0;
    const timeout_ms = getIntParam(params, "timeout") orelse cfg.timeout_ms;
    wait_mod.waitForCursor(pty, term, @intCast(row), @intCast(col), timeout_ms) catch {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"timeout\",\"message\":\"cursor wait timed out\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    try stdout.print("{{\"id\":{d},\"result\":{{}}}}\n", .{id});
    try stdout.flush();
}

fn handleQuery(id: i64, term: *Terminal, stdout: *std.Io.Writer) !void {
    term.updateRenderState();
    const cursor = term.getCursor();
    try stdout.print("{{\"id\":{d},\"result\":{{\"cols\":{d},\"rows\":{d},\"cursor\":[{d},{d}],\"cursor_style\":\"{s}\",\"cursor_visible\":{},\"title\":\"{s}\",\"alt_screen\":{}}}}}\n", .{
        id,
        term.cols,
        term.rows,
        cursor.row,
        cursor.col,
        @as([]const u8, switch (cursor.style) {
            .block => "block",
            .bar => "bar",
            .underline => "underline",
            .block_hollow => "block_hollow",
        }),
        cursor.visible,
        term.getTitle(),
        term.isAltScreen(),
    });
    try stdout.flush();
}

fn handleResize(id: i64, params: ?std.json.Value, term: *Terminal, pty: *Pty, stdout: *std.Io.Writer) !void {
    const cols = getIntParam(params, "cols") orelse {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"invalid_params\",\"message\":\"missing cols\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    const rows = getIntParam(params, "rows") orelse {
        try stdout.print("{{\"id\":{d},\"error\":{{\"code\":\"invalid_params\",\"message\":\"missing rows\"}}}}\n", .{id});
        try stdout.flush();
        return;
    };
    term.resize(@intCast(cols), @intCast(rows));
    pty.resize(@intCast(cols), @intCast(rows));
    try stdout.print("{{\"id\":{d},\"result\":{{}}}}\n", .{id});
    try stdout.flush();
}

fn handleClose(id: i64, pty: *Pty, stdout: *std.Io.Writer) !void {
    const exit_code = pty.close();
    try stdout.print("{{\"id\":{d},\"result\":{{\"exit_code\":{d}}}}}\n", .{ id, exit_code });
    try stdout.flush();
    // Signal main loop to exit
    std.process.exit(0);
}

fn getStringParam(params: ?std.json.Value, key: []const u8) ?[]const u8 {
    if (params) |p| {
        if (p == .object) {
            if (p.object.get(key)) |v| {
                if (v == .string) return v.string;
            }
        }
    }
    return null;
}

fn getIntParam(params: ?std.json.Value, key: []const u8) ?u32 {
    if (params) |p| {
        if (p == .object) {
            if (p.object.get(key)) |v| {
                if (v == .integer) return @intCast(v.integer);
            }
        }
    }
    return null;
}
