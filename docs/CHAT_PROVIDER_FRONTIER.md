# Bounded chat provider frontier

Current disclosure follow-up: [active-file context and selection-scoped proposals](CHAT_SELECTION_FRONTIER.md).
Explicit file contexts now carry reviewed project-relative paths and normalized
selection coordinates; `None` still exports neither. The historical certificates
below do not establish this new capability boundary or a new paid-model result.

## Live Luna demo follow-up (2026-10-14)

Status: **VERIFIED for the local provider extension and one accepted live
mini-project turn**, anchored to `250031d8b7555853aa43f20f8799e64eac626d91`.
The user explicitly requested a real GPT Luna Chat/Lua mini-project trial.
One authenticated model-availability check returned HTTP 200 for `gpt-6-luna`;
one synthetic Chat Completions tool probe without an explicit reasoning effort
returned HTTP 400 with `error.param = reasoning_effort`.

Design-sealed extension: optional, explicitly configured `reasoning_effort`,
validated against the documented enum, persisted without credentials, shown
in Chat settings and Send review, and sent unchanged on every HTTP round.
Omission preserves the previous wire behavior; never infer a value or substitute
a model. Reject malformed persisted values before network access.
Risk: CAUTION (provider wire/config contract). Rollback: one local commit or
disable Chat; the user-owned Makefile remains outside the change.
DoD: red-to-green config/wire/UI tests, focused Chat/Lua regressions, fresh
release, and a real model turn using the reviewed read-only Lua inspector,
model-generated proposal, manual acceptance/save, and mini-project tests.
Guards: omitted settings stay omitted; invalid effort never sends; settings
round-trip and review agree; source/test sentinels stay unchanged before accept.
Hostile-review follow-up guards: serializing an invalid effort must not yield
a valid enabled configuration; settings edit/paste/save require geometry that
discloses all six fields. Too-small settings retain their draft, allow Escape,
and request a resize instead of silently editing hidden fields.

Live trial bound: the initial two-turn allowance is consumed. The user's
subsequent explicit allowance is **$3 for GPT-6 Luna today** (2026-10-14).
Limit this operation to at most four reviewed model turns in total, four
requests per turn and 2048 output tokens per request, plus the single failed
compatibility probe. Review each Send separately; do not turn a cost allowance
into automatic retries. Reserve earlier requests as well as later attempts;
the allowance is not a provider-side account spending limit or a measured bill.
Only synthetic mini-project context is admitted. Reuse the inherited API-key
environment variable in the authorization header; never print or store its
value. No automatic retry/fallback, workspace export, shell tool, generated Lua,
API migration, publication or global installation is admitted. A successful
trial certifies only the observed model/endpoint/source state, not model quality
in general, retention, total billing or universal compatible-provider support.

Observed outcome: the first two live turns were not accepted or saved. The
first terminal tracker stopped on a known UI navigation glyph; the next
settled proposal was malformed and was manually rejected. A separate
synthetic, loopback-only known-correct edit rendered accurately and passed
the 10 examples after a private save. That falsifies downstream rendering
corruption for that payload, not every proposal; the original live edit
arguments were not captured, so their producer cause remains unproven.

The third real turn used inspector-provided exact full-line half-open spans
and proposed the correct one-line repair. Root reviewed the complete frozen
Lua source and prompt in the fresh production Send modal, then separately
accepted the settled inline diff and saved only the private project through
Ctrl+S. Its unchanged 10 specs and Root's independent 704-case index oracle
passed. The original starter/spec and user Makefile remain unchanged. Further
paid calls stopped after this success; no fourth turn or automatic retry.
The $2.10 reservation for three turns plus the compatibility probe is an
assumption-based estimate, not observed provider usage or billing.

Inspector guards bind host results to the selected ID/revision and requested
range, suppress unsafe/incomplete spans and use host Unicode columns rather
than Lua byte lengths. One aggregate report fits the event budget; oversized
output fails without partial presentation. Lua remains read-only and contains
no repair. Final checks: 1687 editor specs, Root's independent 111 focused
specs, 18 harness tests/56 assertions, 8 real-worker inspector tests/485
assertions, fresh release and three existing Lua/proposal PTY regressions.
Scoped hostile review: ROBUST. This is a real production App/HTTP/Lua PTY
trial, not native-window automation, remote CI or a general model-quality
certificate. Exact seals, commands, retained private artifacts and decay
conditions are in [the live-demo packet](../.landmark/evidence/luna-live-demo.json).

The subsequent [CHAT-3 frontier](CHAT_EDIT_FRONTIER.md) separately admits
explicit selected-buffer proposal scope and manual inline acceptance. It does
not promote CHAT-2's read-only grant to edit authority or change its evidence.

