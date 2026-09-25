# Responsiveness and resource regression frontier

Status: scenario suite locally verified 2026-09-20; PTY-output diagnostic
measured 2026-09-25 against a prebuilt binary (source linkage unknown; see
below); source-linked replacement stages measured 2026-09-25 (see follow-up).

This slice turns Adamantine's existing large-input probes into one repeatable
scenario set and closes a transport path that can otherwise freeze editor
input.  The acceptance contract is behavioral and structural.  Machine-local
timings and allocator counters remain observations, not portable CI limits.

## Admitted surface

- Multi-megabyte many-line and single-line fixtures exercise bounded buffer
  search, lexical highlighting, inline preview, and bulk replacement.
- Scenario checks preserve exact results, cancellation/publication guards,
  bounded source and cache work, atomic replacement, and Undo/Redo behavior.
- LSP requests and notifications retain wire order but are written by one
  bounded writer fiber.  A server that stops reading stdin must not suspend the
  editor/input fiber in the pipe write.
- Outgoing transport retention is explicitly bounded.  Saturation or an
  oversized payload fails the transport closed, releases pending requests, and
  enters the existing recovery path instead of blocking or dropping protocol
  state silently.
- A scheduled/manual workflow runs the release probes outside the ordinary PR
  gate and emits a structured report with toolchain and platform identity.

## Rejected claims

- No universal latency, frame-time, peak-RSS, or allocation threshold.
- No claim that GC allocation deltas equal retained editor memory.
- No claim that a yielding-fiber gap equals key-to-visible-echo latency.
- No silent notification drop, unbounded outgoing queue, or concurrent pipe
  writers.
- No asynchronous bulk-replacement publication in this slice; replacement is
  still an atomic synchronous command and its elapsed time remains diagnostic.
- No claim that PTY output receipt equals terminal-emulator frame acknowledgment
  or physical display scan-out.
- No guarantee for files above the existing 16 MiB document limit or for every
  external language server and terminal.

## Key-to-PTY-output diagnostic (not a display-latency SLA)

`scripts/benchmark_input_latency.rb` measures from the monotonic timestamp just
before writing Kitty keyboard-protocol bytes to the application's PTY, until
the PTY reader receives output that makes a small VT grid model contain the
expected changed ASCII text. This is an input-to-PTY-output/rendered-cell
hand-off proxy only: it does not observe an emulator acknowledgment, rasterized
frame, scan-out, or physical pixels. The grid model is intentionally bounded
to the CUP/erase/cursor sequences used by these ASCII markers.

The observer has a no-input negative control and a same-process positive
control. The negative control watches for a unique absent marker for 100 ms
without writing input. The positive control writes an edit key while the app
child is confirmed stopped with `SIGSTOP`, verifies the marker is absent while
stopped, then resumes it and checks that the PTY observer reports the delayed
marker. This validates the probe's delay sensitivity, not a user-facing
latency bound.

The 2026-09-25 paired diagnostic used this exact command on Darwin 25.6.0,
arm64, Ruby 2.6.10 (the report omits the machine hostname):

```sh
ruby scripts/benchmark_input_latency.rb \
  --binary /tmp/adamantine-template-split-smoke \
  --size-mib 15 --repeats 3
```

The fixture was a temporary 15,728,640-byte single-line plain-text document,
1,048,576 bytes below `DocumentOrchestrator::MAX_FILE_BYTES` (16,777,216).
The replace case changed 61,440 `old` matches. The supplied executable was a
prebuilt 3,906,224-byte binary at
`/private/tmp/adamantine-template-split-smoke`, SHA-256
`9dafa73402e036553c1b72aa7ceaca7d9827139831e4324aeaab8a2b3b9b5cd3`, modified
at `2026-09-25T00:30:24Z`; its build checkout/revision is unknown. The script
checkout's HEAD was `f2e173943aa6b53fe2d87c85ce17e4e3c2bea36a`, but the measurement
must not be attributed to that source revision. Re-run against a binary built
from the source state under review before using these values comparatively.

| Case | Median | nearest-rank p95 | Worst | Spread | Evidence |
| --- | ---: | ---: | ---: | ---: | --- |
| No-LSP key edit | 82.610 ms | 113.494 ms | 113.494 ms | 51.631 ms | 3 runs |
| No-LSP file open | 1,308.692 ms | 1,934.315 ms | 1,934.315 ms | 1,391.058 ms | Open-path interval includes file loading |
| Full-sync LSP file open | 472.138 ms | 1,187.259 ms | 1,187.259 ms | 798.057 ms | Fake server received `didOpen` frames of 15,728,907 bytes |
| Full-sync LSP key edit | 68.122 ms | 72.484 ms | 72.484 ms | 8.857 ms | Fake server received `didChange` frames of 15,728,906 bytes |
| No-LSP bulk replace | 464.126 ms | 837.584 ms | 837.584 ms | 439.099 ms | 61,440 matches; replace and local render path only |
| Full-sync LSP bulk replace | 479.176 ms | 782.683 ms | 782.683 ms | 326.681 ms | 61,440 matches; `didChange` frame 15,606,028 bytes |

