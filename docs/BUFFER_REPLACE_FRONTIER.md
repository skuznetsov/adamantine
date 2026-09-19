# Large-buffer replacement frontier

Status: locally verified (2026-09-18).
Base: `db96792`; roadmap slice 2b.

## Boundary and design

The previous command materialized the complete editor text for counting,
preview, replacement, comparison and the whole-document edit. The new route
uses bounded reads and a detached piece-tree candidate. A successful
replacement commits one root as one undo entry and emits one existing full
change event. Preview, no-op and failure must not alter text or history.

Preserve literal first/global replacement, the parser's escaping, existing
regex ignore-case/replacement-string semantics, original UTF-8 bytes and mixed
line endings. Find's lowercase matcher is not an interchangeable authority for
replace's regex case behavior. Preview keeps at most five bounded samples.

Prepare against a stable original root, with no callbacks or visible mutation
until commit. No full-document/line getters or arrays of every match are
admitted in scanning, preview or edit preparation. Scratch may scale with the
pattern/replacement, bounded chunks, and changed tree metadata/source bytes.
Refuse unsafe ranges or explicit hard work/output bounds before committing
any text. CRLF boundary repairs may over-read the adjacent byte, but must never
silently normalize line endings. Preserve cursor clamping and clear selection
on a successful replacement as the old whole-document edit did.

LSP remains an explicit compatibility boundary: a connected server receives
one full-text change after the atomic commit, not one full copy per match.
Undo/Redo continue to emit the existing full change event. This slice does not
introduce multi-edit LSP notifications or claim zero allocation at that boundary.

Rejected: partial application, partial history after errors, changed regex
semantics, silent truncation of replacement, dependency-only patches in ignored
`lib/`, expanded file-size support, or new persisted formats. Asynchronous
replacement publication and protocol batching are not implied by this slice.

The initial safety bounds are 16 KiB for the literal query, 1 MiB for the
replacement argument, 100,000 processed occurrences and a result no larger than
the greater of 16 MiB and the original buffer. These are explicit rejection
limits, not truncation or user-configurable settings. They bound detached
preparation; they do not certify a latency target. Preview stops after five
samples. Matching remains the same escaped-literal regex in ignore-case mode;
replacement expansion is evaluated on the exact matched source bytes.
Ignore-case `\0` expansion is size-checked before allocating the expanded
replacement (16 MiB per occurrence); a result-size check after expansion is
too late to prevent memory amplification. Preview does not expand replacement
backreferences and displays bounded excerpts with original byte-offset labels.

`piece_tree_replace.cr` is a deliberately narrow app-owned bridge to the pinned
`crystal_tui` revision. It provides a fork with a fresh append page, a single
root-construction range replacement, and guarded adoption of the candidate's
allocation state. A plain shallow `dup` is insufficient for mutation. Existing
UTF-8 and CRLF boundary validation stays in force; the editor widens a match
at a CRLF edge by at most one preserved byte on each side. Re-audit this bridge
when the dependency pin changes. No dependency checkout is edited.

Preparation batches nearby matches into 8 KiB source / 64 KiB output windows
before mutating the candidate tree; an individual larger query or replacement
is governed by its separate limits above. It checks the work and projected result
limits for each occurrence. CRLF widening uses the current candidate bytes,
not the original root: replacing both LFs of `"\n\n"` with CR creates a new
CRLF seam after the first edit, which invalidates original-boundary reasoning.

The initial unbatched route was rejected on allocation evidence: 20,000
replacements in a 4 MB fixture allocated about 1.19 GB in total, although it
took about 0.55 seconds versus the old route's 25 seconds. That is allocation
churn, not measured retained memory, but enough to require bounded batching.

## Execution, risk and verification

CAUTION: an incorrect range or half-applied replacement loses user text.
Rollback: revert the atomic slice commit; preserve the unrelated Makefile edit.
No remote publication. Parent owns integration tests, review and measurements;
Luna implements the bounded transformation after API/semantics probes.

