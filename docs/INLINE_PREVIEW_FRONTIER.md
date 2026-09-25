# Inline proposed edits

Status: inline preview and safe selective acceptance implemented and verified
on the 2026-09-24 source snapshot.

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
- Source-backed displayed change groups start selected, preserving Enter's
  existing accept-all behavior. Space toggles the focused group, Tab and
  Shift-Tab move focus, A selects all, N selects none, and Enter applies the
  nonempty selection. Enter with zero groups selected refuses and leaves the
  review open; Escape rejects the proposal. Existing editor/root/client/URI/
  version and geometry guards remain the authority.
- A selectable group is a displayed change hunk with stable original LSP edit
  indices. Adjacent edits that the line-context projection merges are one
  indivisible group; a visual row is never treated as raw edit identity. If
  every source edit cannot be assigned exactly once to a displayed group,
  selective acceptance is conservatively disabled and the legacy accept-all
  path remains available.
- Applying a subset recomposes it from the plan's captured original snapshot,
  revalidates against the live editor, and applies in one Undo step. Errors or
  stale plans do not partially mutate the buffer. Acceptance changes only the
  buffer; it does not save to disk.
- Render within the active editor rectangle; retain source context instead
  of creating a detached sample-only popup. Bound visible row extraction and
  huge-line text. Any truncation must be visible, never presented as complete.
- Persistent snapshots and span metadata are allowed; full-document string
  copies or arrays of every rendered line are not.
- Reject incomplete raw-edit groups, foreign-document edits, filesystem
  operations, server commands, automatic save and applying stale proposals.
- Editable pending proposals, agent integration,
  external-change/recovery comparison and syntax-colored proposed text remain
  follow-up boundaries, not implied by an inline display.
- This is a line-level projection of the server's edit ranges, not a minimal
  text-diff algorithm. Equal prefixes/suffixes are trimmed, but a whole-file
  replacement with distant changes can remain one large review group.
  Changed rows use bounded source-codepoint windows. Left/Right pages through
  a long row; Shift-Left/Shift-Right moves one source codepoint, and the footer
  reports the one-based source column. A visible ellipsis or `[more]` means
  content remains; tabs are shown as `\t` so a page boundary cannot change
  their apparent tab stop. This makes long rows navigable without rendering
  them unboundedly. Group selection follows these same displayed hunks and
  does not claim independent identity for a visual line or raw protocol edit.

## Execution and falsifiers

1. Establish a failing inline-preview spec before production edits. Implement
   a bounded projection near `safe_document_edits.cr` and a dedicated renderer;
   connect the existing `modal_manager.cr` review lifecycle and popup state.
2. Check insertion, deletion, multiline/adjacent edits, unchanged context,
   Unicode/CRLF, long-line page and one-codepoint navigation, off-screen edits,
   clipping and no-color markers.
3. Retain stale-response, stale-preview, paste/key isolation, cancellation,
   atomic Undo and unchanged-disk coverage from formatting/refactoring tests.
4. Check selective grouping and source-index coverage, empty/partial/duplicate
   selection rejection, stale-plan rejection after selection, subset recompose
   from the captured root, Unicode/CRLF, cancellation, single Undo and replay
   rejection after Undo. Run full specs, formatter, release build and real PTY
   workflows.

DoD commands (writable, separate compiler caches):

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-selective-final-full crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-selective-final-build crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-selective-editor
ruby scripts/smoke_refactor.rb /private/tmp/adamantine-selective-editor
ruby scripts/smoke_format_git.rb /private/tmp/adamantine-selective-editor
ruby scripts/smoke_context_actions.rb /private/tmp/adamantine-selective-editor
```

Expected: all checks pass; rendered +/- lines are inside the editor pane;
cancel and preview leave bytes/history/disk unchanged; acceptance changes the
buffer once and Undo restores it. For selective acceptance, a distant chosen
group alone changes, merged adjacent edits remain indivisible, and an empty
selection cannot be accepted. Strongest counterexample: display hides or
misrepresents an edit that Enter nevertheless accepts. Refresh this evidence
after projection, rendering, input routing, plan preparation or apply guards
change. Large-file responsiveness beyond measured probes is not certified.

Selective-acceptance focused checks (2026-09-24): the combined formatting,
refactor UI, preview model and safe-edit specs passed 54 examples. Coverage
includes complete/partial/duplicate/empty group selections, adjacent merged
group indivisibility, distant edits, no-op source identity gaps, stale plans,
Unicode/CRLF, cancellation, one Undo and rejection of replay after Undo. Fresh
render buffers assert the visible selection count at 2/2, 0/2 and 1/2.

## Verification and adversary result

Source lineage: the inline-preview baseline was based on `c809760` (guarded
current-document Rename and Quick Fix). On the final selective-acceptance
snapshot, full specs passed 1128 examples; the whole-tree formatter and diff
checks passed; a release build succeeded; and all three real PTY workflows
passed. The refactor PTY verified visible proposals, cancel/apply/Undo,
mixed-file rejection, Quick Fix preview/cancel/apply/Undo, Tab-not-apply,
empty-selection refusal, selecting one of two distant changes, and unchanged
disk bytes. Format/Git and context-action PTY smokes also passed, including
their legend, modal-isolation and disk-preservation checks.

Parent-owned reconstruction tests cover 1,000 deterministic random multiline
batches plus empty/final-newline/CRLF seams. Additional tests cover 4096 edits,
distant-hunk navigation, stale application rejection, bounded escaped rows,
private-root capture, directional controls, partial repaint coordinates,
wide-glyph boundaries, adjacent-cell preservation and narrow-pane hints.
The earlier implementation failed reconstruction/CRLF/EOF and sanitization
bounds; merged whole-line spans, strict context invariants and bounded output
replaced those failing routes. Review also exposed mutable constructor inputs,
missing bidi marks and partial-clip origin errors; targeted tests now cover
the corrected behavior. Adversary verdict: ROBUST for the documented
current-document source-group acceptance contract. Context-merged edits remain
indivisible, and independent raw-edit acceptance is intentionally not claimed.
This is not a certificate for agent authority, complete visibility of
truncated rows or arbitrary-server behavior. Refresh using the commands above
when the listed producer/renderer/input/apply boundaries change.

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
