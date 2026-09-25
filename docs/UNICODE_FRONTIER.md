# Unicode and tab coordinate frontier

Status: slice 3 locally verified, 2026-09-18 (New York).

## Coordinate boundaries

Editor cursor, selection, search and navigation history columns remain Unicode
codepoint indexes. Crystal `String#size` counts codepoints, not bytes. Terminal
x coordinates count display cells, with tabs advancing to a tab stop and each
extended grapheme rendered as one cluster of its measured width. LSP positions
count UTF-16 code units; never reuse a wire column as an editor column.

The current incremental TextChange already carries UTF-16 positions and must
not be converted twice. Convert interactive request columns at the protocol
boundary, incoming navigation/diagnostics at consumption, and semantic token
ranges before painting codepoint-indexed rows. Preserve stale-response guards.
Reference: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#position

## Admitted design

- Keep the pinned dependency unchanged; ship app-owned adapters/overrides.
- Add tested codepoint/UTF-16 conversion with explicit invalid-position policy:
  reject negative lines/columns, reject surrogate-interior mutation ranges,
  and clamp oversized non-mutating navigation to a valid end position.
- Horizontal movement and single-character deletion operate on extended
  graphemes. Public programmatic coordinates remain codepoints. Preserve one
  Undo/Redo operation, original bytes, selections and existing CRLF handling.
- Render tabs, wide glyphs and combining/ZWJ clusters consistently with cursor,
  hit testing, selection, clipping and horizontal scrolling. Do not output a
  half-wide glyph across a clip boundary. Retain fold gutters/placeholders,
  styling callbacks and scrollbar behavior.
- Use bounded buffer reads where practicable; never reintroduce document-wide
  getters into rendering. Terminal-specific ambiguous-width policy remains
  the pinned Unicode utility's responsibility.

Rejected: public coordinate migration, normalization of user text, arbitrary
workspace edits, snippets, dependency-only patches in ignored `lib/`, and an
universal guarantee that all terminals/font combinations render identically.

## Plan, risk and checks

CAUTION: coordinate errors may delete the wrong text. Rollback is the atomic
slice commit, or separate coherent coordinate/render commits if needed. Parent
owns integration review and final evidence; Luna implements independent parts.

1. LSP adapters: `lsp_action.cr`, `lsp_controller.cr`, `semantic_tokens.cr`,
   app-owned coordinate helper and targeted specs. Inventory all position
   producers/consumers, leaving internal search/marks/history unchanged.
2. Editor: app-owned grapheme/layout helper and `EditingTextEditor` overrides,
   root rendering/mouse/navigation/deletion specs. No ignored dependency edits.
3. First demonstrate failures using `a\t界é🙂`, `👩‍💻`, CRLF, clipping and
   position-after-emoji examples. Verify request/response round trips and the
   existing incremental-sync tests. Add invalid and stale controls.
4. Run full `crystal spec --link-flags=-fuse-ld=/usr/bin/ld` with a writable
   cache, formatting, diff check, release build and `--help`; use a PTY smoke
   check in the final series. Headless cell checks do not certify every terminal.

Refresh these checks after dependency, display-width, protocol or edit-history
changes. Completion insertion depends on the mutation-safe coordinate adapter.

## Parent probes

The initial editor falsifiers reproduced a cursor stopping inside `e\u0301`
and a tab being painted as one cell. The parent regressions now cover
independently specified combining/ZWJ/flag/skin-tone boundaries, deletion and
Undo/Redo, selection containment, scrolled folded placeholders and gutter
protection, plus bounded visible-prefix rendering and mouse input on a 4 MB
single line with whole-document/whole-line getters forbidden.

Streaming segmentation is compared with `String#each_grapheme` across 1024-
codepoint read boundaries. A 128,000-mark combining cluster checks allocation
growth; it is not a universal input-latency guarantee. Stateful segmentation
avoids repeatedly copying the growing cluster, and single-character clusters
avoid allocating a builder for every ASCII character.

The coordinate oracle checks 100 seeded mixed Unicode lines at every valid
UTF-16/codepoint boundary and rejects surrogate interiors. Hostile large token
deltas must not overflow. Diagnostics are converted once on publication and
stored in codepoint coordinates; incremental text changes already carry
UTF-16 and remain unchanged. Navigation resolves against the actual target
editor during guarded opening, not a separate disk snapshot.

Release post-processing recheck on the 5,494,646-byte Adamas `ast_to_hir.cr`:
91.755–94.907 ms, 46,957,472–46,964,512 gross allocated bytes, with all 5,222
fold ranges equal to the array-based reference. This is local synchronous CPU
and allocation measurement, not retained RSS, LSP-server latency or UI frame
latency. Unicode-aware cell mapping still scans a line prefix; very deep
cursor moves in a giant single line can block the UI. Incoming conversion may
materialize one line, and semantic overlays remain codepoint-sized.

Final checks: full root suite, 594 examples with no failures/errors; formatter
and diff checks; release application build and `--help`. A 4-million-character
ASCII cursor scan allocates under 32 MB, guarded by a root regression; cached
ASCII glyph strings avoid a per-cell string allocation. Parent adversary
verdict: ROBUST within the declared coordinate/editing boundary, with the
synchronous prefix-scan and terminal-width limitations above. PTY smoke remains
part of the final series acceptance, not evidence claimed by this slice.
