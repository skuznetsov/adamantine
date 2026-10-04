# DAP debugger implementation plan

Status: **DBG-0 compatibility and DBG-1 foundation verified; DBG-2/3 in progress.** This plan
operationalizes [DEBUGGER_FRONTIER.md](DEBUGGER_FRONTIER.md); that frontier is
the behavior authority. Keep its gates and falsifiers current as code changes.
DBG-0/1 execution evidence is recorded in the frontier; remaining commands below
are future DoD, not evidence of implemented editor behavior.

Current execution track: **DBG-2/3 launch workspace and bounded values**,
following the DBG-0 measured C/Crystal route and DBG-1 library/reducer gate.
The prebuilt Adamas probe remains unadmitted. The controller/lazy-value runtime
has passed its focused and real-Crystal subgates; App composition is a working
draft, not yet an admitted editor release. The remaining workspace, modal and
root/quit gates still apply.
Future bottom-pane chat
and single/shared borders were explicitly deferred by the user on 2026-10-03;
finish the staged debugger gates without implementing those ideas.

DBG-2/3 implementation may now proceed with separate model, runtime and UI
ownership. Inert profile/source/breakpoint model preparation is separate from
the DBG-1 commit. App behavior remains guard-only until the complete DBG-2/3
gates, including real-language and modal/workspace evidence, pass.
The independently executed controller subgate is recorded in the
[runtime evidence](DEBUGGER_FRONTIER.md#dbg-23-controller-runtime-subgate-2026-10-04-utc);
it does not replace those App gates.

## Gate order and release boundary

```text
DBG-0 compatibility evidence -> DBG-1 DAP transport/state -> DBG-2 launch,
source breakpoints, control and workspace -> DBG-3 bounded locals/values
                                      |                         |
                                      +---- first useful release-+

DBG-4 attach/detach: after DBG-1 + DBG-2, independently gated
DBG-5 inferior terminal: after DBG-1 + DBG-2, only with real bidirectional IO
DBG-N native summaries: separate ABI/formatter work after DBG-0 + DBG-3
```

DBG-0 reports C, stock Crystal and Adamas independently; C alone is foundation.
Useful requires DBG-2/3 plus real-binary stepping, locals and children for one
declared Crystal or Adamas target. Report each compiler separately; attach,
terminal and native work require DBG-4/5/N. Language failure narrows support,
not generic DAP. If both target-language probes fail, the result is generic
DAP foundation only, not the useful release requested here.

## Proposed modules and concrete consumers

Editor paths below are proposed. The DBG-0 probe and real-debuggee fixtures
now exist. Keep DAP wire types out of LSP types and widgets free of protocol
IO/target evaluation.

| Proposed path | Responsibility and existing integration consumer |
| --- | --- |
| `src/adamantine/dap/protocol.cr` | DAP envelope, bounded Content-Length framing, schema-safe field decoding; consumed by `dap/transport.cr`. |
| `src/adamantine/dap/transport.cr`, `dap/client.cr` | Owned adapter process, one writer, reader/dispatcher, request correlation/deadlines, reverse-request replies and bounded cleanup; consumed by `DebugController`. |
| `src/adamantine/debug_session_state.cr` | Pure lifecycle, thread/stop epochs, capabilities and immutable UI snapshot reducer; consumed by controller/panel and deterministic specs. |
| `src/adamantine/debug_source_store.cr`, `debug_source_resolver.cr` | Canonical source keys, requested/resolved breakpoints, explicit source maps and session-scoped source references; consumed by `OpenBuffer.views`, gutter projection and navigation. |
| `src/adamantine/debug_profile_store.cr` | Allowlisted launch-profile fields and last profile ID per canonical project in a separate private schema; consumed by setup/controller. Do not change `SessionStore` v2 or persist secrets. |
| `src/adamantine/debug_variable_tree.cr`, `debug_value_detail.cr` | Lazy, paged, generation-scoped children and bounded read-only detail; consumed by Variables panel. |
| `src/adamantine/debug_controller.cr` | Adapter factory seam, session orchestration, generation guards, explicit actions and error publication; included by `App`. |
| `src/adamantine/debug_panel.cr`, `debug_workspace.cr` | Persistent dock, state/control row, Stack/Variables/Breakpoints/Output views and focus/navigation policy; composed by `App`. |
| `spec/fixtures/debugger/dap_scripted_adapter.rb`, `dap_resource_adapter.rb` | Local framed fake adapters with scripted responses/events, ordering, stalls, reverse requests and aggregate byte/item resource stress. |
| `spec/fixtures/debugger/{control.c,control.cr,adamas_locals.cr}` | Small real-debuggee controls compiled only into a temporary directory by the probe script. |
| `scripts/probe_debugger_controls.sh` | Explicit-tool-path DBG-0 real-adapter probe; accepts a prebuilt Adamas compiler and never builds/downloads one. |
| `scripts/smoke_debugger_session.rb` | Real PTY keyboard/focus/layout lifecycle smoke; fake-adapter mode by default, optional explicit real adapter. |

Existing integration consumers to inventory before each widening:

- [`app.cr`](../src/adamantine/app.cr#L75): `App` mixins, `compose`, split geometry,
  narrow fallback and modal capture (`:75-95,329-352,395-397,853-868,870-1015`).
- [`input_router.cr`](../src/adamantine/input_router.cr#L41): action contexts,
  modal precedence, focused routing and ordered handler registry (`:41-55,59-151,158-238`).
- [`key_config.cr`](../src/adamantine/key_config.cr#L42): default map, sparse
  overrides, duplicate warnings and config save/load (`:42-121,319-420`).
- `app.cr:117-159,2283-2310`, `command_palette.cr:106-115`: palette entries,
  execution handlers and Help discovery are separate from key dispatch.
- [`document_types.cr`](../src/adamantine/document_types.cr#L6) and
  [`document_orchestrator.cr`](../src/adamantine/document_orchestrator.cr#L189):
  one shared open document, multiple view widgets, shared edit version and guarded navigation.
- [`editing_text_editor_unicode.cr`](../src/adamantine/editing_text_editor_unicode.cr#L243)
  and `git_gutter_controller.cr:19-50,159-182`: renderer, gutter width/hit testing,
  active-view Git projection and asynchronous freshness guards.
- `lsp_controller.cr:222-265,374-393` and `lsp_client.cr:956-1004,1197-1278,1325-1382`:
  snapshot guards and transport lifecycle patterns. Do not copy latest-only
  request scheduling or JSON-RPC envelopes into DAP.
- `session_store.cr`, `settings_config.cr:132-160`: private/atomic persistence
  patterns. Keep debugger profile state separate from editor tabs/settings.
- Existing test anchors: `spec/key_config_spec.cr`,
  `spec/settings_binding_conflict_spec.cr`, `spec/input_router_spec.cr`,
  `spec/command_palette_spec.cr`, `spec/editor_split_spec.cr`,
  `spec/same_file_views_integration_spec.cr`, `spec/git_gutter_spec.cr`,
  `spec/lsp_client_start_spec.cr`, `spec/lsp_async_navigation_spec.cr`.

## Red-first falsifiers

Before production edits, add each listed failing test/probe and show that it
fails for the intended reason. D01-D15 are the frontier roster, not completed
coverage. Extend existing specs only where that preserves a clear owner.

| ID | First test/probe path (proposed) | Required counterexample |
| --- | --- | --- |
| D01 | `spec/dap_protocol_adversary_spec.cr` | Split/malformed/truncated/oversized frames, bad JSON/depth, unknown IDs and sequence/correlation errors. |
| D02 | `spec/dap_session_ordering_spec.cr` | Init order/partial stop; successful Continue without `continued` means Running unless newer Stop wins; ambiguous timeout means Unknown. |
| D03 | `spec/dap_stale_handle_spec.cr`, `spec/debug_value_detail_spec.cr` | Reused handles; stale results after resume/frame/root/session or Summary/Hex/Raw/JSON-format change; test capability availability and generation invalidation. |
| D04 | `spec/debug_breakpoint_reconcile_spec.cr` | In-flight full-set replacement races, moved/rejected/removed breakpoints, stale adapter IDs. |
| D05 | `spec/debug_source_resolution_spec.cr` | Same basename, UTF-16, sourceReference/checksum mismatch, edits/two views, 32 MiB/32-snapshot cap, eviction and explicit unavailable source. |
| D06 | `spec/debug_modal_focus_spec.cr` | Modal stop/paste races; watch/profile entry consumes or ignores every global debug binding, including F5, Shift+F5, F9, F10, F11, Shift+F11 and any configured Pause. No focus theft, submission, target action or fall-through. |
| D07 | `spec/debug_gutter_spec.cr` | Fold, Git, breakpoint and execution cells coexist; hidden line numbers, mouse hits, wide glyphs and narrow layout. |
| D08 | `spec/debug_variable_limits_spec.cr` | Huge/deep/cyclic values, absent/ignored paging, slow lazy nodes and ANSI text stay bounded and honest. |
| D09 | `spec/debug_watch_safety_spec.cr` | Adding/rendering watches never evaluates; manual evaluation is explicit and frame-bound. |
| D10 | `spec/dap_transport_adversary_spec.cr` | Max-size responses during stalled rendering, blocked writer, floods/crash; aggregate inbound and decoded queues obey byte+count caps and cleanup/state stay bounded. |
| D11 | `spec/debug_ownership_spec.cr` | Stage all dirty-file/session choices before target effects; final approval, Cancel-intact state, uncertain exit, launch Stop vs attach Detach. |
| D12 | `spec/debug_keymap_spec.cr` | Clean sparse defaults have new owners; explicit remaps/empty-unbinds persist unchanged, F1 discovery and conflict warnings work. |
| D13 | `scripts/probe_debugger_controls.sh` | C passes while Crystal/Adamas fails; C alone is foundation. Useful release requires real stepping/locals/children for at least one declared Crystal or Adamas target; report each compiler independently. |
| D14 | `spec/debug_native_format_spec.cr` | Wrong ABI/layout, null/invalid pointer, missing metadata, embedded NUL and stride mismatch never yield guessed values. |
| D15 | `spec/debug_terminal_pty_spec.cr` | `runInTerminal` handles argv/env/stdin/resize/EOF/interrupt with bidirectional PTY IO. |

## Implementation slices

### DBG-0 — compatibility evidence only

- **Risk:** CAUTION (executes explicit local compiler/debugger binaries).
  **Rollback:** temp-directory cleanup; no repository/compiler mutation.
- Add `spec/fixtures/debugger/*` and `scripts/probe_debugger_controls.sh`.
  Require explicit adapter/compiler/CC paths; preflight version, SHA-256 and
  available build provenance; compile only fixtures under a private temporary
  directory. Adamas must be a prebuilt binary, never built here. The inspected
  binary has unknown provenance and cannot certify current or dirty HEAD.
- Verify compiler `--help` and cache defaults first. The source-verified form
  is `--debug -O 0 --no-llvm-cache --no-ast-cache <fixture.cr> --output <probe>`;
  also set `ADAMAS_LLVM_CACHE=0`, use a private working directory/cache home,
  and retain the inspected default-disabled, relative pipeline-cache boundary.
  Never invent `--no-cache`. The prebuilt binary's sparse `--help` does not
  establish support for these source-verified flags.
  Stock Crystal uses
  `crystal build --debug -O 0 -o <tempdir>/crystal-probe <fixture.cr>`.
  On this Darwin/Crystal 1.21 host the harness adds the explicitly scoped
  `--link-flags=-fuse-ld=/usr/bin/ld` linker workaround.
  Do not run unmodified `Adamas/scripts/check_lldb_locals.sh`: its
  `tmp/lldb_smoke_func.cr` and `tmp/lldb_smoke_array.cr` inputs are missing.
  Use only new temp fixtures; never build from Adamas source in this gate.
- Probe real `lldb-dap` DAP transcripts and breakpoint/step/scopes separately
  for C, stock Crystal, and Adamas. Include empty/UTF-8/NUL Strings, empty and
  `[22,44]` Arrays, both `Int32 | String` arms, nil/non-nil `String?` and
  `Pointer(UInt8)?`, nested and shadowed/out-of-scope locals. Record missing or
  optimized-out values as evidence, not harness failure. No install/download.
- **DoD:** `scripts/probe_debugger_controls.sh --adapter "$ADAMANTINE_DEBUG_LLDB_DAP" --crystal-bin "$ADAMANTINE_DEBUG_CRYSTAL_BIN" --adamas-bin "$ADAMANTINE_DEBUG_ADAMAS_BIN" --cc "$ADAMANTINE_DEBUG_CC"`; expected bounded C/Crystal/Adamas results with real transcripts or explicit blockers. C alone admits only the reference control.
- **Observed:** fake-peer suite 17 runs/223 assertions passed. With the explicit
  existing debugserver and scoped fixture-launch permission, C and Crystal
  1.21 passed verified breakpoint, known scalar/record child, exact step,
  exit and clean disconnect. The prebuilt Adamas compiled but its source
  breakpoint remained unverified. No native formatter or editor runtime is
  admitted by this result. Full command, input seals and decay rules:
  [DBG-0 evidence](DEBUGGER_FRONTIER.md#dbg-0-compatibility-evidence-2026-10-03).

### DBG-1 — DAP framing, client and pure session reducer

- **Depends on:** DBG-0 has a working C/reference-adapter route; language
  results remain separately labeled. **Risk:** CAUTION (process/protocol,
  resource bounds). **Rollback:** revert only the DBG-1 slice commit; preserve
  App/keymap and user config.
- Red-first D01, D02, D03 and D10 in the listed specs, using
  `dap_scripted_adapter.rb` for fragmentation, interleaved response/event,
  delayed response, server reverse request, saturation, EOF and timeout.
- Implement only proposed `dap/protocol.cr`, `dap/transport.cr`,
  `dap/client.cr`, and `debug_session_state.cr`. Keep independent request
  correlation; serialize execution mutations; reject unsupported reverse
  requests promptly; isolate reader/writer from UI. Do not advertise
  `runInTerminal`, shell, memory references or unsupported capabilities.
- Bind results to session/adapter and request/stop/thread/frame generations.
  Resume stays pending until success means Running/partially running unless a
  newer stop wins; no `continued` event is required. Ambiguous timeout/failure
  means Execution unknown, not Paused. Retire handles before
  Continue/Step and on invalidation, termination or disconnect.
- Use provisional limits only after adversarial probes: 8 KiB header, 16 MiB
  message (setting range 1-64 MiB), 64 outstanding requests, bounded writer
  bytes, deadlines, JSON depth/tokens, aggregate inbound bytes and queued
  decoded-response/event budgets. Critical-event saturation fails visibly;
  never silently drop lifecycle events.
- **DoD:** shared Crystal command below with D01-03/D10 specs; max-size replies during stalled rendering prove inbound/decoded byte and count caps, while malformed/order/stale/saturation fail closed and resume races reduce correctly.
- **Observed:** parent ran 76 focused examples twice after the closed-stdin
  handshake correction, then the full tracked editor suite plus these specs:
  1,224 examples, no failures/errors/pending. Actual Client initialization
  against the existing LLDB-DAP succeeded; bounded close retired its owned
  process and actors. This is transport/reducer evidence, not App launch/UI or
  a new language compatibility result. Exact envelopes, counterexamples,
  source seals and decay rules are in [DBG-1 evidence](DEBUGGER_FRONTIER.md#dbg-1-clientstate-foundation-evidence-2026-10-03).

### DBG-2 — launch, breakpoints, control and Debug workspace

- **Depends on:** DBG-1 and C control in DBG-0. **Risk:** CAUTION (new process
  ownership, default keys, split/gutter UX). **Rollback:** revert DBG-2 only;
  never rewrite sparse user overrides or unrelated config sections.
- Red-first D04-D07, D11 and D12. Add proposed
  `debug_source_store.cr`, `debug_source_resolver.cr`,
  `debug_profile_store.cr`, `debug_controller.cr`, `debug_panel.cr` and
  `debug_workspace.cr`; compose in `app.cr`. Source references are typed,
  read-only session documents, never fake disk paths or normal Save/watch/LSP/
  session persistence. Use canonical paths and explicit
  source maps, never basename guessing. Keep requested and adapter-resolved
  breakpoint IDs/positions distinct and generation-bound.
- Compose a persistent bottom workspace below groups. Preserve narrow fallback,
  selection/return location and sibling fold/scroll state. A folded stop unfolds only through
  explicit Show Location/selected-frame navigation in the active group; stop
  events never navigate siblings. Keep errors visible if the dock hides
  `status_log`; inferior Output is
  separate from editor diagnostics.
- Bound session source retention at the proposed 32 MiB logical bytes and 32
  snapshots, counting persistent roots despite structural sharing and keeping
  at most one baseline per source. Evict unpinned content first; show unavailable
  or evicted source honestly, never as substituted live text.
- Add distinct fold, breakpoint, line-number, Git and execution gutter cells;
  breakpoint/execution rendering remains when line numbers are hidden. Update
  width calculation and mouse hit-testing. Project source breakpoints into all
  `OpenBuffer.views`; retain Git `line_change_markers` ownership. On source
  mismatch, suppress precise arrows on edited text and retain session source.
- Set approved defaults: F5 Start/Continue, Shift+F5 Stop, F9 Toggle Breakpoint,
  F10 Over, F11 Into, Shift+F11 Out; F6 Hover stays. Add F1 palette entries for
  Start, Continue, Pause, Steps, Stop, Show Debug/Location, Toggle Breakpoint
  and Configure. Keep Help, Settings, Reload Theme and displaced LSP actions
  discoverable; add `LSP actions` -> `lsp.context_menu`. Inventory defaults,
  handlers, palette, Help/footer/startup hints, README/keymap examples and tests.
  Require collision-free defaults, preserved sparse overrides/empty unbinds,
  visible user-conflict warnings and panel/palette alternatives for modified
  function keys unavailable in some terminals.
- Persist allowlisted launch-profile fields and the last selected profile ID
  per canonical project in a separate private bounded atomic store; keep
  secret-valued overrides out of shared profiles and diagnostics.
  Review executable/target/cwd/argv before launch; no shell, build, download,
  auto-save or startup execution. Watch/profile text-entry focus consumes or
  ignores every global debug binding, including all six default debug keys and
  any configured Pause binding; only explicit field commit/evaluate/cancel
  controls act. No launch, breakpoint, stop or step falls through to the target.
- **DoD:** shared Crystal command below with `spec/debug_breakpoint_reconcile_spec.cr spec/debug_source_resolution_spec.cr spec/debug_modal_focus_spec.cr spec/debug_gutter_spec.cr spec/debug_ownership_spec.cr spec/debug_keymap_spec.cr spec/debug_profile_store_spec.cr spec/debug_workspace_spec.cr`, plus `scripts/smoke_debugger_session.rb --fake-adapter`.
  **Expected:** F-key/default and palette behavior matches the contract; source
  mismatch, modal focus, two-view gutter, narrow PTY and owned-adapter cleanup
  regressions pass against the fake adapter. This alone is not first release.

### DBG-3 — bounded locals, children and read-only detail

- **Depends on:** DBG-2 and DBG-0 controls. **Risk:** CAUTION (untrusted values,
  CPU/memory and stale handles). **Rollback:** revert DBG-3; retain working
  launch/control and show a clear “variables unavailable” reason.
- Red-first D03, D08 and D09 in proposed `debug_variable_limits_spec.cr`,
  `debug_watch_safety_spec.cr` and `debug_value_detail_spec.cr`; extend the
  fake adapter with huge, cyclic, slow, lazy and non-paging cases.
- Implement `debug_variable_tree.cr` and `debug_value_detail.cr`: bounded lazy
  paging/Partial state; Summary default, Hex only when capability permits, Raw
  only for adapter-supplied fields, and optional local JSON parsing labeled as
  display interpretation. Mode/format changes retire generations; test stale
  replies and each mode's availability. Watches are manual/frame-bound. Client
  sends no implicit `evaluate`/target calls, but summaries/children are opaque
  executable-provider output with no generic passivity guarantee. No auto-save.
- Close the actual format consumer, not only the pure detail helper:
  `DebugController#request_value_format` is an explicit capability-gated,
  asynchronous Hex refetch of the retained origin page. Keep only one bounded
  selected result; require exact child offset/identity and frame/format
  generation certificates. Keep `render_value` pure. The UI owner invokes this
  seam only on an explicit format choice and retires it when the detail closes
  or selection changes. Raw is Unavailable without adapter-provided structure.
  Carry complete/unchanged value provenance into local JSON interpretation.
  `spec/debug_value_format_consumer_spec.cr` must first fail on missing Hex,
  duplicate-name/wrong-offset replies, late success/error after a format/frame
  change, unsupported capability dispatch, and clipped-valid-prefix JSON.
  A later ordinary sibling page still retires the global variable generation;
  test that this displays a local refresh/retry reason, not a false claim that
  the adapter lacks formatting support. Retry is a new explicit action, never
  an automatic request. The real probe waits for ordinary pages to settle
  before requesting Hex, and preserves the adapter's returned display text.
  **Guard/DoD:** the consumer spec plus variable/detail/controller focused specs
  pass; wire logs show bounded `variables` with `format.hex` and no `evaluate`.
  Refresh the owned real Crystal controller probe afterward. This uses the
  existing DBG-3 CAUTION/rollback boundary, not new adapter settings or native
  formatter imports.
- Validate provisional limits against D08: 100 children/page, 5,000 retained
  nodes, 8 MiB display data, 64 KiB selected detail and bounded depth. Output
  ring is separately capped at 1 MiB with dropped-count notice. Adjust only
  from measured probe evidence; UI must expose partialness and limit reason.
- Repeat DBG-0 real C, Crystal and Adamas probes for locals/scopes/types/children
  through `scripts/probe_debugger_controls.sh`; report each outcome separately.
- **DoD:** shared Crystal command below with `spec/debug_variable_limits_spec.cr spec/debug_watch_safety_spec.cr spec/debug_value_detail_spec.cr spec/dap_stale_handle_spec.cr`, plus DBG-0 probe; expect bounded hostile values, correct Hex/Raw/JSON availability, stale-generation rejection, explicit evaluation and per-compiler locals evidence.
  Useful release needs DBG-2/3 plus real-binary stepping, locals and children
  for one declared Crystal or Adamas target. C alone is foundation; report each
  compiler separately.

### DBG-4 — explicit local-PID attach and detach

- **Depends on:** DBG-1/DBG-2. **Risk:** CAUTION (external target ownership).
  **Rollback:** revert attach UI/controller/tests; launch mode remains unchanged.
- Red-first D11 in `debug_attach_ownership_spec.cr`: success, permission
  denial, timeout, target survives default Detach, and gated terminate needs
  separate approval. Never kill an adapter-reported PID. Stage dirty-file
  choices, then final terminate/detach approval
  before target mutation, discard/close or root change. Cancel preserves project
  and session; explicitly approved saves may remain persisted.
- Add only explicit PID attach fields to `debug_profile_store.cr` and controller;
  no scanning, auto-attach, remote target, or attach at startup.
- **DoD:** shared Crystal command below with `spec/debug_attach_ownership_spec.cr spec/debug_ownership_spec.cr`, plus `scripts/probe_debugger_attach.sh --adapter "$ADAMANTINE_DEBUG_LLDB_DAP" --fixture spec/fixtures/debugger/attach_target.c`.
  Script owns the PTY fixture, attaches by observed PID, detaches and verifies
  it remains alive; fails (never skips) without real-adapter evidence.

### DBG-5 — inferior terminal (separate capability gate)

- **Depends on:** DBG-1/DBG-2 plus a supported OS PTY/process-ownership design.
  **Risk:** CAUTION (live IO, child processes). **Rollback:** remove only the
  terminal bridge; continue to reject `runInTerminal` with a DAP error.
- Red-first D15 in `debug_terminal_pty_spec.cr`; add proposed
  `debug_terminal_session.cr` and `scripts/smoke_debugger_terminal.rb`. Exercise
  stdin, literal argv, env overrides/removals, resize, EOF, interrupt, output
  limits and cleanup with an actual inferior PTY. The editor's existing PTY
  smoke alone is not evidence of target-terminal support.
- Advertise `supportsRunInTerminalRequest` only after both DAP reverse-request
  reply and bidirectional inferior IO are proven. Otherwise reject promptly.
- **DoD:** shared Crystal command below with `spec/debug_terminal_pty_spec.cr`, plus `scripts/smoke_debugger_terminal.rb --fixture spec/fixtures/debugger/terminal_target.c`.
  **Expected:** test inferior observes input/resize/EOF/interrupt and output
  returns to the terminal view; exit/reap is bounded.

### DBG-N — language-native formatters (new separately scoped work)

- **Depends on:** DBG-0/DBG-3 evidence and a separate accepted compiler/ABI
  Frontier SDD before changing Adamas/compiler or formatter code. **Risk:**
  CAUTION (ABI, memory safety, misleading values). **Rollback:** disable the
  specific formatter and retain generic adapter summary/children.
- Red-first D14 editor capability test: `spec/debug_native_format_spec.cr`.
  Proposed `src/adamantine/debug_formatter_capabilities.cr` is view/profile
  glue only. ABI/value work is separate Adamas scope at existing
  `tools/lldb/crystal_formatters.py` in the Adamas compiler checkout, with
  proposed `tools/lldb/test_formatters.py` and
  `tools/lldb/probe_native_values.py`; require its own SDD.
- Never claim providers passive, call target methods, guess offsets or infer a
  shared stock Crystal/Adamas ABI. Keep per-version/architecture goldens in the
  Adamas task. Darwin `probe.ll`/`probe.o` plus
  `llvm-dwarfdump --debug-info probe.o` evidence only debug-info emission, not
  runtime expression or formatter correctness.
- **DoD:** separate Adamas task runs `cd "$ADAMANTINE_DEBUG_ADAMAS_SRC" && "$ADAMANTINE_DEBUG_PYTHON" tools/lldb/test_formatters.py && "$ADAMANTINE_DEBUG_PYTHON" tools/lldb/probe_native_values.py --adamas-bin "$ADAMANTINE_DEBUG_ADAMAS_BIN" --adapter "$ADAMANTINE_DEBUG_LLDB_DAP"`; expect ABI/version goldens and union/pointer/metadata fallback. Editor `spec/debug_native_format_spec.cr` tests capability glue only; no generic DAP claim changes.

## Shared build, resource and closure gates

- Before later Crystal builds/specs, verify the `shard.lock` pin
  `7ca26fd559cf8c05e5b4ed924e7c691fabb66e43` against
  `git -C "$ADAMANTINE_DEBUG_TUI_SRC" rev-parse HEAD`. Installed `lib` may be
  stale; append stdlib from `crystal env CRYSTAL_PATH` after the pinned TUI `src`
  and repo `lib`. Stop if the pin is unproven.
- Use a task-owned writable `$ADAMANTINE_DEBUG_CRYSTAL_CACHE_DIR` under
  `/private/tmp` (not a repo or user cache); scripts own and clean only their
  exact `mktemp` outputs. Use the
  system-linker workaround required on this host:
  `CRYSTAL_CACHE_DIR="$ADAMANTINE_DEBUG_CRYSTAL_CACHE_DIR" CRYSTAL_PATH="$ADAMANTINE_DEBUG_TUI_SRC/src:$PWD/lib:$(crystal env CRYSTAL_PATH)" crystal spec --link-flags=-fuse-ld=/usr/bin/ld --error-trace <slice-specs>`.
  Run focused slices, then full specs/build, format check and fake/PTY smokes;
  planning itself ran no builds/tests; actual slice results are recorded above
  and in the frontier, not inferred from these future commands.
- Keep parser/frame/request/queue limits measured and configurable within the
  frontier bounds. Critical state events are never silently evicted; user data
  and editor diagnostics remain intact on adapter failure. Raising a limit is
  explicit and applies to the next session.
- Each gate is a separate reviewable implementation slice and commit after its
  DoD passes. Roll back by reverting only that gate's commit; never reset the
  worktree, rewrite the user's sparse keymap, touch the user-owned Makefile, or
  remove artifacts outside a verified temp directory. A failed gate narrows
  support and blocks downstream widening; it does not turn a plan/request into
  an implemented feature.
