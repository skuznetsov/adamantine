# Crystal Editor

This is a terminal (TUI) editor for Crystal with LSP support.

## Build and Run

- Build:
  - `make build`
- Run:
  - `make run ARGS="--theme vscode-light /path/to/project"`
  - or run directly: `./bin/editor /path/to/project`
- Command mode:
  - `Esc Esc` opens command palette.
  - `Shift+Enter` opens quick actions menu (search / replace / LSP actions).
  - `:w` save, `:q` close tab, `:wq` save+quit.
  - `:open <path>` open file.
  - `:theme <name>` apply preset or existing theme file.
  - `:r /old/new/ [gic]` or `:s/old/new/[gic]` replace first match (or all with `g`, ignore case with `i`, preview with `c`).
  - `:buf [1..]` jump to buffer, `:ls` list open buffers.
  - `:cd <dir>` change project root, `:pwd` print current root.
  - `:set theme=<name>` set theme.
  - `:mark <name>` set a mark at cursor; `:marks` list marks; `:jump <name>` jump by mark.

## Development Helpers

- Check LSP connectivity (handshake): `make harness`
  - Uses `scripts/harness.sh`
  - Uses `CRYSTAL_EDITOR_LSP` env var if set, otherwise defaults to:
    `/Users/sergey/PRojects/Crystal/crystal_v2_repo/bin/crystal_v2_lsp`
- One-shot verification:
  - `make check`
- Test suite:
  - `make spec`
- Format check:
  - `make fmt-check`
- Auto format sources:
  - `make fmt`

## Make targets

- `make build` — build `bin/editor`
- `make run ARGS=...` — run editor with arguments
- `make harness` — run LSP handshake harness
- `make spec` — run Crystal specs
- `make check` — run `build`, `spec`, then `harness`
- `make ci` — run full check pipeline (`check`)
- `make fmt-check` — check source formatting without modifications
- `make fmt` — format source files in place
- `make clean` — remove `bin/editor`
- `make help` — show available targets

## LSP Config

- CLI flag: `--lsp PATH`
- Environment:
  - `EDITOR_LSP`
  - `CRYSTAL_EDITOR_LSP`
