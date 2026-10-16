const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const unicode_width = @import("unicode_width.zig");
const protocol = @import("protocol.zig");
const pty_mod = @import("pty.zig");
const vt_mod = @import("vt.zig");
const scrollback_mod = @import("scrollback.zig");
const grid_mod = @import("grid.zig");
const pane_mod = @import("pane.zig");
const tab_mod = @import("tab.zig");
const render_mod = @import("render.zig");
const status_bar_mod = @import("status_bar.zig");
const config_mod = @import("config.zig");
const mode_mod = @import("mode.zig");
const session_mod = @import("session.zig");

// ─── Constants ────────────────────────────────────────────────────────────────

/// epoll data tag for the listen socket
const TAG_LISTEN: u64 = 0xFFFF_FFFF_FFFF_0000;
/// epoll data tag for the signal fd
const TAG_SIGNAL: u64 = 0xFFFF_FFFF_FFFF_0002;
/// epoll data tags for PTY fds are encoded as: TAG_PTY_BASE | pane_id
const TAG_PTY_BASE: u64 = 0x0001_0000_0000_0000;
/// epoll data tags for client fds are encoded as: TAG_CLIENT_BASE | client_id
const TAG_CLIENT_BASE: u64 = 0x0002_0000_0000_0000;

fn ptyTag(pane_id: pane_mod.PaneId) u64 {
    return TAG_PTY_BASE | @as(u64, pane_id);
}

fn isPtyTag(tag: u64) bool {
    return (tag & TAG_PTY_BASE) != 0 and
        tag != TAG_LISTEN and
        tag != TAG_SIGNAL;
}

fn paneIdFromTag(tag: u64) pane_mod.PaneId {
    return @intCast(tag & 0xFFFF);
}

fn clientTag(id: u16) u64 {
    return TAG_CLIENT_BASE | @as(u64, id);
}

fn isClientTag(tag: u64) bool {
    return (tag & TAG_CLIENT_BASE) != 0 and
        tag != TAG_LISTEN and
        tag != TAG_SIGNAL;
}

fn clientIdFromTag(tag: u64) u16 {
    return @intCast(tag & 0xFFFF);
}

// ── Formatting helpers ────────────────────────────────────────────────────────

/// Fast decimal formatting for u16 values (avoids std.fmt overhead in hot path).
/// Caller must ensure buf.len >= 5 (max digits for u16 = 65535).
fn writeDecimal(buf: []u8, val: u16) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = val;
    var tmp: [5]u8 = undefined;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        tmp[len] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = tmp[len - 1 - i];
    }
    return len;
}

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;
const MAX_CLIENTS: u8 = 8;
const RECV_BUF_SIZE: usize = protocol.HEADER_SIZE + protocol.MAX_PAYLOAD_LEN;

/// Tab bar + optional status bar + pane content vertical layout for one client.
fn clientLayout(cfg: *const config_mod.Config, cs_rows: u16) struct {
    tab_bar_rows: u16,
    status_bar_rows: u16,
    content_start_row: u16,
    content_rows: u16,
    status_bar_screen_row: ?u16,
} {
    const tab_bar_rows: u16 = if (cs_rows > 0) 1 else 0;
    const status_bar_rows: u16 = if (cfg.status_bar and cs_rows > 0) 1 else 0;
    const reserved = tab_bar_rows + status_bar_rows;
    const content_rows = cs_rows -| reserved;

    const status_top = std.mem.eql(u8, cfg.status_bar_position, "top");
    const content_start_row: u16 = if (status_top)
        tab_bar_rows + status_bar_rows
    else
        tab_bar_rows;

    const status_bar_screen_row: ?u16 = if (status_bar_rows == 0)
        null
    else if (status_top)
        tab_bar_rows
    else
        cs_rows -| 1;

    return .{
        .tab_bar_rows = tab_bar_rows,
        .status_bar_rows = status_bar_rows,
        .content_start_row = content_start_row,
        .content_rows = content_rows,
        .status_bar_screen_row = status_bar_screen_row,
    };
}

// ─── PaneState ────────────────────────────────────────────────────────────────

/// Per-pane runtime state (PTY + VT parser + scrollback + grid screen).
pub const PaneState = struct {
    allocator: std.mem.Allocator,
    pty: pty_mod.Pty,
    vt_parser: vt_mod.Parser,
    scrollback: scrollback_mod.Scrollback,
    grid: grid_mod.Grid,
    /// Pane title (set by OSC set_title VT sequence or defaulted to "Pane N").
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: u8 = 0,

    /// Apply a VT event — delegates to grid; handles set_title, CPR, and DA1 locally.
    pub fn applyEvent(self: *PaneState, ev: vt_mod.Event) void {
        switch (ev) {
            .set_title => |t| {
                const len: u8 = @intCast(@min(t.len, self.title.len));
                @memcpy(self.title[0..len], t.buf[0..len]);
                self.title_len = len;
            },
            .device_attributes_request => {
                // Respond as VT220-compatible terminal (same as zellij): ESC[?62;4c
                _ = self.pty.write("\x1b[?62;4c") catch {};
            },
            .device_secondary_attributes => {
                // DA2 (ESC > c) — keep the same VT220 family as the DA1 reply above
                _ = self.pty.write("\x1b[>62;1;0c") catch {};
            },
            .notification_request => {
                // DSR 5n: the reply is the request itself
                _ = self.pty.write("\x1b[5n") catch {};
            },
            .request_keyboard_flags => {
                // CSI ? u — report "no extended flags" (bit 1 = plain CSI u)
                _ = self.pty.write("\x1b[?1u") catch {};
            },
            .query_palette_color => |idx| {
                // OSC 10;? / 11;? / 12;? — nvim stalls and prints E1568 if nothing answers.
                // Reply with xterm's 4-hex-digit form so nvim can parse the colour.
                // Note: replying pure black makes nvim treat it as "no colour" (E1568).
                var buf: [32]u8 = undefined;
                const response = std.fmt.bufPrint(&buf, "\x1b]{d};rgb:cccc/eeee/ffff\x07", .{idx}) catch return;
                _ = self.pty.write(response) catch {};
            },
            .request_mode_test => |mode| {
                // CSI ? Ps $ p — report "not supported" so the app stops waiting
                var buf: [32]u8 = undefined;
                const response = std.fmt.bufPrint(&buf, "\x1b[?{d};0p", .{mode}) catch return;
                _ = self.pty.write(response) catch {};
            },
            .request_window_op => |op| {
                // CSI Ps t — geometry/title requests (nvim, tmux)
                const rows = self.grid.getRows();
                const cols = self.grid.getCols();
                var buf: [48]u8 = undefined;
                switch (op) {
                    18 => {
                        const response = std.fmt.bufPrint(&buf, "\x1b[18;{d};{d}t", .{ rows, cols }) catch return;
                        _ = self.pty.write(response) catch {};
                    },
                    19 => {
                        // Pixel size — approximate with a 8x18 cell
                        const response = std.fmt.bufPrint(&buf, "\x1b[19;{d};{d}t", .{
                            @as(u32, rows) * 18, @as(u32, cols) * 8,
                        }) catch return;
                        _ = self.pty.write(response) catch {};
                    },
                    21 => {
                        const t: []const u8 = self.title[0..self.title_len];
                        const response = std.fmt.bufPrint(&buf, "\x1b]21;{s}\x07", .{t}) catch return;
                        _ = self.pty.write(response) catch {};
                    },
                    else => {}, // 22/23/24 set a title — no reply
                }
            },
            else => {
                if (self.grid.applyEvent(ev)) |cpr| {
                    var cpr_buf: [32]u8 = undefined;
                    const response = std.fmt.bufPrint(&cpr_buf, "\x1b[{d};{d}R", .{
                        cpr.row, cpr.col,
                    }) catch return;
                    _ = self.pty.write(response) catch {};
                }
            },
        }
    }
};

