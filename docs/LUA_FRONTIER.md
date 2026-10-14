# Lua scripting frontier

Document status: **locally verified within LUA-1**, 2026-10-14. The design was
sealed on 2026-10-13. Current slice: manually launched local named scripts;
Chat-to-Lua remains deferred. Base anchor:
`fff4d7389ee945686f9368fad7443fd28050c9d7`; the feature commit carrying this
document contains the implementation and matching tests. Linux/remote CI is
configured but has not been executed for this slice.

## Purpose and admitted design

Make small editor macros useful without adding a second command executor or
giving a script the App object. The user approved LUA-1 after the shared
[tool contract](ASSISTANT_TOOLS_FRONTIER.md) and reviewed
[Chat proposals](CHAT_EDIT_FRONTIER.md). Chat calling Lua is a later slice.

- F1 discovers Run Lua script and Cancel Lua script. A bounded picker lists
  built-ins and explicitly configured user scripts. Selection opens a review
  showing the name, frozen source digest, requested capabilities and limits.
  Enter approves that one run; Escape leaves editor state unchanged. There
  is no persistent always-allow grant. Enter stays disabled if the full
  digest, permissions or limits cannot be displayed in the current viewport.
- User scripts live under the user's Adamantine configuration directory;
  there is no project catalog, startup execution, arbitrary path command or
  eval API. A bounded versioned manifest contains metadata and requested
  capabilities, not authority. Source is bounded UTF-8 text, captured before
  approval and never reopened by the interpreter. Reject escaped paths,
  symlinked source files and invalid/oversized manifests or scripts.
- Each run has one fresh process and Lua state, opaque run identity, canonical
  project/epoch and an App-owned `Consumer::Lua` tool session. The child knows
  neither the App/backend nor grants it can modify. Requests pass through
  existing exact argument validation, capabilities, quotas and permits.
- Only the App owner drains and dispatches requests. Child/pipe fibers may
  enqueue bounded events and wake the App, not invoke the backend. Keep at
  most one outstanding RPC event and reject late replies/events. A terminal
  owner wake retries a full input queue without blocking the App; stop only
  after delivery or run retirement, not merely because the child was reaped.
- The Lua API is `editor.call(name, arguments)` returning the ordinary typed
  tool result, a bounded run-start selected-buffer context, and bounded print
  output in Log. It includes only base computation and math/string/table/utf8
  helpers, with no file, process, network or native-module API.
- Optional Lua **5.4** is dynamically resolved only in the isolated worker;
  LuaJIT/5.1 and Lua 5.5 are not compatible runtimes for this slice. The editor
  still builds/starts without Lua. Missing runtime has an actionable diagnostic.
  An explicit absolute library override is trusted installation configuration,
  never script/model input; loading arbitrary native libraries is not sandboxed.

## Resource and authority laws

Risk: **CAUTION** (execution, concurrency, resource and proposal boundaries).
Rollback: revert the single LUA-1 local feature commit. No Makefile, shard,
ignored dependency, global installation, remote publication or paid call.

Hard runtime ceilings: 64 KiB source; 8 MiB **Lua-managed heap**, including
bootstrap; 5 seconds monotonic wall time including startup, pending RPC and
cleanup; 16 KiB/64 events of script output. Tests may tighten, not widen these
limits. Existing EditorTools ceilings remain unchanged: 8 KiB request, 64
attempts, 64 KiB result, 512 KiB cumulative results. Worker wire frames,
startup envelope, stderr, JSON depth and queues have independent finite bounds.
Exceeding a budget is terminal even if the script catches a Lua error.

The parent deadline/cancel terminates and reaps the owned child independently
of Lua hooks, `pcall`, native string/pattern work or finalizers. Publish success
only after successful script execution **and** child exit/reap with drained
bounded pipes. A success-shaped frame preceding a hanging finalizer is not
successful completion. Output is control-character sanitized before rendering.
Syntax/runtime diagnostics are independently limited to 512 UTF-8 bytes and
contain no terminal controls. Cancellation is idempotent; a later completion
cannot revive a run. Duplicate terminal frames, terminal frames with pending
RPC, and output/tools after a terminal frame are protocol failures.

One supervisor owns `Process#wait`; shutdown never adds a competing reaper.
The App revokes the session first and requests an immediate hard kill.
`cancel_and_wait` waits at most one second and reports whether reaping was
observed; a timeout is reported as cleanup pending, not confirmed completion.
The supervisor retains child ownership until reap. This is a bounded shutdown
contract, not an OS-wide guarantee that any native process can be reaped within
one second. Supported-case tests must observe actual child exit/reap.

