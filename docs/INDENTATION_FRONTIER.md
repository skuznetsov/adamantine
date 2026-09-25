# Indentation frontier

Status: implemented; verification evidence below (2026-09-18).

## Admitted design

- Space-based indentation, width 1 through 8 (default 2), and auto-indent
  enabled by default. Persist `editor.indent_width` and `editor.auto_indent`
  in the existing JSON config, preserving unrelated keys. Expose both in F10.
- Plain Tab inserts one configured indentation unit at a caret; with an active
  selection it indents touched lines. Shift+Tab removes up to one unit of
  leading spaces, or one leading tab, from touched lines/current line.
- A selection ending at column zero excludes that final line. Keep logical
  selection and cursor positions useful after shifting lines. One command is
  one undoable edit; no-op dedent creates no undo entry.
- Enter copies the leading whitespace before the replacement/caret position;
  it does not infer language structure. Auto-indent off inserts only newline.
  Preserve the document's line endings and normal dirty/LSP change path.
- Editor commands are remappable (`app.indent`, `app.dedent`); plain Tab and
  Shift+Tab must not accidentally move focus or invoke hardcoded widget editing
  after remapping. Outside the editor retain normal focus navigation. Modals
  must not mutate a document behind them. Shift+Enter remains quick actions.
- Keep the pinned TUI dependency unchanged. Use an application-owned editor
  subclass and rope-local mutations, not whole-document text replacement.

## Non-goals and limits

No language-aware indentation, EditorConfig, per-language/per-file detection,
literal-tab insertion mode, visual-width/grapheme repair, or reformat-on-save.
Existing tab prefixes are preserved by Enter; current tab rendering is not
certified by this slice. Selected-line indentation and dedentation use the
existing full-change LSP notification path; caret Tab and Enter produce
incremental changes. No total-process memory or LSP performance claim follows.
Prefix detection reads bounded rope slices rather than a complete line.
Enter still allocates the actual indentation being copied; a genuinely huge
whitespace prefix requires proportionate output storage.

## Plan and risk

CAUTION: editing and persisted settings can damage text or config if incorrect.
Rollback is one atomic local commit; preserve the user's Makefile. No push.

1. `settings_config.cr`, `settings_state.cr`, `editing_settings.cr`: validate
   and persist editor settings; test bad values, legacy JSON, and unrelated
   fields surviving saves in either direction.
2. `editing_text_editor.cr`, `document_orchestrator.cr`, `app.cr`,
   `input_router.cr`, `key_config.cr`: implement local editing and settings UI.
   First reproduce raw Tab/Enter failures; cover CRLF, reversed selections,
   terminal-zero exclusion, no-op dedent, Undo/Redo, modal and tree isolation.
3. Parent independently runs raw terminal dispatch and large-buffer checks,
   reviews the diff, updates controls, and executes the complete suite/build.

DoD: focused indentation/config specs, `crystal spec`,
`crystal tool format --check src spec`, release build and `--help`, diff check.
On this host use `CRYSTAL_CACHE_DIR=/private/tmp/adamantine-indent-cache` and
`--link-flags=-fuse-ld=/usr/bin/ld`. Strongest failure guards: selection and
CRLF transformations must preserve untouched bytes and undo exactly; local
indent must not materialize or replace the complete multi-megabyte document.

## Evidence and boundaries

- Baseline terminal-input probes failed for Tab (focus traversal) and Enter
  (missing indentation), while ordinary input plus Undo passed.
- `spec/indentation_terminal_spec.cr` exercises the real input parser, mounted
  headless app, Tab/back-tab/remapping, CRLF selection boundaries, focus
  navigation, and modal isolation. A failing palette back-tab probe exposed
  global-action fallthrough; editor actions now require normal mode and editor
  focus. Modal Tab variants are also consumed before framework fallbacks.
- `spec/indentation_spec.cr` covers caret edits, forward/reversed selections,
  leading tabs/spaces, no-op history, CRLF, normalized selection-start prefixes,
  and separate Undo entries for repeated Enter.
- `spec/indentation_large_buffer_spec.cr` uses a 4,080,000-byte document and
  rejects whole-document public getters/replacement during local edits. Two
  selected lines add exactly eight stored bytes, preserve distant lines, and
  undo/redo as one command. Caret Tab/Enter use incremental notifications and
  shared history storage. Additional guards reject whole-line materialization
  for a 4 MB single line and verify prefixes spanning multiple scan chunks.
  This is a structural guard, not an RSS benchmark.
- `spec/editing_settings_spec.cr` covers independent field defaults, false
  booleans, out-of-Int32 widths, JSON size limits, and fail-safe preservation.
  `spec/indentation_settings_integration_spec.cr` covers existing/new tabs,
  theme reapplication, width wrap, persistence and failed-save runtime behavior.
- Parent verification: full suite **495 examples, 0 failures, 0 errors**;
  formatting and diff checks pass. Release build and `bin/adamantine --help`
  pass with the host linker flags above.

Adversary outcome: the initial review found the long-single-line allocation
above (VULNERABLE). A failing whole-line getter guard reproduced it; bounded
prefix reads pass that guard. Parent source review and executed counterchecks
support ROBUST within the admitted editing/configuration boundary, not an
arbitrary-size memory or throughput guarantee.

Tests use temporary config files and an unsupported clipboard backend, never
the desktop clipboard. The pinned dependency and user's Makefile are unchanged
by this feature. Re-run these checks after changes to the TUI dependency,
editor mutation/history API, input routing, or config persistence.