// ─── ClientState ──────────────────────────────────────────────────────────

pub const ClientState = struct {
    id: u16,
    fd: posix.fd_t,
    cols: u16 = 0,
    rows: u16 = 0,
    screen: render_mod.Screen,
    active_tab: u8 = 0,
    active_panes: [tab_mod.MAX_TABS]pane_mod.PaneId =
        [_]pane_mod.PaneId{0} ** tab_mod.MAX_TABS,
    scroll_offsets: std.AutoHashMap(pane_mod.PaneId, u16),
    mode: mode_mod.Mode = .normal,
    recv_buf: [RECV_BUF_SIZE]u8 = undefined,
    recv_len: usize = 0,
    write_failed: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u16, fd: posix.fd_t) !*ClientState {
        const cs = try allocator.create(ClientState);
        cs.* = .{
            .id = id,
            .fd = fd,
            .screen = try render_mod.Screen.init(allocator, 80, 24),
            .scroll_offsets = std.AutoHashMap(pane_mod.PaneId, u16).init(allocator),
            .allocator = allocator,
        };
        return cs;
    }

    pub fn deinit(self: *ClientState) void {
        self.screen.deinit();
        self.scroll_offsets.deinit();
        self.allocator.destroy(self);
    }

    pub fn getScrollOffset(self: *const ClientState, pane_id: pane_mod.PaneId) u16 {
        return self.scroll_offsets.get(pane_id) orelse 0;
    }

    pub fn setScrollOffset(self: *ClientState, pane_id: pane_mod.PaneId, offset: u16) void {
        self.scroll_offsets.put(pane_id, offset) catch {};
    }
};

