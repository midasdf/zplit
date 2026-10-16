# zplit

**A terminal multiplexer under 250KB.**

Written in Zig. Zero dependencies. Statically linked. Light enough to run where others won't.

![zplit screenshot](docs/screenshot.png)

## Why

Measured on Raspberry Pi Zero 2W (aarch64, Arch Linux ARM), March 2026:

| | zplit | tmux 3.6a | zellij 0.43.1 |
|---|---|---|---|
| Binary | **229 KB** | 1.3 MB | 44 MB |
| Language | Zig | C | Rust + WASM |
| Runtime deps | **0** | libevent, ncurses, etc. | curl, glibc, zlib, etc. |
| Text reflow | Yes | No | Yes |
| CJK width | Yes | Yes | Yes |

> zplit binary = static aarch64 `ReleaseSmall` (234,512 bytes). tmux/zellij = installed size from `pacman -Si`/`pacman -Qi` on aarch64.

## Features

- **Pane splitting** — horizontal, vertical, resize, focus navigation
- **Tabs** — create, close, switch
- **Session persistence** — detach/attach, layout saved on detach/quit
- **Zellij-style modes** — NORMAL, PANE, TAB, SCROLL, SESSION, LOCKED
- **Text reflow** — content reflows when terminal width changes
- **Scrollback** — preserved on screen clear, scroll mode to browse history
- **CJK support** — fullwidth characters, Japanese input (fcitx5)
- **Terminal emulation** — SGR colors (256 + RGB), alternate screen, DA1/DSR
- **Ncurses support** — colon-form SGR, scroll regions, `ESC 7`/`ESC 8` save-and-restore, absolute cursor addressing, and terminal query replies
- **Alternate screen** — vim, htop, etc. restore correctly on exit
- **Single binary** — client/server in one executable, zero runtime dependencies

## Install

### Build from source

```bash
# Requires Zig 0.16+
git clone https://github.com/midasdf/zplit.git
cd zplit
zig build -Doptimize=ReleaseSmall
# Binary at zig-out/bin/zplit (~230KB)
```

#### System-wide

```bash
zig build -Doptimize=ReleaseSmall
install -m 755 ./zig-out/bin/zplit $HOME/.local/bin/zplit
```

### Cross-compile for ARM

```bash
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-gnu
# Static binary, runs on any aarch64 Linux
```

## Usage

```bash
zplit                    # Start new session
zplit attach <name>      # Attach to existing session
zplit list               # List sessions
```

### Keybindings

All modes return to NORMAL with `Esc` or `Enter`.

| Key | Mode | Action |
|-----|------|--------|
| `Ctrl+p` | → PANE | Pane operations |
| `Ctrl+t` | → TAB | Tab operations |
| `Ctrl+s` | → SCROLL | Browse scrollback |
| `Ctrl+o` | → SESSION | Detach/quit |
| `Ctrl+g` | → LOCKED | Pass all keys to PTY |

**PANE mode:**
`h/j/k/l` focus | `H/J/K/L` resize | `n` split-h | `v` split-v | `x` close

**TAB mode:**
`h/l` switch | `n` new | `x` close

**SCROLL mode:**
`j/k` line | `u/d` half-page | `PageUp/PageDown`

**SESSION mode:**
`d` detach | `q` quit

## Configuration

`~/.config/zplit/config.toml`

```toml
[general]
default_shell = "/bin/fish"
scrollback_lines = 1000
max_panes = 8

[appearance]
status_bar = true
pane_border_style = "single"

[keybinds]
pane_mode = "ctrl+p"
tab_mode = "ctrl+t"
scroll_mode = "ctrl+s"
```

## Architecture

Single binary acts as both client and server, connected via Unix domain socket.

| Client (thin relay) | | Server (owns everything) |
|---|---|---|
| Terminal raw mode | Unix | PTY management |
| Input parser (CSI) | domain | VT parser (custom) |
| Mode state machine | socket | Grid + reflow engine |
| | | Screen compositor |
| | | Tab / Pane tree |

18 source files, ~9700 lines of Zig. No external dependencies.

## License

MIT

## Disclaimer
This project uses AI-generated code (LLM). I do my best to review and test it, but I can't guarantee it's perfect. Please use it at your own risk.\n