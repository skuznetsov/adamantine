# Adamantine

[![CI](https://github.com/skuznetsov/adamantine/actions/workflows/ci.yml/badge.svg)](https://github.com/skuznetsov/adamantine/actions/workflows/ci.yml)

**A keyboard-first terminal editor built alongside the Adamas compiler.**

Adamantine is written in Crystal and built on
[`crystal_tui`](https://github.com/skuznetsov/crystal_tui). It is intentionally
small and hackable. Adamas is its home toolchain, while language intelligence
comes through LSP, so the editor can also work with Crystal and other languages.

> [!NOTE]
> Adamantine is an early preview. It is useful today, but configuration and
> key bindings may still evolve before the first stable release.

## Highlights

- Multiple files in tabs, a project tree, mouse support, and configurable keys
- Find in file, bounded project search, replace, marks, and jump history
- Undo and redo across normal editor input
- Built-in dark, light, and high-contrast themes, plus JSON theme files
- LSP diagnostics, hover, signatures, definitions, references, semantic tokens,
  and code folding, plus completion and code-action previews
- PATH-based Adamas language-server discovery, with explicit CLI and
  environment overrides
- Written and tested entirely in Crystal

## Quick start

You need Crystal and Shards. The current development baseline is Crystal
1.21.0.

```sh
git clone https://github.com/skuznetsov/adamantine.git
cd adamantine
shards install
make build
./bin/adamantine .
```

Run directly from source while developing:

```sh
make run ARGS="--theme vscode-dark /path/to/project"
```

See all CLI options with `./bin/adamantine --help`.

## Everyday controls

| Action | Default binding |
| --- | --- |
| Command palette | `Esc Esc` or `Ctrl+Shift+P` |
| Quick actions | `Shift+Enter` |
| Save | `Ctrl+S` |
| Close tab | `Ctrl+W` |
| Undo / redo | `Ctrl+Z` / `Ctrl+Shift+Z` |
| Find in file | `Ctrl+F` |
| Find in project | `Alt+F` |
| File tree / editor | `F2` / `F3` |
| Go to definition | `F12` |
| Hover / references / signature | `F6` / `F7` / `F8` |
| LSP actions | `F9` |
| Help | `F5` |

Some terminals reserve particular key combinations. Every application action
can be remapped in a JSON keymap; [`keymap.example.json`](keymap.example.json)
is a complete starting point.

### Command palette

Open the palette and enter commands without the leading colon shown below:

```text
:w                         save
:q                         close the active tab
:quit                      quit if every buffer is clean
:q!                        force quit and discard unsaved changes
:wq                        save and quit
:open path/to/file.cr       open a file inside the project
:cd path/to/project         change the project root
:find pattern               find in the active file
:grep [-i] pattern          search the project
:s/old/new/gic              replace; g=all, i=ignore case, c=preview
:buf [number]               list or select open buffers
:mark name                  create a mark
:jump name                  jump to a mark
:theme vscode-light         switch theme
```

`/pattern` opens forward search directly. After closing the search panel, `n`
and `N` repeat the search forward and backward.

## LSP support

Without an explicit command, Adamantine detects the project language and looks
for compatible server executables on `PATH`, preferring `adamas_lsp`. It never
executes a server discovered inside the project tree; select one explicitly
only when you trust it:

```sh
./bin/adamantine . --lsp crystalline
./bin/adamantine . --lsp crystal-tool-lsp --lsp-arg --stdio
EDITOR_LSP=/path/to/language-server ./bin/adamantine .
./bin/adamantine . --no-lsp
```

`ADAMANTINE_LSP` is the application-specific environment override;
`EDITOR_LSP` is accepted as a generic alternative.

LSP capabilities depend on the selected server. The editor remains usable
without one. Completion and code-action results are currently previews;
Adamantine does not yet apply server-provided completion edits, code actions,
renames, or workspace edits.

## Configuration and themes

Pass a keymap or theme explicitly:

```sh
./bin/adamantine . --config ~/.config/adamantine/config.json
./bin/adamantine . --theme ~/.config/adamantine/theme.json
```

Built-in theme names include `vscode-dark`, `vscode-light`, and
`vscode-high-contrast`. The editor also checks
`~/.config/adamantine/config.json` for its default keymap.

Existing preview installations remain compatible with
`CRYSTAL_EDITOR_CONFIG`, `CRYSTAL_EDITOR_THEME`, `CRYSTAL_EDITOR_LSP`, and the
old `~/.config/crystal_editor` and `~/.crystal_editor` directories. New
installations should use the Adamantine names.

## Development

```sh
shards install
make check
```

`make check` verifies formatting, builds the binary, and runs the full spec
suite. The LSP handshake is deliberately separate because it requires a local
server executable and Ruby:

```sh
ADAMANTINE_LSP=/path/to/server make check-lsp
```

Run `make help` for the complete target list. Contributions and focused bug
reports are welcome; please include your Crystal version, terminal, operating
system, and the smallest reproduction you can provide.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the component boundaries and event
flow.

## Project status

The editor is optimized for source-sized projects and interactive terminal use.
Project search intentionally caps traversal, file size, and result count to
keep the UI responsive. Large-file performance, cross-platform terminal quirks,
packaged binaries, and compatibility across language servers are still active
areas of work.

## License

[MIT](LICENSE)
