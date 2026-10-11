require "spec"
require "../src/adamantine/debug_session_state"

private def thread_lifecycle_session : Adamantine::DebugSessionState
  state = Adamantine::DebugSessionState.initial
    .begin_session("lldb-dap", "thread-lifecycle-client")
    .configuring.activate
  stamp = state.session_stamp.not_nil!
  state.stopped(stamp, thread_id: 17_i64, all_threads_stopped: true)
    .select_thread(17_i64)
    .select_frame(101_i64)
end

describe Adamantine::DebugSessionState, "thread lifecycle" do
  it "retires an exited selected thread instead of treating its event as thread-seen" do
    state = thread_lifecycle_session
    stamp = state.session_stamp.not_nil!
    after_exit = state.thread_exited(stamp, 17_i64)

    raise "an exited thread must be removed from tracked membership" unless after_exit.tracked_thread_ids.empty?
    raise "the dead selected thread must lose selection" unless after_exit.selected_thread_id.nil?
    raise "the dead selected frame must lose selection" unless after_exit.selected_frame_id.nil?
    raise "removing the last tracked thread leaves execution unknown" unless after_exit.execution == Adamantine::DebugSessionState::Execution::Unknown
    raise "one thread exit cannot prove process exit" unless after_exit.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
    raise "one thread exit cannot end the session" unless after_exit.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active

    reused = after_exit.thread_seen(stamp, 17_i64)
    raise "a reused ID starts with unknown execution" unless reused.thread_execution(17_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "a reused ID cannot restore the dead selection" unless reused.selected_thread_id.nil?
  end

  it "retires old inspection certificates when their selected thread exits" do
    state = thread_lifecycle_session
    stamp = state.session_stamp.not_nil!
    frame = state.certificate(71_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    after_exit = state.thread_exited(stamp, 17_i64)

    raise "an exited thread cannot retain its old frame certificate" if after_exit.accepts?(frame)
    reused = after_exit.thread_seen(stamp, 17_i64)
    raise "an old frame certificate remains stale after thread-ID reuse" if reused.accepts?(frame)
  end

  it "invalidates a pending operation for the exited ID before that ID can be reused" do
    state = thread_lifecycle_session
    stamp = state.session_stamp.not_nil!
    pending, ticket = state.begin_resume(72_u64, thread_id: 17_i64, all_threads: false)
    raise "the stopped thread should accept resume" if ticket.nil?

    after_exit = pending.thread_exited(stamp, 17_i64)
    reused = after_exit.thread_seen(stamp, 17_i64)
    late_resume = reused.resume_succeeded(ticket, all_threads_continued: false)

    raise "a late resume result cannot revive a reused thread ID" unless late_resume.thread_execution(17_i64) == Adamantine::DebugSessionState::ThreadExecution::Unknown
    raise "late response cannot promote aggregate execution" unless late_resume.execution == Adamantine::DebugSessionState::Execution::Unknown
  end

  it "keeps an unrelated selected thread while retiring handles after membership changes" do
    state = Adamantine::DebugSessionState.initial
      .begin_session("lldb-dap", "unrelated-exit-client")
      .configuring.activate
    stamp = state.session_stamp.not_nil!
    state = state.stopped(stamp, thread_id: 17_i64, all_threads_stopped: true)
      .stopped(stamp, thread_id: 18_i64, all_threads_stopped: true)
      .select_thread(17_i64)
      .select_frame(101_i64)
    frame = state.certificate(73_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)

    after_exit = state.thread_exited(stamp, 18_i64)

    raise "unrelated exit removes only the exited thread" unless after_exit.tracked_thread_ids == [17_i64]
    raise "unrelated exit preserves the still-live thread selection" unless after_exit.selected_thread_id == 17_i64
    raise "membership change retires selected frame handles" unless after_exit.selected_frame_id.nil?
    raise "membership change stales existing frame certificates" if after_exit.accepts?(frame)
    raise "remaining stopped thread stays known stopped" unless after_exit.thread_execution(17_i64) == Adamantine::DebugSessionState::ThreadExecution::Stopped
    raise "unrelated thread exit does not prove target exit" unless after_exit.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive
  end

  it "ignores unknown, foreign-session, and terminal-session thread exits" do
    state = thread_lifecycle_session
    stamp = state.session_stamp.not_nil!
    frame = state.certificate(74_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)

    unknown = state.thread_exited(stamp, 99_i64)
    foreign = Adamantine::DebugSessionState.initial
      .begin_session("lldb-dap", "foreign-thread-exit-client")
      .session_stamp.not_nil!
    foreign_exit = state.thread_exited(foreign, 17_i64)
    ended = state.terminated(stamp)
    late_exit = ended.thread_exited(stamp, 17_i64)

    raise "unknown exit IDs cannot mutate tracked membership" unless unknown.tracked_thread_ids == [17_i64]
    raise "foreign stamps cannot mutate thread membership" unless foreign_exit.tracked_thread_ids == [17_i64]
    raise "foreign stamps cannot retire current certificates" unless foreign_exit.accepts?(frame)
    raise "terminal late events cannot mutate membership" unless late_exit.tracked_thread_ids == [17_i64]
    raise "a thread exit alone does not set target liveness to Exited" unless unknown.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Alive

    liveness_unknown = Adamantine::DebugSessionState.initial
      .begin_session("lldb-dap", "unknown-liveness-thread-client")
      .configuring.activate
    liveness_stamp = liveness_unknown.session_stamp.not_nil!
    liveness_unknown = liveness_unknown.thread_seen(liveness_stamp, 17_i64)
      .thread_exited(liveness_stamp, 17_i64)
    raise "a thread exit does not promote unknown process liveness" unless liveness_unknown.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Unknown
  end
end
