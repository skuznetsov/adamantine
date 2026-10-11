# Debug value presentation frontier

Status: **generic App value presentation and opt-in stock-Crystal native
String/Array(Int32) inspection verified in separate evidence contexts**,
2026-10-04 UTC. App/PTY uses a fake adapter; native goldens use the real
production controller. This earlier certificate does not include a joined
App/real-target workflow.
Parent boundary: [DEBUGGER_FRONTIER.md](DEBUGGER_FRONTIER.md).

The subsequent [workflow finishing track](DEBUG_WORKFLOW_FRONTIER.md) adds its
own joined App/native-target and sidebar consumer gates. It does not change the
scope of this earlier value-provider certificate. Settings passed its focused
gate at `4d86129`; the subsequent joined stock-Crystal App/layout gates passed
1425 specs, release and real/fake PTY checks under their own recorded seals.

## Goal and anchor

The user requested useful variable values, not type-only mockup rows. At
`4210062`, the App already projects `name = value (type)`, but scope roots are
rendered as empty assignments, terminal-width clipping is silent, and the
selected-value detail is a single line. Generic DAP does not supply a universal
language-native display mode. Stock-Crystal String/Array support must therefore
be certified separately from both generic presentation and Adamas support.

## Admitted slices

1. **Generic presentation:** scope headings without fabricated assignments;
   preserve opaque adapter values/types; indicate absent summaries, loading,
   partial data and display clipping; make bounded selected detail readable
   with wrapping/scrolling and name/type context. Rendering must perform no
   protocol IO or target evaluation. Existing explicit lazy/page actions remain
   the only child-loading gestures.
2. **Opt-in stock-Crystal native values:** only a reviewed, bundled LLDB
   provider for DWARF-validated String/Array layouts, with bounded passive
   memory reads and indexed children. A profile must disclose the executable
   formatter effect before launch. Old profiles retain generic values. No
   arbitrary command field, project formatter discovery or automatic import.
   StockCrystal requires an explicitly selected `lldb-dap` executable with
   `--no-lldbinit` immediately after it; an operand or post-`--` token does not
   satisfy this guard. Generic profiles retain their existing adapter argv. This
   slice is admitted only for the fixture/toolchain and production controller
   consumer recorded below, not for arbitrary Crystal versions or Adamas.

Adamas, Hash/union decoding, attach, target-method calls, value mutation, chat,
Lua and the sidebar/activity rail are not implemented by these value slices.
The separately authorized finishing layout is a two-column left activity rail
(letter plus shared separator), a configurable Debug inspector, Files on the
left, and an independent bottom status surface reserved for future chat.
Presentation must remain usable in each admitted dock.

## Safety, rollback and admission

Risk: **CAUTION** for profile serialization, debugger/provider execution and
layout interpretation; **SAFE** for bounded UI-only presentation changes.
Rollback is the atomic slice commit, never the unrelated user-owned Makefile.
Provider failures must expose raw/unavailable data, not invent a language
value. Type spelling alone is not an ABI certificate. Missing metadata, null
or invalid pointers, inconsistent size/capacity, wrong element stride and
short reads must fail closed. No expression evaluation, target calls or writes
may be used to produce a summary or child.

## Falsifiers and Definition of Done

- Production App rows: scope heading versus empty assignment, scalar value
  and type, empty summary versus an empty quoted string, loading/partial
  states, very long names/values and narrow Unicode viewports. Visible
  clipping cannot masquerade as a complete value.
- Selected detail: multiline/long values, terminal controls, grapheme-width
  wrapping, scroll bounds, resize/format changes, and stale stop/frame handles.
  Height-only resize must clamp scrolling without rebuilding wrapped text.
  Read-only modal routing must retain existing execution/focus isolation;
  hidden-field input is blocked in a too-short viewport, with a resize notice
  when it fits. Unavailable status and its reason share one bounded row;
  narrow detail footers prioritize an explicit close gesture.
- Scope completion: successful empty scopes are not an unrequested frame;
  rejected or malformed replies end Loading with an explicit retry reason.
  Unrelated errors and stale frame/session replies cannot complete a current
  request. Detail cache keys use value/format generations, not unrelated output.
- Native provider: empty/UTF-8/embedded-NUL strings; empty/nonempty arrays,
  typed indexed children; bounded large previews; absent/incompatible layouts,
  failed or short reads, null pointers and invalid strides. Test doubles must
  raise if evaluation or target writes are attempted.
