# Shared assistant and Lua tool frontier

The subsequent local bottom Chat / Log slice is tracked separately in
[CHAT_UI_FRONTIER.md](CHAT_UI_FRONTIER.md). It does not imply a connected model,
Lua runtime or broader tool grants.
The later [CHAT-2 provider frontier](CHAT_PROVIDER_FRONTIER.md) separately
admits reviewed network export and selected-buffer reads. Local ReadEditor
authority alone does not authorize provider export or a Lua runtime.

Status: **VERIFIED — local TOOLS-1 within the boundaries below**, 2026-10-05.
Anchor: `ba1a0da8f6d5cd25af698a2b59be038964da5394`, 2026-10-04.

## Goal and authority

The user accepted typed editor/debugger tools followed by a full-width bottom
chat, and asked that Lua remain a potential scripting consumer of the same
tools, including delegation from chat. This frontier replaces the earlier
assistant deferral only for the bounded tools slice below. It does not reopen
the completed [debug workflow](DEBUG_WORKFLOW_FRONTIER.md).

TOOLS-1 builds a local host-owned dispatcher, not a model provider or a Lua
runtime. Chat and Lua are consumer labels, not sources of authority. A trusted
App integration issues a session with a canonical project, an opaque project
epoch and explicit capabilities. An untrusted invocation cannot choose the
root, epoch, caller grants or debugger transport. App-owned root changes,
including changing away and back, retire the old session. Observed external
changes to canonical project/directory identity or loss of root proof also
retire it, so restoring the old path does not revive previously rejected
sessions. This is not a filesystem watcher or proof against every unobserved
external ABA/race. Delegation intersects grants
and shares the original call/result budget; it cannot reset limits or revive
a closed parent. Each backend invocation receives a typed execution permit
distinct from the value-shaped project Context. Its live predicate checks
session/ancestor closure and captured context. Navigation must recheck it at
the existing guarded commit after yielding reads, not only when publishing a
result. An action already committed while permitted is not rolled back if a
later transport yield observes cancellation. These are in-process host API
boundaries, not authentication
for an external server or a sandbox against arbitrary native plugin code.

## Admitted TOOLS-1 design

The wire-shaped local request is `{id, name, arguments}`. The call ID is bounded
and single-use within the shared session budget. The dispatcher validates exact
argument types/keys into typed requests before backend access. Responses retain
the call ID and an explicit status; malformed requests do not echo their input.
Tool definitions and execution use one catalog and capability mapping.

| Tool | Capability | Behavior and limit |
| --- | --- | --- |
| `editor.list_buffers` | ReadEditor | Bounded page of live, in-project buffers, opaque IDs/revisions, active group/view metadata; no full text. |
| `editor.read_buffer` | ReadEditor | Requires current opaque buffer ID/revision. Reads bounded PieceTree fragments, one-based lines and zero-based Unicode codepoint columns; no whole-line/document materialization or disk reload. |
| `editor.find_files` | ReadEditor | Path-only bounded QuickOpen index/ranking under the captured project; generated directories and symlinks retain existing exclusion policy. Partial/cancelled results are explicit. |
| `editor.open_file` | Navigate | Existing guarded open, stable disk identity and canonical project fence; 16 MiB editor limit remains. It can focus tabs and invoke existing LSP didOpen, so it is not a pure read. |
| `editor.focus_buffer` | Navigate | Requires a live ID/revision; activates the actual existing editor group/tab without reopening or discarding text. |
| `debug.snapshot` | ReadDebugger | Inert retained state/threads/certified frames/variables. No polling, DAP requests, source-text/output/watch export or target evaluation. |

Navigation is denied outside Normal input mode, both at submission and at the
existing guarded commit. Read-only calls must not steal focus or alter tabs.
Paths outside the canonical project, non-files, binary/invalid text and stale
identities fail closed. Deleted or unprovable buffer paths may be denied in
this first slice rather than silently reopening disk content. Buffer revisions
use live ownership and exact PieceTree state (including line-ending state), not
a disk timestamp. CHAT-2 adds the document-event version as an additional
fence for ordinary edit/undo transitions; the saturating LSP `Int32` version
alone is not an immortal change counter or a replacement for the state fence.

