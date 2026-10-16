const std = @import("std");
const vt = @import("vt.zig");
const unicode_width = @import("unicode_width.zig");
const Cell = vt.Cell;

// ─── Row ─────────────────────────────────────────────────────────────────────

pub const Row = struct {
    cells: []Cell,
    is_canonical: bool, // true = real newline / first row, false = soft-wrapped continuation

    pub fn init(allocator: std.mem.Allocator, cols: u16, canonical: bool) !Row {
        const cells = try allocator.alloc(Cell, cols);
        @memset(cells, Cell{});
        return Row{
            .cells = cells,
            .is_canonical = canonical,
        };
    }

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        if (self.cells.len > 0) {
            allocator.free(self.cells);
        }
        self.cells = &.{};
    }

    /// Return index of last non-space cell + 1 (content length without trailing spaces).
    pub fn contentLen(self: *const Row) usize {
        var i: usize = self.cells.len;
        while (i > 0) {
            const c = self.cells[i - 1];
            if (c.char != ' ' or
                !c.fg.eql(vt.Color.default) or
                !c.bg.eql(vt.Color.default) or
                @as(u8, @bitCast(c.attr)) != 0)
            {
                break;
            }
            i -= 1;
        }
        return i;
    }
};

// ─── Grid ────────────────────────────────────────────────────────────────────

