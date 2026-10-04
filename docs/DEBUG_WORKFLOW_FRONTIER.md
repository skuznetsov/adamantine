# Debug workflow finishing frontier

Status: **IN_PROGRESS — Settings focused gate passed; joined App/layout gates
pending**, 2026-10-04.
Parent boundaries: [DEBUGGER_FRONTIER.md](DEBUGGER_FRONTIER.md) and
[DEBUG_VALUES_FRONTIER.md](DEBUG_VALUES_FRONTIER.md).

## Goal and current anchor

Finish the current debugger before implementing the deferred assistant or
scripting ideas. At `6c0f9ce`, generic App/PTY and real native-value controller
checks are separate. `DebugWorkspace` is a full-width bottom dock; the DAP
message limit is persisted but has no Settings entry. The accepted layout is
a two-column left activity rail, a side inspector, and an independent bottom
area for a future chat. The user now authorizes the layout/shared-border work.

## Admitted baseline and planned widening

- Existing launch, breakpoints, stepping, bounded value inspection and cleanup
  remain admitted only in their previously recorded contexts.
- A joined real-Crystal App/PTY gate must exercise reviewed launch, source
  breakpoint, displayed scalar/native values, a changed location after Step,
  explicit Stop, Quit and owned-process cleanup. A real controller result or
  accumulated terminal text alone cannot substitute for current-screen truth.
- The activity rail uses one letter column and one shared-separator column.
  Files and Debug select the side inspector without losing editor tabs or
  debugger state. Active background is supplementary to a non-color selection
  signal. Default Debug placement is left; left/right/bottom placement is an
  explicit editor preference, not a session execution action.
- Workspace boundaries use single shared lines and correct junctions, taking
  `crystal_ball/src/tui/app.cr` as a source reference. No dependency pin or
  ignored `lib` change may supply required behavior.
- Settings exposes the existing 1–64 MiB DAP message limit, sampled at the next
  explicit Start. Saving preserves unrelated config/keymap fields. Failure is
  visible; no active session's transport limits change silently.

## Rejected and separate surfaces

No assistant runtime, model requests, paid calls, Lua dependency, LSP snippets,
target evaluation during rendering, compiler changes, adapter installation,
auto-build/auto-launch, remote publication, attach or inferior terminal is
admitted by these three finishing slices. Attach/terminal and broader native
layouts retain their existing later debugger gates. Adamas ABI/debug-info work
belongs to a separate compiler task. The bottom area remains the existing
status surface until chat implementation is separately authorized.

## Safety and rollback

Risk: CAUTION for process execution, layout/focus routing and preferences.
Use only existing explicit local tool paths and a temporary owned debuggee.
Never signal a PID merely reported by an adapter. Cancellation, hidden panels,
layout changes and modal input cannot start, resume, step or terminate a target.
Debugger hiding and relocation preserve the session and selected values.
Narrow/short fallback must not consume input in an invisible field or steal
modal focus. One coherent slice is one local commit; rollback is its revert.
Preserve all unrelated work and keep Makefile/dependency files unchanged.

## Execution order and ownership

1. Real workflow harness: `scripts/smoke_debugger_crystal.rb`, owned fixture and
   reusable bounded PTY helpers/tests. First falsifiers: absent/incorrect tool,
   wrong expected value/location, missing cleanup and terminal-model failure.
   Run against the current release before deciding a production fix is needed.
2. DAP Settings: `app.cr` Settings methods/constants, `settings_config.cr` and
   focused Settings specs. First regression: the actual Settings action is
   missing. Test cycle/persistence, failure, bounds and next-session sampling.
3. Panel layout: app composition/layout, `debug_ui_controller.cr`, workspace
   and dedicated rail/layout widgets/specs. Inventory geometry/focus/split
   consumers before edits. First regressions: absent two-column rail, wrong
   default dock, doubled borders, state loss and modal leakage. Coordinate
   shared `app.cr` ownership with the Settings slice before editing it.

## Definition of Done and strongest counterchecks

Use Crystal TUI pin `7ca26fd559cf8c05e5b4ed924e7c691fabb66e43`, a private
Crystal cache and the current macOS linker flags. Required commands are the
focused `crystal spec` cases for each atomic slice, then the collective full
`crystal spec`, `crystal tool format --check
src spec`, `git diff --check`, a release build, and both debugger smokes:

```sh
ruby scripts/smoke_debugger_session.rb --fake-adapter --editor-bin "$ADAMANTINE_VERIFY_BIN"
ruby scripts/smoke_debugger_crystal.rb --editor-bin "$ADAMANTINE_VERIFY_BIN" \
  --compiler /opt/homebrew/bin/crystal \
  --adapter /opt/homebrew/opt/llvm/bin/lldb-dap \
  --debugserver /Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver
```

Expected: no failed/error/pending examples, genuine observed native values and
step location, clean Stop/Quit/owned cleanup, reachable Files/Debug at supported
geometries, exact two-column rail and single shared borders. Attack stale screen
matches, tiny Unicode layouts, hide/relocate while stopped, modal F5/F9, two
editor groups, persistence failures and config unknown-field preservation.
Do not promote a failed or unavailable real gate to PASS or skip.

## Evidence and decay

### DAP Settings slice

The missing actual Settings action and stale config-warning guidance were the
red-first signals. The implementation adds the row, bounded preset cycling,
next-Start-only hint and visible persistence failure; the active transport is
not reconfigured. The config writer and controller factory remain unchanged.

Root independently executed the following on `6c0f9ce` plus the frozen Settings
slice, using the pinned TUI and Crystal 1.21.0/arm64 macOS:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-debug-finish.zn8Nc3/cache-settings \
CRYSTAL_PATH="/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:$(crystal env CRYSTAL_PATH)" \
crystal spec --link-flags=-fuse-ld=/usr/bin/ld --error-trace \
  spec/dap_settings_ui_spec.cr spec/lsp_response_settings_spec.cr \
  spec/editing_settings_spec.cr spec/indentation_settings_integration_spec.cr \
  spec/settings_binding_conflict_spec.cr spec/debug_app_safety_spec.cr \
  spec/debug_modal_focus_spec.cr spec/debug_ownership_spec.cr
crystal tool format --check src/adamantine/app.cr \
  src/adamantine/settings_config.cr spec/dap_settings_ui_spec.cr
git diff --check
```

Observed: **55 examples, 0 failures/errors/pending**, format and diff checks
passed. Coverage includes the actual F1 Settings route, rendered row/hint,
modal F5/F9 isolation, reload, failed write, strict 1–64 MiB validation,
unknown config/keymap preservation and private `0600` output. The sampling
test observes one provider call during an active session and the changed limit
on a second explicit Start; it does not inject oversized frames under both
limits. The existing factory samples the provider when constructing a client.
Full finishing-suite, release and App/PTY gates remain pending.
The proportionate hostile review verdict is **ROBUST within this Settings
slice**: bounds, modal isolation, factory sampling and atomic writer paths were
inspected. The Luna review is same-lineage/correlated; root's executed checks
are the independent runtime evidence, not a model-consensus certificate.

### Other finishing slices

Standalone layout checks are provisional until App integration is tested.
Record executed commands, revision/source seals, review verdict and remaining
scope here as the joined gates pass. Evidence decays
when its source, TUI pin, compiler, adapter, provider, architecture or terminal
route changes. Refresh the affected consumer gate rather than combining
separate certificates by inference.
