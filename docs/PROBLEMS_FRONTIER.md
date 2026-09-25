# Server-workspace Problems frontier

Document status: locally verified on 2026-09-19.

Current frontier: when the active LSP server statically advertises
the required boolean `diagnosticProvider.interFileDependencies` and
`diagnosticProvider.workspaceDiagnostics: true`, widen the existing Problems
entry point to a bounded, asynchronous snapshot of server-reported workspace
diagnostics. Otherwise preserve the locally verified open-files snapshot.

This is deliberately not called complete project coverage. The server decides
which documents it reports and LSP does not certify that every project file was
examined.

Bounded context: LSP 3.17 pull diagnostics, Adamantine's existing
push-diagnostics pipeline, one canonical project root, the Problems modal and
guarded file opening.

## Admitted surface

- `Ctrl+Shift+M` remains the single Problems entry point. A ready client with a
  static object `diagnosticProvider` and explicit `workspaceDiagnostics: true`
  opens `Problems: Server Workspace (loading)` immediately and performs the
  request off the input path. Unsupported or unavailable clients retain the
  existing `Problems: Open Files` behavior.
- The first workspace request always sends `previousResultIds: []`. It omits
  work-done and partial-result tokens, consumes one final report and retains no
  result-id cache. `unchanged` without retained prior data is skipped and makes
  the visible snapshot partial.
- One workspace request runs at a time. A newer invocation supersedes the UI
  generation and is queued as the latest refresh; late results may not publish
  against a closed modal, replaced client or changed root.
- The parser examines at most 4096 document reports and the UI retains at most
  1000 diagnostics. Malformed, unsupported or truncated input is skipped and
  makes the snapshot visibly partial. A later full report for a repeated URI
  replaces the earlier report, as required by LSP.
- Live open buffers remain authoritative. Their retained push diagnostics are
  used in the workspace view and a workspace report for the same URI, symlink
  alias or hard-link alias is not duplicated or allowed to overwrite dirty
  editor state.
- An unopened report is admitted only for a bounded `file:` URI whose canonical
  target is a readable regular file within the canonical project root and no
  larger than Adamantine's file-open limit. Capturing the row performs metadata
  probes only; file contents are not read until explicit `Enter`.
- `Enter` revalidates client, project root, request generation, URI/path,
  canonical containment and the captured filesystem stamp. The file is read
  through `FileRevision` against that expected stamp, the UTF-16 range is
  resolved on the exact editor instance about to be committed, and all guards
  are checked again before navigation.
- Empty, loading, partial and failed/fallback coverage are visible. A
  request-level failure while the current client remains ready falls back to
  the bounded open-files snapshot and reports the failure without changing a
  document. Managed transport loss invalidates the client and closes the stale
  modal before recovery; it is not represented as a successful fallback.

## Rejected surface

- No claim of complete project coverage, compiler-wide analysis or diagnostic
  freshness for an unopened file beyond the captured metadata identity.
- No disk scan, background source-file read, synthetic diagnostics or use of
  push publications as evidence about unopened files.
- No dynamic diagnostic registration, `textDocument/diagnostic` request, result-id
  cache, related-document cache, partial-result progress or work-done progress
  in this slice.
- No `workspace/diagnostic/refresh` capability advertisement until the server
  request is implemented. Unknown refresh requests retain the existing
  method-not-found behavior.
- No automatic refresh on edits, saves or keystrokes. An edit invalidates an
  open modal; reopening Problems requests a fresh workspace snapshot.
- No blind opening of non-file, missing, external, symlink-escaping, non-regular,
  oversized or changed targets. No save, reload, edit or code-action authority
  follows from a workspace diagnostic.
- No workspace result may replace, deduplicate by basename, or authorize a
  position in a dirty open buffer.

## Design laws

1. Open-buffer diagnostics and server-workspace reports have different
   authorities. They share rendering, not mutable ownership.
2. Capability admission is fail-closed: only the exact static object and
   boolean `true` shape enables the request.
3. Workspace diagnostics remain wire UTF-16 until an exact editor exists.
   Existing push diagnostics remain editor-codepoint coordinates.
4. Snapshot publication requires the same client identity, canonical root and
   request generation before and after all yielding or filesystem work.
5. An unopened row stores a `FileRevision::Stamp`; `DocumentOrchestrator` must
   pass it as the expected stamp to the bounded reader rather than relying on a
   pre-read check with a race window.
6. Modal input remains isolated while loading and after publication. `Enter`
   is inert without a current row; `Esc` immediately closes and invalidates the
   UI generation even if the server ignores cancellation.
7. Bounds apply to inspected reports, diagnostics, strings, URI bytes, response
   frames and retained rows. Any bound hit is visible as partial coverage.

## Execution plan

Risk: CAUTION. This widens the LSP protocol and file-open authority.

Rollback: one atomic feature commit; revert restores the sealed open-files
implementation. The pre-existing user-owned `Makefile` change remains outside
the commit.

