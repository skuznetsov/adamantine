# LSP response limits

Status: admitted within the framed-response boundary below.

## Boundary

The limit governs an inbound JSON-RPC body, not source-file bytes. Default:
16 MiB; configurable within 1–64 MiB through persisted settings. Existing
keymap configuration must survive settings saves and vice versa.

Oversized framed messages must not be allocated or parsed in full. Drain a
bounded body with fixed-size storage and a deadline, warn with the observed
size, limit, and settings location, and keep the stream usable for later
requests. Pending requests may fail conservatively because an unparsed body
does not reveal its request id. Malformed, truncated, excessively large, or
stalled frames may disconnect, with a visible warning. Never resume parsing
inside a partially discarded frame. Unlimited frames and automatic retry
storms are rejected. Full JSON parsing still has memory amplification below
the configured limit; this is not a process-wide memory quota.

## Verification plan

- Transport: framed boundary tests, oversized followed by small response,
  truncated/stalled discard, callback visibility and pending-request release.
- Settings: validation, persistence without deleting unrelated keys, settings
  UI routing, and application to the active client.
- Run `CRYSTAL_CACHE_DIR=<writable-cache> make check`.
- Against local Adamas LSP, request tokens for `ast_to_hir.cr`, then a small
  document. Repeat with a deliberately lower cap and verify warning plus
  a usable connection for the small document.

Risk: protocol/concurrency (CAUTION). Rollback: revert this coherent local
change; no source documents or user settings are changed by verification.

## Implementation evidence (2026-09-07)

- `src/adamantine/lsp_client.cr` and `spec/lsp_response_limit_spec.cr` cover
  configurable acceptance, exact-limit/+1 boundaries, fixed 32 KiB discard
  storage, pending-request failure, callback isolation, hard-cap rejection,
  truncated headers and a stalled pipe with an injected short deadline.
  Production discard deadline is 5 seconds; absolute discard cap is 256 MiB.
- `src/adamantine/settings_config.cr`, settings UI, and
  `spec/lsp_response_settings_spec.cr` cover validation, live application,
  stale warning suppression, and preservation of unrelated configuration.
- Parent ran `CRYSTAL_CACHE_DIR=/private/tmp/adamantine-lsp-parent-cache make check`
  successfully (format, executable build, full specification suite).
- Isolated local Adamas LSP probe against `src/compiler/hir/ast_to_hir.cr`
  produced a 4,298,028-byte response. At 16 MiB, 1,926,205 token integers were
  decoded and a nonempty semantic overlay built. At 4 MiB, the response was
  skipped with one warning. A following `puts 1` document produced 10 token
  integers with the connection still active in both cases. No disk document
  was written by the probe. Probe script was session-local, not a CI fixture.

Review verdict: ROBUST for tested framed responses and settings persistence;
same-lineage worker review was supplemented by parent source inspection and
direct execution. Refresh this evidence after transport, configuration, or
server changes. This is not a terminal screenshot or a memory-use benchmark.

## Residual limits

- Oversized bodies are unparsed: all requests pending at discard completion
  fail conservatively, including unrelated requests; later requests work.
- Newline-delimited compatibility input retains its separate 4 MiB line cap;
  safe discard/recovery is guaranteed only for Content-Length frames.
- Stalled/truncated/malformed input can disconnect; automatic reconnection is
  not implemented by this slice. The discard deadline bounds body reads from
  the production subprocess pipe, not all protocol stages or generic IO.
- Configuration saves are atomic replacements using private temporary files,
  not multi-process merge transactions or power-loss durability guarantees.
