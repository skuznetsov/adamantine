# Architecture Retrospective: Crystal Editor

## Deep Review (2026-02-22)

### Current Position

The editor has moved from single-pass behavior edits to explicit route-driven input control and snapshottable modal state. The biggest win is now the testable contract between:

- `InputModeController::ModeStack` + route predicates in `InputModeController`
- `InputRouter` route tables + mode precedence in `KeyModeRoute`
- `NavigationController` / `LspController` / `CommandPalette` ownership of feature behavior

This materially reduces accidental coupling inside `App` for interaction routing, but most domain state and service lifecycles still live in `App`.

### Post-commit Snapshot (after `8637923`, 2026-02-22)

- Completed extraction of document-state container:
  - Added `src/editor/document_session.cr` and moved `open_buffers`, navigation history, and mark storage behind this object.
  - Removed direct ownership fields from `App` for those state areas.
- Kept route/mode contracts unchanged while reducing some shared mutable surface by moving types to `src/editor/document_types.cr`.
- Verification after commit:
  - `crystal spec` → `78 examples, 0 failures, 0 errors, 0 pending`
  - `make check` → build + spec + harness OK (including `crystal_v2_lsp` handshake)

### Current Position (Re-evaluated)

- `InputModeController::ModeStack` + route table design still looks correct.
- Remaining centralization is now explicit: `App` still owns orchestration, document lifecycle entrypoints, modal stack integration, and LSP lifecycle.

### Evidence of Progress (post-commit)

- Route precedence is now explicit and order-stable in tests:
  - modal route order contract in `spec/input_router_spec.cr`
  - global key route order contract in `spec/input_router_spec.cr`
  - `ModeStack` is a dedicated type (`InputModeController::ModeStack`) and is now used as App-owned state.
- Error-safe overlay lifecycle is tested via forced overlay failure (`FailingOverlayApp` spec).

### Outstanding God-object Pressure

`App` is still the convergence point for:

- buffer/session state (`@document_session`, active tab behavior, file operations),
- command/palette workflows (`@command_*` fields),
- modal configuration (`@settings_*`, marks, themes),
- LSP wiring (`@lsp`, sync callbacks),
- and all UI composition/layout hooks.

Each of these blocks is implemented through extracted modules, but ownership remains centralized and mutations still cross-cut.

### Architecture Drift Risks (ranked)

1. **Modal behavior coupling**
   - Overlay lifecycle and mode transitions are mostly correct now, but they are still coupled to concrete App fields, increasing the cost of adding a new modal mode (e.g., `FindReplace`, `DiffPreview`).

2. **Testing blind spots**
  - Route precedence is covered, but recovery behavior is weaker around chained failure modes:
    - LSP disconnection while menu popups are open.
    - Project root changes while marks/reference locations point to old directories.
    - Escape/double-escape semantics with overlapping mode and overlay state.

3. **Protocol depth vs. feature depth**
   - LSP JSON-RPC client supports many requests, but high-frequency editor actions are not yet consistently abstracted behind a document service, so protocol expansion can still leak into App.

4. **Editing UX gap**
   - The current editor is strong in file/LSP navigation and modal workflows, but still sparse in classic editing ergonomics (undo/redo UI affordances, split diff views, block selection workflows).

### Quadrumvirate Review

- **Cassandra (forecast)**
  - Most likely next regressions are in state transitions when new modes and new LSP request categories are introduced in the same event path.
- **Maieutic (assumptions challenged)**
  - Assumption: route ordering is sufficient to make modal behavior safe.
  - Falsifier: introduce a fifth-mode stack with forced open/close failure and verify stack restoration + mode precedence.
- **Daedalus (frame shift)**
  - Move from "feature methods in App calling each other" to "document/session/LSP controllers with explicit DTOs and event adapters".
- **Adversary (checks)**
  - Add tests for asynchronous LSP failures and command-mark lifecycle when project root changes.

### Proposed Hardening Spec Set

1. **`spec/app_state_spec.cr`**
   - `close_active_tab`, mark persistence and navigation history consistency under repeated open/close and root changes.

2. **`spec/modal_stack_spec.cr`**
   - Full-stack precedence with all overlays active in sequence.
   - Assert command palette dominance over a dirty context menu while preserving previous open/close state.

