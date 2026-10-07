# Bottom chat UI frontier

Status: **local CHAT-1 verified**, 2026-10-07, within the evidence scope below.
Source: the feature commit carrying this document, based on `dba18eb`, with
installed TUI matching the locked `7ca26fd` revision. No production model is
connected and no Lua runtime is admitted by this result.

## Goal and admitted design

Implement the next accepted roadmap slice: a full-width bottom chat surface,
not another side inspector. Reuse the existing single/shared split separator
and preserve the status log in a reachable **Chat / Log** switcher. Showing,
hiding or switching the bottom surface must not stop the debugger, reload a
file, discard unsaved text or destroy a chat draft. The existing two-column
Files/Debug activity rail remains unchanged.

CHAT-1 implements local UI and a bounded frontend seam only. Production has
no connected model. Show that fact plainly; an unavailable Send retains the
draft and must not synthesize an assistant reply or claim a request was sent.
An explicitly injected local test transport may prove streaming/cancellation
and tool-session composition, but is not a user-facing model provider.

The composer supports bounded multiline text, grapheme-safe editing and
clipboard/bracketed paste without silently flattening pasted code. Enter
submits when a transport is available, otherwise explains the unavailable
state. Shift+Enter inserts a newline where the terminal reports that modifier;
provide Alt+Enter as a distinguishable fallback. A delivered Escape event
returns focus to the editor, or cancels an active request first. F1 discovery and an
explicit editor-focus route remain available. Chat actions belong to the
existing remappable keymap/palette; do not use Ctrl+J as a distinct action
without evidence that the terminal can distinguish it from Enter.

Ctrl+G reveals and focuses Chat; F3 returns to the editor. The palette exposes
Toggle bottom panel independently of Chat/Log selection. Hiding returns the
space to the editor/inspector, preserves the draft and remembered split ratio,
and never leaves a hidden composer focused. Modified shortcuts remain
discoverable through F1 when a terminal cannot report their modifier bits.

Chat is a focused non-modal surface, not a new overlay that steals input from
the workspace. Existing modal reviews/popups own keys, paste and mouse before
chat. Chat editing and selection never target the code editor; editor-specific
save/close/undo/cut/paste/indent routes do not fall through from chat. Switching
or hiding a focused pane and resize-before-paint must repair focus without
changing the active buffer/group or destroying the draft.

## Authority, lifetime and resource laws

- Use the real host-issued `EditorTools::Session`, not raw App commands or a
  second dispatcher. The local chat frontend defaults to ReadEditor and
  ReadDebugger; this slice does not grant navigation or execution implicitly.
- Transport callbacks never call editor/debugger APIs from a worker fiber.
  UI and tool execution remain App-owner operations. A callback queue, if
  introduced, must be bounded and drained by the owner, not by a background
  model worker mutating the App. The transport receives no callable Session:
  it emits bounded typed tool requests, and the frontend drains them through
  its host-issued session before returning a result to the matching handle.
- Cancellation/new conversation/project-root retirement/quit fence the old
  turn and close its tool session. Late chunks/completions/tool requests cannot
  publish into a newer turn or revive revoked capabilities. Hide is not
  cancellation; an explicit Cancel is discoverable independently of focus.
- Preserve TOOL-1 request/result/delegation limits. Stop on its sealed terminal
  limit response; do not loop, re-emit it, or mint sessions to retry one turn.
- Bound the draft to 16 KiB, an individual retained message to 64 KiB, the
  transcript to 256 KiB and 128 messages. Eviction/truncation must be explicit;
  rendering only visible bounded text is not a substitute for retained-memory
  bounds. The pending callback queue is separately limited to 128 events and
  128 KiB; terminal overflow must stop a turn rather than grow the queue.
- Terminal controls and invalid UTF-8 cannot become terminal instructions.
  Keep multiline layout/selection coordinates distinct from code-buffer and
  DAP coordinates. Clipboard callbacks revalidate composer identity, revision,
  cursor/selection, focus, project/turn lifetime and visibility before insertion.
- Draft/conversation state stays in memory. No automatic file-content capture
  or upload and no implicit persistence in project/session files.

## Rejected and guard-only surfaces

No network request, paid API call, provider SDK, key storage/configuration, Lua
runtime/dependency, shell/process tool, raw DAP/command string, code mutation,
save/close/discard tool, target evaluation/control, or automatic attachment is
implemented by CHAT-1. Model/provider and constrained Lua are subsequent
frontiers sharing this host API. An injected test transport does not admit a
production provider, native plugin sandbox or arbitrary-thread safety.

## Implemented consumer inventory

Risk: **CAUTION** (focus routing, UI callback lifetime and capability boundary).
Rollback: one atomic local feature commit; no pin/lockfile/Makefile change or
remote publication. Strongest likely failure: a late clipboard/transport event
mutates a different focused surface or publishes stale project evidence.

- `chat_composer.cr` owns the bounded multiline draft, grapheme-aware editing,
  selection and a monotonic mutation revision. Geometry synchronization keeps
  the caret visible after resize without changing draft text or revision.
- `chat_frontend.cr` owns bounded transcript/events, unavailable-send behavior
  and turn/session lifetime. External callbacks only enqueue; App-owner drain
  invokes the real host session and returns a result to the matching turn.
  Cancellation detaches and invalidates state before calling external handles.
