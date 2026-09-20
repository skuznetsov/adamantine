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
- Bounded quick file opening, per-file EditorConfig preferences, and project
  session restoration
- Find in file, bounded project search, replace, marks, and jump history
- Undo and redo across normal editor input
- Background detection of external file changes with reload, keep, and guarded
  overwrite choices
- Private periodic checkpoints of unsaved buffers, with explicit recovery as
  separate files after a crash
- Built-in dark, light, and high-contrast themes, plus JSON theme files
- LSP diagnostics, hover, signatures, definitions, references, semantic tokens,
  and code folding, plus plain-text completion insertion and code-action previews
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
| Search actions / command input | `F1` or `Ctrl+Shift+P` / `Esc Esc` |
| Quick file opener | `Ctrl+P` |
| Quick actions | `Shift+Enter` |
| Save | `Ctrl+S` |
| Review external file changes | `Ctrl+Shift+E` |
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
| Problems | `Ctrl+Shift+M` |
| Next / previous diagnostic | `Alt+N` / `Alt+P` |
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
without interrupting typing or opening a popup. Press `Ctrl+Shift+E`, choose
**Review external changes** from Quick Actions, or run `external` in the F1
palette. Save on an unresolved conflict also opens review instead of writing.

The inline comparison labels `- Editor` and `+ Disk`. Tab/Shift+Tab selects
**Later / Reload from disk / Overwrite disk**, and Enter confirms; Later is
selected initially and Escape also defers the decision. Arrows/PageUp/PageDown
scroll the comparison. Reload remains undoable; Overwrite explicitly writes
your editor text to disk. A newer editor or disk revision invalidates the
decision and requires fresh review. Later leaves both versions unchanged and
the conflict unresolved. Unavailable or non-text disk contents are identified
explicitly, not shown as an empty file. Whole-file comparisons can be coarse,
and very long displayed lines are visibly abbreviated.

### Quick file opener

Press `Ctrl+P`, type a fuzzy filename/path query, select with Up/Down, and
press Enter to open; Escape cancels. Existing unsaved tabs are reused.
The opener indexes paths only, skips dependency/VCS directories and symlinks,
and shows up to 100 ranked matches. Traversal is bounded to 10,000 entries and
16 levels; an incomplete scan is visibly marked partial, even with no matches.
Close and reopen to refresh the index. Query input is limited to 256 characters.
See [workflow boundaries](docs/WORKFLOW_FRONTIER.md) for limits.

### Command palette

Press **F1** and search by ordinary words, for example `open settings` or
`formatting`. Up/Down select an action; Enter runs it; Tab prepares its command.
Actions needing an argument (such as Rename or Open File) prepare the command
for you to finish. Escape cancels. Shortcut hints follow your configured keymap.
An action shown as `unbound` is not reachable by an old default shortcut.
When a shared action is unavailable, the selected action shows its current
reason; Enter and Tab leave it open instead of dispatching it.

For explicit commands, type `:` first, or use **Esc Esc**, which inserts it.
In command mode Enter executes exactly what you typed. Alt+Up/Alt+Down recall
command history; ordinary Up/Down also recall history in command mode. Force
quit is deliberately absent from action search and requires explicit `:q!`.

```text
:w                         save
:q                         close the active tab
:quit                      quit, reviewing unsaved files first
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
:format                    preview LSP formatting of the active document
:external                  compare editor text with external disk changes
:rename new_name           preview a current-file symbol rename via LSP
:quickfix                  choose an LSP quick fix, then preview its edits
:git                       browse Git status, history and diff (read-only)
```

`/pattern` opens forward search directly. After closing the search panel, `n`
and `N` repeat the search forward and backward.

### Quick Actions

Press **Shift+Enter** for contextual actions: search, LSP navigation, Format,
Rename, Quick Fix and external-change review. The first four search entries
keep their positions. Use Up/Down and Enter, or digits 1–9 for the numbered
entries; longer menus scroll with the selection. Escape cancels. Hints marked
`global:` describe shortcuts outside the menu, not extra menu selection keys.

Unavailable entries stay visible with a `!` marker and the selected reason.
Availability is checked again when you choose an action. Typing, paste and
mouse input cannot edit the document behind the menu; F1 can replace it with
action search. Format and refactoring still require explicit preview acceptance
and never save automatically.

### Formatting preview

