# Debug workflow finishing frontier

Status: **VERIFIED within the bounded workflow below — joined stock-Crystal
App/PTY, inspector layout and Settings gates passed**, 2026-10-04.
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
  Files stays on the left even when Debug's compact fallback is bottom. If
  Files cannot fit alongside a usable editor, suppress it with a resize hint;
  never silently turn the file tree into a bottom panel. Hiding the inspector
  reclaims its space, and the shared divider remains draggable.
  F2 first shows/focuses Files, preserving the old focus action. Repeating F2
  while Files is already visible and focused is a new explicit hide action;
  F2 from an editor focuses Files without hiding it. Ctrl+O and selecting the
  Files rail restore the tree without resetting its state.
- Workspace boundaries use single shared lines and correct junctions, taking
  `crystal_ball/src/tui/app.cr` as a source reference. No dependency pin or
  ignored `lib` change may supply required behavior. Vertical boundaries that
  reach the full-width status divider join it; editor dividers that end at an
  internal bottom Debug divider must not continue into the status surface.
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
`crystal spec`, `crystal tool format --check src spec`, `git diff --check`, a
release build, Ruby/Python oracle checks, both fake-adapter placements and the
joined native debugger smoke:

```sh
ruby scripts/test_debugger_crystal_smoke.rb
ruby scripts/smoke_debugger_session.rb --self-check --dock left
ruby scripts/smoke_debugger_session.rb --self-check --dock bottom
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_adamantine_crystal.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_native_values_probe.py
ruby scripts/smoke_debugger_session.rb --fake-adapter --editor-bin "$ADAMANTINE_VERIFY_BIN"
ruby scripts/smoke_debugger_session.rb --fake-adapter --dock bottom --editor-bin "$ADAMANTINE_VERIFY_BIN"
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

### Review-driven verification obligations

Whole-screen substring matches are not sufficient for the joined gate. The
open fixture source already contains its variable names and initial literals.
A redraw can therefore satisfy a scopes or value predicate without presenting
a successful debugger result. Scope/locals/children checks must be bound to
the actual Variables pane body, and value goldens to the selected Value Detail
body, not background source or output. Sensitivity tests must call the same
production predicates and reject source-only goldens, wrong modal values,
retained loading prompts and wrong exact stack locations. `main.cr:5` cannot
stand in for `main.cr:50`.
The wide Bottom header must expose the selected pane in text, not only SGR
styling: the bounded text-grid gate cannot infer color selection. A matching
value/frame in a different pane must not satisfy Variables/Stack predicates.
Closing a modal after resize must repair an unusable inspector's focus before
the next input can reach it, not merely rely on a later repaint. Test an actual
root ResizeEvent without painting first, both in normal input and while a
modal is open. The focus repair must not collapse/reparent editor groups or
perform protocol IO. A release build of the actual CLI entry point is required:
headless App tests alone do not certify constructor-time callback ordering.

Selected native details retain opaque adapter type/value text. The owned
fixture oracle accepts its exact summary either bare or following one bounded
hexadecimal pointer prefix, only for the declared pointer-backed native types.
It rejects additional nonempty body rows, wrong names/types, incorrect values,
and source-only matches. Compiler-generated locals may appear between user
variables; a hard-coded ordinal cannot identify the selected variable. The
real gate must resolve the exact name inside the current Variables pane before
opening detail or expanding children.

Two vertical characters in a header alone do not certify side-by-side layout.
The joined gate must resolve the actual inspector bounds and demonstrate a
nonempty adjacent editor surface on the same rows. Stop/Quit cleanup evidence
must use observed owned process identities and final PTY EOF. Failure cleanup
must have bounded waits; TERM followed by an unbounded `waitpid` is not a
deadline. Any forced fallback may address only a directly spawned owned
compiler/editor, never an adapter-reported target PID or an arbitrary process
group. A forced fallback is failure recovery, not successful Stop evidence.

For rapid adapter shutdown, hold controller polling until the adapter has sent
validated `terminated`/correlated Disconnect acknowledgment and closed stdout.
Neither automatic failure cleanup nor explicit close may erase already
received terminal evidence before its consumer sees it. Also test a one-event
poll which consumes Terminated before close while a validated Exited and
correlated Disconnect ACK remain queued. Preserve only the still-queued facts;
already consumed events must not replay. Conversely, EOF without such evidence
must remain a failed/uncertain session, not a fabricated successful Stop.
Keep target exit separate: session-ending evidence alone must not promote
Unknown to Exited. Keep request status separate too: Terminated does not invent
a successful Disconnect response. An unacknowledged ticket remains a transport
error or cancellation even if its session already ended. Cleanup does not wait
for unread future events. Owned cleanup and protocol/resource bounds remain
required.
These distinctions follow the official [DAP schema](https://github.com/microsoft/debug-adapter-protocol/blob/main/debugAdapterProtocol.json)
for Disconnect, Terminated and Exited, checked on 2026-10-04.
The final audit must also check identities previously observed in the editor's
original process group, even if they were reparented or subsequently changed
groups. Checking only current group membership cannot certify disappearance
of an already captured process. An unobserved descendant remains outside the
cleanup certificate; failure diagnostics must report observed survivors or an
inconclusive audit without claiming that killing the editor cleaned its tree.
Captured identity matching uses PID plus the exact observed command string,
not a process-start-time certificate. A command-changing exec that also leaves
observed ancestry/group membership is outside this bounded owned-fixture gate.

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
The collective finishing-suite, release and App/PTY gates subsequently passed
in the final admission below.
The proportionate hostile review verdict is **ROBUST within this Settings
slice**: bounds, modal isolation, factory sampling and atomic writer paths were
inspected. The Luna review is same-lineage/correlated; root's executed checks
are the independent runtime evidence, not a model-consensus certificate.

### Workspace repairs and discriminators

The two-column rail, independent Files/Debug widths, configurable Debug dock,
single shared boundaries and status-divider junctions are owned by repository
widgets; the TUI pin and ignored `lib` are unchanged. Files hide/restore,
relocation while stopped, editor split/state preservation, modal isolation and
Settings persistence have production-App regression coverage. Selection is
also visible without color: active rail initials are uppercase and a wide
Debug header marks its selected pane with `▶`.

Actual fake-adapter runs first exposed an unreadable side row: splitting the
name/value budget evenly turned `sentinel` into `sentin…` despite enough room
for its name and scalar. The presenter now preserves short names and values
before optional types; clipping, controls, partial status and deep indentation
remain bounded. Detail retains the full opaque adapter value/type. The narrow
smoke reads a visible Unicode comment in the bounded editor, not a line which
has scrolled outside its viewport. Left's exact Record value is required even
when the optional type does not fit; Bottom still requires the full typed row.

Resize-event regressions reproduced hidden Debug input before the next paint,
both during normal input and after closing a modal. Input-time repair now
synchronizes frame/split rectangles without painting, reparenting editor
groups or requesting DAP data. Modal focus stays protected; normal-mode exit
repairs it before the next key. The tests assert unchanged source before the
next keys and editor-directed input afterward, with the hidden Debug row still
unmoved. Historical-source tests explicitly establish valid live geometry and
focus before opening Debug; a zero-sized inspector is not a valid fixture.

The actual CLI release entry point exposed constructor-time mode-exit callbacks
before layout/frame widgets existed, although headless App specs compiled.
Those widgets now exist before collaborator/LSP callbacks are configured.
Fresh release compilation, rather than headless green alone, closes that
initializer-order discriminator.

### Oracle repairs and bounded evidence

The native run exposed legitimate pointer prefixes in String/Array summaries
and Crystal-generated `__temp_*` rows between named locals. Neither is removed
from production data. The smoke instead parses the exact selected detail and
uses bounded, exact-name tree navigation from a validated first Variables
page. Its sensitivity suite rejects wrong names/types/values, extra body rows,
malformed pointers, duplicate/prefix-only assignments, wrong panes, source or
footer decoys, non-tree rows and stale/exactly wrong source locations.

The screen model explicitly admits the observed one-cell `▸` glyph; unknown
widths, invalid UTF-8 and incomplete terminal sequences still fail closed.
Each successful smoke must finish its drain thread, observe PTY EOF, and have
no terminal-parser error. Owned-process disappearance, not a screen message,
is required after Stop and Quit. Failed-run fallback/audit reports remain
failure evidence even if a later scoped audit finds that a transient adapter
has exited.

Root independently ran the following on 2026-10-04:

```sh
ruby -c scripts/lib/pty_screen.rb
ruby -c scripts/lib/crystal_debug_smoke.rb
ruby -c scripts/smoke_debugger_crystal.rb
ruby -c scripts/test_debugger_crystal_smoke.rb
ruby scripts/test_debugger_crystal_smoke.rb
ruby scripts/smoke_debugger_session.rb --self-check --dock left
ruby scripts/smoke_debugger_session.rb --self-check --dock bottom
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_adamantine_crystal.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_native_values_probe.py
```

Observed: four syntax checks passed; **13 Ruby tests / 73 assertions, no
failures/errors/skips**, both screen-model/dock self-checks passed, and **8
provider plus 6 launch-order Python tests passed**. Both actual fake-adapter
App/PTY placements passed on the fresh release binary. These checks alone do
not substitute for the joined real-target or full-suite gate; both subsequently
passed in the final admission below.

### Shutdown race and typed evidence

The first joined native run displayed correct values and stepped at the exact
source locations, but Stop showed Failed/EOF after LLDB-DAP had sent its
terminal frames. `Client#close` discarded queued events and response payloads
before the nonblocking controller consumed them. A valid owned LLDB trace
observed Terminated, correlated Disconnect ACK, Exited, then EOF; an earlier
trace without the required debugserver was rejected as a discriminator.

