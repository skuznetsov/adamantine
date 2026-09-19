# Daily workflow frontier

Status: 5a locally verified after completion commit `6c8bf9a`;
5b–d remain designs, not implemented or verified by this document.
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

Tests: severity ordering, empty results, wraparound, Unicode ranges, invalid
positions, delayed older versions, client replacement, buffer edits, modal
isolation and navigation. Files: diagnostic model/parser, `document_types.cr`,
LSP controller, modal/key routes and root specs. CAUTION stale-state authority.

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

## Shared verification

For every slice: red discriminating tests, parent-added counterexamples, full
root `crystal spec --link-flags=-fuse-ld=/usr/bin/ld` with a writable cache,
formatter, `git diff --check`, release build and `--help`. Finish the series
with a bounded PTY smoke test using temporary config/state and no LSP. This
does not certify all terminals, language servers or network filesystems.
Update this document and the roadmap with observed evidence, not planned
commands, after each slice. Refresh after parser, lifecycle, coordinate,
persistence or modal-routing changes.