For three samples, nearest-rank p95 is the maximum sample; it is not a stable
tail estimate. The replacement cases are paired by fixture, executable and
iteration, with the no-LSP run immediately before the full-sync LSP run. The
paired full-sync-minus-no-LSP deltas were `[-358.408, 318.557, 57.517]` ms
(median `57.517` ms; nearest-rank p95 `318.557` ms). Their sign and size vary
substantially, so this three-pair sample does not isolate a stable LSP cost.
Both paths took hundreds of milliseconds, and the no-LSP path alone reached
`837.584` ms. This makes synchronous full-text LSP publication insufficient as
the sole explanation for the observed replace delay, but does not identify the
individual cost inside the core replacement/render path. The source-linked
follow-up below adds stage probes; the earlier binary measurements remain
unattributed to this checkout. The full-sync path additionally emitted 15.6 MB
`didChange` frames, but frame size and arrival do not directly measure JSON
serialization time.

The negative control sent zero input bytes over 100 ms and observed no target
marker (zero PTY output bytes in this run). The positive `SIGSTOP` control
observed a 250.694 ms forced pause and 254.652 ms input-to-grid latency; the
marker was absent while stopped and arrived 3.958 ms after `SIGCONT`. This
calibrates that the observer notices a seeded delay through the child-process
output path; it still does not observe terminal scan-out. Saved post-measurement
key-edit and both replacement outputs matched exact expected byte lengths and
SHA-256 digests; the original fixture remained 15,728,640 bytes with unchanged
SHA-256. RSS was not sampled. These are host-local diagnostics, not portable
thresholds, an SLA, or a CI pass criterion.

To build the probe's own release executable in a restricted local sandbox, use
a writable task-specific Crystal cache, for example:

```sh
CRYSTAL_CACHE_DIR=/private/tmp/adamantine-input-latency-crystal-cache \
  ruby scripts/benchmark_input_latency.rb --size-mib 15 --repeats 3
```

The cache override is an environment accommodation; a denied default cache
directory is not evidence of an application failure. The report records the
binary path, digest, modification time, and whether it was built by that run.
The run reported above did not build the current source, so it does not verify
the documented source-build invocation.

## Source-linked bulk-replace stage diagnostic

`scripts/profile_replace_stages.cr` imports the current working-tree editor and
replacement code, and runs `EditingTextEditor#replace_literal` directly rather
than launching a prebuilt application. The measured source was based on
`3646d5b346b3f8fde1bf3443302beda2c11bfcb3`; the replacement production files
were unchanged from that revision. The fixture is the same 15 MiB (15,728,640
byte) single-line ASCII pattern as above: `old` followed by 253 `x` bytes,
repeated 61,440 times. Each positive run verified the exact expected output.

Two successive invocations each collected five samples. The table reports
median and full observed range in milliseconds; variation between invocation
sets is itself a warning against treating these as stable host-independent
costs.

| Probe | Set A median (range) | Set B median (range) |
| --- | ---: | ---: |
| Match scan only | 75.090 (73.738–75.740) | 90.364 (84.947–99.439) |
| Capture matches for replay | 87.695 (75.693–93.992) | 105.594 (85.005–111.091) |
| Detached-tree batch/splice replay | 115.463 (113.907–119.462) | 139.242 (125.088–151.345) |
| Candidate line-ending scan | 70.792 (69.064–76.889) | 86.684 (80.226–95.860) |
| Editor commit tail | 0.022 (0.021–0.024) | 0.026 (0.023–0.028) |
| Actual `replace_literal` total | 269.225 (263.266–273.357) | 321.972 (281.090–401.431) |
| Direct editor-widget render, 80×24 | 0.092 (0.085–0.121) | 0.118 (0.097–0.137) |
| No-match scan control | 48.101 (47.409–48.398) | 58.091 (53.193–69.788) |
| No-match `replace_literal` control | 47.426 (46.972–56.910) | 61.043 (54.445–70.255) |

