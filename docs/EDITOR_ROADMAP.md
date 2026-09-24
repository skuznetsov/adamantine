# Editor improvement sequence

## Approved UX sequence (2026-09-19)

The user approved a cohesive UX pass and explicitly prefers Cursor-style
proposed changes inside the editor over floating preview dialogs. The first
slice is [inline proposed edits](INLINE_PREVIEW_FRONTIER.md) for Format,
Rename and Quick Fix: whole-proposal accept/reject and atomic Undo, with no
automatic save. Per-hunk decisions and future agent producers follow only
after their separate authority and coordinate-rebasing contracts are tested.

This first slice is now locally verified: 863 specs, release build and both
real formatting/refactoring PTY workflows passed. Review remains whole-batch;
the rest of this UX queue is not implied complete by that result.

The next bounded slice, [file-scoped Save/Discard/Cancel](CLOSE_CONFIRMATION_FRONTIER.md),
is locally verified: 881 specs, release build and all three PTY workflows pass.
Cancel is the default; cancelling multi-file quit retains every tab, and
stale decisions cannot discard newer edits. Explicit saves remain saved.
External conflicts now have a separate
[non-interrupting inline review](EXTERNAL_REVIEW_FRONTIER.md): a tab/header
notice, explicit shortcut/Quick Actions/Save entry points, safe Later default,
and guarded Reload/Overwrite. Recovery comparisons remain a separate boundary.

The [searchable F1 palette](COMMAND_PALETTE_FRONTIER.md) adds named action
discovery, selected-row execution, argument preparation and keymap-aware hints.
Its catalog also generates the command list in Help. F1/Ctrl+Shift+P now open
discovery; explicit `:` and double Escape retain command mode.

[Contextual actions](CONTEXT_ACTIONS_FRONTIER.md) now reuse shared catalog
metadata and availability checks, expose disabled reasons, preserve numbered
search positions and scroll in short terminals. Context menus isolate editor
input, including paste and unrelated global actions. Local verification:
937 specs, release build and six PTY workflows passed. This is not a general
keymap or editable-input-field redesign.

The recovery-comparison slice is now implemented behind a separate read-only
authority boundary: full checkpoint identity is revalidated, Editor/Disk/
Checkpoint captures remain distinct, pairwise views cycle in-place, and a
standalone checkpoint view survives a missing original. Copy and discard stay
separate menu actions. Evidence and residual filesystem-race limits are in
[RECOVERY_PREVIEW_FRONTIER.md](RECOVERY_PREVIEW_FRONTIER.md). Local verification
covered 949 specs, the recovery-specific real PTY workflow, all six existing
PTY workflows and a release build.

The remaining approved UX queue is:

1. Extend consistent modal isolation beyond the verified close/quit,
   external-change review, palette and contextual-menu surfaces as other
   dialogs are improved.
2. Improve everyday operation: default/override/unbind keymap semantics,
   actionable LSP errors, normal editable input fields and compact terminals.

A bounded modal-isolation follow-up now covers Settings and generic LSP
popups: mouse events are consumed before they reach the editor behind these
render-only overlays. A regression test first proves the same click moves the
editor cursor without a modal, then requires unchanged cursor/text with each
modal open. This does not add mouse selection inside those dialogs or certify
every modal surface. The event-route specs passed 27 focused and 1045 full-suite
examples; formatting, release build, and the existing context-actions and LSP
recovery PTY controls passed. The mouse-specific proof is the real
`handle_event` path in the specs, not a terminal-level mouse smoke.

