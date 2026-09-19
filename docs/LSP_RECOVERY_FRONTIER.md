# LSP recovery frontier

Status: implemented and locally verified on 2026-09-19. Base: `718de65`.
Risk: CAUTION (process ownership, asynchronous resynchronization and stale UI).
Rollback: revert the isolated feature commit; no persistent format changes.

## Admitted design

- Visible disabled/connecting/connected/retrying/failed/stopped health and
  `:lsp restart`; manual and automatic recovery run off the command path.
- Keep the configured executable/arguments; never discover or execute a new
  project-local server during recovery.
- One coordinator owns fresh client creation, old-client stop/reap, epoch/root
  guards and open-document synchronization. Never reuse a failed client.
- At most three automatic retries per explicit connection/restart/root change,
  with backoff. Successful initialization alone never replenishes the budget.
- Resync current buffer identities, versions and unsaved text; never reopen
  files, replace editor objects or modify Undo. Guard changes/open/close while
  initialization or transport writes yield.
- Immediately invalidate old diagnostics, semantic tokens, folds and actions.
  Independent lexical highlighting remains available.
- Root changes cancel old attempts and reconnect the configured server against
  the new root. Quit and run-loop cleanup cancel work and stop owned clients.

## Rejected and residual surface

No formatting/workspace edits, server installer, unbounded restart loops, retry
settings, persistent recovery state or new dependencies. Initial startup and
existing transport write/stop timeout limitations remain explicit. A worker
fiber does not by itself guarantee bounded pipe-write latency.

Wire-order anchor: the official LSP 3.17
[didOpen contract](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/textDocument/didOpen.md)
requires balanced opens/closes, and
[didChange](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/textDocument/didChange.md)
requires an open document before changes and synchronized state before requests.
Recovery tests must assert these events, not infer them from `connected?`.

## Execution and falsifiers

1. Client failure notification and real-process tests in `lsp_client.cr` and
   `spec/lsp_recovery_transport_spec.cr`: unexpected EOF callback once, explicit
   stop silent, old process reaped before replacement, initialization failure.
2. Coordinator/controller and UI tests in a new recovery module and specs;
   integrate `lsp_controller.cr`, `app.cr`, `command_palette.cr` and header.
   Test manual restart, hard crash-loop budget, stale callbacks, two-buffer
   resync, edit/open/close during initialization/resync, root and quit cancellation.
3. Parent counterexamples, full suite, formatter, release build and PTY smoke.

DoD: focused tests and full `crystal spec` have zero failures, formatter and
`git diff --check` pass, release build succeeds. On this macOS host use
`CRYSTAL_CACHE_DIR=/private/tmp/adamantine-recovery-cache` and
`--link-flags=-fuse-ld=/usr/bin/ld`. Tests must include actual subprocess cleanup
and current-buffer content assertions, not just health-label transitions.

The user's Makefile change remains out of scope. No push is authorized.

## Observed verification and limits

The feature adds 17 recovery examples. The focused recovery suite and full
suite passed with zero failures or errors (17 and 775 examples respectively).
Commands run on the final implementation with Crystal 1.21.0 on macOS:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-recovery-cache crystal spec spec/lsp_recovery_spec.cr spec/lsp_recovery_adversary_spec.cr spec/lsp_recovery_process_spec.cr spec/lsp_recovery_transport_spec.cr spec/lsp_recovery_ui_spec.cr --link-flags=-fuse-ld=/usr/bin/ld
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-recovery-cache crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
ruby -c spec/fixtures/recovery_probe_server.rb
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-recovery-release-cache crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-recovery-editor
```

Release `--help` and a PTY smoke passed. The smoke opened a file using the
command palette, ran `:lsp restart`, observed a second peer's `didOpen`, checked
the rendered connected header, quit, and checked both peers were gone and the
file's SHA-256 was unchanged. This used the committed Ruby stdio peer, not a
production language server. Automated process tests additionally assert two
unsaved buffers' exact text/version, preserved identity and Undo, new root URI,
hard crash-loop limits, and no new process after quit.

Parent counterexamples initially rejected dropped fresh diagnostics during
`didOpen`, old-root initialization, a missing manual retry slot, and a worker
that died permanently after a factory exception. Their regression tests now
pass. A held-teardown oracle also checks that quit waits for an already-running
stop. Metadata-only reconciliation avoids retaining a second full text string
for every document throughout recovery. It is not an allocation benchmark.

Adversary verdict: ROBUST within these tested lifecycle and wire-order cases.
The implementation does not promise arbitrary server compatibility or bounded
UI latency for blocked transport writes. Initial startup is synchronous;
shutdown can wait for the existing initialization/stop timeouts. Initial
startup failure remains terminal until explicit restart; automatic recovery
is triggered by unexpected failure of an established transport. Revalidate
these claims if client lifecycle, buffer membership/versioning, scheduler,
transport, or TUI input behavior changes.
