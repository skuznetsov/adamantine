# Reviewed assistant edit frontier

Current follow-up: [active-file context and selection-scoped proposals](CHAT_SELECTION_FRONTIER.md).
The CHAT-3 certificate below is historical; it does not verify the new range
boundary. `BufferProposals` is now presented as Whole-file proposals, while
ordinary inline proposals use the separately enforced selected fragment.

Status: **VERIFIED within the local CHAT-3 boundary**, 2026-10-10.
Anchor: `58db0c7fd34c4930e1954c17bac4fc0a5432bffd` (CHAT-2).

## Goal and authority

CHAT-3 lets an explicitly approved Chat turn propose changes to its selected
current buffer through the existing inline review. The model never applies or
saves edits. Only a subsequent, fresh manual review acceptance changes the
document, with one Undo for the selected batch and no automatic source-file save.
This extends [CHAT-2](CHAT_PROVIDER_FRONTIER.md), not its read-only grant.
Lua remains a later constrained consumer of the shared host API.

Risk: **CAUTION** (capability, coordinate and asynchronous review lifetimes).
Rollback: revert the isolated feature commit. No dependency, lockfile, ignored
TUI, Makefile, compiler, remote publication or paid provider change is admitted.

## Admitted boundary

- A new one-shot `BufferProposals` context is explicitly named in the context
  picker and Send disclosure as selected-buffer reads plus proposed edits.
  It initially exports only the chosen opaque buffer ID/revision; source text
  is obtained through the existing bounded selected-buffer read tool. Default
  `None`, direct Selection/ActiveBuffer and read-only `BufferTools` are unchanged.
- The shared catalog adds `editor.propose_edits` with a separate `ProposeEdits`
  capability. No default session or consumer label gains that capability.
  Production Chat permits only reads and proposals for the exact reviewed
  buffer ID/revision, never navigation, debugger tools or workspace discovery.
- A proposal has exact target ID/revision and 1--32 edits. Each edit contains
  only `start_line`, `start_column`, `end_line`, `end_column`, and `new_text`.
  Lines are one-based and columns are zero-based Unicode codepoints, matching
  `editor.read_buffer`. The host strictly converts to the existing safe edit
  plan's UTF-16 boundary; positions are never clamped or interpreted as bytes.
- The entire tool envelope remains at most 8 KiB, JSON depth 16; existing
  per-turn, request-round, callback, response and deadline limits are not widened.
  Reject malformed, oversized, duplicate-key, overlapping, same-point,
  out-of-range or otherwise invalid batches atomically; never truncate edits.
- The owner dispatcher prepares a read-only safe edit plan. After admission
  against the exact selected buffer/revision, one typed proposal attempt is
  allowed per turn, including a backend-rejected attempt. Malformed wire calls
  remain subject to the existing 16-attempt bound. At most one proposal is
  staged per turn. The tool result means pending manual review,
  not applied. A staged plan is published only after successful turn completion
  and only if its owner proof remains current. Another modal/review is not
  replaced; a conflicting or stale proposal is discarded with a visible reason.
- Use a typed host-owned proposal receipt, not a fabricated LSP request/client.
  The per-invocation `ExecutionPermit` expires when dispatch returns and is
  not a manual-acceptance lease. The receipt carries frozen scalar buffer
  ID/revision, owner event version, source snapshot/line ending, concrete
  editor/view/group, canonical root/epoch and provider/turn revision fences.
- Normal response completion closes the tool session but preserves that
  proposal's manual review receipt. Cancellation, failure, new turn/conversation,
  root/provider retirement, close/reopen, view/group replacement or source
  mutation revoke it. An edit followed by Undo must not revive an old proposal.
- Acceptance rechecks the receipt immediately before applying selected edits.
  Existing colored inline rendering, selection controls, compact-terminal
  acceptance guard and atomic safe-edit Undo are reused. Escape rejects without
  text/history mutation. Successful manual acceptance focuses the exact reviewed
  editor, so the next Ctrl+Z restores the source without a hidden focus command.
  No second preview engine, model navigation or automatic save is added.

## Rejected and guard-only

