const std = @import("std");

const gt = @cImport({
    @cInclude("ghostty/vt.h");
});

pub const Terminal = struct {
    terminal: gt.GhosttyTerminal,
    render_state: gt.GhosttyRenderState,
    row_iterator: gt.GhosttyRenderStateRowIterator,
    row_cells: gt.GhosttyRenderStateRowCells,
    key_encoder: gt.GhosttyKeyEncoder,

    /// Pointer back to the Pty for write_pty callback.
    /// Set after init via setWriteContext.
    write_ctx: ?*anyopaque = null,
    write_fn: ?*const fn (*anyopaque, []const u8) void = null,

    cols: u16,
    rows: u16,

    pub fn init(cols: u16, rows: u16) !Terminal {
        var terminal: gt.GhosttyTerminal = undefined;
        const opts = gt.GhosttyTerminalOptions{
            .cols = cols,
            .rows = rows,
            .max_scrollback = 1000,
        };

        if (gt.ghostty_terminal_new(null, &terminal, opts) != gt.GHOSTTY_SUCCESS) {
            return error.TerminalCreateFailed;
        }
        errdefer gt.ghostty_terminal_free(terminal);

        var render_state: gt.GhosttyRenderState = undefined;
        if (gt.ghostty_render_state_new(null, &render_state) != gt.GHOSTTY_SUCCESS) {
            return error.RenderStateCreateFailed;
        }
        errdefer gt.ghostty_render_state_free(render_state);

        var row_iterator: gt.GhosttyRenderStateRowIterator = undefined;
        if (gt.ghostty_render_state_row_iterator_new(null, &row_iterator) != gt.GHOSTTY_SUCCESS) {
            return error.RowIteratorCreateFailed;
        }
        errdefer gt.ghostty_render_state_row_iterator_free(row_iterator);

        var row_cells: gt.GhosttyRenderStateRowCells = undefined;
        if (gt.ghostty_render_state_row_cells_new(null, &row_cells) != gt.GHOSTTY_SUCCESS) {
            return error.RowCellsCreateFailed;
        }
        errdefer gt.ghostty_render_state_row_cells_free(row_cells);

        var key_encoder: gt.GhosttyKeyEncoder = undefined;
        if (gt.ghostty_key_encoder_new(null, &key_encoder) != gt.GHOSTTY_SUCCESS) {
            return error.KeyEncoderCreateFailed;
        }

        return Terminal{
            .terminal = terminal,
            .render_state = render_state,
            .row_iterator = row_iterator,
            .row_cells = row_cells,
            .key_encoder = key_encoder,
            .cols = cols,
            .rows = rows,
        };
    }

    pub fn deinit(self: *Terminal) void {
        gt.ghostty_key_encoder_free(self.key_encoder);
        gt.ghostty_render_state_row_cells_free(self.row_cells);
        gt.ghostty_render_state_row_iterator_free(self.row_iterator);
        gt.ghostty_render_state_free(self.render_state);
        gt.ghostty_terminal_free(self.terminal);
    }

    /// Feed raw bytes (PTY output) into the terminal for VT processing.
    pub fn feed(self: *Terminal, data: []const u8) void {
        gt.ghostty_terminal_vt_write(self.terminal, data.ptr, data.len);
    }

    /// Set up the write_pty callback so the terminal can respond to queries.
    pub fn setWriteCallback(self: *Terminal, ctx: *anyopaque, func: *const fn (*anyopaque, []const u8) void) void {
        self.write_ctx = ctx;
        self.write_fn = func;

        // Register userdata (pointer to this Terminal)
        _ = gt.ghostty_terminal_set(
            self.terminal,
            gt.GHOSTTY_TERMINAL_OPT_USERDATA,
            @ptrCast(self),
        );

        // Register write_pty callback.
        // The C API expects: ghostty_terminal_set(t, OPT_WRITE_PTY, (const void*)fn_ptr)
        // In Zig, we cast the function pointer to an integer and back to a data pointer.
        const fn_ptr: *const fn (?*gt.struct_GhosttyTerminal, ?*anyopaque, [*c]const u8, usize) callconv(.c) void = &writePtyCallback;
        _ = gt.ghostty_terminal_set(
            self.terminal,
            gt.GHOSTTY_TERMINAL_OPT_WRITE_PTY,
            @ptrFromInt(@intFromPtr(fn_ptr)),
        );
    }

    fn writePtyCallback(_: gt.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self: *Terminal = @ptrCast(@alignCast(userdata));
        if (self.write_fn) |func| {
            if (self.write_ctx) |ctx| {
                func(ctx, data[0..len]);
            }
        }
    }

    /// Update render state from terminal. Call before reading cells.
    pub fn updateRenderState(self: *Terminal) void {
        _ = gt.ghostty_render_state_update(self.render_state, self.terminal);
    }

    /// Get the dirty state of the render.
    pub fn getDirty(self: *Terminal) DirtyState {
        var dirty: c_int = gt.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = gt.ghostty_render_state_get(
            self.render_state,
            gt.GHOSTTY_RENDER_STATE_DATA_DIRTY,
            @ptrCast(&dirty),
        );
        return switch (dirty) {
            gt.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL => .partial,
            gt.GHOSTTY_RENDER_STATE_DIRTY_FULL => .full,
            else => .clean,
        };
    }

    /// Get cursor position (col, row), 0-indexed.
    pub fn getCursor(self: *Terminal) CursorInfo {
        var info = CursorInfo{};

        var x: u16 = 0;
        var y: u16 = 0;
        _ = gt.ghostty_terminal_get(self.terminal, gt.GHOSTTY_TERMINAL_DATA_CURSOR_X, @ptrCast(&x));
        _ = gt.ghostty_terminal_get(self.terminal, gt.GHOSTTY_TERMINAL_DATA_CURSOR_Y, @ptrCast(&y));
        info.col = x;
        info.row = y;

        var visible: bool = true;
        _ = gt.ghostty_terminal_get(self.terminal, gt.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, @ptrCast(&visible));
        info.visible = visible;

        // Cursor style from render state
        var has_cursor: bool = false;
        _ = gt.ghostty_render_state_get(self.render_state, gt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, @ptrCast(&has_cursor));

        if (has_cursor) {
            var style: c_int = gt.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
            _ = gt.ghostty_render_state_get(self.render_state, gt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, @ptrCast(&style));
            info.style = switch (style) {
                gt.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => .bar,
                gt.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => .underline,
                gt.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => .block_hollow,
                else => .block,
            };
        }

        return info;
    }

    /// Get the terminal title.
    pub fn getTitle(self: *Terminal) []const u8 {
        var title: gt.GhosttyString = undefined;
        if (gt.ghostty_terminal_get(self.terminal, gt.GHOSTTY_TERMINAL_DATA_TITLE, @ptrCast(&title)) == gt.GHOSTTY_SUCCESS) {
            if (title.len > 0) {
                return title.ptr[0..title.len];
            }
        }
        return "";
    }

    /// Check if the alternate screen is active.
    pub fn isAltScreen(self: *Terminal) bool {
        var screen: c_int = gt.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        _ = gt.ghostty_terminal_get(self.terminal, gt.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, @ptrCast(&screen));
        return screen == gt.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    }

    /// Resize the terminal.
    pub fn resize(self: *Terminal, cols: u16, rows_val: u16) void {
        _ = gt.ghostty_terminal_resize(self.terminal, cols, rows_val, 0, 0);
        self.cols = cols;
        self.rows = rows_val;
    }

    /// Format terminal content as plain text using ghostty's built-in formatter.
    pub fn formatPlainText(self: *Terminal, allocator: std.mem.Allocator) ![]u8 {
        return self.formatWith(gt.GHOSTTY_FORMATTER_FORMAT_PLAIN, allocator);
    }

    /// Format terminal content as HTML using ghostty's built-in formatter.
    pub fn formatHtml(self: *Terminal, allocator: std.mem.Allocator) ![]u8 {
        return self.formatWith(gt.GHOSTTY_FORMATTER_FORMAT_HTML, allocator);
    }

    /// Format terminal content as VT escape sequences (ANSI).
    pub fn formatVt(self: *Terminal, allocator: std.mem.Allocator) ![]u8 {
        return self.formatWith(gt.GHOSTTY_FORMATTER_FORMAT_VT, allocator);
    }

    fn formatWith(self: *Terminal, format: c_uint, allocator: std.mem.Allocator) ![]u8 {
        var opts: gt.GhosttyFormatterTerminalOptions = std.mem.zeroes(gt.GhosttyFormatterTerminalOptions);
        opts.size = @sizeOf(gt.GhosttyFormatterTerminalOptions);
        opts.emit = @intCast(format);
        opts.trim = true;

        var formatter: gt.GhosttyFormatter = undefined;
        if (gt.ghostty_formatter_terminal_new(null, &formatter, self.terminal, opts) != gt.GHOSTTY_SUCCESS) {
            return error.FormatterCreateFailed;
        }
        defer gt.ghostty_formatter_free(formatter);

        var out_ptr: [*c]u8 = undefined;
        var out_len: usize = 0;
        if (gt.ghostty_formatter_format_alloc(formatter, null, &out_ptr, &out_len) != gt.GHOSTTY_SUCCESS) {
            return error.FormatterFormatFailed;
        }

        // Copy to Zig-managed memory
        const result = try allocator.alloc(u8, out_len);
        @memcpy(result, out_ptr[0..out_len]);

        // Free ghostty-allocated memory
        gt.ghostty_free(null, out_ptr, out_len);

        return result;
    }

    /// Sync key encoder options from terminal state.
    pub fn syncKeyEncoder(self: *Terminal) void {
        gt.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.terminal);
    }

    /// Encode a key event and return the escape sequence bytes.
    pub fn encodeKey(self: *Terminal, key: c_uint, mods: u16, action: c_uint) ![]const u8 {
        self.syncKeyEncoder();

        var event: gt.GhosttyKeyEvent = undefined;
        if (gt.ghostty_key_event_new(null, &event) != gt.GHOSTTY_SUCCESS) {
            return error.KeyEventCreateFailed;
        }
        defer gt.ghostty_key_event_free(event);

        gt.ghostty_key_event_set_action(event, @intCast(action));
        gt.ghostty_key_event_set_key(event, @intCast(key));
        gt.ghostty_key_event_set_mods(event, mods);

        var buf: [128]u8 = undefined;
        var written: usize = 0;
        if (gt.ghostty_key_encoder_encode(self.key_encoder, event, &buf, buf.len, &written) != gt.GHOSTTY_SUCCESS) {
            return error.KeyEncodeFailed;
        }

        if (written == 0) return error.KeyEncodeFailed;

        return buf[0..written];
    }

    /// Get default foreground and background colors.
    pub fn getDefaultColors(self: *Terminal) struct { fg: ColorRgb, bg: ColorRgb } {
        var fg: gt.GhosttyColorRgb = .{ .r = 204, .g = 204, .b = 204 };
        var bg: gt.GhosttyColorRgb = .{ .r = 0, .g = 0, .b = 0 };
        _ = gt.ghostty_render_state_get(self.render_state, gt.GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, @ptrCast(&fg));
        _ = gt.ghostty_render_state_get(self.render_state, gt.GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, @ptrCast(&bg));
        return .{
            .fg = .{ .r = fg.r, .g = fg.g, .b = fg.b },
            .bg = .{ .r = bg.r, .g = bg.g, .b = bg.b },
        };
    }

    /// Iterate rows via render state. Returns a RowIterator.
    pub fn rowIterator(self: *Terminal) RowIterator {
        _ = gt.ghostty_render_state_get(
            self.render_state,
            gt.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            @ptrCast(&self.row_iterator),
        );
        return RowIterator{ .terminal = self };
    }

    pub const RowIterator = struct {
        terminal: *Terminal,

        pub fn next(self: *RowIterator) bool {
            return gt.ghostty_render_state_row_iterator_next(self.terminal.row_iterator);
        }

        /// Get cells iterator for the current row.
        pub fn cells(self: *RowIterator) CellIterator {
            _ = gt.ghostty_render_state_row_get(
                self.terminal.row_iterator,
                gt.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                @ptrCast(&self.terminal.row_cells),
            );
            return CellIterator{ .terminal = self.terminal };
        }

        pub fn isDirty(self: *RowIterator) bool {
            var dirty: bool = false;
            _ = gt.ghostty_render_state_row_get(
                self.terminal.row_iterator,
                gt.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                @ptrCast(&dirty),
            );
            return dirty;
        }
    };

    pub const CellIterator = struct {
        terminal: *Terminal,

        pub fn next(self: *CellIterator) bool {
            return gt.ghostty_render_state_row_cells_next(self.terminal.row_cells);
        }

        pub fn select(self: *CellIterator, x: u16) bool {
            return gt.ghostty_render_state_row_cells_select(self.terminal.row_cells, x) == gt.GHOSTTY_SUCCESS;
        }

        pub fn getGrapheme(self: *CellIterator) []const u8 {
            var len: usize = 0;
            _ = gt.ghostty_render_state_row_cells_get(
                self.terminal.row_cells,
                gt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                @ptrCast(&len),
            );
            if (len == 0) return " ";

            var buf: [*c]const u8 = undefined;
            _ = gt.ghostty_render_state_row_cells_get(
                self.terminal.row_cells,
                gt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                @ptrCast(&buf),
            );
            return buf[0..len];
        }

        pub fn getFgColor(self: *CellIterator) ?ColorRgb {
            var color: gt.GhosttyColorRgb = undefined;
            if (gt.ghostty_render_state_row_cells_get(
                self.terminal.row_cells,
                gt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                @ptrCast(&color),
            ) == gt.GHOSTTY_SUCCESS) {
                return .{ .r = color.r, .g = color.g, .b = color.b };
            }
            return null;
        }

        pub fn getBgColor(self: *CellIterator) ?ColorRgb {
            var color: gt.GhosttyColorRgb = undefined;
            if (gt.ghostty_render_state_row_cells_get(
                self.terminal.row_cells,
                gt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                @ptrCast(&color),
            ) == gt.GHOSTTY_SUCCESS) {
                return .{ .r = color.r, .g = color.g, .b = color.b };
            }
            return null;
        }

        pub fn getStyle(self: *CellIterator) CellStyle {
            var gs: gt.GhosttyStyle = std.mem.zeroes(gt.GhosttyStyle);
            gs.size = @sizeOf(gt.GhosttyStyle);
            if (gt.ghostty_render_state_row_cells_get(
                self.terminal.row_cells,
                gt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                @ptrCast(&gs),
            ) == gt.GHOSTTY_SUCCESS) {
                return CellStyle{
                    .bold = gs.bold,
                    .italic = gs.italic,
                    .underline = gs.underline != 0,
                    .dim = gs.faint,
                    .inverse = gs.inverse,
                    .strikethrough = gs.strikethrough,
                };
            }
            return CellStyle{};
        }
    };

    pub const DirtyState = enum {
        clean,
        partial,
        full,
    };

    pub const CursorStyle = enum {
        block,
        bar,
        underline,
        block_hollow,
    };

    pub const CursorInfo = struct {
        col: u16 = 0,
        row: u16 = 0,
        visible: bool = true,
        style: CursorStyle = .block,
    };

    pub const CellStyle = struct {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        dim: bool = false,
        inverse: bool = false,
        strikethrough: bool = false,
    };
};

pub const ColorRgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Access the raw ghostty C bindings.
pub const c = gt;

test "terminal create and feed" {
    var term = try Terminal.init(80, 24);
    defer term.deinit();

    // Feed some text
    term.feed("Hello, World!");

    // Check cursor moved
    const cursor = term.getCursor();
    try std.testing.expect(cursor.col > 0);
    try std.testing.expectEqual(@as(u16, 0), cursor.row);

    // Check not on alt screen
    try std.testing.expect(!term.isAltScreen());
}

test "terminal format plain text" {
    var term = try Terminal.init(80, 24);
    defer term.deinit();

    term.feed("Hello from ghostty!");

    const text = try term.formatPlainText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Hello from ghostty!") != null);
}