`:format` requests formatting from the connected language server, using the
active document's indentation settings. The server must advertise document
formatting support. Proposed changes appear inside the editor pane: red `-`
lines are removed and green `+` lines are added, with surrounding source context.
Enter accepts the whole proposal; Escape rejects it. Up/Down and Page Up/Down
scroll, Home/End reach the document ends, and Tab/Shift-Tab jump between changes.
Review does not modify the live buffer. Acceptance is one Undo transaction and
never saves automatically. Long or wide rows show explicit truncation; changed
rows identify their line endings. Stale, malformed or overlapping edits are
rejected as a whole. See [inline review boundaries](docs/INLINE_PREVIEW_FRONTIER.md)
and [safe edit boundaries](docs/SAFE_EDITS_FRONTIER.md).

### Rename and Quick Fix

Place the cursor on a symbol and run `:rename new_name`. Use `:quickfix` to
request fixes at the cursor; arrows choose an action and Enter opens its
inline preview. As with formatting, Enter accepts all, Escape rejects and one
Undo restores the previous document. Tab navigates changes; it does not apply.
The connected server must advertise
the requested capability and provide the actual edits.

This first slice accepts **current-document edits only**. If any edit targets
another file, the whole operation is rejected, even when that file is already
open. File creation/deletion/renaming, server commands, disabled actions and
lazy action resolution are not supported. Nothing is saved automatically.
The action list and preview are bounded with visible truncation. Quick Fix
currently sends an empty diagnostic context; servers that depend on diagnostic
code/data may return no actions. See [refactoring boundaries](docs/REFACTOR_FRONTIER.md).

### Git browser

`:git` opens a read-only browser for the current project's repository. Tab
switches status/history (`s` and `l` also select them); arrows select a row and
Enter opens its diff. Escape returns from diff or closes the browser; `r`
refreshes. The status shows both index and working-tree codes; file diffs
separate staged and unstaged changes. This is **disk/index state**, not unsaved
editor content. Untracked file content is not loaded as a diff.

The commit model and approximate branch-lane display are adapted from
Crystal Ball's Git browser. Reads are bounded and cancellable, with visible
errors/limits; no staging, checkout, merge, network operations or repository
configuration writes are offered. See [Git view boundaries](docs/GIT_VIEW_FRONTIER.md).

In-file find reads the piece-tree buffer in bounded chunks. Files above 64 KiB
are searched cooperatively after a short debounce; newer queries cancel stale
work. The live list is capped at 200 matches and labeled partial at the cap,
while `n`/`N` can reach later matches and wrap within a single line. These limits
are currently fixed. Search preserves original Unicode character positions,
including case-insensitive matches whose lowercase representation grows.

Replace scans bounded chunks and prepares edits on a separate piece-tree root;
one successful command is one Undo/Redo step. Preview shows at most five bounded
samples labeled with original byte offsets. Replacement remains literal, with
the existing regex case/backreference behavior for `i` (not Find's lowercase
matching). Safety limits reject the entire operation without changing text or
history: 16 KiB query, 1 MiB replacement argument, 100,000 matches, and output
no larger than the greater of 16 MiB and the current buffer. Backreference
expansion also has a conservative 16 MiB per-match bound. These limits are
currently fixed. Replacement is synchronous; connected LSP servers still
receive one full-text update after commit.

### Project sessions

Closing a changed tab (`Ctrl+W` or `:q`) offers **Save / Discard / Cancel** for
that file. Ordinary quit (`Ctrl+Q` or `:quit`) reviews each changed file before
exiting. The dialog shows the path; Tab or arrows select, Enter confirms, and
Escape cancels. Cancel is selected initially. Discard leaves the source file on
disk unchanged; it is not a command to erase private recovery history.

Cancelling a multi-file quit leaves all tabs open, including files whose
discard was already selected. Any saves explicitly requested earlier remain
saved. Failed saves do not close the file. If an external change prevents Save,
cancel the dialog and resolve that conflict first; Save never implicitly
overwrites an external change. `:q!` remains an explicit force quit.
Discard during quit retains the normal session tab list: those files reopen
from disk at the next launch, not from their discarded editor text.

On normal editor startup, Adamantine restores the project's open tabs, active
tab, cursor and viewport. A successful quit saves this UI metadata; a cancelled
quit does not. Switching projects with `:cd` saves the old project's view and
restores the new project's view without closing existing tabs or replacing
unsaved edits. Files are reopened from their **current disk contents**: missing,
binary or oversized files are skipped with a message, and positions are clamped.

