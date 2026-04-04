const std = @import("std");
const config_mod = @import("config.zig");
const pty_mod = @import("pty.zig");
const terminal_mod = @import("terminal.zig");
const input_mod = @import("input.zig");
const snapshot_mod = @import("snapshot.zig");
const wait_mod = @import("wait.zig");
const session_mod = @import("session.zig");
const render_svg = @import("render_svg.zig");
const render_html = @import("render_html.zig");

const build_options = @import("build_options");

const Config = config_mod.Config;
const Pty = pty_mod.Pty;
const Terminal = terminal_mod.Terminal;

const version = build_options.version;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var stderr = std.fs.File.stderr().writer(&stderr_buf);

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    // Collect all args into a slice
    var args_list: std.ArrayList([]const u8) = .{};
    defer {
        for (args_list.items) |a| allocator.free(a);
        args_list.deinit(allocator);
    }
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, try allocator.dupe(u8, arg));
    }
    const args = args_list.items;

    if (args.len < 2) {
        try printUsage(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(1);
    }

    // Parse global config and find subcommand
    var cfg = Config{};
    var cmd_start: usize = 1;

    // Scan for global flags before the subcommand
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            try stdout.interface.print("termscope {s}\n", .{version});
            try stdout.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(&stdout.interface);
            try stdout.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i < args.len) cfg.cols = std.fmt.parseInt(u16, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i < args.len) cfg.rows = std.fmt.parseInt(u16, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--term")) {
            i += 1;
            if (i < args.len) cfg.term = args[i];
        } else if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "light")) cfg.theme = .light;
            }
        } else if (std.mem.eql(u8, arg, "--inherit-env")) {
            cfg.inherit_env = true;
        } else if (std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.indexOf(u8, args[i], "=")) |eq_pos| {
                    cfg.addEnvOverride(args[i][0..eq_pos], args[i][eq_pos + 1 ..]);
                }
            }
        } else {
            cmd_start = i;
            break;
        }
    }

    if (cmd_start >= args.len) {
        try printUsage(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(1);
    }

    const subcommand = args[cmd_start];

    if (std.mem.eql(u8, subcommand, "snapshot")) {
        try runSnapshot(args[cmd_start + 1 ..], &cfg, allocator, &stdout.interface, &stderr.interface);
    } else if (std.mem.eql(u8, subcommand, "exec")) {
        try runExec(args[cmd_start + 1 ..], &cfg, allocator, &stdout.interface, &stderr.interface);
    } else if (std.mem.eql(u8, subcommand, "session")) {
        // Find command after --
        var session_cmd: ?[]const []const u8 = null;
        var j: usize = cmd_start + 1;
        while (j < args.len) : (j += 1) {
            if (std.mem.eql(u8, args[j], "--")) {
                session_cmd = args[j + 1 ..];
                break;
            }
        }
        const cmd = session_cmd orelse {
            try stderr.interface.print("termscope session: missing command after --\n", .{});
            try stderr.interface.flush();
            std.process.exit(1);
        };
        try session_mod.run(cmd, &cfg, allocator);
    } else {
        try stderr.interface.print("termscope: unknown command '{s}'\n", .{subcommand});
        try stderr.interface.flush();
        std.process.exit(1);
    }
}

