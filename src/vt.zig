const std = @import("std");

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

pub const Color = union(enum) {
    default,
    idx: u8,
    rgb: struct { r: u8, g: u8, b: u8 },

    pub inline fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .idx => |i| switch (b) {
                .idx => |j| i == j,
                else => false,
            },
            .rgb => |c| switch (b) {
                .rgb => |d| c.r == d.r and c.g == d.g and c.b == d.b,
                else => false,
            },
        };
    }
};

pub const Attr = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attr: Attr = .{},
};

pub const SgrParams = struct {
    reset: bool = false,
    attr: ?Attr = null,
    clear_attr: ?Attr = null, // bits set here indicate attributes to CLEAR in the pen
    fg: ?Color = null,
    bg: ?Color = null,
};

pub const TitleData = struct {
    buf: [255]u8,
    len: u8,
};

pub const Event = union(enum) {
    print: u21,
    cursor_move: struct { row: i16, col: i16 },
    cursor_line_move: i16, // CNL/CPL: move N lines + set col=0
    cursor_pos: struct { row: u16, col: u16 },
    erase_display: u8,
    erase_line: u8,
    sgr: SgrParams,
    scroll_region: struct { top: u16, bottom: u16 },
    scroll_up: u16,
    scroll_down: u16,
    insert_lines: u16,
    delete_lines: u16,
    cursor_position_report, // DSR: app requests cursor position (CSI 6n)
    device_attributes_request, // DA1: app requests terminal identity (CSI c / CSI 0c)
    linefeed,
    next_line, // ESC E: linefeed + carriage return
    carriage_return,
    backspace,
    tab,
    bell,
    set_title: TitleData,
    alt_screen: bool,
    cursor_visible: bool,

    // ── Cursor save / absolute positioning ─────────────────────────────────
    cursor_save, // ESC[s (ANSI.SYS SCP)
    cursor_restore, // ESC[u (ANSI.SYS RCP)
    cursor_col_abs: u16, // CSI Ps `  / CSI Ps G  (HPA)
    cursor_row_abs: u16, // CSI Ps d  (VPA)

    // ── Mode changes ───────────────────────────────────────────────────────
    set_autowrap: bool, // CSI ?7h / CSI ?7l  (DECAWM)
    set_origin: bool, // CSI ?36h / CSI ?36l (DECOM)

    // ── Terminal queries (the app waits for a reply) ───────────────────────
    notification_request, // CSI 5 n  (DSR notification)
    device_secondary_attributes, // CSI > c (DA2)
    request_mode_test: u16, // CSI ? Ps $ p  (mode test)
    request_keyboard_flags, // CSI ? u (KBD flags query)
    request_window_op: u8, // CSI Ps t (window/cursor geometry)
    query_palette_color: u8, // OSC 10;? / 11;? / 12;? (palette query)
};

// ─────────────────────────────────────────────────────────────
// Parser
// ─────────────────────────────────────────────────────────────

const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    osc_string,
    dcs_passthrough, // Consume DCS sequences until ST
};

const MAX_PARAMS = 16;
const OSC_BUF_LEN = 256;