pub const Grid = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(Row),
    cols: u16,
    viewport_rows: u16,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,

    // Current drawing pen
    pen_fg: vt.Color = .default,
    pen_bg: vt.Color = .default,
    pen_attr: vt.Attr = .{},

    // Scroll region (DECSTBM) — 0-based, inclusive top/bottom
    scroll_top: u16 = 0,
    scroll_bottom: u16 = 0, // 0 means "viewport_rows - 1" (full screen)

    // Alternate screen support
    saved_main_rows: ?[]Row = null,
    saved_cursor_row: u16 = 0,
    saved_cursor_col: u16 = 0,
    in_alt_screen: bool = false,

    /// Upper bound on rows kept above the viewport (0 = unlimited).
    /// Set by the server from config.scrollback_lines; enforced on resize so
    /// repeated pane grow/shrink cycles cannot grow the row buffer endlessly.
    max_scrollback_lines: usize = 0,

    /// Convert viewport-relative row to absolute row index in self.rows
    fn absRow(self: *const Grid, vp_row: u16) usize {
        const total: usize = self.rows.items.len;
        const vp_start = if (total > self.viewport_rows) total - self.viewport_rows else 0;
        return vp_start + vp_row;
    }

    /// Get a mutable reference to a row by viewport-relative index
    fn getRow(self: *Grid, vp_row: u16) ?*Row {
        const idx = self.absRow(vp_row);
        if (idx >= self.rows.items.len) return null;
        return &self.rows.items[idx];
    }

    pub fn init(allocator: std.mem.Allocator, cols: u16, viewport_rows: u16) !Grid {
        var rows: std.ArrayListUnmanaged(Row) = .{ .items = &.{}, .capacity = 0 };
        errdefer {
            for (rows.items) |*r| r.deinit(allocator);
            rows.deinit(allocator);
        }
        // Initialize with viewport_rows canonical rows
        var i: u16 = 0;
        while (i < viewport_rows) : (i += 1) {
            try rows.append(allocator, try Row.init(allocator, cols, true));
        }
        return Grid{
            .allocator = allocator,
            .rows = rows,
            .cols = cols,
            .viewport_rows = viewport_rows,
        };
    }

    pub fn deinit(self: *Grid) void {
        for (self.rows.items) |*r| r.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        if (self.saved_main_rows) |saved| {
            for (saved) |*r| {
                var row = r.*;
                row.deinit(self.allocator);
            }
            self.allocator.free(saved);
        }
    }

    /// Get a cell at a specific viewport position. Returns blank cell if out of bounds.
    /// Get a cell from the visible viewport. Row 0 is the top of the viewport.
    /// scroll_back: number of lines scrolled back from live view (0 = live).
    pub fn getCell(self: *const Grid, row: u16, col: u16) Cell {
        return self.getCellScrolled(row, col, 0);
    }

    pub fn getCellScrolled(self: *const Grid, row: u16, col: u16, scroll_back: u16) Cell {
        const idx = self.absRow(row);
        // Scroll back: move the viewport up by scroll_back lines
        const scrolled_idx = if (idx >= scroll_back) idx - scroll_back else return Cell{};
        if (scrolled_idx >= self.rows.items.len or col >= self.cols) return Cell{};
        const r = self.rows.items[scrolled_idx];
        if (col >= r.cells.len) return Cell{};
        return r.cells[col];
    }

    /// How many lines of scrollback are available above the viewport
    pub fn scrollbackLen(self: *const Grid) usize {
        const total = self.rows.items.len;
        return if (total > self.viewport_rows) total - self.viewport_rows else 0;
    }

    pub fn getCols(self: *const Grid) u16 {
        return self.cols;
    }

    pub fn getRows(self: *const Grid) u16 {
        return self.viewport_rows;
    }

    // ── Character width ───────────────────────────────────────────────────────

    /// Returns the display width of a Unicode codepoint (0, 1, or 2).
    fn charWidth(cp: u21) u16 {
        if (cp == 0) return 1; // NUL from VT (rare); wide spacers use a separate code path
        return @as(u16, unicode_width.terminalDisplayWidth(cp));
    }

    // ── Apply VT Event ───────────────────────────────────────────────────────

    /// Apply a VT event. Returns an optional CPR response to write to the PTY.
    pub fn applyEvent(self: *Grid, ev: vt.Event) ?CprResponse {
        switch (ev) {
            .print => |ch| {
                const w = charWidth(ch);
                if (w == 0) {
                    // Combining marks / ZWJ / VS: terminal consumes without advancing column;
                    // single-codepoint cells cannot represent overlays — skip.
                    return null;
                }

                // Auto-wrap: if cursor + char width exceeds right margin
                if (self.cursor_col + w > self.cols) {
                    self.cursor_col = 0;
                    self.cursor_row +|= 1;
                    if (self.cursor_row >= self.viewport_rows) {
                        self.cursor_row = self.viewport_rows - 1;
                        self.scrollUp(1);
                    }
                    if (self.getRow(self.cursor_row)) |rr| {
                        rr.is_canonical = false;
                    }
                }
                if (self.getRow(self.cursor_row)) |r| {
                    if (self.cursor_col < r.cells.len) {
                        r.cells[self.cursor_col] = .{
                            .char = ch,
                            .fg = self.pen_fg,
                            .bg = self.pen_bg,
                            .attr = self.pen_attr,
                        };
                    }
                    // For wide chars, fill next cell with a spacer (null char)
                    if (w == 2 and self.cursor_col + 1 < r.cells.len) {
                        r.cells[self.cursor_col + 1] = .{
                            .char = 0, // spacer for wide char
                            .fg = self.pen_fg,
                            .bg = self.pen_bg,
                            .attr = self.pen_attr,
                        };
                    }
                }
                self.cursor_col += w;
            },
            .cursor_pos => |cp| {
                self.cursor_row = @min(cp.row, self.viewport_rows -| 1);
                self.cursor_col = @min(cp.col, self.cols -| 1);
            },
            .cursor_move => |cm| {
                const new_row: i32 = @as(i32, self.cursor_row) + cm.row;
                const new_col: i32 = @as(i32, self.cursor_col) + cm.col;
                self.cursor_row = @intCast(@max(0, @min(new_row, @as(i32, self.viewport_rows) - 1)));
                self.cursor_col = @intCast(@max(0, @min(new_col, @as(i32, self.cols) - 1)));
            },
            .cursor_line_move => |delta| {
                // CNL/CPL: move N lines + set col=0
                const new_row: i32 = @as(i32, self.cursor_row) + delta;
                self.cursor_row = @intCast(@max(0, @min(new_row, @as(i32, self.viewport_rows) - 1)));
                self.cursor_col = 0;
            },
            .linefeed => {
                const bottom = self.effectiveScrollBottom();
                if (self.cursor_row == bottom) {
                    // At the bottom of scroll region — scroll region up
                    if (self.hasScrollRegion()) {
                        self.scrollRegionUp(self.effectiveScrollTop(), bottom, 1);
                    } else {
                        self.scrollUp(1);
                    }
                } else if (self.cursor_row < self.viewport_rows - 1) {
                    self.cursor_row += 1;
                }
                // The row we landed on after a linefeed is canonical
                if (self.getRow(self.cursor_row)) |rr| {
                    rr.is_canonical = true;
                }
            },
            .carriage_return => {
                self.cursor_col = 0;
            },
            .backspace => {
                if (self.cursor_col > 0) self.cursor_col -= 1;
            },
            .erase_display => |mode| {
                switch (mode) {
                    0 => {
                        // Erase from cursor to end of viewport
                        if (self.getRow(self.cursor_row)) |r| {
                            if (self.cursor_col < r.cells.len) {
                                @memset(r.cells[self.cursor_col..], Cell{});
                            }
                        }
                        var vp_i: u16 = self.cursor_row + 1;
                        while (vp_i < self.viewport_rows) : (vp_i += 1) {
                            if (self.getRow(vp_i)) |r| {
                                @memset(r.cells, Cell{});
                            }
                        }
                    },
                    1 => {
                        // Erase from top of viewport to cursor
                        var vp_i: u16 = 0;
                        while (vp_i < self.cursor_row) : (vp_i += 1) {
                            if (self.getRow(vp_i)) |r| {
                                @memset(r.cells, Cell{});
                            }
                        }
                        if (self.getRow(self.cursor_row)) |r| {
                            const end = @min(@as(usize, self.cursor_col) + 1, r.cells.len);
                            @memset(r.cells[0..end], Cell{});
                        }
                    },
                    2 => {
                        if (self.in_alt_screen) {
                            // Alt screen: clear all rows in place
                            for (self.rows.items) |*r| {
                                @memset(r.cells, Cell{});
                            }
                        } else {
                            // Main screen: push only content rows to scrollback,
                            // then clear the viewport in place.
                            // This avoids blank scrollback rows that cause gaps after reflow.
                            const total = self.rows.items.len;
                            const vp_start = if (total > self.viewport_rows) total - self.viewport_rows else 0;
                            // Find last content row in viewport
                            var last_content: usize = total;
                            while (last_content > vp_start) {
                                if (self.rows.items[last_content - 1].contentLen() > 0) break;
                                last_content -= 1;
                            }
                            if (last_content > vp_start) {
                                // There are content rows in the viewport — push them to scrollback
                                // by appending new blank rows (only as many as the content rows)
                                const content_count = last_content - vp_start;
                                var i: usize = 0;
                                while (i < content_count) : (i += 1) {
                                    var new_row = Row.init(self.allocator, self.cols, true) catch break;
                                    self.rows.append(self.allocator, new_row) catch {
                                        new_row.deinit(self.allocator);
                                        break;
                                    };
                                }
                            }
                            // Clear all viewport rows
                            const new_total = self.rows.items.len;
                            const new_vp_start = if (new_total > self.viewport_rows) new_total - self.viewport_rows else 0;
                            for (self.rows.items[new_vp_start..]) |*r| {
                                @memset(r.cells, Cell{});
                                r.is_canonical = true;
                            }
                            self.cursor_row = 0;
                        }
                    },
                    else => {},
                }
            },
            .erase_line => |mode| {
                const r = self.getRow(self.cursor_row) orelse return null;
                switch (mode) {
                    0 => {
                        if (self.cursor_col < r.cells.len) {
                            @memset(r.cells[self.cursor_col..], Cell{});
                        }
                    },
                    1 => {
                        const end = @min(@as(usize, self.cursor_col) + 1, r.cells.len);
                        @memset(r.cells[0..end], Cell{});
                    },
                    2 => {
                        @memset(r.cells, Cell{});
                    },
                    else => {},
                }
            },
            .scroll_up => |n| {
                if (self.hasScrollRegion()) {
                    self.scrollRegionUp(self.effectiveScrollTop(), self.effectiveScrollBottom(), n);
                } else {
                    self.scrollUp(n);
                }
            },
            .scroll_down => |n| {
                if (self.hasScrollRegion()) {
                    self.scrollRegionDown(self.effectiveScrollTop(), self.effectiveScrollBottom(), n);
                } else {
                    self.scrollDown(n);
                }
            },
            .insert_lines => |n| {
                // insert_lines operates within the scroll region (or viewport)
                const bottom = self.effectiveScrollBottom();
                if (self.cursor_row > bottom) return null;
                const count = @min(n, bottom - self.cursor_row + 1);
                if (count == 0) return null;
                self.scrollRegionDown(self.cursor_row, bottom, count);
            },
            .delete_lines => |n| {
                // delete_lines operates within the scroll region (or viewport)
                const bottom = self.effectiveScrollBottom();
                if (self.cursor_row > bottom) return null;
                const count = @min(n, bottom - self.cursor_row + 1);
                if (count == 0) return null;
                self.scrollRegionUp(self.cursor_row, bottom, count);
            },
            .sgr => |params| {
                if (params.reset) {
                    self.pen_fg = .default;
                    self.pen_bg = .default;
                    self.pen_attr = .{};
                }
                if (params.fg) |fg| self.pen_fg = fg;
                if (params.bg) |bg| self.pen_bg = bg;
                if (params.attr) |attr| {
                    if (attr.bold) self.pen_attr.bold = true;
                    if (attr.dim) self.pen_attr.dim = true;
                    if (attr.italic) self.pen_attr.italic = true;
                    if (attr.underline) self.pen_attr.underline = true;
                    if (attr.blink) self.pen_attr.blink = true;
                    if (attr.inverse) self.pen_attr.inverse = true;
                    if (attr.hidden) self.pen_attr.hidden = true;
                    if (attr.strikethrough) self.pen_attr.strikethrough = true;
                }
                if (params.clear_attr) |clear| {
                    if (clear.bold) self.pen_attr.bold = false;
                    if (clear.dim) self.pen_attr.dim = false;
                    if (clear.italic) self.pen_attr.italic = false;
                    if (clear.underline) self.pen_attr.underline = false;
                    if (clear.blink) self.pen_attr.blink = false;
                    if (clear.inverse) self.pen_attr.inverse = false;
                    if (clear.hidden) self.pen_attr.hidden = false;
                    if (clear.strikethrough) self.pen_attr.strikethrough = false;
                }
            },
            .alt_screen => |enter| {
                if (enter and !self.in_alt_screen) {
                    self.saved_cursor_row = self.cursor_row;
                    self.saved_cursor_col = self.cursor_col;
                    const saved = self.allocator.alloc(Row, self.rows.items.len) catch return null;
                    for (self.rows.items, 0..) |r, i| {
                        const new_cells = self.allocator.alloc(Cell, r.cells.len) catch {
                            var j: usize = 0;
                            while (j < i) : (j += 1) {
                                self.allocator.free(saved[j].cells);
                            }
                            self.allocator.free(saved);
                            return null;
                        };
                        @memcpy(new_cells, r.cells);
                        saved[i] = Row{ .cells = new_cells, .is_canonical = r.is_canonical };
                    }
                    if (self.saved_main_rows) |old_saved| {
                        for (old_saved) |*r| {
                            var row = r.*;
                            row.deinit(self.allocator);
                        }
                        self.allocator.free(old_saved);
                    }
                    self.saved_main_rows = saved;
                    for (self.rows.items) |*r| {
                        @memset(r.cells, Cell{});
                        r.is_canonical = true;
                    }
                    self.cursor_row = 0;
                    self.cursor_col = 0;
                    self.in_alt_screen = true;
                } else if (!enter and self.in_alt_screen) {
                    if (self.saved_main_rows) |saved| {
                        for (self.rows.items) |*r| r.deinit(self.allocator);
                        self.rows.clearRetainingCapacity();
                        var restore_failed = false;
                        for (saved, 0..) |r, idx| {
                            self.rows.append(self.allocator, r) catch {
                                // OOM: deinit this row and all remaining saved rows
                                var rr = r;
                                rr.deinit(self.allocator);
                                var j = idx + 1;
                                while (j < saved.len) : (j += 1) {
                                    var rem = saved[j];
                                    rem.deinit(self.allocator);
                                }
                                restore_failed = true;
                                break;
                            };
                        }
                        self.allocator.free(saved);
                        self.saved_main_rows = null;
                        if (restore_failed) {
                            // Ensure at least one row exists
                            if (self.rows.items.len == 0) {
                                const blank = Row.init(self.allocator, self.cols, true) catch return null;
                                self.rows.append(self.allocator, blank) catch return null;
                            }
                        }
                    }
                    self.cursor_row = self.saved_cursor_row;
                    self.cursor_col = self.saved_cursor_col;
                    self.in_alt_screen = false;
                    self.pen_fg = .default;
                    self.pen_bg = .default;
                    self.pen_attr = .{};
                }
            },
            .cursor_position_report => {
                return CprResponse{
                    .row = self.cursor_row + 1,
                    .col = self.cursor_col + 1,
                };
            },
            .scroll_region => |sr| {
                self.scroll_top = sr.top;
                self.scroll_bottom = sr.bottom;
                // DECSTBM resets cursor to home position
                self.cursor_row = 0;
                self.cursor_col = 0;
            },
            .set_title => return null, // handled externally
            else => {},
        }
        return null;
    }

    // ── Scroll region helpers ────────────────────────────────────────────────

    fn effectiveScrollTop(self: *const Grid) u16 {
        return self.scroll_top;
    }

    fn effectiveScrollBottom(self: *const Grid) u16 {
        return if (self.scroll_bottom == 0) self.viewport_rows -| 1 else self.scroll_bottom;
    }

    fn hasScrollRegion(self: *const Grid) bool {
        return self.scroll_top != 0 or (self.scroll_bottom != 0 and self.scroll_bottom != self.viewport_rows -| 1);
    }

    /// Scroll a region of the viewport up by n lines (content moves up, blank at bottom).
    fn scrollRegionUp(self: *Grid, top: u16, bottom: u16, n: u16) void {
        const region_height = bottom - top + 1;
        const count = @min(n, region_height);
        if (count == 0) return;

        // Shift rows up within the region
        var r: u16 = top;
        while (r + count <= bottom) : (r += 1) {
            const src_abs = self.absRow(r + count);
            const dst_abs = self.absRow(r);
            if (src_abs < self.rows.items.len and dst_abs < self.rows.items.len) {
                const tmp = self.rows.items[dst_abs].cells;
                self.rows.items[dst_abs].cells = self.rows.items[src_abs].cells;
                self.rows.items[src_abs].cells = tmp;
                self.rows.items[dst_abs].is_canonical = self.rows.items[src_abs].is_canonical;
            }
        }
        // Blank the bottom rows of the region
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const vp_idx = bottom - count + 1 + i;
            if (self.getRow(vp_idx)) |row| {
                @memset(row.cells, Cell{});
                row.is_canonical = true;
            }
        }
    }

    /// Scroll a region of the viewport down by n lines (content moves down, blank at top).
    fn scrollRegionDown(self: *Grid, top: u16, bottom: u16, n: u16) void {
        const region_height = bottom - top + 1;
        const count = @min(n, region_height);
        if (count == 0) return;

        // Shift rows down within the region
        var r: u16 = bottom;
        while (r >= top + count) : (r -= 1) {
            const src_abs = self.absRow(r - count);
            const dst_abs = self.absRow(r);
            if (src_abs < self.rows.items.len and dst_abs < self.rows.items.len) {
                const tmp = self.rows.items[dst_abs].cells;
                self.rows.items[dst_abs].cells = self.rows.items[src_abs].cells;
                self.rows.items[src_abs].cells = tmp;
                self.rows.items[dst_abs].is_canonical = self.rows.items[src_abs].is_canonical;
            }
            if (r == top + count) break; // prevent underflow
        }
        // Blank the top rows of the region
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            if (self.getRow(top + i)) |row| {
                @memset(row.cells, Cell{});
                row.is_canonical = true;
            }
        }
    }

    // ── Scroll helpers ───────────────────────────────────────────────────────

    fn scrollUp(self: *Grid, n: u16) void {
        const total = self.rows.items.len;
        // vp_start is the absolute index of the first viewport row
        const vp_start: usize = if (total > self.viewport_rows) total - self.viewport_rows else 0;
        const vp_len: usize = total - vp_start; // should equal viewport_rows when total >= viewport_rows
        const count: usize = @min(@as(usize, n), vp_len);
        if (count == 0) return;

        if (self.in_alt_screen) {
            // Alt screen: discard the top viewport rows (shift them out of the array)
            var i: usize = vp_start;
            while (i < vp_start + count) : (i += 1) {
                self.rows.items[i].deinit(self.allocator);
            }
            const remaining = total - vp_start - count;
            if (remaining > 0) {
                std.mem.copyForwards(Row, self.rows.items[vp_start .. vp_start + remaining], self.rows.items[vp_start + count .. total]);
            }
            var j: usize = 0;
            while (j < count) : (j += 1) {
                const idx = vp_start + remaining + j;
                self.rows.items[idx] = Row.init(self.allocator, self.cols, true) catch {
                    self.rows.items.len = vp_start + remaining + j;
                    return;
                };
            }
        } else {
            // Main screen: append new blank rows (old rows become scrollback above viewport)
            var i: usize = 0;
            while (i < count) : (i += 1) {
                var new_row = Row.init(self.allocator, self.cols, true) catch return;
                self.rows.append(self.allocator, new_row) catch {
                    new_row.deinit(self.allocator);
                    return;
                };
            }
        }
    }

    fn scrollDown(self: *Grid, n: u16) void {
        const total = self.rows.items.len;
        const vp_start: usize = if (total > self.viewport_rows) total - self.viewport_rows else 0;
        const vp_len: usize = total - vp_start;
        const count: usize = @min(@as(usize, n), vp_len);
        if (count == 0) return;

        // scrollDown moves content down within the viewport; top rows get blanked.
        // Shift rows within the viewport downward (bottom rows are discarded, top rows are blanked).
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // Deinit the bottom viewport row that will be pushed off
            self.rows.items[vp_start + vp_len - 1 - i].deinit(self.allocator);
        }
        // Shift remaining viewport rows down by count
        const remaining = vp_len - count;
        if (remaining > 0) {
            var j: isize = @as(isize, @intCast(remaining)) - 1;
            while (j >= 0) : (j -= 1) {
                const src: usize = vp_start + @as(usize, @intCast(j));
                const dst: usize = vp_start + @as(usize, @intCast(j)) + count;
                self.rows.items[dst] = self.rows.items[src];
            }
        }
        // Blank the top viewport rows
        i = 0;
        while (i < count) : (i += 1) {
            self.rows.items[vp_start + i] = Row.init(self.allocator, self.cols, true) catch {
                // OOM: leave remaining rows with swapped (non-empty) content
                return;
            };
        }
    }

    /// Keep the number of rows held above the viewport within
    /// `max_scrollback_lines` (0 = unlimited).  Only rows above the viewport
    /// are dropped, so visible content and the cursor never move.
    fn trimScrollback(self: *Grid) void {
        if (self.max_scrollback_lines == 0) return;
        const total = self.rows.items.len;
        const vp = @as(usize, self.viewport_rows);
        const keep = vp + self.max_scrollback_lines;
        if (total <= keep) return;
        const drop = total - keep;
        var i: usize = 0;
        while (i < drop) : (i += 1) {
            self.rows.items[i].deinit(self.allocator);
        }
        std.mem.copyForwards(Row, self.rows.items[0 .. keep], self.rows.items[drop .. total]);
        self.rows.items.len = keep;
    }

    // ── Resize with Reflow ───────────────────────────────────────────────────

    pub fn resize(self: *Grid, new_cols: u16, new_rows: u16) !void {
        if (self.cols == new_cols and self.viewport_rows == new_rows and self.rows.items.len == new_rows) return;

        // Reset scroll region on resize (standard terminal behavior)
        self.scroll_top = 0;
        self.scroll_bottom = 0;

        if (self.in_alt_screen) {
            try self.resizeSimple(new_cols, new_rows);
            return;
        }

        if (self.cols != new_cols) {
            // Preserve scrollback across width changes — reflow handles
            // re-wrapping all rows (scrollback + viewport) correctly.
            try self.reflow(new_cols, new_rows);
        } else {
            try self.resizeHeight(new_rows);
        }
        // Both paths may have appended blank rows below the viewport; keep the
        // scrollback buffer bounded (rows dropped are always above the viewport,
        // so visible content and the cursor stay put).
        self.trimScrollback();
    }

    fn reflow(self: *Grid, new_cols: u16, new_rows: u16) !void {
        const alloc = self.allocator;
        const old_vp_rows = self.viewport_rows;
        // How many rows sit hidden above the viewport before the resize.
        // Preserving it across a reflow is what keeps the viewport anchored:
        // history is never pulled back in, blank rows are created below the
        // cursor instead (the reverted-resize bug).
        const old_vp_start: usize =
            if (self.rows.items.len > self.viewport_rows) self.rows.items.len - self.viewport_rows else 0;

        // Phase 1: Compute cursor's linear position
        // cursor_row is viewport-relative; convert to absolute index
        const cursor_abs = self.absRow(self.cursor_row);
        var cursor_linear: usize = 0;
        {
            var canonical_idx: usize = 0;
            var char_in_canonical: usize = 0;

            for (self.rows.items, 0..) |r, row_idx| {
                if (r.is_canonical and row_idx > 0) {
                    canonical_idx += 1;
                    char_in_canonical = 0;
                }
                if (row_idx == cursor_abs) {
                    cursor_linear = canonical_idx * 1_000_000 + char_in_canonical + self.cursor_col;
                    break;
                }
                char_in_canonical += r.cells.len;
            }
        }

        // Phase 2: Merge wrapped rows back into canonical lines
        // Use a simple dynamic array of dynamic arrays
        var canonical_count: usize = 0;
        // First pass: count canonical lines
        for (self.rows.items, 0..) |r, idx| {
            if (r.is_canonical or idx == 0) canonical_count += 1;
        }

        // Collect canonical lines as slices of cells
        var line_cells_list: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Cell)) = .{ .items = &.{}, .capacity = 0 };
        defer {
            for (line_cells_list.items) |*cl| cl.deinit(alloc);
            line_cells_list.deinit(alloc);
        }

        for (self.rows.items, 0..) |r, idx| {
            if (r.is_canonical or idx == 0 or line_cells_list.items.len == 0) {
                var new_line: std.ArrayListUnmanaged(Cell) = .{ .items = &.{}, .capacity = 0 };
                const content_len = r.contentLen();
                try new_line.appendSlice(alloc, r.cells[0..content_len]);
                try line_cells_list.append(alloc, new_line);
            } else {
                var last = &line_cells_list.items[line_cells_list.items.len - 1];
                const content_len = r.contentLen();
                if (content_len > 0) {
                    try last.appendSlice(alloc, r.cells[0..content_len]);
                }
            }
        }

        // Phase 3: Free old rows
        for (self.rows.items) |*r| r.deinit(alloc);
        self.rows.clearRetainingCapacity();

        // Phase 4: Re-split each canonical line to new width
        var new_cursor_row: u16 = 0;
        var new_cursor_col: u16 = 0;
        var current_canonical: usize = 0;

        for (line_cells_list.items) |cl| {
            const line_cells = cl.items;

            if (line_cells.len == 0) {
                try self.rows.append(alloc, try Row.init(alloc, new_cols, true));
                const cursor_canonical_idx = cursor_linear / 1_000_000;
                if (cursor_canonical_idx == current_canonical) {
                    new_cursor_row = @intCast(self.rows.items.len - 1);
                    new_cursor_col = 0;
                }
            } else {
                var offset: usize = 0;
                var first_chunk = true;
                while (offset < line_cells.len) {
                    const chunk_end = @min(offset + new_cols, line_cells.len);
                    const chunk = line_cells[offset..chunk_end];

                    var new_row = try Row.init(alloc, new_cols, first_chunk);
                    @memcpy(new_row.cells[0..chunk.len], chunk);

                    try self.rows.append(alloc, new_row);

                    const cursor_in_canonical = cursor_linear % 1_000_000;
                    const cursor_canonical_idx = cursor_linear / 1_000_000;
                    if (cursor_canonical_idx == current_canonical and
                        cursor_in_canonical >= offset and
                        (cursor_in_canonical <= chunk_end or
                            // Cursor can be past trimmed content (contentLen trims trailing spaces)
                            chunk_end == line_cells.len))
                    {
                        // Cursor at chunk_end means it's at the right edge;
                        // if it's exactly at the boundary and there's more content,
                        // let the next chunk claim it instead.
                        if (cursor_in_canonical < chunk_end or offset + new_cols >= line_cells.len) {
                            new_cursor_row = @intCast(self.rows.items.len - 1);
                            new_cursor_col = @intCast(cursor_in_canonical - offset);
                        }
                    }

                    offset = chunk_end;
                    first_chunk = false;
                }
            }
            current_canonical += 1;
        }

        // Phase 5: Adjust to the viewport height, keeping the viewport anchored.
        // vp_start (rows hidden above the viewport) is preserved on width
        // changes and on vertical expansion; blank rows are appended below the
        // cursor.  Only when the viewport itself shrinks do we let vp_start grow
        // (content scrolls up, mirroring resizeHeight).
        const cursor_abs_new: usize = @intCast(new_cursor_row);
        var vp_start: usize = old_vp_start;
        if (new_rows < old_vp_rows) {
            vp_start = if (self.rows.items.len > new_rows) self.rows.items.len - new_rows else 0;
        } else if (cursor_abs_new < vp_start) {
            // Re-wrapping collapsed rows above the cursor; slide the window up
            // just enough to keep the cursor visible.
            vp_start = cursor_abs_new;
        } else if (cursor_abs_new >= vp_start + new_rows) {
            // Re-wrapping pushed rows above the cursor past the viewport bottom.
            vp_start = cursor_abs_new + 1 - new_rows;
        }

        // Drop blank trailing rows that no longer fit (never at or above the
        // cursor, so live content is preserved).
        while (self.rows.items.len > vp_start + new_rows) {
            const last = &self.rows.items[self.rows.items.len - 1];
            if (last.contentLen() == 0 and self.rows.items.len - 1 > new_cursor_row) {
                var removed = self.rows.pop().?;
                removed.deinit(alloc);
            } else {
                break;
            }
        }

        // Pad below the cursor so the viewport is completely filled.
        while (self.rows.items.len < vp_start + new_rows) {
            try self.rows.append(alloc, try Row.init(alloc, new_cols, true));
        }

        // NOTE: an earlier version (commit 0245b9e) post-processed the reflowed
        // rows here to delete any "blank rows between content rows" inside the
        // viewport, to patch over gaps left by `clear` (ED2) followed by a
        // pane split. That heuristic cannot distinguish clear-artifacts from
        // legitimate empty output lines (e.g. `printf '\n'` between sections),
        // so it silently erased real output whenever the pane got reflowed
        // (every pane split / focus switch that triggers resize). The root
        // cause of the original gap is now handled at clear time in
        // `eraseDisplay` (d1b5b4b: only push content rows to scrollback) and
        // by scrollback trimming before reflow (fd9a80e), so no post-reflow
        // blank removal is needed and doing it corrupts user-visible output.

        self.cols = new_cols;
        self.viewport_rows = new_rows;

        // Convert new_cursor_row (absolute) to viewport-relative
        if (self.rows.items.len > new_rows) {
            const viewport_start: u16 = @intCast(self.rows.items.len - new_rows);
            if (new_cursor_row >= viewport_start) {
                self.cursor_row = new_cursor_row - viewport_start;
            } else {
                // Cursor is in scrollback; clamp to top of viewport
                self.cursor_row = 0;
            }
        } else {
            self.cursor_row = @min(new_cursor_row, @as(u16, @intCast(self.rows.items.len)) -| 1);
        }
        self.cursor_col = @min(new_cursor_col, new_cols -| 1);
    }

    fn resizeHeight(self: *Grid, new_rows: u16) !void {
        const alloc = self.allocator;

        if (new_rows > self.viewport_rows) {
            // Expansion: the viewport must stay anchored where it is.  Blank
            // rows are appended *after* the viewport (i.e. below the cursor)
            // so vp_start — and with it every visible row and the cursor's
            // viewport-relative row — is unchanged.  Simply letting vp_start
            // move up would pull the missing rows back from history, which is
            // what made a reverted resize show scrollback instead of blanks.
            const grow: usize = @intCast(new_rows - self.viewport_rows);
            var grown: usize = 0;
            while (grown < grow) {
                var blank = Row.init(alloc, self.cols, true) catch break;
                self.rows.append(alloc, blank) catch {
                    blank.deinit(alloc);
                    break;
                };
                grown += 1;
            }
            self.viewport_rows = new_rows;
            // OOM mid-expansion: never let viewport_rows exceed the rows we
            // actually hold, otherwise vp_start would point past the buffer.
            if (self.rows.items.len < self.viewport_rows) {
                self.viewport_rows =
                    @intCast(@min(self.rows.items.len, std.math.maxInt(u16)));
            }
            return;
        }

        // Safety pad: the buffer must be able to fill the viewport
        while (self.rows.items.len < new_rows) {
            try self.rows.append(alloc, try Row.init(alloc, self.cols, true));
        }

        // Shrink (or same height): rows are kept — the excess above the
        // viewport become scrollback (content scrolls up, nothing is lost).
        const old_abs = self.absRow(self.cursor_row);
        self.viewport_rows = new_rows;
        const total = self.rows.items.len;
        const new_vp_start: usize = if (total > new_rows) total - new_rows else 0;
        if (old_abs >= new_vp_start) {
            self.cursor_row = @intCast(old_abs - new_vp_start);
        } else {
            // Cursor scrolled into scrollback; clamp to top of viewport
            self.cursor_row = 0;
        }
    }

    fn resizeSimple(self: *Grid, new_cols: u16, new_rows: u16) !void {
        const alloc = self.allocator;
        var new_row_list: std.ArrayListUnmanaged(Row) = .{ .items = &.{}, .capacity = 0 };
        errdefer {
            for (new_row_list.items) |*r| r.deinit(alloc);
            new_row_list.deinit(alloc);
        }

        const copy_rows = @min(self.rows.items.len, @as(usize, new_rows));
        const copy_cols = @min(self.cols, new_cols);

        var i: usize = 0;
        while (i < copy_rows) : (i += 1) {
            var new_row = try Row.init(alloc, new_cols, self.rows.items[i].is_canonical);
            @memcpy(new_row.cells[0..copy_cols], self.rows.items[i].cells[0..copy_cols]);
            try new_row_list.append(alloc, new_row);
        }
        while (new_row_list.items.len < new_rows) {
            try new_row_list.append(alloc, try Row.init(alloc, new_cols, true));
        }

        for (self.rows.items) |*r| r.deinit(alloc);
        self.rows.deinit(alloc);
        self.rows = new_row_list;
        self.cols = new_cols;
        self.viewport_rows = new_rows;
        self.cursor_row = @min(self.cursor_row, new_rows -| 1);
        self.cursor_col = @min(self.cursor_col, new_cols -| 1);
    }
};

