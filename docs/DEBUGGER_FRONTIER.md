# DAP debugging frontier

Status: **PROPOSED / design only**, inspected 2026-10-03. No DAP client,
debug panel, debugger keybindings, or language formatter is implemented by
this document. The current runtime frontier remains editor + LSP.

Implementation order and executable acceptance gates:
[debugger plan](DEBUGGER_PLAN.md). Product context:
[editor roadmap](EDITOR_ROADMAP.md). Advance this frontier one tested slice
at a time; a passing fake adapter does not certify a compiler or real debugger.

## Problem, value, and factual anchor

The user wants to debug Adamas/Crystal programs without leaving Adamantine:
set a breakpoint, run, understand why execution stopped, inspect useful
language-native values, and step without fighting focus or configuration.
The editor must remain usable with large sources, large values, and a stalled
adapter. Installing a debugger or compiling the project is not an implicit
side effect of opening the editor or starting setup.

Success is a keyboard-only end-to-end workflow with accurate state and useful
errors, not a count of supported DAP requests. The first useful release needs
source breakpoints, launch/control, stack selection, locals/children, output,
and safe cleanup. Calling it useful for this request additionally requires
real-binary stepping and locals/children for at least one declared target
language (Crystal or Adamas), not only the C control. Each language keeps its
own support status: a Crystal success cannot admit Adamas. Attach, interactive
inferior input, and enhanced native formatters have separate acceptance gates.

Live editor anchor: `c88e1b5`, with an unrelated user-owned `Makefile` change.
Read-only inspection found no debugger/DAP implementation under `src`, `spec`,
`scripts`, `docs`, README, or shard manifests before these documents were added.

| Existing surface | Consequence for this feature |
| --- | --- |
| [App composition](../src/adamantine/app.cr), lines 329-397, 2493-2594 | A persistent Debug workspace belongs in the layout, not a transient overlay; preserve both editor groups and their narrow fallback. |
| [Key defaults](../src/adamantine/key_config.cr), lines 42-121, 361-372 | F5 is Help, F9 LSP actions, F10 Settings, F11 Reload Theme. The user explicitly approved replacing these defaults with VSCode debug keys on 2026-10-03; remove collisions rather than layering new owners on old defaults. |
| [Input router](../src/adamantine/input_router.cr), lines 41-79, 158-238 | Register actions and preserve modal priority; debug keys must not execute behind an editable dialog. Palette metadata is a separate integration point. |
| [Shared documents](../src/adamantine/document_types.cr) and [orchestrator](../src/adamantine/document_orchestrator.cr), lines 189-257 | Breakpoints are source/document-owned; cursor, viewport, selection and folds remain view-owned. |
| [Gutter renderer](../src/adamantine/editing_text_editor_unicode.cr), lines 243-301, 582-591 | Git owns one marker cell; add distinct debug cells and update all coordinate/hit-test consumers, not just rendering. |
| [LSP async controller](../src/adamantine/lsp_controller.cr), lines 222-265, 374-393 | Reuse identity/generation guard patterns, not its single-inflight/latest-only request policy or JSON-RPC envelope. |
| [Private session store](../src/adamantine/session_store.cr) and [settings updates](../src/adamantine/settings_config.cr) | Reuse atomic/private storage principles without changing the existing session schema or overwriting unrelated config sections. |