Status: **VERIFIED — local CHAT-2 within the boundaries below** (2026-10-10
local; final aggregate check 2026-10-11 UTC).
Source: the atomic feature commit carrying this document, based on clean
`08cf3a324d3c5083a26a8df5b6612d7de0eebe2b`, the local
[CHAT-1 UI](CHAT_UI_FRONTIER.md). This slice implements a user-configured
provider, not a claim that a live paid model has been tested or that the
separate pinned-library aggregate audit is green.

## Intent and authority

Connect the existing bottom Chat workspace to an explicitly configured model.
Keep the provider, destination, outgoing conversation and selected context
visible. Reading a file locally does not authorize sending it to a provider.
The user's approval admits local implementation and local fake-HTTP tests;
it does not authorize paid model calls during development, key-store access,
remote publication, a dependency change or a Lua runtime.

Risk: **CAUTION**, because network export, cancellation and tool results cross
authority/lifetime boundaries. Rollback is one atomic local feature commit;
disabling Chat in its settings restores the unavailable transport without
changing documents. Drafts survive failed configuration, rejected review and
transport replacement. Existing unrelated changes must remain untouched.

## Admitted behavior

- A discoverable Chat settings UI and an update-only `chat` JSON section store
  enablement, exact completion endpoint, exact model, API-key **environment
  variable name**, and a per-round output-token limit (default 4096, hard
  range 1..32768). The review also shows the four-request turn ceiling; the
  per-round limit is not represented as a total-turn cost bound.
  The application never inserts the resolved credential into settings,
  transcript, logs or error messages; it is used only for the authorization
  header. Provider output is untrusted and is not a secret-scrubbing service:
  an endpoint already receiving the key may echo it as ordinary model text.
  Defaults are disabled and
  have no model; no model is guessed from a name or silently substituted.
- The first wire protocol is **OpenAI-compatible Chat Completions**. It is
  deliberately selected for configurable compatible/local endpoints, not
  described as OpenAI's preferred new-app API. Use streaming text and bounded
  function calls, `max_completion_tokens`, `n: 1`, `store: false`; no automatic
  retries, model discovery, background requests or hosted tools.
- Destinations require HTTPS, except literal loopback HTTP (`127.0.0.1` or
  `[::1]`). Reject userinfo, query/fragment, control characters and ambiguous
  endpoints. Do not follow redirects or use implicit proxy configuration.
  A blank key reference is allowed only for literal-loopback endpoints.
- Every production Send first reviews the destination/model, outgoing prompt
  and history byte count, context identity/bytes and permitted tool scope.
  Cancel is the default. Approval applies to that exact captured submission,
  not a later edited draft, changed root, replaced provider or newer buffer.
- Context is one-shot and defaults to **None**. Explicit choices are selection,
  active buffer, and selected-buffer read tools. Selection/buffer snapshots
  come from the unsaved owner-side document, not a disk read, with a hard
  16 KiB text cap; oversize input is rejected without silent truncation.
  No attachment is captured or uploaded at startup or context-menu selection.
- Selected-buffer tools advertise only `editor_read_buffer`, mapped to
  `editor.read_buffer`. The owner checks the exact approved buffer ID and
  revision before invoking the existing bounded host session. No file listing,
  other buffer, navigation, debugger, evaluation, command, edit or save is
  granted. Direct-context and None modes open no production tool session.
  The review explicitly discloses that later tool rounds may upload bounded
  portions of that selected buffer; zero initial snapshot bytes do not mean
  zero permitted source export.
- Conversation text is explicitly included in the Send review, bounded to
  64 KiB / 16 previous messages; excessive history requires New conversation
  rather than silently removing context. Attachments/tool results are not
  implicitly replayed on later turns. Visible assistant text may quote earlier
  context, so None is not advertised as purging previous conversation content.
  Provider/root replacement retires active work and clears exportable history
  while preserving the user's draft.

## Lifetime, protocol and resource laws

The provider receives immutable request data and emits existing typed Chat
events. It has no App/document/session authority. Tool dispatch stays on the
App owner; network workers never read editor buffers. Existing generation,
root-identity, modal-focus and session-budget fences remain mandatory.

One transport permits at most one live worker, including cancellation cleanup.
Cancellation closes the active HTTP client and wakes any tool-result wait.
Late callbacks, late approvals and duplicate/unmatched tool results cannot
revive a turn. No cancelled round starts a subsequent HTTP request.

