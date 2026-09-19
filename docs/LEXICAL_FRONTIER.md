# Independent lexical highlighting

## Admitted behavior

The app-owned `LexicalHighlighter` reads an immutable piece-tree source for
Crystal-family buffers. It recognizes a deliberately small subset: keywords,
identifier roles inferred from local context, decimal-like numbers, hash
comments and ordinary single/double-quoted strings. Quote state crosses lines;
token columns are codepoints, and the existing renderer maps them to cells.
Semantic LSP tokens override lexical spans; diagnostics retain their existing
priority. No LSP connection is required for the lexical layer.

An edit immediately discards old semantic positions and invalidates the lexer
from the changed line. Unaffected cached prefixes may survive. A missing state
checkpoint causes reconstruction from the beginning, not guessed string state.
The worker checks buffer identity and shutdown between non-yielding batches.
It neither changes text, Undo nor disk contents.

## Resource and coverage boundary

- One worker per buffer; rendering requests rows but never scans the source.
- At most 4,096 source codepoints per worker batch, with a 1 ms cooperative
  delay between batches. This is a work bound, not a hard wall-clock deadline.
- At most 256 completed rows and 4,096 retained token spans per buffer, plus
  the bounded in-progress row. Source chunks contain at most 2,048 codepoints.
- Rows longer than 4,096 codepoints or exceeding the span cap are plain;
  delimiter scanning continues so later ordinary rows can recover.
- Identifier classification retains at most 128 codepoints in a reusable
  scratch buffer. Longer names get generic identifier treatment.
- Rows are requested once per viewport/revision, capped at 256. If the visible
  token set exceeds cache capacity, evicted rows stay plain until the viewport
  changes or an edit invalidates it; repeated repaint must not cause a scan loop.
- An evicted or distant viewport may require a prefix rescan. Total scan work
  and time-to-color can therefore grow with file position, although batches and
  retained cache are bounded. There is no full-document text/line/character
  overlay in this layer. The piece-tree snapshot is shared, not deep-copied.

Unsupported percent literals, backticks and `<<` enter unknown state until the
end of the file. This intentionally includes ambiguous shift/append uses of
`<<`; all later lexical spans are plain, even after a syntactic closing marker.
LSP can still color those regions. Interpolation, regex literals, heredocs,
macro grammar and exact numeric suffix/operator parsing are not certified.
Supporting these constructs requires a separate bounded-state extension;
this initial slice must not be described as a complete Crystal highlighter.

## Verification

Parent-added red probes caught stale semantic positions, wrong restart offsets
across newline forms, requested-row eviction within a chunk, a one-row span
overflow, repeated scans of deliberately plain rows and arithmetic signs
incorrectly included in numeric spans. Focused tests also cover multiline
edits, Undo, Unicode/tab cells, cache-pressure settling and close/reopen identity.

Commands (Crystal 1.21.0, macOS; the system linker is required on this host):

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-lexical-parent-cache crystal spec spec/lexical_highlighter_spec.cr spec/lexical_adversary_spec.cr spec/lexical_integration_spec.cr --link-flags=-fuse-ld=/usr/bin/ld
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-lexical-parent-cache crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec scripts/benchmark_lexical_highlighting.cr
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-lexical-release-cache crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-lexical-editor
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-lexical-release-cache crystal build scripts/benchmark_lexical_highlighting.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-lexical-benchmark
```

Observed on 2026-09-19, based on `907fc7a` plus this isolated slice: 21 focused
examples and 758 full-suite examples passed, with no failures or errors.
Formatting, diff checks, release build and `--help` passed. A release PTY run
with `--no-lsp` opened the Unicode fixture through Ctrl+P, emitted the configured
keyword/comment/string/number colors and exited with status 0. The fixture's
SHA-256 was unchanged. The headless tests establish exact rendered-cell color
positions; the PTY check establishes native terminal startup/open/exit and ANSI
color output, not a visual audit across terminal emulators.

The parent also exercised an edit during a giant-line scan and quit with work
pending: new-revision colors replaced old state, the worker stopped, and disk
bytes remained unchanged. Parent adversary verdict: ROBUST within the admitted
subset and resource/lifecycle boundaries above; full-language coverage remains
explicitly outside that verdict.

Release lexical-only probes on 2026-09-19, excluding file loading and source
construction; other compiler work was running, so timings are observations,
not a stable performance gate:

| Input | Bytes | Total scan ms | Largest batch ms | Gross allocations | Live GC delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| Generated supported syntax, 480,001 lines | 6,080,000 | 190.554 | 5.067 | 119,078,896 | 81,920 |
| One huge line followed by `end` | 6,000,004 | 111.356 | 4.072 | 6,327,472 | 8,192 |
| Local Adamas `ast_to_hir.cr`, 121,807 lines | 5,494,646 | 75.853 | 2.505 | 19,515,744 | 65,536 |

Every probe checked source-work, cached-line and cached-span bounds; the script
has positive keyword/number controls. The Adamas run exercises traversal,
including unknown/plain regions, not full lexical coverage of that file.
Gross allocation is cumulative churn, not retained memory. Live GC delta is
a pessimistic collector estimate after collection, not process RSS. These
probes do not certify end-to-end rendering latency or every terminal.

Evidence is scoped to this implementation and local fixtures. Refresh it when
the lexer, snapshot API, edit notification contract or renderer changes.
Rollback is the isolated feature commit; buffer/Undo formats are unchanged.