These are independent probes, not additive timing slices. In particular,
`match_capture_for_replay` retains 61,440 match records, and the detached-tree
probe replays the bounded batch/splice loop over those precomputed matches. It
calls the current range-adjustment and atomic-splice helpers, but excludes the
actual method's interleaved per-match guards and is not an exact measurement of
its tree-construction cost. The separately timed line-ending probe invokes the
current helper on that candidate; because this fixture has no CR or LF, it
scans the full candidate. The commit-tail probe reuses that measured result.
Direct widget render measures only one 80×24 `EditingTextEditor#render` call
into a TUI buffer, not app composition, TUI buffer flush, PTY output, or display
scan-out. No application/LSP client is attached, so this does not measure
publication or end-to-end user-visible latency.

The negative control searched for an absent literal: it found zero matches,
`replace_literal` returned false, text stayed byte-identical, and no undo entry
was created. Its API duration stayed near its scan-only duration, consistent
with the no-match path stopping after matching. The positive output checks and
this negative control establish probe sensitivity to a real replacement and
to a true no-op, not a performance threshold.

The two sample sets support investigating the full-document match and
line-ending passes and the detached-tree preparation; they do not establish a
specific optimization, its safety, or its expected speedup. In particular, the
line-ending measurement identifies a cost on this no-newline fixture but does
not show that any shortcut preserves newline-style behavior. The low direct
widget-render times narrow only this viewport/render call, not every render
path. Do not compare these source-linked method timings directly with the
earlier prebuilt-binary PTY timings.

Both runs used macOS Crystal 1.21.0, LLVM 22.1.8. The default linker rejected
macOS TAPI `.tbd` files through `ld64.lld`; the system-linker setting below
worked. The default Crystal cache was not writable in the run environment, so
the command uses a task-specific temporary cache:

```sh
CRYSTAL_CACHE_DIR=/tmp/replace-stage-crystal-cache \
  crystal run --release --link-flags='-fuse-ld=/usr/bin/ld' \
  scripts/profile_replace_stages.cr -- 15 5
```

The command prints the Crystal version and emits one CSV row per stage/sample.
Elapsed time and gross allocation deltas are local diagnostics, not CI
thresholds or retained-memory estimates.

## One-line candidate line-ending fast path

`EditingTextEditor#replacement_line_ending` now returns the existing
`@line_ending` immediately when `candidate.line_count == 1`. This guard relies
on the installed `PieceTreeBuffer` implementation: it counts LF and standalone
CR as line breaks, and corrects a CRLF pair split across piece-tree nodes to count
once. Therefore one line certifies that the candidate contains no CR or LF;
the old scan would have found no newline and returned the same remembered
style. This evidence expires if the installed dependency's line-count
definition changes.

The focused integration specs include a slice-forbidden one-line candidate
(which failed before the fast path), standalone CR and CRLF replacement-style
regressions after starting from LF input, and a CRLF seam formed across tree
pieces. These guard both the early-return condition and preservation of the
old style when there is no newline to detect.

The committed stage profiler was run in release mode before and after the
change on the same 15 MiB, 61,440-match fixture, with five samples each. Both
runs were source-linked from the working tree at base revision
`ead272607088a9958e1d049c7fc3b6a678b499f3`; the after run additionally had the
fast-path edit in `src/adamantine/editing_text_editor.cr`. Crystal was 1.21.0
on macOS arm64. Values are medians and full ranges in milliseconds:

| Probe | Before | After |
| --- | ---: | ---: |
| Actual `replace_literal` | 264.681 (253.593–352.832) | 193.283 (191.479–210.774) |
| Candidate line-ending helper | 71.763 (66.837–79.132) | 0.000 (0.000–0.000) |
| No-match `replace_literal` control | 49.717 (47.046–51.691) | 47.934 (47.589–55.869) |

The line-ending stage's after time rounds to 0.000 ms at the script's three
decimal places and allocated zero gross bytes in all five samples. The actual
replace median fell by 71.398 ms (27.0%); matching, detached-tree replay,
commit, and direct widget-render probes stayed in the same rough ranges. This
is consistent with removing the measured full-candidate scan, but the probes
are independent/non-additive and the sequential samples are host-local, so the
full-method delta is not a portable speedup guarantee. No-match timings act as
a control for the unaffected no-change path. Exact replacement output remained
validated in every positive iteration. The fast path does not cover candidates
with CR or LF; those continue through the existing scan, which is why the
standalone-CR and CRLF style regressions remain important.

## Risk, rollback, and invariants

Risk is CAUTION: changing transport ordering or teardown can desynchronize a
server, leak a child process, strand a pending request, or deadlock shutdown.
Rollback is the single slice commit.  The user's unrelated `Makefile` change
must remain untouched.

