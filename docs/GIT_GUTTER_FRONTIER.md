# Read-only Git gutter frontier

Document status: implemented and locally verified on 2026-09-23.
Current frontier: show bounded line-change markers for the saved, tracked current file against local `HEAD`.
Bounded context: the existing read-only Git process boundary and the editor's line-number gutter.
Problem: `:git` exposes diffs, but a user cannot see which visible lines changed without leaving the file.

## Admitted surface

- Use the unused trailing cell of the existing line-number gutter for added,
  modified, and deletion-anchor markers. Do not reduce the text viewport or
  displace the fold control. The marker is informational and has no click action.
- Compute against local `HEAD` and the saved worktree file, combining staged
  and unstaged changes. Parse only zero-context hunk metadata; retain only
  markers after the runner's bounded output is parsed, never the full file.
  Resolve Git paths literally through the existing read-only, deadline- and
  output-bounded runner.
- Run Git outside the render and input paths. Publish only while the same file,
  editor instance, project, clean document, and accepted disk stamp remain
  current. Invalidate on edit, tab close/switch, project change, and save;
  refresh after save/open. The stamp probe reads metadata only, not file bytes.
- Bound the marker count. A failed, cancelled, oversized, binary, or unsupported
  read clears the old markers and gives a concise, non-spamming status signal.

## Rejected surface

- No staging, checkout, reset, index mutation, network, or repository writes.
- No unsaved-buffer diff, untracked-file markers, blame, or historical compare.
- No synchronous Git invocation from rendering, scrolling, or keystrokes.
- No marker shown as current if the buffer is dirty or the source identity has
  changed. Empty/unsupported is not represented as a confirmed clean file.

## Execution and falsifiers

1. Reader: a temporary-repository spec must first fail for added, modified,
   and deleted hunks, staged plus unstaged state, literal unusual paths, and
   bounded failure. Implement the smallest reader using the existing runner.
2. Renderer/controller: a real editor integration spec must first fail for
   visible markers, folds, narrow terminals, stale publication, and dirty
   buffer suppression. Wire open/save/switch lifecycle with one active reader
   and latest-request cancellation.
3. Verify focused specs, full suite, formatter, release build, and a terminal
   smoke. Inspect the diff for Git writes and synchronous hot-path work.

Risk: CAUTION (async publication, Git process output, editor viewport).
Rollback: revert the isolated feature commit; no persistent format changes.
Strongest failure: delayed markers for another file or dirty revision appear
beside the current text. The stale-result and dirty-buffer specs guard this.

## Verification and residual boundary

- The parser and UI specs reproduced mixed-hunk misclassification, a denied
  close that erased markers, and publication after unseen disk bytes replaced
  the editor's accepted revision before the corresponding guards were added.
- `crystal spec --link-flags=-fuse-ld=/usr/bin/ld`: 1056 examples, no failures
  or errors. `crystal tool format --check src spec` and `git diff --check`
  passed. The release build and `scripts/smoke_format_git.rb` passed with the
  same system-linker workaround; the terminal smoke covers editor launch and
  existing Git/format interactions, while gutter geometry and lifecycle are
  covered by focused specs.
- The metadata stamp does not close a change occurring after publication, or
  a change that preserves all compared metadata. The external-file monitor
  remains responsible for eventual fingerprint detection and conflict UI.
  Oversized and unsupported diffs fail closed with no markers, not a claim
  that the file is clean.
