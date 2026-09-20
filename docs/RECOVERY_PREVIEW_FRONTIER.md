# Recovery Preview Frontier

Status: implemented; locally verified with Crystal 1.21.0 on macOS

## Problem

The recovery menu currently identifies abandoned checkpoints and can either
open a private recovered copy or explicitly discard a checkpoint. It cannot
show what is in a checkpoint before either action. A useful preview must keep
three independently changing sources distinct:

- the editor text for the checkpoint source path, when that file is open;
- a bounded, stable disk snapshot captured when the review opens, but only
  when the recorded source is inside the currently authorized project;
- the selected private recovery checkpoint.

## Admitted behavior

- `Review draft` opens a read-only editor-pane review without creating a
  recovered copy, changing an editor buffer, writing a source file, or deleting
  a checkpoint.
- The review presents pairwise comparisons. The preferred initial pair is
  `Editor -> Checkpoint`, then `Disk -> Checkpoint`; `Editor -> Disk` remains
  available when both sources exist. Pairwise views keep `-` and `+` line
  coordinates meaningful when all three sources have shifted independently.
- A standalone `Checkpoint contents` view is always available. It renders the
  verified checkpoint as document context and does not invent an empty Editor
  or Disk source; this keeps review useful after the original file was deleted.
- `Tab` and `Shift-Tab` cycle only comparisons whose two sources were captured.
  Arrow, Page Up/Down, Home, and End keys move the detached preview. `Escape`
  closes it. Other keyboard, paste, and mouse input is consumed by the modal.
- The title names the active pair and the scope identifies Editor, Disk, and
  Checkpoint as captured states. Reopening the review refreshes the capture;
  an open review never silently swaps in newer bytes.
- Missing, unreadable, non-regular, oversized, unstable, or non-text disk
  content is reported as unavailable and is never represented as an empty
  document. An absent/non-compatible editor is reported independently.
- Checkpoint reads re-lock the abandoned session, match the complete checkpoint
  identity, including digest and byte count, and checksum the streamed frame
  before returning content. This is within the store's cooperative advisory-
  lock model, not protection against a hostile same-user process.
- A checkpoint `source_path` is display metadata, not filesystem read
  authority. Disk capture is unavailable when the path escapes the canonical
  project boundary or resolves through an unsafe target.
- `Open recovered copy` retains the existing behavior: create and open a
  private copy while leaving the source and checkpoint unchanged.
- `Discard checkpoint` remains a separate, explicit deletion action.

## Rejected behavior

- No three-column line diff. Independent insertions cannot share honest line
  alignment, and terminal width would hide the source labels first.
- No automatic reload, merge, overwrite, source recreation, checkpoint
  deletion, or recovered-copy creation from the review.
- No cached `OpenBuffer#disk_revision` as current-disk authority.
- No disk read merely because a checkpoint metadata field contains a path.
- No preview implemented by calling recovery-copy creation as a hidden side
  effect.
- No unavailable source represented as empty text.

## Guards and bounds

- Recovery checkpoint and disk content retain the existing 16 MiB per-document
  bound. Checkpoint framing, checksum, permissions, regular-file, symlink, and
  session-lock checks remain authoritative.
- Preview rows stay lazy and long displayed lines stay bounded by the existing
  inline-preview limits.
- The recovery menu carries full checkpoint identity. A replacement or removal
  between discovery and review/recover/discard fails closed.
- Captured editor identity and version are descriptive freshness evidence, not
  authority to mutate the live editor.

## Falsifiers

The slice is rejected if any focused test can show that:

1. opening or closing a review changes a buffer, source file, recovery frame,
   recovered-copy count, or checkpoint count;
2. replacing/removing the checkpoint after discovery, through the cooperative
   store boundary or before an action starts, yields preview bytes or an action
   against the replacement;
3. unavailable disk/editor state appears as an empty-file comparison;
4. a later editor/disk change mutates an already-open captured review;
5. printable keys, paste, or mouse input reach the editor under the review;
6. compact rendering advertises Accept, Reload, Overwrite, or Discard;
7. checkpoint/disk limits or inline row bounds can be bypassed;
8. forged checkpoint metadata can make preview read outside the authorized
   project boundary.

## Definition of Done

- Focused recovery store/controller/review UI specs pass, including identity
  replacement, missing disk/editor, modal isolation, compact rendering, and
  no-mutation assertions.
- The full Crystal spec suite passes with a writable external cache.
- A release build succeeds with the system linker.
- PTY smoke checks cover opening, cycling, and closing recovery review without
  source/checkpoint mutation.

Rollback is the single feature commit for this slice; existing recovery copy
and discard behavior remains independently testable throughout.

## Observed evidence (2026-09-19)

- The focused recovery, review, renderer, modal and shared-preview selection
  completed with 98 examples and zero failures/errors/pending.
- The full Crystal suite completed with 949 examples and zero
  failures/errors/pending. `crystal tool format --check src spec` and
  `git diff --check` were clean.
- A release build with `/usr/bin/ld` succeeded and its `--help` path ran.
- `scripts/smoke_recovery_preview.rb` created a real checkpoint in one PTY,
  abandoned it with SIGKILL, opened and cycled the read-only review in a second
  PTY, injected ignored editor/paste/Enter/mouse input, closed the review and
  proved source bytes, checkpoint digests/count and the recovered-copy tree
  unchanged.
- All six existing PTY workflows also passed: Format/Git, Rename/Quick Fix,
  close/quit, command palette, external-change review and contextual actions.

This evidence is scoped to the tested local filesystem and terminal. The
existing recovery threat model does not protect against a malicious process
running as the same OS user and racing path replacement; reopening the review
is also required to observe later editor or disk changes. Those limits do not
grant the review any mutation authority.