- `chat_panel.cr` owns Chat/Log selection, full-width rendering, panel focus and
  composer geometry. `app.cr` composes it as the bottom split child instead of
  the former direct status-log child. Collapse preserves draft and split ratio.
- `debug_inspector_layout.cr` synchronizes child rectangles before paint,
  preserves shared border junctions, and gives captured divider drag/release
  priority over child input. Hidden panels have no active input rectangle.
- `input_router.cr` isolates Chat/Log keys, paste and mouse from code editing
  while preserving modal precedence. `input_mode_controller.cr` fences delayed
  clipboard delivery on every modal entry, including programmatic transitions.
  `key_config.cr`, `command_palette.cr` and `keymap.example.json` expose the
  remappable actions through the existing discovery surface.
- `editor_tools_controller.cr` issues the existing host sessions. Project-root
  retirement and quit also retire Chat's transport/session lifetime; late
  output, tool requests and clipboard callbacks cannot revive it.
- `scripts/smoke_chat_panel.rb` inspects current bottom-screen state, not only
  an accumulated terminal transcript. Its local fixture constructs the real
  App and injects a deterministic transport; it reads an unsaved buffer through
  the actual host session and proves denied navigation/evaluation paths.

Existing single-line `EditableInput` semantics are unchanged. Crystal Ball's
bottom-panel and multiline-input precedents informed the Chat/Log composition;
the existing shared divider is reused rather than adding nested pane borders.

## Acceptance evidence and adversary result

DoD: focused new specs and existing input/modal/tool/debug-layout guards,
`make spec`, `make fmt-check`, `git diff --check`, normal-path `make release`,
`ruby scripts/test_build_dependencies.rb`, chat App/PTY plus an existing
fake-debugger App/PTY control. Expected: executed behavioral gates pass, real
terminal workflow succeeds and missing transport remains honest. Root checks
the delegated implementation and strongest counterexamples before closure.
The final source passed these root-executed checks on macOS / Crystal 1.21.0:

| Gate | Observed result |
| --- | --- |
| `make spec` | 1,523 examples, zero failures/errors/pending |
| `make release` | Exit 0 using the normal Makefile path |
| `make fmt-check`; `git diff --check` | Exit 0 |
| `ruby scripts/test_build_dependencies.rb` | 6 runs, 77 assertions, zero failures/errors |
| `ruby -c scripts/smoke_chat_panel.rb`; smoke `--self-check` | Syntax OK; top-only decoy rejected |
| Production and local-transport Chat App/PTY | Both PASS under the default 45-second bound |
| Existing fake-debugger App/PTY, left and bottom docks | Both PASS on the final release binary |

The Chat PTY commands were:

```sh
ruby scripts/smoke_chat_panel.rb --editor-bin /Users/sergey/Projects/Crystal/editor/bin/adamantine
ruby scripts/smoke_chat_panel.rb --fixture-bin /private/tmp/adamantine-chat-verify.T7c69t/chat-smoke-app
```

The local fixture was compiled from `spec/fixtures/chat/chat_smoke_app.cr` with
`crystal build`, `--error-trace` and macOS
`--link-flags=-fuse-ld=/usr/bin/ld`. Debug controls used
`ruby scripts/smoke_debugger_session.rb --fake-adapter --editor-bin
/Users/sergey/Projects/Crystal/editor/bin/adamantine --dock left` and the same
command with `--dock bottom`. Verification caches/fixture binaries were private
temporary artifacts, not committed source.

Adversary verdict: **ROBUST within these local gates**, not a claim about every
terminal, provider, native thread or future Lua consumer. Delegated review was
same-lineage; root independently executed the final behavioral gates. Tested
counterexamples include delayed paste after modal open/close without another
key, edit/undo ABA, unchanged-text turn retirement, reentrant session creation
and cancellation, stale tools after root retirement, queue/retention limits,
and actual multiline CJK/emoji rendering. UI gates cover Ctrl+S/Ctrl+W isolation
with exact final buffer retention, modal priority, captured divider dragging,
and immediate caret-tail visibility at 64 columns by 16 rows before any cursor
movement. Resize preserves text, selection and mutation revision.

Regressions exposed and corrected during verification: character-index/byte-slice
mixing in streamed Unicode tails, child consumption of a captured divider drag,
stale clipboard delivery across modal or ABA transitions, and caret clipping
after a shorter viewport. The PTY oracle itself has a negative control against
matching text only in the editor or old terminal output.

One apparent Escape/redraw failure was refuted: the pinned TUI input decoder
waits for another byte after a bare single-byte Escape and has no Escape timeout.
The completed Kitty `CSI 27 u` Escape event works in the tested workflow; bare
Escape compatibility is an inherited limitation, not fixed or certified here.
F3 returns to the editor and F1 exposes cancellation/actions as explicit routes.
The frontend seam has no production provider, persistent conversation/history
browser or arbitrary-thread safety guarantee. Four existing `Time.monotonic`
deprecation warnings remain in the build.

Evidence decays on frontend/callback, host-session, root/focus, TUI pin or
terminal/input-route changes. Refresh the affected gates before widening;
retain the last admitted authority/resource boundaries when a gate fails.

Next local track after CHAT-1: model connection with explicit context and key
handling, separately authorized provider calls, followed by proposed edits and
constrained Lua. Passing this local frontend does not implement those tracks.
