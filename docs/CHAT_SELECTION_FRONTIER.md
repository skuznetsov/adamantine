# Chat active-file context and selection-scoped proposals

Status: **VERIFIED locally within the declared boundary on 2026-10-14**.

Source anchor: `9cf1a1268b4b675f65acd9baa96e4901e019029f`.
Implementation and this certificate travel together in the atomic feature
commit whose parent is that anchor; Git history records the exact revision.

## User boundary

Chat must identify the active file and selected fragment explicitly. Ordinary
inline proposals require a selection. Whole-file proposals remain a separate,
clearly named, per-turn permission. Selection scope is host-enforced, not an
instruction that a model or Lua script may override.

`None` remains the default disclosure mode: no new file path, coordinates,
source text, editor tools, or Lua grant. Previously disclosed conversation
history is not erased by choosing `None`.

## Admitted contract

- Every explicit file context includes a canonical project-relative path;
  absolute paths and traversal are rejected. The path is metadata, not a
  tool argument granting filesystem access.
- A nonempty active-view selection is normalized and frozen as `SourceRange`.
  Lines are one-based, columns are zero-based Unicode codepoints (not bytes,
  UTF-16 units, or display cells), and the end is exclusive.
- `Selection` discloses only bounded selected text and location, without tools.
- `SelectionProposals` discloses the same bounded selected text and location,
  and grants bounded reads/proposals for that exact selection and buffer
  revision. The Send review shows the file, range, and selection-only scope.
- `ActiveBuffer` and `BufferTools` retain their explicit read-only meanings.
  `BufferProposals` is labeled **Whole-file proposals**. A captured selection
  in that mode is informative metadata, not a restriction or implicit consent.
- Tool requests continue using the existing opaque buffer ID/revision and
  coordinate schema. No arbitrary file navigation or filesystem write is added.
- Selection reads expose only the intersection of the requested bounded
  fragment and the frozen selection, with truthful absolute line/column and
  continuation metadata. A disjoint read is denied; continuation never points
  outside the selected range. Prefixes/suffixes outside a selected line must
  never be serialized to a provider or Lua child.
- Out-of-scope reads are denied uniformly before inspecting excluded row or
  column bounds. Error differences must not reveal an unselected suffix's
  length or the physical file's end; skipped prefix rows cannot affect results.
- Selected-read rows retain absolute codepoint columns. `newline_after` marks
  a selected line break reached by that row; a newline-only selection may
  therefore return an empty text row with this flag. `complete`, `next_column`,
  and continuation describe the remaining authorized fragment, not the rest
  of the file or an unselected suffix.
- Every edit in a proposal batch must be contained in the selected range.
  One outside edit rejects the entire batch before staging. Zero-width
  insertions at either boundary are allowed; points beyond them are denied.
  Full-selection replacement may change length but cannot consume adjacent text.
- Direct model tools and approved named Lua scripts share the same scoped host
  backend. Script capability intersection, attempt/result limits, sticky child
  refusal, successful child reap, and parent Complete gates remain in force.
  One typed exact-buffer proposal attempt is shared across both routes,
  including a selection-containment refusal before backend dispatch. A denied
  direct attempt must not leave an unused proposal allowance for a Lua child,
  and a child attempt must not leave one for a subsequent direct tool call.
- A selected-scope receipt is bound to the actual editor view, pane group,
  project root, canonical path, revision/event version, snapshot, and exact
  selection. A monotonic selection epoch prevents moving away and back from
  reviving an earlier grant. Changed/cleared selection or another same-file
  view revokes it.
  Recheck before publication and immediately before manual acceptance.
- Accepted changes remain unsaved, form one Undo action, and require explicit
  inline review. No automatic acceptance, save, fallback to whole-file scope,
  paid model call, or startup script execution is admitted.

## Risk, rollback, and discriminators

Risk tier: CAUTION (serialized disclosure and delegated editor capability).
Rollback: one atomic local feature commit; no dependency or lockfile changes.
The user's existing dirty `Makefile` is excluded and preserved byte-for-byte.

The strongest failure is same-line prefix/suffix leakage or out-of-selection
mutation through a child Lua session. Guards must run before returning content
or staging any edit, and tests must exercise the actual App backend.

Required falsifiers:

1. `None` exports no new location/source/tools; immutable metadata and request
   copies cannot be altered after review; invalid paths/ranges are rejected.
2. Normalized reversed, multiline, CRLF, astral, and combining-character
   selections report the correct file/codepoint range and selected text.
3. Selection read pagination never returns outside sentinels or advertises an
   outside continuation; direct and real Lua reads use the same restriction.
   Beyond-selection coordinates yield identical refusals on either side of
   the physical EOL/EOF, and prefix-row probes cannot disclose excluded bounds.
4. Mixed in/out-of-range edit batches and just-outside insertions are denied
   atomically; both insertion boundaries and full-selection replacement work.
5. Selection drift/ABA, edit/Undo ABA, and same-file sibling view changes prevent
   stale preview publication/acceptance. Manual acceptance remains one Undo
   without saving the file.
