# Architecture

Adamantine has one owner process for its terminal UI and documents, with
separate optional protocol/interpreter children. It is built alongside the
Adamas compiler. Its language-facing features remain LSP-driven rather than tied to a
single compiler. The UI is built on
[`crystal_tui`](https://github.com/skuznetsov/crystal_tui); the entry point in
`src/adamantine.cr` parses CLI options and starts `Adamantine::App`.

## Main boundaries

- `App` owns the widget tree and composes the editor's controllers.
- `DocumentSession` is the source of truth for open buffers.
- `DocumentOrchestrator` manages file lifecycle, tabs, document/LSP sync, and
  resolution of external file conflicts.
- `FileRevision` obtains stable metadata and streaming SHA-256 snapshots;
  `ExternalFileMonitor` is the single cooperative poller for all open buffers.
- `RecoveryStore` owns private, bounded draft checkpoints and abandoned-session
  locks. `RecoveryController` schedules checkpoints and offers explicit recovery
  copies; it has no authority to overwrite a draft's original source path.
- `InputModeController` and `InputRouter` decide which surface owns each key.
- `ModalManager` and the small `*_state.cr` types keep overlays explicit.
- `CommandPalette`, `SearchPanel`, and `NavigationController` implement
  user-facing workflows without owning documents. `SearchPanel` schedules
  debounced project and large-buffer scans and owns their publication guards.
- `BufferSearch` reads immutable piece-tree roots through bounded chunks.
  `EditingTextEditor` exposes the read source; live find and repeat search share
  the matcher without materializing the document or its logical lines.
- `Lsp::Client` owns JSON-RPC transport; `LspController` translates protocol
  results into editor behavior.
- `EditorTools::Host` issues bounded, capability-scoped local sessions.
  `EditorToolsController` binds their typed requests to App-owned documents,
  guarded navigation and inert debugger inspection. Chat and local Lua
  consumers share this boundary rather than receiving the App or DAP client.
- `Chat::Frontend` owns bounded in-memory turns and queues typed transport
  events for App-owner draining. The bottom Chat / Log surface owns a separate
  multiline composer, not the active code buffer. `Chat::ProviderTransport`
  handles explicitly reviewed streaming Chat Completions requests; transport
  injection remains a local test seam. Settings contain a credential name,
  never its value.
- `ChatEditController` stages source-bound edit plans and publishes them to the
  existing inline review only after successful turn completion. Its host-owned
  receipt is separate from a tool invocation permit; manual acceptance checks
  the source, view, root, provider and turn again, then applies one Undo batch
  without saving.
- `LuaScripts::Catalog` freezes explicitly listed user scripts and built-ins;
  `LuaScripts::Runner` owns one fresh, bounded Lua 5.4 child per reviewed run.
  `LuaScriptController` dispatches queued tool calls on the App owner and keeps
  each run's proposal receipt separate from Chat. The child has no App/session
  reference, and successful completion requires exit/reap and drained pipes.
- `Theme`, `KeyConfig`, `LanguageRegistry`, and `LspRegistry` contain policy
  that can be tested without running the terminal UI.

## Event flow

```text
terminal event
    -> crystal_tui
    -> App#on_capture
    -> active modal/input mode
    -> configured action or focused widget
    -> document/navigation/LSP controller
    -> widget state + status log
```

Input modes are stacked. The topmost modal gets the first chance to consume an
event, which prevents menu shortcuts from leaking into search or command text.
Closing a modal restores the previous mode rather than guessing which widget
should become active.

## Documents and LSP

Each open buffer associates a path, URI, language identifier, version, and
`Tui::TextEditor`. It also retains the last accepted disk revision, a watch
token, and at most one unresolved external revision. Local edits increment the
document version and emit
`textDocument/didChange` when a server is connected. Opening, saving, and
closing follow the matching LSP lifecycle notifications.

The file monitor first compares cheap path and resolved-target metadata. A
changed stamp triggers a bounded, streaming SHA-256 pass. It never mutates the
editor while bytes are being read. Completed external observations are routed
back through `DocumentOrchestrator`, which keeps the in-memory piece-tree root
unchanged until the user chooses reload, keep, or overwrite. Every save performs
a fresh content check immediately before the atomic rename and confirms the
result after it; this catches same-size edits whose modification timestamp was
restored and avoids marking a buffer clean when a competing writer wins during
post-rename validation.

Protocol transport is intentionally separated from UI policy. The client
parses framed JSON-RPC messages and correlates requests; the controller decides
how diagnostics, semantic tokens, locations, completion items, code actions,
and folding ranges appear in the editor.

LSP integration is optional. Startup with no explicit setting attempts
discovery; `--no-lsp` leaves the editor fully local.

## Local assistant and scripting tools

`App#open_tool_session` is a trusted host API. Its default grants allow editor
and debugger observations; navigation requires an explicit additional grant.
The consumer invokes `Session#invoke_json` with a call ID, catalog name and
strictly typed arguments. It cannot supply its own project, grants or transport.
The App's canonical project and opaque lifetime epoch are captured at issuance
and rechecked before execution and result publication. Root changes and
committed quit retire the context; cancelled quit does not.
Each invocation also carries a live `ExecutionPermit`, separate from project
identity. Guarded navigation checks it after yielding reads and immediately
before committing, so session or ancestor cancellation cannot authorize a new
tab merely because the project and path still match.

Buffer IDs and revisions identify live ownership and exact PieceTree state,
including line endings, independently of the LSP version. Reads return bounded
Unicode codepoint fragments from unsaved editor text, not reloaded disk text.
Navigation uses existing guarded file opens and tab activation, and is denied
while a modal owns input. Debug observations expose only retained state and
currently certified stack rows; they do not poll, evaluate or expand variables.
Their retained target-origin directory identity must match the current project;
launch review or editor binding cannot relabel values from an earlier target.

Delegation intersects capabilities, inherits context and shares call/output
quotas. Closing a parent invalidates its descendants. A reviewed Chat turn can
delegate a narrower session to one frozen named Lua script without creating
another authority path. The shared contract alone is not a sandbox or
interpreter. Manually reviewed local scripting has its separate
[LUA-1 frontier](docs/LUA_FRONTIER.md); Chat-to-Lua delegation has its own
[CHAT-LUA-1 frontier](docs/CHAT_LUA_FRONTIER.md). Reviewed
assistant proposals have their own [CHAT-3 frontier](docs/CHAT_EDIT_FRONTIER.md),
not permission inherited from inspection. See
[the shared tools frontier](docs/ASSISTANT_TOOLS_FRONTIER.md) for exact ceilings,
falsifiers and exclusions.

Local Lua execution self-execs a hidden worker with cleared environment,
non-project working directory and a bounded startup frame containing the
already frozen source. Only that child dynamically loads trusted compatible
Lua 5.4; the main editor has no linked Lua dependency. A nonraising allocator
bounds Lua-managed heap, not process RSS. The worker loads text-only source in
an allowlisted environment; `editor.call` yields a bounded request, and only
the App owner invokes its capability-scoped session. At most one outstanding
tool RPC waits for a reply; print output has separate byte/event/queue ceilings
rather than per-output acknowledgements. Parent-owned wall deadline/cancellation
requests termination independently of Lua error handlers, native work or
finalizers. One supervisor owns reaping; bounded shutdown reports cleanup
pending rather than confirming an unobserved exit. Completion and proposal
publication require observed successful exit/reap and drained bounded pipes.
This assumes trusted native interpreter code, not an OS security sandbox.

Lua proposal dispatch uses a private run-bound backend/receipt, never a Chat
approval or shared routing switch. The receipt captures selected source, view,
revision and root at run start. One valid batch remains private until worker
success, then uses the existing manual inline preview and one-Undo commit.
Source/view changes, failed runs and cancellation cannot revive it. Run
liveness also fences yielding navigation before commit; already committed
navigation is not rolled back on later cancellation. Project retirement and
App shutdown retire both the run and session.

Chat-to-Lua uses a one-shot `RunScript` grant, never a default capability or a
manifest permission. The provider sees frozen metadata and an empty-argument
function; the adapter binds the approved ID, not model-supplied source or paths.
The parent reserves the call ID and budget before issuing a deferred ticket.
The App owner completes that exact ticket only for its live turn/session/handle
after child terminal delivery and observed reap. The child receives only the
manifest intersection with selected-buffer read/proposal authority, using the
same scoped backend and cumulative quota as direct Chat calls. Any child
refusal makes outer success impossible. Selected-view/event-version receipts
also guard read-only delegation against edit/Undo ABA. Child proposals remain
private until successful outer result accounting and provider completion; the
existing manual review still owns all document mutation. Parent retirement
revokes authority before cancelling the child, while cleanup wakeups and the
supervisor remain responsible for draining/reaping it. Local and Chat runs
share one actual worker slot, not merely a picker-level busy check.

The local injected Chat / Log fixture uses real host-issued sessions with
ReadEditor and ReadDebugger. The configured external provider is narrower:
None, Selection and ActiveBuffer open no session; BufferTools grants only the
selected `editor.read_buffer` ID and revision. The owner validates this typed
allowlist before invoking a ReadEditor session, because ReadEditor itself is
broader than permission to export one buffer. Denied and malformed attempts
also consume the per-turn attempt budget.

BufferProposals explicitly adds the separate ProposeEdits capability, still
restricted to the exact selected ID/revision. One typed attempt is admitted per
turn, including a backend rejection. It stages at most one bounded batch of
codepoint-coordinate edits; the host strictly converts coordinates
to the safe plan's UTF-16 representation and rejects the whole invalid batch.
Dispatch never mutates a document. A separate proposal revision survives normal
Complete but not cancellation, failure or turn/context replacement. The manual
receipt also captures immutable reference scalars, an owner document-event
version and a monotonic view fence, so edit/Undo and file-switch round trips do
not revive a proposal. Staged ownership is transferred into the popup and
released on rejection, acceptance or revocation. No fabricated LSP request or
connected LSP client is needed for this review.

A transport receives an immutable turn request and an
enqueue callback, never a callable session or App reference. The owner drains
bounded events and tool requests, rechecks turn lifetime and returns results
only to the matching live handle. Cancel, new conversation, project retirement
and committed quit revoke the old turn; hiding the panel does not. Production
Send reviews freeze prompt, visible history, provider/root/composer identity
and selected source revision. A document-event version plus piece-tree state
fence rejects ordinary text edit/undo ABA even when the persistent root is
restored. Provider and project changes additionally clear exportable
conversation history.

Each transport permits one live turn including cancellation cleanup, closes
the active client on cancellation and bounds SSE events, total stream bytes,
requests, tool fragments, results and elapsed time. New HTTP clients per round
avoid implicit reused-connection retries; redirects and ambient proxies are
not used. The provider protocol is explicit rather than inferred from a model
name. A production App/PTY with a literal-loopback fake server exercises this
boundary without paid model calls. See
[the reviewed edits frontier](docs/CHAT_EDIT_FRONTIER.md),
[the provider frontier](docs/CHAT_PROVIDER_FRONTIER.md) and
[Chat UI frontier](docs/CHAT_UI_FRONTIER.md) for exact limits, evidence and
live-provider/terminal residuals.

## Safety and responsiveness limits

- `:open` resolves paths within the active project root, including symlink
  checks. `:cd` is the explicit operation that may select a different root.
- Documents larger than 16 MiB and files detected as binary are rejected.
- All open documents share one cooperative external-file monitor. Unresolved
  changes block ordinary save, close, and quit; force quit remains explicit.
- Reload preserves the previous in-memory piece-tree root as undo history.
  Guarded overwrite narrows the race window but does not claim portable
  compare-and-swap semantics against an uncooperative writer.
- Project search skips generated/vendor directories, symlinks, and binary or
  oversized files. It caps depth, scanned files, and displayed matches. The
  scan runs in a cooperative background fiber; changing the query, scope, root,
  or panel lifetime cancels the old generation before it can publish results.
- In-file find keeps at most 200 live matches; repeat search is not capped by
  that list. Buffers above 64 KiB use one cooperative search worker with one
  replaceable pending request. Publication checks document identity/version,
  request state and cursor position. The source root is captured at dispatch,
  not for every query keystroke. See `docs/BUFFER_SEARCH_FRONTIER.md` for the
  measured scope and excluded rendering/LSP costs.
- Keymap and theme files are size-limited and fall back to defaults on errors.
- Optional LSP failures are reported in the status log without terminating the
  editor.
- Draft recovery is separate from ordinary save and external-file conflict
  resolution. Recovery copies do not restore undo history or imply the original
  file is unchanged. See `docs/RECOVERY_FRONTIER.md` for checkpoint and retention
  boundaries.

## Testing seams

Most behavior is exercised through focused specs around controllers and state
objects. The default verification command is:

```sh
make check
```

It checks formatting, builds the application, and runs the full spec suite.
First provision the private Lua test library and set the real worker path as
shown in [the development setup](README.md#development); the Lua cases fail
actionably rather than silently skipping missing setup.
`make check-lsp` adds an integration handshake against a caller-provided server
executable.
