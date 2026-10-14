# GPT-6 Luna + reviewed Lua demo

This tiny Crystal project demonstrates one bounded Chat turn in Adamantine:
the model inspects the selected source buffer through one locally reviewed,
read-only Lua script, then proposes its own source edit for manual review. The
starter deliberately contains a pagination off-by-one defect. The Lua script
does not contain a repair, generate code, or run tests.

## Contents

- `src/pagination.cr` — the only source buffer to select in the editor.
- `spec/pagination_spec.cr` — 10 deterministic examples. Keep this file
  unopened and unselected during the Chat turn; it is the user's independent
  check after reviewing and saving a proposed fix.
- `config/manifest.json` and `config/scripts/inspect_pagination.lua` — a
  matching example catalog entry and bounded selected-buffer inspector.

The starter is expected to have **10 examples with 2 failures** before the
Chat turn. The red cases are an interior page with `offset = 1, limit = 2`
returning one extra item, and an interior one-item page with `offset = 2,
limit = 1` returning two items. The other cases cover empty input, zero and
negative values, and end-of-buffer boundaries.

## Isolated interactive runner

From the editor repository, use a freshly built production Adamantine binary
and an explicitly configured compatible Lua 5.4 library. The invoking
environment must already contain `OPENAI_API_KEY`; do not paste the key into
the command or a config file.

```sh
ruby scripts/demo_chat_lua.rb \
  --editor-bin "$PWD/bin/adamantine" \
  --library-path "$ADAMANTINE_LUA_LIBRARY" \
  --allow-paid
```

This is an opt-in **real provider call**, not a fake-provider smoke test. The
runner creates a private project copy, config, Lua catalog and compiler cache;
it does not replace personal settings or alter the original starter. It opens
the source in the production editor through a PTY and captures sanitized text
screens, not a graphical terminal screenshot.

The runner stops twice for an operator decision: type `send` only after
reading the full Send review, then `accept` or `reject` after inspecting the
inline proposal. Accepting also authorizes a normal Ctrl+S save to the private
copy and a separate local test run. EOF or timeout is not consent. There is
one model turn, no automatic retry or fallback, and a 300-second whole-run
deadline. Lua completion must be observed in the active production Log view;
an assistant's claim is not a completion signal. The private copy and captures
remain available after the editor process is stopped. The repository's starter
stays deliberately red so another run can reproduce the experiment.

## Prepare the local editor

Adamantine does not discover scripts from this project. Review the sample
Lua source and manifest, then add the script to your personal Lua catalog at
`$HOME/.config/adamantine/lua/`. Put the Lua file under that directory's
`scripts/` folder. If a manifest already exists, merge the one script entry
into its `scripts` array; do not replace your existing catalog wholesale. The
example manifest can be copied only when no personal manifest exists. The
editor loads explicitly listed user scripts on startup.

Configure the following values through `F1 → Chat settings`:

- Endpoint: `https://api.openai.com/v1/chat/completions`
- Model: `gpt-6-luna`
- Credential env var: `OPENAI_API_KEY` (the name, never the key)
- Max output tokens/round: `2048`
- Reasoning effort: `none`