pub const Parser = struct {
    state: State = .ground,

    // CSI parameter accumulator
    params: [MAX_PARAMS]u16 = [_]u16{0} ** MAX_PARAMS,
    param_idx: usize = 0,
    has_params: u16 = 0, // bitmask: bit N set if param N had at least one digit
    private: bool = false, // '?' or '>' prefix seen
    priv_marker: u8 = 0, // which private marker was seen ('?' or '>')
    csi_inter: u8 = 0, // first intermediate byte of the CSI (0 = none)

    // OSC accumulator
    osc_buf: [OSC_BUF_LEN]u8 = undefined,
    osc_len: usize = 0,

    // UTF-8 multibyte accumulator
    utf8_buf: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_expected: u3 = 0,

    pub fn init() Parser {
        return .{};
    }

    fn resetCsi(self: *Parser) void {
        self.params = [_]u16{0} ** MAX_PARAMS;
        self.param_idx = 0;
        self.has_params = 0;
        self.private = false;
        self.priv_marker = 0;
        self.csi_inter = 0;
    }

    fn getParam(self: *const Parser, idx: usize, default: u16) u16 {
        if (idx > self.param_idx) return default;
        const v = self.params[idx];
        const has_digit = (self.has_params & (@as(u16, 1) << @intCast(idx))) != 0;
        return if (v == 0 and !has_digit) default else v;
    }

    // Returns the actual stored param value (0 means not set / literal 0).
    fn rawParam(self: *const Parser, idx: usize) u16 {
        if (idx > self.param_idx) return 0;
        return self.params[idx];
    }

    pub fn feed(self: *Parser, byte: u8) ?Event {
        switch (self.state) {
            // ── Ground ───────────────────────────────────────
            .ground => {
                switch (byte) {
                    0x1b => {
                        // ESC interrupts any in-progress UTF-8 sequence
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        self.state = .escape;
                        return null;
                    },
                    '\n' => {
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        return .linefeed;
                    },
                    '\r' => {
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        return .carriage_return;
                    },
                    0x08 => {
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        return .backspace;
                    },
                    '\t' => {
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        return .tab;
                    },
                    0x07 => {
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        return .bell;
                    },
                    0x20...0x7e => {
                        // Printable ASCII interrupts any in-progress UTF-8 sequence
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        return .{ .print = byte };
                    },
                    // UTF-8 multibyte start bytes — reset and start fresh
                    0xc0...0xdf => {
                        self.utf8_buf[0] = byte;
                        self.utf8_len = 1;
                        self.utf8_expected = 2;
                        return null;
                    },
                    0xe0...0xef => {
                        self.utf8_buf[0] = byte;
                        self.utf8_len = 1;
                        self.utf8_expected = 3;
                        return null;
                    },
                    0xf0...0xf7 => {
                        self.utf8_buf[0] = byte;
                        self.utf8_len = 1;
                        self.utf8_expected = 4;
                        return null;
                    },
                    // UTF-8 continuation bytes (when accumulating)
                    0x80...0xbf => {
                        if (self.utf8_len > 0 and self.utf8_len < self.utf8_expected) {
                            self.utf8_buf[self.utf8_len] = byte;
                            self.utf8_len += 1;
                            if (self.utf8_len == self.utf8_expected) {
                                // Decode complete UTF-8 sequence
                                const cp = decodeUtf8(self.utf8_buf[0..self.utf8_len]);
                                self.utf8_len = 0;
                                self.utf8_expected = 0;
                                return if (cp) |c| .{ .print = c } else null;
                            }
                            return null;
                        }
                        // Stray continuation byte — discard
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        return null;
                    },
                    else => {
                        // Other control chars — reset UTF-8 state
                        self.utf8_len = 0;
                        self.utf8_expected = 0;
                        return null;
                    },
                }
            },

            // ── Escape ───────────────────────────────────────
            .escape => {
                switch (byte) {
                    '[' => {
                        self.state = .csi_entry;
                        self.resetCsi();
                        return null;
                    },
                    ']' => {
                        self.state = .osc_string;
                        self.osc_len = 0;
                        return null;
                    },
                    '7' => {
                        // ESC 7 (DEC SC): save cursor position
                        self.state = .ground;
                        return .cursor_save;
                    },
                    '8' => {
                        // ESC 8 (DEC RC): restore cursor position
                        self.state = .ground;
                        return .cursor_restore;
                    },
                    'D' => {
                        // Index: move the cursor down one line, scrolling at the margin
                        self.state = .ground;
                        return .linefeed;
                    },
                    'E' => {
                        // Next line: Index + carriage return
                        self.state = .ground;
                        return .next_line;
                    },
                    'M' => {
                        self.state = .ground;
                        return .{ .scroll_down = 1 };
                    },
                    'P' => {
                        // DCS (Device Control String) — consume until ST
                        self.state = .dcs_passthrough;
                        return null;
                    },
                    0x20...0x2f => {
                        // intermediate bytes
                        self.state = .escape_intermediate;
                        return null;
                    },
                    else => {
                        self.state = .ground;
                        return null;
                    },
                }
            },

            // ── Escape intermediate ──────────────────────────
            .escape_intermediate => {
                if (byte >= 0x30 and byte <= 0x7e) {
                    self.state = .ground;
                }
                return null;
            },

            // ── CSI Entry ────────────────────────────────────
            .csi_entry => {
                switch (byte) {
                    '?' , '>' => {
                        self.private = true;
                        self.priv_marker = byte;
                        self.state = .csi_param;
                        return null;
                    },
                    '0'...'9' => {
                        self.state = .csi_param;
                        self.params[0] = byte - '0';
                        self.has_params |= 1; // mark param 0
                        return null;
                    },
                    ';', ':' => {
                        // ':' is the alternate (sub)parameter separator; treat it like ';'
                        self.state = .csi_param;
                        if (self.param_idx + 1 < MAX_PARAMS) self.param_idx += 1;
                        return null;
                    },
                    0x20...0x2f => {
                        self.csi_inter = byte;
                        self.state = .csi_intermediate;
                        return null;
                    },
                    0x40...0x7e => {
                        // Final byte with no params
                        self.state = .ground;
                        return self.dispatchCsi(byte);
                    },
                    else => {
                        self.state = .ground;
                        return null;
                    },
                }
            },

            // ── CSI Param ────────────────────────────────────
            .csi_param => {
                switch (byte) {
                    '0'...'9' => {
                        const digit: u16 = byte - '0';
                        const cur = self.params[self.param_idx];
                        self.params[self.param_idx] = cur *| 10 +| digit;
                        self.has_params |= @as(u16, 1) << @intCast(self.param_idx);
                        return null;
                    },
                    ';', ':' => {
                        // ':' is the alternate (sub)parameter separator used by ncurses and
                        // many modern apps (CSI 38:2:r:g:b m). Treat it like ';'.
                        if (self.param_idx + 1 < MAX_PARAMS) {
                            self.param_idx += 1;
                        }
                        // has_param tracks per-param; reset tracking for new param
                        return null;
                    },
                    0x20...0x2f => {
                        if (self.csi_inter == 0) self.csi_inter = byte;
                        self.state = .csi_intermediate;
                        return null;
                    },
                    0x40...0x7e => {
                        self.state = .ground;
                        return self.dispatchCsi(byte);
                    },
                    else => {
                        self.state = .ground;
                        return null;
                    },
                }
            },

            // ── CSI Intermediate ─────────────────────────────
            .csi_intermediate => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    self.state = .ground;
                    return self.dispatchCsi(byte);
                } else if (byte >= 0x20 and byte <= 0x2f) {
                    // Additional intermediate byte — keep the first one.
                } else if (byte == 0x1b) {
                    self.state = .ground;
                }
                return null;
            },

            // ── OSC String ───────────────────────────────────
            .osc_string => {
                switch (byte) {
                    0x07 => {
                        // BEL terminates OSC
                        self.state = .ground;
                        return self.dispatchOsc();
                    },
                    0x1b => {
                        // ESC starts ST (string terminator = ESC \)
                        // Transition to escape state so the following '\' is consumed
                        // by the escape handler (not printed as a character)
                        self.state = .escape;
                        return self.dispatchOsc();
                    },
                    else => {
                        if (self.osc_len < OSC_BUF_LEN) {
                            self.osc_buf[self.osc_len] = byte;
                            self.osc_len += 1;
                        }
                        return null;
                    },
                }
            },

            // ── DCS passthrough ──────────────────────────────────
            // Consume all bytes until ST (ESC \) or BEL
            .dcs_passthrough => {
                switch (byte) {
                    0x1b => {
                        // ESC starts ST (ESC \). Go to escape state to consume the '\'.
                        self.state = .escape;
                        return null;
                    },
                    0x07 => {
                        // BEL also terminates
                        self.state = .ground;
                        return null;
                    },
                    else => return null, // consume silently
                }
            },
        }
    }

    // ─────────────────────────────────────────────────────────
    // CSI dispatch
    // ─────────────────────────────────────────────────────────

    fn dispatchCsi(self: *Parser, final: u8) ?Event {
        if (self.private) {
            return self.dispatchCsiPrivate(final);
        }
        if (self.csi_inter != 0) {
            return self.dispatchCsiInter(final);
        }
        switch (final) {
            // Cursor up
            'A' => return .{ .cursor_move = .{
                .row = -@as(i16, @intCast(self.getParam(0, 1))),
                .col = 0,
            }},
            // Cursor down
            'B' => return .{ .cursor_move = .{
                .row = @as(i16, @intCast(self.getParam(0, 1))),
                .col = 0,
            }},
            // Cursor right / forward
            'C' => return .{ .cursor_move = .{
                .row = 0,
                .col = @as(i16, @intCast(self.getParam(0, 1))),
            }},
            // Cursor left / backward
            'D' => return .{ .cursor_move = .{
                .row = 0,
                .col = -@as(i16, @intCast(self.getParam(0, 1))),
            }},
            // Cursor Next Line (CNL) — move N lines down, col=0
            'E' => return .{ .cursor_line_move = @as(i16, @intCast(self.getParam(0, 1))) },
            // Cursor Previous Line (CPL) — move N lines up, col=0
            'F' => return .{ .cursor_line_move = -@as(i16, @intCast(self.getParam(0, 1))) },
            // Cursor position (CUP) — 1-based → 0-based
            'H', 'f' => {
                const row = self.getParam(0, 1);
                const col = self.getParam(1, 1);
                return .{ .cursor_pos = .{
                    .row = if (row > 0) row - 1 else 0,
                    .col = if (col > 0) col - 1 else 0,
                }};
            },
            // Erase in display
            'J' => return .{ .erase_display = @intCast(self.rawParam(0)) },
            // Erase in line
            'K' => return .{ .erase_line = @intCast(self.rawParam(0)) },
            // Insert lines
            'L' => return .{ .insert_lines = self.getParam(0, 1) },
            // Delete lines
            'M' => return .{ .delete_lines = self.getParam(0, 1) },
            // Scroll up
            'S' => return .{ .scroll_up = self.getParam(0, 1) },
            // Scroll down
            'T' => return .{ .scroll_down = self.getParam(0, 1) },
            // Horizontal absolute position (HPA) — 1-based → 0-based
            '`', 'G' => {
                const col = self.getParam(0, 1);
                return .{ .cursor_col_abs = if (col > 0) col - 1 else 0 };
            },
            // Vertical absolute position (VPA) — 1-based → 0-based
            'd' => {
                const row = self.getParam(0, 1);
                return .{ .cursor_row_abs = if (row > 0) row - 1 else 0 };
            },
            // Save / restore cursor (ANSI.SYS SCP / RCP)
            's' => return .cursor_save,
            'u' => return .cursor_restore,
            // Window/cursor geometry query — the app waits for a reply
            't' => return .{ .request_window_op = @intCast(self.rawParam(0)) },
            // Set scrolling region
            'r' => {
                const top = self.getParam(0, 1);
                const bot = self.getParam(1, 1);
                return .{ .scroll_region = .{
                    .top = if (top > 0) top - 1 else 0,
                    .bottom = if (bot > 0) bot - 1 else 0,
                }};
            },
            // SGR
            'm' => return .{ .sgr = self.parseSgr() },
            // DSR (Device Status Report) — CSI 6 n = request cursor position
            'n' => {
                const p = self.rawParam(0);
                if (p == 6) return .cursor_position_report;
                if (p == 5) return .notification_request; // ESC[5n echoes back
                return null;
            },
            // DA1 (Device Attributes) — CSI c or CSI 0 c
            'c' => {
                const p = self.rawParam(0);
                if (p == 0) return .device_attributes_request;
                return null;
            },
            else => return null,
        }
    }

    fn dispatchCsiPrivate(self: *Parser, final: u8) ?Event {
        const p = self.rawParam(0);

        // CSI ? Ps $ p — mode test: report "not supported" so the app stops waiting.
        if (self.csi_inter == '$' and final == 'p') {
            return .{ .request_mode_test = p };
        }

        // DA2 / DA3 (CSI > c, CSI > 4 ; c)
        if (self.priv_marker == '>' and final == 'c') {
            if (p == 4) return null; // DA3 — no reply needed
            return .device_secondary_attributes;
        }

        // DA1 with parameters (CSI ? 1 ; 2 c) — same reply as bare CSI c
        if (self.priv_marker == '?' and final == 'c') {
            return .device_attributes_request;
        }

        // Keyboard flags query (CSI ? u)
        if (final == 'u' and self.has_params == 0) {
            return .request_keyboard_flags;
        }

        switch (final) {
            'h' => switch (p) {
                1049, 1047, 47, 1048 => return .{ .alt_screen = true },
                25 => return .{ .cursor_visible = true },
                7 => return .{ .set_autowrap = true },
                36 => return .{ .set_origin = true },
                else => return null,
            },
            'l' => switch (p) {
                1049, 1047, 47, 1048 => return .{ .alt_screen = false },
                25 => return .{ .cursor_visible = false },
                7 => return .{ .set_autowrap = false },
                36 => return .{ .set_origin = false },
                else => return null,
            },
            else => return null,
        }
    }

    /// CSI with an intermediate byte (CSI Ps SP q, CSI Ps $ p, …)
    fn dispatchCsiInter(self: *Parser, final: u8) ?Event {
        switch (self.csi_inter) {
            ' ' => switch (final) {
                'q' => return null, // DECSCSR cursor style — accepted, no reply
                else => return null,
            },
            '$' => switch (final) {
                'p' => return .{ .request_mode_test = self.rawParam(0) },
                else => return null,
            },
            '!' => return null, // DECRPS — accepted, no reply
            else => return null,
        }
    }

    // ─────────────────────────────────────────────────────────
    // SGR parsing
    // ─────────────────────────────────────────────────────────

    fn parseSgr(self: *const Parser) SgrParams {
        var result = SgrParams{};
        var attr = Attr{};
        var has_attr = false;
        var clear_attr = Attr{};
        var has_clear_attr = false;

        var i: usize = 0;
        const count = self.param_idx + 1;

        while (i < count) : (i += 1) {
            const p = self.params[i];
            switch (p) {
                0 => {
                    result.reset = true;
                    attr = .{};
                    has_attr = true;
                    result.fg = null;
                    result.bg = null;
                },
                1 => { attr.bold = true; has_attr = true; },
                2 => { attr.dim = true; has_attr = true; },
                3 => { attr.italic = true; has_attr = true; },
                4 => { attr.underline = true; has_attr = true; },
                5 => { attr.blink = true; has_attr = true; },
                7 => { attr.inverse = true; has_attr = true; },
                8 => { attr.hidden = true; has_attr = true; },
                9 => { attr.strikethrough = true; has_attr = true; },
                // Attribute-off codes
                22 => { clear_attr.bold = true; clear_attr.dim = true; has_clear_attr = true; },
                23 => { clear_attr.italic = true; has_clear_attr = true; },
                24 => { clear_attr.underline = true; has_clear_attr = true; },
                25 => { clear_attr.blink = true; has_clear_attr = true; },
                27 => { clear_attr.inverse = true; has_clear_attr = true; },
                28 => { clear_attr.hidden = true; has_clear_attr = true; },
                29 => { clear_attr.strikethrough = true; has_clear_attr = true; },
                // Foreground colors
                30...37 => result.fg = .{ .idx = @intCast(p - 30) },
                38 => {
                    // 38;5;N or 38;2;R;G;B
                    if (i + 2 < count and self.params[i + 1] == 5) {
                        result.fg = .{ .idx = @intCast(self.params[i + 2]) };
                        i += 2;
                    } else if (i + 4 < count and self.params[i + 1] == 2) {
                        result.fg = .{ .rgb = .{
                            .r = @intCast(self.params[i + 2]),
                            .g = @intCast(self.params[i + 3]),
                            .b = @intCast(self.params[i + 4]),
                        }};
                        i += 4;
                    }
                },
                39 => result.fg = .default,
                // Background colors
                40...47 => result.bg = .{ .idx = @intCast(p - 40) },
                48 => {
                    if (i + 2 < count and self.params[i + 1] == 5) {
                        result.bg = .{ .idx = @intCast(self.params[i + 2]) };
                        i += 2;
                    } else if (i + 4 < count and self.params[i + 1] == 2) {
                        result.bg = .{ .rgb = .{
                            .r = @intCast(self.params[i + 2]),
                            .g = @intCast(self.params[i + 3]),
                            .b = @intCast(self.params[i + 4]),
                        }};
                        i += 4;
                    }
                },
                49 => result.bg = .default,
                // Bright foreground (90-97)
                90...97 => result.fg = .{ .idx = @intCast(p - 90 + 8) },
                // Bright background (100-107)
                100...107 => result.bg = .{ .idx = @intCast(p - 100 + 8) },
                else => {},
            }
        }

        if (has_attr) result.attr = attr;
        if (has_clear_attr) result.clear_attr = clear_attr;
        return result;
    }

    // ─────────────────────────────────────────────────────────
    // OSC dispatch
    // ─────────────────────────────────────────────────────────

    fn decodeUtf8(bytes: []const u8) ?u21 {
        if (bytes.len == 2) {
            const c0: u21 = bytes[0] & 0x1f;
            const c1: u21 = bytes[1] & 0x3f;
            return (c0 << 6) | c1;
        } else if (bytes.len == 3) {
            const c0: u21 = bytes[0] & 0x0f;
            const c1: u21 = bytes[1] & 0x3f;
            const c2: u21 = bytes[2] & 0x3f;
            return (c0 << 12) | (c1 << 6) | c2;
        } else if (bytes.len == 4) {
            const c0: u21 = bytes[0] & 0x07;
            const c1: u21 = bytes[1] & 0x3f;
            const c2: u21 = bytes[2] & 0x3f;
            const c3: u21 = bytes[3] & 0x3f;
            return (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
        }
        return null;
    }

    fn dispatchOsc(self: *Parser) ?Event {
        const buf = self.osc_buf[0..self.osc_len];
        // Palette colour queries: ESC ] 10 ; ? BEL / 11 ; ? / 12 ; ? — the app waits for a
        // reply (nvim prints "E1568: Terminal did not respond to DSR request for 'background'
        // color" when nothing answers).
        if (buf.len == 4 and buf[2] == ';' and buf[3] == '?' and
            buf[0] >= '0' and buf[0] <= '9' and buf[1] >= '0' and buf[1] <= '9')
        {
            const num: usize = @as(usize, buf[0] - '0') * 10 + @as(usize, buf[1] - '0');
            if (num >= 10 and num <= 12) return .{ .query_palette_color = @intCast(num) };
        }
        // Expect "0;" or "2;" prefix
        if (buf.len < 2) return null;
        if ((buf[0] == '0' or buf[0] == '2') and buf[1] == ';') {
            const title_src = buf[2..];
            const len: u8 = @intCast(@min(title_src.len, 255));
            var result = TitleData{ .buf = undefined, .len = len };
            @memcpy(result.buf[0..len], title_src[0..len]);
            return .{ .set_title = result };
        }
        return null;
    }
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

fn feedAll(p: *Parser, seq: []const u8) ?Event {
    var last: ?Event = null;
    for (seq) |b| {
        if (p.feed(b)) |ev| last = ev;
    }
    return last;
}

test "parse printable ASCII" {
    var p = Parser.init();
    const ev = p.feed('A');
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(Event{ .print = 'A' }, ev.?);
}

test "parse space character" {
    var p = Parser.init();
    const ev = p.feed(' ');
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(Event{ .print = ' ' }, ev.?);
}

test "parse cursor up CSI A" {
    var p = Parser.init();
    // ESC [ A  (1 row up, default param)
    _ = p.feed(0x1b);
    _ = p.feed('[');
    const ev = p.feed('A');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_move => |cm| {
            try std.testing.expectEqual(@as(i16, -1), cm.row);
            try std.testing.expectEqual(@as(i16, 0), cm.col);
        },
        else => return error.WrongEvent,
    }
}