The normal editable-input and compact-rendering part is now locally verified
for the command palette, Search, Quick Open and the command-backed Rename path.
It adds grapheme-safe cursor/selection editing, clipboard and bracketed-paste
isolation, draft-preserving command history, atomic Quick Open limits and
width-1/2/3 rendering. Evidence and intentionally deferred behavior are in
[EDITABLE_INPUT_FRONTIER.md](EDITABLE_INPUT_FRONTIER.md). The bounded
default/override/explicit-unbind keymap semantics with conflict-aware shortcut
hints and actionable LSP error UX are both implemented. See
[KEYMAP_FRONTIER.md](KEYMAP_FRONTIER.md) and
[LSP_ERROR_UX_FRONTIER.md](LSP_ERROR_UX_FRONTIER.md) for their respective
verification states and boundaries.

Acceptance includes real workflows without requiring colon-command knowledge;
green unit tests alone do not establish intuitive interaction. Keep existing
keybindings unless an explicit migration or opt-in profile is provided.

## Next approved sequence (2026-09-19)

The user approved the following queue after the first sequence below. Start
with independent highlighting and LSP recovery; implement and verify each
bounded slice before widening the next. Status: slice 1 implemented within the
initial lexical subset; slice 2 is also locally verified. Slice 3a implements
safe current-document formatting. Slice 3b adds current-document Rename and
Quick Fix with the same guarded edit plans; see REFACTOR_FRONTIER.md for its
verification state and explicit server/workspace limitations.

1. LSP-independent incremental lexical highlighting for Adamas/Crystal, with
   semantic overlay priority and bounded work on large files.
2. Visible LSP health, manual restart, bounded automatic retries and guarded
   resynchronization of open documents.
3. Safe formatting, Rename and Quick Fix through a shared version-checked edit
   mechanism, preview and coherent Undo.
4. Diff preview for external changes, recovery and LSP edits.
5. Problems across open files, then project coverage where supported, with
   explicit coverage boundaries.
6. Automated responsiveness/resource scenarios for large files, huge single
   lines, hung LSP and bulk replacement. This slice is now locally verified;
   observed timing, allocation and RSS fields remain diagnostics rather than
   portable pass/fail limits. See
   [RESPONSIVENESS_FRONTIER.md](RESPONSIVENESS_FRONTIER.md).

Two-group split views for distinct files are implemented; their boundaries and
local verification are in [SPLIT_VIEWS_FRONTIER.md](SPLIT_VIEWS_FRONTIER.md).
Editor-owned templates are implemented through an explicit picker, bounded
user/project catalogs and local field navigation. LSP snippets remain a
separate UX/integration proposal; the editor still does not advertise the full
snippet grammar. See [TEMPLATE_FRONTIER.md](TEMPLATE_FRONTIER.md) and
[COMPLETION_FRONTIER.md](COMPLETION_FRONTIER.md).
The read-only Git gutter is implemented
within the [Git gutter frontier](GIT_GUTTER_FRONTIER.md).
No remote publication is authorized. Preserve the user's Makefile change.
Heavy work is delegated to Luna and independently checked by the parent.

The user also requested a read-only Git repository view adapted from Crystal
Ball. `:git` now provides bounded current-project status, approximate history
lanes and commit/file diff, without repository mutations. This is separate
from the in-file Git gutter. See [GIT_VIEW_FRONTIER.md](GIT_VIEW_FRONTIER.md).

### Completed slice: independent lexical highlighting

Risk: CAUTION (cache invalidation, scheduling and rendering). Rollback: revert
the isolated feature commit; do not alter the buffer storage or Undo format.
Anchor: `app.cr#seed_syntax_overlay` only seeds hash comments, allocating a
whole-document per-character overlay. Semantic tokens are the sole general
syntax source. The new layer must not depend on a connected LSP.

Design boundary: an app-owned lexer for keywords, comments, ordinary quoted
strings and numbers; codepoint spans consumed by the existing cell renderer.
Semantic tokens take precedence. Carry lexical string state between lines;
edits invalidate affected state and stale results may never publish. Cache and
per-turn scan work are bounded; unsupported constructs and exhausted work may
remain plain text. This is lexical assistance, not a Crystal parser or complete
language grammar. No dependency changes or filesystem writes from the lexer.

