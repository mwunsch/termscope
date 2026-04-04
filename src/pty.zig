const std = @import("std");
const posix = std.posix;
const config_mod = @import("config.zig");
const Config = config_mod.Config;

const builtin = @import("builtin");
const c = @cImport({
    if (builtin.os.tag == .linux) {
        @cInclude("pty.h");
    } else {
        @cInclude("util.h");
    }
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
});

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,

    pub const SpawnError = error{
        ForkFailed,
        OpenPtyFailed,
        ExecFailed,
        SetNonBlockFailed,
    } || std.mem.Allocator.Error;

    /// Spawn a child process in a new PTY.
    /// `argv` is the command + args (e.g. &.{"vim", "test.txt"}).
    /// `cfg` provides terminal size and environment.
    pub fn spawn(
        argv: []const []const u8,
        cfg: *const Config,
        allocator: std.mem.Allocator,
    ) SpawnError!Pty {
        if (argv.len == 0) return error.ExecFailed;

        const cols = cfg.resolvedCols();
        const rows = cfg.resolvedRows();

        var ws: posix.winsize = .{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };

        var master_fd: posix.fd_t = undefined;
        const pid = c.forkpty(&master_fd, null, null, @ptrCast(&ws));

        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // Child process
            execChild(argv, cfg, allocator) catch {
                std.posix.exit(127);
            };
            unreachable;
        }

        // Parent: set master fd to non-blocking
        setNonBlocking(master_fd) catch return error.SetNonBlockFailed;

        return Pty{
            .master_fd = master_fd,
            .child_pid = pid,
        };
    }

    fn execChild(
        argv: []const []const u8,
        cfg: *const Config,
        allocator: std.mem.Allocator,
    ) !void {
        // Build env
        var env_list = try cfg.buildChildEnv(allocator);
        defer env_list.deinit(allocator);

        // Convert argv to null-terminated C strings
        const argv_z = try allocator.alloc(?[*:0]const u8, argv.len + 1);
        for (argv, 0..) |arg, i| {
            argv_z[i] = try allocator.dupeZ(u8, arg);
        }
        argv_z[argv.len] = null;

        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_z.ptr);
        const env_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(env_list.items.ptr);

        return posix.execvpeZ(argv_ptr[0].?, argv_ptr, env_ptr);
    }

    /// Read from the PTY master. Returns bytes read, or null if EAGAIN (no data).
    pub fn read(self: *const Pty, buf: []u8) !?usize {
        const n = posix.read(self.master_fd, buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        if (n == 0) return null; // EOF
        return n;
    }

    /// Write to the PTY master (sends input to the child).
    pub fn write(self: *const Pty, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const written = posix.write(self.master_fd, data[offset..]) catch |err| switch (err) {
                error.WouldBlock => {
                    // Brief yield, then retry
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return err,
            };
            offset += written;
        }
    }

    /// Resize the PTY.
    pub fn resize(self: *const Pty, cols: u16, rows: u16) void {
        var ws: posix.winsize = .{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);
    }

    /// Close the PTY: send SIGHUP, wait up to 2s, then SIGKILL if needed.
    pub fn close(self: *Pty) i32 {
        // If child already exited (reaped by checkChildExit), just close fd
        if (self.child_pid == 0) {
            posix.close(self.master_fd);
            return 0;
        }

        // Send SIGHUP to child
        posix.kill(self.child_pid, std.posix.SIG.HUP) catch {};

        // Wait up to 2 seconds for child to exit
        const exit_code = self.waitForExit(2000);
        if (exit_code != null) {
            posix.close(self.master_fd);
            return exit_code.?;
        }

        // Force kill
        posix.kill(self.child_pid, std.posix.SIG.KILL) catch {};
        const forced_exit = self.waitForExit(1000) orelse -1;
        posix.close(self.master_fd);
        return forced_exit;
    }

    /// Poll the PTY fd for readability. Returns true if data is available.
    pub fn pollRead(self: *const Pty, timeout_ms: i32) bool {
        var fds = [_]posix.pollfd{.{
            .fd = self.master_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const n = posix.poll(&fds, timeout_ms) catch return false;
        return n > 0 and (fds[0].revents & posix.POLL.IN != 0);
    }

    /// Check if child has exited (non-blocking). Returns exit code or null.
    pub fn checkChildExit(self: *Pty) ?i32 {
        if (self.child_pid == 0) return 0; // Already reaped
        const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
        if (result.pid != 0) {
            self.child_pid = 0; // Mark as reaped
            return decodeExitStatus(result.status);
        }
        return null;
    }

    fn waitForExit(self: *Pty, timeout_ms: u32) ?i32 {
        var elapsed: u32 = 0;
        const interval: u32 = 50;
        while (elapsed < timeout_ms) {
            if (self.checkChildExit()) |code| return code;
            std.Thread.sleep(interval * std.time.ns_per_ms);
            elapsed += interval;
        }
        return null;
    }

    fn decodeExitStatus(status: u32) i32 {
        // WIFEXITED: high byte of low 16 bits
        if (status & 0x7f == 0) {
            // Normal exit: WEXITSTATUS
            return @intCast((status >> 8) & 0xff);
        }
        // Signaled: return negative signal number
        const sig: i32 = @intCast(status & 0x7f);
        return -sig;
    }
};

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    // O_NONBLOCK = 0x0004 on macOS, 0x800 on Linux
    const O_NONBLOCK: usize = if (@import("builtin").os.tag == .linux) 0x800 else 0x0004;
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);
}

test "pty spawn and read" {
    const allocator = std.testing.allocator;
    var cfg = Config{ .cols = 80, .rows = 24 };

    const argv = &[_][]const u8{ "/bin/echo", "hello from pty" };
    var pty = try Pty.spawn(argv, &cfg, allocator);

    // Wait for output
    var buf: [4096]u8 = undefined;
    var output: []const u8 = &.{};
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        if (pty.pollRead(50)) {
            if (pty.read(&buf) catch null) |n| {
                output = buf[0..n];
                break;
            }
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, output, "hello from pty") != null);

    const exit_code = pty.close();
    try std.testing.expect(exit_code >= 0);
}
