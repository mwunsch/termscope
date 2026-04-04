# termscope

Headless terminal emulator CLI powered by [libghostty-vt](https://ghostty.org).

Spawn any command in a real virtual terminal, interact with it programmatically, and capture the state — all from a single binary with zero runtime dependencies. Built for AI agents, CI pipelines, and TUI testing. Inspired by [Playwright](https://playwright.dev)-style automation, but for the terminal.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mwunsch/termscope/main/install.sh | sh
```

Or build from source (requires [Zig 0.15.x](https://ziglang.org)):

```bash
git clone https://github.com/mwunsch/termscope.git
cd termscope
zig build -Doptimize=ReleaseSafe
```

## Quick Start

### Snapshot a TUI

```bash
termscope snapshot -- htop
termscope snapshot --format json -- btop
termscope snapshot --format svg -o screenshot.svg -- my-tui
```

### Interact then capture

```bash
termscope exec \
  --wait-for-text "Search:" \
  --type "hello" \
  --press RET \
  --wait-idle 200 \
  --snapshot \
  -- my-tui
```

### Assert in CI

```bash
termscope exec --expect "Connection refused" -- my-app
# exit 0 if found, exit 1 if not
```

### Drive from an agent (session mode)

```bash
termscope session -- vim test.txt
```

Reads JSON-line requests from stdin, writes JSON-line responses to stdout:

```jsonl
{"id":1,"method":"snapshot"}
{"id":1,"result":{"cols":80,"rows":24,"cursor":[0,0],"screen":"primary","title":"vim","text":"..."}}

{"id":2,"method":"type","params":{"text":"ihello world"}}
{"id":2,"result":{}}

{"id":3,"method":"press","params":{"key":"ESC"}}
{"id":3,"result":{}}

{"id":4,"method":"query"}
{"id":4,"result":{"cols":80,"rows":24,"cursor":[0,12],"cursor_style":"block","cursor_visible":true,"title":"vim","alt_screen":true}}

{"id":5,"method":"close"}
{"id":5,"result":{"exit_code":0}}
```

## Key Notation

Emacs-style, the established standard:

| Notation | Meaning |
|---|---|
| `C-c` | Ctrl+C |
| `M-x` | Alt+X |
| `RET` | Enter |
| `TAB` | Tab |
| `ESC` | Escape |
| `SPC` | Space |
| `DEL` | Backspace |
| `<up>` `<down>` `<left>` `<right>` | Arrow keys |
| `<f1>` … `<f12>` | Function keys |
| `C-x C-s` | Key sequence |

## Output Formats

| Format | Use |
|---|---|
| `text` (default) | Numbered lines, optimized for LLMs |
| `spans` | Text + per-line style runs |
| `json` | Structured JSON |
| `html` | Styled `<pre>` with `<span>` elements |
| `svg` | Visual screenshot |

## Session Protocol

| Method | Params | Response |
|---|---|---|
| `snapshot` | `format?` | Snapshot data |
| `type` | `text` | `{}` |
| `press` | `key` | `{}` |
| `wait_for_text` | `pattern`, `timeout?` | `{found, row, col}` |
| `wait_for_idle` | `duration?` | `{}` |
| `wait_for_cursor` | `row`, `col`, `timeout?` | `{}` |
| `query` | — | Terminal state |
| `resize` | `cols`, `rows` | `{}` |
| `close` | — | `{exit_code}` |

Errors: `{"id":N,"error":{"code":"...","message":"..."}}`. The session continues on errors.

## Agent Skill

```bash
npx skills add mwunsch/termscope
```