The explicit `none` is required for GPT-6 Luna function calling with this
Chat Completions adapter; it is not inferred from the model name. See the
[official model documentation](https://developers.openai.com/api/docs/models/gpt-6-luna).
Do not put provider credentials in this demo. Chat Lua also needs the editor
process to have an explicit compatible Lua 5.4 shared library configured, for
example `ADAMANTINE_LUA_LIBRARY=/absolute/path/to/liblua5.4.dylib` on macOS (or
the matching `.so` path on Linux). This is a local runtime prerequisite; it
does not make the model's generated code executable.

## One-turn walkthrough

1. Run the RED command below and note the two failing examples.
2. Open `src/pagination.cr` in Adamantine. Do not open or select the spec.
3. Use `F1 → Chat context → Buffer proposals + Lua…`, then choose
   `Inspect selected pagination source` in the named-script picker.
4. In the Chat draft, ask for a diagnosis and a minimal patch to the selected
   buffer. The model may request the approved, parameterless Lua script once;
   the script reads only the exact selected buffer and prints its bounded
   source plus the buffer receipt needed for a proposal. The Lua result
   also supplies exact same-line, half-open replacement spans for
   fully read lines: one-based line numbers and zero-based Unicode columns.
   These are host-returned coordinates, not Lua byte-length guesses. The
   model should preserve indentation and add no trailing newline when using
   one of these spans. Incomplete lines have no full-line replacement hint.
   The initial provider request contains only reviewed script metadata. After
   the model requests the script, its bounded result (including the selected
   source text and project-relative path) is sent to the provider. Review this
   permitted later export in the Send disclosure before approving the turn.
5. Inspect the complete local Send review, including the Lua source,
   capabilities and selected-buffer receipt. Approve it only if it matches
   this demo. The model should call `editor.propose_edits` with its own patch;
   Lua itself has only `read_editor` and cannot stage edits.
6. Review the inline proposal. Accept manually and save only if the diff is
   correct. Escape rejects it. Neither Chat nor Lua applies or saves changes
   automatically.
7. Run the spec yourself after saving. Do not claim that Chat ran the tests.

Suggested single-turn prompt (include the measured failing contract in the
prompt; keep the spec unopened):

> Diagnose the pagination defect in the currently selected source buffer.
> The contract is zero-based `offset` and a count-valued `limit`: return at
> most `limit` items, with the final page shortened at the end. The measured
> failures are: on `red, green, blue, amber, indigo`, `(offset=1, limit=2)`
> returns `green, blue, amber` instead of `green, blue`; `(offset=2, limit=1)`
> returns `blue, amber` instead of `blue`. Use only the approved read-only
> selected-buffer script to inspect the source, then propose a minimal fix to
> this buffer. Use the inspector's exact full-line span, preserve the original
> indentation, and add no trailing newline. Do not guess substring columns.
> Do not inspect or request the spec, do not claim to run tests,
> and explain the boundary reasoning so I can review it manually.

The prompt supplies measured behavior instead of asking the model to inspect
the tests. This keeps the demo to one source-buffer turn and leaves the spec
as an independent post-edit check. A useful harness captures the Send review,
selected-buffer receipt, script tool result, proposal diff, manual acceptance,
saved source, and post-save spec output. It should not treat an assistant
claim as evidence that tests ran.

## Run the deterministic spec

Use a private compiler cache and a missing config path so the check does not
depend on personal editor configuration. This does not modify `HOME` or write
to the personal Lua catalog:

```sh
DEMO_TMP="$(mktemp -d)"
mkdir -p "$DEMO_TMP/crystal-cache"
CRYSTAL_CACHE_DIR="$DEMO_TMP/crystal-cache" \
ADAMANTINE_CONFIG="$DEMO_TMP/no-config.json" \
CRYSTAL_EDITOR_CONFIG= \
crystal spec --error-trace --link-flags=-fuse-ld=/usr/bin/ld \
  examples/luna_lua_demo/spec/pagination_spec.cr
```

The initial nonzero exit with exactly two assertion failures is intentional.
After manually accepting and saving a correct patch, rerun the same command;
all 10 examples should pass. No live model call is needed for either test run.

On Linux, omit the macOS-specific `--link-flags=-fuse-ld=/usr/bin/ld` option.

## Independent boundary checker

After the private save, `scripts/check_luna_lua_pagination.cr` checks 704
cases with a separate index-iteration oracle: three element types, sizes
0..6, offsets through two past the end, deduplicated limits including
`Int32::MAX`, the interior regression and negative-input error ordering.
It is not sent to the model. Run it from the editor repository:

```sh
DEMO_PROJECT=/absolute/path/to/the/private/project
DEMO_CHECK_CACHE="$(mktemp -d)"
DEMO_CRYSTAL_PATH="$(crystal env CRYSTAL_PATH)"
CRYSTAL_PATH="$DEMO_PROJECT/src:$DEMO_CRYSTAL_PATH" \
CRYSTAL_CACHE_DIR="$DEMO_CHECK_CACHE" \
ADAMANTINE_CONFIG="$DEMO_CHECK_CACHE/no-config.json" \
CRYSTAL_EDITOR_CONFIG= \
env -u OPENAI_API_KEY crystal run --link-flags=-fuse-ld=/usr/bin/ld \
  scripts/check_luna_lua_pagination.cr -- "$DEMO_PROJECT/src/pagination.cr"
```

The target is selected by the first directory in `CRYSTAL_PATH` at compile
time; the trailing source-path argument labels it and checks its existence.
Keep those paths consistent. The original starter should fail this checker.

## Observed live trial (2026-10-14)

The third separately reviewed GPT-6 Luna turn completed the real production
editor/HTTP/Lua/proposal path. It proposed only the interior endpoint change
from `offset + limit` to `offset + limit - 1`, preserving the existing
overflow-safe clamp. After manual acceptance and normal Ctrl+S to the private
copy, the unchanged 10-example spec and the independent 704-case checker
passed. The original starter remains red; no repair is embedded in Lua.

The two earlier real turns were not accepted or saved: the first also exposed
a bounded PTY parser/navigation-glyph issue, and the second settled preview
was malformed and was rejected. Their raw edit arguments were not retained,
so the exact producer cause is not proven. A known-correct loopback edit
rendered and saved correctly; the next real turn used inspector-provided
full-line spans instead of guessed substring columns. This is a successful
single example, not a model reliability benchmark or proof of universal
renderer correctness.

The inspector's real-worker tests separately cover receipt identity,
completion metadata, Unicode columns, partial rows, row order/range and
bounded output. The harness deliberately uses `TUI_AMBIGUOUS_WIDE=0` for its
owned child PTY, without changing personal terminal settings. This trial used
a real release App in a PTY, not a native terminal-window GUI automation or a
remote Linux/macOS CI run. Further provider calls stopped after the success;
the user's $3 daily allowance was managed with a conservative reservation,
not a measured billing total. See the
[scoped evidence packet](../../.landmark/evidence/luna-live-demo.json).