The rapid-EOF regression failed before the repair. A second non-EOF regression
consumed only Terminated, explicitly closed with the ACK and Exited still
queued, and failed because the queued ACK vanished. Cleanup now preserves only
facts actually discarded at close: at most one Terminated, one Exited with a
valid Int32 exit code, and an already-validated successful Disconnect result.
It retains no raw adapter payload or wire/decoded reservation. Projection and
result consumption are one-shot; already consumed and unread future events are
excluded. Other response payloads still follow the existing discard policy.

A direct-client guard proves that Terminated without an ACK leaves Disconnect
as TransportError, not synthetic Success. The controller suppresses only
teardown-related TransportError/Cancelled diagnostics after an already-Ended
session. A rejected or timed-out Disconnect still exposes its request error;
the existing reducer preserves Ended and any already-certified Exited fact.
Only an explicit valid Exited event supplies the target exit code. Plain EOF
and a wrong-correlated ACK remain Failed/Unknown without terminal evidence.

Luna's focused four-spec run passed **90 examples, 0 failures/errors**. Root's
full-suite execution below independently includes all seven new shutdown
regressions. The focused resource counters are not a process-list audit; a
worker's separate `ps` probe was denied by the OS. The successful root native
gate supplies its own scoped, observed-process disappearance evidence.

