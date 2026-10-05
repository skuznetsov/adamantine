# DAP debugging frontier

Status: **DBG-0/1 foundation, DBG-2/3 controller runtime and App composition
gates verified within the evidence contexts below**, updated 2026-10-04 UTC.
The actual App/PTY uses a fake adapter; real stock-Crystal/LLDB execution was
verified through the controller. The opt-in native provider additionally passed
String/Array(Int32) goldens for Crystal 1.21.0 / LLDB 22.1.8 on arm64 macOS.
That earlier value slice did not include a joined App/real-target run. Adamas,
attach, inferior terminal and broader language-native layouts remain unadmitted.

Current finishing track: [DEBUG_WORKFLOW_FRONTIER.md](DEBUG_WORKFLOW_FRONTIER.md).
The Settings DAP-cap slice passed its focused gate at `4d86129`; the subsequent
joined stock-Crystal App/PTY and two-column rail/configurable inspector/shared-
border layout passed 1425 specs, release and real/fake PTY gates. That consumer
admission and its exact seals live in the finishing frontier. The newly accepted
shared assistant/Lua tool foundation has its own
[TOOLS-1 frontier](ASSISTANT_TOOLS_FRONTIER.md), locally verified on 2026-10-05
with 1,475 specs, release and fake-adapter left/bottom App/PTY gates. This adds
inert certified inspection, not model-controlled DAP execution. A separately
committed matching-Pause stop-ordering fix (`11c795e`) has reducer and
fake-adapter regression coverage. Chat providers and the Lua runtime remain
separate, unadmitted slices. The bottom-workspace description
below records the preceding admission, not the new layout's acceptance evidence.

Preceding verified value slice: **useful value presentation and opt-in stock-Crystal
String/Array(Int32) values**, requested 2026-10-04. The bounded design,
rejected surface and final 1380-example/release/PTY/native gates are in
[DEBUG_VALUES_FRONTIER.md](DEBUG_VALUES_FRONTIER.md). Generic App and real
native-controller evidence remain separate; existing DBG-2/3 history below
is unchanged.
The user's 2026-10-03 continuation returned to the staged debugger implementation
after the measured C/Crystal reference route. The bounded launch/values slice
now has the separate controller and App gates recorded below. Building or changing
Adamas, installing tools and model API calls remain out of scope. The new value
slice authorizes bounded owned stock-Crystal fixtures and an explicitly reviewed
bundled provider; it does not authorize project formatter discovery or assume
Adamas/native compatibility from the prior probes.

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

Historical preimplementation anchor: `c88e1b5`, with an unrelated user-owned `Makefile` change.
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

The existing editor infrastructure, bounded DBG-0 harness, parent-executed
DBG-1 library/reducer, DBG-2/3 controller and App composition gates are admitted
within the evidence below. Generic App value presentation and the bounded
stock-Crystal native-controller slice are admitted in the
[values ledger](DEBUG_VALUES_FRONTIER.md). Attach, inferior terminal and other
native layouts remain **guard-only until their named gates pass**. The fake-App
and real controller contexts are complementary, not a single end-to-end
real-target run.

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

Future model-assisted debugging chat belongs in an independent full-width
bottom pane, not a Variables/Stack sidebar. Chat/provider implementation remains
deferred. The user subsequently authorized a two-column left activity rail,
Files/Debug inspector selection, configurable Debug placement and single/shared
borders using `crystal_ball`'s frame-junction rendering as a reference. Those
changes have their own finishing frontier and consumer gates; the earlier
2026-10-03 border deferral no longer governs this layout work.

The preceding admitted layout was a bottom workspace with a persistent state row and
Stack, Threads, Variables, Watch, Breakpoints, Output and Sources tabs. Both
wide and compact terminals display one selected pane without losing its data
or selection; a wide header exposes all tabs, and a compact header names the
selected pane. Side-by-side Stack/Variables and clickable control buttons in
the original sketch remain future UX, not part of this admission gate.

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

An explicit Hex choice refetches only the selected node's original bounded
`variables` page, with `format.hex`, after the adapter advertises
`supportsValueFormattingOptions`. The consumer must retain the parent
reference, page/offset and current frame certificate: matching a variable by
name alone is insufficient for duplicate or shadowed names. Missing or changed
identity, late responses/errors, a resumed target or a changed inspection view
make the representation Unavailable. Format requests never send `evaluate`,
mutate a variable, or turn an adapter-reported PID into ownership.
Local retirement is not evidence of unsupported formatting: if a later
ordinary variable page changes the inspection generation, discard the Hex
result and show an explicit retry reason. Retry requires a new user action;
there is no automatic refetch. The default wire page count is 100, with at most
one extra mapped row retained temporarily as an overflow witness if an adapter
ignores that count. Keep only one bounded selected-detail representation;
rendering a snapshot performs no I/O.

Local JSON interpretation requires complete, unchanged returned text. A clipped
prefix that happens to parse, or terminal sanitization that changes text, cannot
certify complete JSON. Carry completeness provenance through the controller and
variable DTOs; keep bounded Summary display available with its clipping reason.
Raw remains adapter-supplied structure, not a fabricated generic raw field.

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
overwrite an editable file. A positive reference takes precedence even when
the adapter also supplies an existing local path: DAP requires a `source`
request for that content. Keep the path as display metadata, not an editable
substitute if retrieval fails. Zero permits local-path resolution; invalid
negative references are rejected. Missing sources offer Configure source map or
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