6. Whole-file scope is available only through its explicitly labeled choice
   and Send review; read-only Selection gains no proposal tools.
7. Mixed direct/Lua sequences cannot obtain a second typed proposal attempt,
   including an outside-selection direct refusal followed by an in-selection
   child proposal. Refused children remain sticky-failed and are reaped without
   publishing a preview; the reverse route order is checked as well.

## Verification commands

Run focused context/provider/host regression specs red, then green.
Use one private task directory/cache for compiled artifacts and the existing
checksum-pinned Lua test builder; no provider key or paid request is needed.

Completion commands:

- `crystal tool format --check src spec`
- `make ci ADAMANTINE_BIN=<private-task-directory>/adamantine-worker`, with the
  same private Crystal cache and real Lua 5.4 library/worker configured.
- `crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld
  -o <private-task-directory>/adamantine-release` on macOS, then `--help`.
- Keyless Ruby harness regressions and terminal smoke tests for reviewed Chat
  Lua/manual inline editing, using the private release binary.

Expected signals: no failing specs, no silent Lua-test skips, successful
build/CLI/smoke checks, unchanged Makefile hash, and no generated artifacts in
the feature commit. Remote Linux/macOS CI is not claimed without a separately
authorized push/PR and an observed result at the exact head.

## Discriminating regressions

- A paired-buffer App probe failed before read intersection moved ahead of
  physical row/column validation: excluded prefix/suffix lengths and EOF could
  change the error. The passing regression now requires identical out-of-scope
  refusals and identical authorized output despite those excluded differences.
- A real Lua App probe failed before deferred requests shared the frontend
  proposal ledger: a direct selection refusal followed by a valid child edit
  returned `ok` and opened a preview after Complete. The passing regression
  requires child refusal, sticky failure, successful reap, no candidate/preview,
  and unchanged editor/disk contents.
- The reverse route is checked at the frontend boundary: a current child guard
  consumes the allowance, then an actual direct proposal event is denied before
  backend execution. Reusing the outer call ID across replaced turns cannot let
  the retired ticket consume the new generation's allowance.

## Observed local certificate

- Root's focused context/provider/App/Lua gate passed **140 examples, zero
  failures/errors/pending**. The subsequent complete `make ci` gate passed
  **1,714 examples, zero failures/errors/pending**, including the strengthened
  retired-ticket/reverse-route regressions. A real Lua 5.4 library and worker
  were configured; no Lua cases were silently skipped.
- Root's direct macOS release build and CLI `--help` passed. Root independently
  passed both proposal PTYs with the resulting production binary:
  `scripts/smoke_chat_edit_proposals.rb <release>` and the same command with
  `--selection-only`. These exercise explicit whole-file permission and
  keyboard selection, selected-only disclosure/reads, atomic mixed-batch
  refusal, completion/manual acceptance, one Undo, and unchanged disk bytes.
- Luna's production-release `smoke_lua_scripts.rb`, `smoke_chat_lua.rb`, and
  `smoke_template_split.rb` gates passed with the real Lua library where needed.
  Root separately ran `test_luna_lua_inspector.rb`: **8 runs, 485 assertions,
  zero failures/errors/skips**.
- Root's Ruby regressions passed: demo harness **18/56**, Chat-Lua harness
  **6/21**, adapter-exit fixture **6/160**, Crystal-debugger harness **13/77**,
  and dependency preflight **6/77** (runs/assertions), all with zero
  failures/errors/skips. Dependency preflight used the intended committed
  `HEAD:Makefile`, not the user's excluded installation-command modification.
- The old whole-file PTY initially failed because its fixture extracted the
  buffer ID/revision from prompt prose rather than the approved tool schema.
  Its read was correctly refused as out of scope. The harness now extracts
  both read/proposal schema tuples, requires equality, and the unchanged
  release binary passes the complete flow; this was not a runtime read fix.
- Scoped hostile review returned **ROBUST** for shared proposal accounting and
  retired-ticket fencing. Same-lineage review is correlated evidence; the
  red/green App probes and Root's executed gates establish the local result.
- All provider checks used synthetic loopback responses with
  `OPENAI_API_KEY` unset. No paid call, automatic acceptance/save, installed
  binary overwrite, dependency change, or remote action was used. The protected
  Makefile remained unchanged at SHA-256
  `a4299b908cf1ee23c0eb6ce2627f61b156b5044f4bd31f4693f8a14ddfffe111`.

Linux/macOS CI includes the selection PTY, but no remote run is claimed for
this feature. These checks do not establish live-model behavior, TLS/provider
compatibility, billing, an OS sandbox, or a separately green upstream TUI suite.
The reverse direct/Lua attempt order is tested at the frontend boundary, not
as a second real-Lua App integration.

This certificate decays when context capture, coordinate conversion, tool
grants/backend, source receipts, Lua dispatch, or inline acceptance changes.
Refresh by rerunning the affected falsifiers, the full suite with real Lua,
and the production-release PTYs before reusing the claim. A failed or skipped
required gate reopens the corresponding capability claim; safety-only refusal
does not by itself prove the requested editing workflow.
