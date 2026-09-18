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
- Background detection of external file changes with reload, keep, and guarded
  overwrite choices
- Private periodic checkpoints of unsaved buffers, with explicit recovery as
  separate files after a crash
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
| Copy / cut / paste in the editor | `Ctrl+C` / `Ctrl+X` / `Ctrl+V` |
| Close tab | `Ctrl+W` |
| Undo / redo | `Ctrl+Z` / `Ctrl+Shift+Z` |
| Indent / dedent | `Tab` / `Shift+Tab` |
| Find in file | `Ctrl+F` |
| Find in project | `Alt+F` |
| File tree / editor | `F2` / `F3` |
| Go to definition | `F12` |
| Hover / references / signature | `F6` / `F7` / `F8` |
| LSP actions | `F9` |
| Help | `F5` |
| Quit | `Ctrl+Q` |

Some terminals reserve particular key combinations. Every application action
can be remapped in a JSON keymap; [`keymap.example.json`](keymap.example.json)
is a complete starting point.

Copy and cut retain a shared in-memory clipboard across editor tabs. On macOS,
Adamantine also uses `pbcopy`/`pbpaste` as a best-effort system clipboard bridge;
other platforms currently use the internal clipboard. Helper failures are
reported without discarding the internal copy. `Ctrl+C` is no longer an
implicit quit shortcut; use `Ctrl+Q` to quit. Clipboard actions apply only to
the focused editor, not to a document behind a dialog. Terminal bracketed paste
remains available in the editor.

Clipboard data is limited to 16 MiB and system helpers time out after 250 ms.
If a system copy fails, paste keeps using that internal copy until another copy
successfully reaches the system clipboard. A delayed paste is discarded if you
continue typing, move the cursor, switch tabs, or change the selection first.

When another process changes an open file, Adamantine marks its tab with `!`
and asks whether to reload the disk version, keep the in-memory version, or
overwrite the observed disk revision. Reload remains undoable. Dismissing the
dialog or choosing **Keep my version** does not write anything; the unresolved
marker remains until the file is reloaded or explicitly overwritten.

### Command palette

Open the palette and enter commands without the leading colon shown below:

```text
:w                         save
:q                         close the active tab
:quit                      quit if every buffer is clean
:q!                        force quit (keep available recovery checkpoints)
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
:recover                   list recoverable drafts
```

`/pattern` opens forward search directly. After closing the search panel, `n`
and `N` repeat the search forward and backward.

### Unsaved buffer recovery

While the editor is running, modified file-backed buffers are periodically
checkpointed outside the project (a pass runs roughly every two seconds).
State lives under `$XDG_STATE_HOME/adamantine/recovery` when `XDG_STATE_HOME` is
absolute, otherwise under `~/.local/state/adamantine/recovery`.
Abandoned sessions are discovered at startup
and with `:recover`; another running editor's snapshots are not offered.
Recovery opens a separate copy, leaving both the original file and the checkpoint
untouched. This also works when the original was changed or deleted. Discarding
a checkpoint is a separate explicit action; dismissing the menu keeps it.
Limits are 16 MiB per document and 256 MiB per session, not a global disk quota.
Discovery is bounded; warnings indicate when accumulated state needs attention.

Recovery files are private to your OS account, but **not encrypted**. Set
`ADAMANTINE_RECOVERY=0` before launch to disable recovery for sensitive work.
Checkpoints are not a keystroke journal or an undo-history backup: edits since
the last successful checkpoint can be lost, and power-loss durability is not
guaranteed. See [the recovery scope](docs/RECOVERY_FRONTIER.md).

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

Interactive LSP actions run in background fibers. Editing, cursor movement,
tab switches and popup dismissal discard outdated results. The scheduler keeps
one running action and only the latest queued action; a slow server can delay
that next action until the current request finishes or times out. Server
startup, transport writes and semantic highlighting retain their existing
behavior. See [the async runtime scope](docs/LSP_ASYNC_FRONTIER.md).

## Configuration and themes

Pass a keymap or theme explicitly:

```sh
./bin/adamantine . --config ~/.config/adamantine/config.json
./bin/adamantine . --theme ~/.config/adamantine/theme.json
```

Built-in theme names include `vscode-dark`, `vscode-light`, and
`vscode-high-contrast`. The editor also checks
`~/.config/adamantine/config.json` for its default keymap.

### Indentation

In **F10 → Settings**, change the indentation width (1–8 spaces, default 2)
or toggle auto-indent (on by default). Changes apply to open and future tabs
and are saved in the active config:

```json
{
  "editor": { "indent_width": 2, "auto_indent": true }
}
```

Tab inserts one indentation unit at the cursor or indents selected lines.
Shift+Tab removes up to one unit of leading spaces, or one leading tab. A
selection ending at column zero leaves that last line unchanged. Each command
is one undoable edit. These actions can be remapped as `app.indent` and
`app.dedent`; unbound Tab keys do not fall back to hardcoded editor indentation.
Outside the editor, Tab remains focus navigation.

Enter copies the whitespace prefix before the cursor or start of the selected
range; it does not infer nesting from language syntax. Existing tab prefixes
are preserved, but new indentation uses spaces. EditorConfig, automatic
indent detection, and a literal-tab insertion mode are not yet supported.

### LSP response limit

Open **F10 → Settings → LSP response limit** and press Enter to cycle through
1, 4, 8, 16, 32, and 64 MiB. The default is 16 MiB. Changes are saved to the
active config (`--config`, `ADAMANTINE_CONFIG`, or the default path above) and
apply immediately. Increasing the limit requests highlighting again for the
current file. The config accepts any integer from 1 through 64:

```json
{
  "lsp": { "max_response_mib": 16 }
}
```

Merge this section into your existing config; settings and keymap saves preserve
unrelated keys. This limits an incoming **LSP response body**, not source-file
size or total process memory. Larger values permit more memory use during JSON
parsing. An oversized framed response is discarded without parsing, with a
warning in the status log showing its size, the limit, and where to change it.
Pending requests may fail, but later small requests keep working. Truncated or
stalled responses, or frames exceeding the hard 256 MiB discard cap, disconnect
with a warning. See [the response-limit boundary](docs/LSP_RESPONSE_FRONTIER.md).

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
Project search runs in a cancellable background fiber and intentionally caps
traversal, file size, and result count to keep the UI responsive. Partial scans
are labeled even when no matches are returned; a partial zero is not proof
that the project contains no matches. The current limits are 1 MiB per file,
1,500 scanned text files, depth 16, and 40 results. Skipped unreadable files
also make a scan partial. These limits are not yet configurable in Settings.
Large-file performance, filesystem watcher latency, cross-platform terminal quirks,
packaged binaries, and compatibility across language servers are still active
areas of work.

The ordered improvement plan and its verification boundaries are tracked in
[docs/EDITOR_ROADMAP.md](docs/EDITOR_ROADMAP.md).

## License

[MIT](LICENSE)