Protocol facts were checked against the official
[DAP overview](https://microsoft.github.io/debug-adapter-protocol/overview),
[canonical schema](https://raw.githubusercontent.com/microsoft/debug-adapter-protocol/main/debugAdapterProtocol.json),
[LLDB-DAP configuration](https://lldb.llvm.org/use/lldbdap.html), and
[LLDB variable formatting](https://lldb.llvm.org/use/variable.html).
These are moving sources: recheck capabilities and version-specific options
against the actual adapter binary before implementation or release.

## Admitted, guard-only, and excluded surfaces

Only the inspected existing editor infrastructure and this design are admitted
at present. All new runtime behavior below is **guard-only until its named
gate passes**.

| Frontier | Proposed widening | Admission gate |
| --- | --- | --- |
| DBG-0 | Reference adapter/compiler compatibility evidence | C positive control, real DAP transcript, separate Crystal and Adamas outcomes; no inference from DWARF presence alone. |
| DBG-1 | One local stdio adapter/session, framed transport and session reducer | Malformed-frame, ordering, timeout, saturation, stale-result, reverse-request and cleanup falsifiers. |
| DBG-2 | Explicit launch profiles, source breakpoints/control, stack/source/output UI | Real noninteractive launch + breakpoint + step + exit, modal/split/gutter/source-mismatch PTY regressions. |
| DBG-3 | Bounded lazy scopes/variables, detail view, optional manual watches and formats | Large/cyclic/lazy values, paging and frame/stop/format races; real locals inspection. First useful debugger release is DBG-2 + DBG-3. |
| DBG-4 | Local explicit-PID attach and detach | Actual target survives detach; ownership, crash, timeout and quit tests. |
| DBG-5 | Interactive inferior terminal | Bidirectional terminal IO and terminal ownership tests; only then advertise `supportsRunInTerminalRequest`. |
| DBG-N | ABI-matched language-native summaries/children | Real-binary golden fixtures, bounded passive reads, unsupported-layout fallback. Separate compiler/formatter work, not assumed delivered by the generic client. |

Out of the first release: concurrent sessions, remote/TCP adapters, automatic
build/download/install, arbitrary project tasks or VSCode extension execution,
memory/register/disassembly editors, value mutation, reverse debugging,
conditional/function/data breakpoints, logpoints, REPL auto-detection,
automatic hover evaluation, and full VSCode `launch.json` compatibility.
Unsupported actions are hidden or disabled with a reason, never silently
approximated. Exception-stop reasons are shown; configurable exception filters
are a later capability-gated slice, not a promise of catch-all exceptions.

## UX contract

### Start and discover

`F5` and `F1 -> Debug: Start` work with the new default keymap. Without a profile, show a
short setup flow for adapter, existing executable, working directory and argv;
offer a prefilled LLDB profile if an executable adapter is found. DBG-2 setup
is launch-only; Attach becomes selectable after DBG-4 passes, with an explicit
not-yet-supported reason before then. Show the resolved adapter/target and
launch effects before starting. Missing binary/debug information yields an actionable explanation,
not an empty panel. Setup alone starts no processes.

The last selected profile is remembered per canonical project. The first
release does not rebuild or silently save dirty files. A dirty-source notice
offers explicit Save, Start without saving, or Cancel; Save is not a rebuild
and must not remove the source/binary matching warning.

Add palette actions for Start, Continue, Pause, Step Over/Into/Out, Stop,
Show Debug, Show Stopped Location, Toggle Breakpoint and Configure. Their
labels, availability and effective shortcuts feed Help and panel hints.
Closing the panel does not stop the session. Starting while a session exists
selects it and explains available controls; it never replaces the session.

Use **VSCode-style debug defaults**, explicitly approved by the user:
F5 Start/Continue, Shift+F5 Stop, F9 Toggle Breakpoint, F10 Step Over,
F11 Step Into, Shift+F11 Step Out. Keep Help, LSP actions, Settings and Reload
Theme available through F1, removing their collided default function keys.
Preserve explicit user overrides/unbinds; unresolved user conflicts get the
existing visible warning rather than rewriting the user's configuration.
Default keys must be collision-free, and hints/Help/README must reflect the new
owners. F6 Hover and F1 palette remain unchanged in this bounded migration.
Pause remains a named panel/palette action. Terminal-dependent modified
function keys always have palette and panel alternatives. The convention is
anchored to [VSCode debugging](https://code.visualstudio.com/docs/debugtest/debugging),
not a claim of full VSCode keymap or extension compatibility.

### Workspace and focus

The proposed layout is a bottom workspace with a persistent state/control row
and Stack, Variables, Breakpoints and Output tabs. At sufficient width Stack
and Variables can be adjacent; compact terminals use one selected tab without
losing data or selection. The exact width/height cutoffs are selected by PTY
tests, not certified by this sketch.

```text
  existing project tree | editor group A | editor group B
  ------------------------------------------------------
  Paused: breakpoint   [Continue] [Over] [Into] [Out] [Stop]
  thread / selected frame    | locals / watches
  > main : line 42           | > users   Array(User), 100000
    parse : line 19          |   name    "Alice"
  Stack  Variables  Breakpoints  Output       [Hide Debug]
```

Start explicitly opens/focuses the workspace and retains the return editor
location. A stop refreshes its state, but never steals focus from a modal,
text-entry field or an editor in which the user is typing. Automatic source
navigation is limited to focus already in the Debug workspace/control flow,
and is suppressed by `preserveFocusHint`. Otherwise show `Paused ... Show
location`; the explicit action navigates the active group and records a return
location. The sibling group never follows implicitly. Selecting a frame is an
explicit navigation action. Narrow fallback and hiding the panel preserve the
selected thread/frame, expanded nodes and return location.

Within the panel, Tab/Shift+Tab select regions, arrows move, Right/Left
expand/collapse, Enter opens value detail or the selected frame's source, and
Escape exits detail before returning focus. Values and adapter-provided source
are read-only; ordinary Save/Undo cannot write them into a project document.
State, disabled reasons and breakpoint symbols must work without color.
Watch/profile text-entry fields consume F5/F9/Shift+F5 and other global debug
bindings; only their explicit commit/evaluate/cancel controls act. A stop may
refresh the status behind such a field, never submit its draft or run a command.

Breakpoints have separate requested and adapter-resolved positions. Display
pending, verified, rejected/unverified, disabled and moved states with reasons.
Adapter verification means acceptance of that breakpoint, **not** proof that
the current editor text matches the executable. Dedicated gutter slots retain
Git and fold markers; the execution arrow and selected historical-frame marker
are distinct. Render decorations in every view of the source. A dedicated
breakpoint hit target toggles only breakpoints, not Git or fold actions.
Debug slots remain usable with line numbers hidden. Explicit source navigation
may reveal a folded line only in its destination view; do not unfold the sibling.

### Values in the language's own terms

| View | Source and honest boundary |
| --- | --- |
| Summary, default | Adapter `value`, optional `type` and presentation hints. Preserve opaque display text; do not infer a runtime layout from a type-name regex. |
| Children | Adapter `variablesReference`, lazy expansion and paged named/indexed children when available. Unknown counts remain unknown. |
| Hex | Request `format.hex` only with `supportsValueFormattingOptions`; no local numeric-string conversion presented as debugger truth. |
| Raw fields | Adapter-specific structural view, e.g. LLDB's `[raw]` synthetic child with `enableSyntheticChildDebugging`. This is not a universal DAP mode or a memory dump. |
| Parsed JSON text | Optional local parsing of valid returned text, clearly labeled as a display interpretation, not serialization of the target object. Never call `.to_json` to provide it. |
| Expanded detail | Bounded read-only display of the selected text/children; truncation and unavailable data are explicit. No automatic persistence of values. |

DAP `ValueFormat` standardizes hex, not a generic native/JSON/raw formatter
API. Native String/Array/Hash/union presentation belongs to the adapter and
language formatter layer. The editor consumes that presentation uniformly.
Changing a view retires affected request generations before refetching.

Opening a scope may enumerate ordinary variables. The **client** never sends
implicit `evaluate` requests or calls target methods to implement display.
DAP provides no universal passive-read guarantee: an adapter's summaries,
children or synthetic provider may compute data or execute code even for a
`variables` request. Treat those results as opaque provider output, not a
certificate of purity. Known formatter imports require explicit profile review;
third-party adapters/providers remain executable code within that trust boundary.
Lazy/side-effect-marked nodes require a distinct explicit evaluation gesture;
absence of such a hint is not proof of no side effects.
Watches are optional manually evaluated expressions in the selected frame;
they become stale at every resume/frame change. No automatic reevaluation on
each stop in the first release. Adding/editing a watch does not execute it.
An unsupported language evaluator leaves locals usable and shows a reason.
Raw fields and language summaries do not require a public memory-view feature.

## Architecture and protocol laws

Separate `Dap::Client` transport from a pure session-state reducer, breakpoint
store, source resolver, bounded variable-tree model, and `DebugController`.
The controller publishes immutable/owned UI snapshots; the panel renderer
performs no protocol IO or target evaluation. New module paths and their exact
integration consumers are in the plan.

### Transport and initialization

Use DAP's byte-counted Content-Length framing and request/response/event
envelopes (`seq` and `request_seq`), not LSP JSON-RPC IDs. One writer owns
outgoing order; reader/dispatcher/request deadlines are separate from UI IO.
Support multiple correlated outstanding reads; serialize execution mutations.
Unsupported adapter-to-client requests receive a failed response promptly.
Do not advertise terminal launching, shell interpretation, child sessions,
ANSI styling or memory references before those consumers exist.

Wait for the `initialize` response, then send launch/attach; after `initialized`
perform configuration. Do not wait for the launch response before servicing
configuration: an adapter can defer it until configuration completes. Send
`configurationDone` only when supported. Follow the schema's exception-filter
configuration requirements even if no custom filter UI is offered. Omitted
adapter capabilities mean false; a documentation table is not negotiation.

Use `pathFormat: path`, one-based lines/columns and explicit conversion at the
source boundary. DAP columns use UTF-16; editor codepoints and terminal display
cells are different contexts. Reuse tested coordinate utilities, never apply
LSP conversion twice or assume a tab occupies one display cell.

`supportsVariableType` and `supportsVariablePaging` are **client initialize
flags**, not adapter capabilities. Set the latter only after paging consumers
and bounded fallback pass. Absent counts or ignored start/count cannot become
an invented completeness claim. A count of zero requests all children, not
an empty page.

### State, ordering, and stale handles

Track session lifecycle separately from target execution and target liveness.
Lifecycle is Idle -> Starting/Configuring -> Active -> Disconnecting -> Ended,
or Failed. Active can have running and stopped threads simultaneously.
Do not invent thread 1 or label all threads stopped when `threadId` is absent
or `allThreadsStopped` is false/missing. A debugger thread is not necessarily
a Crystal/Adamas fiber. Pause is pending until a stop event actually arrives.

Dispatching Continue/Step moves the affected execution state to Resume pending
and disables its frame/step/evaluation actions. A successful response promotes
it to Running/partially running unless a newer stop epoch already superseded
that command; no `continued` event is needed for this transition. A timeout or
ambiguous failure shows Execution unknown, not Paused. Do not infer a fresh
stop from an error alone. A newer confirmed stop permits fresh inspection;
offer explicit Pause/status recovery or Stop instead of using retired handles.

Each asynchronous result carries session/adapter identity, project generation,
stop epoch, selected thread/frame generation, format generation and request
identity as appropriate. DAP frame/variable handles are scoped to a suspension;
retire them before dispatching Continue/Step and on unsolicited continuation,
termination, invalidation or disconnect. A `continued` event is not required
after an execution request. Integer handles may be reused at the next stop.
No cached reference can survive just because its number matches.

A fast new `stopped` event can precede an old step response: the response must
not set the new stop back to Running. A failed execution request does not
resurrect old handles; reestablish stopped state and fetch a fresh generation.
Respect scoped `invalidated` events, conservatively invalidating all affected
state for unknown areas. Cancellation is best effort; correctness relies on
result guards, not acknowledgement. Terminal session states never revive on
a delayed response. Partial thread continuation may conservatively expire all
cached handles without pretending every thread ran.

Keep one full replacement `setBreakpoints` request in flight per source and
one latest desired set behind it. Apply only matching-generation results, then
reconcile the newest desired set. The request contains all enabled breakpoints
for that source, including an empty list to remove them. Preserve stable local
IDs separately from adapter IDs, and reconcile moved/removed breakpoint events
without attaching an obsolete adapter ID to a new session.

### Source truth and edits

Resolve canonical paths and explicit source maps, not basenames. Positive
`sourceReference` content is session-scoped read-only source; it must not
overwrite an editable file. Missing sources offer Configure source map or
Show adapter source, not a guess at a similarly named file.

The launch-time editor snapshot is only a session baseline, not evidence of
what was compiled. Adapter/sourceReference content is preferred for navigation,
but also is not compiled-text proof without a matching checksum/build identity.
Use those checks when supplied. Otherwise label source match unverified.
Represent local paths and session-only source references as distinct identities;
never feed a made-up disk path to normal save/watch/LSP/session persistence.
Keep debugger source identity/version separate from
live editable identity. Edits, external reloads, undo/redo and Save can change
editor lines but do not update the binary. Mark the live source outdated and
keep execution navigation in a read-only session source when available; when
unavailable show the location with an explicit mismatch banner and no precise
execution arrow on the changed text.

Requested breakpoint anchors can rebase locally with edits, but do not silently
submit those shifted live-source lines against the old binary. Rebind explicitly
or on a new launch, retaining the old resolved binding until then. Project/root
change invalidates requests and must resolve any active-session exit choice
before switching. Closing the final editable view does not destroy session
source or the breakpoint model.

### Ownership, security, and failure

The editor owns the adapter process it created. A launched target and an
attached target are distinct ownership cases. Stop for launch disconnects with
termination semantics; attach defaults to **Detach**, leaving the target alive.
Explicit Terminate attached target is a separate choice, capability-gated by
`supportTerminateDebuggee`. Do not kill a PID merely received from an adapter.
Quit/project-switch must expose these effects and allow Cancel.

Stage close/project-switch decisions before any target mutation: collect all
dirty-file choices, then final approval of the session's terminate/detach effect.
Do not discard/close views, change root or send that request before final
approval. Cancel before commit preserves the project and session; earlier
explicitly approved Saves may remain persisted under the existing close
contract. Once a target action was sent it cannot be rolled back by a later
dialog; cleanup failure must report the uncertain result, not claim Cancel
restored the old target state.

`terminated` ends the debug session; only `exited` or other direct evidence
proves target exit. EOF/timeouts may leave target state unknown. Preserve that
uncertainty in the UI, retire handles, reap owned adapter handles with bounded
cleanup, and never auto-restart/reattach or issue further execution commands.
Do not claim that killing the adapter necessarily killed the target.

Adapter profiles execute local programs; LLDB formatter imports and command
hooks execute code too. Project profiles are inert until explicit review/start;
commands, adapter paths, formatter paths and target argv appear in that review.
No shell interpolation, `${command:...}`, arbitrary task runner, automatic
formatter discovery/import, or implicit evaluation from formatting choices.
Retain secret-valued env overrides only in memory/user-private configuration;
never copy them to a shared project profile, protocol log or failure report.
Debugger values can contain secrets: no automatic value/trace persistence.
Render adapter text as sanitized text, not raw terminal escape sequences.

### Resource envelope

Initial **proposed, unmeasured** defaults: 8 KiB header, 16 MiB message limit
(user setting range 1-64 MiB), 64 outstanding requests, 100 children/page,
5,000 retained variable nodes/8 MiB display data, 1 MiB output ring and
64 KiB selected-text detail. Proposed source-cache ceiling: 32 MiB logical
source bytes and 32 retained snapshots, at most one baseline per source rather
than a history of revisions. Count referenced persistent roots against this
budget too; structural sharing is not an unbounded-retention license. Evict
unpinned sources first. If even the selected source cannot fit, show source
unavailable/evicted and its metadata; never substitute live text silently.

Add bounded JSON depth/token/collection parsing, **aggregate inbound bytes and
queued decoded-response/event budgets**, pending-frame/writer byte budgets,
request/partial-frame deadlines and maximum tree depth. Pick exact parser/queue
budgets with DBG-1 falsifiers before sealing
that runtime envelope. A background fiber alone does not make CPU-heavy JSON
parsing or large string rendering nonblocking.

Variable/tree limits leave a visible Partial/Load more notice; a nonpaging or
noncompliant adapter may yield only a bounded subset. Output eviction records
the dropped count. Do not silently drop lifecycle events to keep the UI alive:
critical-event saturation or an oversized/malformed frame fails the session
visibly, preserving editor work. The UI explains the relevant limit and where
to change it; raising a limit applies explicitly to the next session, never
automatically. Display limits must not scan/duplicate a multi-megabyte value
on every frame. Timing and RSS are measured diagnostics until matched-host
tests justify a portable regression gate.

## Native-language readiness: separate from DAP readiness

Local `lldb-dap --version` reports Homebrew LLVM/liblldb **22.1.8**. No real
debugger session or compiler build was run during planning. Presence is not
compatibility evidence; platform permissions and Python formatter support
must be probed with that binary, not assumed from current online docs.

There is no `adamas` command on the inspected PATH. Executable `bin/adamas`
and `bin/adamas_deb` candidates exist in the compiler checkout, dated September
22 and 18, but their build provenance against the dirty October 3 sources is
unknown. A probe of either certifies only that selected binary, never the
current working tree. Record compiler binary identity/provenance with each
compatibility result; a current-source claim requires a source-matched build.

Adamas was inspected at HEAD `09d6ef6c` with **dirty CLI and LLVM backend**.
The following anchors describe that live working tree, not the clean commit:

- `src/compiler/cli.cr:968-973,3412-3413,3926-3939` routes `--debug` to backend
  metadata and clang `-g` with the selected optimization level.
- `src/compiler/mir/llvm_backend.cr:858-1055,1092-1097,7050-7059` emits
  subprograms, parameter/local bindings and source locations. The compile unit
  uses DWARF 5 but a C++ language label; this does not establish Crystal/Adamas
  expression semantics or usable locals in every function.
- `tools/lldb/crystal_dap.py` contains response-enhancement helpers, but no
  demonstrated transport hook into the real adapter. It is not a ready DAP
  server. Its expression fallback is not a passive formatting mechanism.
- A concrete source contradiction blocks trusting the existing union provider:
  backend `llvm_backend.cr:7298-7328,30112-30119` emits a variant discriminator
  at offset 0 and payload at +4; `tools/lldb/crystal_formatters.py:545-601`
  assumes a union-type header at 0, discriminator at +4 and payload at +8.
  Raw reference unions and `Pointer(T)|Nil` also need different decoding.
  This is not an executed debugger failure, but copying that provider would
  import an unsupported ABI assumption.

Source fingerprints on inspection (SHA-256; refresh after any source edit):

```text
src/compiler/cli.cr
dda6e9d91467bbc2234f06ffc2f99ab438cc08c98807c20c80a0ae1cf06b264b
src/compiler/mir/llvm_backend.cr
76305423539f8e71fed1a478af16ec7b26ce0aea0575147f1191bce72033f740
tools/lldb/crystal_formatters.py
250b4b42c5d5acd0b3b0496313f92196a5969d8b4d35c3658ad35552271492c1
tools/lldb/crystal_dap.py
dc043d59e4326cc97fa1dcceb044e92239bf9da9a4ede60a52a1006df24bd544
```

DBG-0 tests C as a positive control, then stock Crystal and Adamas independently:
primitives, Unicode/embedded-NUL String, Array, empty/nonempty containers,
optional/union values, nested records and shadowed/out-of-scope locals. Record
breakpoint resolution, stepping, scopes, types, children and unavailable values
separately. Optimized-out data is not an editor error or a license to invent a
value. Formatter mock tests and a DWARF dump cannot replace a real-binary probe.

DBG-N first admits bounded memory-only String/Array summaries, then additional
layout families only with actual ABI/version/architecture fixtures. Prefer
DWARF member layouts and compiler-provided metadata over hardcoded offsets;
missing or incompatible metadata disables that formatter with raw fallback.
Do not call target methods to obtain summaries. Do not assume Adamas and stock
Crystal share an ABI merely because the type spelling matches. Compiler or
Adamas formatter fixes are a separately scoped task; generic DAP work can
proceed with the reference adapter even when that language-specific gate fails.

## Falsifier roster and stop rules

All gates below are **planned / not executed** for debugging in this checkout.

| ID | Counterexample that must be rejected or handled honestly |
| --- | --- |
| D01 | Split UTF-8 frames, malformed/duplicate length, truncation, invalid JSON/depth, unknown responses and requests, sequence/correlation errors. |
| D02 | Launch waits for configuration; initialized/response races; partial stop without thread ID; successful Continue without continued transitions out of Paused to Running/partial; a newer stop wins over an older resume response; ambiguous timeout becomes ExecutionUnknown. |
| D03 | Stop A and Stop B reuse frame/reference IDs; delayed variables/evaluate/source responses arrive after resume, frame change, format change, root change or session end. |
| D04 | Full-set breakpoint replacement races with toggle/remove/edits; adapter moves/rejects/removes a breakpoint; obsolete IDs/events cannot corrupt a new binding. |
| D05 | Same basename in two directories, UTF-16/Unicode columns, sourceReference without path, unavailable/checksum-mismatched/evicted source, external reload and two views of one file. |
| D06 | Stop arrives during typing, palette/Settings/confirmation or paste; every global debug binding during watch/profile entry, including F5, Shift+F5, F9, F10, F11, Shift+F11 and any configured Pause. No stolen focus, submitted draft, wrong-file insertion, target action or fall-through. |
| D07 | Git + breakpoint + execution marker + fold coexist, including hidden line numbers; hit testing and scrolling match at narrow widths/Unicode. Revealing a folded stop never unfolds the sibling. |
| D08 | Huge String/100k-element Array, deep/cyclic children, missing counts, ignored paging, slow getter/lazy node, and malicious ANSI output. Bounded retention, explicit partialness, no implicit client evaluation; opaque adapter/provider execution is not certified as passive. |
| D09 | A watch mutates state or evaluator is unsupported; adding/rendering a watch never runs it, manual evaluation warns and binds to the selected frame. |
| D10 | Adapter blocks its writer, bursts maximum-size replies while rendering stalls, floods output/state events or crashes; aggregate queues stay bounded, cleanup is bounded, target state is not invented. |
| D11 | Launch Stop versus attach Detach, terminated without exited, lost connection, denied attach, dirty-file plus session quit/root-switch Cancel before any target action, and delayed old-session cleanup. |
| D12 | New VSCode-style defaults retain old function-key owners, lose explicit overrides/unbinds, or rely on missing modified function keys; palette/panel and displaced actions remain fully usable. |
| D13 | C control succeeds but Crystal/Adamas does not; per-language support remains unadmitted. A useful target-language release needs at least one real-language stepping/locals/children pass. |
| D14 | Native formatter sees a different ABI, nullable raw pointer, invalid pointer, missing metadata, embedded NUL or wrong element stride; no guessed language value or target method call. |
| D15 | runInTerminal gets literal argv, env removals, stdin, resize, EOF and interrupt; output-only logs cannot satisfy this gate. |

Stop widening on a failed discriminator. Preserve surviving layers: an Adamas
formatter failure does not refute generic DAP, while a passing transport does
not admit Adamas debugging. Fix the failing layer or narrow support with a
visible reason. Do not hide crashes by raising limits or replacing a live
session automatically. No production or compiler mutation is authorized by
the planning artifact alone.

## Evidence freshness and closure

The design's evidence is live source inspection plus official protocol/docs;
Luna code/UX findings were checked at the critical key/gutter/async/ABI seams by
the parent. This is correlated review, not independent runtime replication.
The plan names red-first specs, real-adapter and PTY checks for each widening.
Revalidate source anchors after editor changes, compiler fingerprints after
Adamas edits, and adapter options after binary/version/platform changes.
Docs/link validation only certifies document consistency, not runtime behavior.

Planning checks: `git diff --cached --check` found no whitespace errors; the
local Markdown link/whitespace validator passed 43 links across these three
documents, with present/missing-path controls. Nine existing spec-file anchors
were checked for presence. The bounded adversarial review reached **ROBUST for
proposed design/plan alignment only** after the resource, resume, source-cache,
approval-ordering, language-release and modal-key gaps were closed in the
documents. No compiler build, DAP session, debugger spec or inferior PTY gate
was executed. These checks do not advance any runtime admission gate.
