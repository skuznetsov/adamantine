# External-change review

Status: locally verified within the contract below (2026-09-19).

## Contract

External observations must not steal focus, replace another modal, reload a
buffer or write a file. Retain conflict markers and a discoverable review hint.
An explicit Review action (shortcut or command) or attempted Save on a known
conflict opens comparison in the editor pane. The comparison labels removed
rows as editor text and added rows as disk text. Default Enter and Escape mean
Later: keep editing with the conflict unresolved. Tab selects an explicit
Reload from disk or Overwrite disk action; Enter confirms that selection.

Reload preserves the previous editor state in Undo. Overwrite uses the existing
checked atomic-save path. Neither action can apply an old decision to a newer
editor, reopened buffer or different disk observation. Capture buffer/editor
identity, document version and conflict token/generation; revalidate after
yielding reads and immediately before mutation. Re-read/hash disk at acceptance.
Changed observations require fresh review rather than silently refreshing an
already selected destructive action. Clipboard, paste, mouse and deferred LSP
results cannot edit beneath the comparison or supersede it.

The disk read uses the existing file-size bound. The projection uses persistent
editor roots and bounded visible rows, not two full editor strings or arrays of
every line. A whole-document replacement may yield a coarse diff; this is not a
minimal-diff claim. Missing/unreadable/non-text/oversized candidates must be
identified as unavailable, never rendered as an empty file. Only a confirmed
missing path may use the existing explicit recreate/overwrite capability.

Rejected: automatic reload/write, unsolicited modal changes, stale acceptance,
Enter defaulting to reload/overwrite, accepting a different disk revision from
the captured review. Visible rows may be scrolled and long lines abbreviated;
the fingerprint covers the full bounded candidate, not just displayed cells.
Non-goals: per-hunk merging, recovery comparison, keymap redesign, agent edits,
mouse buttons and an atomic cross-process filesystem compare-and-swap.

## Execution plan

Risk: CAUTION (source data and asynchronous observations). Rollback: one local
feature commit, excluding the user-owned Makefile change. Base: `c50f8c5`.

1. `external_change_review.cr`, `document_orchestrator.cr`, focused specs:
   immutable review capture and guarded apply; red stale-editor/disk tests.
2. New controller and `inline_preview_renderer.cr`: reuse bounded projection
   with explicit source labels and safe selectable actions. App/input/command
   glue: non-interrupting notification, explicit review and modal isolation.
3. Parent adversary tests, full specs, release build and real PTY workflow;
   preserve existing close/refactor/format/Git scenarios. Update roadmap/docs.

Consumer inventory: `rg -n 'external_conflict|resolve_external_conflict' src`
finds the orchestrator save/monitor/resolve paths, App notification/menu/header,
close confirmation and recovery hooks. Existing direct resolve tests retain
their backend contract; the new UI uses captured review authority.

DoD: `CRYSTAL_CACHE_DIR=/private/tmp/adamantine-external-parent crystal spec
--link-flags=-fuse-ld=/usr/bin/ld`, formatting and diff checks, release build,
new external-review PTY plus existing three smoke scripts all pass.
Strongest falsifier: modify editor or disk after selecting Reload/Overwrite;
confirmation must fail without discarding newer text or writing the new disk
revision. Also change disk during another modal and keep typing: neither focus
nor modal identity may change. Cancel/default Enter must preserve text, disk,
history and unresolved conflict. Refresh evidence after lifecycle/input/save
or projection changes.

## Evidence

Source lineage: local feature based on `c50f8c5`, tested on macOS with Crystal
1.21.0. The initial parent notification regressions failed on the old automatic
menu because it interrupted typing and replaced the command palette. The new
PTY harness also rejected the previous release binary, which lacked explicit
inline external review.

Observed after implementation: 903 full-suite examples passed with no failures
or errors. This includes nine backend review examples, nine parent application
examples and four UI examples, alongside the existing file-monitor, reload,
save, projection and modal tests. Formatter and diff checks pass. Release
build and all four PTY scripts pass. The external-review PTY gate checks
settings-popup isolation, continued typing, labeled/scrolled comparisons,
paste isolation, Later/Tab wraparound/Escape, Reload with Undo, Save-triggered
review and explicit Overwrite. For stale acceptance it confirms Overwrite is
selected, changes disk, presses Enter, then requires a new editor `didChange`
after the modal closes while the newer disk bytes and prior editor text remain.
It does not infer rejection from historical terminal output or an already-true
disk predicate. Parent run evidence is temporary under
`adamantine-external-review-20260919-96890-1lkpvi8`; the checked-in script is the
reproducible gate, not the availability of that temporary log.

Parent counterexamples cover editor edits during preparation and acceptance,
changed disk fingerprints before reload/rename, a newer conflict during reload
callbacks, missing-path recreation and reappearance, non-text refusal, default
Later, delayed clipboard cancellation, loading cancellation and background
events during existing modals. A same-lineage Luna review found no additional
concrete stale-authority defect; that review is correlated supporting evidence,
not a replacement for executed parent checks.

Adversary verdict: ROBUST for this local review/guard boundary. This is not an
atomic cross-process filesystem exclusion guarantee or completion of recovery
review, per-hunk merging, or the broader UX roadmap.

Commands (local temporary caches/binary are not repository artifacts):

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-external-parent crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-external-build crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-external-editor
ruby scripts/smoke_external_review.rb /private/tmp/adamantine-external-editor
ruby scripts/smoke_close_confirmation.rb /private/tmp/adamantine-external-editor
ruby scripts/smoke_refactor.rb /private/tmp/adamantine-external-editor
ruby scripts/smoke_format_git.rb /private/tmp/adamantine-external-editor
```

Residual boundary: filesystem fingerprint checks do not constitute an atomic
cross-process compare-and-swap. A writer can race the final check/rename; a
post-rename failure cannot undo that filesystem operation. Completion feedback
therefore does not falsely promise that no action occurred. Reload likewise
retains a newer conflict if a callback observes it after replacing editor text;
the old text remains in Undo. These checks do not certify every terminal,
filesystem, language server, or end-to-end large-file latency/RSS. Refresh this
evidence after changes to lifecycle, input, save/reload guards, monitor
publication or projection; do not carry the completion claim across such edits
without rerunning the commands and relevant race falsifiers.