/// CPR response data -- caller formats and writes to PTY.
pub const CprResponse = struct {
    row: u16,
    col: u16,
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "reflow wraps long line to narrower width" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 3);
    defer grid.deinit();

    const text = "ABCDEFGHIJ";
    for (text) |ch| {
        _ = grid.applyEvent(.{ .print = ch });
    }

    try grid.resize(5, 3);

    try std.testing.expectEqual(@as(u16, 5), grid.cols);
    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expectEqual(@as(u21, 'A'), grid.rows.items[0].cells[0].char);
    try std.testing.expectEqual(@as(u21, 'E'), grid.rows.items[0].cells[4].char);
    try std.testing.expect(!grid.rows.items[1].is_canonical);
    try std.testing.expectEqual(@as(u21, 'F'), grid.rows.items[1].cells[0].char);
    try std.testing.expectEqual(@as(u21, 'J'), grid.rows.items[1].cells[4].char);
}

test "reflow unwraps when width increases" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 4);
    defer grid.deinit();

    for ("ABCDE") |ch| _ = grid.applyEvent(.{ .print = ch });
    for ("FGH") |ch| _ = grid.applyEvent(.{ .print = ch });

    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expect(!grid.rows.items[1].is_canonical);

    try grid.resize(10, 4);

    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expectEqual(@as(u21, 'A'), grid.rows.items[0].cells[0].char);
    try std.testing.expectEqual(@as(u21, 'H'), grid.rows.items[0].cells[7].char);
    try std.testing.expectEqual(@as(u21, ' '), grid.rows.items[0].cells[8].char);
}

