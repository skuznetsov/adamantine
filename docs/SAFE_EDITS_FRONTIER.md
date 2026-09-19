# Safe document edits

Status: implemented and locally verified. Scope: one current document
formatted by its connected LSP; no filesystem writes or multi-document edits.

The existing piece-tree replacement fork and single history transaction are
the anchor. The formatting client now has a guarded preview/application path.
Risk: CAUTION (server-controlled mutations and history). Rollback: revert the
isolated feature commit, preserving the unrelated user Makefile change.

## Design laws

- Capture editor/buffer identity, URI, version, client, root and action epoch.
  Revalidate before publishing preview and immediately before applying.
- Strict UTF-16 ranges against the original snapshot; reject malformed,
  out-of-bounds, reversed, overlapping or ambiguous same-position edits.
  No surrogate splitting, annotations, resource operations or server commands.
- Validate the complete batch before live mutation; build a detached candidate
  with bounded edit count and replacement/output bytes. Reject the whole batch
  on any error. Empty/no-op responses do not create Undo entries.
- Show a bounded, explicitly truncated per-edit before/after preview. Enter
  applies the complete validated batch; Escape cancels. Preview truncation is
  display-only and must be visible. Exactly one Undo restores original bytes.
- Use per-document indentation options and the existing bounded async LSP
  action scheduler. No auto-save, auto-format or multi-document changes.

Rename and Quick Fix reuse this engine under the separately bounded
[refactoring frontier](REFACTOR_FRONTIER.md). File operations and
general-purpose diff integration are not admitted by this formatting slice.

## Execution and falsifiers

1. `safe_document_edits.cr`, editor adapter and focused specs: first failing
   probes for multi-edit transaction, Unicode/CRLF, overlap, late malformed
   edit, stale snapshot, no-op and limits; then implement the detached batch.
2. `lsp_client.cr`, `lsp_action.cr`, `lsp_controller.cr`, popup state/manager
   and command palette: capability/options, async formatting, guarded preview
   and explicit acceptance. Test cancellation, edits/replaced editor/client,
   project switch and modal isolation while waiting or previewing.
3. Parent counterexamples, full specs, format/diff checks, release build and
   terminal smoke. Update this document with observed evidence and limits.

DoD on this macOS host:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-recovery-cache crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-recovery-release-cache crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-format-editor
```

Expected: all tests pass, clean formatter/diff checks, successful release build;
manual/PTY preview-cancel-apply-Undo must not be conflated with every-server
compatibility. Refresh evidence when coordinates, history, modal routing or
LSP lifecycle changes. Protocol references: LSP 3.17 document formatting and
TextEdit specifications (microsoft/language-server-protocol).

## Implementation limits

The detached piece-tree plan admits at most 4,096 plain edits, 16 MiB of
replacement text and 16 MiB of output growth (also bounded by Int32 byte
offsets). Preview is capped at 256 rows and 4,096 bytes per row. Omitted rows
and text samples are marked; narrower terminal clipping uses an ellipsis.
Enter applies the full batch, not just the displayed sample.

Preparation is synchronous after the asynchronous server response. It avoids
whole-document text/line materializers, but coordinate scans and exact net-no-op
comparison can still cost O(document bytes). This is not a latency or RSS
guarantee for arbitrarily large formatting responses. Existing LSP document
and transport limits remain in effect. Ambiguous colocated insertions are
rejected rather than assigned an invented ordering. Servers without a
document-formatting capability remain unsupported.

Parent counterexamples include 80 independently computed Unicode edit batches,
late malformed-surrogate rejection, detached-preview mutation, single-use
plans, and a 2.4 MB single-line edit with whole-document getters disabled.
Byte-exact one-step Undo/Redo is checked separately from LSP modal integration.

## Observed verification (2026-09-19)

Parent full-suite run passed 817 examples with zero failures/errors using
`CRYSTAL_CACHE_DIR=/private/tmp/adamantine-final-parent-20260919` and the linker
flag above. This includes the contemporaneous read-only Git feature. Formatting
has 14 dedicated integration examples and nine shared-engine/adversary examples.
An export of the formatting-only staged tree also passed its complete suite:
800 examples, zero failures/errors, with no Git feature files present.
Formatter and diff checks passed. A release build and real PTY exercised
preview cancel, apply, byte-exact Undo notifications and unchanged disk bytes
against `spec/fixtures/formatting_probe_server.rb`.

The same-lineage reviewer found an Escape hint/key-remapping mismatch; raw
Escape/Enter and navigation keys now remain valid under completion remaps,
with a regression. Parent clipping/scrolling, indentation-option and stale
identity counterexamples are also covered. Adversary verdict: ROBUST for the
declared single-document subset, not for workspace edits or every LSP server.
Refresh on the coordinate/history/modal/LSP lifecycle changes named above.

Use separate Crystal cache directories for simultaneous `crystal spec` runs:
the compiler's shared `crystal-run-spec.tmp` can disappear while subprocess
tests still need it. A concurrent-cache run failed that way; the isolated
parent rerun above passed.
