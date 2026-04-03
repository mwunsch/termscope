const std = @import("std");
const terminal_mod = @import("terminal.zig");
const Terminal = terminal_mod.Terminal;
const ColorRgb = terminal_mod.ColorRgb;

pub const Format = enum {
    text,
    spans,
    json,
    svg,
    html,
    ansi,
};

pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    cursor_style: []const u8,
    screen: []const u8,
    title: []const u8,
    lines: std.ArrayList([]const u8) = .{},
    span_lines: std.ArrayList([]const u8) = .{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        for (self.span_lines.items) |line| self.allocator.free(line);
        self.span_lines.deinit(self.allocator);
    }
};

/// Capture the current state of a terminal into a Snapshot.
pub fn capture(term: *Terminal, allocator: std.mem.Allocator) !Snapshot {
    term.updateRenderState();
    const cursor = term.getCursor();

    var snap = Snapshot{
        .cols = term.cols,
        .rows = term.rows,
        .cursor_row = cursor.row,
        .cursor_col = cursor.col,
        .cursor_visible = cursor.visible,
        .cursor_style = switch (cursor.style) {
            .block => "block",
            .bar => "bar",
            .underline => "underline",
            .block_hollow => "block_hollow",
        },
        .screen = if (term.isAltScreen()) "alternate" else "primary",
        .title = term.getTitle(),
        .allocator = allocator,
    };
    errdefer snap.deinit();

    // Use ghostty's formatter for plain text lines
    const plain = try term.formatPlainText(allocator);
    defer allocator.free(plain);

    // Split into lines
    var line_iter = std.mem.splitScalar(u8, plain, '\n');
    while (line_iter.next()) |line| {
        try snap.lines.append(allocator, try allocator.dupe(u8, line));
    }

    // Build span data from render state
    var row_it = term.rowIterator();
    var row_idx: u16 = 0;
    while (row_it.next()) : (row_idx += 1) {
        var span_buf: std.ArrayList(u8) = .{};
        defer span_buf.deinit(allocator);

        var cells = row_it.cells();
        var col: u16 = 0;
        var run_start: u16 = 0;
        var run_style: ?SpanStyle = null;

        while (cells.next()) : (col += 1) {
            const style = readSpanStyle(&cells, col, cursor, row_idx);

            if (run_style) |rs| {
                if (!spanStyleEql(rs, style)) {
                    try writeSpanRun(allocator, &span_buf, run_start, col - 1, rs);
                    run_start = col;
                    run_style = style;
                }
            } else {
                run_start = col;
                run_style = style;
            }
        }
        if (run_style) |rs| {
            if (!isDefaultSpanStyle(rs)) {
                try writeSpanRun(allocator, &span_buf, run_start, col - 1, rs);
            }
        }

        try snap.span_lines.append(allocator, try allocator.dupe(u8, span_buf.items));
    }

    return snap;
}

const SpanStyle = struct {
    fg: ?ColorRgb = null,
    bg: ?ColorRgb = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,
    is_cursor: bool = false,
};

fn readSpanStyle(cells: *Terminal.CellIterator, col: u16, cursor: Terminal.CursorInfo, row_idx: u16) SpanStyle {
    var style = SpanStyle{
        .fg = cells.getFgColor(),
        .bg = cells.getBgColor(),
    };
    const cell_style = cells.getStyle();
    style.bold = cell_style.bold;
    style.italic = cell_style.italic;
    style.underline = cell_style.underline;
    style.dim = cell_style.dim;
    style.inverse = cell_style.inverse;
    style.strikethrough = cell_style.strikethrough;

    if (cursor.visible and cursor.col == col and cursor.row == row_idx) {
        style.is_cursor = true;
    }
    return style;
}

fn spanStyleEql(a: SpanStyle, b: SpanStyle) bool {
    return std.meta.eql(a, b);
}

fn isDefaultSpanStyle(s: SpanStyle) bool {
    return s.fg == null and s.bg == null and !s.bold and !s.italic and
        !s.underline and !s.dim and !s.inverse and !s.strikethrough and !s.is_cursor;
}

