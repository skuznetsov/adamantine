# Read-only Git view

Status: implemented and locally verified. User explicitly requested reuse
of `crystal_ball/src/tui/git_browser.cr`; source revision inspected:
`b79052cc63805c9d5502190b2a5067f95afbd646`.

Reuse the commit model, active-branch lane calculation and graph-row rendering
from that browser, adapted to bounded app-owned rows. Do not transplant its
synchronous unbounded process runner, delimiter-unsafe log parsing, repo scan,
persistence or mutation callbacks. The dependency DiffView's per-character
renderer and unbounded word-diff preprocessing are not part of this port.

Scope: `:git` opens a modal current-project repository browser: status, commit
history graph and colored unified diff. Disk/index state only; unsaved editor
buffers are not represented. No stage, checkout, reset, merge, network or writes.

Risk: CAUTION (process lifecycle, hostile filenames/output, modal input).
Rollback: revert the isolated feature commit; no persistent format changes.

## Design laws

- Read-only argv-based Git invocations, no shell, pager, external diff or
  textconv. Disable optional locks and lazy fetch; cap output and elapsed time,
  terminate/reap the child on cancellation/limits. Never present a partial
  failure as an empty clean repository.
- NUL-delimited status and structured log fields. Sanitize control characters
  only for display; retain exact paths for argv with literal pathspecs.
- Bounded commit/status counts, bounded graph lanes and bounded diff lines.
  Display all truncation/unsupported states explicitly.
- One running reader plus one latest pending request. Stale results after
  close, reopen, root change or quit must not publish. Escape cancels; all
  modal input is consumed rather than editing the underlying document.
- Use display-cell clipping and small-terminal guards. The graph is a bounded
  history visualization, not a complete topology or history coverage claim.

## Execution and evidence

1. `git_repository.cr`, `spec/git_repository_spec.cr`: first failing probes
   against temporary local repos, then bounded reader/parser and graph port.
2. `git_controller.cr`, app/input-mode/command hooks and integration specs:
   status/history/diff navigation, cancellation, stale publication, paste/mouse
   isolation and narrow-terminal rendering.
3. Parent review, full Crystal suite, formatter/diff checks, release build and
   terminal smoke. Use commands/cache/linker flags in SAFE_EDITS_FRONTIER.md.

Strongest failure: user-controlled Git config runs a helper or an old child
updates a new modal. Test external-diff suppression and cancellation/stale
generation explicitly. Refresh evidence after Git argv/process, parser,
dependency or event-routing changes. This is not a Git write client.

## Supported subset and limits

The reader supports local worktrees (including linked worktrees) with SHA-1
commit IDs. SHA-256 repositories are rejected, not silently misparsed. History
contains up to 200 commits from local refs, status up to 2,000 entries, and the
approximate graph has eight lanes. Porcelain-v2 XY codes retain `.` for an
unchanged side. Submodule internals are deliberately excluded.

Each public read has a shared three-second command deadline. Each command has
a combined stdout/stderr budget of 512 KiB; staged/unstaged diff commands each
receive half that budget. Exceeding a process-output budget is a visible error,
not a partial clean snapshot. Rendered diffs are additionally capped at 4,000
rows, 512 characters per row, and 512 KiB overall, with truncation markers.
File diffs show explicit staged and unstaged sections; untracked content is
unsupported. Refresh is manual; unsaved editor buffers are outside this view.

No external diff/textconv/fsmonitor helper, pager or automatic lazy fetch is
admitted. User/global Git config is excluded; the executable is resolved from
the user's PATH and remains a trusted host dependency. This is not a sandbox
for malicious Git executables or a proof that every Git version has identical
behavior. Normal repository reads may update OS access metadata.

Process state is held in a reference object: Crystal's Atomic is a value type,
so passing bare atomics to reader helpers would copy counters and stop reasons.
Parent regression probes exercise late cancellation, deadline termination,
reaping, output overflow and a shared stdout/stderr budget. Real-repo probes
cover newline/control-character paths, literal pathspecs, linked worktrees and
configured helper suppression with a positive control.

## Observed verification (2026-09-19)

Six reader examples, six modal examples and six parent process/parsing
adversary examples passed. The final isolated-cache parent suite passed all
818 examples (including the added UTF-8 expansion/byte-cap regression).
Formatter/diff checks and release build passed. The real PTY
smoke `ruby scripts/smoke_format_git.rb /private/tmp/adamantine-format-editor`
passed status, history, commit diff and Escape closure, alongside formatting
cancel/apply/Undo, with unchanged source-file disk bytes.

The output-limit/deadline probes first failed against copied atomic state and
passed after introducing reference-owned state. Modal tests cover stale close,
immediate reopen, project switch, narrow terminals and blocked paste/mouse/edit
input. Adversary verdict: ROBUST within this bounded read-only subset. Graph
lanes are approximate and no repository mutation workflow is claimed. Refresh
the evidence after process, parser, modal routing or dependency changes.
