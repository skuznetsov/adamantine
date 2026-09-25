# Responsiveness and resource regression frontier

Status: scenario suite locally verified 2026-09-20; PTY-output diagnostic
measured 2026-09-25 against a prebuilt binary (source linkage unknown; see below).

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
individual cost inside the core replacement/render path. The next discriminating
step for a production change is stage-level profiling of matching, detached-tree
construction/commit, and render; do not infer an optimization target from this
paired run alone. The full-sync path additionally emitted 15.6 MB `didChange`
frames, but frame size and arrival do not directly measure JSON serialization
time.

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