- Profile opt-in: old profile round-trip; strict optional field validation;
  explicit setup/review visibility; cancelled review starts no provider;
  generic launch sends no formatter commands; unsupported adapters retain an
  actionable failure, not silent native-support claims. An option-looking
  argument consumed by another adapter option cannot pass the no-init guard.
  Short/narrow review tests must use an otherwise valid StockCrystal profile:
  an unrelated invalid-profile rejection cannot certify invisible-approval
  prevention. A too-small profile form must not hide fields or accept unseen
  input behind its resize guard.
- Real gate: compile only owned temporary stock-Crystal fixtures with explicit
  existing tools, record compiler/adapter identities, and inspect exact
  String/Array summaries and children through the real DAP/controller path.
  This does not admit Adamas or a joined App/real-target workflow.

Run focused presentation/profile/provider falsifiers first, then the full
Crystal spec suite against the exact pinned TUI checkout, formatting and
release build. Expected signal: no failed/error/pending examples, bounded
provider reads and exact real-fixture values. Run the existing fake-adapter
App/PTY smoke for launch/values/Stop/Quit regression. Execute commands before
recording evidence or admitting either slice.

## Evidence ledger

The parent independently executed these real-fixture subgates on 2026-10-04,
using existing Crystal 1.21.0 / LLVM 22.1.8, Homebrew LLDB-DAP/libLLDB 22.1.8,
and arm64 macOS. The explicit Xcode debugserver path was
`/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver`.
Sandboxed launch was unavailable; scoped launch permission was limited to the
owned temporary fixture. No compiler, adapter or dependency was installed.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/probe_native_crystal_values.py \
  --adapter /opt/homebrew/opt/llvm/bin/lldb-dap \
  --compiler /opt/homebrew/bin/crystal \
  --debugserver /Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver \
  --timeout 15
PYTHONDONTWRITEBYTECODE=1 python3 scripts/probe_native_crystal_values.py \
  --adapter /opt/homebrew/opt/llvm/bin/lldb-dap \
  --compiler /opt/homebrew/bin/crystal \
  --debugserver /Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver \
  --formatter-source "$PWD/tools/lldb/adamantine_crystal.py" --timeout 15

PYTHONDONTWRITEBYTECODE=1 python3 scripts/probe_native_crystal_values.py \
  --adapter /opt/homebrew/opt/llvm/bin/lldb-dap \
  --compiler /opt/homebrew/bin/crystal \
  --debugserver /Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver \
  --production-controller --timeout 15
```

All three commands exited 0. The raw baseline exposed String/Array pointers
and DWARF fields, not language summaries. Provider-on goldens checked empty,
UTF-8 and embedded-NUL Strings; 2048-byte String preview disclosure; empty
Array; exact `[22, 44]` and shifted-buffer `[5, 7]` summaries and indexed
children. The 300-element Array advertised preview 8 and child cap 256;
the final allowed page returned `[255] = 255`, and the next page was empty.
The production `DebugController` independently checked reviewed profile launch,
source breakpoint and the embedded provider's exact summaries/children. It
does not join these results to an App/real-target workflow.

Provider bounds: String preview 1024 bytes; integer Array preview 8 elements
and at most 64 bytes; at most 256 synthetic children. Real certification is
String and `Array(Int32)` on this fixture/toolchain. Wider signed/unsigned
integer metadata is guarded in the implementation, not independently certified
by these real examples. Complex elements, unions, Hash and Adamas are excluded.

Two attempted falsifiers were rejected for testing the wrong context: plain
LLDB CLI treats `!script` differently from
[LLDB-DAP's required-command directive](https://llvm.googlesource.com/llvm-project/lldb/+/refs/heads/main/tools/lldb-dap/LLDBUtils.cpp);
the actual embedded-provider controller run is the applicable
check. An initial controller probe passed one-based marker line 12 to a
zero-based editor API, stopping at DAP line 13; correcting the probe to editor
11 / DAP 12 passed. This was not a compiler line-table discrepancy.

### Final App and regression gates

The parent executed the following commands on the final source state with
clean TUI checkout `7ca26fd559cf8c05e5b4ed924e7c691fabb66e43`; the local unpinned
TUI was not used as acceptance evidence. No shard or lockfile changed.

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-values-verify.u8Wwe8/cache-spec \
  CRYSTAL_PATH="/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:$(crystal env CRYSTAL_PATH)" \
  crystal spec --link-flags=-fuse-ld=/usr/bin/ld --error-trace
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-values-verify.u8Wwe8/cache-release \
  CRYSTAL_PATH="/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:$(crystal env CRYSTAL_PATH)" \
  crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld \
  -o /private/tmp/adamantine-values-verify.u8Wwe8/adamantine --error-trace
ruby scripts/smoke_debugger_session.rb --fake-adapter \
  --editor-bin /private/tmp/adamantine-values-verify.u8Wwe8/adamantine
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_adamantine_crystal.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_native_values_probe.py
ruby scripts/test_debugger_probe.rb
ruby scripts/smoke_debugger_session.rb --self-check
```