// ─── Server struct ────────────────────────────────────────────────────────────

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    config: config_mod.Config,
    tab_manager: tab_mod.TabManager,
    pane_states: std.AutoHashMap(pane_mod.PaneId, *PaneState),
    listen_fd: posix.fd_t,
    epoll_fd: posix.fd_t,
    clients: std.AutoHashMap(u16, *ClientState),
    next_client_id: u16 = 0,
    active_client: ?u16 = null,
    running: bool,
    socket_path: []const u8, // owned, for cleanup
    session_name: []const u8, // owned, for session save
    next_pane_id: pane_mod.PaneId, // global pane ID counter (pane 0 is reserved for first tab)
    /// Debug: if >= 0, mirror every sendFrameTo payload to this fd.
    /// Enabled by setting env var ZPLIT_TEE_PATH=/path/to/log before starting server.
    tee_fd: i32 = -1,

    /// Allocate a fresh pane ID, skipping any that are still in use.
    fn allocPaneId(self: *Server) ?pane_mod.PaneId {
        // Try up to 65536 candidates to find an unused ID
        var attempts: u32 = 0;
        while (attempts < std.math.maxInt(u16)) : (attempts += 1) {
            const candidate = self.next_pane_id;
            self.next_pane_id +%= 1; // wrapping increment
            if (!self.pane_states.contains(candidate)) {
                return candidate;
            }
        }
        return null; // all 65536 IDs exhausted (practically impossible)
    }

    // ── init ──────────────────────────────────────────────────────────────────

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        socket_path: [:0]const u8,
        session_name: []const u8,
        config: config_mod.Config,
    ) !Server {
        // Ensure parent directory exists with mode 0o700
        if (std.fs.path.dirname(socket_path)) |dir_path| {
            std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
            // chmod the directory to 0700
            const dir_cstr = try allocator.dupeZ(u8, dir_path);
            defer allocator.free(dir_cstr);
            _ = linux.chmod(dir_cstr.ptr, 0o700);
        }

        // Remove stale socket file if present
        _ = linux.unlink(socket_path);

        // Create + bind listen socket
        const sock_rc = linux.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        if (linux.errno(sock_rc) != .SUCCESS) return error.SocketFailed;
        const listen_fd: posix.fd_t = @intCast(sock_rc);
        errdefer _ = linux.close(listen_fd);

        var addr = posix.sockaddr.un{ .path = [_]u8{0} ** 108 };
        if (socket_path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..socket_path.len], socket_path);
        if (linux.errno(linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) != .SUCCESS) return error.BindFailed;
        if (linux.errno(linux.listen(listen_fd, 1)) != .SUCCESS) return error.ListenFailed;

        // Create epoll instance
        const epoll_fd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(epoll_fd_rc) != .SUCCESS) return error.EpollCreateFailed;
        const epoll_fd: posix.fd_t = @intCast(epoll_fd_rc);
        errdefer _ = linux.close(epoll_fd);

        // Register listen_fd on epoll
        {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.ERR,
                .data = .{ .u64 = TAG_LISTEN },
            };
            const r = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &ev);
            if (linux.errno(r) != .SUCCESS) return error.EpollCtlFailed;
        }

        // Initialize TabManager (creates first tab with one pane, id=0)
        var tab_manager = try tab_mod.TabManager.init(allocator);
        errdefer tab_manager.deinit();

        const path_copy = try allocator.dupe(u8, socket_path);
        errdefer allocator.free(path_copy);

        const name_copy = try allocator.dupe(u8, session_name);
        errdefer allocator.free(name_copy);

        var srv = Server{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .config = config,
            .tab_manager = tab_manager,
            .pane_states = std.AutoHashMap(pane_mod.PaneId, *PaneState).init(allocator),
            .listen_fd = listen_fd,
            .epoll_fd = epoll_fd,
            .clients = std.AutoHashMap(u16, *ClientState).init(allocator),
            .running = true,
            .socket_path = path_copy,
            .session_name = name_copy,
            .next_pane_id = 1, // pane 0 is the initial pane of the first tab
        };

        // Optional debug: mirror every outgoing payload to a file when
        // ZPLIT_TEE_PATH is set in the environment. Used to capture the raw
        // ANSI stream sent to clients for off-line analysis.
        blk: {
            const prefix = "ZPLIT_TEE_PATH=";
            const env_slice = environ.block.view().slice;
            for (env_slice) |entry_ptr| {
                const entry = std.mem.span(entry_ptr);
                if (!std.mem.startsWith(u8, entry, prefix)) continue;
                const path = entry[prefix.len..];
                if (path.len == 0) break :blk;
                const pathZ = allocator.dupeZ(u8, path) catch break :blk;
                defer allocator.free(pathZ);
                const fd_rc = linux.open(
                    pathZ.ptr,
                    .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
                    0o600,
                );
                if (linux.errno(fd_rc) == .SUCCESS) {
                    srv.tee_fd = @intCast(fd_rc);
                }
                break;
            }
        }

        // Spawn PTY for the initial pane (id=0)
        try srv.spawnPaneState(0);

        return srv;
    }

    // ── deinit ────────────────────────────────────────────────────────────────

    pub fn deinit(self: *Server) void {
        // Close all PTYs and free pane states
        var ps_it = self.pane_states.iterator();
        while (ps_it.next()) |entry| {
            const state = entry.value_ptr.*;
            state.pty.close();
            state.scrollback.deinit(self.allocator);
            state.grid.deinit();
            self.allocator.destroy(state);
        }
        self.pane_states.deinit();

        // Close and free all clients
        var cl_it = self.clients.valueIterator();
        while (cl_it.next()) |cs_ptr| {
            const cs = cs_ptr.*;
            _ = linux.close(cs.fd);
            cs.deinit();
        }
        self.clients.deinit();

        _ = linux.close(self.listen_fd);
        _ = linux.close(self.epoll_fd);
        if (self.tee_fd >= 0) _ = linux.close(self.tee_fd);

        // Remove socket file
        const socket_pathZ = self.allocator.dupeZ(u8, self.socket_path) catch null;
        if (socket_pathZ) |p| {
            _ = linux.unlink(p);
            self.allocator.free(p);
        }
        self.allocator.free(self.socket_path);
        self.allocator.free(self.session_name);

        self.tab_manager.deinit();
    }

    // ── run ───────────────────────────────────────────────────────────────────

    pub fn run(self: *Server) !void {
        // Register SIGTERM + SIGINT via signalfd
        var sig_mask = linux.sigemptyset();
        linux.sigaddset(&sig_mask, linux.SIG.TERM);
        linux.sigaddset(&sig_mask, linux.SIG.INT);
        _ = linux.sigprocmask(linux.SIG.BLOCK, &sig_mask, null);

        const sig_fd_rc = linux.signalfd(-1, &sig_mask, linux.SFD.CLOEXEC);
        if (linux.errno(sig_fd_rc) != .SUCCESS) return error.SignalFdFailed;
        const sig_fd: posix.fd_t = @intCast(sig_fd_rc);
        defer _ = linux.close(sig_fd);

        {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.ERR,
                .data = .{ .u64 = TAG_SIGNAL },
            };
            const r = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, sig_fd, &ev);
            if (linux.errno(r) != .SUCCESS) return error.EpollCtlFailed;
        }

        while (self.running) {
            var events: [32]linux.epoll_event = undefined;
            const n_rc = linux.epoll_wait(self.epoll_fd, &events, events.len, -1);
            const n_events = switch (linux.errno(n_rc)) {
                .SUCCESS => n_rc,
                .INTR => continue,
                else => return error.EpollWaitFailed,
            };

            for (events[0..n_events]) |ev| {
                const tag = ev.data.u64;

                if (tag == TAG_LISTEN) {
                    // Accept a new client connection
                    const acc_rc = linux.accept4(self.listen_fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
                    if (linux.errno(acc_rc) != .SUCCESS) continue;
                    const new_fd: posix.fd_t = @intCast(acc_rc);
                    if (self.clients.count() >= MAX_CLIENTS) {
                        _ = linux.close(new_fd);
                        continue;
                    }
                    // Assign ID (skip if in use)
                    var id = self.next_client_id;
                    while (self.clients.contains(id)) : (id +%= 1) {}
                    self.next_client_id = id +% 1;

                    const cs = ClientState.init(self.allocator, id, new_fd) catch {
                        _ = linux.close(new_fd);
                        continue;
                    };
                    self.clients.put(id, cs) catch {
                        cs.deinit();
                        _ = linux.close(new_fd);
                        continue;
                    };
                    var client_ev = linux.epoll_event{
                        .events = linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP,
                        .data = .{ .u64 = clientTag(id) },
                    };
                    const r2 = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, new_fd, &client_ev);
                    if (linux.errno(r2) != .SUCCESS) {
                        _ = self.clients.remove(id);
                        cs.deinit();
                        continue;
                    }
                    self.sendFrameTo(cs, .hello_ack, &.{}) catch {};
                    // Hide cursor and force full redraw
                    self.sendFrameTo(cs, .render, "\x1b[?25l") catch {};
                } else if (isClientTag(tag)) {
                    const client_id = clientIdFromTag(tag);
                    const cs = self.clients.get(client_id) orelse continue;
                    // Read into per-client recv_buf
                    const space = cs.recv_buf.len - cs.recv_len;
                    if (space == 0) {
                        self.disconnectClient(client_id);
                        continue;
                    }
                    const n_read = posix.read(cs.fd, cs.recv_buf[cs.recv_len..]) catch {
                        self.disconnectClient(client_id);
                        continue;
                    };
                    if (n_read == 0) {
                        self.disconnectClient(client_id);
                        continue;
                    }
                    cs.recv_len += n_read;
                    // Drain frames
                    var consumed: usize = 0;
                    while (cs.recv_len - consumed >= protocol.HEADER_SIZE) {
                        const hdr_slice: *const [protocol.HEADER_SIZE]u8 =
                            cs.recv_buf[consumed..][0..protocol.HEADER_SIZE];
                        const hdr = protocol.decodeHeader(hdr_slice) catch {
                            consumed += 1;
                            continue;
                        };
                        const frame_end = consumed + protocol.HEADER_SIZE + hdr.payload_len;
                        if (cs.recv_len < frame_end) break;
                        const payload = cs.recv_buf[consumed + protocol.HEADER_SIZE .. frame_end];
                        self.handleClientFrame(client_id, hdr.msg_type, payload);
                        consumed = frame_end;
                        // Guard: handleClientFrame may have disconnected this client
                        // (e.g. .detach frame), freeing `cs`. Stop draining in that case.
                        if (self.clients.get(client_id) == null) break;
                    }
                    if (self.clients.get(client_id) == null) continue;
                    if (consumed > 0 and consumed < cs.recv_len) {
                        std.mem.copyForwards(u8, cs.recv_buf[0..], cs.recv_buf[consumed..cs.recv_len]);
                    }
                    cs.recv_len = if (consumed > cs.recv_len) 0 else cs.recv_len - consumed;
                } else if (tag == TAG_SIGNAL) {
                    // SIGTERM or SIGINT — save layout before exit
                    var ssi: linux.signalfd_siginfo = undefined;
                    _ = posix.read(sig_fd, std.mem.asBytes(&ssi)) catch {};
                    session_mod.saveSession(self.allocator, self.io, self.environ, self.session_name, &self.tab_manager) catch {};
                    self.running = false;
                } else if (isPtyTag(tag)) {
                    // PTY output for a pane
                    const pane_id = paneIdFromTag(tag);
                    const is_hup = (ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0;
                    // Read any remaining output first
                    self.handlePtyOutput(pane_id);
                    // If HUP/ERR or read returned 0, close the pane
                    if (is_hup) {
                        self.closePaneById(pane_id);
                    }
                }
            }
        }
    }

    // ── handleClientFrame ─────────────────────────────────────────────────────

    fn handleClientFrame(self: *Server, client_id: u16, msg_type: protocol.MessageType, payload: []const u8) void {
        const cs = self.clients.get(client_id) orelse return;
        switch (msg_type) {
            .hello => {
                const hp = protocol.decodeHello(payload) catch return;
                cs.cols = hp.cols;
                cs.rows = hp.rows;
                cs.screen.resize(hp.cols, hp.rows) catch {};
                cs.screen.invalidate();
                // Initialize active_panes for all existing tabs and pick a valid active_tab
                var first_open_tab: ?u8 = null;
                for (self.tab_manager.tabs, 0..) |maybe_tab, i| {
                    if (maybe_tab) |t| {
                        const tab_idx: u8 = @intCast(i);
                        cs.active_panes[tab_idx] = pane_mod.firstLeafId(t.pane_tree.root);
                        if (first_open_tab == null) first_open_tab = tab_idx;
                    }
                }
                if (first_open_tab) |tab_idx| {
                    cs.active_tab = tab_idx;
                }
                if (self.active_client == null) {
                    self.active_client = client_id;
                }
                self.composeForClient(cs);
            },
            .input => {
                self.active_client = client_id;
                const active_pane = cs.active_panes[cs.active_tab];
                if (self.pane_states.get(active_pane)) |state| {
                    _ = state.pty.write(payload) catch {};
                }
            },
            .command => {
                if (payload.len < 1) return;
                self.active_client = client_id;
                const cmd = std.enums.fromInt(protocol.CommandId, payload[0]) orelse return;
                self.handleCommand(client_id, cmd, payload[1..]);
            },
            .resize => {
                const rp = protocol.decodeResize(payload) catch return;
                cs.cols = rp.cols;
                cs.rows = rp.rows;
                cs.screen.resize(rp.cols, rp.rows) catch {};
                cs.screen.invalidate();
                self.composeAll();
            },
            .state => {
                if (payload.len >= 1) {
                    const new_mode = std.enums.fromInt(mode_mod.Mode, payload[0]) orelse .normal;
                    if (cs.mode == .scroll and new_mode != .scroll) {
                        // Reset scroll offset on leaving scroll mode
                        const active_pane = cs.active_panes[cs.active_tab];
                        cs.scroll_offsets.put(active_pane, 0) catch {};
                    }
                    cs.mode = new_mode;
                    self.composeAll();
                }
            },
            else => {},
        }
    }

    // ── handleCommand ─────────────────────────────────────────────────────────

    pub fn handleCommand(self: *Server, client_id: u16, cmd_id: protocol.CommandId, payload: []const u8) void {
        const cs = self.clients.get(client_id) orelse return;
        const active_tab = self.tab_manager.activeTab(cs.active_tab);
        const active_pane_id = cs.active_panes[cs.active_tab];

        switch (cmd_id) {
            .split_horizontal => {
                const new_id = self.allocPaneId() orelse return;
                _ = active_tab.pane_tree.splitPane(active_pane_id, .horizontal, new_id) catch return;
                self.spawnPaneState(new_id) catch |err| {
                    _ = active_tab.pane_tree.closePane(new_id);
                    std.log.warn("split_horizontal: spawnPaneState failed: {s}", .{@errorName(err)});
                    return;
                };
                cs.active_panes[cs.active_tab] = new_id;
                self.invalidateAllClients();
                self.composeAll();
            },
            .split_vertical => {
                const new_id = self.allocPaneId() orelse return;
                _ = active_tab.pane_tree.splitPane(active_pane_id, .vertical, new_id) catch return;
                self.spawnPaneState(new_id) catch |err| {
                    _ = active_tab.pane_tree.closePane(new_id);
                    std.log.warn("split_vertical: spawnPaneState failed: {s}", .{@errorName(err)});
                    return;
                };
                cs.active_panes[cs.active_tab] = new_id;
                self.invalidateAllClients();
                self.composeAll();
            },
            .close_pane => {
                const sibling = active_tab.pane_tree.closePane(active_pane_id) orelse return;
                self.destroyPaneState(active_pane_id);
                // Update ALL clients that had this pane focused
                var it = self.clients.valueIterator();
                while (it.next()) |other_cs| {
                    if (other_cs.*.active_panes[cs.active_tab] == active_pane_id) {
                        other_cs.*.active_panes[cs.active_tab] = sibling;
                    }
                    _ = other_cs.*.scroll_offsets.remove(active_pane_id);
                }
                self.invalidateAllClients();
                self.composeAll();
            },
            .focus_pane => {
                if (payload.len < 1) return;
                const dir = std.enums.fromInt(protocol.Direction, payload[0]) orelse return;
                const lay = clientLayout(&self.config, cs.rows);
                const total_region = pane_mod.Region{
                    .row = lay.content_start_row,
                    .col = 0,
                    .rows = lay.content_rows,
                    .cols = cs.cols,
                };
                const regions = active_tab.pane_tree.calculateRegions(total_region) catch return;
                defer self.allocator.free(regions);
                if (active_tab.pane_tree.focusDirection(active_pane_id, dir, regions)) |new_id| {
                    cs.active_panes[cs.active_tab] = new_id;
                    self.composeAll();
                }
            },
            .resize_pane => {
                if (payload.len < 3) return;
                const dir = std.enums.fromInt(protocol.Direction, payload[0]) orelse return;
                const delta: i16 = @bitCast((@as(u16, payload[1]) << 8) | payload[2]);
                active_tab.pane_tree.resizePane(active_pane_id, dir, delta);
                self.invalidateAllClients();
                self.composeAll();
            },
            .toggle_fullscreen => self.composeAll(),
            .new_tab => {
                const new_pane_id = self.allocPaneId() orelse return;
                const new_tab_idx = self.tab_manager.createTab(new_pane_id) catch return;
                self.spawnPaneState(new_pane_id) catch return;
                cs.active_tab = new_tab_idx;
                // Propagate new tab's focused pane to ALL clients
                var it = self.clients.valueIterator();
                while (it.next()) |other_cs| {
                    other_cs.*.active_panes[new_tab_idx] = new_pane_id;
                }
                self.invalidateAllClients();
                self.composeAll();
            },
            .close_tab => {
                // Reject closing the last tab before destroying any state
                if (self.tab_manager.tabCount() <= 1) return;
                const closed_tab = cs.active_tab;
                // Clean up per-pane client state (scroll_offsets) before destroying
                self.cleanupClientStateForTab(closed_tab);
                self.destroyAllPanesInTab(closed_tab);
                const nearest = self.tab_manager.closeTab(closed_tab) orelse return;
                // Update ALL clients viewing the closed tab
                var it = self.clients.valueIterator();
                while (it.next()) |other_cs| {
                    if (other_cs.*.active_tab == closed_tab) {
                        other_cs.*.active_tab = nearest;
                    }
                }
                self.invalidateAllClients();
                self.composeAll();
            },
            .next_tab => {
                cs.active_tab = self.tab_manager.nextTab(cs.active_tab);
                cs.screen.invalidate();
                self.composeForClient(cs);
            },
            .prev_tab => {
                cs.active_tab = self.tab_manager.prevTab(cs.active_tab);
                cs.screen.invalidate();
                self.composeForClient(cs);
            },
            .switch_tab => {
                if (payload.len < 1) return;
                const target = payload[0];
                if (target < tab_mod.MAX_TABS and self.tab_manager.tabs[target] != null) {
                    cs.active_tab = target;
                    cs.screen.invalidate();
                    self.composeForClient(cs);
                }
            },
            .rename_tab => {
                if (payload.len > 0) {
                    self.tab_manager.activeTab(cs.active_tab).setName(payload);
                    self.composeAll();
                }
            },
            .scroll_up_lines => {
                if (self.pane_states.get(active_pane_id)) |state| {
                    const max: u16 = @intCast(@min(state.grid.scrollbackLen(), std.math.maxInt(u16)));
                    const cur = cs.getScrollOffset(active_pane_id);
                    cs.setScrollOffset(active_pane_id, @min(cur +| 1, max));
                    self.composeForClient(cs);
                }
            },
            .scroll_down_lines => {
                const cur = cs.getScrollOffset(active_pane_id);
                cs.setScrollOffset(active_pane_id, cur -| 1);
                self.composeForClient(cs);
            },
            .scroll_half_page_up => {
                if (self.pane_states.get(active_pane_id)) |state| {
                    const max: u16 = @intCast(@min(state.grid.scrollbackLen(), std.math.maxInt(u16)));
                    const cur = cs.getScrollOffset(active_pane_id);
                    cs.setScrollOffset(active_pane_id, @min(cur +| (state.grid.viewport_rows / 2), max));
                    self.composeForClient(cs);
                }
            },
            .scroll_half_page_down => {
                if (self.pane_states.get(active_pane_id)) |state| {
                    const cur = cs.getScrollOffset(active_pane_id);
                    cs.setScrollOffset(active_pane_id, cur -| (state.grid.viewport_rows / 2));
                    self.composeForClient(cs);
                }
            },
            .detach => {
                session_mod.saveSession(self.allocator, self.io, self.environ, self.session_name, &self.tab_manager) catch {};
                self.disconnectClient(client_id);
            },
            .quit => {
                session_mod.saveSession(self.allocator, self.io, self.environ, self.session_name, &self.tab_manager) catch {};
                self.running = false;
            },
        }
    }

    // ── spawnPaneState ────────────────────────────────────────────────────────

    pub fn spawnPaneState(self: *Server, pane_id: pane_mod.PaneId) !void {
        // Use $SHELL if available, otherwise fall back to config default
        const shell = std.process.Environ.getPosix(self.environ, "SHELL") orelse self.config.default_shell;
        const shell_z = try self.allocator.dupeZ(u8, shell);
        defer self.allocator.free(shell_z);

        // Initial size: use active client dimensions minus reserved UI rows/cols.
        // The grid will be properly resized to the actual pane region on the first compose().
        const reserved_cols: u16 = 2; // border left/right
        var c_cols: u16 = DEFAULT_COLS;
        var c_rows: u16 = DEFAULT_ROWS;
        if (self.active_client) |ac_id| {
            if (self.clients.get(ac_id)) |ac| {
                if (ac.cols > 0) c_cols = ac.cols;
                if (ac.rows > 0) c_rows = ac.rows;
            }
        }
        const tab_r: u16 = if (c_rows > 0) 1 else 0;
        const status_r: u16 = if (self.config.status_bar and c_rows > 0) 1 else 0;
        const reserved_rows: u16 = tab_r + status_r + 2; // UI chrome + pane border top/bottom
        const init_cols: u16 = if (c_cols > reserved_cols) c_cols - reserved_cols else 1;
        const init_rows: u16 = if (c_rows > reserved_rows) c_rows - reserved_rows else 1;
        const pty = try pty_mod.Pty.spawn(shell_z, init_cols, init_rows, self.environ);

        const sb_lines = self.config.scrollback_lines;
        const sb_bytes = self.config.scrollback_max_bytes;
        const sb = try scrollback_mod.Scrollback.init(self.allocator, sb_lines, sb_bytes);

        var grid = try grid_mod.Grid.init(self.allocator, init_cols, init_rows);
        errdefer grid.deinit();
        // Bound the rows the grid keeps above the viewport (pane resizes push
        // rows into scrollback; without a cap they would grow unboundedly).
        grid.max_scrollback_lines = @as(usize, sb_lines);

        const state = try self.allocator.create(PaneState);
        errdefer self.allocator.destroy(state);
        state.* = PaneState{
            .allocator = self.allocator,
            .pty = pty,
            .vt_parser = vt_mod.Parser.init(),
            .scrollback = sb,
            .grid = grid,
        };

        try self.pane_states.put(pane_id, state);

        // Register PTY master fd on epoll
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .data = .{ .u64 = ptyTag(pane_id) },
        };
        const r = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, pty.master_fd, &ev);
        if (linux.errno(r) != .SUCCESS) {
            _ = self.pane_states.remove(pane_id);
            state.pty.close();
            state.scrollback.deinit(self.allocator);
            state.grid.deinit();
            self.allocator.destroy(state);
            return error.EpollCtlFailed;
        }
    }

    // ── destroyPaneState ─────────────────────────────────────────────────────

    pub fn destroyPaneState(self: *Server, pane_id: pane_mod.PaneId) void {
        const state = self.pane_states.fetchRemove(pane_id) orelse return;
        const s = state.value;
        // Remove from epoll before closing
        const r = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, s.pty.master_fd, null);
        _ = r;
        s.pty.close();
        s.scrollback.deinit(self.allocator);
        s.grid.deinit();
        self.allocator.destroy(s);
    }

    // ── closePaneById ──────────────────────────────────────────────────────────

    fn closePaneById(self: *Server, pane_id: pane_mod.PaneId) void {
        // Search all tabs to find which one contains this pane.
        var found_tab_idx: ?u8 = null;
        for (&self.tab_manager.tabs, 0..) |*slot, i| {
            if (slot.*) |*t| {
                if (self.isPaneInTree(t.pane_tree.root, pane_id)) {
                    found_tab_idx = @intCast(i);
                    break;
                }
            }
        }
        const tab_idx = found_tab_idx orelse return;
        const tab = &(self.tab_manager.tabs[tab_idx].?);

        // Try to close in the pane tree — returns sibling or null if last pane
        if (tab.pane_tree.closePane(pane_id)) |sibling| {
            self.destroyPaneState(pane_id);
            // Update ALL clients that had this pane focused
            var it = self.clients.valueIterator();
            while (it.next()) |cs_ptr| {
                if (cs_ptr.*.active_panes[tab_idx] == pane_id) {
                    cs_ptr.*.active_panes[tab_idx] = sibling;
                }
                _ = cs_ptr.*.scroll_offsets.remove(pane_id);
            }
            self.composeAll();
        } else {
            // Last pane in tab — close the tab or keep it empty
            self.destroyPaneState(pane_id);
            if (self.tab_manager.tabCount() > 1) {
                const nearest = self.tab_manager.closeTab(tab_idx) orelse return;
                // Update ALL clients viewing the closed tab
                var it = self.clients.valueIterator();
                while (it.next()) |cs_ptr| {
                    if (cs_ptr.*.active_tab == tab_idx) {
                        cs_ptr.*.active_tab = nearest;
                    }
                }
                self.composeAll();
            } else {
                // Last tab, last pane — quit
                self.running = false;
            }
        }
    }

    // ── handlePtyOutput ───────────────────────────────────────────────────────

    fn handlePtyOutput(self: *Server, pane_id: pane_mod.PaneId) void {
        const state = self.pane_states.get(pane_id) orelse return;
        var buf: [16384]u8 = undefined;
        const n = state.pty.read(&buf) catch {
            return; // Error reading — HUP handler will clean up
        };
        if (n == 0) return; // EOF — child process exited; EPOLLHUP handler will clean up


        // Feed bytes through VT parser and update pane screen buffer
        const was_in_alt = state.grid.in_alt_screen;
        for (buf[0..n]) |byte| {
            if (state.vt_parser.feed(byte)) |event| {
                state.applyEvent(event);
            }
        }
        const left_alt = was_in_alt and !state.grid.in_alt_screen;

        // Check if this pane is visible for any client, and invalidate screens if leaving alt screen
        var any_visible = false;
        var cl_it = self.clients.valueIterator();
        while (cl_it.next()) |cs_ptr| {
            const c = cs_ptr.*;
            const tab = self.tab_manager.activeTab(c.active_tab);
            if (self.isPaneInTree(tab.pane_tree.root, pane_id)) {
                any_visible = true;
                if (left_alt) c.screen.invalidate();
            }
        }
        if (any_visible) {
            self.composeAll();
        }
    }

    // ── invalidateAllClients ─────────────────────────────────────────────

    /// Mark all client screens as fully dirty so the next compose sends a
    /// complete redraw.  Must be called before composeAll() whenever the
    /// pane layout changes (split, close, tab switch, resize_pane).
    fn invalidateAllClients(self: *Server) void {
        var it = self.clients.valueIterator();
        while (it.next()) |client| {
            client.*.screen.invalidate();
        }
    }

    // ── composeAll ─────────────────────────────────────────────────────────

    /// Resize PTYs based on active client's dimensions, then render for all clients.
    fn composeAll(self: *Server) void {
        // Pre-pass: resize PTYs based on active client's dimensions
        if (self.active_client) |ac_id| {
            if (self.clients.get(ac_id)) |ac| {
                self.resizePtysForClient(ac);
            }
        }
        // Render for each connected client
        var it = self.clients.valueIterator();
        while (it.next()) |cs| {
            self.composeForClient(cs.*);
        }
        // Disconnect clients that failed to write (corrupted protocol stream)
        self.sweepFailedClients();
    }

    // ── resizePtysForClient ──────────────────────────────────────────────

    fn resizePtysForClient(self: *Server, cs: *ClientState) void {
        const lay = clientLayout(&self.config, cs.rows);
        const total_region = pane_mod.Region{
            .row = lay.content_start_row,
            .col = 0,
            .rows = lay.content_rows,
            .cols = cs.cols,
        };
        const active_tab = self.tab_manager.activeTab(cs.active_tab);
        const regions = active_tab.pane_tree.calculateRegions(total_region) catch return;
        defer self.allocator.free(regions);
        for (regions) |entry| {
            const pane_state = self.pane_states.get(entry.id) orelse continue;
            const new_cols = if (entry.region.cols > 2) entry.region.cols - 2 else 1;
            const new_rows = if (entry.region.rows > 2) entry.region.rows - 2 else 1;
            if (pane_state.grid.cols != new_cols or pane_state.grid.viewport_rows != new_rows) {
                pane_state.pty.setSize(new_cols, new_rows) catch {};
                pane_state.grid.resize(new_cols, new_rows) catch {};
            }
        }
    }

    // ── composeForClient ─────────────────────────────────────────────────

    /// Composite all pane screen buffers onto a client's Screen, draw borders,
    /// render the tab bar and status bar, send dirty regions to the client.
    fn composeForClient(self: *Server, cs: *ClientState) void {
        if (cs.cols == 0 or cs.rows == 0) return;

        // Clear back buffer
        cs.screen.clear();

        const lay = clientLayout(&self.config, cs.rows);

        const total_region = pane_mod.Region{
            .row = lay.content_start_row,
            .col = 0,
            .rows = lay.content_rows,
            .cols = cs.cols,
        };

        // Collect tab names
        var tab_names_buf: [tab_mod.MAX_TABS][]const u8 = undefined;
        var tab_names_len: usize = 0;
        for (&self.tab_manager.tabs) |*slot| {
            if (slot.*) |*t| {
                tab_names_buf[tab_names_len] = t.getName();
                tab_names_len += 1;
            }
        }
        const tab_names = tab_names_buf[0..tab_names_len];

        // Render tab bar in row 0
        if (lay.tab_bar_rows > 0 and cs.screen.rows > 0) {
            const tab_bar_start: usize = 0;
            const tab_bar_end = @as(usize, cs.screen.cols);
            if (tab_bar_end <= cs.screen.back.len) {
                const tab_bar_cells = cs.screen.back[tab_bar_start..tab_bar_end];
                status_bar_mod.renderTabBar(
                    tab_bar_cells,
                    cs.screen.cols,
                    tab_names,
                    cs.active_tab,
                );
            }
        }

        // Calculate pane regions for this client's active tab
        const active_tab = self.tab_manager.activeTab(cs.active_tab);
        const regions = active_tab.pane_tree.calculateRegions(total_region) catch return;
        defer self.allocator.free(regions);

        // For each pane region, draw border with title and copy pane content
        for (regions) |entry| {
            const pane_state = self.pane_states.get(entry.id) orelse continue;
            const region = entry.region;
            const is_active = (entry.id == cs.active_panes[cs.active_tab]);

            var default_title_buf: [16]u8 = undefined;
            const title: []const u8 = if (pane_state.title_len > 0)
                pane_state.title[0..pane_state.title_len]
            else blk: {
                const s = std.fmt.bufPrint(&default_title_buf, "Pane {d}", .{entry.id + 1}) catch "Pane";
                break :blk s;
            };

            cs.screen.drawBorderWithTitle(region, title, is_active);

            const inner_row = region.row + 1;
            const inner_col = region.col + 1;
            const inner_rows = if (region.rows > 2) region.rows - 2 else 0;
            const inner_cols = if (region.cols > 2) region.cols - 2 else 0;

            // Hoist scroll offset computation out of the inner cell loop
            const max_scroll: u16 = @intCast(@min(pane_state.grid.scrollbackLen(), std.math.maxInt(u16)));
            const eff_scroll = @min(cs.getScrollOffset(entry.id), max_scroll);
            const eff_inner_rows = @min(inner_rows, pane_state.grid.viewport_rows);
            const eff_inner_cols = @min(inner_cols, pane_state.grid.cols);

            var r: u16 = 0;
            while (r < eff_inner_rows) : (r += 1) {
                const screen_row = inner_row + r;
                if (screen_row >= cs.screen.rows) break;

                var c: u16 = 0;
                while (c < eff_inner_cols) : (c += 1) {
                    const screen_col = inner_col + c;
                    if (screen_col >= cs.screen.cols) break;

                    const vt_cell = pane_state.grid.getCellScrolled(r, c, eff_scroll);

                    const screen_cell = cs.screen.cellAt(screen_row, screen_col);
                    screen_cell.* = render_mod.Cell{
                        .char = vt_cell.char,
                        .fg = vt_cell.fg,
                        .bg = vt_cell.bg,
                        .attr = vt_cell.attr,
                    };
                }
            }
        }

        // Render status bar (row from config: top = below tab bar, bottom = last row)
        if (lay.status_bar_screen_row) |bar_row| {
            if (bar_row < cs.screen.rows) {
                const bar_start = @as(usize, bar_row) * cs.screen.cols;
                const bar_end = bar_start + cs.screen.cols;
                if (bar_end <= cs.screen.back.len) {
                    const bar_cells = cs.screen.back[bar_start..bar_end];
                    status_bar_mod.renderStatusBar(
                        bar_cells,
                        cs.screen.cols,
                        cs.mode,
                    );
                }
            }
        }

        // Send dirty regions to this client
        self.sendDirtyRegionsTo(cs);

        // Position cursor in active pane and show it
        const active_pane_id = cs.active_panes[cs.active_tab];
        if (self.pane_states.get(active_pane_id)) |active_state| {
            for (regions) |entry| {
                if (entry.id == active_pane_id) {
                    const cursor_row = entry.region.row + 1 + active_state.grid.cursor_row;
                    const cursor_col = entry.region.col + 1 + active_state.grid.cursor_col;
                    var cursor_buf: [32]u8 = undefined;
                    const cursor_seq = std.fmt.bufPrint(&cursor_buf, "\x1b[{d};{d}H\x1b[?25h", .{
                        cursor_row + 1, cursor_col + 1,
                    }) catch break;
                    self.sendFrameTo(cs, .render, cursor_seq) catch {};
                    break;
                }
            }
        }

        // Swap buffers
        cs.screen.swapBuffers();

        // Disconnect clients that failed to write during this render
        if (cs.write_failed) {
            self.sweepFailedClients();
        }
    }

    // ── sendDirtyRegionsTo ───────────────────────────────────────────────

    /// Optimized rendering pipeline:
    /// - Inline front/back buffer comparison (zero allocation for dirty regions)
    /// - SGR delta encoding (skip unchanged styles between consecutive cells)
    /// - Fixed stack buffer with chunked sends (no dynamic allocation)
    /// - Cursor position elision (skip CUP when cursor naturally advances)
    fn sendDirtyRegionsTo(self: *Server, cs: *ClientState) void {
        const front = cs.screen.front;
        const back = cs.screen.back;
        const cols = cs.screen.cols;
        const rows = cs.screen.rows;
        const Cell = render_mod.Cell;

        // Fixed output buffer — flush when approaching capacity
        var buf: [32768]u8 = undefined;
        var pos: usize = 0;

        // SGR state tracking for delta encoding
        var last_fg: vt_mod.Color = .default;
        var last_bg: vt_mod.Color = .default;
        var last_attr: u8 = 0;
        var sgr_valid = false;

        // Cursor position tracking — skip CUP when cursor naturally advances
        var cur_row: u16 = 0xFFFF;
        var cur_col: u16 = 0xFFFF;

        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            const row_off = @as(usize, row) * @as(usize, cols);
            var col: u16 = 0;
            while (col < cols) : (col += 1) {
                const idx = row_off + col;
                if (Cell.eql(front[idx], back[idx])) continue;

                const cell = back[idx];
                // Skip spacer cells (second cell of wide characters)
                if (cell.char == 0) {
                    cur_row = row;
                    cur_col = col + 1;
                    continue;
                }

                // Flush if near capacity (worst case ~60 bytes per cell)
                if (pos + 80 > buf.len) {
                    self.sendFrameTo(cs, .render, buf[0..pos]) catch return;
                    pos = 0;
                }

                // CUP: only emit when cursor isn't at expected position
                if (row != cur_row or col != cur_col) {
                    buf[pos] = '\x1b';
                    buf[pos + 1] = '[';
                    pos += 2;
                    pos += writeDecimal(buf[pos..], row + 1);
                    buf[pos] = ';';
                    pos += 1;
                    pos += writeDecimal(buf[pos..], col + 1);
                    buf[pos] = 'H';
                    pos += 1;
                }

                // SGR: only emit when style differs from last emitted cell
                const cell_attr: u8 = @bitCast(cell.attr);
                const style_same = sgr_valid and
                    cell.fg.eql(last_fg) and
                    cell.bg.eql(last_bg) and
                    cell_attr == last_attr;

                if (!style_same) {
                    // Emit full SGR reset + active styles
                    buf[pos] = '\x1b';
                    buf[pos + 1] = '[';
                    buf[pos + 2] = '0';
                    pos += 3;

                    // Foreground
                    switch (cell.fg) {
                        .default => {},
                        .idx => |i| {
                            buf[pos] = ';';
                            pos += 1;
                            if (i < 8) {
                                pos += writeDecimal(buf[pos..], @as(u16, 30) + @as(u16, i));
                            } else if (i < 16) {
                                pos += writeDecimal(buf[pos..], @as(u16, 90) + @as(u16, i) - 8);
                            } else {
                                @memcpy(buf[pos..][0..4], "38;5");
                                pos += 4;
                                buf[pos] = ';';
                                pos += 1;
                                pos += writeDecimal(buf[pos..], @as(u16, i));
                            }
                        },
                        .rgb => |c| {
                            @memcpy(buf[pos..][0..5], ";38;2");
                            pos += 5;
                            buf[pos] = ';';
                            pos += 1;
                            pos += writeDecimal(buf[pos..], @as(u16, c.r));
                            buf[pos] = ';';
                            pos += 1;
                            pos += writeDecimal(buf[pos..], @as(u16, c.g));
                            buf[pos] = ';';
                            pos += 1;
                            pos += writeDecimal(buf[pos..], @as(u16, c.b));
                        },
                    }

                    // Background
                    switch (cell.bg) {
                        .default => {},
                        .idx => |i| {
                            buf[pos] = ';';
                            pos += 1;
                            if (i < 8) {
                                pos += writeDecimal(buf[pos..], @as(u16, 40) + @as(u16, i));
                            } else if (i < 16) {
                                pos += writeDecimal(buf[pos..], @as(u16, 100) + @as(u16, i) - 8);
                            } else {
                                @memcpy(buf[pos..][0..4], "48;5");
                                pos += 4;
                                buf[pos] = ';';
                                pos += 1;
                                pos += writeDecimal(buf[pos..], @as(u16, i));
                            }
                        },
                        .rgb => |c| {
                            @memcpy(buf[pos..][0..5], ";48;2");
                            pos += 5;
                            buf[pos] = ';';
                            pos += 1;
                            pos += writeDecimal(buf[pos..], @as(u16, c.r));
                            buf[pos] = ';';
                            pos += 1;
                            pos += writeDecimal(buf[pos..], @as(u16, c.g));
                            buf[pos] = ';';
                            pos += 1;
                            pos += writeDecimal(buf[pos..], @as(u16, c.b));
                        },
                    }

                    // Attributes
                    const a = cell.attr;
                    if (a.bold) {
                        @memcpy(buf[pos..][0..2], ";1");
                        pos += 2;
                    }
                    if (a.dim) {
                        @memcpy(buf[pos..][0..2], ";2");
                        pos += 2;
                    }
                    if (a.italic) {
                        @memcpy(buf[pos..][0..2], ";3");
                        pos += 2;
                    }
                    if (a.underline) {
                        @memcpy(buf[pos..][0..2], ";4");
                        pos += 2;
                    }
                    if (a.blink) {
                        @memcpy(buf[pos..][0..2], ";5");
                        pos += 2;
                    }
                    if (a.inverse) {
                        @memcpy(buf[pos..][0..2], ";7");
                        pos += 2;
                    }
                    if (a.hidden) {
                        @memcpy(buf[pos..][0..2], ";8");
                        pos += 2;
                    }
                    if (a.strikethrough) {
                        @memcpy(buf[pos..][0..2], ";9");
                        pos += 2;
                    }

                    buf[pos] = 'm';
                    pos += 1;

                    last_fg = cell.fg;
                    last_bg = cell.bg;
                    last_attr = cell_attr;
                    sgr_valid = true;
                }

                // UTF-8 encode the character
                const utf8_len = std.unicode.utf8Encode(cell.char, buf[pos..][0..4]) catch {
                    @memcpy(buf[pos..][0..3], "\xef\xbf\xbd");
                    pos += 3;
                    cur_row = row;
                    cur_col = col + 1;
                    continue;
                };
                pos += utf8_len;

                // Advance tracked column by display width so the next CUP is correct
                // for wide characters (spacer column is skipped in the loop body).
                const disp_w: u16 = @intCast(unicode_width.terminalDisplayWidth(cell.char));
                cur_row = row;
                cur_col = col + @max(disp_w, 1);
            }
        }

        if (pos > 0) {
            self.sendFrameTo(cs, .render, buf[0..pos]) catch {};
        }
    }

    // ── sendFrameTo ──────────────────────────────────────────────────────

    fn sendFrameTo(self: *Server, cs: *ClientState, msg_type: protocol.MessageType, payload: []const u8) !void {
        // Debug tee: mirror render payloads (the actual ANSI stream) to a log
        // file when ZPLIT_TEE_PATH is configured. Skipped for non-render
        // message types and best-effort on write errors.
        if (self.tee_fd >= 0 and msg_type == .render and payload.len > 0) {
            var written: usize = 0;
            while (written < payload.len) {
                const rc = linux.write(self.tee_fd, payload[written..].ptr, payload.len - written);
                if (linux.errno(rc) != .SUCCESS) break;
                if (rc == 0) break;
                written += rc;
            }
        }

        var buf: [protocol.HEADER_SIZE + protocol.MAX_PAYLOAD_LEN]u8 = undefined;
        const n = try protocol.encodeFrame(&buf, msg_type, payload);
        var sent: usize = 0;
        while (sent < n) {
            const w_rc = linux.write(cs.fd, buf[sent..n].ptr, n - sent);
            const w_err = linux.errno(w_rc);
            if (w_err != .SUCCESS) {
                // Retry on signal interruption — matches the old posix.write behavior
                // that std.posix.* used to do automatically.
                if (w_err == .INTR) continue;
                // WouldBlock before any data sent = transient backpressure, skip frame
                // WouldBlock after partial send = protocol stream corrupted, must disconnect
                if ((w_err == .AGAIN) and sent == 0) return error.WouldBlock;
                cs.write_failed = true;
                return error.WriteFailed;
            }
            if (w_rc == 0) {
                cs.write_failed = true;
                return error.BrokenPipe;
            }
            sent += w_rc;
        }
    }

    // ── disconnectClient ─────────────────────────────────────────────────

    fn disconnectClient(self: *Server, client_id: u16) void {
        const cs = self.clients.get(client_id) orelse return;
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, cs.fd, null);
        _ = linux.close(cs.fd);
        cs.deinit();
        _ = self.clients.remove(client_id);
        if (self.active_client) |ac| {
            if (ac == client_id) {
                // Fall back to lowest ID client
                self.active_client = null;
                var it = self.clients.keyIterator();
                var min_id: ?u16 = null;
                while (it.next()) |k| {
                    if (min_id == null or k.* < min_id.?) min_id = k.*;
                }
                self.active_client = min_id;
            }
        }
    }

    // ── sweepFailedClients ─────────────────────────────────────────────

    /// Disconnect clients whose write_failed flag is set (protocol stream corrupted).
    /// Safe to call after iteration since it collects IDs first.
    fn sweepFailedClients(self: *Server) void {
        var to_remove: [MAX_CLIENTS]u16 = undefined;
        var count: u8 = 0;
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.write_failed) {
                if (count < MAX_CLIENTS) {
                    to_remove[count] = entry.key_ptr.*;
                    count += 1;
                }
            }
        }
        for (to_remove[0..count]) |cid| {
            self.disconnectClient(cid);
        }
    }

    // ── cleanupClientStateForTab ────────────────────────────────────────

    /// Remove scroll_offsets entries for all panes in the given tab from every client.
    fn cleanupClientStateForTab(self: *Server, tab_idx: u8) void {
        const tab = self.tab_manager.activeTab(tab_idx);
        var cit = self.clients.valueIterator();
        while (cit.next()) |client_cs| {
            self.removeScrollOffsetsInNode(client_cs.*, tab.pane_tree.root);
        }
    }

    fn removeScrollOffsetsInNode(self: *Server, cs_ptr: *ClientState, node: *pane_mod.LayoutNode) void {
        switch (node.*) {
            .leaf => |l| {
                _ = cs_ptr.scroll_offsets.remove(l.id);
            },
            .split => |s| {
                self.removeScrollOffsetsInNode(cs_ptr, s.first);
                self.removeScrollOffsetsInNode(cs_ptr, s.second);
            },
        }
    }

    // ── destroyAllPanesInTab ─────────────────────────────────────────────

    fn destroyAllPanesInTab(self: *Server, tab_idx: u8) void {
        const tab = self.tab_manager.activeTab(tab_idx);
        self.destroyPanesInNode(tab.pane_tree.root);
    }

    fn destroyPanesInNode(self: *Server, node: *pane_mod.LayoutNode) void {
        switch (node.*) {
            .leaf => |l| self.destroyPaneState(l.id),
            .split => |s| {
                self.destroyPanesInNode(s.first);
                self.destroyPanesInNode(s.second);
            },
        }
    }

    // ── isPaneInTree ──────────────────────────────────────────────────────────

    fn isPaneInTree(self: *Server, node: *pane_mod.LayoutNode, pane_id: pane_mod.PaneId) bool {
        switch (node.*) {
            .leaf => |l| return l.id == pane_id,
            .split => |s| return self.isPaneInTree(s.first, pane_id) or
                self.isPaneInTree(s.second, pane_id),
        }
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "clientLayout bottom matches tab then content then status row" {
    var cfg = config_mod.Config{};
    const lay = clientLayout(&cfg, 24);
    try std.testing.expectEqual(@as(u16, 1), lay.tab_bar_rows);
    try std.testing.expectEqual(@as(u16, 1), lay.status_bar_rows);
    try std.testing.expectEqual(@as(u16, 1), lay.content_start_row);
    try std.testing.expectEqual(@as(u16, 22), lay.content_rows);
    try std.testing.expectEqual(@as(u16, 23), lay.status_bar_screen_row.?);
}

test "clientLayout top places status below tab bar and content below both" {
    var cfg = config_mod.Config{ .status_bar_position = "top" };
    const lay = clientLayout(&cfg, 24);
    try std.testing.expectEqual(@as(u16, 1), lay.tab_bar_rows);
    try std.testing.expectEqual(@as(u16, 1), lay.status_bar_rows);
    try std.testing.expectEqual(@as(u16, 1), lay.status_bar_screen_row.?);
    try std.testing.expectEqual(@as(u16, 2), lay.content_start_row);
    try std.testing.expectEqual(@as(u16, 22), lay.content_rows);
}

test "clientLayout disabled status bar frees a row for content" {
    var cfg = config_mod.Config{ .status_bar = false };
    const lay = clientLayout(&cfg, 24);
    try std.testing.expectEqual(@as(u16, 0), lay.status_bar_rows);
    try std.testing.expectEqual(@as(?u16, null), lay.status_bar_screen_row);
    try std.testing.expectEqual(@as(u16, 1), lay.content_start_row);
    try std.testing.expectEqual(@as(u16, 23), lay.content_rows);
}

test "Server struct compiles" {
    // Ensure the Server type is valid and fields are accessible.
    const info = @typeInfo(Server);
    comptime std.debug.assert(info == .@"struct");
}

test "PaneState applyEvent print" {
    const allocator = std.testing.allocator;

    const cols: u16 = 10;
    const rows: u16 = 5;

    var grid = try grid_mod.Grid.init(allocator, cols, rows);
    defer grid.deinit();

    var sb = try scrollback_mod.Scrollback.init(allocator, 100, 4096);
    defer sb.deinit(allocator);

    var state = PaneState{
        .allocator = allocator,
        .pty = undefined, // not used in this test
        .vt_parser = vt_mod.Parser.init(),
        .scrollback = sb,
        .grid = grid,
    };
    // Detach scrollback ownership so deinit isn't called twice
    state.scrollback.count = 0;

    state.applyEvent(.{ .print = 'A' });
    try std.testing.expectEqual(@as(u21, 'A'), state.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(u16, 1), state.grid.cursor_col);
}

test "PaneState applyEvent cursor_pos" {
    const allocator = std.testing.allocator;

    const cols: u16 = 80;
    const rows: u16 = 24;

    var grid = try grid_mod.Grid.init(allocator, cols, rows);
    defer grid.deinit();

    var sb = try scrollback_mod.Scrollback.init(allocator, 100, 4096);
    defer sb.deinit(allocator);

    var state = PaneState{
        .allocator = allocator,
        .pty = undefined,
        .vt_parser = vt_mod.Parser.init(),
        .scrollback = sb,
        .grid = grid,
    };

    state.applyEvent(.{ .cursor_pos = .{ .row = 5, .col = 10 } });
    try std.testing.expectEqual(@as(u16, 5), state.grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 10), state.grid.cursor_col);
}