Session metadata contains paths and positions, not document text or Undo history.
Unsaved-text recovery remains separate. Set `ADAMANTINE_SESSION=0` to disable
session restoration and persistence. Use `ADAMANTINE_STATE_HOME` to choose the
state directory; otherwise it uses `$XDG_STATE_HOME/adamantine` when absolute,
or `~/.local/state/adamantine`. Session files live in its private `sessions`
subdirectory and are not encrypted.

Limits are 128 tabs, 1 MiB of metadata, 16 MiB per restored file and 64 MiB of
source bytes per restoration. These are not a total memory limit, especially
when a language server is running. Concurrent editor instances use the last
successful snapshot; sessions are not merged. See the
[workflow boundaries](docs/WORKFLOW_FRONTIER.md).

### Unsaved buffer recovery

While the editor is running, modified file-backed buffers are periodically
checkpointed outside the project (a pass runs roughly every two seconds).
State lives under `$XDG_STATE_HOME/adamantine/recovery` when `XDG_STATE_HOME` is
absolute, otherwise under `~/.local/state/adamantine/recovery`.
Abandoned sessions are discovered at startup
and with `:recover`; another running editor's snapshots are not offered.
Each draft has three separate actions. `Review draft (read-only)` opens a
detached, non-mutating comparison of the captured editor text, current disk
contents and checkpoint wherever those sources are available. Use `Tab` and
`Shift-Tab` to cycle pairwise views, arrows/Page Up/Page Down/Home/End to move,
and `Escape` to close. A standalone checkpoint view remains available when the
original file was deleted. Review never creates a copy, reloads or overwrites a
file, edits a buffer, or deletes the checkpoint.

`Open recovered copy` creates an independent private copy, leaving both the
original file and checkpoint untouched. This also works when the original was
changed or deleted. `Discard checkpoint` is a separate explicit deletion;
dismissing the menu keeps the checkpoint.
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

The header shows connection health. Use `:lsp` for details and `:lsp restart`
to reconnect the configured server without reopening files. Unexpected
transport failures trigger at most three automatic retries (250, 500 and
1000 ms backoff); a successful handshake does not reset that budget. Manual
restart or a project-root change starts a new budget. `--no-lsp` stays disabled:
restart never discovers a new executable.

Recovery sends current unsaved text to a fresh server and leaves buffers and
Undo intact. Old diagnostics and semantic/folding results are invalidated;
lexical highlighting remains available. Initial startup is still synchronous,
and existing pipe-write/stop timeout limits apply. See the
[recovery boundary and tests](docs/LSP_RECOVERY_FRONTIER.md).

LSP capabilities depend on the selected server. The editor remains usable
without one. Crystal-family buffers have a bounded, background lexical layer
for keywords, identifiers, decimal numbers, hash comments and ordinary quoted
strings. LSP semantic tokens take priority. This is not a full grammar:
ambiguous percent literals, backticks and `<<` conservatively leave the rest
of the file plain until LSP supplies tokens. Very long or token-dense lines
may also remain plain. See [lexical limits and evidence](docs/LEXICAL_FRONTIER.md).

In the F9 completion list, Up/Down selects, Enter or Tab inserts,
and Escape cancels. These physical modal controls remain safety/navigation
guards even when application bindings are remapped; they are not promises that
the same key is available to the editor widget. Plain-text completions and standard
single-line source `textEdit` ranges are supported, including multiline
replacement text, as one Undo/Redo operation. Stale results, active selections,
snippets, insert/replace edits, additional edits, commands and list defaults
are rejected explicitly. Lists and insertion payloads are bounded; see
[completion limits and verification](docs/COMPLETION_FRONTIER.md).
Rename and eager Quick Fix edits can be reviewed and accepted for the current
document; multi-document workspace edits and server commands remain rejected.

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

F1 opens action search; type `:` to switch to explicit command input. Esc Esc
opens command input with `:` already entered; Escape closes either mode.
Existing custom keymaps take precedence over defaults. If your config already
defines `app.command_palette`, add `"f1"` to that action's binding list to use
the new shortcut.

Keymap entries are sparse overrides. An omitted action inherits its built-in
default; a non-empty string or array replaces it; and an explicit empty array
unbinds it and remains unbound after restart. For example:

```json
{
  "keymap": {
    "app.save": [],
    "app.undo": ["alt+u"]
  }
}
```

Empty strings, `null`, and arrays with no valid bindings are invalid and keep
the built-in default (with a warning). In **F10 → Settings**, select a key
binding and press physical **Delete** or **Backspace** to request an unbind;
Enter/Y confirms and N/Escape cancels. Rebinding onto a key lists every
same-context owner before confirmation. Settings, Help, action search and
Quick Actions all show the effective map, including `unbound` and conflict
status. Modal dialogs keep documented physical Escape/Enter/arrows/Tab recovery
and navigation controls where applicable, and clipboard/editor Tab guards stay
active even when their application actions are unbound.