test "parse cursor up CSI 3A" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('3');
    const ev = p.feed('A');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_move => |cm| {
            try std.testing.expectEqual(@as(i16, -3), cm.row);
            try std.testing.expectEqual(@as(i16, 0), cm.col);
        },
        else => return error.WrongEvent,
    }
}

test "parse CUP with params CSI 10;20H" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('1');
    _ = p.feed('0');
    _ = p.feed(';');
    _ = p.feed('2');
    _ = p.feed('0');
    const ev = p.feed('H');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_pos => |cp| {
            // 1-based → 0-based
            try std.testing.expectEqual(@as(u16, 9), cp.row);
            try std.testing.expectEqual(@as(u16, 19), cp.col);
        },
        else => return error.WrongEvent,
    }
}

test "parse CUP default params CSI H" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    const ev = p.feed('H');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_pos => |cp| {
            try std.testing.expectEqual(@as(u16, 0), cp.row);
            try std.testing.expectEqual(@as(u16, 0), cp.col);
        },
        else => return error.WrongEvent,
    }
}

test "parse SGR bold CSI 1m" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('1');
    const ev = p.feed('m');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |s| {
            try std.testing.expect(!s.reset);
            try std.testing.expect(s.attr != null);
            try std.testing.expect(s.attr.?.bold);
        },
        else => return error.WrongEvent,
    }
}