Hard provider ceilings: 4 HTTP rounds per approved turn, 120 seconds total,
5-second connect / 15-second idle read / 10-second write timeout, 256 KiB per
outgoing body, 64 KiB per SSE event and 1 MiB total incoming stream per turn.
At most 4 tool calls per round, 8 KiB arguments per call, 64 KiB each encoded
tool result and 512 KiB aggregate owner-session output. The existing host
additionally caps source text at 8 KiB per buffer read. Protocol names, IDs,
indexes and fragmented arguments are untrusted;
duplicate IDs, invalid JSON/UTF-8, missing finish markers, unknown functions,
oversize frames and unexpected choices fail closed with a static actionable
error. The owner counts every tool attempt, including denied/malformed
requests, against a 16-attempt turn ceiling. Errors do not reflect provider
bodies, exception text, headers or keys. Credential values are bounded to
8 KiB and must be safe as an HTTP header; they are resolved only on Send.
These are application/request bounds, not a claim about total process RSS,
provider-side billing or provider-side retention. `store: false` is not ZDR.

## Rejected and guard-only surfaces

Rejected in CHAT-2: real paid validation calls, OAuth/Codex subscription reuse,
plaintext key storage, provider/model inference, silent retry/fallback,
automatic workspace capture, workspace-wide tools, debugger control, shell,
arbitrary DAP/evaluation, navigation, proposed edits, persistence of chat or
context, Lua execution and arbitrary native-thread consumers. Broader tools
and Responses/Anthropic/Gemini protocols need their own compatible boundaries.

Existing unavailable/local injected transports remain control surfaces, not
evidence of real-model compatibility. TLS/public-provider behavior and model
quality remain guard-only until separately authorized live validation.

## Implementation ownership and checks

1. Provider module: immutable validated settings; bounded SSE/HTTP worker;
   loopback stub tests for text, function rounds, errors and cancellation.
2. Owner/UI integration: immutable disclosure/context/history contract,
   settings/menu/review, request/session policy and visible controls; tests
   proving no export before approval and no stale approval.
3. Adversary: forged tools, credential/error reflection, redirect, malformed
   streams, budgets and cancellation races; actual production App/PTY against
   local HTTP only. Delegated review is correlated and root checks the result.

Executed falsifier roster:

| Obligation | Rejecting observation |
| --- | --- |
| Explicit export | Startup, context choice or cancelled review makes HTTP traffic |
| Exact approval | Changed draft/root/provider/document can use an old approval |
| Context boundary | None sends hidden file/debug data; another buffer tool executes |
| Secret boundary | Application credential handling or reflected error bodies put a key in transcript/config/log |
| Protocol integrity | Malformed/oversize stream or unknown tool executes or reports success |
| Bounded turn | Infinite stream/tool rounds, cancel/restart accumulates workers or requests |
| Conversation boundary | Old root/provider context is replayed after replacement |
| UX isolation | Settings/review/paste changes the source editor behind the modal |

CHAT-2 DoD: focused red-to-green provider/context/modal tests; `make spec`
(editor suite), `make release`, formatting/diff checks,
`ruby scripts/test_build_dependencies.rb`, existing Chat/debugger controls and
a production App/PTY with local fake HTTP. Expected signal: all green, zero
unapproved HTTP traffic, exact expected requests/bytes/tools, intact drafts
and source buffers. Root performs scoped adversarial review before commit.
Do not promote a passing local stub to a verified live-provider claim.

## Verification evidence

The root reran the following checks on the final production source, using
private build caches and literal-loopback synthetic HTTP only. The final
same-file fixture correction changes test configuration, not production
source; the release and PTY certificates remain tied to that same production
source. No actual keys, key stores or paid model services were used.

Toolchain: Crystal 1.21.0, LLVM 22.1.8, target
`aarch64-apple-darwin25.6.0`. Shard lock and installed `.shards.info` metadata
retain TUI `7ca26fd559cf8c05e5b4ed924e7c691fabb66e43`; `shards check` passed.
This is metadata/dependency-satisfaction evidence, not a new byte-for-byte
comparison with a remote archive. `Makefile`, shard files and the sample
keymap are unchanged. Direct Crystal commands below use
`--link-flags=-fuse-ld=/usr/bin/ld`; the Makefile supplies it on macOS.

