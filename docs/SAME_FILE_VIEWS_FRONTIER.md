# Same-file split views frontier

Status: implemented and locally verified against `crystal_tui` commit
`7ca26fd559cf8c05e5b4ed924e7c691fabb66e43`; publication and merge are
tracked separately.

Previous frontier: one `OpenBuffer` per path and one `Tui::TextEditor` per
buffer. Two editor groups could show different files, but reopening an existing
path activated its owning group and view. The new implementation retains one
`OpenBuffer` while allowing one view of that document in each editor group.

## Problem and boundary

Same-file views need two independently navigable widgets over one mutable
document. This is a document-model boundary change, not a tab duplication
change. The source currently couples the model and view in `TextEditor`:
`@buffer`, saved snapshot, line ending, dirty state and undo/redo history are
stored beside cursor, selection, scroll and folding state. `EditingTextEditor`
also accesses the inherited buffer directly. `OpenBuffer` owns that editor;
the orchestrator installs one text-change callback on it; app commands and
controllers resolve editors through `buffer.editor`. Creating another editor
or reparenting the existing widget would therefore either fork text/history or
share one widget's cursor and parent.

The previous behavior was fail-closed and intentional: an already-open path
was routed to its owning group, so no unsaved text was lost. Same-file split
support retains that document-identity guarantee while adding a second view.

## Design laws

- There is one live document per normalized path/URI. It owns the piece-tree
  root, saved state, line-ending policy, dirty state, and a single linear
  undo/redo history.
- Each pane tab has a distinct view/widget over that document. Cursor,
  selection, horizontal/vertical viewport, and collapsed-fold state are per
  view. Document edits update every view without replacing their independent
  navigation state.
- Undo and redo are document-wide and ordered across views. Invoking Undo in
  either view reverses the latest document edit. Cursor restoration or
  transformation is view-aware; restoring the editing view's historical
  cursor must not move the other view's cursor.
- A logical edit, undo, or redo produces one document change event. The app
  increments the document version once and sends one LSP `didChange`; LSP
  `didOpen`, diagnostics, semantic tokens, file watching, external-change
  review, and recovery remain document-scoped.
- Closing one of multiple views removes only that view. It must not stop the
  document watch or send LSP `didClose`. Closing the final view follows the
  existing dirty-document confirmation and retires the document exactly once.
- Text is never copied between independent editors as a synchronization
  strategy. No view may silently become an independent source of truth.

## Smallest implementation sequence

1. **Attest the dependency source.** Before this change, the application
   `shard.yml` and `shard.lock` both pinned `crystal_tui` to
   `d62a49e738ee765dc17e2d05023ee455718d6942`.
   On 2026-09-24, the local Shards cache at
   `~/.cache/shards/github.com/skuznetsov/crystal_tui.git` contained the exact
   pinned commit and its source. The neighboring `crystal_tui` checkout is
   still at `2678aa6`, 15 commits behind its `origin/main`, and has an unrelated
   untracked `.crystal-cache/`; it is not the pinned source. The ignored
   installed `lib/crystal_tui` tree is also not byte-identical to the pin:
   four `src` files differ, including a one-line `replace_text` guard change.
   The existing app test run therefore establishes behavior of that installed
   tree, not the pinned commit. Work from an isolated checkout of the exact
   cached commit, test the new dependency against the app explicitly, and do
   not overwrite either pre-existing checkout or installed tree while
   resolving this discrepancy.
2. **Separate model from widget in `crystal_tui`.** Add a document object that
   owns the piece tree, saved snapshot, line ending and shared undo/redo. Make
   editor widgets views that reference that object and own navigation/layout
   state. Preserve a one-view construction path for existing callers. Add
   library specs for two views sharing one root, independent cursors, immediate
   cross-view text updates, and one ordered shared undo/redo history. This is a
   dependency API change and cannot be safely replaced by an Adamantine-only
   wrapper around two existing `TextEditor`s.
3. **Move Adamantine lifecycle to document identity.** Keep one path-keyed
   `OpenBuffer` (or successor document record) for LSP version/state, file
   watching, diagnostics, overlays and recovery. Add explicit view records
   keyed by pane/tab identity; make active-view lookup return the selected
   widget, while document lookup remains path-based. A second-group open of an
   existing path creates/selects a view over the existing document without a
   disk reread or second `didOpen`.
4. **Route edits and lifetime once.** Attach the LSP/change publisher to the
   shared document event, not to each view callback. Update save/dirty labels,
   close confirmation, recovery, external-file handling and session restore
   to distinguish closing a view from closing the final document view. Keep
   distinct-file split behavior unchanged.

These steps cross the dependency and application repositories and touch many
consumers of `buffer.editor`. The implementation uses a shared
`Tui::TextEditor::Document`, document-scoped publication, and per-group view
widgets; it does not synchronize independent text copies. The app retains the
canonical editor accessor for document-scoped consumers and resolves the
mounted widget for active-view actions. The dependency commit and application
pin must be published together before release.

## Falsifier roster

The app integration spec is
`spec/same_file_views_integration_spec.cr`. It uses an isolated temporary
workspace and a recording LSP client to:

1. Open one file in the left group, create the right group, then open that same
   path from the right group.
2. Require one document in the session, the same path in each group's tabs,
   and group 2 to remain active. This assertion was the initial red gate: the
   previous behavior yielded `[[path], []]` and active group 0.
3. Require distinct widget identities and
   a shared document identity; place the cursors at different positions; edit
   in each view and require both widgets to show each committed text state
   immediately while preserving the other view's cursor.
4. Undo from the first view after edits in both views and require the latest
   edit to be undone once, then redo once. Count one document change/version
   advance for each edit/undo/redo. With a recording LSP sink, require one
   `didOpen`, one `didChange` per operation with increasing versions, no
   `didClose` after closing one view, and exactly one `didClose` after the
   final view closes.

The integration gate is not proved by a duplicated-tab assertion or by
library-only tests. Separate specs also cover view-state rebasing, session
restore, right-view LSP actions, and distant lexical viewports.

## DoD and residual boundary

Before release, the focused library and app falsifiers above must pass,
then the existing split, save/close, recovery, external-change, LSP and full
Crystal specs, formatting, diff check and release build must pass. The narrow
guard is that edits and Undo/Redo from either view emit exactly one
document-level change while both views converge on the same snapshot. The
primary rollback is reverting the atomic app feature and restoring its
compatible pinned library dependency. Full document replacement and
undo/redo conservatively clamp sibling navigation state rather than deriving
an expensive diff from snapshots; incremental edits rebase sibling cursor and
selection anchors. The original `crystal_tui` mouse-spec failures are tracked
separately from this feature's regression gates.

The committed library change passed its 18 shared-document examples and a
related 61-example editor/piece-tree subset. Its full suite ran 695 examples
with four failures, all in the same mouse-spec cases reproduced on the
untouched baseline, and no errors. A retired view is also barred from saving
its stale document over the live disk path. The application pin identifies
this exact library commit; publication remains a separate gate.

The final application suite passed 1,146 examples with zero failures, errors,
or pending examples against the pinned library source. The release build passed
with three existing `Time.monotonic` deprecation warnings. A concurrent build
and spec attempt collided in Crystal's temporary cache; the suite was rerun
sequentially to the clean result above.

This record becomes stale if the dependency source, `TextEditor` ownership,
`OpenBuffer` identity, split routing, or LSP document lifecycle changes.