The writer starts before initialization, preserves enqueue order, and is the
only fiber that touches server stdin.  Queue admission never waits for space.
Writer failure, queue saturation, EOF, and explicit stop converge on the
existing once-only transport-detach boundary.  Stop closes the queue and pipe,
releases pending requests, bounds writer/reader cleanup, and reaps the child.

## Falsifiers

1. A real fake server completes initialize and then stops reading stdin.  A
   multi-megabyte full-document change fills the pipe while a separate marker
   proves the calling/input fiber continues before the server is released.
2. Fill the bounded outgoing queue behind the blocked writer.  Admission must
   fail closed without waiting; the failure callback fires once and pending
   requests are released.
3. Normal initialize/request/notification/shutdown traffic arrives in order,
   and a replacement client works after the blocked client is stopped.
4. Existing recovery, response-limit, async-LSP, and lifecycle specs remain
   green; these are the nearby deadlock and stale-publication counterexamples.
5. Release probes must contain the expected fixture rows and non-negative
   metrics.  Malformed/missing output and a hung child must make the scenario
   runner fail; a self-test qualifies both detectors.

Timing, gross-allocation, live-GC, and cooperative-gap fields are observations.
They may be compared only with compatible host/toolchain fixtures and cannot
promote a behavioral failure to a pass.

## Implemented boundary

`Lsp::Client` now starts one writer fiber before initialization. Callers only
perform a non-blocking enqueue; the writer alone owns the stdio write order.
The queue retains at most four frames and accounts for the active write plus
queued payloads against a 128 MiB aggregate budget. The same 128 MiB per-frame
cap covers the worst-case JSON escaping of an admitted 16 MiB document with
envelope headroom. Count or byte saturation disconnects the transport, closes
the pipe to release a blocked writer, releases pending requests and invokes the
existing recovery callback once. It never drops a `didChange` and continues as
if the server had received it.

The no-read regression uses a real Ruby child: it completes initialization,
then stops consuming stdin while a multi-megabyte `didChange` fills the pipe.
The caller returns before the child is released. Additional tests cover normal
wire order, aggregate backpressure, once-only failure publication, pending
request release, process reap and replacement-client startup.

`scripts/verify_responsiveness.rb` separately builds six release probes and
then runs their binaries, so sampled RSS does not include Crystal compilation.
It validates exact CSV schemas, fixture coverage and non-negative numeric
fields, then runs the asynchronous LSP/write-queue batch. Output capture is
bounded. Every direct child has a process-group watchdog with TERM/KILL cleanup,
and output draining has its own deadline so a descendant that escapes the group
cannot strand capture threads after either timeout or normal parent exit. The
runner emits one versioned JSON report; a weekly/manual GitHub workflow runs it
outside the ordinary pull-request gate. On hosts where `ps` sampling is denied
or unavailable, RSS is `null` with zero samples and does not change the result.

Full-document LSP JSON construction still happens synchronously before enqueue
and can temporarily allocate a large serialized string. Bulk replacement also
remains synchronous. The new writer removes unbounded pipe waiting from the
calling fiber; it does not claim to make serialization or replacement
incremental, nor does it establish key-to-visible-render latency.

Recovery replaces a failed `Lsp::Client` instance and then stops the old one.
Restarting the same failed instance before its reader fiber has unwound is not
an admitted lifecycle. Direct users that do not install the recovery controller
must still call `stop` after transport failure to reap the server process.

## Verification evidence

Observed on macOS with Crystal 1.21.0:

- `ruby -w -c scripts/verify_responsiveness.rb` reported `Syntax OK`.
- `ruby scripts/verify_responsiveness.rb --self-test` passed malformed-output
  rejection, timed-out child reap, and escaped-descendant output-holder
  counterexamples after both timeout and successful direct-child exit.
- `ruby scripts/verify_responsiveness.rb` reported all seven scenarios PASS:
  six multi-megabyte release probes and 23 asynchronous LSP/write-queue specs.
  The local sandbox denied `ps`, so RSS remained explicitly unavailable.
- The focused transport/recovery/response-limit/hardening batch passed 30
  examples.
- The complete suite passed 987 examples with no failures or errors.
- Crystal formatting, `git diff --check`, a release build to a temporary path,
  and the binary's `--help` smoke passed.

## Definition of Done

- Focused write-queue regression and neighboring LSP transport/recovery specs
  pass with a writable Crystal cache.
- The scenario runner passes its parser/watchdog self-test and a complete local
  release run.
- The full Crystal suite, formatter, diff check, release application build, and
  `--help` pass.
- The final evidence records exact commands, observed counts, and residual
  synchronous/full-materialization boundaries without converting diagnostics
  into an SLA.
