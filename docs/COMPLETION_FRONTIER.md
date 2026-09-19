# Completion insertion frontier

Status: slice 4 locally verified on 2026-09-19, based on `9a6a5ed`.

The previous completion was a read-only label popup. This slice admits mutation of
the current document only, when the user explicitly accepts a selected item.
CAUTION: a server result gains local edit authority. Rollback: atomic feature
commit. No workspace edits, command execution, snippets, or implicit acceptance.

## Supported contract

- Up/down select; Enter or Tab accepts; Escape cancels. Selection stays visible
  in a bounded viewport. All completion-modal keys are isolated from the
  underlying editor. Other popup behavior remains compatible.
- Plain-text `insertText` or label fallback replaces the ASCII identifier prefix up
  to the captured cursor, not an arbitrary current selection. A standard
  `textEdit` takes precedence, uses UTF-16 positions, spans one source line,
  and contains the request position. Replacement text may contain newlines.
- Use slice 3 strict range conversion: reject negative/out-of-document,
  reversed and surrogate-interior ranges. Validate everything before mutation.
- Reject snippets, insert/replace variants, additional edits, commands and
  non-default indentation modes explicitly; do not silently apply only a
  subset. Do not advertise unsupported capabilities. Reject unsupported
  list defaults rather than misinterpret them as ordinary insertion.
- Acceptance revalidates client/project, buffer/editor identity, URI, version,
  request generation and cursor. A selection change also invalidates acceptance.
  One accepted edit is exactly one Undo/Redo operation with ranged LSP sync.
- Bound item count, displayed labels and insertion bytes; invalid or oversized
  results leave text, history and selection unchanged with an actionable notice.

Limits: parse at most 100 items, display at most the configured request count
(30 by default), retain 512-codepoint labels/filter text, 2048-codepoint details
and 256 KiB insertion payloads. Popup detail rendering is further capped at 256
codepoints. Prefix fallback uses ASCII letters, digits and underscore; Unicode
identifier replacement requires a server-provided `textEdit`. Source-line and
UTF-16 conversion work remains synchronous and line-size-dependent; the fallback
does not additionally allocate a whole-line character array. Ignored modal keys,
paste and mouse events neither edit the underlying buffer nor accept a result.

Primary reference (read 2026-09-18):
https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/language/completion.md

## Implementation and falsifiers

Own parser models in `lsp_client.cr`, popup state/input/rendering in
`lsp_popup_state.cr` and `modal_manager.cr`, acceptance in `lsp_controller.cr`
with an application-owned editor transaction helper. Keymap changes are
limited to explicit completion actions and must preserve remapping.

Integration guard: `App#on_capture` currently invalidates interactive requests
on every key or mouse event. A visible completion needs its own captured
acceptance context, or an explicit modal exception for selection/accept/cancel
keys; otherwise the acceptance key itself makes the result stale. Do not
disable invalidation globally. Bracketed paste and mouse edits must remain
isolated from the focused editor underneath the popup.

First red: accepting a completion currently cannot modify the document.
Cover textEdit precedence, label/insertText fallback, Unicode before range,
multiline inserted text, CRLF, Undo/Redo, malformed/unsupported edits, stale
version/cursor/selection/closed-reopened buffer, and popup isolation. Parent
adds independent counterexamples. Full root suite, formatter, diff check,
release build/help must pass. Refresh after coordinate, parser, history or
LSP lifecycle changes; mocked responses do not certify every language server.

Parent counterexamples reproduced before correction: Enter/Tab did not insert,
Backspace leaked into the underlying editor, oversized malformed textEdit payloads
bypassed the insertion retention bound, and Undo restored a range endpoint rather
than the request cursor when a textEdit extended beyond it. Independent checks also
cover UTF-16 surrogate interiors, oversized/reversed/non-containing ranges,
replaced editor/client identities, changed versions/selections, CRLF preservation
and a single ranged LSP change. Small-terminal viewport and remapping tests cover
the application capture path rather than only invoking handlers directly.

Final parent verification: 633 root-suite examples, zero failures/errors;
`crystal tool format --check src/adamantine spec`, `git diff --check`, release
build and executable `--help` passed. Crystal commands used a temporary cache
and `--link-flags=-fuse-ld=/usr/bin/ld` on this macOS host. Scoped adversary
verdict: ROBUST for the supported plain-text subset and tested modal/history
boundaries, not a certification of arbitrary language servers or terminals.
