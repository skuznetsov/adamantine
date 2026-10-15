# Chat-to-named-Lua frontier

Current scope follow-up: [active-file context and selection-scoped proposals](CHAT_SELECTION_FRONTIER.md).
A SelectionProposals child inherits the same frozen fragment as direct Chat
tools; choosing a script cannot widen it to the whole file. The historical
CHAT-LUA-1 certificate below must not be reused as proof of this new boundary.

Status: **VERIFIED — local CHAT-LUA-1 within the boundaries below**, 2026-10-14.
Anchor: `1db63a41cf2add54f1b285226dbe18a8da5b7a79` (locally verified LUA-1).
Current frontier: CHAT-LUA-1, one reviewed named child per selected-buffer turn.

## Goal, authority and rollback

Let a configured Chat model request one user-selected, frozen local Lua script
without gaining the broader local scripting host's authority. Reuse LUA-1's
bounded worker and CHAT-3's manual proposal review; do not add a second command
executor or permit automatic edits. The user approved continuing the roadmap
and delegated heavy implementation/checks to Luna Max; this authorizes local
code, tests, docs and an atomic feature commit, not paid calls or publication.

Risk: **CAUTION** (delegated export, shared quotas and asynchronous lifetimes).
Rollback: the isolated `codex/chat-lua-1` feature commit. Preserve the existing
user Makefile change byte-for-byte; no dependency, lockfile, TUI pin, global
installation, push, PR or merge belongs to this slice.

## Admitted design

- F1 offers a named script selection for the next Chat turn and a clear action.
  The context picker may offer explicit read/proposal-plus-Lua shortcuts. Only
  `BufferTools` and `BufferProposals` can carry that selection. Existing contexts
  keep their default behavior; selection or a project file never starts a worker.
- The Send review binds the frozen catalog entry, its SHA-256, requested and
  effective capabilities, exact selected-buffer revision, provider and turn.
  Show frozen source locally in the scrollable review and disclose that bounded
  script output may be sent to that provider. Identity, scope and execution
  limits must be reviewable before approval, including on compact terminals.
  Cancel preserves the draft; an accepted send resets the one-shot selection.
- Provider requests receive bounded script metadata, not script source or paths,
  an App handle or secrets. The named-run function accepts an exact empty
  argument object; the adapter supplies the frozen approved ID to the typed
  host request. No model-supplied ID, arbitrary arguments, code, paths or
  capabilities are accepted. At most one bound run attempt is available per turn.
- Reserve the outer call's unique ID and shared quota before starting work.
  Retain a one-shot deferred-call ticket with parent session/context lifetime,
  not an expired per-invocation execution permit. Deliver its terminal result
  on the App owner only, for the same live generation, handle, session and call.
  App input/rendering must remain responsive while the provider awaits it.
- Delegate through the parent session: manifest capabilities intersect the
  reviewed parent's selected-buffer read/proposal grants. Strip named-run
  authority from the child. Both direct and delegated calls pass through the
  same Chat-scoped backend, not the broad local Lua host. Reads and proposals
  must name the exact approved opaque buffer ID/revision; no other buffer,
  listing, search, navigation or debugger observation is admitted.
- Shared accounting covers the outer call, every child attempt/refusal and
  response, and the final encoded result including sanitized print output.
  Keep the Chat ceiling of 16 cumulative attempts, 8 KiB/request, 64 KiB/result
  and 512 KiB aggregate responses; delegation cannot reset budgets or call IDs.
  Existing four HTTP rounds and callback/body limits are not widened.
- Reuse LUA-1's optional explicit trusted Lua 5.4 library and isolated worker:
  64 KiB source, 8 MiB tracked Lua allocation, five-second wall budget including
  teardown, 16 KiB/64 output events, bounded protocol queues and one supervisor
  reaper. No second process waiter, busy wait on the App owner or success before
  observed process reap. At most one local-or-Chat Lua worker is active.
