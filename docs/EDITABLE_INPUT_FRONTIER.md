# Editable modal input frontier

Scope: one shared, app-owned, single-line input model and renderer for the
command palette, Search and Quick Open. Rename continues to use the command
palette argument path, so domain validation still happens on submit. This
slice does not change the pinned `crystal_tui` dependency or the editor's
multi-line text model.

Risk: CAUTION. Input routing, asynchronous clipboard publication and Unicode
cell rendering cross modal and authority boundaries. Rollback is the single
feature commit; no persistent format or user configuration migration is
introduced.

## Admitted behavior

- Left/Right, Home/End, Shift-selection, Ctrl+A, Backspace/Delete and
  word-oriented Ctrl/Alt navigation operate through one `EditableInput`.
- Cursor positions use Crystal codepoint offsets but always land on an
  extended-grapheme boundary. Deletion and selection never split a combining,
  emoji ZWJ or wide-character grapheme.
- Insertion replaces the active selection atomically. Quick Open retains its
  256-codepoint query bound; rejected typing, bracketed paste and clipboard
  paste leave the complete previous value and show the same limit message.
- Paste is a single logical mutation. CRLF, CR, LF and tab become spaces;
  C0/C1 control characters are discarded while Unicode format characters
  needed by graphemes (including emoji ZWJ sequences) are preserved. Search,
  Quick Open and the command palette own bracketed paste while open, so the
  focused editor underneath is unchanged.
- Copy, cut and paste reuse the bounded clipboard service. An asynchronous
  read publishes only when input identity, modal mode, generation, revision,
  cursor and selection still match the captured target.
- Command history preserves the current draft and restores it after moving
  past the newest history item. Programmatic values place the cursor at the
  end and clear selection.
- The renderer uses grapheme display widths, keeps the block cursor visible,
  applies selection style to complete graphemes and never emits half of a
  wide cell. Widths 1 through 3 and partial repaint clips are explicit tests.

## Rejected or deferred behavior

This is not a general widget-tree migration, multi-line input, IME/preedit
implementation, mouse-drag selection, input-specific Undo stack, clipboard
history, OSC52 transport, or configurable word-boundary policy. General
keymap default/override/unbind semantics remain the next separate slice.
Per-command validation also remains outside the generic model.

## Verification

The primary falsifiers cover combining marks, emoji ZWJ clusters, selection
replacement, atomic query limits, newline/control paste normalization, stale
clipboard callbacks, command-history drafts, all three modal paste routes,
partial clips and compact wide-cell rendering.

Observed on 2026-09-20:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-editable-cache crystal spec \
  spec/editable_input_spec.cr spec/editable_input_renderer_spec.cr \
  spec/command_palette_spec.cr spec/quick_open_ui_spec.cr \
  spec/search_spec.cr spec/search_panel_render_spec.cr \
  spec/clipboard_spec.cr spec/clipboard_terminal_spec.cr \
  spec/clipboard_backend_spec.cr spec/input_router_spec.cr \
  spec/command_palette_authority_spec.cr spec/quick_open_adversary_spec.cr \
  spec/quick_open_backend_adversary_spec.cr \
  --link-flags=-fuse-ld=/usr/bin/ld
# 154 examples, 0 failures

CRYSTAL_CACHE_DIR=/private/tmp/adamantine-editable-full-cache2 crystal spec \
  --link-flags=-fuse-ld=/usr/bin/ld
# 1017 examples, 0 failures

crystal tool format --check src spec
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-editable-build-cache2 crystal build \
  src/adamantine.cr --release -o /private/tmp/adamantine-editable-input-bin \
  --link-flags=-fuse-ld=/usr/bin/ld
ruby scripts/smoke_command_palette.rb /private/tmp/adamantine-editable-input-bin
# PASS, including real left-arrow middle edit and bracketed-paste argument
```

These checks establish the bounded single-line behavior on this source state.
They do not certify every terminal's IME or key-encoding behavior. Refresh the
evidence after changing the model, renderer, key dispatch, modal ordering,
clipboard generation policy, query limit or terminal buffer cell semantics.

Adversary verdict: ROBUST within this bounded scope. Counterexamples for a ZWJ
insertion joining the following grapheme, either half of a pre-existing wide
cell crossing a repaint clip, and a paste containing only discarded controls
are explicit regression tests. IME/preedit and terminal-specific encodings
remain deferred rather than implied by this verdict.