fn runSnapshot(
    args: []const []const u8,
    cfg: *Config,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var format: snapshot_mod.Format = .text;
    var output_path: ?[]const u8 = null;
    var cmd_args: ?[]const []const u8 = null;

    // Parse snapshot-specific flags
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i < args.len) format = parseFormat(args[i]);
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--wait-idle")) {
            i += 1;
            if (i < args.len) cfg.wait_idle_ms = std.fmt.parseInt(u32, args[i], 10) catch cfg.wait_idle_ms;
        } else if (std.mem.eql(u8, arg, "--")) {
            cmd_args = args[i + 1 ..];
            break;
        }
    }

    const cmd = cmd_args orelse {
        try stderr.print("termscope snapshot: missing command after --\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    if (cmd.len == 0) {
        try stderr.print("termscope snapshot: empty command\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Spawn child
    var pty = Pty.spawn(cmd, cfg, allocator) catch |err| {
        try stderr.print("termscope snapshot: failed to spawn: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    // Create terminal
    var term = Terminal.init(cfg.resolvedCols(), cfg.resolvedRows()) catch |err| {
        try stderr.print("termscope snapshot: failed to create terminal: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer term.deinit();

    // Set up write_pty callback
    const PtyWriter = struct {
        pty_ref: *const Pty,

        fn write(ctx: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.pty_ref.write(data) catch {};
        }
    };
    var pty_writer = PtyWriter{ .pty_ref = &pty };
    term.setWriteCallback(@ptrCast(&pty_writer), &PtyWriter.write);

    // Wait for idle
    wait_mod.waitForIdle(&pty, &term, cfg.wait_idle_ms) catch {};

    // Render in the requested format
    const output = renderForFormat(format, &term, allocator, stderr) catch |err| {
        try stderr.print("termscope snapshot: failed to render: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer allocator.free(output);

    if (output_path) |path| {
        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            try stderr.print("termscope snapshot: failed to write {s}: {}\n", .{ path, err });
            try stderr.flush();
            std.process.exit(1);
        };
        defer file.close();
        file.writeAll(output) catch |err| {
            try stderr.print("termscope snapshot: write error: {}\n", .{err});
            try stderr.flush();
            std.process.exit(1);
        };
    } else {
        try stdout.writeAll(output);
        try stdout.flush();
    }

    _ = pty.close();
}

fn runExec(
    args: []const []const u8,
    cfg: *Config,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // Find command after --
    var cmd_args: ?[]const []const u8 = null;
    var steps: std.ArrayList(ExecStep) = .{};
    defer steps.deinit(allocator);
    var exec_format: snapshot_mod.Format = .text;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            cmd_args = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--wait-for-text")) {
            i += 1;
            if (i < args.len) try steps.append(allocator, .{ .wait_for_text = args[i] });
        } else if (std.mem.eql(u8, arg, "--type")) {
            i += 1;
            if (i < args.len) try steps.append(allocator, .{ .type_text = args[i] });
        } else if (std.mem.eql(u8, arg, "--press")) {
            i += 1;
            if (i < args.len) try steps.append(allocator, .{ .press = args[i] });
        } else if (std.mem.eql(u8, arg, "--wait-idle")) {
            i += 1;
            if (i < args.len) {
                const ms = std.fmt.parseInt(u32, args[i], 10) catch cfg.wait_idle_ms;
                try steps.append(allocator, .{ .wait_idle = ms });
            }
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            try steps.append(allocator, .snapshot);
        } else if (std.mem.eql(u8, arg, "--expect")) {
            i += 1;
            if (i < args.len) try steps.append(allocator, .{ .expect = args[i] });
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i < args.len) {
                cfg.timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch cfg.timeout_ms;
            }
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i < args.len) exec_format = parseFormat(args[i]);
        }
    }

    const cmd = cmd_args orelse {
        try stderr.print("termscope exec: missing command after --\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    if (cmd.len == 0) {
        try stderr.print("termscope exec: empty command\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Spawn child
    var pty = Pty.spawn(cmd, cfg, allocator) catch |err| {
        try stderr.print("termscope exec: failed to spawn: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };

    var term = Terminal.init(cfg.resolvedCols(), cfg.resolvedRows()) catch |err| {
        try stderr.print("termscope exec: failed to create terminal: {}\n", .{err});
        try stderr.flush();
        std.process.exit(1);
    };
    defer term.deinit();

    // Set up write_pty callback
    const PtyWriter = struct {
        pty_ref: *const Pty,

        fn write(ctx: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.pty_ref.write(data) catch {};
        }
    };
    var pty_writer = PtyWriter{ .pty_ref = &pty };
    term.setWriteCallback(@ptrCast(&pty_writer), &PtyWriter.write);

    // Initial drain
    wait_mod.waitForIdle(&pty, &term, 100) catch {};

    // Execute steps in order
    for (steps.items) |step| {
        switch (step) {
            .wait_for_text => |pattern| {
                _ = wait_mod.waitForText(&pty, &term, pattern, cfg.timeout_ms, allocator) catch |err| {
                    try stderr.print("termscope exec: wait_for_text '{s}' failed: {}\n", .{ pattern, err });
                    try stderr.flush();
                    std.process.exit(1);
                };
            },
            .type_text => |text| {
                pty.write(text) catch |err| {
                    try stderr.print("termscope exec: type failed: {}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
            },
            .press => |key_notation| {
                const seq = input_mod.parse(key_notation) catch |err| {
                    try stderr.print("termscope exec: invalid key '{s}': {}\n", .{ key_notation, err });
                    try stderr.flush();
                    std.process.exit(1);
                };
                pty.write(seq.bytes()) catch |err| {
                    try stderr.print("termscope exec: press failed: {}\n", .{err});
                    try stderr.flush();
                    std.process.exit(1);
                };
            },
            .wait_idle => |ms| {
                wait_mod.waitForIdle(&pty, &term, ms) catch {};
            },
            .snapshot => {
                wait_mod.drainPty(&pty, &term);
                const output = renderForFormat(exec_format, &term, allocator, stderr) catch {
                    std.process.exit(1);
                };
                defer allocator.free(output);
                try stdout.writeAll(output);
                try stdout.flush();
            },
            .expect => |pattern| {
                wait_mod.drainPty(&pty, &term);
                const text = term.formatPlainText(allocator) catch {
                    std.process.exit(1);
                };
                defer allocator.free(text);
                if (std.mem.indexOf(u8, text, pattern) == null) {
                    std.process.exit(1);
                }
            },
        }
    }

    _ = pty.close();
}

const ExecStep = union(enum) {
    wait_for_text: []const u8,
    type_text: []const u8,
    press: []const u8,
    wait_idle: u32,
    snapshot,
    expect: []const u8,
};

/// Render terminal state in the given format. Used by snapshot, exec, and session.
fn renderForFormat(
    format: snapshot_mod.Format,
    term: *Terminal,
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
) ![]u8 {
    switch (format) {
        .text, .spans, .json => {
            var snap = try snapshot_mod.capture(term, allocator);
            defer snap.deinit();
            return switch (format) {
                .text => snapshot_mod.renderText(&snap, allocator),
                .spans => snapshot_mod.renderSpans(&snap, allocator),
                .json => snapshot_mod.renderJson(&snap, allocator),
                else => unreachable,
            };
        },
        .html => return render_html.render(term, allocator),
        .svg => return render_svg.render(term, allocator),
        .ansi => return term.formatVt(allocator),
    }
    _ = stderr;
}

fn parseFormat(s: []const u8) snapshot_mod.Format {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "spans")) return .spans;
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "svg")) return .svg;
    if (std.mem.eql(u8, s, "html")) return .html;
    if (std.mem.eql(u8, s, "ansi")) return .ansi;
    return .text;
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: termscope <command> [options] [-- <cmd> [args...]]
        \\
        \\Commands:
        \\  snapshot    Capture terminal state of a command
        \\  exec        Launch, interact, and capture (linear sequence)
        \\  session     Interactive JSON-lines session (Playwright mode)
        \\
        \\Global Options:
        \\  --cols N        Terminal width (default: auto-detect or 80)
        \\  --rows N        Terminal height (default: auto-detect or 24)
        \\  --term VALUE    TERM env var (default: xterm-256color)
        \\  --theme dark|light  Color theme (default: dark)
        \\  --env KEY=VALUE     Extra env var (repeatable)
        \\  --inherit-env       Inherit full parent environment
        \\  --version           Print version
        \\  --help              Print this help
        \\
        \\Snapshot Options:
        \\  --format text|spans|json|svg|html  Output format (default: text)
        \\  -o PATH             Write to file instead of stdout
        \\  --wait-idle MS      Wait for idle before snapshot (default: 200)
        \\
        \\Exec Options (processed left-to-right):
        \\  --wait-for-text PATTERN  Block until text appears
        \\  --type TEXT              Send characters to PTY
        \\  --press KEY              Send key (Emacs notation: C-c, RET, <up>)
        \\  --wait-idle MS           Wait for output to settle
        \\  --snapshot               Take a snapshot
        \\  --expect TEXT             Assert text present (exit 1 if not)
        \\  --timeout MS             Set timeout for waits (default: 30000)
        \\
    , .{});
}

// Reference modules so their tests get included
comptime {
    _ = config_mod;
    _ = pty_mod;
    _ = terminal_mod;
    _ = input_mod;
    _ = snapshot_mod;
    _ = wait_mod;
    _ = session_mod;
    _ = render_svg;
    _ = render_html;
}