Use Lua's custom allocator with a noncapturing, nonraising callback and
unmanaged byte accounting. For a null old pointer, `osize` is a type tag, not
allocated bytes. Failed realloc leaves accounting unchanged. No callback may
raise a Lua error across Crystal frames. Script execution is protected by
`lua_resume`; an unprotected host-side Lua allocation failure may abort the
isolated child and must produce a bounded failure, never a preview or App crash.
Do not describe this as a process-RSS cap or an OS security sandbox. It assumes
a trusted compatible native Lua library; interpreter/native exploits are not
contained by removing globals.

Load user chunks in text-only mode with a fresh allowlisted environment.
Do not expose `io`, `os`, `package`, `debug`, `require`, `load`, `loadfile`,
`dofile`, coroutine creation, `collectgarbage`, FFI or bytecode loading.
Trusted coroutine-yield closures implement the bridge; scripts cannot replace
the parent's dispatcher. Use argv rather than shell commands, a cleared
environment and a non-project working directory. Do not inherit credentials,
`LUA_INIT`, `LUA_PATH`, `LUA_CPATH` or dynamic-loader override variables.

Navigation requires its explicit grant and existing Normal-mode/commit guards.
An action already committed while permitted is not rolled back on subsequent
cancellation. Root change/loss/replacement, quit and run cleanup retire the run
and session. Source/view changes revoke proposals, not retarget their owner.

## Manual proposals

`ProposeEdits` requires separate per-run consent. Capture the selected live
buffer, opaque revision, document snapshot/line endings/event version, actual
view/group identities, view epoch and project context at run start. One bound
proposal attempt per run, consumed before source/range validation, including
rejected typed proposals; no direct apply/save. Route Lua proposals with a
host-owned run identity, not a fabricated Chat approval or a global switch
that could redirect a concurrent Chat invocation.

A validated plan remains private until successful child completion. Recheck
the receipt before opening the existing inline preview and before applying
selected/all changes. Reject stale root, source, view, closed/reopened owner,
edit/Undo ABA and conflicting modal. Explicit manual acceptance creates one
Undo transaction, leaves disk untouched and restores editor focus. Keep the
existing Chat receipt/provider/review guards unchanged.

## Rejected and guard-only

Rejected: project autorun, arbitrary eval/path execution, raw App/session access,
direct document changes/save/close/discard, shell/process/network/filesystem
functions, raw DAP, target control/evaluate and implicit external content export.

Guard-only: Chat-to-named-Lua invocation preserving parent grants and cumulative
budgets, persistent grants, plugin discovery, event hooks, background services,
configuration execution and additional Lua versions. User consent to a local
script does not authorize any of these.

## Implementation order and falsifiers

1. Runtime owner: `src/adamantine/lua_script_runtime.cr`, hidden worker dispatch
   in `src/adamantine.cr`, runtime specs/worker fixture, reproducible test-only
   Lua library builder and CI provision. First red: absent runtime API. Positive
   control: actual Lua computes/prints and calls a tool. Attack infinite loops
   (including pcall/native work), heap exhaustion/recovery attempts, output/
   stderr/frame floods, partial frames, binary chunks, startup-env injection,
   missing/wrong ABI, cancellation and cleanup/finalizer hangs.
2. Host owner: `lua_script_catalog.cr`, `lua_script_controller.cr`, App/palette/
   input routes, Lua receipt and existing popup integration, catalog/App specs.
   First red: absent discovery/review/proposal API. Attack no-autorun, manifest
   path escapes, frozen bytes, ungranted tools, root/view/source ABA, proposal
   before failure/cancel, concurrent Chat ownership, manual reject/accept/Undo,
   modal navigation and late events. Built-ins demonstrate read, navigation and
   bounded selected-source manual proposals; labels must disclose partial work.
3. Root verifies the composed diff and real runtime; fresh Luna hostile review
   attacks the implemented boundary. Fix or narrow any vulnerable claim before
   closure. Same-lineage review is correlated, not an independent certificate.

DoD: focused Lua and shared-tool/Chat/modal specs, then full `crystal spec
--link-flags=-fuse-ld=/usr/bin/ld` on macOS, `crystal tool format --check src
spec`, `git diff --check`, direct release build into a private temporary path
(never the user-dirty Makefile release target), CLI and real Lua App/PTY run,
cancel and manual preview/accept/Undo. CI provisions checksum-pinned Lua 5.4.9
on Linux/macOS, but configuring CI is not evidence that remote jobs ran.
Test Lua source/build stays outside the checkout and global installation.