3. **`spec/lsp_protocol_spec.cr`**
   - Contract tests for protocol methods that should map to UI actions (hover/references/signature/completion/diagnostics/code actions + rename/rename preview).

4. **`spec/feature_regression_spec.cr`**
   - `:mark/:jump` robustness across relative paths, non-file URIs, and deleted target files.
   - Replace flow for `:s`/`:r` with preview and apply modes.

### Strategic Next Step

Keep the current line for route/mode hardening and add one domain service at a time:

- `DocumentSession` (buffer + editor tab lifecycle),
- `ModalManager` (all overlay/modal modes),
- `LspSession` (connection + diagnostics + request dispatch),
- then re-home `App` as orchestration glue only.
## Current Observation

The current codebase is progressing in the right direction (extracted `NavigationController`, `LspController`, `InputRouter`, `CommandPalette`, and `OverlayController`), but `App` is still the central orchestration object.

`App` still owns:
- UI composition/layout (`initialize`, `compose`, `layout_children`)
- Global state and cross-feature state (`@document_session`, trees, tabs, overlays, command mode, settings mode, LSP client)
- Event dispatch precedence and mode transitions
- Domain actions (file IO, navigation history, search/replace, marks, LSP command execution, project tree operations)

This is effectively a **god-object concentration point with explicit behavior extraction around it**, not yet a true service boundary model.

## Evidence (Concrete)

- `App` length is still large (`~1300` lines) and contains initialization, routing, and many feature methods.
- `InputRouter` no longer depends on raw overlay-open booleans for mode routing; it now queries derived `InputMode` predicates.
- `App` still owns most integration state and modal lifecycles, but overlay mode transitions now use an explicit stack:
  - `src/editor/app.cr` (`InputMode` stack, open/close synchronization)
  - `src/editor/input_router.cr` (routes consult `settings_mode_active?`, `context_menu_mode_active?`, `lsp_popup_mode_active?`)
  - `src/editor/keyboard_mode_engine.cr` (mode route execution abstraction)
- Mode-transition lifecycle is now extracted into `InputModeController`:
  - `src/editor/input_mode_controller.cr`
  - predicate methods (`command_palette_active?`, etc.) + stack transitions moved here, reducing `App` responsibility.
- `NavigationController` and `LspController` receive and mutate many parent-level ivars directly (`@lsp`, `@document_session`, `@status_log`, etc.), so behavior is distributed but not owned cleanly.
- `Settings` and `KeyConfig` updates are still tightly coupled with UI state and key map persistence.

## Risks Right Now

1. **Action/Mode Coupling Risk**
  - Event handling and UI-mode state still live in one class; adding new modal behaviors increases branching complexity.
2. **Testing Depth Risk**
  - Existing specs validate many user-visible behaviors, but not all transitions between all modes are locked (e.g., popup/settings/context + stale keyboard races).
3. **Refactor Churn Risk**
- New contributors can modify one module and need to understand hidden state in `App` to avoid regressions.
4. **Mode Stack Drift Risk**
  - `InputMode` transitions were mostly manual (`enter_input_mode`/`exit_input_mode`), so any new mode had to register open/close points exactly once.
5. **Overlay Mount Failure Risk**
  - Overlay creation could fail after mode push and leave modal state inconsistent.

## What changed recently

- Input routing moved from long `if/elsif` chain to ordered route table:
  - `src/editor/input_router.cr`
  - This reduced ordering ambiguity and made conflict behavior explicit.
- Input modes are now represented by a stack with explicit transitions:
  - `src/editor/app.cr`
  - `src/editor/input_router.cr`
  - `spec/input_router_spec.cr` (nested overlay stack restore behavior)
- LSP methods moved out of `App` into `LspController`:
  - `src/editor/lsp_controller.cr`
- Specs expanded to cover modal and key-routing edge cases:
  - `spec/input_router_spec.cr`

## Near-term Refactor Plan (god-object hardening)

