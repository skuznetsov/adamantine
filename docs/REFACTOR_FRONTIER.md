# Current-document Rename and Quick Fix

Status: implemented and locally verified within the subset below (2026-09-19).
This is slice 3b of the editor roadmap, not multi-document refactoring support.

## Boundary and anchor

At the pre-change anchor, formatting prepared a detached `SafeDocumentEdits::Plan`,
guarded editor/buffer/URI/version/client/root/action identity, previewed bounded
samples and applied one Undo transaction without saving. Rename transport
existed but had no UI application path. The old code-action hint was read-only;
its request incorrectly used `position` instead of the required `range`.

Risk: CAUTION, because server responses confer edit authority. Rollback: revert
the isolated feature commit. Preserve the unrelated user-owned Makefile edit.

Admit `:rename NEW_NAME` at the cursor and `:quickfix` at the cursor. Require
an advertised server capability. Request UTF-16 positions/ranges through the
existing bounded async scheduler. Quick Fix admits eager CodeAction literals
with a direct edit; selection only opens a preview, a second Enter applies.
Escape cancels, and unrelated keys/paste/mouse cannot leak into the editor.
Neither operation writes files or executes server commands.

The current presentation is the [inline proposed-edit projection](INLINE_PREVIEW_FRONTIER.md),
shared with formatting. Enter accepts the whole batch, Escape rejects it and
Tab/Shift-Tab navigate changes without applying them.

Accept `WorkspaceEdit.changes` or `documentChanges`, never both. Every target
must exactly match the captured current URI. A versioned TextDocumentEdit
must match the captured version, or explicitly carry null. Reject duplicate
document entries, unknown edit envelope fields, malformed shapes, annotations,
resource operations and any foreign URI, including an open or dirty buffer.
Reject the whole operation, never apply a same-file subset of a wider rename.
Plain TextEdit validation and bounds remain owned by SafeDocumentEdits.

Code actions carrying commands, disabled state, unresolved edits or unsupported
payloads cannot apply. Bound the picker to 100 items and sanitize display text;
make omitted items visible. Request only quick fixes and filter explicit
non-quickfix kinds. A kindless direct edit remains a compatibility candidate.
The initial request uses an empty diagnostic context: retained UI diagnostics
do not preserve the server's opaque code/data. Servers requiring those fields
may offer no fix. Do not invent diagnostic identity or advertise resolve support.

Rename passes a bounded nonempty new name to the server for language-specific
validation; it does not advertise prepareRename support. Multi-document atomic
Undo, filesystem operations, lazy action resolution, automatic application and
complete server compatibility remain unimplemented, not implied by this slice.

The inspected Adamas source (`src/compiler/lsp/server.cr`, 2026-09-19) implements
Rename but its `create_quick_fix_action` returns nil unconditionally. Client
workflow verification does not imply that this server currently supplies fixes.
Recheck the compiler implementation before treating this observation as current.

## Execution and falsifiers

1. Add strict workspace-envelope extraction and protocol/capability tests in
   `workspace_document_edits.cr`, `lsp_client.cr` and dedicated specs. Establish
   a failing probe before adding production behavior.
2. Add request snapshots, commands, a bounded action picker and reuse guarded
   edit previews in controller/modal/app files. Test cancellation, one Undo,
   stale responses/previews, modal isolation and malformed/mixed-file replies.
3. Parent checks the diff, adversarial counterexamples and real wire/PTY flow.
   Run focused and full specs, formatter, release build and diff checks before
   the atomic local commit. No push is authorized.

DoD (use distinct cache directories for concurrent compilers):

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-refactor-parent crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-refactor-build crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-refactor-editor
ruby scripts/smoke_refactor.rb /private/tmp/adamantine-refactor-editor
ruby scripts/smoke_format_git.rb /private/tmp/adamantine-refactor-editor
```

Expected: green specs/build, clean format/diff, PTY rename and quick-fix
preview/cancel/apply/Undo with unchanged disk and no executeCommand calls.
Highest-risk counterexample: a valid first edit followed by a foreign target
or unsupported command must leave all live bytes and Undo unchanged.

Protocol anchors: official LSP 3.17 source for
[WorkspaceEdit](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/types/workspaceEdit.md),
[Rename](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/language/rename.md) and
[CodeAction](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/language/codeAction.md).
Refresh evidence after edit/history, snapshot guards, modal routing or LSP
capability/transport changes. Synchronous plan preparation retains the limits
and latency caveats in SAFE_EDITS_FRONTIER.md.

## Observed verification

The parent ran the complete suite on the final production source: 848 examples,
zero failures/errors/pending. The release build, `crystal tool format --check
src spec` and `git diff --check` passed. Focused protocol/parser/adversary tests
passed 17 examples; the UI suite contains 13 examples, including stale delayed
responses and stale previews for both operations.

The real PTY refactor probe passed rename preview/cancel/apply/Undo, whole-batch
mixed-file rejection, quick-fix picker/preview/cancel/apply/Undo, Tab isolation,
unchanged disk content and no server-command execution. The existing formatting
and Git PTY probe also passed preview cancellation, apply/Undo, Git history/diff
navigation and unchanged disk content. Both used the release executable and
deterministic wire-level fixture servers, not an actual Adamas server.

Red-to-green anchors: the pre-change executable could not issue the rename
request in the PTY probe; new parser tests initially had no implementation.
Parent counterexamples caught malformed capability handling, missing null-result
semantics, pending clipboard invalidation, narrow-terminal truncation and
Enter/Escape conflicts with configurable completion navigation. These now have
guards or regression tests. An independent text oracle additionally checks
32 Unicode/CRLF edit cases against the safe-edit plan.

The bounded Luna review found the final omission disclosure could disappear
with short action rows. A count-first title and title-aware bounded popup width
closed that finding; real-render regression tests cover 32- and 100-column
viewports. Parent inspection and the final DoD rerun support a ROBUST verdict
for the declared subset. Same-lineage model review is corroboration, not an
independent proof of completeness.

Evidence applies only to this current-document, eager-edit subset. It does not
establish server fix availability, lazy resolution, multi-document atomicity or
responsiveness beyond the existing safe-edit and transport limits. Test logs and
PTY captures are temporary; the committed specs and smoke scripts are the
reproducible evidence sources.
