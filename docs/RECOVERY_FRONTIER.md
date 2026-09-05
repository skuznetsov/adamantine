# Unsaved Buffer Recovery Frontier

Status: implemented; locally verified with Crystal 1.21.0 on macOS.

## Scope and safety laws

Periodically checkpoint modified file-backed buffers into private local state,
outside the project. Offer abandoned checkpoints on the next run and through
`:recover`. Recovery opens an independent copy, never overwrites the original
path and never silently replaces a current editor buffer. Deleted or externally
changed source files must not prevent recovery of the saved draft.

- One cooperative worker checkpoints sequentially; no per-edit fiber backlog.
- Stream document bytes with bounded I/O, retaining the previous valid snapshot
  until a complete replacement is published atomically. Recheck buffer identity,
  version and modified state before publishing.
- Private directories and files; reject symlink/non-regular recovery entries.
  Snapshot metadata is untrusted and must never authorize arbitrary writes or
  deletion outside the recovery store.
- Live sessions own distinct stores and retain exclusive locks. Never offer,
  overwrite or delete another active session's checkpoints.
- Bound per-document bytes, checkpoint counts, total stored bytes and scanning.
  Report limit or I/O failures without preventing editing or ordinary saves.
- Clean/closed buffers retire only this session's snapshots. Explicit recovery
  preserves the checkpoint; dismissal keeps it available. Discard is explicit.
- Forced exit preserves the latest available draft; normal shutdown releases
  ownership. No power-loss durability or zero-keystroke-loss guarantee.

## Operational bounds

`RecoveryController` starts only from the application run lifecycle. One
cooperative worker attempts a pass, then sleeps for two seconds. Shutdown waits
up to 250 ms for a serialized final pass; on timeout the writer retains its lock
until it drains or the process exits. Blocking filesystem syscalls can exceed
this cooperative wait budget.

`RecoveryStore` uses versioned, SHA-256-checked frames, temporary files and atomic
rename. Files are mode 0600 and owned directories mode 0700. Recovery requires a
local filesystem with working advisory locks and rename semantics. Known
symlink paths are rejected; this is not protection against a malicious process
running as the same OS user and racing filesystem mutations.

Each session admits at most 128 snapshots, 128 recovered copies, 16 MiB per
document and 256 MiB total (including the old snapshot and temporary replacement
at peak). The limit is **per session**, not a global disk quota. No old drafts or
recovered copies are evicted automatically. Recovered copies remain ordinary
editable files; later user edits are not a storage-quota enforcement boundary.

Discovery is bounded and reports truncation rather than claiming every draft
was found: at most 128 session directories, 4096 examined frames and 256 MiB of
frame bytes per scan. Large accumulated stores can therefore require manual
archival or cleanup with editor instances stopped; preserve wanted checkpoints and copies
before doing so. Project affiliation is the initial run root, even after `:cd`.

## Verification and rollback

Implemented slices (CAUTION: durable local snapshots):

1. `recovery_store.cr` and its specs: private crash-atomic streaming storage,
   bounded decoding/scanning and abandoned-session ownership checks. Falsify
   partial-write replacement and cross-session interference first.
2. `recovery_controller.cr`, `app.cr`, `command_palette.cr` and integration
   specs: one periodic worker, explicit copy recovery and lifecycle cleanup.
   Constructors must not write user state; tests inject temporary stores.
3. Review corruption, stale publication and original-file preservation;
   execute the full check, document the measured boundary and commit locally.

Observed checks on 2026-09-05:

- `spec/recovery_store_spec.cr`: 11 examples covering streamed round trips,
  stale/failed replacement, checksum corruption, truncation, project filtering,
  symlink rejection, bounded discovery and document/session/count admission.
  Sparse padding verifies peak quota rejection preserves the prior checkpoint.
- `spec/recovery_controller_spec.cr`: 9 examples covering inert construction,
  opt-out, dirty/clean/closed lifecycle, stale writes, final checkpoints,
  in-flight shutdown ownership, menu pagination/discard and copy recovery while
  preserving another dirty buffer.
- `spec/recovery_crash_spec.cr`: 1 subprocess test. A live child's session stays
  hidden, SIGKILL makes it recoverable, and recovery neither overwrites externally
  changed bytes nor recreates a subsequently deleted source.
- `CRYSTAL_CACHE_DIR=/private/tmp/adamantine_recovery_parent_cache make check`:
  formatting, build and 419 examples pass with zero failures/errors.

Parent review additionally corrected overlapping shutdown writes, repeated
background scans, non-scrolling menu overflow, quadratic clean-buffer cleanup,
second-read metadata bounds and count admission hidden by crash-left temporary
files. Adversarial verdict is robust for tested ownership, frame integrity and
original-write safety; it does not certify power-loss durability or unlimited
recovery availability. Changes to framing, locks, buffer-version notifications,
shutdown scheduling or filesystem semantics require re-running these checks.

Rollback is reverting the feature commit; user recovery data stays outside Git.

## Non-goals

Automatic original-file overwrite, replaying undo history, cloud backup,
cross-user sharing, encrypted-at-rest storage, crash-proof saving and unlimited
retention are not admitted. The interval leaves a bounded-by-scheduling window
of recent edits not yet captured; stalled filesystem I/O can extend it.