1. `spec/buffer_replace_integration_spec.cr`: a runtime text getter guard first
   rejects the old command path for replacement and preview (observed: two
   errors at `command_palette.cr`'s counting read). Add single Undo/Redo and
   notification assertions, no-op and failure controls.
2. `src/adamantine/buffer_replace.cr`, `editing_text_editor.cr`,
   `command_palette.cr`: implement bounded preparation and atomic commit.
   Keep legacy `ReplaceUtils` helpers as a reference oracle and parser source.
3. Focused matcher/editor tests compare output with the legacy string route:
   Unicode case behavior and replacement escaping, overlap, first/global,
   chunk boundaries, mixed CRLF/CR/LF, newline insertion/deletion, long lines,
   output/work limits and unchanged bytes/history after failure.
4. Run the full suite, standalone release build and formatting. Measure gross
   allocation and elapsed time separately on large sparse/dense fixtures.
   No-getter tests establish routing, not an end-to-end latency or RSS bound.

Inventory: `rg 'replace_text_content|replace_match_count|make_replace_previews|execute_replace_command|sync_lsp_change' src spec`
identifies command execution, parser/reference helpers and the LSP consumer.
`TextEditor` history uses persistent snapshots; `PieceTreeBuffer` exposes
`snapshot`, `restore`, and `same_state?` at the unchanged dependency revision.

DoD on this macOS host:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-replace-parent-cache crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec scripts/benchmark_buffer_replace.cr
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-replace-build-cache crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o bin/adamantine
bin/adamantine --help
```

Expected: reference comparisons and byte-exact single Undo/Redo pass; failed,
preview and no-op operations have no mutation/history/notification effect;
successful replacement emits only its committed state. Re-run after changes to
buffer persistence, regex semantics, history, command parsing or LSP sync.

## Observed evidence and remaining limits

Parent verification on this slice passed all 564 examples with zero failures
or errors, the standalone release build and `--help`, formatting and diff
checks. Tests include a throwing whole-document getter, legacy byte-output
comparisons, seeded mixed-Unicode/newline cases, single-step Undo/Redo,
notification counts and failures after an earlier candidate batch was flushed.
The visible document, selection, redo history and notifications remain unchanged
on those preparation failures.

Adversary verdict: ROBUST within the tested byte/history/notification boundary.
Parent counterexamples rejected both transient delete/insert CRLF seams and
original-root boundary widening: a later batch must not restore a byte changed
by an earlier batch. Candidate-only range repair passes the dense mixed-CRLF
regression and validates the resulting piece tree. Expansion limits are checked
before allocating repeated full-match backreferences.

Reproduce the isolated release-mode benchmark:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-replace-benchmark-cache crystal build scripts/benchmark_buffer_replace.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-replace-benchmark
/private/tmp/adamantine-replace-benchmark baseline
/private/tmp/adamantine-replace-benchmark buffer
```

Three local runs per fixture (decimal MB, rounded):

| Fixture | Previous route, ms | Buffer route, ms | Previous / buffer allocated MB |
| --- | --- | --- | --- |
| 3.96 MB sparse lines | 34.8–38.2 | 15.9–17.0 | 20.5 / 8.2 |
| 4 MB sparse single line | 44.5–46.5 | 22.2–23.0 | 20.7 / 12.5 |
| 4 MB, 20,000 replacements | 24,614–25,253 | 68.8–70.4 | 25.3 / 44.3 |

These are gross GC allocation deltas, not RSS or retained-memory bounds.
Dense replacement allocates more than the previous route, despite being much
faster; batching reduced the rejected new route's 1.19 GB churn to 44.3 MB.
Setup, GC and byte-output/Undo/Redo validation are outside the timed interval;
there is no connected LSP server in this probe. No RSS measurement is claimed.

Replacement remains synchronous. Fixed rejection limits, byte-offset preview
labels and a full-text LSP copy after commit are deliberate residual boundaries,
not general responsiveness or zero-copy guarantees. Persistent history retains
the original snapshot for Undo. Re-audit the private piece-tree bridge when its
dependency pin changes, and refresh the checks above after changes to matching,
batching, buffer persistence, history or notification consumers.