DBG-1's tested default envelope is an 8 KiB header, 16 MiB message, 32 MiB
aggregate retained/in-progress wire bytes, 64 MiB logical decoded credits,
128 decoded messages, 64 pending requests and 64 timeout tombstones. The writer
counts active IO plus queued frames against 16 MiB/64 frames; actual IO helpers
must exit before retirement. JSON depth is capped at 64 and tokens at 250,000.
Writes have a two-second deadline; a started incomplete frame has an absolute
five-second deadline, while a completely idle adapter is not timed out. Request
deadlines default to ten seconds and are bounded by five minutes.

The constructor supports a 1-64 MiB message range, not an implemented UI
setting yet. Raising that limit must explicitly raise compatible inbound,
decoded and writer envelopes for the next session; it is never automatic.
Logical credits and per-subsystem scalar samples are not RSS or a globally
atomic memory snapshot. A bounded parser is not proof of UI latency.

Later **proposed, unmeasured** defaults: 100 children/page,
5,000 retained variable nodes/8 MiB display data, 1 MiB output ring and
64 KiB selected-text detail. Proposed source-cache ceiling: 32 MiB logical
source bytes and 32 retained snapshots, at most one baseline per source rather
than a history of revisions. Count referenced persistent roots against this
budget too; structural sharing is not an unbounded-retention license. Evict
unpinned sources first. If even the selected source cannot fit, show source
unavailable/evicted and its metadata; never substitute live text silently.

Keep parser/queue and request/partial-frame guards covered as consumers are
added; add a maximum tree depth and measured rendering guards in DBG-3.
A background fiber alone does not make CPU-heavy JSON parsing or large string
rendering nonblocking.

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

Production gates below remain **planned / not executed** for the editor
debugger. DBG-0 has executed its narrower harness falsifiers and D13 real
compiler controls; those do not certify the proposed Crystal transport,
session reducer, UI, native formatters, or inferior terminal.

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

Original planning checks: `git diff --cached --check` found no whitespace errors; the
local Markdown link/whitespace validator passed 43 links across these three
documents, with present/missing-path controls. Nine existing spec-file anchors
were checked for presence. The bounded adversarial review reached **ROBUST for
proposed design/plan alignment only** after the resource, resume, source-cache,
approval-ordering, language-release and modal-key gaps were closed in the
documents. No compiler build, DAP session, debugger spec or inferior PTY gate
was executed during that planning slice. Those document checks did not advance
any runtime admission gate.

### DBG-0 compatibility evidence (2026-10-03)

The [probe harness](../scripts/lib/debugger_probe.rb),
[fake-peer tests](../scripts/test_debugger_probe.rb), and
[fixtures](../spec/fixtures/debugger/control.cr) execute a bounded real DAP
sequence against owned temporary binaries. No compiler source build, formatter
import, expression evaluation, installation, editor runtime change, or model
API request is part of this gate. Temporary fixture binaries and the explicit
private compiler-cache directories are removed. The adapter has a private cwd
and skips `.lldbinit`, but still inherits ambient HOME/XDG; no general claim of
adapter cache-write isolation is made.

| Target | Compilation | Source breakpoint | Integer/known record child | Exact source step | Exit/disconnect | Admission |
| --- | --- | --- | --- | --- | --- | --- |
| C / clang 22.1.8 | exit 0 | verified line 37 | `271828`, `value = 31` | line 38, same thread | target 0, clean adapter 0 | reference core PASS |
| Crystal 1.21.0 | exit 0 | verified line 24 | `271828`, `value = 31` | line 25, same thread | target 0, clean adapter 0 | this language/toolchain core PASS |
| Adamas 0.1.0-dev, prebuilt | exit 0 | line 24 unverified | not reached | not reached | bounded owned-process cleanup | NOT ADMITTED |

The Adamas binary's provenance is unknown and its `--help` exposes none of
the requested flags. The invocation follows the separately inspected current
CLI source, not an assertion of that binary's ancestry. A separate bounded
LLDB check also found no resolved source breakpoint and no adjacent `.dSYM`;
this does not establish the compiler-side root cause or certify current dirty
Adamas HEAD. No Adamas source or binary was changed. Its tracked/untracked
status and the CLI/backend/compiler-binary fingerprints matched the pre-run
guard after verification.

Native values remain a separate frontier. C exposed indexed `[22,44]` children;
Crystal did not expose the required indexed Array shape. Crystal core PASS
therefore certifies only the known scalar/record/control route, not Array,
String, nullable/union semantics or a native formatter. Shadowed/out-of-scope
presence and all other captured values are observations, not certificates.

