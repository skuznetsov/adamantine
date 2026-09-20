# Responsiveness and resource regression frontier

Status: locally verified, 2026-09-20.

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
- No guarantee for files above the existing 16 MiB document limit or for every
  external language server and terminal.

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