- Keep proposals private until both successful child reap and successful
  completion of the entire provider turn. Child failure, malformed protocol,
  exhaustion, timeout or revoked authority fails the pending delegation and
  discards its candidate. A later provider failure/cancel also discards it.
  Direct and child proposals share the existing single proposal attempt.
- Capture the selected owner, view/group, event version, snapshot/revision,
  root/epoch and provider/turn fences even for read-only delegation. Edits plus
  Undo, close/reopen, view/group switches, root/provider retirement and new
  turn/conversation cannot resurrect a grant. Close parent authority before
  requesting child cancellation; retain supervisor cleanup responsibility.
- After success, reuse CHAT-3's colored inline proposal review. No edits or
  source saves happen at tool dispatch. Manual acceptance rechecks its receipt,
  focuses the exact source editor and forms one Undo step; Escape changes no
  document/history. Do not overwrite another open review.

## Meaning bridge and rejected surface

Local Lua `ReadEditor` is broader than Chat selected-buffer export. The relation
is **narrower**, not identity: a delegated `Consumer::Lua` label is provenance,
never authorization. Cap intersection is necessary but insufficient; the
inherited scoped backend must enforce the parent's exact source boundary.
Similarly, local print logging is not equivalent to a provider tool result:
the latter is an export and consumes the parent's cumulative response budget.

Reject raw eval/source/path calls, model-selected manifests, workspace catalogs,
autorun/hooks, recursive delegation, persistent approval, automatic apply/save,
file creation/deletion, navigation, shell/raw App/FFI access, debugger execution
and grants from `None`, `Selection` or `ActiveBuffer`. Retain those standalone
local LUA-1 capabilities unchanged rather than making them available to Chat.

Guard-only future: multiple named scripts/arguments, broader reviewed scopes,
agent-generated scripts and richer automation. These need separate frontiers.
Lua heap tracking is not an OS/RSS sandbox. Local synthetic-provider checks
do not establish live-model support, TLS, retention, cost or model quality.

