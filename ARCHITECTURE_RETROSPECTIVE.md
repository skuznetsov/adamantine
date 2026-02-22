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
- `InputRouter` still depends on multiple `App`-owned concerns (`@settings_open`, `@context_menu_open`, `@lsp_popup_open`, `@file_panel`, `@editor_tabs`) and action methods (`open_file`, `open_settings_dialog`, `goto_definition`, etc.) that are implemented in other modules of same class.
- `NavigationController` and `LspController` receive and mutate many parent-level ivars directly (`@lsp`, `@open_buffers`, `@status_log`, etc.), so behavior is distributed but not owned cleanly.
- `Settings` and `KeyConfig` updates are still tightly coupled with UI state and key map persistence.

## Risks Right Now

1. **Action/Mode Coupling Risk**
   - Event handling and UI-mode state live in one chain; adding new modal behaviors increases branching complexity.
2. **Testing Depth Risk**
   - Existing specs validate many user-visible behaviors, but not all transitions between all modes are locked (e.g., popup/settings/context + stale keyboard races).
3. **Refactor Churn Risk**
- New contributors can modify one module and need to understand hidden state in `App` to avoid regressions.

## What changed recently

- Input routing moved from long `if/elsif` chain to ordered route table:
  - `src/editor/input_router.cr`
  - This reduced ordering ambiguity and made conflict behavior explicit.
- LSP methods moved out of `App` into `LspController`:
  - `src/editor/lsp_controller.cr`
- Specs expanded to cover modal and key-routing edge cases:
  - `spec/input_router_spec.cr`

## Near-term Refactor Plan (god-object hardening)

1. **Phase 1: Router and Mode Engine**
   - New `KeyboardModeEngine` type responsible for:
     - active mode (`command`, `settings`, `context_menu`, `popup`, `normal`)
     - precedence resolution
     - action dispatch (pure decision list + executor table)
   - `InputRouter` becomes a thin adapter from `Tui` events -> engine.

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

## Confidence Signals

- Existing tests currently indicate no regression after routing refactor (`51` examples, green).
- The next hardening tests should reduce accidental regressions as action map grows and new modes are added.
