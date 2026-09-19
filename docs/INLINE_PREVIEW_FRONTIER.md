# Inline proposed edits

Status: implemented and locally verified within the admitted subset (2026-09-19).

## User contract

Show proposed changes directly in the editor pane, with removed and added
lines, surrounding source context, readable line numbers and explicit accept
or reject. Color is supplementary: `-` and `+` carry the same distinction.
The user's preferred interaction is inline review rather than a floating
technical edit list. Future agent proposals may reuse this presentation, but
agent transport and authority are not implemented by this slice.

Risk: CAUTION (edit authority, rendering and input isolation). Rollback: revert
the isolated local feature commit. Preserve the user-owned Makefile change.

## Admitted design and rejected surface

- First consumers: current-document Format, Rename and Quick Fix.
- Review is a read-only projection of the original and candidate piece-tree
  roots. It must not change live bytes, cursor, selection, Undo, LSP document
  version or disk before acceptance.
- Enter accepts the entire captured proposal, Escape rejects it. Existing
  editor/root/client/URI/version guards and atomic one-step Undo remain the
  authority. Navigation and unrelated keys cannot accidentally apply edits.
- Render within the active editor rectangle; retain source context instead
  of creating a detached sample-only popup. Bound visible row extraction and
  huge-line text. Any truncation must be visible, never presented as complete.
- Persistent snapshots and span metadata are allowed; full-document string
  copies or arrays of every rendered line are not.
- Reject partial application, foreign-document edits, filesystem operations,
  server commands, automatic save and applying stale proposals.
- Per-hunk accept/reject, editable pending proposals, agent integration,
  external-change/recovery comparison and syntax-colored proposed text are
  follow-up boundaries, not implied by an inline display.
- This is a line-level projection of the server's edit ranges, not a minimal
  text-diff algorithm. Equal prefixes/suffixes are trimmed, but a whole-file
  replacement with distant changes can remain one large review group.
  Wide/huge lines are visibly abbreviated; there is no horizontal review
  scrolling yet. Do not confuse bounded display with full visibility.

## Execution and falsifiers

1. Establish a failing inline-preview spec before production edits. Implement
   a bounded projection near `safe_document_edits.cr` and a dedicated renderer;
   connect the existing `modal_manager.cr` review lifecycle and popup state.
2. Check insertion, deletion, multiline/adjacent edits, unchanged context,
   Unicode/CRLF, long lines, off-screen edits, clipping and no-color markers.
3. Retain stale-response, stale-preview, paste/key isolation, cancellation,
   atomic Undo and unchanged-disk coverage from formatting/refactoring tests.
4. Parent inspect the implementation and run full specs, formatter, release
   build and both real PTY workflows. Update documentation with observed
   evidence only after those commands finish.

DoD commands (writable, separate compiler caches):

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-inline-parent crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-inline-build crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-inline-editor
ruby scripts/smoke_refactor.rb /private/tmp/adamantine-inline-editor
ruby scripts/smoke_format_git.rb /private/tmp/adamantine-inline-editor
```

Expected: all checks pass; rendered +/- lines are inside the editor pane;
cancel and preview leave bytes/history/disk unchanged; acceptance changes the
buffer once and Undo restores it. Strongest counterexample: display hides or
misrepresents an edit that Enter nevertheless accepts. Refresh this evidence
after projection, rendering, input routing, plan preparation or apply guards
change. Large-file responsiveness beyond measured probes is not certified.

## Verification and adversary result

Source lineage: the feature commit containing this document, based on
`c809760` (guarded current-document Rename and Quick Fix). All DoD commands
above passed on the final implementation: 863 full-suite examples, formatter
and diff checks, release build, and both real PTY workflows. The PTY probes
observed inline original/proposed text and accept/reject labels, cancellation,
apply/Undo, unchanged disk bytes, mixed-file rejection, no server command
execution, and retained read-only Git browsing.

Parent-owned reconstruction tests cover 1,000 deterministic random multiline
batches plus empty/final-newline/CRLF seams. Additional tests cover 4096 edits,
distant-hunk navigation, stale application rejection, bounded escaped rows,
private-root capture, directional controls, partial repaint coordinates,
wide-glyph boundaries, adjacent-cell preservation and narrow-pane hints.
The earlier implementation failed reconstruction/CRLF/EOF and sanitization
bounds; merged whole-line spans, strict context invariants and bounded output
replaced those failing routes. Review also exposed mutable constructor inputs,
missing bidi marks and partial-clip origin errors; targeted tests now cover
the corrected behavior. Parent adversary verdict: ROBUST within this contract,
not a certificate for per-hunk acceptance, agent authority, complete visibility
of truncated rows or arbitrary-server behavior. Refresh using the commands
above when the listed producer/renderer/input/apply boundaries change.

## Bounded performance probe

`scripts/benchmark_inline_preview.cr` is a release-mode probe, not a timing
assertion in CI. It excludes source loading, reports plan preparation
separately, then measures opening the projection, 200 hunk jumps and up to 30
row reads. On this macOS host, the 7,360,000-byte / 160,001-line fixture took
7.778 ms to prepare and 0.687 ms for the preview operations, with 33,440 gross
allocated bytes in the latter interval. The 6,000,000-byte single-line fixture
took 16.205 ms and 0.053 ms respectively, with 337,968 gross preview allocation
bytes. These are single-run observations, not end-to-end rendering latency,
peak RSS, universal bounds or benchmarks of every 4096-edit batch.

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-inline-build crystal build scripts/benchmark_inline_preview.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-inline-benchmark
/private/tmp/adamantine-inline-benchmark
/private/tmp/adamantine-inline-benchmark --single-line
```
