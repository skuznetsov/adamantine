# Editor improvement sequence

Status: user-approved sequence, started 2026-09-18. Slices 1, 2a and 2b passed
local verification, as have slices 2c, 3, 4, 5a and 5b. Next: slice 5c (EditorConfig).
Evidence for 2a and 2b is in `BUFFER_SEARCH_FRONTIER.md` and
`BUFFER_REPLACE_FRONTIER.md` respectively.
Later entries are planned capabilities, not release claims.

## Order and boundaries

| Slice | Status | Scope and acceptance signal |
| --- | --- | --- |
| 1. Honest search results | Locally verified | Partial project scans remain visibly partial with zero or nonzero matches, including Enter feedback. Complete empty scans still report no matches. |
| 2a. Large-buffer find | Locally verified | Chunked live find and repeat-search with bounded/cancellable work, original Unicode spans and guarded publication. Full suite: 537 examples; release build and bounded allocation/fiber-gap probes passed. See `BUFFER_SEARCH_FRONTIER.md` for tradeoffs and limits. |
| 2b. Large-buffer replace | Locally verified | Bounded scanning and batched atomic replacement, byte-exact single Undo/Redo and correct LSP notifications. Full suite: 564 examples; release build and allocation probes passed. See `BUFFER_REPLACE_FRONTIER.md` for synchronous execution and allocation tradeoffs. |
| 2c. LSP post-processing | Locally verified | Persistent snapshot streams replace repeated whole-document line snapshots; linear branch processing and identity/version guards. Full suite: 570 examples. Exact folding oracle and release benchmark passed; see `LSP_POSTPROCESS_FRONTIER.md` for limits. |
| 3. Unicode and tabs | Locally verified | Display-cell rendering/hit testing and grapheme editing with codepoint/UTF-16 boundary adapters. Full suite: 594 examples; release build, Unicode oracle, bounded allocation and stale-navigation checks passed. See `UNICODE_FRONTIER.md` for synchronous prefix-scan and terminal-width limits. |
| 4. Completion insertion | Locally verified | Selected plain-text insertion and strict UTF-16 textEdit ranges, single Undo/Redo with original cursor, bounded parser and modal isolation. Full suite: 633 examples; release build and parent counterexamples passed. See `COMPLETION_FRONTIER.md` for supported subset and limits. |
| 5a. Quick file opener | Locally verified | Configurable Ctrl+P, bounded metadata-only fuzzy search, single-worker cancellation and ordinary guarded opens. Full suite: 657 examples; release build and parent modal/open/limit checks passed. See `WORKFLOW_FRONTIER.md`. |
| 5b. Problems navigation | Locally verified | Bounded current-document list, source-order next/previous, version/client/edit invalidation, cooperative conversion and no-copy inverse coordinates. Full suite: 682 examples plus one added coordinate regression; release build passed. See `WORKFLOW_FRONTIER.md`. |
| 5c. EditorConfig | Planned | Per-project/file indentation and line-ending preferences with explicit precedence; do not silently rewrite existing file bytes. |
| 5d. Session restoration | Planned | Restore tabs, cursor and scroll positions safely; keep UI session state separate from unsaved-text recovery and external-file conflict handling. |

Implement and verify one slice before admitting the next. Later slices require
fresh source inspection and a bounded design before edits. No dependency pin
changes, new persistent format, workspace edits, snippets or code-action
execution are implied by the first slice. Completion extensions require their
own follow-up acceptance tests.

## Slice 1: honest search results

Risk: SAFE, local UI behavior change. The search limits and disk traversal stay
unchanged. Rollback: revert the atomic feature commit. Preserve unrelated
working-tree changes, including the user's Makefile. No remote publication.

Anchor: `ProjectSearch::Result#truncated` records scan/result limits and read
failures, but the empty panel and Enter feedback previously dropped it.