The current compatible Chat Completions adapter stays in place. Function schema
is guidance, not host authority. The official [function-calling reference](https://developers.openai.com/api/docs/guides/function-calling)
was refreshed on 2026-10-14; this slice does not migrate APIs or claim universal
support for every configured model.

## Implementation and falsifier roster

1. Protocol owner: `editor_tools.cr`, `chat_submission.cr`, `chat_frontend.cr`,
   `chat_provider_transport.cr` and their focused specs. Enumerated consumers:
   Session/Host/delegation, immutable Request copies and review equality,
   provider tool schema/envelope, owner dispatch and termination. First red:
   typed approved named call is missing at the anchor. Guards: default denial,
   exact ID, duplicate/second call, shared child/outer response quota, pending
   Complete/late result, parent closure and metadata-only provider requests.
2. Host owner: new `chat_lua_controller.cr`, App, Chat settings/review, command
   palette, scoped backend and `chat_lua_app_spec.cr`. Initial red: missing
   explicit F1 selection. A later real-App read-only positive control exposed
   a stale receipt during Session construction; it now reads only the reviewed
   buffer revision. Real-worker gates cover Lua read -> model result, then child
   proposal -> parent Complete -> manual acceptance -> one Undo, disk unchanged.
   A later real-worker falsifier reproduced missing refusal-result delivery
   without Undo: discarding a child candidate also cleared the live parent's
   scoped receipt. Candidate disposal must remain distinct from authority
   retirement; a refused child still returns its charged non-OK terminal result,
   while every later proposal stays denied. The fix passes the strengthened
   real-worker App gate and five release PTY scenarios. The final isolated
   aggregate and Root's independent focused verification also pass.
   Guards:
   script/source/provider/draft staleness, edit/Undo ABA, view/group/root changes,
   ungranted list/read/open/debug calls, direct-plus-child proposal count,
   child failure and later parent failure, missing runtime and busy worker.
3. Terminal/adversary owner: `scripts/smoke_chat_lua.rb` and its CI step. Use an
   actual release App, actual Lua 5.4 and a loopback synthetic provider, no LSP,
   real key or paid call. Require positive result delivery, visible explicit
   review, responsiveness/cancel/reap, no preview before both completions,
   manual reject/apply/Undo and unchanged disk/other-file sentinels. Never turn
   an App setup failure into a skipped or successful example.

Workers own disjoint files, coordinate interfaces and preserve others' edits.
Execute distinguishing reds before production edits; record the measured signal.
Same-lineage review is correlated; root inspects the implementation and runs a
separate focused behavioral gate before closure.

## Definition of Done and evidence scope

- Build a fresh production worker/release with
  `crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld`
  into a private temporary path (omit the macOS linker flag on Linux).
- With explicit `ADAMANTINE_LUA_WORKER` and `ADAMANTINE_LUA_LIBRARY`, run the new
  protocol/frontend/provider/App falsifiers, then `crystal spec` with the same
  macOS linker flag. Expected: zero failures/errors/pending; tests require the
  real runtime rather than silently skipping it.
- Run new Chat-Lua, existing local-Lua, Chat-proposal and template/split PTYs
  against that fresh binary. Expected: observable real child execution and the
  selected-buffer/manual-only/one-Undo/no-save boundaries above.
- Run formatter checks, Ruby syntax, `shards check` and `git diff --check`.
  Run dependency preflight in an isolated copy with the committed Makefile:
  the user's uncommitted installation command is neither reverted nor certified.
- Hostile review must find no unresolved blocker within this declared boundary.
  Remote Linux/macOS CI is configured only, unless actual remote runs occur.

Evidence expires on changes to script grants/source capture, shared accounting,
deferred dispatch/cancel/reap, Chat source/turn/provider receipts, preview apply,
provider adapter, worker ABI, TUI pin or test fixtures. Refresh affected gates.
Sync this frontier, README/architecture and the editor roadmap at closure;
preserve the historical LUA-1 and CHAT-3 certificates as scoped predecessors.

## Observed evidence

All gates below consumed the frozen final production/input seals recorded in
[the evidence packet](../.landmark/evidence/chat-lua-1.json). Luna Max performed
the heavy implementation, release and aggregate/PTY checks. Root inspected the
authority/lifetime paths and independently ran the focused 77 and static checks.
Same-lineage review is correlated, not independent model agreement.

- Fresh production release and actual Lua 5.4.9 worker/library: PASS on macOS,
  Crystal 1.21.0/LLVM 22.1.8, with the system-linker override. No global install.
- Final `crystal spec --error-trace --link-flags=-fuse-ld=/usr/bin/ld`: **1681
  examples, 0 failures, 0 errors, 0 pending**, exit 0, 2:17. Configuration was
  explicitly isolated and the real worker/library were supplied.
- Root's separate Chat-Lua/local-Lua App, edit/provider adversary and shared-tool
  gate: **77 examples, 0 failures, 0 errors, 0 pending**, exit 0, 4.5 seconds.
- Five Chat-Lua release PTY scenarios: PASS, including actual read/output
  delivery, child/parent completion gates, caught refusal, parent failure,
  late Complete after cancellation, active-worker responsiveness/reap and
  manual acceptance/one Undo/no save. Existing local-Lua, Chat-proposal,
  provider-adversary and template/split PTYs also pass on that same release.
- Formatter, both Lua smoke syntax checks, dependency check, ordinary CLI help
  without Lua environment, workflow YAML parse and diff checks: PASS. Isolated
  committed-Makefile dependency preflight: 6 runs, 77 assertions, no failures,
  errors or skips. The user's dirty Makefile remains byte-identical/excluded.
- Scoped adversary verdict: **ROBUST**, with no unresolved source blocker in
  the declared boundary. Four existing debugger deprecation warnings remain.

The Linux/macOS CI matrix now includes the Chat-Lua PTY gate, but no remote CI
or local Linux run occurred. This is not live-provider, OS/RSS-isolation or
arbitrary native-thread-race evidence. The packet retains exact seals, commands,
executor distinctions, measured refutations and refresh conditions.