Execution: lexer and focused specs in `lexical_highlighter.cr`; rendering and
edit invalidation in `app.cr`/`document_types.cr`; integration specs and parent
counterexamples. First falsifiers: no-LSP keyword/string/comment colors,
multiline quote edits, Unicode columns, huge lines, semantic precedence and
closed/replaced buffers. Verify focused specs, full `crystal spec`, formatter,
release build and an actual no-LSP rendering smoke; use a writable temporary
Crystal cache and `--link-flags=-fuse-ld=/usr/bin/ld` on this macOS host.

Observed: 21 focused and 758 full-suite examples passed; formatter, diff checks,
release build and no-LSP PTY smoke passed. Release probes checked bounded work
and cache retention on the multi-megabyte Adamas file, generated supported
syntax and a 6 MB single line. Exact subset, fallback behavior, measurements
and evidence limits: [LEXICAL_FRONTIER.md](LEXICAL_FRONTIER.md). Unsupported
percent literals, backticks and `<<` leave the remaining lexical region plain;
this is explicitly not complete Crystal grammar support.

### Completed slice: LSP recovery

The original inspection found that `Lsp::Client#reader_failed` detaches transport
but leaves child cleanup to `stop`; restarting must stop/reap the old client
and must create a fresh instance. Previously `:cd` shut the connection down
without reconnecting, and run-loop cleanup did not stop the LSP client.

Implemented one recovery coordinator, retained launch configuration,
epoch/root guards, visible health and `:lsp restart`. Recovery startup runs in
a fiber; existing startup/transport timeout boundaries remain explicit. Use a
hard retry budget with backoff; a successful handshake alone does not reset
the budget and permit an endless initialize/crash loop. Resynchronize existing
buffer identities and current versions, without re-opening files or changing
Undo. Invalidate stale diagnostics, semantic tokens, folds and actions.

Falsifiers: real child EOF/reap and replacement, two-buffer resync, old-client
publication, repeatedly crashing servers, cancellation on root change/quit,
and editing/closing/opening a buffer while initialization or resync yields.
Observed: 17 recovery tests and 775 full-suite examples passed, along with
formatter, diff checks, release build and a real PTY open/restart/quit smoke.
The tests check current unsaved text/version and process cleanup, including
close/reopen during a yielded `didOpen`, immediate fresh diagnostics, retry
exhaustion, worker exceptions and quit during teardown. Exact commands and
remaining transport/startup limits: [LSP_RECOVERY_FRONTIER.md](LSP_RECOVERY_FRONTIER.md).

### Actionable LSP error UX (locally verified in App and bounded PTY workflows)

