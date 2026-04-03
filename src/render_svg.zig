const std = @import("std");
const terminal_mod = @import("terminal.zig");
const Terminal = terminal_mod.Terminal;

const font_size: u16 = 14;
const cell_width: u16 = 9;
const cell_height: u16 = 20;
const padding: u16 = 10;

/// Render terminal state as SVG.
/// Uses ghostty's plain text formatter for content, wraps in SVG.
pub fn render(term: *Terminal, allocator: std.mem.Allocator) ![]u8 {
    term.updateRenderState();
    const colors = term.getDefaultColors();
    const cursor = term.getCursor();

    const width = @as(u32, term.cols) * cell_width + padding * 2;
    const height = @as(u32, term.rows) * cell_height + padding * 2;

    // Get plain text from formatter
    const plain = try term.formatPlainText(allocator);
    defer allocator.free(plain);

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // SVG header
    try w.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {d} {d}" width="{d}" height="{d}">
        \\<style>text {{ font-family: "JetBrains Mono", "Fira Code", "SF Mono", monospace; font-size: {d}px; white-space: pre; }}</style>
        \\<rect width="100%" height="100%" fill="rgb({d},{d},{d})"/>
        \\
    , .{ width, height, width, height, font_size, colors.bg.r, colors.bg.g, colors.bg.b });

    // Render each line as a <text> element
    var line_iter = std.mem.splitScalar(u8, plain, '\n');
    var row: u16 = 0;
    while (line_iter.next()) |line| : (row += 1) {
        if (row >= term.rows) break;
        if (line.len == 0) continue;

        const x = padding;
        const y = @as(u32, row) * cell_height + padding + font_size;

        try w.print("<text x=\"{d}\" y=\"{d}\" fill=\"rgb({d},{d},{d})\">", .{
            x, y, colors.fg.r, colors.fg.g, colors.fg.b,
        });

        // XML-escape the line
        for (line) |ch| {
            switch (ch) {
                '<' => try w.writeAll("&lt;"),
                '>' => try w.writeAll("&gt;"),
                '&' => try w.writeAll("&amp;"),
                '"' => try w.writeAll("&quot;"),
                else => try w.writeByte(ch),
            }
        }

        try w.writeAll("</text>\n");
    }

    // Cursor
    if (cursor.visible) {
        const cx = @as(u32, cursor.col) * cell_width + padding;
        const cy = @as(u32, cursor.row) * cell_height + padding;
        try w.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"rgb({d},{d},{d})\" opacity=\"0.5\"/>\n", .{
            cx, cy, cell_width, cell_height, colors.fg.r, colors.fg.g, colors.fg.b,
        });
    }

    try w.writeAll("</svg>\n");

    return buf.toOwnedSlice(allocator);
}