test "parse SGR reset CSI m (no params)" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    const ev = p.feed('m');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |s| {
            try std.testing.expect(s.reset);
        },
        else => return error.WrongEvent,
    }
}

test "parse erase display CSI 2J" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('2');
    const ev = p.feed('J');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .erase_display => |n| try std.testing.expectEqual(@as(u8, 2), n),
        else => return error.WrongEvent,
    }
}

test "parse alt screen on CSI ?1049h" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('1');
    _ = p.feed('0');
    _ = p.feed('4');
    _ = p.feed('9');
    const ev = p.feed('h');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .alt_screen => |on| try std.testing.expect(on),
        else => return error.WrongEvent,
    }
}

test "parse alt screen off CSI ?1049l" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('1');
    _ = p.feed('0');
    _ = p.feed('4');
    _ = p.feed('9');
    const ev = p.feed('l');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .alt_screen => |on| try std.testing.expect(!on),
        else => return error.WrongEvent,
    }
}

test "parse newline" {
    var p = Parser.init();
    const ev = p.feed('\n');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .linefeed => {},
        else => return error.WrongEvent,
    }
}

test "parse carriage return" {
    var p = Parser.init();
    const ev = p.feed('\r');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .carriage_return => {},
        else => return error.WrongEvent,
    }
}