1. **Phase 1: Router and Mode Engine**
   - ✅ Done: `InputMode` stack + route predicates in dedicated `InputModeController` (`src/editor/input_mode_controller.cr`),
     route-driven dispatch in `InputRouter`, and nested overlay restore verified in specs.
   - Hardening done:
     - overlay open paths now use `with_input_mode_guard` in `App` and `CommandPalette` to restore input-mode stack on overlay mount failure.
     - added regression spec for failed overlay mount not leaking mode.
   - Hardening done:
     - extracted mode stack state into dedicated `ModeStack` object (`InputModeController::ModeStack`), moved from direct ivar use.
     - `App` now holds `@input_mode_controller` only.
   - Next hardening:
     - promote `ModeStack` to a first-class controller service with explicit invariants and lifecycle hooks.

2. **Phase 2: Document Session Service**
   - Done: document ownership (`@document_session`) now centralizes buffer registry, marks and navigation history.
   - Next: move active tab lifecycle and tab-focused navigation commands into document service methods.

3. **Phase 3: LSP Session Service**
   - isolate protocol lifecycle (`connect`, `start`, `diagnostics`, `on_document_*`) from `App`.
   - expose stable result DTOs for `App` to render and execute.

4. **Phase 4: Settings/Key Binding Domain**
   - separate keymap persistence UI from in-memory binding model.
   - create explicit conflict strategy interface (`deny`, `override`, `prompt`) to keep behavior testable.

## Concrete next commit candidates

- Add a dedicated spec for **mode precedence** with all overlays visible:
  - command palette > settings > context menu > popup > global fallback.
- Add focused spec for `InputRouter` route table integrity:
  - each table route resolves to a dedicated handler and preserves order.
- Introduce explicit `AppState` snapshot type for tests to avoid direct ivar reach-through.

## God-object Audit (Focused)

- `App` as single orchestration sink
  - Pros: quick feature velocity and straightforward data locality for terminal UI flows.
  - Cons: new features often require touching three+ modules simultaneously, creating merge pressure and hidden coupling.

- Current containment hotspots
  - `InputRouter` has clear delegation boundaries but still relies on `App` state (`@file_panel`, `@editor_tabs`, `@status_log`).
  - `LspController`/`NavigationController` centralize protocol/domain logic but remain mutation-heavy against `App` ivars.
  - Settings UX still lives in `App` while key-binding persistence is split between `KeyConfig` + `Settings` handlers.

- God-object drift indicators (measurable)
  - number of `include` modules grows while shared mutable state remains in one owner;
  - test doubles still require `TestApp` subclassing to expose behavior;
  - lifecycle coupling (open/close overlay + state + focus) handled by route handlers and not by a dedicated mode service.

## Quadrumvirate Check (Retrospective)

- Cassandra (risk forecast): likely next regressions are precedence and race conditions in route/mode transitions when new modal overlays are added.
- Maieutic (critical assumption): `ModeStack` + ordered route guards are sufficient to prevent all modal regressions.
  - falsifier to keep: open/close two overlays without focus change + command palette in the middle.
- Daedalus (frame shift): move from “single state owner + helpers” toward explicit domain services for session-doc, modal-session, and key-mapping to reduce future accidental coupling.
- Adversary check needed: malformed keymaps and repeated mode transitions under exceptions/harness failures.

## Suggested Additional Specs

- mode precedence chain
  - command palette / settings / context-menu / popup / global fallback order is strict and stable.
- conflict transparency
  - when two actions map to same key, first route in table is deterministic and covered by test.
- overlay failure matrix
  - exception in open and close paths should never desync mode stack or UI-facing mode predicates.

## Confidence Signals

- Existing tests currently indicate no regression after routing + mode-stack refactor (`56` examples, green).
- The next hardening tests should reduce accidental regressions as action map grows and new modes are added.

## Operational Snapshot (2026-02-22)

- Baseline commit: `8637923` (DocumentSession extraction and command-mark/navigation-state migration).
- Verification signals:
  - `make spec` → `78 examples, 0 failures, 0 errors, 0 pending`
  - `make harness` → handshake with `/Users/sergey/PRojects/Crystal/crystal_v2_repo/bin/crystal_v2_lsp` success
  - `make check` → build + spec + harness OK
- Current architecture state:
  - Routing/mode boundaries are now contract-driven and well-tested.
  - `App` still remains central owner for orchestration, modal integration, settings, and LSP wiring.
  - Most practical coupling risk is now concentrated around cross-module state mutation in `App`-owned ivars.