Definition of Done: focused protocol/parser/lifecycle/navigation specs fail
before production edits and pass afterward; the full Crystal spec suite,
formatter check, release build and a pull-capable PTY smoke pass. The PTY must
show an unopened diagnostic without reading or changing the file before Enter,
then open the exact in-root file and place the cursor at a non-ASCII UTF-16
position. Unsupported-server fallback must remain usable.

Implementation steps:

1. `lsp_client.cr`: add fail-closed static capability detection, the typed
   final-response request and a bounded full/unchanged workspace parser.
2. `problems_state.cr` and `problems_controller.cr`: add explicit coverage,
   loading and target authority; schedule latest-only workspace requests and
   merge authoritative open-buffer rows without duplicates.
3. `document_orchestrator.cr` and `navigation_controller.cr`: carry an optional
   expected filesystem stamp into the existing stable bounded read.
4. Lifecycle integration and specs: invalidate on close, edit, client/root
   replacement and late results; verify bounds, canonical containment, dirty
   precedence and no-support fallback.
5. Documentation and PTY: describe server-reported coverage accurately and
   exercise the real JSON-RPC/UI boundary.

Pre-mortem: the most likely severe failure is a late or aliased server URI
opening different bytes than the report described. The guard check is a
canonical in-root path plus an expected-stamp `FileRevision.read`, followed by
generation/client/root revalidation immediately before UI commit.

## Falsifier roster

- Missing, false, boolean-true and malformed `diagnosticProvider` shapes do not
  enable workspace pulls; only the required object shape does.
- The request contains `previousResultIds: []` and no progress token.
- Full, empty, repeated-URI, unknown-unchanged, malformed and over-limit reports
  produce the documented rows and partial signal without unbounded retention.
- A slow response does not block input; Esc closes immediately, and a late
  response after close, edit, root change or client replacement cannot reopen
  or mutate the modal.
- A dirty open buffer contributes only its current push diagnostics. Workspace
  diagnostics for that URI neither duplicate it nor cause a disk reread.
- A closed in-root UTF-16 target opens only on Enter and resolves against the
  exact loaded editor. Changed, deleted, non-text, oversized, outside-root and
  symlink-escaping targets leave editor state unchanged.
- More than 1000 retained rows and more than 4096 inspected document reports
  are visibly partial and deterministically bounded.
- Printable keys, paste, mouse and unrelated shortcuts do not leak through the
  loading or populated modal.

## Stop rules

- Stop rather than infer support from a boolean or malformed provider.
- Stop rather than add a progress token, refresh capability or result cache
  without its complete transport and invalidation contract.
- Stop rather than weaken client/root/generation/stamp checks to keep a stale
  row navigable.
- Stop rather than call a server-reported subset complete project coverage.

## Prior implementation seal

The preceding open-files slice is locally verified: 26 focused Problems
examples and the full 959-example suite passed, together with formatting,
release build, `--help`, a real two-file PTY workflow and an independent ROBUST
adversary verdict within the admitted live-open-buffer scope. Commit `3238f77`
is the rollback anchor for that behavior.

## Observed evidence

The initial parser specs failed because no workspace-diagnostic result model
existed. A later hard-link counterexample failed by duplicating a dirty buffer
through another name for the same inode. After implementation, 56 focused
diagnostics/Problems examples and the full 982-example suite passed with zero
failures/errors. Source/spec
formatting, `git diff --check`, a release build and `--help` passed. A real
pull-capable PTY run rendered an unopened in-root diagnostic without opening or
changing the file before Enter, isolated paste input, then opened the exact
target and proved UTF-16 column conversion after an emoji via the subsequent
full-sync edit. Both source files remained byte-identical.

Parent counterexamples cover exact capability shapes, wire request parameters,
unknown unchanged and malformed reports, request failure fallback, managed
transport invalidation, 4096-report and 1000-row bounds, dirty open-buffer
precedence, late Escape, changed files, outside-root and symlink escapes,
canonical symlink and hard-link aliases, and loading-modal input isolation.

Residual limits: server-reported coverage may be incomplete. Unversioned closed
file diagnostics carry no semantic freshness proof beyond the captured
filesystem identity. This slice retains no result-id cache, progress stream,
refresh request or cancellation; an invalidated request may run until its
30-second timeout but cannot publish. Metadata probes remain synchronous, and
the verification does not certify every LSP server, filesystem or terminal.

## Implementation seal

- Slice: capability-honest server-workspace Problems.
- Source/spec: LSP capability/request/parser, Problems state/controller,
  expected-stamp file opening, focused specs and pull-capable PTY fixture.
- Falsifiers: exact capability matrix, real JSON-RPC request, bounds, stale
  lifecycle, dirty/alias precedence, containment and UTF-16 guarded navigation.
- Boundary: server-reported workspace subset; no disk scan or completeness
  claim.
