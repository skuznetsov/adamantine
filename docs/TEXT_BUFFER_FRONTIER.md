# Adamantine Text Buffer Frontier

Document status: implemented and verified against published `crystal_tui`
revision `d0005944d5c36f43adf592df397c9ef3658046b3`.

Current frontier: replace `Tui::TextEditor`'s line-array storage and full-text
undo snapshots with a piece-tree buffer that remains byte-for-byte compatible
with the editor's public text, line, cursor, save, rendering, folding, and undo
contracts. The migration must bound edit amplification for multi-megabyte UTF-8
source files without widening file-size, binary-file, or LSP mutation support.

## Admitted surface

- Valid UTF-8 documents accepted by the existing editor, up to Adamantine's
  existing file-size limit.
- Random line lookup and sequential visible-line iteration without materializing
  the complete document.
- Insert, delete, paste, replace, undo, and redo expressed as bounded edits over
  the piece tree.
- Explicit full-text materialization at compatibility boundaries such as
  `TextEditor#text`, `TextEditor#lines`, initial LSP open, and callers that
  request a complete copy.
- Byte-exact preservation of homogeneous and mixed LF, CRLF, and CR endings,
  plus atomic-save behavior.

## Rejected surface

- Treating arbitrary byte offsets inside a UTF-8 code point as edit boundaries.
- Full-document snapshots in the undo or redo history.
- Rebuilding an `Array(String)` or complete `String` on ordinary character edits
  or visible-line rendering.
- Silent normalization of file bytes beyond the editor's existing newline
  contract.
- Binary-file editing, concurrent collaborative editing, and unbounded files.

## Guard-only future

- Incremental LSP `didChange` ranges sourced directly from buffer edits.
- Persistent piece-tree snapshots for crash recovery or session restoration.
- Structural preservation of the current root when an external disk revision
  is accepted through the editor's reload-as-saved transition.
- Background compaction of append-only edit storage.
- Memory-mapped original buffers and files above the current size limit.

## Design laws

1. Original text storage is immutable and added text storage is append-only.
2. Pieces reference valid UTF-8 byte ranges and empty pieces never persist.
3. Every subtree caches exact byte length and logical newline count. CRLF is one
   newline even when its bytes belong to adjacent pieces; lone CR and lone LF
   are independently indexed. Cached metrics are checked recursively in tests.
4. Public cursor columns retain their existing Crystal character-index meaning.
5. LSP UTF-16 conversion remains a separate protocol-boundary responsibility.
6. Undo records edits or shared structural roots, never complete document text.
7. A compatibility method may materialize the document only when its caller
   explicitly asks for the complete document.

## Implemented shape

1. `Tui::PieceTreeBuffer` stores 2-8 KiB pieces in a persistent implicit treap
   with cached byte, codepoint, newline, count, and height metrics.
2. Original sources are immutable; inserted bytes use append-only 8 KiB pages.
3. Undo and redo retain shared tree roots. The tree rebuilds deterministically
   if its height exceeds 64.
4. `TextEditor` keeps character-indexed cursor semantics while translating edit
   coordinates to UTF-8 byte offsets at the buffer boundary.
5. Rendering requests only the visible line slice, and atomic save streams tree
   pieces instead of assembling a complete document string.
6. Word motion walks bounded source ranges sequentially and keeps at most one
   piece payload in transient string storage.
7. External reload replaces the saved root while retaining the prior root as a
   single bounded undo entry; saving and editor fingerprints stream tree pieces.

## Falsifier roster

- Insert/delete differential tests with a deterministic random seed.
- Empty, final-newline, homogeneous and mixed LF/CRLF/CR, emoji,
  combining-mark, and CJK fixtures.
- Invalid UTF-8-boundary edit rejection.
- Tree metric and balancing invariant checks after every randomized edit.
- Undo/redo round trips without full-document history fields.
- Multi-megabyte edit probes covering start, middle, and end of a document.
- Existing TextEditor file, rendering, folding, mouse, and Adamantine contract
  specs.

## Stop rules

- Stop integration if byte-for-byte differential tests fail, cursor behavior
  changes, or an edit path still captures the complete document for history.
- Do not claim bounded end-to-end typing cost while Adamantine still sends full
  document LSP changes; that optimization is a separate frontier slice.
- Do not update the Adamantine dependency pin until the upstream commit exists
  in a fetchable repository.

## Implementation seals

- Source/spec: `crystal_tui` piece-tree source, TextEditor integration, focused
  upstream specs, and Adamantine dependency contract specs.
- Observed upstream DoD: 36 focused buffer/editor examples pass. The complete
  suite adds no failures to the pinned baseline; its existing 8 failures and 2
  errors remain confined to Markdown and mouse-event specs (636 examples
  total).
- Observed Adamantine DoD: `make check` passes 339 examples against published
  `crystal_tui` revision `d0005944d5c36f43adf592df397c9ef3658046b3`
  without a `CRYSTAL_PATH` override.
- Observed 15 MiB probe: 100 distinct snapshots retain 15,729,004 source bytes,
  the tree height is 24, release-mode initialization takes 50.31 ms, the 100
  edits take 0.19 ms, and process peak RSS is 22,544,384 bytes on the measured
  host. These timings are diagnostic, not portable CI thresholds.
- Observed long-line adversary probe: moving one word across 200,000 ASCII
  characters takes 0.82 ms in release mode on the measured host, down from the
  rejected per-character tree-lookup implementation's 40.1 seconds.
- Publication seal: `crystal_tui` revision
  `d0005944d5c36f43adf592df397c9ef3658046b3` is fetchable; `shard.yml` and
  `shard.lock` pin it exactly, and `make check` passes without a `CRYSTAL_PATH`
  override.
- Residual boundary: crash recovery and files above the current limit remain
  separate. External-file conflict policy belongs to Adamantine rather than the
  generic text buffer.
- A whole-document `replace_text` necessarily retains the previous and new
  immutable sources while both undo states are reachable. The rare height-guard
  recovery is an O(piece-count) metadata rebuild; old snapshots can temporarily
  retain the preceding node graph, though source bytes remain shared.
- `TextEditor#lines` preserves its read result but now returns a materialized
  copy. Mutating the formerly exposed internal array was never a coherent edit
  transaction and is not preserved.