Direct model mutation, automatic acceptance/save, model-provided paths/URIs,
workspace edits, file creation/deletion, navigation, shell/raw commands, DAP
execution, Lua execution, arbitrary plugin access and grants inherited from
read-only context are rejected. No proposals are shown during incomplete or
failed streaming. A completed preview cannot be overwritten by another tool
call, late callback or proposal. Real paid calls, TLS/provider compatibility,
model quality, cost/retention policy and global memory/performance guarantees
are not certified by local fake-provider tests.

The API remains the existing compatible Chat Completions adapter, not a new
Responses migration or a claim that every model supports that endpoint.
Official function-calling and Chat Completions references were refreshed on
2026-10-10: [function calling](https://developers.openai.com/api/docs/guides/function-calling)
and [request reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create).
Provider schema is guidance; host validation is the authority boundary.

## Implementation and falsifiers

1. Protocol/transport owner: `editor_tools.cr`, `chat_submission.cr`,
   `chat_frontend.cr`, `chat_provider_transport.cr` and focused protocol/context/
   frontend/provider specs. First red: missing separate grant/context/schema;
   denied proposals in every existing context; normal Complete versus Cancel;
   malformed/oversized/duplicate proposals and exact selected-buffer scope.
2. Owner/UI integration: a separate proposal controller/receipt, existing tool
   backend, Chat Send/context controller, App drain and popup/input integration.
   First red: no-LSP prepare -> Complete -> inline review -> explicit apply ->
   one Undo, with unchanged disk bytes and no mutation before acceptance.
   Guard checks: edit/Undo ABA, source/view/group/root/provider changes,
   cancelled or replaced turn, immutable reference scalars, modal conflict,
   compact terminal, valid astral Unicode/CRLF and atomic invalid-batch refusal.
3. Adversary owner: independent App falsifiers and release CLI/loopback PTY
   workflow with a synthetic key and no LSP, real credentials or paid calls.
   Exercise reject, apply and Undo, read-only denial, cancellation/late callback,
   request scope and unchanged disk/other-file sentinels.

Workers own disjoint paths, preserve other edits and use private build caches.
Write and execute distinguishing failing tests before production changes;
root reviews code and independently reruns declared gates. Same-lineage agent
review is correlated, not a substitute for observed behavioral checks.

## Definition of Done and evidence scope

Run focused new protocol/frontend/App falsifiers; `make spec`; `make release`;
`crystal tool format --check src spec`; `git diff --check`; existing dependency
checks; production provider/Chat and fake-DAP left/bottom PTY controls; and the
new production proposal PTY. Expected signal: zero failures and demonstrated
manual-only, source-bound, one-Undo/no-save behavior without LSP. Isolate
ambient config and caches. Keep the unchanged TUI's known separate test-order
audit failures outside an all-green claim; do not change or skip its tests.

Evidence expires on changes to tool validation/grants, Chat review/lifetime,
owner/version/coordinate semantics, preview acceptance, provider adapter, TUI
pin or fixtures. Refresh affected behavioral checks before promoting a claim.
The compact [evidence packet](../.landmark/evidence/chat-3-reviewed-edits.json)
records the source/input seals, observed gates and default-deny path boundary.
It is an index to executed evidence, not proof by its own shape.

## Observed closure evidence (2026-10-10)

Root independently ran the final gates from the unchanged CHAT-2 anchor plus
this feature's frozen working-tree source. Crystal 1.21.0 / LLVM 22.1.8,
arm64 Darwin 25.6.0; ambient configuration and compiler caches were isolated.
The final source seal covers 110 files under `src/`:
`514cfd1f3565771a8544ac9aa988708c5f7af85403ff7ef9ce1e85bbbc10c401`.
The 236-file verification-input seal covers `spec/`, `scripts/`, Makefile and
dependency manifests:
`aef80de271ca47e2585df71f376471f25129d9a21f84e1c79abc6885a3a35bc1`.
Each seal hashes sorted repository-relative paths, NUL, each file's SHA-256,
then NUL. Root resealed production source before and after the final behavioral
gates; the final input seal identifies the frozen tests and fixtures exercised.

- `make spec`: **1,605 examples, zero failures/errors/pending**. This includes
  the new seven protocol, six real-App UI and 21 adversary examples, plus the
  context/provider and existing editor regression checks.
- `make release`: passed, including dependency validation and linking. Release
  SHA-256: `9a444490d4e78a4507933673fee7a8d97e9ae1ba951dfb9e6f1fe9a95d633f39`.
  Four pre-existing debugger `Time.monotonic` deprecation warnings remain.
- `crystal tool format --check src spec`, `git diff --check`,
  `ruby -c scripts/smoke_chat_edit_proposals.rb` and `shards check`: passed.
  `ruby scripts/test_build_dependencies.rb`: six runs / 77 assertions,
  zero failures/errors/skips.
- Six PTY workflows passed: the new no-LSP production proposal path, existing
  production provider adversary, production unavailable-provider Chat, rebuilt
  injected-local Chat, and fake-DAP left/bottom docks. The injected App was
  rebuilt from the same final source; its SHA-256 is
  `da0772310829c3b2bdd55a9d70695cacc50dcbba78afd910bb60e4bce7ad14c0`.
  All HTTP calls used literal-loopback synthetic fixtures, never real keys or
  paid services.

The new release PTY observes exact selected-buffer read/propose scope, no source
in the initial request, a bounded requested line rather than an unopened-file
sentinel, pending-review acknowledgements, no preview/mutation before Complete,
late-cancel non-resurrection, Escape rejection, Enter acceptance and immediate
Ctrl+Z as one Undo. Source and unopened-file digests remain unchanged on disk.
App falsifiers additionally cover selective groups, astral codepoints/CRLF,
atomic invalid batches, read-only/forged grants, source edit/Undo and view/group
ABA, close/reopen, modal conflict, root/provider/conversation retirement,
exhausted owner versions and compact-viewport refusal.

### Discriminating failures and narrow fixes

The 112x30 production preview initially clipped `not saved` from its header.
A failing rendered-App assertion led to a shorter Chat-specific title with
unsaved state before the source path; the final PTY sees source identity,
unsaved scope and Apply/Esc controls. A suspected missing footer was refuted by
a stable frame: partial PTY frames were not a layout defect, so no shared
renderer or TUI patch was admitted.

The production PTY then found that immediate Ctrl+Z after Enter targeted the
still-focused Chat composer. Root reproduced the failure on release
`431dbc9ada3f05438fed0874ed479a673d2dedaf2c753785e5c457fc0f2d2a18`.
The split-view App regression was changed to route a real Ctrl+Z, not call
editor Undo directly. Focusing only the receipt's validated editor after a
successful manual apply made that test and the unchanged normal-user PTY green.
There is no compensating palette/focus hop in the acceptance test.

### Verdict and residual boundary

Adversary verdict: **ROBUST for this local selected-buffer grant, proposal
lifetime and manual-acceptance UX**, supported by root's executed final gates.
Delegated implementation/review remains same-lineage correlated evidence.
Serialized owner-drain and permit checks are tested boundaries, not a formal
arbitrary native-thread or cross-fiber race proof. Live-provider behavior,
TLS/model compatibility, remote retention/billing, portable RSS and Lua remain
uncertified; this slice neither makes paid calls nor installs a Lua runtime.

The TUI pin remains `7ca26fd559cf8c05e5b4ed924e7c691fabb66e43`; its 129-file
source/spec seal remains
`f8efbc4fb479e8ffaf615e074e1566e07a1b2be754be099cda374c5673066a2f`.
The separate [known foundation audit](CHAT_PROVIDER_FRONTIER.md#separate-pinned-foundation-audit-2026-10-11)
has four test-order mouse failures. That extra library aggregate was not rerun
or represented as green here; no dependency edit, test skip or pin change was
made. The repository lacks the Landmark graph validator/template, so a narrow
JSON/path/hash check validates the packet's shape and current seals only, not
semantic truth or independence. Refresh the affected executed gates on the
decay events listed above; otherwise treat this certificate as stale.