Observed results: **1380 Crystal examples, 0 failures/errors/pending**;
release exit 0; actual fake-adapter App/PTY PASS; provider 8/8; launch-order
6/6; Ruby probe 17 runs / 223 assertions / 0 failures/errors/skips; smoke
screen-model self-check PASS. All touched Crystal sources/specs passed
`crystal tool format --check`; touched Ruby scripts passed syntax checks;
`git diff --check` passed. Existing `Time.monotonic` deprecation warnings remain.

The App tests exercise actual modal/event/render paths for values, scoped
loading/error/empty states, format completion, cached detail identity,
stale-stop retirement, height-only resize, and minimum geometry. The PTY run
checks both first and saved launch review, no early adapter start, source
breakpoints, stack/locals/children, narrow Unicode resize, direct Stop,
Quit's cleanup barrier, owned adapter exits and final output drain/EOF.
It does not run the native provider in the App.

The first full suite failed one stale three-Tab argv-review scenario; the
Values selector is a fifth setup step, so the test now verifies it after
four Tabs before entering Review. The first final PTY run reached values and
Stop but timed out at saved setup for the same four-field assumption; the
script now observes Values before proceeding and retains the no-early-start
assertions. The final reruns above passed; no production launch change was
needed to fix either harness assumption.

### Source lineage and review limits

Base revision: `4210062ea4cf6d0108d1336838982d4f83b1dc5e`.
Final gated SHA-256 anchors:

```text
debug_ui_controller.cr          179bcfc26bcad0038a4cc9cc43b822c36c539417d9c8b2431a7be3a1a3851ccb
debug_variable_presenter.cr     9a763844ddf2a0735f9e1344dc8d6045c3a81f16198bed56a9159f61bcad8796
debug_controller.cr             d5c8ac53c382b60662969a130197a0e03259a65aff9d9011365993899e647292
debug_profile_store.cr          50bb367755692e37aea0a3b247f606df67e733caa6398a92a664f32ab3f726c7
debug_native_values.cr          31bec8d19e6aefbd6de4d345d23a1a80c5755886d9a0a65d2dc58a4089b30a96
tools/lldb/adamantine_crystal.py bac11722357ccc86c9d7948317b44bc40758cd6448f7d8c023367df08ac92dcf
probe_native_crystal_values.py  2933f1e19bf1e7bf055eb9d8941961a22373e7027eeaba4c44d634ee8844f3bd
probe_native_crystal_controller.cr 85b70c31b53bc25bb81545358e08c8e42b120aef13d2354711edc618c767466b
smoke_debugger_session.rb       4f632537dc45c633ce253d875e42df533262c88fa07115f07d9a8d11e82608c3
private release binary         47da59fda2b9453c1d4219c429d3a81a15915d610464d1c184c44bed849bad69
```

Review-driven falsifiers caught hidden StockCrystal disclosure in a short or
narrow review, a blank error-row overwrite at the valid 77-column/14-row
boundary, stale scroll after height-only resize, and detail error/footer
collisions. Tests were strengthened to use an otherwise valid reviewed
profile; an invalid adapter profile cannot certify the geometry guard.
The repaired UI status/footer cases failed before their fixes and passed in
the final parent suite. Same-lineage Luna review is correlated; admission
rests on the independently executed parent gates, not model agreement.
Final adversary verdict: **ROBUST within these declared contexts**, with no
unresolved concrete blocker. This does not extend the native certificate to
another ABI or imply a joined App/native-target workflow.

Evidence decays when the relevant source, compiler ABI, adapter, provider,
architecture or TUI pin changes; refresh the affected gate rather than treating
prior language evidence as generic compatibility. Failure withdraws only the
affected context's admission. Adamas, Hash/unions/complex Array elements,
attach and inferior input remain open. The joined App/native-target workflow
was open at this earlier slice; its subsequent bounded admission is recorded
in [DEBUG_WORKFLOW_FRONTIER.md](DEBUG_WORKFLOW_FRONTIER.md).