fn writeSpanRun(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), start: u16, end: u16, style: SpanStyle) !void {
    if (isDefaultSpanStyle(style)) return;

    const writer = buf.writer(allocator);
    if (buf.items.len > 0) try writer.writeByte(' ');

    if (start == end) {
        try writer.print("{d}:", .{start});
    } else {
        try writer.print("{d}-{d}:", .{ start, end });
    }

    var need_sep = false;

    if (style.is_cursor) {
        try writer.writeAll("cursor");
        return;
    }

    if (style.fg) |fg| {
        try writer.print("{d},{d},{d}", .{ fg.r, fg.g, fg.b });
        need_sep = true;
    }

    if (style.bg) |bg| {
        if (need_sep) try writer.writeByte('/');
        try writer.print("{d},{d},{d}", .{ bg.r, bg.g, bg.b });
        need_sep = true;
    }

    inline for (.{ .{ style.bold, "bold" }, .{ style.italic, "italic" }, .{ style.underline, "underline" }, .{ style.dim, "dim" }, .{ style.inverse, "inverse" }, .{ style.strikethrough, "strikethrough" } }) |pair| {
        if (pair[0]) {
            if (need_sep) try writer.writeByte('+');
            try writer.writeAll(pair[1]);
            need_sep = true;
        }
    }
}

/// Render snapshot in the "text" format.
pub fn renderText(snap: *const Snapshot, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("=== TERMSCOPE ===\n", .{});
    try w.print("cols={d} rows={d} cursor={d}:{d} screen={s} title=\"{s}\"\n\n", .{
        snap.cols, snap.rows, snap.cursor_row, snap.cursor_col, snap.screen, snap.title,
    });

    try w.print("=== TEXT ===\n", .{});
    var last_nonempty: usize = 0;
    for (snap.lines.items, 0..) |line, idx| {
        if (line.len > 0 and !isAllSpaces(line)) last_nonempty = idx + 1;
    }

    for (snap.lines.items[0..last_nonempty], 0..) |line, idx| {
        try w.print("[{d:0>3}] {s}\n", .{ idx + 1, line });
    }

    return buf.toOwnedSlice(allocator);
}

/// Render snapshot in the "spans" format.
pub fn renderSpans(snap: *const Snapshot, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("=== TERMSCOPE ===\n", .{});
    try w.print("cols={d} rows={d} cursor={d}:{d} screen={s} title=\"{s}\"\n\n", .{
        snap.cols, snap.rows, snap.cursor_row, snap.cursor_col, snap.screen, snap.title,
    });

    var last_nonempty: usize = 0;
    for (snap.lines.items, 0..) |line, idx| {
        if (line.len > 0 and !isAllSpaces(line)) last_nonempty = idx + 1;
    }

    try w.print("=== TEXT ===\n", .{});
    for (snap.lines.items[0..last_nonempty], 0..) |line, idx| {
        try w.print("[{d:0>3}] {s}\n", .{ idx + 1, line });
    }

    try w.print("\n=== SPANS ===\n", .{});
    for (snap.span_lines.items[0..@min(last_nonempty, snap.span_lines.items.len)], 0..) |spans, idx| {
        if (spans.len > 0) {
            try w.print("[{d:0>3}] {s}\n", .{ idx + 1, spans });
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Render snapshot as JSON.
pub fn renderJson(snap: *const Snapshot, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("{{\"cols\":{d},\"rows\":{d},\"cursor\":[{d},{d}],\"cursor_visible\":{},\"cursor_style\":\"{s}\",\"screen\":\"{s}\",\"title\":", .{
        snap.cols, snap.rows, snap.cursor_row, snap.cursor_col, snap.cursor_visible, snap.cursor_style, snap.screen,
    });
    try writeJsonString(w, snap.title);
    try w.writeAll(",\"lines\":[");

    for (snap.lines.items, 0..) |line, idx| {
        if (idx > 0) try w.writeByte(',');
        try writeJsonString(w, line);
    }

    try w.writeAll("]}");
    return buf.toOwnedSlice(allocator);
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn isAllSpaces(s: []const u8) bool {
    for (s) |ch| {
        if (ch != ' ') return false;
    }
    return true;
}

test "snapshot text format" {
    var term = try Terminal.init(80, 24);
    defer term.deinit();

    term.feed("Hello, World!");

    var snap = try capture(&term, std.testing.allocator);
    defer snap.deinit();

    const text = try renderText(&snap, std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "=== TERMSCOPE ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello, World!") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cols=80") != null);
}

test "snapshot json format" {
    var term = try Terminal.init(80, 24);
    defer term.deinit();

    term.feed("Test output");

    var snap = try capture(&term, std.testing.allocator);
    defer snap.deinit();

    const json_out = try renderJson(&snap, std.testing.allocator);
    defer std.testing.allocator.free(json_out);

    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"cols\":80") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "Test output") != null);
}
