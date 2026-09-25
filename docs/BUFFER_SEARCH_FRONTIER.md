# In-file buffer search frontier

Status: locally verified (2026-09-18).
Scope: roadmap slice 2a, based on `88005ac`. Project disk search, replacement,
LSP post-processing and terminal Unicode rendering are separate slices.

## Admitted design

- Literal live find and repeat commands read the piece tree through bounded
  chunks, not `editor.text`, `editor.lines` or complete logical-line copies.
- A search source retains an O(1) copy of the persistent buffer root, exposing
  only reads. Searches must not modify the document or history. Source bytes
  remain shared; append-only storage may grow while the old root is read.
- Small buffers (at most 64 KiB) may execute synchronously through the same
  engine. Larger live queries are debounced and scanned cooperatively.
- Keep at most one running in-file scan and one replaceable pending request.
  Capture a source only when a current request begins scanning. Superseding,
  dismissal, edits, tab changes and shutdown invalidate pending publication.
- Publication requires the same document identity/version, query/case mode,
  request generation and relevant cursor/panel state. Old results must neither
  select text nor update the result list after invalidation, even after an ABA
  tab/query round trip. Errors must release scheduler state and be visible.
- Live results retain the 200-match cap and explicit partial marker. Repeat
  search is not restricted to those 200 matches; it locates the next/previous
  occurrence and wraps, including earlier/later positions on the same line.
- Coordinates refer to original codepoints, not bytes or lowercased-string
  offsets. LF, CRLF and lone CR are logical line boundaries. Search does not
  change document bytes. No multiline query matching is added.
- Unicode case-insensitive matches must preserve original match spans when
  lowercase mapping changes length. Snippets and matching scratch storage
  must not grow with a huge line. Storage may grow with the query and bounded
  result count; no regex or unbounded result collection is added.

## Risks and non-guarantees

CAUTION: asynchronous results can move the cursor in a different/edited file;
chunked matching can miss boundary matches or report transformed coordinates.
Guard both with behavioral regressions before shipping. Keep the dependency
pin unchanged, preserve unrelated Makefile edits, and commit the slice
atomically after checks. No remote publication is authorized.

The intended value is responsive, correct find. No-full-copy guards prove a
resource routing property, not a latency or total-process memory bound. Record
release-mode scan and cooperative scheduling measurements separately; preserve
match correctness and cancellation as counterchecks. Rendering, LSP work,
document opening and worst-case arbitrarily long queries remain outside the
input-latency claim. Existing document-size limits remain unchanged.

## Execution and consumer inventory

1. `buffer_search.cr`, `editing_text_editor.cr`: bounded read source and matcher.
   First tests reject full-text/line getters and exercise boundaries, case,
   original coordinates, immutable-root behavior and cancellation.
2. `search_panel.cr`, `command_palette.cr`, `app.cr`, `navigation_controller.cr`
   and `document_orchestrator.cr`: replace
   live `ProjectSearch.search_text(editor.text, ...)` and repeat
   `editor.text.split` paths, then add bounded scheduling/publication guards.
   Tests cover live jumps, n/N, wrapping, cap independence and stale results.
3. Parent independently reviews the boundary cases, runs focused/full specs,
   formatting, build and a release probe. Update `EDITOR_ROADMAP.md` and README
   with the observed boundary, not a blanket performance claim.

Inventory: `rg 'search_text|search_forward|search_backward|search_in_active_editor'
src spec` identifies the live panel, repeat helpers and tests. The disk search
API remains available. `ProjectSearch::Match` is shared with project search and
render specs: any optional original-span metadata must default compatibly, and
both consumers must continue to render/navigate old matches correctly.

## Falsifiers and DoD

- Match crossing a read boundary; many short lines and a multi-megabyte single
  line; LF/CRLF/CR split across chunks; empty document/query; no match and cap.
- CJK, emoji, combining marks and length-changing lowercase mappings; compare
  against a simple independent reference on bounded randomized fixtures.
- Forward/backward navigation, one-line wrap, matches beyond the live cap;
  no document mutation or history entries from search.
- Supersede a scan, edit, close/reopen, change tabs away/back, move cursor,
  dismiss, change case, and stop the app before publication. Verify another
  fiber progresses during scanning and cancellation stops stale work.
