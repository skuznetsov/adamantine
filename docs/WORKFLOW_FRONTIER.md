# Daily workflow frontier

Status: 5a locally verified in `7071169`; 5b in `1dc530e`.
5c locally verified in `645b631`; 5d locally verified below.
Admit each feature after its predecessor's checks pass. Preserve the user's
Makefile. Rollback is one local atomic commit per feature; no remote push.

## 5a: Quick file opener

Configurable `app.quick_open`, default Ctrl+P, a query/list modal, arrows/Enter
and Escape. Enumerate file paths only, never file contents; use bounded fuzzy
subsequence ranking with deterministic path ties. Skip known dependency/VCS
directories and symlinks. Bound traversal entries, depth, results and query
length; yield/cancel during traversal and scoring. A partial index must be
visibly partial, including zero matches. Root/query/generation guards prevent
stale publication. Opening delegates to ordinary guarded `open_file`, so binary,
oversized or unstable files stay rejected and unsaved existing buffers are
reused, not reloaded. No filesystem writes or gitignore-conformance claim.

Bounds: 10,000 examined entries (including skipped names and directories),
depth 16, individual paths 4096 bytes, retained path strings about 4 MiB,
query 256 codepoints and 100 returned rows. Prefer exact/prefix basename
matches before directory-only matches, with deterministic path ties. Cooperative
checkpoints cover enumeration and scoring; only one active worker and one latest
pending query may exist. A cached index lives only within the current modal/root.
Metadata failures, traversal/path/memory limits and cancellation preserve an
explicit partial state. Opening still validates the selected disk file afresh.

Tests first: ranking, no-content-read, limits, cancellation and stale results;
app remapping, modal isolation, duplicate tabs and ordinary open guards. Files:
new quick-open backend/state/controller, `app.cr`, `input_router.cr`,
`input_mode_controller.cr`, `key_config.cr`, root specs and README. SAFE UI plus
CAUTION cooperative scheduling; parent reviews all publication boundaries.

Observed 2026-09-19: 24 focused examples and the full 657 examples passed with
zero failures/errors, as did source/spec formatting, diff checks, release build
and `--help`. Parent regressions first demonstrated missing modal isolation and
13 worker launches across rapid close/reopen; final checks cover single-worker
ownership, latest-query publication, partial-empty Enter feedback, unsaved tab
reuse, deleted/binary files, Unicode query keys, metadata and retained-path
limits. The existing settings conflict test now uses an unassigned key because
Ctrl+P is deliberately assigned. Adversary: ROBUST for this bounded local scope.
Directory metadata calls themselves remain synchronous; network filesystems
and all terminal key encodings are not certified. The path budget counts
cumulative directory strings conservatively, not exact process RSS. Results
are the top 100, not an exhaustive match list. Refresh after traversal,
modal ownership, root switching or guarded-open changes.

## 5b: Problems navigation

Current-document Problems list with severity, message and source position;
next/previous diagnostic actions wrap deterministically, and selecting a row
navigates using the stored codepoint coordinates. Slice 3 converts UTF-16 once
on publication; Problems must not convert those stored ranges a second time.
Do not imply project-wide completeness.
Versioned diagnostics publish only for the current buffer version/client.
Clear obsolete diagnostics on document changes and close; never reinterpret
stale ranges as positions in new text. Unversioned servers remain supported,
but cannot provide proof of freshness: document this protocol limitation and
invalidate local state on edits. Invalid ranges must not navigate outside the
document or crash rendering. No server-requested edits or automatic fixes.

Admission bounds: inspect at most 1000 diagnostic items per notification,
retain at most 4096 message codepoints and 256 source codepoints per item;
malformed items and truncation preserve an explicit partial marker. URI limit
8192 bytes. Malformed supplied versions are rejected, not treated as absent.
Preserve valid zero-length ranges. Advertise versionSupport; the protocol's
optional integer version is verified against the official source:
https://raw.githubusercontent.com/microsoft/vscode-languageserver-node/main/protocol/src/common/protocol.ts
(PublishDiagnosticsParams, read 2026-09-19). Compatibility callbacks must not
publish twice when both APIs are installed. Cancellation/freshness does not
make unversioned server notifications trustworthy after a local edit.

Tests: severity ordering, empty results, wraparound, Unicode ranges, invalid
positions, delayed older versions, client replacement, buffer edits, modal
isolation and navigation. Files: diagnostic model/parser, `document_types.cr`,
LSP controller, modal/key routes and root specs. CAUTION stale-state authority.

