# Clipboard and editing-key frontier

Status: verified locally for the headless routing and subprocess boundary below.

## Scope

Repair copy/cut/paste through Adamantine's application key routing without
changing the pinned `crystal_tui` dependency. Preserve modal input ownership
and explicit quit behavior. Indentation and other editing features are separate
slices.

## Design laws

- Editor copy/cut/paste actions are configurable. Default Ctrl+C copies instead
  of reaching the framework's implicit quit shortcut; Ctrl+Q remains quit.
- A bounded in-memory clipboard is shared across open documents. Copy without a
  selection leaves its previous value intact. Cut never deletes text before it
  has been retained. Clipboard failures never erase document text.
- System clipboard integration is best effort, uses fixed executables/argument
  arrays (no shell), bounded input/output, and a bounded lifetime. No clipboard
  contents appear in logs. Missing helpers retain useful internal clipboard
  behavior and make the limitation visible.
- Slow external reads must not apply to a different document, revision, cursor,
  selection, or input mode. The UI must remain responsive while helpers run.
- Paste uses the existing editor edit path, including LSP change notification,
  dirty state, and one-step Undo. Terminal bracketed paste remains supported.
- Tests use injected clipboard backends; automated tests must not read or
  overwrite the user's system clipboard.

## Rejected and non-guaranteed surface

No OSC 52 reads/writes, clipboard history, clipboard persistence, selection
clipboard, automatic transfer to remote desktops, or dependency upgrade.
Unsupported platforms use the internal clipboard. No claim of terminal-matrix
coverage follows from headless application tests.

## Implemented boundary

- The macOS bridge uses absolute `pbcopy`/`pbpaste` paths with a UTF-8 locale,
  no shell, discarded stderr, a 16 MiB data limit, and a 250 ms helper timeout.
  The clipboard is session-local; it is not a recovery or persistence store.
- One read and one write may run concurrently. Each direction retains only its
  latest queued request. A new copy is retained before cut changes the document.
  A failed system write pins paste to that internal value until a subsequent
  system write succeeds, avoiding an unrelated old desktop clipboard value.
- Helper timeout and backend shutdown kill and await active helper cleanup.
  A rejected late registration also reaps the child. Dirty-buffer quit refusal
  does not close the clipboard; successful quit and run cleanup do.
- Any intervening key, mouse, or bracketed-paste input invalidates pending
  external paste. Application also checks document/editor identity, revision,
  focus, mode, cursor, and selection snapshot. A selection with no bounded
  snapshot is not an admissible delayed-paste target. Empty clipboard text is
  a no-op, not selection deletion.
- Publication follows the application's existing cooperative-fiber model;
  target validation and initial text mutation contain no explicit yield.
  Parallel UI execution is not certified by these tests.

## Falsifiers and verification

Application-dispatch tests must cover copy/cut/paste and Undo, C0 and modified
key events, modal/tree focus isolation, key remapping, empty selection,
clipboard failure, size/encoding rejection, delayed reads after editor changes,
and retained bracketed paste behavior. Backend tests cover helper failure,
timeout, and output bounds without touching a real desktop clipboard.

DoD: focused specs, full `crystal spec`, formatting check, and application build.
On this host use a temporary `CRYSTAL_CACHE_DIR` and
`--link-flags=-fuse-ld=/usr/bin/ld` for the current SDK/linker incompatibility.
Rollback is the single feature commit; preserve the user's unrelated Makefile
change. No push is included.

## Baseline evidence

`spec/clipboard_terminal_spec.cr` feeds raw terminal bytes through
`Tui::InputParser` and `App#handle_event`. Before the fix its two examples
reported one failure: Ctrl+C called `quit` once (expected zero), while the
Ctrl+Q positive control passed. The editor-level cut/paste probe separately
produced an empty document after both cut and paste; Undo restored its text.

The expanded raw-input baseline also reproduced bracketed paste modifying the
document behind the command palette. Fixed-helper process probes initially
failed three of eight cases: the read path accessed `Process#input`, a raising
getter when stdin is closed. Removing that access made valid output, oversized
output, and invalid UTF-8 distinguishable.

## Verification limitations

Injected backends and fixed non-clipboard executables test application routing
and subprocess behavior. Actual desktop clipboard integration, terminal-matrix
behavior, and parallel UI execution still require separate validation.
An early test accidentally omitted backend injection and may have overwritten
the desktop clipboard with fixture text; it is now injected. No claim of
non-interference applies to that early run. Subsequent test fixtures avoid
desktop clipboard reads and writes.

## Verification record

Verified on 2026-09-17 with Crystal 1.21.0 on macOS, after the clipboard source
and spec changes based on `1a2ac0b`:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-clipboard-cache crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-clipboard-cache crystal build src/adamantine.cr --release -o bin/adamantine --link-flags=-fuse-ld=/usr/bin/ld
bin/adamantine --help
git diff --check
```

Observed: 463 examples, zero failures/errors; formatting, release build, CLI
help, and whitespace checks passed. The 29 new examples cover application,
raw terminal-event, and helper-process boundaries. The existing Ctrl+C remap
test now explicitly confirms replacing the new copy binding.

Adversarial result: ROBUST within default cooperative execution and the tested
boundaries, after helper cleanup and missing-selection-snapshot fixes. No
actual language-server round trip or desktop clipboard integration is certified.
Refresh this evidence after changing key routing, the pinned TUI editor,
clipboard lifecycle/limits, or the concurrency model. Rollback is the atomic
clipboard commit; no dependency change or remote write is part of this slice.
