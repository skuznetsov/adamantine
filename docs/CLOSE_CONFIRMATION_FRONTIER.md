# File-scoped close confirmation

Status: implemented and locally verified (2026-09-19); bounded close/quit slice.

## Scope and safety contract

Replace refusal-only dirty tab close and ordinary quit with a file-scoped
Save / Discard / Cancel dialog. Show the target path, not just its basename.
Cancel is initially selected; Escape cancels. Tab/arrows select, Enter confirms.
Discard means close without writing the source file. It does not promise to
erase private recovery history. Existing explicit `:q!` remains force quit.
During quit, the session retains its normal tab list for reopening from disk.
Before shutdown I/O can yield, stop the monitor and invalidate the remaining
poll batch. This is the quit commit boundary, not a filesystem snapshot or a
promise to discover edits made externally after exit has begun.

Capture buffer and editor identities, document version and conflict generation.
A stale decision cannot close a reopened or subsequently edited buffer. Save
uses the existing guarded disk-save path and never implicitly authorizes an
external overwrite. Failure leaves the file open. Save targets the captured
file, even when another tab becomes active.

During multi-file quit, collect discard decisions without closing tabs. Cancel
keeps all tabs and unsaved text; earlier explicitly requested saves remain on
disk. Recheck the entire live buffer set before shutdown. A new or changed
unsafe buffer needs a fresh decision. Dialog input and late clipboard/LSP work
must not edit the underlying buffer or replace the confirmation unexpectedly.

Rejected: automatic overwrite, default destructive Enter, blanket force quit
after partial confirmation, discarded tabs disappearing before quit completes.
Non-goals: redesign external-change review, recovery deletion, mouse buttons,
save-all, and keymap/palette redesign.

## Execution and verification plan

Risk: CAUTION (unsaved-data lifecycle). Rollback: one isolated feature commit;
preserve the pre-existing Makefile change and do not include it in the commit.

1. `document_orchestrator.cr` and focused specs: file-targeted save, preserving
   disk-conflict guards. Consumers: App close flow and existing active save.
2. Close confirmation controller/state, `app.cr`, navigation/modal integration:
   red tests for dirty close, Cancel, Save, Discard, stale identity/version,
   multi-file quit cancellation and failed/external-conflict save.
3. Parent review, complete specs, formatting, release build, and real PTY smoke
   covering close/quit keyboard flow plus existing refactor/format interactions.

DoD: `crystal spec --link-flags=-fuse-ld=/usr/bin/ld` with a writable
`CRYSTAL_CACHE_DIR`; zero failures. `crystal tool format --check src spec` and
`git diff --check`; clean. Release build and PTY checks must exit successfully.
Strongest falsifier: confirm an old dialog after the target changes or reopens;
the new text must remain live. Also cancel the second file in a quit sequence
after discarding the first; neither tab may have disappeared.

## Evidence

At this feature's source state (base `693de5d` plus the scoped close-confirmation
diff), the parent ran:

- `CRYSTAL_CACHE_DIR=/private/tmp/adamantine-close-parent crystal spec --link-flags=-fuse-ld=/usr/bin/ld`:
  881 examples, zero failures/errors/pending.
- `crystal tool format --check src spec` and `git diff --check`: passed.
- `CRYSTAL_CACHE_DIR=/private/tmp/adamantine-close-build crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-close-editor`:
  passed.
- `ruby scripts/smoke_close_confirmation.rb /private/tmp/adamantine-close-editor`:
  passed default Cancel, input isolation, partial-quit cancellation, Save and
  Discard against real terminal input and independent disk/LSP observations.
- `ruby scripts/smoke_refactor.rb /private/tmp/adamantine-close-editor` and
  `ruby scripts/smoke_format_git.rb /private/tmp/adamantine-close-editor`:
  both passed existing inline preview, accept/reject/Undo and Git workflows.

Discriminating checks: the close PTY gate failed against the old binary (no
file-scoped dialog). The shutdown test observed a still-running monitor at
session persistence before the stop was moved. The poll callback regression
published the second event after stop before the generation guard was added.
Their fixed versions pass. Adversary specs additionally exercise stale editor
identity/version, newly opened buffers during quit, late clipboard delivery,
compact rendering/control characters and clipped repaint stability. Session
integration confirms quit Discard reopens the tab from unchanged disk text.
After isolating the confirmation test fixtures from user config/recovery, the
8-test confirmation suite was rerun successfully. A final read-only Luna review
returned ROBUST within the bounded data-loss scope, with no remaining concrete
blocker. This same-lineage review supplements, rather than replaces, the
parent-executed tests and real terminal gates.

These checks establish the tested keyboard workflows, not universal terminal
usability or atomic filesystem snapshots. External-change comparison UI and
mouse-operated dialog buttons remain outside this slice. Evidence decays when
close routing, save checks, modal capture, monitor lifecycle or buffer versions
change; rerun these gates before promoting a new completion claim.
