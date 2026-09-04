# Adamantine Incremental LSP Synchronization Frontier

Document status: implementation verified against the published upstream
revision; upstream review and Adamantine PR integration pending.

Current frontier: propagate one structured text-edit event from
`Tui::TextEditor` to Adamantine and use it for LSP `textDocument/didChange`
when the server advertises incremental synchronization. Ordinary edits must not
materialize the complete document. Full-document synchronization remains the
compatibility and recovery path where a precise incremental edit is unavailable
or the server does not admit it.

## Admitted surface

- Insert, delete, newline, paste, and selection replacement represented as one
  post-mutation event with a pre-mutation range and exact replacement text.
- Existing `TextEditor#on_change` callbacks retained for source compatibility;
  the structured callback is an additional API.
- LSP ranges expressed in zero-based UTF-16 line/character coordinates while
  public editor cursor columns retain Crystal character-index semantics.
- Incremental `didChange` only when `textDocumentSync` is numeric kind `2` or
  an options object whose `change` member is kind `2`.
- Full-text `didChange` when the server advertises full synchronization, omits
  the capability, exposes an unsupported capability shape, or an editor event
  represents a whole-document/coarse operation.
- Full text for `didOpen`, reconnect, undo, redo, and whole-document replacement.
- Exact LF, CRLF, and CR replacement text matching the editor buffer.

## Rejected surface

- Reconstructing a change by diffing the complete pre-edit and post-edit text.
- Treating Crystal character columns or UTF-8 byte offsets as LSP UTF-16
  character positions.
- Sending incremental ranges to a server that advertises full synchronization.
- Emitting two version increments or two LSP changes for one selection
  replacement.
- Materializing the complete editor text on an admitted incremental edit path.
- Changing save, cursor, undo-history, or legacy callback semantics except to
  eliminate duplicate notifications for one logical edit.

## Guard-only future

- Incremental undo, redo, and whole-document replacement.
- Negotiation of position encodings other than UTF-16.
- Debouncing, batching, and multi-change `contentChanges` notifications.
- Server-requested dynamic synchronization registration.
- Suppressing synchronization entirely for servers that advertise sync kind
  `None`; this slice preserves Adamantine's existing fallback behavior.

## Design laws

1. A structured event describes exactly one logical mutation and is emitted
   after that mutation succeeds.
2. Its range is measured in the document state before the mutation; its text is
   the exact replacement stored by the editor, including newline bytes.
3. A selection replacement produces one event spanning the former selection,
   never a visible delete event followed by an insert event.
4. UTF-16 conversion uses cached subtree metrics and inspects at most the
   affected piece; it does not assemble the document or line array.
5. Adamantine increments the document version once per structured event and
   sends at most one `didChange` notification for that event.
6. Capability parsing is fail-closed for optimization: only explicit kind `2`
   enables incremental synchronization; every other shape uses the established
   full-text path.
7. The upstream `crystal_tui` revision must be fetchable before Adamantine pins
   it.

## Falsifier roster

- ASCII insertion, deletion, newline, paste, and selection-replacement events
  have the expected pre-edit range and exact text.
- Emoji before an edit position contributes two UTF-16 code units; combining
  marks and CJK characters retain their protocol-defined widths.
- CRLF and CR buffers produce logical ranges and exact inserted newline bytes.
- One selection replacement invokes both legacy and structured callbacks once.
- Undo, redo, and `replace_text` emit full-text events rather than guessed
  incremental ranges.
- Numeric and object-shaped incremental capabilities produce ranged JSON;
  full, absent, and malformed capabilities produce full-text JSON.
- A multi-megabyte ordinary edit does not call `TextEditor#text` and emits a
  bounded replacement payload.

## Stop rules

- Stop integration if a structured range is measured after mutation, a Unicode
  or newline fixture diverges, or one logical edit creates multiple versions.
- Stop the bounded-cost claim if any admitted incremental path calls
  `TextEditor#text`, `TextEditor#lines`, or another full-document materializer.
- Do not update Adamantine's dependency pin until the upstream commit is
  available from the configured GitHub repository.
- Do not call the slice verified until focused upstream tests, focused
  Adamantine protocol tests, the full Adamantine check, and a materialization
  adversary probe pass at the same source state.

## Verification seal

Local implementation evidence:

- Published `crystal_tui` commit `16bac34` implements structured text changes
  and cached UTF-16 metrics; its focused suite passes with 26 examples.
- The full upstream suite runs 644 examples and has the same four pre-existing
  mouse-spec failures as the 638-example clean `a0ebbd5` baseline; the six new
  examples introduce no failure.
- Adamantine's focused orchestration and protocol suite passes with 67 examples
  against that local upstream revision.
- `make check` passes against the exact fetchable dependency pin with 345
  examples, zero failures, and formatting clean, without a local source
  override.
- On an 8,000,000-character single-line buffer, ten one-byte incremental edits
  complete in 0.24 ms in release mode after cached UTF-16 metrics replaced the
  405.74 ms line-prefix scan; the emitted replacement payload remains one byte.

Publication seal:

- `16bac34` is published on `codex/structured-text-changes` and is under review
  through `crystal_tui` PR #8.
- Adamantine pins `16bac34bae6709a31c905dd3f5d9a987c923e1e5`; dependency
  resolution fetches it from GitHub.
- The remaining integration boundary is upstream review/merge followed by the
  Adamantine commit and PR.
