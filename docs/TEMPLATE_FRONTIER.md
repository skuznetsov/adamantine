# Editor templates frontier

Document status: implemented and locally verified at the current source state.
Bounded context: Adamantine-owned templates, not LSP completion snippets.

## Admitted surface for this slice

- Explicitly invoked templates for the active document, discoverable through
  F1 and `:template`. Built-ins cover the Crystal/Adamas editing path.
- Optional bounded user and project JSON catalogs. Project definitions may
  override user definitions for the same language and trigger. Invalid files
  leave built-ins available and produce a visible warning.
- One atomic insertion, ordered local tabstops, Tab/Shift+Tab navigation, and
  Escape to leave field navigation without reverting text. Changes to the
  active field keep later stops aligned; edits outside it end the session.
- No full-document materialization for lookup, insertion, or navigation.

## Rejected and guard-only surface

- Do not advertise LSP `snippetSupport` or accept LSP
  `insertTextFormat: 2`; the internal parser does not cover that grammar.
- No implicit trigger expansion, script execution, template commands,
  workspace edits, linked placeholders, choices, variables, or transforms.
- Preview-in-buffer and live configuration editing remain future UX work;
  the explicit picker must be usable without them.

## Falsifiers and stop rules

- Acceptance must not edit if the active buffer, editor, cursor, selection, or
  revision changed while the picker was open.
- Unicode and multiline bodies must place stops correctly; CRLF, indentation,
  undo/redo, split-editor focus, disabled LSP, and modal paste/key isolation
  must retain their existing semantics.
- Malformed/oversized templates fail closed without partial insertion. A
  session must cancel when its position cannot be updated safely.
- Do not claim this slice verified until focused specs, the root suite,
  formatting, release build, and a bounded adversarial check pass.

## Local closure evidence

- Focused catalog/config/session/UI/router run: 66 examples, 0 failures or
  errors. The first full run exposed the modal route-order contract; updating
  that contract made its focused suite pass.
- Root suite: 1106 examples, 0 failures or errors on the final feature code.
- `crystal tool format --check src spec`, `git diff --check`, and release build
  with the system linker are the final format/build gates.
- Adversarial checks cover stale picker targets, malformed and oversized
  catalogs, terminal control characters, CRLF, Unicode offsets, indentation,
  modal paste isolation, and one-step Undo of the initial insertion. These
  establish local behavior, not full end-to-end terminal UX across platforms.
- A real-terminal smoke now runs against the release executable. On macOS, the
  command `ruby scripts/smoke_template_split.rb /tmp/adamantine-template-split-smoke`
  passed twice in 2.32–3.73 seconds: a 70-column split was refused with
  widening guidance, a 100-column terminal opened two groups, picker paste and
  typing stayed isolated, and the built-in method template saved into the
  active right group without changing the left file. The CI workflow runs this
  bounded smoke after its existing release build; Linux CI execution remains
  pending.

LSP snippets stay rejected. Reopen this certificate when the parser grammar,
text editor change semantics, command router, or config format changes.

Rollback: revert the atomic template feature commit. The existing user-owned
`Makefile` modification is outside this slice and must remain untouched.