Observed 2026-09-19: full suite 682 examples passed, plus a subsequently added
fragmented-line/CRLF/Undo coordinate regression (3 inverse-coordinate examples
passed together). Release build, help, formatter and diff checks passed.
Parent red tests exposed stale publication, surrogate-range partial reporting,
modal Ctrl+P leakage and client-replacement invalidation before correction.
Tests exercise actual cooperative interleavings, close/reopen versions and
Unicode navigation without double conversion. Inverse UTF-16 lookup now
binary-searches tree prefix counts without materializing multi-megabyte lines;
the string oracle and a no-line-copy editor verify this boundary.
Adversary: ROBUST within the bounded current-document scope. Unversioned
notifications cannot prove freshness; Int32 document-version exhaustion and
all server/terminal variants are not certified. Refresh after diagnostic,
version lifecycle, coordinate or modal-routing changes.

## 5c: EditorConfig

Bounded per-file configuration, nearest ancestor and later matching section
wins; stop at `root=true`. Global F10 settings remain defaults. Support
`indent_style`, `indent_size`, `tab_width`, `end_of_line`, including `unset`;
unsupported/invalid values cannot poison valid settings. Preserve the editor's
bounded numeric policy (1–8) and report unsupported values. Unknown properties
are ignored, not falsely claimed as implemented. Matching supports common
EditorConfig globs; any unsupported syntax is explicitly documented and safely
ignored rather than applied too broadly. Bound file bytes, ancestors, patterns
and expansion/matching work; no new dependency or executable config.

Preferences apply to indentation and new line insertion, not an implicit
whole-file conversion. Existing bytes survive open/save/Undo; mixed endings
stay mixed unless the user explicitly edits them. Global setting changes must
recompute per-buffer overrides without rewriting project files. Tab display
width and inserted indentation width/style are separate settings.

Tests: root/ancestor/order/glob/section precedence, unset, malformed/oversized
files, tab/space insertion, EOL policy, per-buffer isolation and byte-preserving
save. Files: new parser/resolver, editing settings/editor integration and root
specs. CAUTION configuration precedence; no claim of complete EditorConfig
conformance. Reference: https://spec.editorconfig.org/ (read 2026-09-18).

Reference refreshed against official version 0.17.2 on 2026-09-19. Parent
app-level red tests demonstrate missing per-file precedence, tab insertion
and ancestor fallback. Matching work and regular-file bounded reads must
prevent pathological patterns or a FIFO from blocking configuration loading.

Implemented bounds: 32 ancestors, 64 KiB per regular non-symlink config,
4096 lines, 4096-byte lines/target paths, 128 sections per file, 256 total
patterns, 256-byte patterns, 16 brace alternatives, two million cumulative
matching steps, and 64 warnings capped at 512 UTF-8 bytes. Supported globs:
`*`, `**`, `**/`, `?`, literal/negated character classes and simple brace lists.
Escaping, numeric/nested brace expansion and wildcard runs longer than two
stars are rejected with warnings. This deliberately falls short of the full
EditorConfig conformance limits. Filesystem metadata itself is synchronous;
concurrent malicious replacement of configuration paths is not certified.

Observed 2026-09-19: full suite 707 examples and 24 focused examples passed;
release build, help,
formatter and diff checks passed. Parent adversaries caught value-copy loss,
Unicode byte/character confusion, `indent_size=tab` precedence, recursive-glob
overmatching and its zero-directory counterexample. Tests cover mixed EOL
byte-preserving save, dirty-buffer reconfiguration, Undo, per-file F10/theme
precedence and cumulative matching limits. Adversary: ROBUST for this subset.
Refresh after parser, precedence, newline insertion or style lifecycle changes.

## 5d: Safe session restoration

Persist only versioned UI metadata: canonical project root, bounded tab paths,
active tab, codepoint cursor and scroll positions. Never persist text in this
format; recovery remains separate. Use project-keyed private state under an
explicit override or the platform state directory, bounded JSON and atomic
temporary-file rename. Constructing an App must not write session state: only
the actual session lifecycle activates persistence, so embedded/test App
instances cannot accidentally write into the user's home. Tests inject a
temporary state root. Save only after
quit safety checks succeed; never silently discard a prior valid state when
serialization/write fails. Startup restoration uses ordinary guarded opens
before presenting independent recovery choices. Changed disk files load current
disk text with positions clamped; missing/unsupported files are skipped with a
summary. Never reload or overwrite an already open unsaved buffer, never save
source files as a side effect, never run LSP commands from persisted state.