test "parse backspace" {
    var p = Parser.init();
    const ev = p.feed(0x08);
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .backspace => {},
        else => return error.WrongEvent,
    }
}

test "parse OSC set title" {
    var p = Parser.init();
    // ESC ] 0 ; H e l l o BEL
    _ = p.feed(0x1b);
    _ = p.feed(']');
    _ = p.feed('0');
    _ = p.feed(';');
    _ = p.feed('H');
    _ = p.feed('e');
    _ = p.feed('l');
    _ = p.feed('l');
    _ = p.feed('o');
    const ev = p.feed(0x07);
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .set_title => |t| try std.testing.expectEqualStrings("Hello", t.buf[0..t.len]),
        else => return error.WrongEvent,
    }
}

test "parse SGR fg color 31 (red)" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('3');
    _ = p.feed('1');
    const ev = p.feed('m');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |s| {
            try std.testing.expect(s.fg != null);
            switch (s.fg.?) {
                .idx => |i| try std.testing.expectEqual(@as(u8, 1), i),
                else => return error.WrongColor,
            }
        },
        else => return error.WrongEvent,
    }
}

test "parse SGR 256-color fg 38;5;200" {
    var p = Parser.init();
    _ = feedAll(&p, "\x1b[38;5;200m");
    var p2 = Parser.init();
    _ = p2.feed(0x1b);
    _ = p2.feed('[');
    _ = p2.feed('3');
    _ = p2.feed('8');
    _ = p2.feed(';');
    _ = p2.feed('5');
    _ = p2.feed(';');
    _ = p2.feed('2');
    _ = p2.feed('0');
    _ = p2.feed('0');
    const ev = p2.feed('m');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |s| {
            try std.testing.expect(s.fg != null);
            switch (s.fg.?) {
                .idx => |i| try std.testing.expectEqual(@as(u8, 200), i),
                else => return error.WrongColor,
            }
        },
        else => return error.WrongEvent,
    }
}