test "canonical line boundary preserved" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 5);
    defer grid.deinit();

    for ("Hello") |ch| _ = grid.applyEvent(.{ .print = ch });
    _ = grid.applyEvent(.linefeed);
    _ = grid.applyEvent(.carriage_return);
    for ("World") |ch| _ = grid.applyEvent(.{ .print = ch });

    try grid.resize(5, 5);

    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expectEqual(@as(u21, 'H'), grid.rows.items[0].cells[0].char);
    try std.testing.expect(grid.rows.items[1].is_canonical);
    try std.testing.expectEqual(@as(u21, 'W'), grid.rows.items[1].cells[0].char);
}

test "cursor position correct after reflow" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 3);
    defer grid.deinit();

    for ("ABCDEFGH") |ch| _ = grid.applyEvent(.{ .print = ch });
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);

    try grid.resize(5, 3);

    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), grid.cursor_col);
}

test "print with auto-wrap creates non-canonical row" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 3);
    defer grid.deinit();

    for ("ABCDEF") |ch| _ = grid.applyEvent(.{ .print = ch });

    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expect(!grid.rows.items[1].is_canonical);
    try std.testing.expectEqual(@as(u21, 'F'), grid.rows.items[1].cells[0].char);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
}

test "getCell returns blank for out of bounds" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 3);
    defer grid.deinit();

    const cell = grid.getCell(100, 100);
    try std.testing.expectEqual(@as(u21, ' '), cell.char);
}

