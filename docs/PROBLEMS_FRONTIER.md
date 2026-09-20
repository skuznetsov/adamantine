# Open-files Problems frontier

Document status: locally verified on 2026-09-19.

Current frontier: replace the current-document Problems snapshot with a bounded
read-only snapshot of diagnostics retained by every live open buffer. Project
coverage remains a later, separately admitted slice.

Bounded context: Adamantine's existing push-diagnostics pipeline, open-buffer
lifecycle, Problems modal and guarded tab navigation.

## Admitted surface

- `Ctrl+Shift+M` / the existing Problems action lists diagnostics from all
  currently open buffers.
- Every row identifies its file, severity, one-based source position, optional
  diagnostic source and message. Paths use a bounded project-relative
  representation when possible and a bounded path representation otherwise.
- Rows are ordered deterministically by severity, file path, position and
  source order. The global retained list remains bounded to 1000 rows.
- `Enter` revalidates the selected buffer, editor, document version,
  diagnostics generation and LSP client before switching to the already-open
  tab and moving its cursor. It does not reread the file.
- An edit, close, replacement publication or LSP-client replacement invalidates
  the affected diagnostics and closes an open aggregate snapshot.
- Empty and partial coverage are visible. Partial means at least one open
  buffer supplied a partial publication or more rows existed than the global
  display bound.
- Existing current-buffer next/previous diagnostic actions retain their local
  source-order behavior; widening those shortcuts is not part of this slice.

## Rejected surface

- No claim of project-wide completeness, unopened-file coverage or workspace
  diagnostic support.
- No disk scan, source-file read, background indexing or persistence of
  diagnostics after a buffer closes.
- No automatic fix, save, reload, edit or LSP request from the Problems modal.
- No trust in a row after its captured buffer/client/version/generation changes.
- No claim that unversioned server publications prove freshness before local
  invalidation.

## Guard-only future

A later project-coverage slice may introduce a URI-keyed diagnostic index only
after the server capability/coverage contract, unopened-file freshness,
workspace-root containment, retention bounds and navigation/open authority are
specified and falsified. Open-buffer aggregation must not be mislabeled as that
index.

## Design laws

1. Diagnostics remain owned by `OpenBuffer`; the modal captures immutable row
   guards and never becomes a second mutable source of truth.
2. Capture inspects only live `DocumentSession#open_buffers` and performs no
   source-file reads or scans. It resolves the project-root identity once and
   canonicalizes a buffer path only when both lexical and expanded containment
   fail, so common symlink aliases do not turn ordinary rows into misleading
   `../../` paths.
3. A selected row authorizes navigation only to the exact captured live buffer
   and diagnostic generation under the exact captured client.
4. Modal input remains isolated: unknown keys, paste and mouse input cannot
   reach an editor below the overlay.
5. Bounds and partial state are global as well as per publication.

## Execution order

1. Add red model/UI tests for two buffers, deterministic order, global bounds,
   stale non-active targets, close/publication invalidation and guarded tab
   navigation.
2. Extend `ProblemsState::Row` with file and live-snapshot identity.
3. Aggregate and render open-buffer rows, then revalidate and navigate the
   selected existing tab.
4. Update documentation and run focused, full, release and PTY checks.

## Falsifier roster

- A problem from an inactive dirty tab navigates to that exact unsaved editor
  without reading or replacing its text.
- Editing, closing or republishing the inactive target makes the captured row
  unusable and closes the modal.
- A replaced LSP client cannot authorize any retained row.
- More than 1000 aggregate rows are visibly partial and retain exactly the
  deterministic first 1000 rows; a partial empty publication remains visible.
- Duplicate basenames in different directories remain distinguishable.
- Printable keys, paste, mouse and unrelated global shortcuts do not edit or
  switch the underlying document.
- A missing current editor with other open buffers does not create a navigation
  authority shortcut.

## Stop rules

- Stop rather than retain diagnostics for unopened files in this slice.
- Stop rather than open a path that is no longer represented by the exact live
  captured buffer.
- Stop rather than weaken version/client/generation checks to keep a stale
  modal open.

## Observed evidence

The first aggregate regression failed with one row instead of two. Later
adversarial regressions independently exposed source/message sorting ahead of
publication order and macOS `/var` versus `/private/var` aliases producing
misleading paths; both failed before their fixes and pass afterward.

Observed 2026-09-19: 26 focused Problems examples and the full 959 examples
passed with zero failures/errors. Source/spec formatting, diff checks, a release
build and `--help` passed. A real two-file PTY run rendered both relative paths,
kept pasted input and Enter from emitting `didChange`, switched to the inactive
row target, then proved the active URI with a deliberate unsaved edit; source
files remained byte-identical. The existing context-actions PTY also passed.
Independent adversary verdict: ROBUST within the admitted open-buffer scope.

Residual limits: unversioned server publications cannot prove freshness before
local invalidation. A genuinely external open file may display as `../...`
rather than with a special external marker. Root/path identity metadata calls
remain synchronous, and all LSP servers and terminal encodings are not
certified. Refresh after diagnostics ownership, path identity, tab switching,
modal routing or client/version lifecycle changes.

## Implementation seal

- Slice: open-files Problems.
- Source/spec: `problems_state.cr`, `problems_controller.cr`, LSP/document
  lifecycle integration, Problems specs, README and roadmap.
- Falsifiers: focused Problems/diagnostics/modal/input suite plus a real
  two-file PTY workflow.
- Boundary: live open buffers only; no project-coverage claim.
- Next local track: capability-honest project coverage where the server can
  provide it.
