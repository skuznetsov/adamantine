# Adamantine Safety Frontier

Document status: design-sealed for the public-preview hardening slice.

Current frontier: Adamantine may discover language servers automatically only
from trusted executable search paths. Project-local, parent, and sibling
executables require an explicit `--lsp` or environment override. User text must
survive an open/save round trip, and dirty buffers must not be discarded without
an explicit force action.

## Admitted surface

- Explicit LSP commands supplied through CLI or supported environment variables.
- Automatic LSP discovery through `PATH`.
- `:q` for a clean active buffer and `:quit` for a clean application.
- `:q!` as the explicit force-quit operation.
- `:wq` only after every required save succeeds.
- Bounded, well-framed JSON-RPC traffic with prompt failure when the server dies.

## Rejected surface

- Implicit execution of executables found inside the project or its relatives.
- Silent close or quit while affected buffers are dirty.
- Successful-looking save commands after an I/O failure.
- Loss of final newlines or line-ending style during an unchanged save.
- Interleaved JSON-RPC frames, request/response ID confusion, and stale connected
  state after reader failure.

## Guard-only future

- A persisted workspace-trust model that can authorize project-local tools.
- Applying server-provided workspace edits outside the active project root.
- Crash-recovery journals and swap files.

## Design laws

1. Text durability outranks command convenience.
2. Automatic discovery must not widen execution authority beyond `PATH`.
3. One complete JSON-RPC frame is one serialized write operation.
4. Reader termination atomically disconnects the client and fails pending work.
5. User-facing capability claims describe actions Adamantine can complete, not
   protocol methods its client can merely request.

## Falsifier roster

- Open/save byte-for-byte fixtures for LF, CRLF, and no-final-newline files.
- Dirty close/quit and failed `:wq` integration tests.
- Adversarial project/sibling executable discovery tests.
- Yielding-writer, server-request-ID collision, EOF, malformed-frame, and bounded
  shutdown LSP tests.
- Replace/undo, wide-character rendering, stale search result, and bounded or
  incomplete project traversal regression tests.

## Implementation seals

- DoD: `make check` passes from a clean dependency install.
- Adversary: focused probes above pass and the release build answers `--help`.
- Residual boundary: project trust persistence, cross-root workspace edits, and
  crash recovery remain rejected or guard-only until separately specified.
