# Adamantine Safety Frontier

Document status: design-sealed for the public-preview hardening slice.

Current frontier: Adamantine may discover language servers automatically only
from trusted executable search paths. Project-local, parent, and sibling
executables require an explicit `--lsp` or environment override. User text must
survive an open/save round trip, and dirty buffers must not be discarded without
an explicit force action. Completed external file changes must not be silently
reloaded or overwritten. Project-wide search must not synchronously scan the
project from an input handler, and superseded searches must not publish stale
results.

## Admitted surface

- Explicit LSP commands supplied through CLI or supported environment variables.
- Automatic LSP discovery through `PATH`.
- `:q` for a clean active buffer and `:quit` for a clean application.
- `:q!` as the explicit force-quit operation.
- `:wq` only after every required save succeeds.
- Bounded, well-framed JSON-RPC traffic with prompt failure when the server dies.
- Debounced project search in a cooperative background fiber, with bounded file
  traversal and cancellation checks between filesystem and scanning units.
- One cooperative external-file monitor for all open buffers, with metadata
  gating, streaming content fingerprints, and typed conflict states.
- Explicit reload, keep, and guarded-overwrite actions. Reload preserves the
  prior editor state as structural undo history; keep performs no write.

## Rejected surface

- Implicit execution of executables found inside the project or its relatives.
- Silent close or quit while affected buffers are dirty.
- Successful-looking save commands after an I/O failure.
- Loss of final newlines or line-ending style during an unchanged save.
- Interleaved JSON-RPC frames, request/response ID confusion, and stale connected
  state after reader failure.
- Publishing project-search results after the query, case mode, project root, or
  panel lifetime that produced them has changed.
- Silent external reload, unchecked overwrite, stale conflict actions, or
  treating timestamps as save authority.

## Guard-only future

- A persisted workspace-trust model that can authorize project-local tools.
- Applying server-provided workspace edits outside the active project root.
- Crash-recovery journals and swap files.
- Native filesystem notifications and filesystem-specific compare-and-swap.
- Streaming partial search results and preemptive operating-system thread
  cancellation.

## Design laws

1. Text durability outranks command convenience.
2. Automatic discovery must not widen execution authority beyond `PATH`.
3. One complete JSON-RPC frame is one serialized write operation.
4. Reader termination atomically disconnects the client and fails pending work.
5. User-facing capability claims describe actions Adamantine can complete, not
   protocol methods its client can merely request.
6. Search cancellation is cooperative: every admitted scan unit is bounded, and
   only the current request generation may update panel state.
7. Background file observation is advisory; a fresh content check immediately
   before atomic rename is the overwrite authority, and a post-rename check
   must pass before the editor becomes clean or emits its save callback.
8. External conflict actions are scoped to one path watch and candidate
   generation. Dismissal never resolves the conflict.

## Falsifier roster

- Open/save byte-for-byte fixtures for LF, CRLF, and no-final-newline files.
- Dirty close/quit and failed `:wq` integration tests.
- Adversarial project/sibling executable discovery tests.
- Yielding-writer, server-request-ID collision, EOF, malformed-frame, and bounded
  shutdown LSP tests.
- Replace/undo, wide-character rendering, stale search result, and bounded or
  incomplete project traversal regression tests.
- In-flight project-search cancellation, newest-query-wins publication, and
  panel-close invalidation tests.
- External edit/deletion/replacement/symlink tests, stale-action rejection,
  same-size restored-mtime save checks, and own-save suppression.

## Implementation seals

- DoD: `make check` passes from a clean dependency install.
- Adversary: focused probes above pass and the release build answers `--help`.
- Residual boundary: project trust persistence, cross-root workspace edits,
  crash recovery, native file notifications, portable cross-process CAS,
  streaming search results, and preemptive cancellation remain rejected or
  guard-only until separately specified.