Hard ceilings: 8 KiB request JSON, depth 16, 64 invocation attempts, 64 KiB encoded
response, 512 KiB aggregate response bytes, delegation depth 4 and 16 child
sessions. Reserve space for one sealed terminal limit response, charged once;
later attempts return that same stop signal without backend access or a new
admitted call/result. A frontend must stop at exhaustion, not repeatedly emit
the terminal result or count it as a new tool call.
Read text is capped at 8 KiB per result; catalog/request-specific page, query,
path and fragment bounds remain below these hard ceilings. Errors and failed
calls consume the same budget. Frontends must invoke through the App owner;
the facade is not thread-safe and cannot be called from an arbitrary worker
fiber while the App is mutating state.

## Debug evidence boundary

The existing full controller snapshot retains old frames after resume while
the reducer retires handles. TOOLS-1 must not label that array a fresh stack.
A lightweight inspection snapshot retains the accepted stack's reducer
certificate, rechecks it against session/client/project/stop/thread/handle
state, and exports frames only while that proof remains current. A legitimate
frame selection can reseal a previously current stack; stale rows cannot mint
fresh evidence. Thread execution must come from the current reducer, not the
UI's last inbound-event cache. The snapshot's copied canonical target-origin
project and retained directory stamp must match the tool's captured project
and currently proven directory identity before values are exported. A launch
review or later editor binding is not the preceding target's origin proof;
neither alias retargeting nor replacing a directory at the same path can
relabel its values. Ordinary directory mtime changes do not change identity.
Inspection does not restamp an old target, materialize source text or call poll.
This proof identifies the accepted launch's project binding using its retained
pre-start directory observation. It does not certify executable build/source
provenance or eliminate unobserved filesystem races during adapter startup.

Unknown execution, pending pause/resume, target liveness, scope unloaded,
pending, failed, loaded-empty and partial values remain distinct. Stack total
completeness is unknown unless supported by evidence. Numeric DAP IDs are
observation metadata, never tool execution handles. Retained values are not
automatically expanded, reformatted or evaluated. A source line from DAP is
not a byte/codepoint column and must be labeled separately.

## Guard-only and rejected surfaces

- Bottom chat/provider configuration and model tool-call adapters follow this
  slice. No model request, key storage, paid call or conversation persistence
  is implemented or verified by TOOLS-1.
- Lua is an admitted future consumer contract, not an installed runtime.
  A future named-script tool must inherit the parent session and additionally
  constrain runtime, libraries, cancellation, time, memory and output. No
  arbitrary `eval(lua)` tool or access to the App object is admitted.
- Proposed edits must enter the existing inline preview with stale-owner
  guards and manual acceptance/Undo. Direct edits, save, close/discard, raw
  command strings, shell/process execution, raw DAP, launch/resume/step/stop,
  watches/evaluate, automatic file-content upload and out-of-root access are
  not tools in this slice. Navigation is not approval for any of them.

Reference inspection: Crystal Ball's `llm/base.cr` supplies useful tool
definition/call-ID shapes and `tools/registry.cr` a pre-dispatch guard pattern.
Do not copy its subagent allow-always approval. Commander's
`src/plugin_runtime.cr` runs Lua with `Process.run`/`dofile` and unbounded
captured output; manifest permission checks there are not an OS sandbox.
Reuse API ideas, not those authority or resource assumptions.

## Execution plan, rollback and falsifiers

Risk: **CAUTION**, new capability/freshness boundary. Rollback: one atomic local
commit; no remote publication, dependency, ignored `lib` or Makefile change.
Inventory: `rg -n '@project_root\\s*=' src/adamantine` finds App construction
and the command-palette root commit as the two App assignment sites. Tool
epoch retirement must cover the latter; debugger generations keep their own
meaning. New catalog consumers are typed dispatcher, App backend, future chat
and future Lua; no raw command handler becomes a tool.