Stop rules: no runtime closure from simulated EditorTools Lua labels; no success
while a child is unreaped; no preview from a failed/stale run; no safety claim
from manifest permissions alone. If a necessary boundary cannot be enforced,
report the open capability rather than weakening the test or calling it safe.

Ledger: this frontier, `EDITOR_ROADMAP.md`, README usage and the matching source/
specs. Evidence decays on runtime ABI, allocator, pipe/deadline, App/root hooks,
proposal receipts, tool contract or TUI changes; refresh the affected gates.

## Implementation evidence

Verification ran on macOS arm64, Crystal 1.21.0, with a private checksum-pinned
Lua 5.4.9 library and actual full editor workers, not a simulated Lua consumer.
Only formatting normalization followed the release build; the final suite
compiled the formatted host sources. No production behavior changed after the
tested release builds.

- Full `crystal spec --link-flags=-fuse-ld=/usr/bin/ld`: **1,662 examples,
  zero failures/errors/pending**, with `ADAMANTINE_LUA_WORKER` pointing to the
  private production release and `ADAMANTINE_LUA_LIBRARY` to the private Lua
  library plus adjacent incompatible-ABI fixtures.
- Root's separate composed gate: **118 examples**, zero failures/errors/pending:
  `lua_script_runtime_spec.cr`, `lua_script_catalog_spec.cr`,
  `lua_script_app_spec.cr`, EditorTools protocol/App/root-lifetime, Chat
  proposal/adversary and modal manager/stack specs. The 40 Lua-specific cases
  include actual computation/RPC, ABI rejection, heap/output/deadline attacks,
  real reap, receipt revocation and one accepted Undo without save.
- `ruby scripts/smoke_lua_scripts.rb --editor-bin <private-release>
  --library-path <private-lua-library>`: **PASS**, separately repeated by root.
  The PTY gate checks F1 discovery/no project autorun, review/cancel, frozen
  source bytes, denied ungranted reads/navigation, responsive runaway cancel
  with actual reap, finalizer timeout without success/preview, manual
  reject/accept/one Undo and unchanged disk digest.
- Existing `smoke_template_split.rb` and `smoke_chat_edit_proposals.rb` PTYs:
  **PASS** on a fresh full release. Chat uses a local fake provider; no paid
  provider or model was called.
- `crystal tool format --check src spec`, `git diff --check`, Ruby/Bash syntax,
  CI YAML parsing, `shards check`, and release `--help` with both Lua overrides
  unset: **PASS**. Normal editor startup remains independent of Lua.
- Debugger fixture shutdown: **3 runs / 92 assertions**, zero failures/errors.
  Dependency preflight: **6 runs / 77 assertions**, zero failures/errors against
  a private copy of the committed Makefile. The user-dirty release installation
  command makes that test's fake-compiler fixture fail in the working tree;
  that unrelated Makefile remains unchanged and outside the feature commit.

The adversary found a genuine terminal-wakeup race: a one-shot nonblocking
send could fail against the 32-slot full input queue and permanently leave the
App thinking a reaped run was active. The focused falsifier failed with
`terminal Lua owner wakeup was not retried`, then passed with retry-until-
delivered-or-retired behavior. Failure/cancel/quota/concurrent-Chat tests now
positively observe `ok/pending_review` before testing proposal discard. An
invalid-range-first/valid-second case observes `invalid_request` then `denied`,
with no preview, in-memory change or save. Missing real-worker setup now raises
an actionable test error rather than silently omitting lifecycle cases.

Fresh read-only Luna hostile review returned **ROBUST within these runtime,
wakeup, cancellation, publication and test seams** after the fixes. This is
same-lineage, correlated review, supplemented by root's source inspection and
separate real-runtime/PTY checks, not an independent safety certificate.

Residual scope: Linux/remote CI still needs its actual run. No live model/TLS,
Chat-to-Lua, OS security isolation or total process-RSS claim is made. Bounded
shutdown may report cleanup pending until the sole supervisor observes reap.
The above certificate expires on changes to the runtime ABI, allocator,
transport/deadline, App input/root/view hooks, proposal receipts, tool contract
or TUI; rerun the affected gates rather than inheriting this status.

Primary references: [Lua 5.4 manual](https://www.lua.org/manual/5.4/manual.html)
(`lua_Alloc`, `lua_resume`, text-only `luaL_loadbufferx`) and the
[official release/checksum index](https://www.lua.org/ftp/). Commander supplied
API/UX ideas only; its unbounded Process/dofile authority is not reused.