- Proposed immediate next action (next small commit):
  - Extract a `ModalManager` to own settings/context/lsp-popup/command-palette interactions and stack safety.
  - Extract a `DocumentOrchestrator` service for tab lifecycle methods (`open_file`, `close_tab`, `switch_to_tab*`) while keeping `DocumentSession` as state holder.
  - Add an explicit App snapshot fixture for `@document_session` assertions used by tests.

## Deep Review Update (2026-02-22, after `a067a44`)

### Verification Delta

- Test surface expanded with `spec/document_orchestrator_spec.cr` (6 additional examples) to lock `DocumentOrchestrator` contracts.
- `make check` currently reports:
  - `89 examples, 0 failures, 0 errors, 0 pending`
  - harness LSP handshake success with `/Users/sergey/PRojects/Crystal/crystal_v2_repo/bin/crystal_v2_lsp`
- Document-specific regression risk around edit/save callbacks and tab marker state is now directly covered.

### What changed in the architecture risk profile

- Positive:
  - `DocumentOrchestrator` moved from “integration-adjacent behavior” to a test-enforced contract boundary.
  - Editing side effects are now explicit in tests (change callback, version increment, modified-tab labeling, save callback).
  - This reduces blind regressions when refactoring tab handling and file lifecycle.
- Still negative:
  - The orchestrator is still mostly a service with multiple callbacks into `App`, meaning cross-module invariants are not yet owned by a dedicated layer.
  - Failure-path behavior on callback exceptions remains untested.
  - `App` still drives too much overlay behavior despite route stabilization.

### New or Refined Hypotheses

- Cassandra: after test-hardening, next high-probability regressions are still around exception paths (overlay mount failure, LSP callback failure, close-order side effects), not around happy-path tab lifecycle.
- Daedalus: if callback-heavy services continue to live in `App`, any modal addition will still couple unrelated event paths.
- Maieutic:
  - what must be true for stable refactor: orchestrator must own close semantics and not defer tab state cleanup to callers.
  - falsifier: close tab callback order can desync `open_buffers`, `tabs`, and mode predicates in a single event.

### Adversarial checks needed next

1. Induce exceptions inside injected callbacks in `DocumentOrchestrator` and assert no leaked modal/input state or partially-mutated tab state.
2. Simulate rapid open→edit→close sequences to ensure callback order and final status log/header updates remain consistent.
3. Assert route mode precedence when overlay mount fails while command/context/menu modes overlap.

### Immediate action list after this update

1. Add callback-failure unit specs for `DocumentOrchestrator` around `sync_change` and `sync_save`.
2. Add full overlay precedence spec that includes `command palette + settings + context menu + popup`.
3. Start `ModalManager` extraction ticket after the two specs above.

## Deep Review Update (2026-02-22, after `e10213a`)

### Verification Delta

- `crystal spec spec/lsp_protocol_spec.cr` → `5 examples, 0 failures`.
- `make check` → `94 examples, 0 failures` (including harness against `/Users/sergey/PRojects/Crystal/crystal_v2_repo/bin/crystal_v2_lsp`).

### God-Object Status

- `src/editor/app.cr` remains the single orchestration owner for:
  - modal state (`@command_*`, `@settings_*`, `@context_menu_*`, `@lsp_popup_*`),
  - UI routing side-effects (`@input_mode_controller`),
  - session-owned services (`@document_session`) orchestration hooks,
  - LSP client lifecycle (`@lsp`) and request paths.
- The module split is healthy, but ownership did not move: this is a **structured god-object**, not yet true decoupling.

### Quadrumvirate Notes

- Cassandra: likely future failures are in cross-layer exception paths (overlay open failures + stale modal state + missing LSP client) rather than plain routing order.
- Daedalus: next frame shift is to promote `ModalManager`/`LspSession`-style service boundaries with explicit transition invariants and immutable event payloads.
- Maieutic: if route ordering alone were sufficient, an adversarial overlap of all overlays in one pass should never desync mode predicates; this remains an open falsifier.
- Adversary gaps:
  - context menu/LSP action path with disconnected `@lsp` is still weakly covered.
  - recovery from overlapping open/close sequences under no-LSP conditions is only partially locked.