test "PaneState applyEvent erase_display 2" {
    const allocator = std.testing.allocator;

    const cols: u16 = 10;
    const rows: u16 = 5;

    const grid = try grid_mod.Grid.init(allocator, cols, rows);

    // Fill with non-blank cells
    for (grid.rows.items) |*r| {
        for (r.cells) |*c| c.* = vt_mod.Cell{ .char = 'X' };
    }

    var sb = try scrollback_mod.Scrollback.init(allocator, 100, 4096);
    defer sb.deinit(allocator);

    var state = PaneState{
        .allocator = allocator,
        .pty = undefined,
        .vt_parser = vt_mod.Parser.init(),
        .scrollback = sb,
        .grid = grid,
    };
    defer state.grid.deinit();

    state.applyEvent(.{ .erase_display = 2 });

    // After erase_display 2 in normal mode, the viewport shows blank rows
    // (old content is preserved above viewport)
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        var c: u16 = 0;
        while (c < cols) : (c += 1) {
            try std.testing.expectEqual(@as(u21, ' '), state.grid.getCell(r, c).char);
        }
    }
}

test "ptyTag and isPtyTag" {
    const id: pane_mod.PaneId = 3;
    const tag = ptyTag(id);
    try std.testing.expect(isPtyTag(tag));
    try std.testing.expect(!isPtyTag(TAG_LISTEN));
    try std.testing.expect(!isPtyTag(TAG_CLIENT_BASE));
    try std.testing.expect(!isPtyTag(TAG_SIGNAL));
    try std.testing.expectEqual(id, paneIdFromTag(tag));
}

test "handleCommand dispatch (unit smoke)" {
    // Verify that command ID integer encoding matches what the client sends.
    // Client sends: [cmd_byte] [optional payload...]
    // Server receives payload[0] as CommandId raw byte.
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(protocol.CommandId.split_horizontal));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(protocol.CommandId.split_vertical));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(protocol.CommandId.close_pane));
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(protocol.CommandId.detach));
    try std.testing.expectEqual(@as(u8, 0x21), @intFromEnum(protocol.CommandId.quit));
}