Host prerequisite: the Homebrew LLDB route could not locate `debugserver`
without an explicit override. With the existing CommandLineTools stub selected,
a sandboxed C attempt timed out before `initialized`; the successful runs used
scoped outside-sandbox permission only for these private fixtures. No tools
were installed and no system settings or foreign-process attachment changed.
The explicit override is documented by
[LLDB's debugserver launcher](https://lldb.llvm.org/cpp_reference/ProcessGDBRemote_8cpp_source.html).

Reproduction on this inspected macOS/arm64 host (requires permission to launch
only the temporary debuggees):

```sh
LLDB_DEBUGSERVER_PATH=/Library/Developer/CommandLineTools/Library/PrivateFrameworks/LLDB.framework/Resources/debugserver \
scripts/probe_debugger_controls.sh \
  --adapter /Users/sergey/.local/bin/lldb-dap \
  --cc /opt/homebrew/opt/llvm/bin/clang \
  --crystal-bin /opt/homebrew/bin/crystal \
  --adamas-bin /Users/sergey/Projects/Adamas/adamas/bin/adamas \
  --step-timeout 5 --process-timeout 45 --require-language
```

Observed command exit: **0**, because C and one target language passed;
Adamas remains a separate failed result. `--require-language` does not require
both languages. The script prints bounded per-target JSON, tool identities,
requested/resolved breakpoints, step results, value observations, output
excerpts and cleanup outcomes, rather than converting compilation into PASS.

Reproducibility seal (SHA-256):

| Input | Digest |
| --- | --- |
| `scripts/lib/debugger_probe.rb` | `5845177b5a7efc4fe0822bc8424a4e94311d53b1185d1717899447017490abb1` |
| `scripts/test_debugger_probe.rb` | `7fb0ee06f16e6ae5ccffdb07d9ce4143779fb42073ba81d9c9453d1a16ce94b2` |
| `fake_dap_adapter.rb` | `371310c71c586f6d9fdf9bfaead6b096b8089ac369de977c4b53882a9c300742` |
| `control.c` | `348da74e1e5d9aa6cfe6826e6ea30f0f041f495a44e35883649d8d94ee98f090` |
| `control.cr`, `adamas_locals.cr` (identical contents) | `d0783682d8975c445b576ea1ea1e8cc254dfee842c6dead9a975c391efdf3321` |
| LLDB-DAP wrapper `/Users/sergey/.local/bin/lldb-dap` | `6d2c1f5b3f509acebd37042270e44bb09c2e5e5936fcb45e4fc7ebc8e2abeb92` |
| Backing `/opt/homebrew/opt/llvm/bin/lldb-dap` 22.1.8 | `f983337ddb6403631bf4bbf68aeb149de3289c1b2dee2617650dbd2715b5aa1f` |
| Selected CommandLineTools `debugserver` | `cf1300df4aed1dd2c4fe268d1f3eea8f9ba32734fa5d0a5a12367066faebb302` |
| clang 22.1.8 | `305697d3868243dca6e4aabf4f628df7de135d701eb4fd78f6a5d7528fef4395` |
| Crystal 1.21.0 | `40cffa1b29b572c064b4a397c6b82c7a84c55a146685d0971dab816f855eb836` |
| Prebuilt Adamas | `a52b7d92e4fcdb2d997d382710d5352b364b6cb3a93623d5bb581c95a1c58bcf` |

Parent checks ran Ruby syntax, shell syntax/help, Crystal fixture formatting,
and `ruby scripts/test_debugger_probe.rb`: **17 runs, 223 assertions, no
failures/errors/skips**. Seeded wrong-source/frame/locals/children, malformed
framing/correlation, output/reverse floods, timeouts and owned-child cleanup
fail closed. Legitimate metadata bursts, a fragmented observation before
Continue, and `exited -> terminated -> disconnect` pass. A buffered premature
exit or premature/duplicate termination fails. Ordering proves local receipt
relative to the request write, not the peer's unobservable emission time.
An exit emitted after the local drain, but before the peer consumes Continue,
cannot be distinguished causally by this protocol transcript; the probe does
not certify rejection of every possible delayed stale exit.
The harness bounds headers/messages, aggregate protocol bytes/count, pending
requests/queues, diagnostic retention, child expansion and process deadlines.
Explicit aggregate probes reject a 257-notification burst and five valid
900,000-byte frames at the total-message/traffic caps, not the reverse-request
or individual-message caps.

The bounded same-lineage hostile review returned **ROBUST for the documented
local-receipt guard and evidence/claim alignment** after the termination,
fragmentation and aggregate-budget counterexamples were covered. This is
correlated review, not independent certification of the adapter or compiler;
the parent separately executed the real C/Crystal/Adamas command above.

These results decay on any harness/fixture/tool/wrapper/stub change, host
permission/platform change, or target optimization/debug configuration change.
Refresh syntax/fake checks and the real command above; an unavailable or failed
target stays unadmitted. No editor build/spec/PTY suite was run for this slice,
because it changes only the probe, fixtures and documentation. A real editor
debugging release still requires DBG-1, DBG-2 and DBG-3.

### DBG-1 client/state foundation evidence (2026-10-03)

Implemented [protocol](../src/adamantine/dap/protocol.cr),
[owned transport](../src/adamantine/dap/transport.cr),
[asynchronous client](../src/adamantine/dap/client.cr) and
[pure session reducer](../src/adamantine/debug_session_state.cr). Construction
is inert. Explicit start owns one stdio adapter process, not a target PID.
Client tickets use fresh per-client identity; generic requests cannot bypass
the serialized execution slot. Local encoding rejection does not consume an
outgoing sequence. Partial-stop thread lists reconcile membership without
promoting newly listed threads to Stopped absent all-stop evidence.

Parent verification used Crystal 1.21.0, a private writable cache and TUI
revision `7ca26fd559cf8c05e5b4ed924e7c691fabb66e43` verified by `rev-parse`:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-dbg1.LUWUz6/cache \
CRYSTAL_PATH=/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:/opt/homebrew/Cellar/crystal/1.21.0/share/crystal/src \
crystal spec spec/dap_protocol_adversary_spec.cr \
  spec/dap_transport_adversary_spec.cr spec/dap_session_ordering_spec.cr \
  spec/dap_stale_handle_spec.cr spec/dap_resource_limits_spec.cr \
  --link-flags=-fuse-ld=/usr/bin/ld --error-trace
```

The same five-spec runner passed **76 examples, no failures/errors/pending**
twice after the final correction. The full tracked editor spec list plus those
five new specs passed **1,224 examples, no failures/errors/pending**. Guard-only
DBG-2 model files were excluded from that foundation gate. Ruby syntax for both
new adapter fixtures, Crystal formatting and diff whitespace checks passed.
The existing App release build passed against the same pin; it does not yet
import the debugger and is not debugger UI evidence.

The strongest discovered counterexamples were foreign-client tickets, mutation
through the generic request method, abandoned actual writer IO helpers,
semantic client failure without process cleanup, a lost pending ticket at
tombstone saturation, absent threads retaining inspection authority, and a
local rejected encode consuming an outgoing sequence. Regression tests now
cover those boundaries. An independent parent repeat exposed a test readiness
race: the fake peer acknowledged initialize before closing stdin, and the
assertion deadline equaled the writer deadline. A new readiness assertion was
red against that fixture. The corrected peer closes stdin and publishes a
marker before acknowledging; the assertion waits `WRITE_DEADLINE + 1s`.
The producer ran that case ten times; the parent reran the complete group twice
and the full suite afterward. The proportionate review returned **ROBUST within
these transport/reducer boundaries** after the discovered counterexamples were
closed. Same-lineage review remains correlated; it is not a compatibility
certificate for arbitrary adapters or compilers.

Resource probes admit two retained legal 15 MiB frames below the 32 MiB wire
cap, then reject a third; separately they saturate 64 MiB decoded credits and
128 items. Ordered `stopped` events are retained below saturation, not silently
dropped. Fragmented partial bytes remain charged until consumption. A no-read
peer exercises active/queued writer caps and bounded cleanup; the owned adapter
is reaped while an unrelated sentinel remains alive. Actual helper count and
credits reach zero before the tested `retired?` claim. These are logical-credit
and ownership tests, not portable RSS or UI-latency bounds. Host RSS timing
instrumentation was unavailable under the sandbox; no RSS result is inferred.

Separately, the parent compiled a temporary probe using the actual new Client,
started only `/Users/sergey/.local/bin/lldb-dap --no-lldbinit` in its private
cwd, initialized with a three-second request deadline, polled for at most four
seconds and ensured close. It reported successful initialize, six-millisecond
close, `owned_adapter_alive=false`, `actors_retired=true` at the final production
source state. No target was launched by that probe. Wrapper/backing-tool hashes
matched the DBG-0 seal. This proves that the new library accepts that real
initialize envelope and retires its adapter; it does not repeat the Crystal
launch/locals evidence through a controller or App.

SHA-256 source seal:

| Input | Digest |
| --- | --- |
| `dap/protocol.cr` | `273e9efa9849cb4ca35d3154b6f36ce33c5334a2be7f848318ff28fcac64db1c` |
| `dap/transport.cr` | `cf8d4e85e4499b36a4e97df791ab0f6f07f73dfdaf92d543b17916f8d553fd48` |
| `dap/client.cr` | `e8fe7ebcffd40d780e15055ac46133ef8daba66bed7dadafc55fd9daa261b85b` |
| `debug_session_state.cr` | `7367c8b1657de0d535fdd76ab5b37364aa18247e536d27c443df5938ddaa95bf` |
| `dap_transport_adversary_spec.cr` | `416a76c2619c8a7e5d23f8fc9d651fade5c7790c71653835b233184422c63be5` |
| `dap_scripted_adapter.rb` | `d9ca291b9f8f53a5bcf3ecb486a7eb461d5a565dcaa9d92352e45536efaa8084` |
| `dap_resource_limits_spec.cr` | `4a654238903600e8a06a8b4c8730ea3a68b3b69ef405e129bf821f47b56fc3ee` |
| `dap_resource_adapter.rb` | `85bee1f66fe335c736b43db7b728e402fd867fa6b2e32a4e6d5f55db4bb977a4` |

Consumption boundary: the next controller must abort outstanding UI reads on
terminal session failure; explicit close releases events and unconsumed
response-backed results rather than guaranteeing their delivery afterward.
Polling consumes a result at most once. Resume handles must retire before
wire dispatch; the reducer's local request IDs are not DAP sequences. Timeout
or adapter cleanup does not prove target exit. No panel, default-key migration,
manual watch consumer, source navigation or model tools are admitted here.

Refresh the five-spec/full/build gates after source, fixture, pin or compiler
changes; refresh the real initialize probe after client/adapter/wrapper/platform
changes. Reopen only the affected claims on failure. DBG-2/3 still requires real
Crystal or Adamas launch/step/locals/children plus workspace/modal evidence.

### DBG-2 inert model preparation (2026-10-03)

The separate [profile store](../src/adamantine/debug_profile_store.cr),
[source store](../src/adamantine/debug_source_store.cr),
[source resolver](../src/adamantine/debug_source_resolver.cr) and
[breakpoint store](../src/adamantine/debug_breakpoint_store.cr) now exist as
inert data models. This preparation does not admit the App launch workspace
or variable consumer. Their constructors and profile inspection do not start
an adapter, build a target or evaluate code.

The parent independently ran:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-dbg1.LUWUz6/cache \
CRYSTAL_PATH=/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:/opt/homebrew/Cellar/crystal/1.21.0/share/crystal/src \
crystal spec spec/debug_profile_store_spec.cr \
  spec/debug_source_resolution_spec.cr spec/debug_breakpoint_reconcile_spec.cr \
  --link-flags=-fuse-ld=/usr/bin/ld --error-trace
```

Observed: **21 examples, no failures/errors/pending**, formatting and diff
checks passed. The counterexamples that were red before correction were a
positive source reference losing to an existing disk path, foreign-session
breakpoint source keys being accepted, and edits losing their visible Outdated
barrier after a later toggle. These now have regression tests. Positive
references retain a session-only key and display-only path metadata, never
editable local identity or checksum evidence inferred from local bytes.
Source byte accounting no longer copies text, repeated same-reason outdated
marking reuses the immutable snapshot, and position conversion scans to one
requested line rather than creating an array of all source lines. Those are
structural and functional checks, not measured RSS or latency claims.

The model review is **ROBUST within these inert model boundaries**. Private
allowlisted state replacement, malformed/oversized/symlinked state, canonical
mapping ambiguity, Unicode coordinates, logical source retention and
breakpoint generations were exercised. Controller composition, save/quit/root
transactions, gutter projection and real adapter retrieval remain separately
unadmitted until DBG-2/3 acceptance.

SHA-256 source seal:

| Input | Digest |
| --- | --- |
| `debug_profile_store.cr` | `e50617ed814a8aebed9b24f63f6a6fd926e3e40c0d6a065c6da6f135be458b55` |
| `debug_source_store.cr` | `a2e3fb451643875b1779f56249fb453225bd188b475608aa3afb1a003703e810` |
| `debug_source_resolver.cr` | `5104ef7ce53ac2f19ca037badfaf27fda9215c3a15c257600ea8f28ddf129fe4` |
| `debug_breakpoint_store.cr` | `b76f6c0c8bdef01ab8620be93a16c15bf07b6f6c4b4282708b1b6a1093d56078` |
| `debug_profile_store_spec.cr` | `5b9052604a0d3337b68adbb91df7b9c3276d4e1b0594e882db465774d95540f5` |
| `debug_source_resolution_spec.cr` | `45a275a08919b0fe40de57946f2bec61957cf51796730aa5bd160b29caec7669` |
| `debug_breakpoint_reconcile_spec.cr` | `7421123cd221855e69297583e0262833a6c6e7f0139b204bc49b972d4cb00325` |

Refresh this focused gate after any model/spec/compiler change. Session source
keys and adapter IDs must not become persistent project state; editable source
changes do not authorize breakpoint resubmission against the old binary.

### DBG-2/3 controller runtime subgate (2026-10-04 UTC)

The UI-agnostic [controller](../src/adamantine/debug_controller.cr),
[lazy variable tree](../src/adamantine/debug_variable_tree.cr) and
[value detail](../src/adamantine/debug_value_detail.cr) now compose the bounded
DAP client with the session, source and breakpoint models. Preparing a launch
is inert. Only explicit Start consumes a single-use, owner/project-bound review
and creates the owned adapter; executable/cwd validity is rechecked at that
boundary. There is no build, shell, attach, terminal or automatic evaluation.

The parent independently ran the following at the source state sealed below:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-dbg1.LUWUz6/cache \
CRYSTAL_PATH=/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:/opt/homebrew/Cellar/crystal/1.21.0/share/crystal/src \
crystal spec spec/debug_source_resolution_spec.cr spec/debug_profile_store_spec.cr \
  spec/dap_transport_adversary_spec.cr spec/debug_source_snapshot_coordinates_spec.cr \
  spec/debug_variable_limits_spec.cr spec/dap_resource_limits_spec.cr \
  spec/dap_protocol_adversary_spec.cr spec/debug_watch_safety_spec.cr \
  spec/dap_stale_handle_spec.cr spec/debug_controller_integration_spec.cr \
  spec/debug_breakpoint_reconcile_spec.cr spec/debug_value_detail_spec.cr \
  spec/debug_thread_lifecycle_spec.cr spec/debug_ownership_spec.cr \
  spec/dap_session_ordering_spec.cr spec/debug_value_format_consumer_spec.cr \
  --link-flags=-fuse-ld=/usr/bin/ld --error-trace
```

Observed: **156 examples, no failures/errors/pending**, in 20.85 seconds.
The owned Crystal files passed `crystal tool format --check`. Crystal 1.21
reports deprecation warnings for `Time.monotonic`; that API retains the declared
older Crystal compatibility and these warnings are not test failures.

Discriminating counterexamples and their guarded boundaries:

- Initialization/configuration waits for both exception-filter and the newest
  full breakpoint-set replies. A held/replaced set and stop-before-launch-ACK
  no longer lose the first stack or finish configuration too early.
- Mandatory configuration failure, rejected Disconnect and Stop during a
  stalled execution request end visibly with Unknown execution and bounded
  owned-adapter cleanup, rather than remaining in Configuring/Stopping.
  A rejected source breakpoint remains a visible row; it does not abort an
  otherwise valid session. Pause acknowledgment alone is not a stopped event.
- Successful Disconnect ends the session but does not prove target exit.
  Repeated Start/Stop retires each owned client. The singular adapter capability
  `supportTerminateDebuggee` gates the DAP terminate flag; no adapter-reported
  process ID becomes kill authority.
- Exited-thread membership retires inspection handles but does not imply
  process exit. Old success and failure watch responses cannot replace a newer
  Pending watch or its current error. Adding/rendering watches sends no evaluate;
  manual evaluation is bound to the current selected stopped frame.
- Unknown/ignored paging, cyclic/deep values, scope clipping, invalid UTF-8 and
  no-progress pages remain bounded and visibly Partial/Unavailable. An exact
  full default page with unknown total remains Partial with a next-page action,
  rather than falsely Complete. ESC replacement expansion exposes clipping.
- Explicit Hex consumes the exact originating page/offset and immutable child
  metadata, not a name-only lookup. Missing capability sends no request;
  changed-child, stale success and stale failure cannot publish a value or
  replace current diagnostics. Rendering sends no requests. A held ordinary
  sibling page retires pending Hex with an honest local refresh/retry reason;
  a new user action is required after its bounded old ticket is consumed.
- Complete, unchanged returned text is required for local JSON interpretation:
  a clipped valid prefix and sanitized controls cannot certify complete JSON.
  The interpretation remains labeled local display, not target serialization.
  Raw fields mean adapter-supplied structure, not memory reads or a generic
  DAP raw-value field.
- Frame coordinate conversion copies only the retained requested line. Tests
  forbid the whole-source text getter, including a late line in a large source.
  Source edits mark the baseline and breakpoint rows Outdated before precision
  can be reused; they do not authorize resubmission against an old binary.
  Current stack SHA256 reports certify only existing local launch baselines;
  mismatching digests remain Mismatch, adapter-source references gain no local
  identity certificate, and checksum reports cannot clear an edited barrier.

The separate real-binary consumer probe was built with:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-dbg1.LUWUz6/cache \
CRYSTAL_PATH=/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:/opt/homebrew/Cellar/crystal/1.21.0/share/crystal/src \
crystal build scripts/probe_debug_controller.cr \
  -o /private/tmp/adamantine-real-controller.UMtq6I/controller-probe \
  --link-flags=-fuse-ld=/usr/bin/ld --error-trace

LLDB_DEBUGSERVER_PATH=/Library/Developer/CommandLineTools/Library/PrivateFrameworks/LLDB.framework/Resources/debugserver \
/private/tmp/adamantine-real-controller.UMtq6I/controller-probe \
  --adapter /Users/sergey/.local/bin/lldb-dap \
  --program /private/tmp/adamantine-real-controller.UMtq6I/crystal-control \
  --cwd /private/tmp/adamantine-real-controller.UMtq6I \
  --source "$PWD/spec/fixtures/debugger/control.cr" --project-root "$PWD" --require-hex
```

The fixture was already compiled with stock Crystal 1.21/LLVM 22 for arm64
Darwin, debug information and the explicit system linker. The existing adapter
wrapper resolves to Homebrew LLDB-DAP 22.1.8; no tools were installed. With
scoped permission to run only this owned fixture/adapter outside the sandbox,
the final probe **exited 0**: verified breakpoint at DAP line 24, primitive
`271828`, explicit adapter-provided Hex `0x000425d4`, record child `31` (adapter
text `0x0000001f`), exact step to line 25, actual exited event with code 0 and
complete owned-adapter retirement. Ordinary variable pages had settled before
the explicit Hex request. LLDB retained hexadecimal presentation for the later
child; the editor preserves that text instead of converting it. Numeric parsing
in the probe is only the known-fixture oracle. The session source checksum
remained **Unverified**; breakpoint acceptance is not binary/source identity.

Rejected probe explanations are retained for reproducibility. The default
sandbox timed out before the first breakpoint; rerunning the same binary/env
outside it reached the stop, isolating the host launch restriction. A later
locals condition timed out because the probe expected `nested_outer` instead
of the fixture's `debugger_nested_outer`; correcting only that probe expectation
made that path pass. Requesting Hex while an unrelated ordinary page was still
loading retired the selected detail by its global inspection generation;
settling those pages separated that race from missing adapter support. The
sibling-page regression now requires an honest explicit-retry message without
relaxing stale-value rejection. After Hex, a decimal-only child oracle rejected
LLDB's native `0x0000001f`; accepting the known fixture number in either returned
notation completed the probe without changing display semantics. None of these
results authorized longer deadlines, implicit refetch or local value conversion.

The subgate verdict is **ROBUST for these controller/model boundaries** from
the parent-run tests and real consumer probe, not model agreement. At this
controller checkpoint, App row actions, truthful current-stop versus
historical-frame markers, read-only adapter-source display, shared-view
projection, dirty launch and staged quit/root switching still required their
own gates; the subsequent App admission below records that evidence. Adamas,
native String/Array/union formatting, attach and inferior terminal remain
unadmitted. No RSS/latency claim follows from the source-copy tests.

Runtime SHA-256 seal:

| Input | Digest |
| --- | --- |
| `dap/client.cr` | `debdbb7129333b20f00b3f8af60654abf6da7b5de20060eae05e31a428a6c3eb` |
| `debug_session_state.cr` | `de7d5b06d10bf79ae376e8563249d2d475c078aeb4bf6b72d93421c4f6d41bfd` |
| `debug_source_store.cr` | `e9afbd2c345e04db324363e11d04a93dee6ee8d57aac1a2c6842fca2ce5ea528` |
| `debug_source_resolver.cr` | `c56cbaa913387821dceee342bd4e658b132d0f0e29137636257e2f33c3b46413` |
| `debug_controller.cr` | `394b33d03ad1801ab7fb03915379d3e33e73a2ae5a3611f92d4533b9a6895df1` |
| `debug_variable_tree.cr` | `8459350c0712676800016397debe49191e2b0896ba6f61a3ded51acea357fc82` |
| `debug_value_detail.cr` | `95819c0fc9cf7a78d2b2870f3c7f8426fb5a91a4222821fbe0c1f9842a63951e` |
| `debug_controller_integration_spec.cr` | `425b25594c1f3ef5ce0843e617c371596ce50ada02bf0e7e646efbee15018bdd` |
| `debug_value_format_consumer_spec.cr` | `36e1c6556eab8e57a9b1be47b462b41ae6c890660878a5dc3cceea390b921e3d` |
| `debug_value_detail_spec.cr` | `b28f7f93689aca56b7acdbec10bdd1630cf5db7f1249a48e76bb57bf66052ba8` |
| `debug_variable_limits_spec.cr` | `f47b4bc2f11c2def0dc0d436506d05a5d5fb10763cc51b92715c9a30ea5f6e44` |
| controller adapter fixture | `b816ca4a47a0ae8406cd85863a6c8ce4efa5d9d409b23cd3790217e1c3963abf` |
| `probe_debug_controller.cr` | `d4df36d40f8fea1dcc221887aebd3986b6505e0baada9a8ee1daf49cadd23829` |
| built controller probe | `5802aacf3dbae434dd5e3723b126bbdeb3f1d7a004d547c2ee1aea843b9ec9a2` |
| built Crystal fixture | `fa4a588237ed4f3ac5fe0620f5b9a5123f484cecc4da71c17e328833f9179cc0` |
| `control.cr` fixture | `d0783682d8975c445b576ea1ea1e8cc254dfee842c6dead9a975c391efdf3321` |
| existing adapter wrapper | `6d2c1f5b3f509acebd37042270e44bb09c2e5e5936fcb45e4fc7ebc8e2abeb92` |
| Homebrew `lldb-dap` | `f983337ddb6403631bf4bbf68aeb149de3289c1b2dee2617650dbd2715b5aa1f` |

Refresh the focused gate after runtime/model/spec/fixture/compiler changes;
refresh the real probe after controller/client/source/probe/target/adapter,
wrapper or platform changes. New App consumers must independently preserve
generation and ownership contracts. Failed evidence reopens only its affected
claims. Rollback is the local runtime-slice commit, not user configuration,
editor buffers or the unrelated user-owned Makefile.

### DBG-2/3 App composition admission (2026-10-04 UTC)

Lineage: this UI slice composes the frozen controller/runtime commit
`004c146`. Runtime, adapter fixture and real-controller probe sources were
unchanged during final UI verification. The parent verified Crystal 1.21.0,
arm64 Darwin 25.6, and a clean private TUI checkout at the exact lock pin
`7ca26fd559cf8c05e5b4ed924e7c691fabb66e43`; installed `lib/tui` was not used
as pin authority. No dependency, compiler, user configuration or Makefile
change was included in this slice.

The parent executed the following final commands against the sealed sources:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-dbg1.LUWUz6/cache \
CRYSTAL_PATH=/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:/opt/homebrew/Cellar/crystal/1.21.0/share/crystal/src \
crystal spec --link-flags=-fuse-ld=/usr/bin/ld --error-trace

CRYSTAL_CACHE_DIR=/private/tmp/adamantine-dbg23-final.iS02MM/cache \
CRYSTAL_PATH=/private/tmp/adamantine-dbg1.LUWUz6/tui/src:$PWD/lib:/opt/homebrew/Cellar/crystal/1.21.0/share/crystal/src \
crystal build src/adamantine.cr --release \
  -o /private/tmp/adamantine-dbg23-final.iS02MM/adamantine \
  --link-flags=-fuse-ld=/usr/bin/ld --error-trace

ruby -c scripts/smoke_debugger_session.rb
ruby scripts/smoke_debugger_session.rb --self-check
ruby scripts/smoke_debugger_session.rb --fake-adapter \
  --editor-bin /private/tmp/adamantine-dbg23-final.iS02MM/adamantine
```

Observed: **1,354 examples, zero failures/errors/pending**, in 1:41 minutes;
release build exit 0, Ruby syntax and screen-model self-check PASS, and actual App/PTY PASS under
the unchanged default 45-second deadline. All 28 changed Crystal paths passed
`crystal tool format --check`; keymap JSON parsing and `git diff --check`
passed. The release build reported seven `Time.monotonic` deprecation warnings,
not failures. No RSS, latency or general terminal-compatibility claim follows.

Behavioral evidence and its precise consumers:

- Headless App specs cover accepted-Start dock focus, pure asynchronous
  projection, Escape returning focus, Tab/Shift+Tab pane routing and text/paste
  not editing the document behind the dock. Selection follows node identity;
  viewport scrolling moves only when selection crosses a visible edge.
- Profile setup/review starts no adapter. The final approval shows literal JSON
  argv and retains saved profile identity/source maps. Manual Watch evaluation
  requires its visible warning and sends the exact expression once for the
  selected frame; adding/rendering/canceling sends no `evaluate`.
- Dirty launch, Quit and root-change specs retain Cancel authority, stage Stop
  approval and wait for owned-adapter retirement. An edit during held Stop
  invalidates the earlier dirty approval. Root changes retain open tabs, and
  normal/narrow review copy distinguishes Save from continuing without saving.
- Shared-view specs distinguish the top stopped frame (`▶`) from a selected
  historical caller (`◇`). Precision requires a matching, unchanged local
  launch baseline; an edit suppresses it in every view. Only enabled accepted
  breakpoints are solid `●`; other states are muted `o`. Gutter tests preserve
  independent execution styles, fold/debug/Git lanes, hidden line numbers,
  clipping and breakpoint mouse hits. These split/mismatch assertions are
  headless tests, not claims of PTY coverage for those cases.
- Wide header render and mouse hits use one compact-label extent map, avoiding
  adjacent-tab capture. Every projection rebinds the current view's gutter
  callback: cached object IDs are only bounded live-view accounting, never
  callback authority. A regression pre-seeds a reopened view's ID, clicks its
  breakpoint lane, and checks creation plus retained counts `2 -> 1 -> 2 -> 1`.
- Effective debugger bindings feed Help, startup hints and footer slots.
  Physical-key and footer-click specs agree after remap/unbind and respect
  modal capture. A residual discovery gap is that some modal-only actions
  remapped to function keys have no footer label; dispatch still follows the
  normal router. The DAP message cap is config-only, 1-64 MiB/default 16,
  sampled at next Start, with unrelated settings preserved.
- The real App/PTY starts only after alternate-screen/Kitty/raw readiness,
  captures F9 during review, then sends an actual source/line breakpoint.
  It projects Stack, explicitly loads scopes and displays `271828` plus child
  `31`, clears the current Loading row, hides/reopens the dock, resizes
  `38x14 -> 112x26` with known Unicode source glyphs, and exercises two explicit
  Starts, held Stop/Quit cleanup, fixture start/exit markers and orderly exit.
  PASS is emitted only after the output drain reaches EOF and rejects parser
  errors, including a truncated final sequence.

The PTY oracle is a bounded current-grid model for the fixture's known Unicode
widths, not a general terminal emulator or cursor-style/focus proof. Focus is
asserted separately in headless App tests. Historical raw text, arbitrary read
chunk UTF-8 validity, and assumptions about cursor/viewport position were
rejected as oracles; they did not establish production bugs. Missing-method
compilation errors are not behavioral red-first evidence.

The scoped verdict is **ROBUST** from parent-executed gates and attacked
marker/header/callback/authority/cleanup boundaries. Same-lineage Luna review
is correlated supporting inspection, not independent agreement. The real
stock-Crystal controller evidence above remains separate: a full App plus
real-target run was not executed, and LLDB's source checksum remained
Unverified. No Adamas, native String/Array/union summaries, attach, inferior
input, chat, border redesign or Lua scripting is admitted here.

UI SHA-256 seal (remaining paths are identified by the resulting UI commit):

| Input | Digest |
| --- | --- |
| `app.cr` | `17b6434ce50b6e1d430529f8a2c6e2d2d2aa54c469fb4ffc218953030dc77e18` |
| `debug_ui_controller.cr` | `fc42026ae844eaef9c9f55b3b96b5995b7606cb5144bb1f341231ddb6dd4ea86` |
| `debug_panel.cr` | `dbb4937ddbe9c7310e828c1f64ed2bd0d1bf1a3e4c6d489c50a72e1ab9ac8399` |
| `debug_workspace.cr` | `9ec9d46237275a173b73c17058ea1d1abfd2540306563b654c358c5f0dd675b2` |
| `editing_text_editor_unicode.cr` | `ff7a6b47359b5d88e4e8092b8a0002751e7b7f481d6aba9d0c38fa7877b6bcef` |
| `close_confirmation_controller.cr` | `72771b6a8469be93145292bed96e730e7b9df4a893ec2ce28c077d268fda3dc0` |
| `key_config.cr` | `6eba93c1e6f3aef36b0f0843a7fde550f4093f0e1aedc836de3717a2b59744b8` |
| `settings_config.cr` | `f0ffba5b7687f15c17f0f6152495344adda4e95cb96a327a8c6c3ce668b65364` |
| `debug_editor_integration_spec.cr` | `0c7e6ab18a4cb3568869a516cca5cc9d90f3e3ca80cae7fb9b29be5161666354` |
| `debug_gutter_spec.cr` | `5eff6686dada098042edf37ca3667578df48b58b266fc113316ca4bbf916b8aa` |
| `debug_app_safety_spec.cr` | `b7c30c3401025a9db97594afede0c02993fdf5edf0e266ad0a728b955a6ef20f` |
| `debug_ui_authority_spec.cr` | `4dd79848686c636643fa3b8fed0bbb0996a80a48687fae250668aff63f3cff88` |
| `debug_footer_spec.cr` | `59af24437caf32369dd87f7a3d18552f783c322134fa2f3b4d198234ff58d3d4` |
| `smoke_debugger_session.rb` | `0d490183448e3418214d50381f6a666992ee7d69ada732533aa0a2ded752b907` |
| built release editor | `5f4d81e43676475c32456852a6c453f64471d0426a85852abf38cdf08e82a2de` |

UI evidence decays after relevant App/panel/router/keymap/source-view/spec,
fixture, config, TUI pin, compiler or terminal-platform changes. Refresh the
full suite, release build, format/model checks and actual PTY gate; refresh the
real-controller probe separately on its declared runtime/tool/target changes.
Reopen only affected claims on failure. Rollback is the local UI slice commit,
preserving buffers, private user configuration and the unrelated Makefile.
