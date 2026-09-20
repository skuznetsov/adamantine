# Contextual actions

Status: locally verified within the scope below.

## Scope and behavior

Quick Actions reuses F1 catalog titles, real keymap hints and command dispatch
for existing shared commands. Preserve the first four menu positions (find in
file, backward find, project find, replace); add formatting, rename, quick fix
and external review without requiring colon-command knowledge. Existing LSP
navigation actions remain a specialized menu; no new LSP wire capabilities.
Hints distinguish global bindings from command syntax; global hints reflect
actual configured bindings, including explicit unbinds. Menu selection uses
arrows/Enter or the first nine numbered entries, not the displayed global keys.

Unavailable actions remain visible/selectable with an explicit reason. Enter
or a numbered selection must recheck current availability, leave an unavailable
action open and never invoke it. Rendering is advisory; existing operation,
version and file-conflict guards remain authoritative. Availability is shared
with F1 discovery for commands exposed on both surfaces. Explicit raw command
semantics remain unchanged.

Reasons cover missing editor, disconnected/reconnecting LSP, unsupported
format/rename/quick-fix capabilities, and absent external conflict. General
LSP navigation retains existing capability semantics rather than inventing new
server requirements. No fuzzy dispatch, force-quit discovery or automatic save.

Context menus own unrelated keys, paste and mouse input; explicit existing
palette/quick-open transitions remain supported. Resize propagates. Opening
a menu invalidates pending editor paste. Existing close/external-review guards
cannot be replaced. Recovery menu callbacks keep their existing authority.

Menus scroll the selected row into view and display the selected unavailable
reason in a bounded footer. Drawing uses grapheme-aware clipping. Extremely
short terminals need not display every element, but must remain safely clipped.

## Plan, risks and falsifiers

Risk: CAUTION, shared menu dispatch and modal input. Rollback: one isolated
feature commit; no config, persistent format, dependency or lockfile changes.
User-owned Makefile changes are excluded.

1. `document_types.cr`, `context_menu_state.cr`, `modal_manager.cr`: add optional
   live availability to context actions, guarded selection and scrolling/reasons.
   Consumers enumerated with `rg 'LspContextAction.new|open_context_menu' src spec`:
   Quick Actions, LSP navigation, recovery and test-only menus. Defaults preserve
   existing generic/recovery callbacks.
2. `app.cr`, `command_palette.cr`, `lsp_controller.cr`: reuse shared metadata,
   add cheap read-only availability checks and isolate context-menu input.
3. Focused regressions before production changes; parent checks disabled/stale
   callbacks, literal command behavior, remapped/unbound hints, modal isolation,
   Unicode clipping and selected-row visibility on resize.

Strongest failure: a stale displayed enabled state authorizes a callback after
context changes, or a disabled selection leaks input into the editor. Test both
directions of state change and observable buffer/disk/callback effects.

DoD: focused specs, full `crystal spec --link-flags=-fuse-ld=/usr/bin/ld`,
`crystal tool format --check src spec`, `git diff --check`, release build and
actual PTY contextual-menu workflow plus palette/external/close/refactor/Git
regressions. Use writable `/private/tmp` Crystal caches. Other terminal emulators
and a general keymap/input-field redesign remain out of scope. Changes to shared
dispatch, availability, modal routing or rendering invalidate this evidence.

## Execution evidence (2026-09-19)

Baseline: `916851f`. Parent red tests demonstrated missing paste-generation
invalidation and an invisible selected row in short menus. A later render
falsifier exposed reason/hint clipping for short action labels; menu width now
accounts for the footer. A routing counterexample demonstrated that the global
Problems opener replaced an active menu. Its route now defers to context-menu
capture; F1 and Quick Open remain deliberate replacement paths.

Review also rejected use of the legacy `key_hint` helper: it falls back to
defaults for explicitly empty bindings. Contextual hints read the active map
without restoring those defaults. F1 availability is rendered in its footer,
not appended beyond a usually clipped description. Project search does not
require an open file. The existing numbered-find routing test now opens a
document and uses isolated configuration rather than the user's keymap.

Commands used (Crystal caches are isolated from the default read-only cache):

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-context-parent crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-context-build crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-context-editor
ruby scripts/smoke_context_actions.rb /private/tmp/adamantine-context-editor
ruby scripts/smoke_command_palette.rb /private/tmp/adamantine-context-editor
ruby scripts/smoke_external_review.rb /private/tmp/adamantine-context-editor
ruby scripts/smoke_close_confirmation.rb /private/tmp/adamantine-context-editor
ruby scripts/smoke_refactor.rb /private/tmp/adamantine-context-editor
ruby scripts/smoke_format_git.rb /private/tmp/adamantine-context-editor
```

Final full suite: 937 examples, 0 failures, 0 errors, 0 pending. Formatting,
Ruby syntax and diff-whitespace checks passed. Release build and all six PTY
probes passed. The new probe uses a 16-row
terminal, selects the last unavailable entry, verifies its reason, refuses
Problems replacement and pasted/typed edits, dispatches numbered Find, opens
and rejects a real formatting proposal, and resumes editing after Escape.
Its temporary disk source remains unchanged. Other probes retain external
reload/Undo, stale-overwrite refusal, close/quit cancellation, refactoring
accept/reject/Undo, and read-only Git navigation coverage.

The production diff hash (`git diff -- src | shasum -a 256`) remained
`50c4d7442e01654f14f1fe23c109d82de30846a6ddc4327932110d0175e372ab`
across the release build and probes. Release binary SHA-256:
`057b95fe3929820b3aaee40fe396f81259bb96da8a34029f5eda8e5ecf7f3493`.
The binary and raw terminal logs are temporary local artifacts; reproducible
scripts and assertions are committed evidence, not claims that every terminal
emulator was manually inspected.

Adversary verdict: ROBUST within the tested local scope after repairing the
observed clipping and Problems-routing counterexamples. Scope: stale
availability in both directions, numbered disabled
actions, remapped/unbound hints, unsupported/reconnecting LSP, modal input,
small/degenerate viewports, Unicode clipping and shared recovery-menu callback
compatibility. No automatic save, capability expansion or recovery overwrite
authority was added. Recovery comparisons are the next separate slice.