1. `src/adamantine/editor_tools.cr`, `spec/editor_tools_protocol_spec.cr`:
   typed catalog, validation, explicit grants, session/delegation lifecycle,
   quotas and bounded responses. First red: missing API. Adversaries: forged
   grants/root, unexpected keys/types, duplicate IDs, deep JSON, large output,
   child escalation/quota reset and closed-parent invocation.
2. `src/adamantine/debug_controller.cr`,
   `spec/debug_inspection_snapshot_spec.cr`: inert lightweight observation and
   certified stack freshness. First red: missing inspection API/old rows after
   resume. Adversaries: frame-ID reuse, partial thread state, frame selection,
   pending/unloaded/empty/failed scopes and no additional DAP commands.
   A fake-adapter falsifier also rejected cached thread rows immediately after
   Continue: the reducer was ResumePending while the observation said Stopped.
   Project origin and current reducer execution must be joined in the inert
   inspection/facade without polling or silently rebinding the debugger.
   A real-path Partial-stop probe exposed a preceding reducer bug: a matching
   stop arriving before the Pause ACK clears the pause ticket but leaves
   aggregate execution PausePending, so no fresh stack can be requested.
   Before admitting inspection, separately fix the narrow transition in
   `src/adamantine/debug_session_state.cr` with a red-first regression in
   `spec/dap_session_ordering_spec.cr`, then repeat the real fake-adapter
   stop-before-ACK path. Risk: CAUTION; rollback is its separate atomic commit.
   Guard: a genuinely pending unrelated action must remain pending, and an ACK
   alone still does not prove a stop. DoD: reducer/pause specs and the new
   inspection integration probe pass; the final full suite covers composition.
3. `src/adamantine/editor_tools_controller.cr`, App include/initialization and
   command-palette root hook, `spec/editor_tools_app_spec.cr` and
   `spec/editor_tools_root_lifetime_spec.cr`: bind typed calls
   to existing guarded editor operations and inspection. First red: absent
   App session. Adversaries: modal navigation, symlink/out-of-root/binary input,
   root A-to-B-to-A, close/reopen, version saturation, huge Unicode line,
   unsaved text reuse and real shared-view group focus. The hostile source pass
   also found that an externally retargeted symlink project root could revive
   a stale session when restored; retain the last observed proven directory
   identity and retire on change or loss, without treating ordinary directory
   mtime changes as a new project. It also found that the original
   post-execution closure fence could suppress output
   after a cancelled yielding open without stopping its tab commit. The
   execution permit must reach that commit guard; an actual multi-chunk read
   cancelled by closing its parent must leave tabs and open buffers unchanged.
   Closed-buffer references must be pruned at the UI close commit, not retain
   large PieceTree roots until the next tool call.

DoD: focused new specs plus existing modal/quick-open/debug-controller specs;
then full `crystal spec`, `crystal tool format --check src spec`,
`git diff --check`, actual CLI release build and fake-debugger App/PTY smoke.
Use pinned TUI `7ca26fd559cf8c05e5b4ed924e7c691fabb66e43` first on CRYSTAL_PATH,
private Crystal caches and the existing macOS linker flags. Pass means the
declared behavioral falsifiers execute, not merely that schemas have fields.
Root verifies delegated code and a hostile review before admission. Evidence
decays when dispatcher/host bindings, root hooks, PieceTree semantics, reducer
certificates, TUI pin or verification fixture changes. Refresh the affected
behavioral gates; no provider/runtime claim follows from local tool tests.

## Verification evidence (2026-10-05)

The preceding Pause transition was independently checked with 69 reducer,
controller and thread-lifecycle examples, then committed separately as
`11c795e`. It moves aggregate execution derivation after consumption of the
matching pause ticket; unrelated pending pauses and ACK-only uncertainty remain
guarded. The real fake-adapter inspection path also passed.

