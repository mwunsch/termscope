# CLAUDE.md

termscope is a headless terminal emulator CLI — "Playwright for the terminal." It uses libghostty-vt as its VT engine.

## Build and test

Requires Zig 0.15.x.

```
zig build
zig build test
zig build run -- --version
```

The ghostty dependency is fetched automatically on first build.

## Quick verification

```bash
# Snapshot
./zig-out/bin/termscope snapshot -- echo hello

# JSON snapshot
./zig-out/bin/termscope snapshot --format json -- echo hello

# Exec with assertions
./zig-out/bin/termscope exec --expect "hello" -- echo hello

# Session mode (JSON-lines over stdin/stdout)
echo '{"id":1,"method":"query"}' | ./zig-out/bin/termscope session -- cat
```

## Architecture

```
src/
  main.zig        CLI: arg parsing, subcommand dispatch (snapshot, exec, session)
  config.zig      Config struct, TTY size detection, env var assembly
  pty.zig         PTY lifecycle: forkpty, read/write, resize, close
  terminal.zig    libghostty-vt wrapper: create, feed, query state, format
  input.zig       Emacs key notation → escape sequence bytes
  snapshot.zig    Terminal state → text/spans/json formats
  wait.zig        Polling: wait_for_text, wait_for_idle, wait_for_cursor
  session.zig     JSON-lines protocol loop for session mode
```

## How it works

1. `pty.zig` forks a child process in a pseudo-terminal via `forkpty()`
2. `terminal.zig` creates a libghostty-vt terminal and feeds PTY output into it
3. The ghostty terminal processes VT escape sequences and maintains screen state
4. `snapshot.zig` reads the terminal state (via ghostty's render state API and formatter) to produce output
5. `input.zig` converts Emacs-style key notation to raw bytes written to the PTY
6. `wait.zig` polls the PTY and terminal for conditions (text match, idle, cursor position)

## Key notation

Uses Emacs-style: `C-c` (Ctrl+C), `M-x` (Alt+X), `RET` (Enter), `TAB`, `ESC`, `SPC`, `DEL`, `<up>`, `<f1>`.

## libghostty-vt C API

The terminal module wraps these key ghostty functions:
- `ghostty_terminal_new/free` — lifecycle
- `ghostty_terminal_vt_write` — feed bytes
- `ghostty_terminal_get` — query cursor, title, screen, etc.
- `ghostty_render_state_update` + row/cell iteration — read styled cells
- `ghostty_formatter_terminal_new` + `ghostty_formatter_format_alloc` — format as text/HTML
- `ghostty_key_encoder_*` — encode key events

## Conventions

- Zig 0.15.x API: `std.ArrayList` is unmanaged (pass allocator to each call), `std.fs.File.stdout()` returns `File`, `writer()` needs a buffer, use `.interface` for formatted printing.
- PTY output → terminal via `feed()`, terminal queries via `getCursor()`, `getTitle()`, `isAltScreen()`, `formatPlainText()`.
- Session protocol: JSON-lines on stdin/stdout, stderr for diagnostics only.
- `renderForFormat` in main.zig and session.zig is the shared rendering path for all formats.

## Deferred

- `--palette` flag: parsed in config but not wired to ghostty's color palette API. Named palettes (solarized-dark, catppuccin-mocha, etc.) are defined in the enum but have no effect yet.