### Indentation

In **F10 → Settings**, change the default indentation width (1–8, default 2)
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

Text layout uses terminal display cells: existing tabs advance to tab stops,
wide characters occupy two cells, and combining/emoji sequences are rendered
as graphemes. Left/Right and Delete/Backspace operate on whole graphemes.
Mouse hit testing and horizontal scrolling use the same layout. Internal
cursor/search positions remain codepoint-based; LSP positions are converted
at the UTF-16 boundary. Terminal/font width differences can still affect
appearance. Visible-prefix rendering avoids whole-document copies; moving
deep into a single enormous line still scans its prefix synchronously.

Enter copies the whitespace prefix before the cursor or start of the selected
range; it does not infer nesting from language syntax. Existing tab prefixes
are preserved. Without a per-file override, new indentation uses spaces.
Automatic indent detection and a separate literal-tab insertion mode are not
supported.

### EditorConfig

Per-file `.editorconfig` settings override the F10 defaults. Closer files and
later matching sections win; `root = true` stops ancestor lookup and `unset`
removes an inherited property. Supported properties are `indent_style`,
`indent_size` (1–8 or `tab`), `tab_width` (1–8) and `end_of_line` (`lf`, `crlf`,
`cr`). Tab display width and indentation width are independent.

```ini
root = true
[*.cr]
indent_style = space
indent_size = 2
end_of_line = lf
```

Preferences affect newly inserted whitespace and line breaks, never an
implicit whole-file conversion. Existing mixed line endings survive open,
save and Undo. Opening a file, reapplying a theme, or changing F10 editing
settings refreshes overrides; configuration files are not watched continuously.
Unsupported values produce warnings and unknown properties are ignored.
This is a bounded supported subset, not full EditorConfig conformance;
see [`docs/WORKFLOW_FRONTIER.md`](docs/WORKFLOW_FRONTIER.md) for limits.

### Problems navigation

Problems always lists diagnostics retained by every currently open file,
ordered by severity, path and position. If the active language server also
advertises LSP workspace diagnostics, the same action asynchronously adds its
reports for unopened files and labels the view **Server Workspace**. This means
"reported by the server", not proof that every project file was checked. Rows
use project-relative paths where possible.

Use arrows and Enter to navigate, or Escape to close. Open tabs are reused
without rereading their text. An unopened server result is opened only after
Enter, and only when its canonical file is still unchanged, readable, regular,
within the project root and below the file-size limit. Alt+N/Alt+P remain
current-file actions: they visit that file's diagnostics in source order and
wrap. These actions are remappable.

Edits, closed buffers, replacement publications and LSP replacement invalidate
old rows. Versioned notifications must match the target buffer; servers
omitting versions cannot guarantee freshness. Live open-buffer diagnostics
remain authoritative over a workspace report for the same file, including
symlink and hard-link aliases.

The view retains at most 1000 rows and is visibly partial when a source or hard
bound was truncated. Workspace parsing examines at most 4096 document reports
and 4096 diagnostics; individual push responses inspect at most 1000 items.
Messages retain at most 4096 codepoints. A server without the exact static
workspace-diagnostic capability keeps the existing **Open Files** view. No disk
scan, automatic fix or source read occurs merely by opening Problems.

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

Large-file and stalled-LSP regression scenarios are available separately:

```sh
ruby scripts/verify_responsiveness.rb --list
ruby scripts/verify_responsiveness.rb --self-test
ruby scripts/verify_responsiveness.rb
```

The complete run builds release probes for multi-megabyte many-line and
single-line search, highlighting, replacement and inline preview, then runs
the asynchronous LSP transport scenarios. It emits one JSON report. Timings,
allocation counters and best-effort peak RSS are diagnostic observations, not
portable performance thresholds; behavioral checks, report validation and the
hung-process watchdog determine pass/fail. The same runner executes weekly and
can be started manually in GitHub Actions.

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
The scheduled responsiveness runner now covers representative multi-megabyte
and huge-single-line operations, but end-to-end input-to-render latency,
filesystem watcher latency, cross-platform terminal quirks, packaged binaries,
and compatibility across language servers remain active areas of work.

The ordered improvement plan and its verification boundaries are tracked in
[docs/EDITOR_ROADMAP.md](docs/EDITOR_ROADMAP.md).

## License

[MIT](LICENSE)