### Suggested new specs (high value)

- `spec/lsp_protocol_spec.cr`
  - add no-op safety tests for `goto_definition`, `declaration`, `type_definition`, `implementation` when `@lsp` is nil.
  - assert stale navigation history is not mutated when LSP is unavailable.
- `spec/modal_stack_spec.cr`
  - add one end-to-end overlap scenario: command palette over settings over context menu over popup, then close in sequence, then re-open.
  - verify final `input_mode_stack_snapshot` and all flags.
- `spec/input_router_spec.cr`
  - add route collision tests across command mode + settings mode + modal mode for identical key bindings.
- `spec/lsp_protocol_spec.cr` (or separate)
  - add regression for context menu opening with unavailable LSP should emit warning and close cleanly without changing buffers.
## Deep Review Update (2026-02-22, after `3b062ff`)

### Verification Delta

- `crystal spec spec/lsp_protocol_spec.cr` → `7 examples, 0 failures, 0 errors, 0 pending`
- `make check` → `96 examples, 0 failures, 0 errors, 0 pending` (including LSP handshake against `/Users/sergey/PRojects/Crystal/crystal_v2_repo/bin/crystal_v2_lsp`)

### Concrete architectural impact

- `spec/lsp_protocol_spec.cr` now validates all declaration-style jump paths exposed by the LSP context menu:
  - `definition`, `declaration`, `type definition`, `implementation`
- The test fixture (`FakeLspClient`) tracks per-action call counters, so regressions in action dispatch order are now directly observable.
- Keymap-dependent test behavior was normalized by forcing explicit `lsp.goto_definition` binding when testing global key routing.
- This reduced one source of non-determinism tied to external user keymap state while preserving behavior contracts.

### God-object status after the hardening

- `App` remains the orchestration center and still owns modal, routing, and LSP wiring surfaces.
- Test strategy is now catching more cross-cut failures (`lsp_controller` actions, menu dispatch, navigation-history side effects), which is a practical signal that service boundaries are better tested than fully separated.

### Quadrumvirate check

- **Cassandra**
  - Most likely next faults are now in callback/exception paths inside action execution and menu callback lifecycle, not in happy-path action routing.
- **Maieutic**
  - Assumption under test: context menu action index order is stable.
  - Falsifier: reorder one menu entry label/handler while keeping same tests; if selection still passes, assertion is accidentally label-agnostic.
- **Daedalus**
  - Current frame is stable: from centralized `App` to more observable domain contracts.
  - Next shift remains `ModalManager` + explicit `LspSession` services with failure semantics.
- **Adversary**
  - Remaining high-value adversarial case: make an action callback throw from menu execution and verify mode stack/input flags are fully restored.

### Suggested next specs (ranked)

1. Add negative callback test for menu action execution exceptions (context menu action errors should never leak input mode or stale overlays).
2. Add regression test for explicit `declaration/type_definition/implementation` no-result path (LSP returns `[]`) and assert no navigation history growth.
3. Add contract test that `open_lsp_context_menu_public` with active LSP but no cursor location emits a user-visible warning and closes menu state.

### Confidence signal

- Current trend is stable: existing modal/routing/lsp contracts are green under deterministic CI-style runs; further risk budget should focus on exception-path hardening.

## Deep Review Update (2026-02-22, after `4920c65`)

### Verification Delta

- `crystal spec spec/modal_stack_spec.cr` → `4 examples, 0 failures, 0 errors, 0 pending`
- `make check` → `97 examples, 0 failures, 0 errors, 0 pending` (including harness against `/Users/sergey/PRojects/Crystal/crystal_v2_lsp`)

### Concrete Impact

- Added adversarial regression for exceptioning context-menu actions in `spec/modal_stack_spec.cr`.
- The spec proves nested mode recovery: when a context-menu action raises, the menu closes and parent `Settings` mode remains active.
- This validates one specific callback-failure class from previous architecture review.

### Adversary Status

- Previous high-risk gap ("menu action exception leaks modal/input state") is now explicitly tested and currently closed.
- Remaining highest-risk area is now action-result/error behavior in callback-heavy flows that do not currently toggle overlay state (e.g., non-modal background handlers).