test "parse reverse index ESC M" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    const ev = p.feed('M');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .scroll_down => |n| try std.testing.expectEqual(@as(u16, 1), n),
        else => return error.WrongEvent,
    }
}

test "parse cursor visible CSI ?25h" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('2');
    _ = p.feed('5');
    const ev = p.feed('h');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_visible => |v| try std.testing.expect(v),
        else => return error.WrongEvent,
    }
}

test "parse cursor hidden CSI ?25l" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('2');
    _ = p.feed('5');
    const ev = p.feed('l');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_visible => |v| try std.testing.expect(!v),
        else => return error.WrongEvent,
    }
}

test "parser returns to ground after sequence" {
    var p = Parser.init();
    // After a full CSI sequence, next byte should be treated as ground
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('A'); // cursor up
    const ev = p.feed('X');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .print => |c| try std.testing.expectEqual(@as(u21, 'X'), c),
        else => return error.WrongEvent,
    }
}

// ─────────────────────────────────────────────────────────────
// Tests for the sequences nvim/vis/vim rely on
// ─────────────────────────────────────────────────────────────

test "colon-separated SGR (CSI 38:2:r:g:b m)" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[38:2:200:211:245m");
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |params| {
            if (params.fg == null) return error.WrongColor;
            switch (params.fg.?) {
                .rgb => |c| {
                    try std.testing.expectEqual(@as(u8, 200), c.r);
                    try std.testing.expectEqual(@as(u8, 211), c.g);
                    try std.testing.expectEqual(@as(u8, 245), c.b);
                },
                else => return error.WrongColor,
            }
        },
        else => return error.WrongEvent,
    }
}