- Repeated input does not retain unbounded sources/requests; the scheduler
  recovers after errors. Search failures do not masquerade as exhaustive misses.

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-buffer-search-parent-cache crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec scripts/benchmark_buffer_search.cr
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-buffer-search-build-cache crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o bin/adamantine
bin/adamantine --help
```

Expected: regressions fail before their implementation, focused and full suites
pass afterwards; no full-document/line getters in the in-file scan paths.
Re-run after matcher, scheduler, buffer persistence or search-coordinate changes.

## Review evidence

Parent-added randomized reference comparisons cover mixed line endings, Unicode
case expansion, overlap, and both repeat directions. A CRLF-at-chunk-boundary
probe rejected the first reader because the piece tree disallows slicing
between CR and LF; bounded over-read with byte-based trimming resolves that
boundary without changing document bytes. A multibyte-prefix control checks
that trimming uses byte offsets, not character indices.

Integration review also caught repeat direction being overwritten by `N`,
stale debounce requests retaining loading state, and a first-tab reopen that
did not dispatch a new query. Regression coverage now exercises those paths.
The standalone application build additionally caught a constructor dependency
cycle that subclass-based specs did not expose: the change callback is installed
after the document orchestrator exists. Build the application as well as specs.

The runtime getter guard rejects whole-text/line materialization in the live
and repeat paths. Query churn must capture exactly one source for the latest
pending request, with a distinct matching result as its positive control.
Held-source lifecycle tests force old work to resume after invalidation rather
than relying only on timing to expose stale publication.

Final parent verification of this slice based on `88005ac`: 537 full-suite
examples, zero failures/errors/pending; format and diff checks passed. The
release application build and `bin/adamantine --help` passed. The new coverage
includes 19 matcher/reference examples, 7 integration examples and 10 lifecycle
examples. No dependency pin or document-size limit changed.

Adversary verdict: ROBUST within the admitted matcher and publication boundary.
The claim is based on runtime guards, randomized reference comparisons, forced
stale interleavings, the full regression suite and a standalone release build;
model agreement alone is not evidence. No interactive terminal session, global
RSS bound, replacement behavior or LSP post-processing improvement is certified.
Rollback is reverting the atomic slice commit. Re-run the DoD after changing the matcher,
search scheduling, tab activation, buffer persistence or coordinate contracts.

## Release probe (2026-09-18)

`scripts/benchmark_buffer_search.cr` compares the former `editor.text` plus
`ProjectSearch.search_text` route with the cooperative buffer route in the same
release executable. It asserts a positive matching control and an absent-token
result, initializes the editor and runs explicit GC before timing, then records
gross GC allocation and the largest observed gap of a competing yielding fiber.
Three scans per fixture; times and allocations below are medians, fiber gaps
are the largest observed across the three runs. These are local diagnostics,
not portable thresholds or total-process RSS measurements.

| Fixture | Scan ms, old / buffer | Allocated bytes, old / buffer | Largest fiber gap ms, old / buffer |
| --- | --- | --- | --- |
| 4,000,000 bytes, short lines | 12.262 / 33.182 | 9,186,736 / 4,220,416 | 12.843 / 0.413 |
| 4,000,000 bytes, one line | 11.049 / 31.456 | 8,000,224 / 4,220,608 | 11.170 / 0.524 |
| 5,494,646 bytes, `ast_to_hir.cr` | 16.396 / 42.154 | 18,122,864 / 5,797,696 | 16.739 / 0.467 |

The real-file input was the local Adamas compiler's `src/compiler/hir/ast_to_hir.cr`,
SHA-256 `34d0204ba29951a0e3a93f9d86485284d11503589a395f9e4b53bf467a9c592d`.
No source content from that repository is included here.

The tradeoff is explicit: this matcher does more total scan work than the
optimized whole-string search on these no-hit fixtures, while substantially
reducing allocation and uninterrupted fiber time. Debounce, rendering, opening,
selection, LSP activity and real terminal input latency are not timed here.
The KMP failure table avoids the repeated-prefix quadratic comparison route;
chunk sizes and scratch allocation remain bounded apart from query storage.

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-buffer-search-probe-cache crystal build scripts/benchmark_buffer_search.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-buffer-search-probe
/private/tmp/adamantine-buffer-search-probe baseline
/private/tmp/adamantine-buffer-search-probe buffer
# Append an input path to either command to measure an initialized real file.
```
