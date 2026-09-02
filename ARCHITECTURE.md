# Architecture

Crystal Editor is a single-process terminal application built on
[`crystal_tui`](https://github.com/skuznetsov/crystal_tui). The entry point in
`src/editor.cr` parses CLI options and starts `CrystalEditor::App`.

## Main boundaries

- `App` owns the widget tree and composes the editor's controllers.
- `DocumentSession` is the source of truth for open buffers.
- `DocumentOrchestrator` manages file lifecycle, tabs, and document/LSP sync.
- `InputModeController` and `InputRouter` decide which surface owns each key.
- `ModalManager` and the small `*_state.cr` types keep overlays explicit.
- `CommandPalette`, `SearchPanel`, and `NavigationController` implement
  user-facing workflows without owning documents.
- `Lsp::Client` owns JSON-RPC transport; `LspController` translates protocol
  results into editor behavior.
- `Theme`, `KeyConfig`, `LanguageRegistry`, and `LspRegistry` contain policy
  that can be tested without running the terminal UI.

## Event flow

```text
terminal event
    -> crystal_tui
    -> App#on_capture
    -> active modal/input mode
    -> configured action or focused widget
    -> document/navigation/LSP controller
    -> widget state + status log
```

Input modes are stacked. The topmost modal gets the first chance to consume an
event, which prevents menu shortcuts from leaking into search or command text.
Closing a modal restores the previous mode rather than guessing which widget
should become active.

## Documents and LSP

Each open buffer associates a path, URI, language identifier, version, and
`Tui::TextEditor`. Local edits increment the document version and emit
`textDocument/didChange` when a server is connected. Opening, saving, and
closing follow the matching LSP lifecycle notifications.

Protocol transport is intentionally separated from UI policy. The client
parses framed JSON-RPC messages and correlates requests; the controller decides
how diagnostics, semantic tokens, locations, completion items, code actions,
and folding ranges appear in the editor.

LSP integration is optional. Startup with no explicit setting attempts
discovery; `--no-lsp` leaves the editor fully local.

## Safety and responsiveness limits

- `:open` resolves paths within the active project root, including symlink
  checks. `:cd` is the explicit operation that may select a different root.
- Documents larger than 16 MiB and files detected as binary are rejected.
- Project search skips generated/vendor directories, symlinks, and binary or
  oversized files. It caps depth, scanned files, and displayed matches.
- Keymap and theme files are size-limited and fall back to defaults on errors.
- Optional LSP failures are reported in the status log without terminating the
  editor.

## Testing seams

Most behavior is exercised through focused specs around controllers and state
objects. The default verification command is:

```sh
make check
```

It checks formatting, builds the application, and runs the full spec suite.
`make check-lsp` adds an integration handshake against a caller-provided server
executable.
