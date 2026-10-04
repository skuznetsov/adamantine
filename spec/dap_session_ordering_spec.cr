require "spec"
require "../src/adamantine/debug_session_state"

def active_debug_session(project_generation : UInt64 = 0_u64) : Adamantine::DebugSessionState
  Adamantine::DebugSessionState.initial(project_generation)
    .begin_session("lldb-dap", "ordering-spec-client", project_generation)
    .configuring
    .activate
end

describe Adamantine::DebugSessionState do
  it "keeps lifecycle, execution, and target liveness independent" do
    state = Adamantine::DebugSessionState.initial
    raise "new session must be idle" unless state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Idle
    raise "execution must start unknown" unless state.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "target liveness must start unknown" unless state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown

    state = state.begin_session("lldb-dap", "lifecycle-spec-client")
    raise "begin must not invent a live target" unless state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown
    state = state.configuring.activate
    raise "activation must not invent execution state" unless state.execution == Adamantine::DebugSessionState::Execution::Unknown
  end

  it "treats process-started as liveness evidence only" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    started = state.process_started(stamp)
    raise "process event proves liveness" unless started.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
    raise "process event does not invent execution" unless started.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "process event does not invent a thread" unless started.tracked_thread_count == 0

    exited = started.exited(stamp)
    late_event = exited
      .process_started(stamp)
      .continued(stamp, thread_id: 7_i64, all_threads_continued: true)
      .stopped(stamp, thread_id: 7_i64, all_threads_stopped: true)
      .thread_seen(stamp, 8_i64)
    raise "late events cannot revive known exit" unless late_event.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Exited
    raise "late events cannot infer execution after exit" unless late_event.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "late thread event after exit must be ignored" unless late_event.tracked_thread_count == 0
    ended = late_event.terminated(stamp)
    terminal_process = ended.process_started(stamp)
    raise "process event cannot revive terminal session" unless terminal_process.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended
  end

  it "does not invent a thread when a stopped event omits its id" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: nil, all_threads_stopped: nil)

    raise "missing thread id must not create a synthetic thread" unless state.tracked_thread_count == 0
    raise "missing allThreadsStopped proof cannot mean all stopped" unless state.execution == Adamantine::DebugSessionState::Execution::Partial
    raise "a stopped event is evidence that the target was alive" unless state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
    raise "no selected thread should be invented" unless state.selected_thread_id.nil?
  end

  it "marks only the identified thread stopped when allThreadsStopped is absent" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: 7_i64, all_threads_stopped: nil)

    raise "thread 7 should be stopped" unless state.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    raise "an omitted allThreadsStopped flag is only partial" unless state.execution == Adamantine::DebugSessionState::Execution::Partial
    raise "thread ids must remain debugger ids, not inferred fiber ids" unless state.tracked_thread_ids == [7_i64]
  end

  it "uses a fresh stop-certified threads listing without inventing a thread id" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    all_stopped = state.stopped(stamp, thread_id: nil, all_threads_stopped: true)
    stop_certificate = all_stopped.certificate(20_u64, Adamantine::DebugSessionState::RequestScope::Stop)

    raise "all-stop without an ID must not synthesize a thread" unless all_stopped.tracked_thread_count == 0
    event_only = all_stopped.thread_seen(stamp, 37_i64)
    raise "an unsolicited thread event must remain Unknown" unless event_only.thread_execution(37_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "an uncorrelated new thread weakens aggregate stopped knowledge" unless event_only.execution == Adamantine::DebugSessionState::Execution::Partial

    listed = event_only.threads_listed(stamp, [37_i64], stop_certificate)
    raise "fresh threads response under all-stop certificate establishes stopped ID" unless listed.thread_execution(37_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    raise "fresh listing restores known global stopped state" unless listed.execution == Adamantine::DebugSessionState::Execution::Stopped
    pending, ticket = listed.begin_resume(21_u64, thread_id: 37_i64, all_threads: false)
    raise "listed stopped thread must be actionable without inventing an ID" if ticket.nil?
    raise "resume pending remains explicit" unless pending.execution == Adamantine::DebugSessionState::Execution::ResumePending
  end

  it "reconciles a fresh full threads listing and retires omitted thread handles" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 17_i64, all_threads_stopped: true)
      .stopped(stamp, thread_id: 18_i64, all_threads_stopped: true)
      .select_thread(17_i64)
      .select_frame(101_i64)
    old_frame = state.certificate(31_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    stop_certificate = state.certificate(32_u64, Adamantine::DebugSessionState::RequestScope::Stop)

    listed = state.threads_listed(stamp, [18_i64], stop_certificate)

    raise "full threads response must remove omitted thread IDs" unless listed.tracked_thread_ids == [18_i64]
    raise "omitted selected thread must lose selection" unless listed.selected_thread_id.nil?
    raise "omitted thread's frame certificate must become stale" if listed.accepts?(old_frame)
    raise "fresh all-stop evidence remains stopped" unless listed.execution == Adamantine::DebugSessionState::Execution::Stopped
    raise "the full listing must not infer target exit" unless listed.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
  end

  it "reconciles omissions after a partial stop without promoting unknown threads" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 17_i64, all_threads_stopped: false)
      .select_thread(17_i64)
      .select_frame(101_i64)
      .thread_seen(stamp, 18_i64)
    old_frame = state.certificate(40_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    stop_certificate = state.certificate(41_u64, Adamantine::DebugSessionState::RequestScope::Stop)

    listed = state.threads_listed(stamp, [18_i64, 19_i64], stop_certificate)
    _after_resume, resume = listed.begin_resume(42_u64, thread_id: 17_i64, all_threads: false)
    _after_unknown_resume, unknown_resume = listed.begin_resume(43_u64, thread_id: 19_i64, all_threads: false)

    raise "partial-stop full listing must reconcile IDs" unless listed.tracked_thread_ids == [18_i64, 19_i64]
    raise "omitted selected thread must lose selection" unless listed.selected_thread_id.nil?
    raise "omitted thread's certificate must become stale" if listed.accepts?(old_frame)
    raise "new IDs listed after partial stop remain Unknown" unless listed.thread_execution(18_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "fresh IDs listed after partial stop remain Unknown" unless listed.thread_execution(19_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "partial stop cannot be promoted to global stopped" unless listed.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "removed thread cannot receive a resume ticket" unless resume.nil?
    raise "unknown thread cannot receive a resume ticket" unless unknown_resume.nil?
    raise "partial listing is not target-exit evidence" unless listed.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
  end

  it "accepts an empty full threads listing without inventing target exit" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 17_i64, all_threads_stopped: true)
      .select_thread(17_i64)
      .select_frame(101_i64)
    stop_certificate = state.certificate(33_u64, Adamantine::DebugSessionState::RequestScope::Stop)

    listed = state.threads_listed(stamp, [] of Int64, stop_certificate)

    raise "empty full listing must remove every tracked thread" unless listed.tracked_thread_count == 0
    raise "empty listing must clear selected thread and frame" unless listed.selected_thread_id.nil? && listed.selected_frame_id.nil?
    raise "stop-event evidence remains independent of thread count" unless listed.execution == Adamantine::DebugSessionState::Execution::Stopped
    raise "empty listing is not target-exit evidence" unless listed.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
  end

  it "does not revive thread certificates when an ID is removed and reused in the same stop" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 17_i64, all_threads_stopped: true)
      .stopped(stamp, thread_id: 18_i64, all_threads_stopped: true)
      .select_thread(17_i64)
      .select_frame(101_i64)
    old_thread = state.certificate(36_u64, Adamantine::DebugSessionState::RequestScope::Thread, thread_id: 17_i64)
    old_frame = state.certificate(37_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    first_stop_certificate = state.certificate(38_u64, Adamantine::DebugSessionState::RequestScope::Stop)
    without_17 = state.threads_listed(stamp, [18_i64], first_stop_certificate)
    second_stop_certificate = without_17.certificate(39_u64, Adamantine::DebugSessionState::RequestScope::Stop)

    reintroduced = without_17.threads_listed(stamp, [17_i64, 18_i64], second_stop_certificate)
      .select_thread(17_i64)
      .select_frame(202_i64)

    raise "same-stop ID reuse cannot revive a thread certificate" if reintroduced.accepts?(old_thread)
    raise "same-stop ID reuse cannot revive a frame certificate" if reintroduced.accepts?(old_frame)
    raise "reintroduced ID requires fresh state" unless reintroduced.thread_execution(17_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
  end

  it "does not let a stale full threads listing remove current thread state" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 17_i64, all_threads_stopped: true)
    stale_stop_certificate = state.certificate(34_u64, Adamantine::DebugSessionState::RequestScope::Stop)
    newer_stop = state.stopped(stamp, thread_id: 18_i64, all_threads_stopped: true)

    listed = newer_stop.threads_listed(stamp, [18_i64], stale_stop_certificate)

    raise "stale listing must not reconcile away a current thread" unless listed.tracked_thread_ids == [17_i64, 18_i64]
    raise "newer all-stop state must remain current" unless listed.execution == Adamantine::DebugSessionState::Execution::Stopped
  end

  it "keeps thread tracking bounded and reports a truncated fresh listing" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    stopped = state.stopped(stamp, thread_id: nil, all_threads_stopped: true)
    stop_certificate = stopped.certificate(35_u64, Adamantine::DebugSessionState::RequestScope::Stop)
    ids = (1_i64..(Adamantine::DebugSessionState::MAX_TRACKED_THREADS + 1).to_i64).to_a

    listed = stopped.threads_listed(stamp, ids, stop_certificate)

    raise "thread tracking must respect its hard cap" unless listed.tracked_thread_count == Adamantine::DebugSessionState::MAX_TRACKED_THREADS
    raise "truncated ID inventory must remain visible" unless listed.thread_tracking_limited?
    raise "all-stop event still proves execution state despite bounded inventory" unless listed.execution == Adamantine::DebugSessionState::Execution::Stopped
  end

  it "does not let an old all-stop certificate classify a thread after continuation" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    all_stopped = state.stopped(stamp, thread_id: nil, all_threads_stopped: true)
    stop_certificate = all_stopped.certificate(22_u64, Adamantine::DebugSessionState::RequestScope::Stop)
    running = all_stopped.continued(stamp, all_threads_continued: true)
    seen = running.thread_seen(stamp, 38_i64)
    listed = seen.threads_listed(stamp, [38_i64], stop_certificate)

    raise "stale stop certificate cannot promote a later thread event" unless listed.thread_execution(38_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "stale listing cannot rewrite running state" unless listed.execution == Adamantine::DebugSessionState::Execution::Running
  end

  it "retires inspection handles before a resume is dispatched" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: 7_i64, all_threads_stopped: true)
      .select_thread(7_i64)
      .select_frame(101_i64)
    old_frame = state.certificate(1_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 7_i64)
    pending, ticket = state.begin_resume(2_u64, thread_id: 7_i64, all_threads: true)

    raise "a stopped thread should accept resume" if ticket.nil?
    raise "resume must be pending before transport writes" unless pending.execution == Adamantine::DebugSessionState::Execution::ResumePending
    raise "pre-resume handles must already be stale" if pending.accepts?(old_frame)
    raise "dispatch must advance the handle generation" unless pending.handle_generation > state.handle_generation
  end

  it "accepts a successful resume without waiting for a continued event" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: 7_i64, all_threads_stopped: true)
    pending, ticket = state.begin_resume(3_u64, thread_id: 7_i64, all_threads: true)
    raise "resume should start" if ticket.nil?

    state = pending.resume_succeeded(ticket, all_threads_continued: true)
    raise "successful response should leave ResumePending" if state.execution == Adamantine::DebugSessionState::Execution::ResumePending
    raise "allThreadsContinued=true is positive running evidence" unless state.execution == Adamantine::DebugSessionState::Execution::Running
    raise "known thread should be running" unless state.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Running
  end

  it "honors DAP's default-true allThreadsContinued response field" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: 7_i64, all_threads_stopped: true)
    pending, ticket = state.begin_resume(4_u64, thread_id: 7_i64, all_threads: true)
    raise "resume should start" if ticket.nil?

    state = pending.resume_succeeded(ticket, all_threads_continued: nil)
    raise "omitted allThreadsContinued defaults to true by DAP schema" unless state.execution == Adamantine::DebugSessionState::Execution::Running
    raise "known thread should be running" unless state.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Running
  end

  it "keeps execution partial when allThreadsContinued is explicitly false" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: 7_i64, all_threads_stopped: true)
    pending, ticket = state.begin_resume(4_u64, thread_id: 7_i64, all_threads: true)
    raise "resume should start" if ticket.nil?

    state = pending.resume_succeeded(ticket, all_threads_continued: false)
    raise "explicit false means continuation is not global" unless state.execution == Adamantine::DebugSessionState::Execution::Partial
    raise "the explicitly resumed thread should be running" unless state.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Running
  end

  it "lets a newer stop win over an older global resume response" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 7_i64, all_threads_stopped: true)
    pending, ticket = state.begin_resume(5_u64, thread_id: 7_i64, all_threads: true)
    raise "resume should start" if ticket.nil?
    after_new_stop = pending.stopped(stamp, thread_id: 12_i64, all_threads_stopped: false)

    state = after_new_stop.resume_succeeded(ticket, all_threads_continued: true)
    raise "newer stopped thread must not be overwritten" unless state.thread_execution(12_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    raise "unaffected thread may reflect successful continuation" unless state.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Running
    raise "mixed thread state must remain partial" unless state.execution == Adamantine::DebugSessionState::Execution::Partial
  end

  it "does not leave sibling threads ResumePending after an ambiguous global resume" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 7_i64, all_threads_stopped: true)
      .stopped(stamp, thread_id: 8_i64, all_threads_stopped: true)
    pending, ticket = state.begin_resume(28_u64, thread_id: 7_i64, all_threads: true)
    raise "global resume should start" if ticket.nil?
    after_partial_stop = pending.stopped(stamp, thread_id: 8_i64, all_threads_stopped: false)
    failed = after_partial_stop.resume_failed(ticket)

    raise "newer stopped sibling remains stopped" unless failed.thread_execution(8_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    raise "ambiguous sibling execution must be unknown" unless failed.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "no resolved request may leave a thread ResumePending" unless failed.tracked_thread_ids.all? { |id| failed.thread_execution(id) != Adamantine::DebugSessionState::ThreadExecution::ResumePending }
    raise "newer confirmed stop keeps mixed/unknown state partial" unless failed.execution == Adamantine::DebugSessionState::Execution::Partial
    inspectable = failed.select_thread(8_i64)
    stopped_certificate = inspectable.certificate(30_u64, Adamantine::DebugSessionState::RequestScope::Thread, thread_id: 8_i64)
    raise "newer stopped thread remains inspectable after old failure" unless inspectable.accepts?(stopped_certificate)
  end

  it "lets a stop arriving after a successful response establish a newer state" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 7_i64, all_threads_stopped: true)
    pending, ticket = state.begin_resume(29_u64, thread_id: 7_i64, all_threads: true)
    raise "resume should start" if ticket.nil?
    running = pending.resume_succeeded(ticket, all_threads_continued: true)
    after_stop = running.stopped(stamp, thread_id: 7_i64, all_threads_stopped: true)
    duplicate_old_reply = after_stop.resume_succeeded(ticket, all_threads_continued: true)

    raise "new stop after response must be current inspection state" unless duplicate_old_reply.execution == Adamantine::DebugSessionState::Execution::Stopped
    raise "new stop makes thread stopped" unless duplicate_old_reply.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
  end

  it "allows a thread-scoped resume response after an unrelated thread stops" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 7_i64, all_threads_stopped: false)
    pending, ticket = state.begin_resume(6_u64, thread_id: 7_i64, all_threads: false)
    raise "thread 7 resume should start" if ticket.nil?
    after_other_thread_stops = pending.stopped(stamp, thread_id: 8_i64, all_threads_stopped: false)

    state = after_other_thread_stops.resume_succeeded(ticket, all_threads_continued: false)
    raise "resumed thread should not remain stale-paused" unless state.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Running
    raise "unrelated stopped thread state must be preserved" unless state.thread_execution(8_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    raise "mixed thread states must be reported as partial" unless state.execution == Adamantine::DebugSessionState::Execution::Partial
  end

  it "does not allow overlapping execution mutations" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: 7_i64, all_threads_stopped: true)
    pending, first = state.begin_resume(7_u64, thread_id: 7_i64, all_threads: false)
    raise "first resume should start" if first.nil?
    unchanged, second = pending.begin_resume(8_u64, thread_id: 8_i64, all_threads: false)

    raise "second concurrent resume must be rejected" unless second.nil?
    raise "rejection must not replace the pending state" unless unchanged.execution == pending.execution
    raise "rejection must not change the current identity" unless unchanged.session_generation == pending.session_generation
  end

  it "binds a resume result to every field of its exact dispatched ticket" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: 7_i64, all_threads_stopped: true)
    pending, ticket = state.begin_resume(25_u64, thread_id: 7_i64, all_threads: false)
    raise "resume should start" if ticket.nil?
    forged = Adamantine::DebugSessionState::ResumeTicket.new(
      ticket.request_id, ticket.stamp, 99_i64, ticket.all_threads,
      ticket.command_generation, ticket.stop_epoch, ticket.thread_stop_epoch,
      ticket.broadcast_stop_epoch, ticket.unattributed_stop_epoch
    )
    ignored = pending.resume_succeeded(forged, all_threads_continued: false)

    raise "a mismatched target cannot consume the in-flight ticket" unless ignored.execution == pending.execution
    raise "a mismatched target cannot poison another thread" unless ignored.thread_execution(99_i64).nil?
    raise "the actual dispatched ticket still resolves" unless pending.resume_succeeded(ticket, all_threads_continued: false).execution == Adamantine::DebugSessionState::Execution::Partial
  end

  it "keeps pause pending until a stopped event confirms the pause" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.continued(stamp, thread_id: 7_i64, all_threads_continued: true)
    pending, ticket = state.begin_pause(9_u64, thread_id: 7_i64)
    raise "pause should start" if ticket.nil?
    raise "pause request is not proof of a stop" unless pending.execution == Adamantine::DebugSessionState::Execution::PausePending

    acknowledged = pending.pause_succeeded(ticket)
    raise "successful pause response alone is not a stopped event" unless acknowledged.execution == Adamantine::DebugSessionState::Execution::PausePending
    stopped = acknowledged.stopped(stamp, thread_id: 7_i64, all_threads_stopped: false)
    raise "stopped event confirms pause" unless stopped.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    late_expiry = stopped.pause_unconfirmed(ticket)
    raise "newer stop wins over an old pause deadline" unless late_expiry.execution == stopped.execution
    raise "newer stopped thread remains stopped" unless late_expiry.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
  end

  it "expires acknowledged Pause without claiming a stop and allows explicit recovery" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    state = state.continued(stamp, thread_id: 7_i64, all_threads_continued: true)
    pending, ticket = state.begin_pause(26_u64, thread_id: 7_i64)
    raise "pause should start" if ticket.nil?
    acknowledged = pending.pause_succeeded(ticket)
    expired = acknowledged.pause_unconfirmed(ticket)

    raise "acknowledgement expiry leaves execution unknown" unless expired.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "acknowledgement expiry leaves affected thread unknown" unless expired.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "pause expiry cannot report a stopped thread" unless expired.execution != Adamantine::DebugSessionState::Execution::Stopped

    recovery, recovery_ticket = expired.begin_pause(27_u64, thread_id: 7_i64)
    raise "explicit Pause is available for a tracked unknown thread on a last-known-live target" if recovery_ticket.nil?
    raise "recovery request remains pending rather than claiming a stop" unless recovery.execution == Adamantine::DebugSessionState::Execution::PausePending
  end

  it "uses the DAP default true for a continued event with an omitted allThreadsContinued" do
    state = active_debug_session
    state = state.continued(state.session_stamp.not_nil!, thread_id: nil, all_threads_continued: nil)

    raise "omitted continued-event allThreadsContinued defaults to true" unless state.execution == Adamantine::DebugSessionState::Execution::Running
  end

  it "makes ambiguous resume failure unknown without reviving old handles" do
    state = active_debug_session
    state = state.stopped(state.session_stamp.not_nil!, thread_id: 7_i64, all_threads_stopped: true)
    old_frame = state.certificate(10_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 7_i64)
    pending, ticket = state.begin_resume(11_u64, thread_id: 7_i64, all_threads: false)
    raise "resume should start" if ticket.nil?

    state = pending.resume_failed(ticket)
    raise "ambiguous transport/result failure must not restore Paused" unless state.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "affected thread state is unknown" unless state.thread_execution(7_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "retired inspection certificate stays stale" if state.accepts?(old_frame)
  end

  it "does not infer process exit from terminated or disconnect" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    ended = state.terminated(stamp)
    raise "terminated ends the session" unless ended.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended
    raise "terminated alone does not prove target exit" unless ended.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown

    state = active_debug_session
    disconnected = state.disconnected(state.session_stamp.not_nil!)
    raise "disconnect loses liveness certainty" unless disconnected.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown
    raise "disconnect must not claim exit" unless disconnected.target_liveness != Adamantine::DebugSessionState::TargetLiveness::Exited
  end

  it "does not let late events, responses, or old-session cleanup revive terminal state" do
    state = active_debug_session
    old_stamp = state.session_stamp.not_nil!
    state = state.stopped(old_stamp, thread_id: 7_i64, all_threads_stopped: true)
    pending, ticket = state.begin_resume(12_u64, thread_id: 7_i64, all_threads: true)
    raise "resume should start" if ticket.nil?
    ended = pending.terminated(old_stamp)
    late_response = ended.resume_succeeded(ticket, all_threads_continued: true)
    late_stop = late_response.stopped(old_stamp, thread_id: 7_i64, all_threads_stopped: true)

    raise "old response/event cannot revive an ended session" unless late_stop.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended
    raise "ended execution remains non-inspectable" unless late_stop.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "terminated alone leaves target exit unknown" unless late_stop.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown
  end

  it "binds old resume tickets to the prior session generation" do
    state = active_debug_session
    old_stamp = state.session_stamp.not_nil!
    state = state.stopped(old_stamp, thread_id: 7_i64, all_threads_stopped: true)
    pending, old_ticket = state.begin_resume(13_u64, thread_id: 7_i64, all_threads: true)
    raise "resume should start" if old_ticket.nil?
    ended = pending.terminated(old_stamp)
    restarted = ended.begin_session("lldb-dap", "ordering-spec-client")
    new_session = restarted.configuring.activate
    after_late_response = new_session.resume_succeeded(old_ticket, all_threads_continued: true)

    raise "restart must advance session identity" unless restarted.session_generation > ended.session_generation
    raise "old cleanup/result cannot poison a restarted session" unless after_late_response.session_generation == restarted.session_generation
    raise "old result cannot change new execution state" unless after_late_response.execution == new_session.execution
    raise "new session identity must not match old stamp" if after_late_response.matches_session?(old_stamp)
  end

  it "fails closed and exposes a bounded thread tracking limit" do
    state = active_debug_session
    stamp = state.session_stamp.not_nil!
    (1_i64..Adamantine::DebugSessionState::MAX_TRACKED_THREADS.to_i64).each do |thread_id|
      state = state.stopped(stamp, thread_id: thread_id, all_threads_stopped: false)
    end
    state = state.stopped(stamp, thread_id: (Adamantine::DebugSessionState::MAX_TRACKED_THREADS + 1).to_i64, all_threads_stopped: false)

    raise "tracked thread storage must be capped" unless state.tracked_thread_count == Adamantine::DebugSessionState::MAX_TRACKED_THREADS
    raise "overflow must be visible" unless state.thread_tracking_limited?
    _, ticket = state.begin_resume(14_u64, thread_id: (Adamantine::DebugSessionState::MAX_TRACKED_THREADS + 1).to_i64, all_threads: false)
    raise "an untracked thread cannot receive an execution action" unless ticket.nil?
  end
end
