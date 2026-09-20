# Keymap Semantics Frontier

Status: accepted implementation frontier for the keymap semantics slice.

## Problem

Adamantine currently loads defaults and replaces them with non-empty configured
bindings. An empty binding is written by Settings but discarded on reload, so a
removed default silently returns. Several help surfaces also advertise that
default even while the runtime map considers the action unbound. Finally,
editor-owned Ctrl+S/Z/Y handling can bypass the application keymap.

## Admitted behavior

- A missing action in `keymap` inherits Adamantine's current default.
- A non-empty string or array replaces the complete binding list for that
  action after normalization.
- An exact empty JSON array (`[]`) is an explicit unbind and survives reload.
- Empty strings, `null`, unsupported values, and non-empty arrays that contain
  no valid bindings are invalid overrides. They produce a warning and do not
  silently unbind a default.
- Unknown action names are preserved for extension compatibility, including an
  explicit empty array.
- Interactive changes preserve a sparse user-override layer. Saving a keymap
  does not pin every inherited default, and unrelated configuration sections
  remain unchanged.
- Settings exposes an explicit, confirmed unbind operation. Moving a key shows
  every conflicting owner in the same input context before it removes that key
  from those owners.
- Conflict diagnostics ignore intentional reuse between mutually exclusive
  modal contexts, but report reuse within the global/focused route or within
  the same modal context.
- Help, Settings, command discovery, context menus, and status hints describe
  the effective runtime map. An empty action is shown as `unbound`; a real
  same-context collision is marked as a conflict.
- Application shortcuts do not fall through to legacy editor Ctrl+S/Z/Y
  handlers after remap or unbind.
- Settings consumes unrelated keys while its modal is open, so remapping or
  unbinding cannot accidentally edit the document behind the dialog.

## Guard-only behavior

- Escape/Enter/arrows/Tab that form a modal's safety and navigation protocol
  may remain physical fallbacks. They are modal controls, not global action
  bindings, and documentation must distinguish them from remappable shortcuts.
- Clipboard and editor Tab keys remain consumed at the existing routing safety
  boundary when their actions are unbound, so they cannot mutate the editor via
  an old widget fallback.
- Existing contextual routing priority remains unchanged.

## Rejected for this slice

- Key chords or multi-step sequences.
- Per-language, per-workspace, or mode-specific keymap profiles.
- Macros, arbitrary command bindings, hot reload, and external keymap editors.
- A redesign of terminal key decoding or modal routing precedence.

## Falsifiers and Definition of Done

1. Load, save, and reload `{"keymap":{"app.save":[]}}`; `app.save` remains
   empty while an omitted action still inherits its default.
2. Invalid empty/scalar values warn and retain the inherited default.
3. Remap Save onto Close Tab, accept the complete conflict, restart, and prove
   Save owns the key while Close Tab stays explicitly unbound.
4. Save a mixed override/unbind/unknown-action map and prove unrelated root
   configuration survives and inherited defaults are not serialized.
5. Settings can confirm/cancel an unbind and renders `unbound` without
   resurrecting a default.
6. Same-context conflicts list every owner and are marked in discovery; reuse
   across exclusive modal contexts is not reported.
7. Unbound/remapped undo, redo, and save keys cannot execute the editor's old
   physical Ctrl+Z/Y/S behavior.
8. Focused keymap, routing, Settings, discovery, and full regression suites are
   green; formatting and diff checks are clean.

## Rollback

The work is isolated on `codex/keymap-semantics` and will be one atomic commit.
Reverting that commit restores the previous loader, Settings flow, and hints.