test "colon SGR leaves no printable garbage" {
    var p = Parser.init();
    // After the SGR, the next byte must print as 'A' (previously the tail of the
    // colon form leaked onto the screen as text).
    _ = feedAll(&p, "\x1b[38:2:1:2:3m");
    const ev = p.feed('A');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .print => |c| try std.testing.expectEqual(@as(u21, 'A'), c),
        else => return error.WrongEvent,
    }
}

test "VPA CSI 20d" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[20d");
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_row_abs => |row| try std.testing.expectEqual(@as(u16, 19), row),
        else => return error.WrongEvent,
    }
}

test "HPA CSI 65`" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[65`");
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_col_abs => |col| try std.testing.expectEqual(@as(u16, 64), col),
        else => return error.WrongEvent,
    }
}

test "save/restore cursor CSI s / CSI u" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[s");
    try std.testing.expectEqual(Event.cursor_save, ev.?);
    const ev2 = feedAll(&p, "\x1b[u");
    try std.testing.expectEqual(Event.cursor_restore, ev2.?);
}

test "autowrap off CSI ?7l" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[?7l");
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .set_autowrap => |on| try std.testing.expect(!on),
        else => return error.WrongEvent,
    }
}

test "mode test CSI ?69$ p answers" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[?69$p");
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .request_mode_test => |m| try std.testing.expectEqual(@as(u16, 69), m),
        else => return error.WrongEvent,
    }
}

test "DA2 CSI > c" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[>c");
    try std.testing.expectEqual(Event.device_secondary_attributes, ev.?);
}

test "DSR 5n notification" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[5n");
    try std.testing.expectEqual(Event.notification_request, ev.?);
}

test "DA1 variant CSI ?1;2c" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[?1;2c");
    try std.testing.expectEqual(Event.device_attributes_request, ev.?);
}

test "keyboard flags CSI ? u" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[?u");
    try std.testing.expectEqual(Event.request_keyboard_flags, ev.?);
}

test "background colour query OSC 11;?" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b]11;?\x07");
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .query_palette_color => |idx| try std.testing.expectEqual(@as(u8, 11), idx),
        else => return error.WrongEvent,
    }
}

test "cursor style CSI 1 SP q is consumed" {
    var p = Parser.init();
    _ = feedAll(&p, "\x1b[1 q");
    // The following byte must print normally (no leaked 'q')
    const ev = p.feed('A');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .print => |c| try std.testing.expectEqual(@as(u21, 'A'), c),
        else => return error.WrongEvent,
    }
}

test "window geometry CSI 18t" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[18t");
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .request_window_op => |op| try std.testing.expectEqual(@as(u8, 18), op),
        else => return error.WrongEvent,
    }
}

test "many empty params do not overflow" {
    var p = Parser.init();
    const ev = feedAll(&p, "\x1b[;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;A");
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_move => |cm| try std.testing.expectEqual(@as(i16, -1), cm.row),
        else => return error.WrongEvent,
    }
}

test "nvim startup prefix emits palette query" {
    var p = Parser.init();
    const prefix = "\x1b[?2004h\x1b[?1049h\x1b[?1h\x1b[H\x1b[2J\x1b[?2004h\x1b[?69$p\x1b[?2026$p\x1b[?2027$p\x1b[?2031$p\x1b[?2048$p\x1b[?u\x1b[c\x1b]11;?\x07\x1b[5n";
    var found = false;
    for (prefix) |b| {
        if (p.feed(b)) |ev| {
            switch (ev) {
                .query_palette_color => found = true,
                else => {},
            }
        }
    }
    try std.testing.expect(found);
}
