# Adamantine External File Conflict Frontier

Document status: implemented and verified with the published upstream pin;
Adamantine pull-request publication is pending.

Current frontier: Adamantine may monitor every open regular text file for
completed external changes, preserve the in-memory piece-tree state while the
user chooses how to resolve a conflict, and refuse an unchecked overwrite.

Bounded context: one Adamantine process, local filesystem paths, cooperative
Crystal fibers, and files within the existing open-file size limit.

## Admitted surface

- One cooperative monitor covers all open buffers.
- A cheap file stamp (existence, kind, size, modification time, and resolved
  target) gates a streaming SHA-256 comparison.
- External replacement, deletion, unreadable/non-regular transitions, and
  symlink retargeting become typed conflict events.
- The active buffer retains BASE (last accepted disk revision), OURS (current
  piece-tree root), and THEIRS (the latest observed disk revision/content).
- `Reload from disk` accepts THEIRS as the saved baseline and records OURS as
  one structural undo step. Undo restores OURS as a dirty buffer; redo restores
  THEIRS as clean. A later external reload replaces that recovery pair instead
  of retaining a chain of complete external sources. If only file identity
  changed and the bytes are identical, the current root is accepted directly
  without a duplicate undo entry or LSP change.
- `Keep my version` preserves OURS without writing the disk and keeps the
  conflict visible.
- `Overwrite disk` is explicit and revalidates the observed external generation
  immediately before the existing atomic save path.
- Adamantine's own successful save acknowledges its resulting revision without
  producing a user-visible external-change event. The editor is marked clean
  and emits its save callback only after a post-rename fingerprint succeeds.

## Rejected surface

- Silent reload of a dirty buffer.
- Silent overwrite after `Keep my version` or dismissal of the dialog.
- Treating modification time, size, or a background polling result as authority
  to overwrite a file.
- Applying an action from a stale conflict generation after the file changed
  again.
- Updating widgets or editor state from the monitor while it is reading or
  hashing a file.
- Copying OURS into a full-document history string.
- Claiming atomic compare-and-swap semantics against an uncooperative external
  writer.

## Guard-only future

- Native FSEvents, kqueue, inotify, or Windows directory-change notifications
  as latency hints; they do not replace content validation.
- A side-by-side diff or three-way merge UI.
- Crash-recovery persistence of unresolved conflicts.
- Cooperative cross-process file locking or filesystem-specific compare-and-
  swap facilities.

## Non-goals

- Binary files, files above the existing size limit, remote filesystems with
  stronger consistency claims, or collaborative editing.
- Retaining an unbounded sequence of external candidates.

## Design laws

1. Background observation is advisory; save-time content validation is the
   overwrite authority.
2. A conflict action is valid only for the path watch token and external
   generation that produced it.
3. Disk bytes do not change until a user explicitly chooses an action that
   writes them.
4. Accepting THEIRS changes the saved baseline but preserves OURS structurally.
5. Monitoring work is sequential and chunk-yielding so one large file cannot
   monopolize the cooperative scheduler.
6. At most one unresolved external candidate is retained per open buffer;
   newer observations replace THEIRS but never discard OURS implicitly.
7. If an in-place external writer returns the path from a candidate to the exact
   accepted BASE revision, the conflict clears and stale dialog actions are
   invalidated.

## Execution order

1. Add the upstream `crystal_tui` reload-as-saved history transition.
2. Add independently testable file revision and monitor primitives.
3. Attach baseline/conflict state to `OpenBuffer` and wire watch lifecycle to
   open, close, save, project-root change, and quit.
4. Add the conflict dialog and generation-checked actions.
5. Guard every save with a fresh digest comparison and route mismatches to the
   dialog without writing.

## Falsifier roster

- A clean buffer changed externally yields one dialog; reload is clean, undo
  restores the former bytes as dirty, and redo restores external bytes as clean.
- A dirty buffer changed externally preserves both disk and editor bytes.
- `Keep my version` performs no write and leaves a visible unresolved conflict.
- `Overwrite disk` revalidates the generation, writes OURS atomically, updates
  BASE, and produces no self-change dialog.
- An external writer that wins during post-rename validation leaves OURS dirty,
  suppresses the save callback, and becomes the current conflict.
- A second external change invalidates every action captured from the first
  dialog and coalesces notification to the latest generation.
- Same-size replacement with changed modification time is hashed; same-size
  content with a restored timestamp is caught by the mandatory save-time hash.
- Deletion, atomic replacement, symlink retarget, non-regular, and unreadable
  transitions fail closed.
- Close/reopen cannot deliver an old watch event to the new buffer.
- Multi-megabyte hashing is chunked and does not materialize OURS.
- A content-changing external reload sends one full-document LSP change and
  does not perturb the existing incremental typing path; an identical-byte
  replacement sends no redundant change.

## Stop rules

- Stop if a conflict path writes before a fresh generation check.
- Stop if reload clears the only recoverable OURS state or records it as a full
  document string.
- Stop if a stale watch or dialog action can target a closed or reopened buffer.
- Do not promote polling to a no-race or compare-and-swap guarantee.

## Ledger sync

- Safety frontier: `docs/SAFETY_FRONTIER.md`
- Text buffer frontier: `docs/TEXT_BUFFER_FRONTIER.md`
- Architecture overview: `ARCHITECTURE.md`
- Source/spec: `src/adamantine/file_revision.cr`,
  `src/adamantine/external_file_monitor.cr`, document orchestration and modal
  integration, plus focused specs.

## Implementation seals

- Slice: external-file conflict protection.
- Source/spec: stable file-revision snapshots, one cooperative monitor,
  per-buffer conflict state, guarded save integration, modal actions, and the
  upstream structural reload transition are implemented.
- Focused evidence: 55 file-revision, monitor, orchestrator, and app examples
  pass with the local upstream worktree.
- Full Adamantine evidence: `make check` passes 380 examples with the local
  upstream worktree supplied through `CRYSTAL_PATH`.
- Upstream evidence: 36 focused editor examples pass; the full 652-example
  suite retains only four pre-existing mouse-event failures.
- Publication seal: upstream commit
  `c70c5426a09f0487ece0fbb9264b4d73ef402818` is fetchable through
  `crystal_tui` pull request #9; `shard.yml` and `shard.lock` pin it exactly,
  `shards check` succeeds, and `make check` passes 380 examples without a
  `CRYSTAL_PATH` override.
- Boundary: notification polling narrows ordinary data-loss risk but cannot
  provide portable atomic compare-and-swap against external writers.
- Next local track: asynchronous LSP runtime after this slice closes.