| Check | Observed signal |
| --- | --- |
| `crystal spec spec/chat_provider_config_spec.cr spec/chat_provider_transport_spec.cr` | 21 examples, zero failures/errors |
| `crystal spec spec/chat_provider_adversary_spec.cr` | 9 examples, zero failures/errors |
| `crystal spec spec/same_file_views_integration_spec.cr` with synthetic ambient indent 3 / auto-indent false | 17 examples, zero failures/errors; the synthetic config remained unchanged |
| `make spec` with an explicit nonexistent private config override | 1,569 examples, zero failures/errors/pending; 2:05 runtime |
| `make release` | Optimized production binary built successfully |
| `make fmt-check`, `git diff --check` | Clean |
| `ruby scripts/test_build_dependencies.rb` | 6 runs, 77 assertions, zero failures/errors/skips |
| `ruby scripts/smoke_chat_provider_adversary.rb bin/adamantine` | Production provider approval/privacy/tool workflow passed |
| `ruby scripts/smoke_chat_panel.rb --editor-bin bin/adamantine` | Production Chat/Log focus, draft, resize and quit workflow passed |
| `ruby scripts/smoke_debugger_session.rb --fake-adapter --editor-bin bin/adamantine --dock left` | Fake DAP workflow passed |
| Same fake-DAP command with `--dock bottom` | Fake DAP workflow passed |
| `ruby scripts/smoke_chat_panel.rb --fixture-bin /path/to/chat-smoke-app` | Separately built injected-transport fixture passed |

The provider PTY observed zero HTTP requests during startup, settings,
context selection and cancelled approval. Approved ActiveBuffer, one-shot
None and selected-buffer tools produced exactly four POSTs altogether.
Initial tool disclosure was visible before approval; only the approved
buffer ID/revision was read. An unopened-file sentinel did not reach the
provider, the synthetic credential appeared only in the authorization
header, and source/disk hashes were unchanged. Unit adversaries additionally
reject stale draft/root/provider/document approvals, ordinary edit/undo ABA,
other-buffer tools, malformed streams, oversized data and excess rounds.
Blocked/trickling peers and a peer held open after `[DONE]` exercise deadline,
cancellation and worker-release boundaries rather than treating EOF as the
only completion signal.

Closure found and repaired failed-start draft/history publication, user-turn
ordering after transcript eviction, history retirement across root changes,
and hidden Log auto-scroll geometry. Their regression tests are part of the
aggregate gate. The same-file views test had also inherited ambient editor
config and could save to its default path. Its helper now defaults reads and
writes to the temporary project config while preserving explicit paths and
all other constructor arguments. Two isolated focused runs and the root's
synthetic-ambient full-file run passed. The exact prior ambient config source
was not inspected or established, so no claim about actual user-config
mutation or restoration is made. Theme discovery is a separate ambient seam.

Adversary verdict: **ROBUST for this local export/lifetime/UX frontier**.
Delegated implementation and review are correlated; the root's executed
protocol, aggregate and production-PTY checks supply the closure evidence.
This does not certify public-provider TLS/API compatibility, model quality,
cost/retention, native-thread safety, Lua or mutation tools. The existing
bare single-byte Escape limitation remains; F3/F1 are documented fallbacks.

### Separate pinned-foundation audit (2026-10-11)

The initially proposed extra all-green foundation gate is **not achieved**.
`crystal spec lib/crystal_tui/spec` reports 695 examples with four TextEditor
mouse failures. The exact mouse spec alone passes all six examples; running
`tui/events/mouse_event_spec.cr` followed by
`tui/widgets/text_editor_mouse_spec.cr` reproduces the four failures in 37
examples. This is a measured test-order defect in the unchanged dependency,
not an assertion that the aggregate gate passed.

The final vertical-split test presses and drags without releasing capture
(`mouse_event_spec.cr:292-305`); its group resets capture only in `before_each`
(`:198-202`). `SplitContainer` captures on press and releases on release
(`src/tui/containers/split_container.cr:503-529`). The leaked global capture
redirects subsequent editor mouse events before their handler runs
(`src/tui/widget.cr:372-382`). The library helper imports only `spec` and
`../src/tui`, not Adamantine or CHAT-2 modules. The narrow passing mouse check
and the editor gates therefore support a local CHAT-2 certificate, not an
all-green certificate for the entire pinned library. No dependency patch,
test skip, altered foundation assertion or pin update is included here.

## Primary references

Checked 2026-10-10: [Chat Completions create](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create),
[function calling](https://developers.openai.com/api/docs/guides/function-calling),
and [streaming](https://developers.openai.com/api/docs/guides/streaming-responses).
The official API recommends Responses for new OpenAI-specific applications;
this slice chooses an explicit compatible Chat Completions protocol for the
editor's configurable provider seam. Crystal Ball's LLM sources inform the
message/function shapes only: model-prefix routing, OAuth/key loading,
unbounded/silent SSE parsing and exception-body reporting are not reused.

Evidence is tied to the final source revision, pinned TUI and observed Crystal
toolchain. A provider/API, root/session, config or parser change reopens the
dependent checks. Live validation, if later approved, must state model,
endpoint, cost/count bound and credential handling separately.