test "resize height only adds rows" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 3);
    defer grid.deinit();

    for ("ABC") |ch| _ = grid.applyEvent(.{ .print = ch });

    try grid.resize(10, 5);
    try std.testing.expectEqual(@as(usize, 5), grid.rows.items.len);
    try std.testing.expectEqual(@as(u21, 'A'), grid.rows.items[0].cells[0].char);
}

test "resize height preserves rows as scrollback" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 5);
    defer grid.deinit();

    try grid.resize(10, 3);
    // Total rows unchanged — the 2 excess rows become scrollback
    try std.testing.expectEqual(@as(usize, 5), grid.rows.items.len);
    try std.testing.expectEqual(@as(u16, 3), grid.viewport_rows);
    // Scrollback: rows.len - viewport_rows = 2
    try std.testing.expectEqual(@as(usize, 2), grid.scrollbackLen());
}

test "reflow preserves content through narrow-wide cycle" {
    const alloc = std.testing.allocator;
    var grid = try Grid.init(alloc, 20, 5);
    defer grid.deinit();

    // Write "hello world" on row 0
    const text = "hello world";
    for (text) |ch| {
        _ = grid.applyEvent(.{ .print = ch });
    }

    // Verify initial state
    try std.testing.expectEqual(@as(u21, 'h'), grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'd'), grid.getCell(0, 10).char);

    // Resize to narrow (10 cols) — "hello worl" + "d"
    try grid.resize(10, 5);
    try std.testing.expectEqual(@as(u21, 'h'), grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'l'), grid.getCell(0, 9).char);

    // Resize back to wide (20 cols) — should restore "hello world"
    try grid.resize(20, 5);
    try std.testing.expectEqual(@as(u21, 'h'), grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'd'), grid.getCell(0, 10).char);
    // After 'd', rest should be spaces
    try std.testing.expectEqual(@as(u21, ' '), grid.getCell(0, 11).char);
}
