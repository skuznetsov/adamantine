# Interactive LSP Runtime Frontier

Status: implemented; local verification passed on 2026-09-05.

## Scope

Interactive read-only LSP actions must return control to the UI without waiting
for the server. Hover, completion previews, signatures, references, definition
navigation and code-action previews retain their existing result behavior.

## Design laws

- Bound interactive work to one executing request and one replaceable latest
  queued action. Repeated input must not accumulate waiting request fibers.
- Publish only for the same client, project, buffer identity, document version,
  cursor position and action generation that requested the result.
- Dismissing results and shutting down invalidate pending publication.
- Key and mouse input invalidate previous interactive work before routing the
  event; switching tabs also invalidates it. Moving away and back must not
  resurrect a response. Internal wakeup events do not cancel requests.
- Loading feedback must permit continued editing and navigation.
- Failed requests release scheduling state and permit subsequent requests.
- UI wakeups are coalesced when the bounded event queue is full, rather than
  suspending a publisher halfway through a state change.
- Navigation rechecks request freshness after reading an unopened target and
  before publishing its tab or changing navigation history.
- Existing read-only previews do not gain authority to apply workspace edits.

## Falsifiers and verification

Hold a fake server response while the action caller returns and editor input
continues. Supersede requests, edit or close/reopen the document, move the cursor,
replace the client and dismiss the popup before releasing the response. Verify
that stale responses cause neither popup nor navigation. Exercise errors and
shutdown, then run focused LSP specs and `make check` with a writable cache.

Observed evidence on the implementation based on `dac9a30`:

- `CRYSTAL_CACHE_DIR=/private/tmp/adamantine_async_parent_cache make check`:
  format, build and 398 examples passed with no failures or errors.
- `spec/lsp_async_spec.cr` covers bounded scheduling, stale results, errors,
  shutdown and a full event queue.
- `spec/lsp_async_lifecycle_spec.cr` covers tab round trips, close/reopen,
  hyperclick invalidation and stale queued work before dispatch.
- `spec/lsp_async_transport_spec.cr` exercises the real stdio client with a
  controlled server, reordered replies, input during delayed replies and stop.
- `spec/lsp_async_navigation_spec.cr` reproduced stale navigation during a
  2 MB target snapshot before guarded publication was connected, then passed.

These checks must be rerun when the scheduler, event-loop wakeup semantics,
document-opening commit order or pinned UI dependency changes. They do not
establish compatibility with an installed Adamas or Crystal language server.

## Boundaries

This slice does not make startup, transport writes, semantic-overlay CPU work or
all editor operations asynchronous. Server-side cancellation, applying completion
edits, rename, workspace edits and crash recovery remain separate work.
The latest queued action may wait for the running request's existing timeout;
the UI remains available during that wait.
Rollback is a revert of the feature commit.