### Final joined admission (2026-10-04)

Root ran the collective gates on parent `ae8e027` plus this frozen workflow
slice, with the pinned TUI, Crystal 1.21.0 and arm64 Darwin. The source seal was
unchanged before and after the commands. Build and full specs used separate
private caches:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-debug-finish.zn8Nc3/cache-final2-spec \
CRYSTAL_PATH="/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:$(crystal env CRYSTAL_PATH)" \
crystal spec --link-flags=-fuse-ld=/usr/bin/ld --error-trace
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-debug-finish.zn8Nc3/cache-final2-build \
CRYSTAL_PATH="/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:$(crystal env CRYSTAL_PATH)" \
crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld \
  --error-trace -o /private/tmp/adamantine-debug-finish.zn8Nc3/adamantine-final2
crystal tool format --check src spec
git diff --check
```

Observed: **1425 examples, 0 failures/errors/pending**, in 1:48 minutes;
actual CLI release, format and diff checks passed. Release reports seven
existing Time.monotonic deprecations, including the external TUI; the suite
reports 53 deprecation warnings. These are not a warning-free certificate.

Root also reran every Ruby/Python and PTY command in the DoD above with
`ADAMANTINE_VERIFY_BIN=/private/tmp/adamantine-debug-finish.zn8Nc3/adamantine-final2`:
**13 Ruby tests / 73 assertions**, **8 provider + 6 launch-order Python tests**,
both dock self-checks, actual fake Left and Bottom workflows, and the actual
joined stock-Crystal App/LLDB-DAP PTY all passed. The native gate displayed
scalar `314159`, String `"Crystal gate" (12 bytes)`, Array `[22, 44] (size=2)`
and children `22`/`44`; it stopped at line 5, stepped to lines 6 and 7, and
displayed scalar `314160`. Stop reached Ended and the captured target/adapter
identities disappeared. Quit exited successfully; previously captured owned
and original-group identities disappeared, the drain reached PTY EOF without
parser errors, and the successful temporary project was removed.

Additional root regression commands on the same binary all passed:

```sh
ruby scripts/smoke_close_confirmation.rb "$ADAMANTINE_VERIFY_BIN"
ruby scripts/smoke_refactor.rb "$ADAMANTINE_VERIFY_BIN"
ruby scripts/smoke_format_git.rb "$ADAMANTINE_VERIFY_BIN"
ruby scripts/smoke_external_review.rb "$ADAMANTINE_VERIFY_BIN"
```

Seals (SHA-256; the 309-file source seal covers the sorted Git-known/unignored
`src`, `spec`, `scripts` paths as `path + NUL + file SHA-256 + NUL`):

```text
source/spec/scripts: 0b844dbb383ca783715f673f284f6fb988d6e8ca94715b1f9904ef436ec343c0
release binary:      5671cfb861a7f81bcb57ab54c59f15f7830ed28b8b35148f158771e156ba458d
Crystal compiler:    40cffa1b29b572c064b4a397c6b82c7a84c55a146685d0971dab816f855eb836
LLDB-DAP:            f983337ddb6403631bf4bbf68aeb149de3289c1b2dee2617650dbd2715b5aa1f
debugserver:         6e8ab0f0a30c30834d61ab8dd21ea54e48731903d4bca1a789d09d52dadc58e9
passive provider:    bac11722357ccc86c9d7948317b44bc40758cd6448f7d8c023367df08ac92dcf
native smoke:        12051c44fbdc0a35c0afb477f5206b4772b7382242836396f16a50c6fb0c542c
native oracle:       63537d03979a6220a97bf98e345edd20015c67b8a03e3e7f4dc5c550820689ae
PTY screen model:    37855b5621468fb90d288f0d8dcea755a70ddf0056ed6f3bc61bed8e86889b56
fake smoke:          5b264aa63f2e8b5c9869c3cb0e11f8839164371d1826670f3208043cb17e07c3
TUI Git revision:    7ca26fd559cf8c05e5b4ed924e7c691fabb66e43
```

Proportionate adversary verdict: **ROBUST within these admitted contexts**.
Source review checked queue-discard timing, correlation/tombstones, bounded
one-shot projection, and request/session/target evidence separation. Runtime
counterchecks cover modal isolation, unpainted resize repair, split preservation,
wrong-screen/value/location decoys, cleanup and persistence failure. Luna's
source review is correlated evidence; root's independently executed gates are
the runtime anchor. No Adamas ABI, arbitrary native layouts, unobserved process
descendants, unread exit event, attach, inferior input, chat or Lua is admitted.

Evidence decays when source, TUI pin, compiler, adapter, provider, architecture
or terminal route changes. Refresh the affected consumer gate rather than
combining separate certificates by inference.