Scope state by project, reject malformed/unsupported versions and excessive
counts/size/invalid paths, and provide an opt-out. Project switching must not
write one project's tabs into another project's state. A failed quit must not
persist a misleading exit snapshot. Forced quit preserves only UI metadata;
unsaved text follows existing recovery policy.

Tests: roundtrip order/active/cursor/scroll, missing/changed files, malformed and
oversized state, atomic failure, unsaved buffer preservation, project isolation,
recovery interaction and opt-out. Files: new store/controller, app lifecycle,
editor view-state adapter and root specs. CAUTION persistence, fail closed.

The version-1 state is limited to 128 tabs, 1 MiB JSON and 4096-byte paths.
Positions are nonnegative Int32: cursor columns are codepoints, horizontal
scroll columns are terminal cells. Reject state/source paths escaping the
canonical owner project. Missing source files may be skipped during guarded
restore; symlink state targets are rejected. Existing `:cd` keeps open tabs:
save the old project's filtered snapshot before changing roots, then restore
the new project's state without closing or reloading existing dirty buffers.
Normal guarded-open LSP notifications remain allowed; persisted executable
commands and server edits do not. No LSP lifecycle rewrite is implied.

Automatic restoration also has a cumulative 64 MiB source-byte budget, not
merely the ordinary 16 MiB per-file cap: 128 individually valid tabs could
otherwise load 2 GiB before editor and language-server overhead. Admission must
bound actual reads using the remaining budget, report skipped files, and yield
between files. This is a source-byte bound, not an RSS or LSP allocation bound.
Canonical aliases of an already open buffer must reuse that buffer and must not
reset its dirty text, history or view.

Implementation: `SessionStore` owns strict versioned metadata and atomic private
files; `SessionController` gates activity; App lifecycle hooks capture and
restore through `DocumentOrchestrator`. State lives at
`ADAMANTINE_STATE_HOME/sessions`, or `XDG_STATE_HOME/adamantine/sessions`, or
`~/.local/state/adamantine/sessions`. Explicit overrides must be absolute.
`ADAMANTINE_SESSION=0` disables it. Existing non-private owned state directories
are rejected, never chmodded; metadata files are mode 0600 and newly created
directories mode 0700. Source paths are canonicalized by capture; unsafe or
duplicate persisted paths and unknown format fields are rejected. No fallback
to a cached snapshot is allowed after state validation fails.

Observed 2026-09-19: 30 new session examples; full root suite 737 examples,
zero failures/errors; release build, help, formatter and diff checks passed.
Parent counterexamples cover corrupt state, symlinked state ancestors, project
isolation, pre-rename failure preserving previous bytes, disabled/inert lifecycle,
refused quit, current disk text, missing/binary files, dirty aliases beyond the
128th open buffer, stale file-size metadata with a zero remaining budget, and
Unicode viewport overflow/fidelity. A release PTY run opened two tabs through
Ctrl+P, exited and restarted twice: order, active tab and codepoint cursor
persisted, and both source SHA-256 hashes remained unchanged. Recovery's existing
suite also passed; the PTY check used recovery and LSP disabled with temporary
configuration/state. Adversary: ROBUST within this stated scope.

Residual limits: static symlink/containment checks do not certify hostile
same-user validation/open races. State is private, not encrypted; concurrent
instances are last-successful-writer-wins. Directory fsync is best-effort, not a
power-loss guarantee. Source-byte limits do not bound total RSS, piece-tree or
language-server overhead. Filesystem metadata and streamed viewport prefix
calculation remain synchronous; restore yields every 32 entries and ordinary
file reads yield by chunk. Refresh these claims after persistence, lifecycle,
path identity, read-limit or viewport-coordinate changes.

## 5e: Problems across open files

The existing Problems action now builds one deterministic, read-only snapshot
from diagnostics already retained by all live open buffers. Each row carries
its path and exact buffer, editor, document-version, diagnostics-generation and
LSP-client authority. Enter revalidates that authority, switches only to the
already-open tab and moves the cursor without reading from disk. This preserves
dirty inactive text. Any edit, close, replacement publication or LSP-client
replacement closes the aggregate snapshot rather than trying to repair stale
rows in place.

Rows sort by severity, path, position, source and original publication order.
The aggregate retains at most 1000 rows; bounded intermediate compaction keeps
the globally highest-priority rows, and the UI reports partial coverage when
the aggregate or any source publication was truncated. Duplicate basenames are
distinguished by their paths. Alt+N/Alt+P deliberately remain current-file,
source-order actions so this slice does not silently change their navigation
contract.

