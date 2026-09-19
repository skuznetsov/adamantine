# Searchable command palette

## Contract

This slice implements action discovery, not a general keymap/context-menu rewrite.
F1 and Ctrl+Shift+P open an empty action search. Names, descriptions and aliases
are searchable without colon syntax. Up/Down select a visible result, Enter
invokes it, Tab prepares its colon command, and Escape cancels. Empty search
starts on a safe Help action. Actions requiring arguments prepare a command
and show the required argument rather than invoking an empty operation.
Repeated Enter keeps a prepared required-argument command open until its
argument is supplied, including commands prepared by legacy Tab completion.
Manually typed legacy commands retain their existing no-argument semantics.
Preparation belongs to an action identity, not an argument label: editing a
prepared `:open` into explicit `:cd` must not transfer its guard merely because
both actions show `<path>`.
Exact aliases rank before descriptive matches. Changing the query resets the
selection to its first match, rather than retaining an unrelated row index.

Typing `:` explicitly enters legacy command mode. Double Escape and existing
pre-seeded command entry points retain legacy command mode. Slash/question-mark
search and replacement syntax remain available there. Command-mode Enter runs
the typed command, never a fuzzy substitute. Force quit is never discoverable;
only explicit `:q!` retains that authority. No-result Enter is inert.

Palette arrows now select search results; Alt+Up/Alt+Down recall history in
either mode. Plain letters remain text. Existing raw-command history arrows
may remain supported in command mode. Shortcut hints use the current keymap,
including remaps/unbound actions. Rendering stays within the supplied clip,
with selection scrolling. Opening/using the palette must not edit the buffer
or bypass close/external-review modal guards.

## Plan and verification

Risk: CAUTION: command dispatch can save or close documents. Rollback is the
isolated feature commit; no dependency, storage or configuration migration.
Strongest failure: fuzzy matching accidentally dispatches a destructive command
or treats a search phrase as a file argument. Separate explicit-command and
discovery modes, hide force quit and test no-match/argument preparation.

Luna owns catalog metadata, palette controller/rendering/state, input opener,
and focused specs. Parent owns this contract, user docs and real PTY probes,
and reviews the implementation and executes integrated verification.

DoD: focused falsifiers first; full `crystal spec`, formatter check, release
build and a real PTY discovery/selection/argument/cancel workflow, plus existing
external-review, close-confirmation, formatting and refactoring PTY regressions.
Use writable `/private/tmp` caches and the system linker on this host.
Evidence is local to the tested source state; changes to dispatch, keymaps,
modal routing or renderer invalidate it. Other terminals remain unverified.

## Baseline falsifiers

Before implementation, the parent authority spec ran three cases: discovery
`q!` incorrectly closed the app and printable menu remaps incorrectly closed
the palette (two failures); existing dirty-quit confirmation isolation passed.
The new PTY script failed against the prior release binary at the Open File
argument workflow, distinguishing the new capability from existing raw commands.
The Ruby harness was first corrected for the host's pre-`filter_map` Ruby;
that harness error is not counted as a product falsifier.

Interim regression probes also rejected a hidden selected row after shrinking
the terminal, premature execution of a prepared command on a second empty
Enter, and legacy Tab completion leaking subsequent path text into the editor.
The last case uses the LSP fixture's actual document-change events as its oracle,
not just popup text.

## Verification evidence (2026-09-19)

Parent reran the following on the final source after Luna's implementation and
review fixes; all exited successfully:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-palette-parent crystal spec --link-flags=-fuse-ld=/usr/bin/ld
crystal tool format --check src spec
git diff --check
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-palette-build crystal build src/adamantine.cr --release --link-flags=-fuse-ld=/usr/bin/ld -o /private/tmp/adamantine-palette-editor
ruby scripts/smoke_command_palette.rb /private/tmp/adamantine-palette-editor
ruby scripts/smoke_external_review.rb /private/tmp/adamantine-palette-editor
ruby scripts/smoke_close_confirmation.rb /private/tmp/adamantine-palette-editor
ruby scripts/smoke_refactor.rb /private/tmp/adamantine-palette-editor
ruby scripts/smoke_format_git.rb /private/tmp/adamantine-palette-editor
```

Full suite: **924 examples, zero failures/errors/pending**. All five real PTY
scenarios returned PASS on the release binary. The new palette probe covers
actual F1 input, phrase/description dispatch, required-argument preparation and
repeated Enter, raw Tab preparation, cancellation, paste/no-result isolation,
selected-row Save and explicit force-quit cleanup. Existing probes retain
external-conflict, dirty-close, formatting/refactor preview and Git coverage.

Parent adversary verdict: **ROBUST within this slice**. Targeted tests also
cover dirty-quit authority, remapped printable controls, remapped/unbound hints,
literal unknown commands, history recall, resize propagation, wide-character
clipping and selected-row visibility at heights 6, 8 and 14. Same-lineage agent
review is correlated; the verdict rests on source inspection and these executed
behavioral probes, not agreement between agents.

Review after the initial feature commit `4750211` reopened the preparation
boundary: shared `<path>` hints incorrectly transferred the guard from prepared
Open File to manually edited Change Directory. Controller and rendered-input
regressions failed before the fix. Preparation now records the canonical action
and matches only that action or its aliases; opening, closing and history recall
reset the identity. Parent reran the full suite, release build and all five PTY
scenarios after this fix; the counts above describe that refreshed state.

Residual scope: clips shorter than six rows cannot display a normal results
row, although drawing remains bounded. General editable-field navigation,
contextual action availability, context-menu unification and other terminal
emulators remain outside this result. Refresh the evidence after dispatch,
keymap, modal-routing or rendering changes.
