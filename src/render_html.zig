const std = @import("std");
const terminal_mod = @import("terminal.zig");
const Terminal = terminal_mod.Terminal;
const ColorRgb = terminal_mod.ColorRgb;

/// Render terminal state as HTML using ghostty's built-in HTML formatter.
pub fn render(term: *Terminal, allocator: std.mem.Allocator) ![]u8 {
    return term.formatHtml(allocator);
}