This is open-buffer aggregation, not project coverage. It performs no scan,
does not retain closed-file diagnostics and cannot claim completeness for an
LSP server or workspace. A future URI-keyed project index requires an explicit
server capability and coverage contract, root containment, unopened-file
freshness, retention bounds and separate guarded-open authority. Unversioned
publishDiagnostics messages still cannot prove freshness before local
invalidation.

Tests cover two-buffer aggregation, deterministic priority, duplicate names,
global bounds and partial state, stale inactive targets, dirty-tab preservation
and modal invalidation. See `PROBLEMS_FRONTIER.md` for the admitted boundary and
falsifiers. CAUTION stale-state and cross-tab navigation authority.

Observed 2026-09-19: 26 focused examples and the full 959 examples passed;
formatter, diff checks, release build and `--help` passed. A two-file LSP PTY
smoke proved relative-path rendering, modal isolation, exact inactive-target
navigation and unchanged disk bytes; the context-actions PTY also passed.
Adversarial red tests caught publication-order tie breaking and project-root
symlink aliases before correction. Verdict: ROBUST within the bounded
open-buffer scope. Unversioned publications, external-path presentation and all
server/terminal variants remain outside the strong claim. Refresh after
diagnostics, path identity, tab switching, modal routing or LSP-client changes.

## 5f: Server-reported workspace Problems

When a ready LSP server statically advertises an object
`diagnosticProvider` with the required boolean `interFileDependencies` and
`workspaceDiagnostics: true`, the existing Problems
action immediately opens a loading modal and requests one final
`workspace/diagnostic` report in a background fiber. The title says **Server
Workspace** because coverage is chosen by the server; Adamantine does not call
the result complete project diagnostics. Unsupported servers preserve the
locally verified open-files view.

The first request sends `previousResultIds: []` and uses no progress token or
result cache. Parsing examines at most 4096 document reports and 4096
diagnostics; the sorted UI retains at most 1000 rows and visibly marks partial
input, malformed or unsupported reports, unknown `unchanged` results and hard
bounds. Live open buffers keep authority over matching workspace reports,
including symlink and hard-link aliases, so a dirty editor is never replaced or
duplicated by disk state.

An unopened result remains metadata-only until Enter. Its URI must identify a
readable regular file whose canonical target is within the canonical project
root and no larger than the ordinary open-file limit. Navigation rechecks the
client, root, request generation, filesystem identity and any newly opened
canonical alias; the reader then enforces the captured stamp while loading.
Only the exact loaded editor converts the report's UTF-16 position. Escape,
edits, replacement publications, client/root changes and stale filesystem
metadata invalidate the snapshot. A failed request falls back to open files.

Observed 2026-09-19: 56 focused diagnostics/Problems examples and the full 982
examples passed with zero failures/errors. Formatter/diff checks, release build,
`--help` and a real pull-capable PTY workflow passed. The PTY showed an unopened
file without opening or changing it before Enter, then proved UTF-16 navigation
after an emoji through the subsequent full-sync edit; both source files stayed
byte-identical. Parent counterexamples cover request failure, managed transport
invalidation, input isolation, row limits, outside-root and symlink escapes,
changed files, and canonical symlink and hard-link aliases. Refresh this
evidence after LSP capability/request parsing, file identity, modal lifecycle or
navigation authority changes. A request-level failure while the same client
remains ready falls back to Open Files; managed transport loss instead closes
the invalidated modal before recovery.

Residual limits: the server may report only a subset and an unversioned closed
file report has no semantic freshness proof beyond Adamantine's captured file
identity. The first slice has no incremental result-id cache, progress stream,
refresh request or request cancellation; a superseded server call may continue
until its 30-second timeout, but cannot publish stale UI state. Filesystem
metadata probes are synchronous and do not certify hostile same-user races.

## Shared verification

For every slice: red discriminating tests, parent-added counterexamples, full
root `crystal spec --link-flags=-fuse-ld=/usr/bin/ld` with a writable cache,
formatter, `git diff --check`, release build and `--help`. Finish the series
with a bounded PTY smoke test using temporary config/state and no LSP. This
does not certify all terminals, language servers or network filesystems.
Update this document and the roadmap with observed evidence, not planned
commands, after each slice. Refresh after parser, lifecycle, coordinate,
persistence or modal-routing changes.