Startup and exhausted-recovery failures now retain a bounded, sanitized reason
and expose a manual path through F1 search for **LSP status**/**Restart LSP** or
`:lsp`/`:lsp restart`. Disabled configuration remains non-actionable until a
server is configured. Failure reasons clear on a new manual attempt,
reconfiguration, or successful connection; stale epochs may not publish the
terminal failed state, retry count, or failure log over a newer restart.

The initial slice passed 1040 specs, formatting and a release build, but its
first PTY attempt was inconclusive. Follow-up `8cca471` fixed first-layout
status-log visibility and put the F1 hint before long failure details. The
integrated suite then passed 1043 specs and a release build; headless rendering
tests checked the first visible frame, including an 80-column case. A fresh
bounded PTY workflow observed failure guidance, sent physical F1 through the
terminal parser, selected Restart LSP and observed one replacement peer; a
`--no-lsp` control stayed disabled. The PTY transcript is not a final-screen
model. See [LSP_ERROR_UX_FRONTIER.md](LSP_ERROR_UX_FRONTIER.md) for the exact
scope and residual limits.

### Slice 3a: safe current-document formatting

The shared detached edit plan and `:format` path now exist: strict original-
snapshot UTF-16 validation, whole-batch rejection, bounded preview, explicit
accept/cancel, identity/version/client/root guards and one-step Undo. See
[SAFE_EDITS_FRONTIER.md](SAFE_EDITS_FRONTIER.md) for verification and limits.

### Slice 3b: current-document Rename and Quick Fix

`:rename NEW_NAME` and `:quickfix` reuse the one-document plan without assuming
workspace write authority. Quick Fix requires action selection, then preview
confirmation. The whole operation is rejected if any target is foreign, a
version is stale, or a server command/resource operation/annotation is present.
There is no automatic save. Protocol, bounds, verification and current Adamas
server limitations are recorded in [REFACTOR_FRONTIER.md](REFACTOR_FRONTIER.md).
Multi-document transactions and lazy action resolution remain outside this slice.

### External-change and recovery review

External-change review is implemented with bounded editor/disk projection,
non-interrupting notices and explicit checked actions; see
[EXTERNAL_REVIEW_FRONTIER.md](EXTERNAL_REVIEW_FRONTIER.md) for evidence and
limits. Recovery preview now has its own comparison contract without weakening
checkpoint identity or allowing preview itself to write files; see
[RECOVERY_PREVIEW_FRONTIER.md](RECOVERY_PREVIEW_FRONTIER.md). Copy recovery and
explicit discard remain independent actions. Open-file and server-workspace
Problems are locally verified within their documented coverage contracts.
Repeatable large-file, single-line, replacement and stalled-LSP scenarios now
run through the scheduled/manual responsiveness runner; its structural gates
and diagnostic-only resource observations are in
[RESPONSIVENESS_FRONTIER.md](RESPONSIVENESS_FRONTIER.md).

## Previous completed sequence

Status: user-approved sequence, started 2026-09-18. Slices 1, 2a and 2b passed
local verification, as have slices 2c, 3, 4, 5a, 5b, 5c and 5d. This sequence is
implemented and locally verified within the documented per-slice boundaries.
Evidence for 2a and 2b is in `BUFFER_SEARCH_FRONTIER.md` and
`BUFFER_REPLACE_FRONTIER.md` respectively.
Final integrated suite: 737 examples passed; release build and restart PTY smoke
passed. This is local evidence, not certification of every terminal or LSP server.

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
| 5c. EditorConfig | Locally verified | Bounded per-file indentation, tab widths and insertion-only line-ending preferences with explicit precedence; existing bytes and Undo survive reconfiguration. Full suite: 707 examples; release build and parent glob/Unicode/precedence counterexamples passed. See `WORKFLOW_FRONTIER.md` for the supported subset. |
| 5d. Session restoration | Locally verified | Private atomic project-scoped UI metadata, guarded lifecycle, dirty-buffer reuse and bounded current-disk restoration. Full suite: 737 examples; release and two-tab restart PTY smoke passed. See `WORKFLOW_FRONTIER.md` for concurrency, durability and filesystem limits. |
| 5e. Open-file Problems | Locally verified | Bounded aggregate of diagnostics retained by live open buffers, exact stale-row guards and existing-tab navigation without disk rereads. Full suite: 959 examples; release build and two-file LSP PTY passed. See `PROBLEMS_FRONTIER.md`. |
| 5f. Server-workspace Problems | Locally verified | Capability-gated `workspace/diagnostic`, asynchronous loading, bounded server-reported coverage, alias-safe open-buffer precedence and stamp-guarded unopened-file navigation. Full suite: 982 examples; release build and pull-capable UTF-16 PTY passed. This is not a completeness claim. See `PROBLEMS_FRONTIER.md`. |
| 6. Responsiveness/resource scenarios | Locally verified | Release probes cover multi-megabyte many-line and single-line search, lexical highlighting, replacement and inline preview. A bounded asynchronous LSP writer prevents a no-read server from blocking the caller and fails closed on count/byte backpressure. Scheduled/manual CI validates behavior and report structure; timing, allocation and RSS remain observations. See `RESPONSIVENESS_FRONTIER.md`. |

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
