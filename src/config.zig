const std = @import("std");
const posix = std.posix;

pub const Theme = enum {
    dark,
    light,
};

pub const Palette = enum {
    default,
    solarized_dark,
    solarized_light,
    catppuccin_mocha,
    catppuccin_latte,
};

pub const Config = struct {
    cols: u16 = 0, // 0 = auto-detect
    rows: u16 = 0, // 0 = auto-detect
    term: []const u8 = "xterm-256color",
    theme: Theme = .dark,
    palette: Palette = .default,
    inherit_env: bool = false,
    wait_idle_ms: u32 = 200,
    timeout_ms: u32 = 30000,

    /// Extra env vars set via --env KEY=VALUE
    env_override_keys: [64][]const u8 = [_][]const u8{""} ** 64,
    env_override_vals: [64][]const u8 = [_][]const u8{""} ** 64,
    env_override_count: usize = 0,

    /// Resolve cols/rows: use explicit values if set, otherwise detect from TTY,
    /// fallback to 80x24.
    pub fn resolvedCols(self: *const Config) u16 {
        if (self.cols != 0) return self.cols;
        const ws = getTtySize() orelse return 80;
        return ws.cols;
    }

    pub fn resolvedRows(self: *const Config) u16 {
        if (self.rows != 0) return self.rows;
        const ws = getTtySize() orelse return 24;
        return ws.rows;
    }

    pub fn addEnvOverride(self: *Config, key: []const u8, value: []const u8) void {
        if (self.env_override_count < 64) {
            self.env_override_keys[self.env_override_count] = key;
            self.env_override_vals[self.env_override_count] = value;
            self.env_override_count += 1;
        }
    }

    /// Build the environment for the child process as a null-terminated
    /// array of null-terminated strings suitable for execve.
    pub fn buildChildEnv(self: *const Config, allocator: std.mem.Allocator) !std.ArrayList(?[*:0]const u8) {
        var env: std.ArrayList(?[*:0]const u8) = .{};
        errdefer env.deinit(allocator);

        if (self.inherit_env) {
            const environ = std.c.environ;
            var i: usize = 0;
            while (environ[i]) |entry| : (i += 1) {
                try env.append(allocator, entry);
            }
        } else {
            const inherit_keys = [_][]const u8{ "PATH", "HOME", "USER", "SHELL", "LANG" };
            for (&inherit_keys) |key| {
                if (posix.getenv(key)) |val| {
                    const entry = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ key, val }, 0);
                    try env.append(allocator, entry);
                }
            }
        }

        const term_entry = try std.fmt.allocPrintSentinel(allocator, "TERM={s}", .{self.term}, 0);
        try env.append(allocator, term_entry);

        const colorterm: [*:0]const u8 = "COLORTERM=truecolor";
        try env.append(allocator, colorterm);

        const term_program: [*:0]const u8 = "TERM_PROGRAM=termscope";
        try env.append(allocator, term_program);

        for (0..self.env_override_count) |idx| {
            const entry = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ self.env_override_keys[idx], self.env_override_vals[idx] }, 0);
            try env.append(allocator, entry);
        }

        try env.append(allocator, null);

        return env;
    }
};

pub const TtySize = struct {
    cols: u16,
    rows: u16,
};

pub fn getTtySize() ?TtySize {
    var wsz: posix.winsize = undefined;
    const fd = posix.STDIN_FILENO;

    const rc = std.c.ioctl(fd, std.c.T.IOCGWINSZ, &wsz);
    if (rc == 0) {
        if (wsz.col > 0 and wsz.row > 0) {
            return TtySize{
                .cols = wsz.col,
                .rows = wsz.row,
            };
        }
    }
    return null;
}

test "config defaults" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(u16, 0), cfg.cols);
    try std.testing.expectEqual(@as(u16, 0), cfg.rows);
    try std.testing.expectEqualStrings("xterm-256color", cfg.term);
    try std.testing.expectEqual(Theme.dark, cfg.theme);
    try std.testing.expectEqual(@as(u32, 200), cfg.wait_idle_ms);
    try std.testing.expectEqual(@as(u32, 30000), cfg.timeout_ms);
}

test "config resolved size fallback" {
    const cfg = Config{};
    const cols = cfg.resolvedCols();
    const rows = cfg.resolvedRows();
    try std.testing.expect(cols > 0);
    try std.testing.expect(rows > 0);
}

test "config explicit size" {
    const cfg = Config{ .cols = 120, .rows = 40 };
    try std.testing.expectEqual(@as(u16, 120), cfg.resolvedCols());
    try std.testing.expectEqual(@as(u16, 40), cfg.resolvedRows());
}
