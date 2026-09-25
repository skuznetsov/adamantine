# Same-file split views frontier

Status: proposed; no same-file view behavior is admitted yet.

Current frontier: one `OpenBuffer` per path and one `Tui::TextEditor` per
buffer. Two editor groups may show different files. Opening a path that is
already open activates its existing owning group and view.

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

The current behavior is fail-closed and intentional: an already-open path is
routed to its owning group, so no unsaved text is lost. Same-file split support
must retain this guarantee while adding a second view.

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

1. **Attest the dependency source.** The application `shard.yml` and
   `shard.lock` both pin `crystal_tui` to `d62a49e738ee765dc17e2d05023ee455718d6942`.
   The earlier task-context reference to `c70a542` is not verifiable as the
   identity of the live `lib/crystal_tui`: local
   `git -C lib/crystal_tui rev-parse --show-toplevel` resolves to the
   application repository, and the source is ignored there. The neighboring
   `crystal_tui` repository inspected on 2026-09-24 is at
   `2678aa646a2429cf2cb735b9c79e7f9dbdc434f5`; neither
   `c70a542` nor the pinned `d62a49e` object is available in that repository.
   Its worktree has an unrelated untracked `.crystal-cache/`, and its
   `TextEditor` source differs from the ignored installed copy. Thus the
   lockfile records the declared resolution, but the code currently compiled
   from `lib/crystal_tui` cannot be tied to either revision from local
   metadata. Before changing this dependency, identify and record the exact
   source used by `crystal spec`/`crystal build`; do not infer API compatibility
   or rewrite the pin from the short hash.
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
consumers of `buffer.editor`. A type-only foundation in
`document_types.cr`/`document_session.cr`/`document_orchestrator.cr` would not
share the piece tree or history, so it is not an admitted partial
implementation. No production code or dependency pin change is included in
this proposal.

## Falsifier roster

The first app integration spec should be named
`spec/same_file_views_integration_spec.cr`. It is intentionally not checked in
as a red test while this feature is unimplemented. With an isolated temporary
workspace and LSP command disabled, it should:

1. Open one file in the left group, create the right group, then open that same
   path from the right group.
2. Require one document in the session, the same path in each group's tabs,
   and group 2 to remain active. On today's source the request returns to the
   path's owner; this assertion should fail with the existing shape
   `[[path], []]` and active group index 0 (the left group), proving that the
   feature is absent without labeling the current safe reroute a data-loss bug.
3. After the document/view API exists, require distinct widget identities and
   a shared document identity; place the cursors at different positions; edit
   in each view and require both widgets to show each committed text state
   immediately while preserving the other view's cursor.
4. Undo from the first view after edits in both views and require the latest
   edit to be undone once, then redo once. Count one document change/version
   advance for each edit/undo/redo. With a recording LSP sink, require one
   `didOpen`, one `didChange` per operation with increasing versions, no
   `didClose` after closing one view, and exactly one `didClose` after the
   final view closes.

The first two assertions are the red integration gate for the capability. The
remaining assertions are required before the app admits same-file views; they
are not proved by a duplicated-tab assertion or by library-only tests.

## DoD and residual boundary

For implementation, the focused library and app falsifiers above must pass,
then the existing split, save/close, recovery, external-change, LSP and full
Crystal specs, formatting, diff check and release build must pass. The narrow
guard is that edits and Undo/Redo from either view emit exactly one
document-level change while both views converge on the same snapshot. The
primary rollback is reverting the atomic app feature and restoring its
compatible pinned library dependency. Until dependency provenance is resolved
and these gates pass, supported behavior remains one view per open document.

This proposal becomes stale if the dependency source, `TextEditor` ownership,
`OpenBuffer` identity, split routing, or LSP document lifecycle changes.