1. `spec/search_panel_render_spec.cr`, `spec/search_spec.cr`: first reproduce
   misleading zero-result output. Include a complete-zero control, nonzero
   partial results, loading/empty-query precedence, and Enter feedback.
2. `src/adamantine/search_panel.cr`: carry completeness into visible messages
   and the panel title without changing matching or navigation semantics.
3. Parent review and focused/full checks. The strongest counterexample is a
   project whose only matching file exceeds the scan limit: a partial empty
   result must not look like an exhaustive miss.

DoD commands on the current macOS host:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-search-parent-cache crystal spec spec/search_panel_render_spec.cr spec/search_spec.cr spec/project_search_spec.cr --link-flags=-fuse-ld=/usr/bin/ld
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-search-parent-cache crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
git diff --check
```

Expected: regression red before the change, all focused/full specs green after,
format and diff checks clean. Headless rendering and application tests do not
certify a real-terminal session or large-file latency/RSS.

Observed on the slice based on `574299e`, 2026-09-18: the new render and Enter
regressions failed before production changes. Parent verification after the
fix passed 33 focused examples and the full 501 examples, with no failures or
errors; formatting and diff checks passed. The parent-added 24-column guard
keeps the partial marker visible for zero and nonzero results without
overwriting the panel border. An application-level test searches an oversized
file containing the requested token and verifies that Enter reports a partial
result, rather than an exhaustive miss.

The release build also passed with
`CRYSTAL_CACHE_DIR=/private/tmp/adamantine-search-build-cache crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o bin/adamantine`,
followed by `bin/adamantine --help`.

Adversary verdict: ROBUST within this UI-completeness boundary. Empty-query,
loading and complete-zero controls retain their meanings. This slice does not
identify individual omission reasons, make limits configurable, change the
backend search limits, or improve large-file processing cost. Re-run the checks
after changes to search-state publication, panel layout or navigation feedback.

## Follow-up anchors and guards

- **2:** `search_panel.cr`, `project_search.cr`, `command_palette.cr`,
  `replace_utils.cr`, `semantic_tokens.cr`, `folding.cr`, `lsp_controller.cr`.
  CAUTION: scheduling and edit/history contracts. Extend the relevant frontier
  before implementation. Start with whole-document-getter guards and measured
  input latency/memory probes; include huge single lines, UTF-8 and mixed line
  endings. Test stale publication, cancellation, Undo/Redo and LSP sync.
  Existing document-size limits remain in force. A structural no-copy check
  alone is not an end-to-end responsiveness certificate.
- **3:** pinned `crystal_tui` TextEditor plus `editing_text_editor.cr` and LSP
  coordinate adapters. CAUTION: a coordinate change can corrupt edits. Preserve
  public codepoint-coordinate compatibility unless deliberately migrated and
  tested at every consumer. Cover `a\t界é🙂`, ZWJ sequences, clipping and mouse
  coordinates. Do not ship changes only in ignored `lib/`; choose a reproducible
  integration before implementation. Upstream publication needs authorization.
- **4:** `lsp_client.cr`, `lsp_controller.cr`, `lsp_popup_state.cr`,
  `input_router.cr`, `editing_text_editor.cr`. CAUTION: server responses gain
  document-mutation authority. Pin the supported completion subset first; test
  Unicode ranges, invalid ranges, stale versions and one-step Undo. Keep
  unsupported multi-document edits and command execution rejected.
- **5a/b:** existing command, keymap, overlay and navigation components. Test
  remapping, modal isolation, stale results and bounded work before new actions
  become defaults.
- **5c/d:** `settings_config.cr`, `document_orchestrator.cr`,
  `document_session.cr`, `recovery_controller.cr`. CAUTION: configuration and
  persistence. Specify precedence/formats, atomic writes and size limits first;
  test malformed state, missing/changed files, failed writes and recovery
  interaction. Never replace unsaved content merely to restore a UI session.

Refresh this sequence after each slice and before changes to dependencies,
coordinate contracts, search scheduling, configuration or recovery formats.
