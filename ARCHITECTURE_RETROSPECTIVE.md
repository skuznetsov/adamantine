# Architecture Retrospective: Crystal Editor

## Current Observation

The current codebase is progressing in the right direction (extracted `NavigationController`, `LspController`, `InputRouter`, `CommandPalette`, and `OverlayController`), but `App` is still the central orchestration object.

`App` still owns:
- UI composition/layout (`initialize`, `compose`, `layout_children`)
- Global state and cross-feature state (`@open_buffers`, trees, tabs, overlays, command mode, settings mode, navigation stacks, LSP client)
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
- `NavigationController` and `LspController` receive and mutate many parent-level ivars directly (`@lsp`, `@open_buffers`, `@status_log`, etc.), so behavior is distributed but not owned cleanly.
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
   - Move buffer registry + active document resolution + tab operations into one module/object.
   - Keep LSP sync as a service boundary triggered by document events.

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
