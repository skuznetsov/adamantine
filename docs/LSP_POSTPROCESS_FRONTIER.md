# LSP post-processing frontier

Status: locally verified on 2026-09-18. Base: `8b057c0`.

Slice 2c removes whole-document line snapshots from semantic overlay and
Crystal branch-fold post-processing. Read lines lazily from a persistent buffer
snapshot; preserve current token/branch behavior and reject stale publication.
No dependency changes, wire protocol changes, or broader file-size support.
Unicode coordinate corrections belong to the following slice.

CAUTION: publishing stale overlays or folds can misrepresent edited text.
Rollback: revert this slice's atomic commit. Keep the unrelated Makefile edit.
First falsifier: an editor whose `lines` getter raises must still finish semantic
and Crystal folding processing. Compare lazy and array inputs on empty, Unicode,
mixed-line-ending and branch fixtures. Include changed/closed/reopened documents
while a response is pending. A no-getter assertion is not an RSS/latency claim.

Plan: extend the existing persistent source with a line-access adapter; update
`semantic_tokens.cr` and `folding.cr` consumers; integrate in `lsp_controller.cr`;
add focused and application-level regressions. Preserve compatibility overloads
for current array callers. Do not cache every source line in the adapter.

DoD: focused specs plus full `crystal spec` using a writable cache and
`--link-flags=-fuse-ld=/usr/bin/ld`, formatter, diff check, release build and
`--help`. Refresh evidence after persistence, LSP lifecycle or overlay changes.

## Observed evidence

- Initial missing-adapter regression was red. Parent full suite: 570 examples,
  zero failures/errors. Formatting, diff checks, release application build and
  `--help` passed with the Apple linker.
- Parent oracle compares 120 seeded branch fixtures against the original
  forward-scan implementation, including duplicate pre-existing ranges. Line
  readers match the editor on mixed CR/LF/CRLF, Unicode and chunk boundaries.
- Lifecycle tests reject version changes without a generation change and
  closing/reopening the same path while a response is pending.
- Release `scripts/benchmark_lsp_postprocess.cr`, actual 5,494,646-byte
  `ast_to_hir.cr`: baseline 2545–2551 ms / 73.4 MB gross allocation; snapshot
  80–84 ms / 39.1 MB. Three iterations each, with exact equality of all 5222
  folding ranges against the old implementation checked outside the timer.
  Reproduce with `crystal build scripts/benchmark_lsp_postprocess.cr --release
  --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-post-benchmark`,
  then run the binary with a file path and `baseline` or `snapshot`.

Adversary verdict: ROBUST within the post-processing boundary. This is not an
end-to-end LSP latency or peak-RSS certificate: server work is excluded, CPU
processing remains synchronous, a giant single line is still materialized,
and overlay rows still consume space proportional to codepoints. The prior
Unicode wire-coordinate limitation is explicitly deferred to slice 3.
