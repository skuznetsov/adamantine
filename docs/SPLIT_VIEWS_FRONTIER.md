# Split editor frontier

Status: first implementation slice locally verified (2026-09-23). The
split-focused and neighboring specs, full suite, formatter, diff check and
release build passed. The integration suite also covered a standalone snippet
parser added in parallel; it is not wired into completion yet.

The current application owns one `TabbedPanel`, and each `OpenBuffer` owns one
`TextEditor` with its own content, cursor, history and viewport. A second panel
cannot safely display that same widget. This slice adds a second, editable
editor group while preserving a single owner for every open path.

## Admitted behavior

- A discoverable split-right action creates a side-by-side editor group. The
  existing tabs stay in the left group; the right group starts empty. A
  clearly visible active-group indicator and focus-next-group action make
  keyboard and mouse focus legible. A close-split action returns to one group.
- Opening a new path from any navigation entry point adds it to the active
  group. Opening an already-open path selects its owning group and tab; it
  never creates a duplicate editor or rereads unsaved content.
- Tab switching, saving, closing, LSP actions and status/header state operate
  on the active group. Closing the final tab in one group leaves the other
  group intact. Closing a split never discards or silently closes a document;
  tabs in the removed group must move to the surviving group first.
- A terminal too narrow for two useful editor panes must keep a usable single
  view or refuse the split with an actionable notice. The command remains
  keyboard-remappable.

## Rejected or deferred behavior

- The same file in two panes with independent cursors/scroll is deferred. It
  needs a shared document model with separate views, coordinated history and
  LSP lifecycle; reparenting one `TextEditor` or duplicating its text is not a
  correct substitute.
- Arbitrary nested splits, drag-and-drop tabs, and more than two groups are
  deferred. Splitting does not implicitly open a second file.
- Split layout persistence is deferred for this slice. Existing flat session
  metadata remains readable and restores into one group; no version-1 session
  schema is reinterpreted. This limitation must be visible in user docs.

## Safety and verification

Risk: CAUTION (focus, tab ownership and session behavior). Rollback is the
atomic feature commit. The likeliest failure is a command acting on the
visually inactive editor. Tests must discriminate this with two different
files, focus changes, save/close, and reopening an already-open dirty file.
Also test collapse with dirty tabs and the narrow-terminal guard. Relevant
specs, the full suite, formatting, diff check and release build form the DoD;
the observed signal is zero failures and no lost or duplicated buffer.

Final integration verification: 1067 examples, zero failures/errors, including
the right-active collapse regression and standalone parser specs. The release
binary's `--help` command passed. No live LSP server was used to observe
`didClose`; source inspection and retained watch/Undo tests support the narrower
claim that layout collapse does not retire buffers.

This design becomes stale if `OpenBuffer` ownership, `TabbedPanel` parenting,
the session schema, or input focus routing changes; refresh the tests and
contracts at that point. Mocked tests do not certify every terminal geometry.