Root's frozen-production check passed 163 focused examples across tools,
inspection, pause ordering, controller/thread lifecycle, modal isolation,
QuickOpen and document orchestration. The final source state additionally
passed 48 focused tool/inspection examples and the complete 1,475-example
suite (0 failures, errors or pending; 1:50 minutes). The final tests include a
multi-chunk open cancelled by closing a Chat parent while its Lua child is
invoking, and a joined Chat-to-Lua-to-App-to-debugger inspection that exports
retained typed values without new DAP commands. The joined spec also rejects
values from another App project and from a replaced origin directory.

The final behavioral-input seal is 319 unique sorted paths under `src`,
`spec` and `scripts`, plus `Makefile`, `shard.yml` and `shard.lock`, using the
same path/NUL/file-SHA-256/NUL recipe as the production seal below:
`29ea877f0aba498f41bb573686142f7ba67a433c5912d162488ec6805fd34c4e`.
Documentation is excluded from these input seals. The pinned TUI checkout was
clean; Makefile, dependency manifests and ignored `lib` were unchanged.
Root ran these final checks with private caches:

```sh
export CRYSTAL_PATH="/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:$(/opt/homebrew/bin/crystal env CRYSTAL_PATH)"
export CRYSTAL_CACHE_DIR="/private/tmp/adamantine-tools-verify.n13HQ7/cache"
/opt/homebrew/bin/crystal spec spec/editor_tools_protocol_spec.cr spec/editor_tools_app_spec.cr spec/editor_tools_root_lifetime_spec.cr spec/editor_tools_debug_app_spec.cr spec/debug_inspection_snapshot_spec.cr --link-flags=-fuse-ld=/usr/bin/ld --error-trace
export CRYSTAL_CACHE_DIR="/private/tmp/adamantine-tools-verify.n13HQ7/cache-full"
/opt/homebrew/bin/crystal spec --link-flags=-fuse-ld=/usr/bin/ld --error-trace
/opt/homebrew/bin/crystal tool format --check src spec
git diff --check
```

An actual CLI release was built with Crystal 1.21.0, the pinned clean TUI and
`--link-flags=-fuse-ld=/usr/bin/ld`. Its production-input seal is 105 sorted
paths under `src`, plus `Makefile`, `shard.yml` and `shard.lock`, hashing each
relative path and file SHA-256 separated by NUL:
`2364830b2335d493817e20a01ad534caae81afd2a6038ff1980b7ee61b808d3f`.
The release command was:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-tools-verify.n13HQ7/cache-release /opt/homebrew/bin/crystal build --release src/adamantine.cr -o /private/tmp/adamantine-tools-verify.n13HQ7/adamantine --link-flags=-fuse-ld=/usr/bin/ld --error-trace
```

The private binary SHA-256 is
`c2a269936796015276f2a04980100257d292e6141bfe656cd5f4989c51e9fad3`.
Both commands passed against that binary:

```sh
ruby scripts/smoke_debugger_session.rb --fake-adapter --editor-bin /private/tmp/adamantine-tools-verify.n13HQ7/adamantine --dock left
ruby scripts/smoke_debugger_session.rb --fake-adapter --editor-bin /private/tmp/adamantine-tools-verify.n13HQ7/adamantine --dock bottom
```

They exercised actual App/PTY launch review, modal capture, breakpoint routing,
stack/variables, Unicode/narrow resize and adapter/quit cleanup. The script's
syntax and screen-model self-check also passed. This is a fake-adapter UI
regression check, not evidence about native executable provenance.

Two Luna source passes returned ROBUST within the local, cooperative App-owner
boundary; their lineage is correlated. Root separately inspected the guards,
preserved the original client-start ordering and ran the behavioral commands
above. Final verdict: **ROBUST within the declared local TOOLS-1 boundary**.
Unobserved filesystem ABA/races, cancellation after a valid navigation commit,
and frontend handling of the sealed terminal quota response retain the limits
described above. No provider, chat UI, Lua runtime, native sandbox or
arbitrary-thread claim is admitted.
