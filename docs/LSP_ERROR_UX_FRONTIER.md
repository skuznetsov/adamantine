# Actionable LSP failure UX frontier

Status: locally verified at the App/UI-event boundary (2026-09-22); direct
PTY smoke remains inconclusive. Base: `160b2db`.
Risk: CAUTION (asynchronous failure state and user-visible recovery actions).
Rollback: revert this isolated feature commit. No persistent format or keymap
change is admitted.

## Admitted behavior

- The existing compact header health label remains stable. `:lsp`, the footer
  LSP status action, and F1 discovery explain disabled, connecting, retrying,
  failed, and connected states without requiring the user to know a colon
  command.
- F1 exposes a distinct **Restart LSP** action when a launch command is
  configured. A failed status points to that action and `:lsp restart`.
- Retain the latest failure reason from startup or transport/recovery in
  bounded, single-line in-memory state. Reset it on successful connection,
  reconfiguration, and a new manual restart. A stale client/epoch must not
  replace the current explanation.
- Never turn a failed server into automatic unbounded retries. Disabled still
  means no launch command; explicit restart must not discover a new server.

## Rejected and guard-only behavior

No server installer, project-local executable discovery during recovery,
automatic config edits, new default keybinding, or raw exception dump in the
header. Error text is untrusted: normalize control characters and cap display
length. A generic explanation is acceptable where the client cannot identify
the underlying server failure; do not claim a precise cause without evidence.

## Falsifiers and DoD

Focused tests must reject a hidden F1 restart action, a failed status with no
next step, disabled restart presented as available, unbounded/multiline failure
text, stale reason after success or reconfiguration, and recovery callbacks
from an old epoch overriding the new one. Pause teardown of the final failed
client, start a newer manual restart, and reject any stale terminal-failure
state or log publication from the prior epoch. Existing lifecycle and resync
tests must stay green. Then run the full Crystal spec suite, formatter, diff
check, release build, and a small real-terminal interaction check if feasible.

## Observed verification and boundary

- Focused UX/start/recovery suite: **12 examples, 0 failures/errors/pending**.
  It exercises F1 open, search for `Restart LSP`, selection and Enter execution;
  it also covers disabled/retrying/failed states, stale reason reset, million-
  character reason fail-closed behavior, and command/argument token redaction.
- Full suite: `crystal spec --link-flags=-fuse-ld=/usr/bin/ld` — **1040 examples,
  0 failures/errors/pending**.
- `crystal tool format --check src spec` and `git diff --check` passed.
- Release build with `crystal build --release -s -p -t src/adamantine.cr` and
  host linker override passed (exit 0).
- Deterministic coordinator races pause teardown before terminal publication
  and pause wakeup after the failed-state commit. A newer manual epoch must
  retain `retrying 1/3` and suppress stale failed-state/log publication.
- A bounded `expect` PTY smoke used a temporary project and missing `--lsp`
  executable, then attempted F1 search. It did not observe the rendered
  `LSP failed` or `Restart LSP` text, and the quit input was not acknowledged
  before timeout. Treat terminal rendering/input integration as **inconclusive**;
  the App-level event-route spec is the strongest positive evidence and does
  not prove terminal-emulator interaction.

Residual: a server that exits without a useful message may still yield a
generic explanation. This slice does not diagnose language-server-specific
configuration or install one for the user. Terminal-level F1 rendering/input
remains unverified by the PTY smoke.
