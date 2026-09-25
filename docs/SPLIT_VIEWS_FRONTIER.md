# Split editor frontier

Status: two-group split and persisted group-layout slices implemented. The
split-session slice adds version-2 bounded UI metadata while retaining the
version-1 flat-session reader. On 2026-09-24, focused session/store/App specs
passed (29 examples), the integrated suite passed (1118 examples), formatting,
release build and diff checks passed. `scripts/smoke_split_session.rb` also
passed against that source-linked release binary, covering a wide restart and
narrow-terminal fallback in a real PTY.

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

## Safety and verification

Risk: CAUTION (focus, tab ownership and session behavior). Rollback is the
atomic feature commit. The likeliest failure is a command acting on the
visually inactive editor. Tests must discriminate this with two different
files, focus changes, save/close, and reopening an already-open dirty file.
Also test collapse with dirty tabs and the narrow-terminal guard. Relevant
specs, the full suite, formatting, diff check and release build form the DoD;
the observed signal is zero failures and no lost or duplicated buffer.

The original split-UI slice's integration verification (2026-09-23) was 1067
examples with zero failures/errors, including the right-active collapse
regression and standalone parser specs. Its release binary's `--help` command
passed. No live LSP server was used to observe `didClose`; source inspection and
retained watch/Undo tests support the narrower claim that layout collapse does
not retire buffers.

This design becomes stale if `OpenBuffer` ownership, `TabbedPanel` parenting,
the session schema, or input focus routing changes; refresh the tests and
contracts at that point. Mocked tests do not certify every terminal geometry.

## Persisted group layout (implemented; narrow-layout fallback)

Version 2 persists only bounded UI metadata: whether a two-group split is open,
each tab's group, the selected tab in each group, and the active group. Version
1 retains its original schema and maps to a flat group. Invalid group refs,
selection indices, or active-group combinations fail before any source is
opened. Source text, Undo, LSP state, and dirty-buffer contents remain outside
session storage.

New files restore through the ordinary guarded opener. Missing files are
skipped with an explicit warning while surviving tabs remain open. A terminal
known to be too narrow at restore time gets a one-group restore and warning;
when startup begins before geometry is known, the first narrow layout pass
collapses the provisional split with a warning. Both paths keep the tabs.
Existing dirty buffers keep their current group and editor identity rather than
being moved to match the saved layout; their cursor, viewport, Undo history and
watch remain attached to that buffer. There is still one `TextEditor` per path.

After a degraded split is saved, it is a flat session; widening the terminal on
a later launch does not automatically recreate the split. The user can reopen
it with `:splitright`. The focused falsifiers cover unchanged v1 reads, a v2
round trip with independent pane selections, malformed metadata rejected
without opening sources, missing-file survival, both known-narrow and
first-layout-narrow startup paths, and pre-opened dirty-buffer identity/watch/
Undo retention. The source-linked real-PTY smoke uses a private temporary
project and state root, verifies version-2 metadata after exit, sees both
groups on a wide restart, then sees both tabs and flat metadata after a narrow
restart. This checks only those layouts and one terminal implementation; other
terminal geometry and window-manager behavior remain outside its scope.
Independent views of one document and arbitrary/nested groups remain deferred.