## Deep Review Update (2026-02-22, after `8fba6f4` + follow-up LSP empty-result spec)

### Verification Delta

- `crystal spec spec/lsp_protocol_spec.cr` → `8 examples, 0 failures, 0 errors, 0 pending`
- `make check` → `98 examples, 0 failures, 0 errors, 0 pending` (including harness against `/Users/sergey/PRojects/Crystal/crystal_v2_lsp`)

### Concrete Impact

- Added `spec/lsp_protocol_spec.cr` case for declaration-style menu actions returning empty results.
- Verified that for `definition`, `declaration`, `type definition`, `implementation`:
  - selected action still invokes corresponding LSP method,
  - context menu closes cleanly,
  - no navigation history entry is appended,
  - user-facing warning is emitted when result set is empty.

### Risk reduction

- This closes the second highest-priority adversary gap from previous block: "empty LSP jump responses mutate navigation history or fail to report."
- Remaining watch list: empty-result and exception behavior for non-navigation LSP actions (hover/references/signature/diagnostics) and their side effects on overlays/history.

## Deep Review Update (2026-02-22, after `878d3db`)

### Verification Delta

- `crystal spec spec/lsp_protocol_spec.cr` → `9 examples, 0 failures, 0 errors, 0 pending`
- `make check` → `99 examples, 0 failures, 0 errors, 0 pending` (including harness against `/Users/sergey/PRojects/Crystal/crystal_v2_lsp`)

### Concrete Impact

- Added non-navigation empty-result coverage for:
  - hover (`No hover information`)
  - references (`No references`)
  - signature (`No signature help`)
  - code actions (`No code actions`)
  - diagnostics (`No diagnostics on current line`)
- For each case, assertions ensure:
  - popups remain closed,
  - navigation history is unchanged,
  - status message level is correct and user-visible.

### Risk status

- This closes the highest-priority remaining gap in the earlier adversary matrix around non-navigation LSP response handling.
- Focus moves to exception-path hardening for non-navigation callback handlers and explicit user-visible recovery behavior under thrown LSP errors.

## Deep Review Update (2026-02-22, after `692590f`)

### Verification Delta

- `crystal spec spec/lsp_protocol_spec.cr` → `10 examples, 0 failures, 0 errors, 0 pending`
- `make check` → `100 examples, 0 failures, 0 errors, 0 pending` (including harness against `/Users/sergey/PRojects/Crystal/crystal_v2_lsp`)

### Concrete Impact

- Expanded `spec/lsp_protocol_spec.cr` with negative-path fault injection coverage for non-navigation LSP actions.
- `FakeLspClient` now supports forced failures for `hover`, `references`, `signature`, `completion`, and `code_actions`.
- Added `does not leak state when non-navigation LSP action raises` spec:
  - forces `hover` and `references` exceptions,
  - verifies exceptions are surfaced,
  - verifies `lsp_popup_open` remains false,
  - verifies navigation history does not mutate on failure.

### Risk status

- This closes the previously identified exception-path gap for non-navigation action failures (`hover` and `references`), where state could leak after thrown LSP errors.
- Outstanding high-value adversary checks remain:
  - exception behavior for `completion`, `signature`, and `code_action`,
  - modal/input-mode restoration consistency when failures occur in richer user flows.

## Deep Review Update (2026-02-22, after `7c271bd`)

### Verification Delta

- `crystal spec spec/lsp_protocol_spec.cr` → `10 examples, 0 failures, 0 errors, 0 pending`
- `make check` → `100 examples, 0 failures, 0 errors, 0 pending` (including harness against `/Users/sergey/PRojects/Crystal/crystal_v2_lsp`)

### Concrete Impact

- Added failure-path assertions for `signature`, `completion`, and `code_action` within the existing non-navigation leak test.
- Assertions now verify for each path:
  - raised exception surfaces,
  - `lsp popup` remains closed,
  - navigation history is unchanged.

### Risk status

- This closes the remaining targeted non-navigation LSP exception leak gap in `show_signature_hint`, `show_completion_hint`, and `execute_code_action_hint`.
- Remaining focus remains broader exception-composition behavior across modal and overlay interleaving (mode-stack restoration under callback-heavy flows).
