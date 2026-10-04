require "spec"
require "../src/adamantine/debug_session_state"

def stopped_debug_session(project_generation : UInt64 = 0_u64) : Adamantine::DebugSessionState
  state = Adamantine::DebugSessionState.initial(project_generation)
    .begin_session("lldb-dap", "stale-handle-spec-client", project_generation)
    .configuring
    .activate
  state = state.stopped(state.session_stamp.not_nil!, thread_id: 17_i64, all_threads_stopped: true)
  state.select_thread(17_i64).select_frame(101_i64)
end

describe Adamantine::DebugSessionState do
  it "scopes request certificates to thread, frame, stop, format, project, and session generations" do
    state = stopped_debug_session
    session_cert = state.certificate(1_u64, Adamantine::DebugSessionState::RequestScope::Session)
    thread_cert = state.certificate(2_u64, Adamantine::DebugSessionState::RequestScope::Thread, thread_id: 17_i64)
    frame_cert = state.certificate(3_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    format_cert = state.certificate(4_u64, Adamantine::DebugSessionState::RequestScope::Format, thread_id: 17_i64)

    selected_other_thread = state.select_thread(22_i64)
    raise "same session certificate should survive selection" unless selected_other_thread.accepts?(session_cert)
    raise "thread selection invalidates old thread requests" if selected_other_thread.accepts?(thread_cert)
    raise "thread selection invalidates old frame requests" if selected_other_thread.accepts?(frame_cert)
    raise "format request is frame/thread scoped too" if selected_other_thread.accepts?(format_cert)

    selected_same_thread = selected_other_thread.select_thread(17_i64).select_frame(101_i64)
    new_thread_cert = selected_same_thread.certificate(5_u64, Adamantine::DebugSessionState::RequestScope::Thread, thread_id: 17_i64)
    new_frame_cert = selected_same_thread.certificate(6_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    new_format_cert = selected_same_thread.certificate(7_u64, Adamantine::DebugSessionState::RequestScope::Format, thread_id: 17_i64)
    reformatted = selected_same_thread.change_format("hex")

    raise "format change must preserve the frame certificate" unless reformatted.accepts?(new_frame_cert)
    raise "format change must invalidate formatted values" if reformatted.accepts?(new_format_cert)
    raise "format change must not invalidate thread selection" unless reformatted.accepts?(new_thread_cert)

    rooted = reformatted.project_changed(1_u64)
    raise "project/root change must stale every project-bound result" if rooted.accepts?(session_cert)
    raise "project generation must advance" unless rooted.project_generation == 1_u64
    raise "root change must clear old selected thread authority" unless rooted.selected_thread_id.nil?
    raise "root change must discard old thread snapshots" unless rooted.tracked_thread_count == 0
  end

  it "accepts inspection certificates only for an active stopped thread and fresh frame" do
    initial = Adamantine::DebugSessionState.initial
    idle_frame = initial.certificate(20_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    raise "idle cannot authorize inspection" if initial.accepts?(idle_frame)

    starting = initial.begin_session("lldb-dap", "stale-handle-lifecycle-client")
    starting_frame = starting.certificate(21_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    raise "starting cannot authorize inspection" if starting.accepts?(starting_frame)
    raise "connected session metadata can remain current while starting" unless starting.accepts?(starting.certificate(22_u64, Adamantine::DebugSessionState::RequestScope::Session))

    active = starting.configuring.activate
    stamp = active.session_stamp.not_nil!
    active = active.stopped(stamp, thread_id: 17_i64, all_threads_stopped: true).select_thread(17_i64).select_frame(101_i64)
    pending, ticket = active.begin_resume(23_u64, thread_id: 17_i64, all_threads: true)
    raise "resume should start" if ticket.nil?
    pending_frame = pending.certificate(24_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    raise "resume pending cannot authorize inspection" if pending.accepts?(pending_frame)

    running = pending.resume_succeeded(ticket, all_threads_continued: true)
    running_frame = running.certificate(25_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    raise "running cannot authorize inspection" if running.accepts?(running_frame)
    raise "connected session metadata remains valid while active" unless running.accepts?(running.certificate(26_u64, Adamantine::DebugSessionState::RequestScope::Session))

    ended = running.terminated(running.session_stamp.not_nil!)
    ended_frame = ended.certificate(27_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    ended_session = ended.certificate(28_u64, Adamantine::DebugSessionState::RequestScope::Session)
    raise "ended cannot authorize inspection" if ended.accepts?(ended_frame)
    raise "ended session cannot authorize delayed session metadata" if ended.accepts?(ended_session)
  end

  it "rejects certificates from another reducer/client instance using the same adapter brand" do
    left = Adamantine::DebugSessionState.initial
      .begin_session("lldb-dap", "client-instance-left")
      .configuring.activate
    left_stamp = left.session_stamp.not_nil!
    left = left.stopped(left_stamp, thread_id: 17_i64, all_threads_stopped: true)
      .select_thread(17_i64)
      .select_frame(101_i64)
    certificate = left.certificate(30_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)

    right = Adamantine::DebugSessionState.initial
      .begin_session("lldb-dap", "client-instance-right")
      .configuring.activate
    right_stamp = right.session_stamp.not_nil!
    right = right.stopped(right_stamp, thread_id: 17_i64, all_threads_stopped: true)
      .select_thread(17_i64)
      .select_frame(101_i64)

    raise "matching adapter brand does not imply matching client identity" unless left_stamp.adapter_id == right_stamp.adapter_id
    raise "client-instance identity is part of session stamp" if left_stamp == right_stamp
    raise "certificate remains current in its own reducer" unless left.accepts?(certificate)
    raise "certificate from another reducer/client instance is stale" if right.accepts?(certificate)
  end

  it "rejects frame-ID reuse at a new stop epoch" do
    state = stopped_debug_session
    old_frame = state.certificate(8_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    stamp = state.session_stamp.not_nil!
    next_stop = state.stopped(stamp, thread_id: 17_i64, all_threads_stopped: true)
      .select_thread(17_i64)
      .select_frame(101_i64)

    raise "same integer frame ID does not restore old authority" if next_stop.accepts?(old_frame)
    raise "stop epoch must advance even when IDs are reused" unless next_stop.stop_epoch > state.stop_epoch
  end

  it "invalidates handles on unknown adapter invalidation areas" do
    state = stopped_debug_session
    frame = state.certificate(9_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    stamp = state.session_stamp.not_nil!
    invalidated = state.invalidated(stamp, areas: ["future-adapter-area"])

    raise "unknown invalidation area must conservatively retire handles" if invalidated.accepts?(frame)
    raise "handle generation must advance" unless invalidated.handle_generation > state.handle_generation

    missing_areas = state.invalidated(stamp, areas: nil)
    raise "missing invalidation areas must not be a no-op" if missing_areas.accepts?(frame)
    raise "unknown invalidation must forget stopped execution" unless missing_areas.execution == Adamantine::DebugSessionState::Execution::Unknown
  end

  it "returns owned thread-id snapshots instead of exposing reducer storage" do
    state = stopped_debug_session
    ids = state.tracked_thread_ids
    ids.clear

    raise "caller mutation must not poison the session snapshot" unless state.tracked_thread_ids == [17_i64]
    raise "thread count must remain stable" unless state.tracked_thread_count == 1
  end

  it "does not accept delayed old-session results after a project/root change" do
    state = stopped_debug_session
    stale = state.certificate(10_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    rooted = state.project_changed(1_u64)
    raise "old inspection selection must not survive the root change" unless rooted.selected_thread_id.nil?
    raise "old thread handles must not survive the root change" unless rooted.tracked_thread_count == 0
    new_request = rooted.certificate(11_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)

    raise "old root request must be rejected" unless !rooted.accepts?(stale)
    raise "a new certificate cannot legitimize a prior root's frame ID" if rooted.accepts?(new_request)

    fresh_stamp = rooted.session_stamp.not_nil!
    freshly_stopped = rooted.stopped(fresh_stamp, thread_id: 17_i64, all_threads_stopped: true)
      .select_thread(17_i64)
      .select_frame(202_i64)
    fresh_request = freshly_stopped.certificate(12_u64, Adamantine::DebugSessionState::RequestScope::Frame, thread_id: 17_i64)
    raise "fresh stop, thread, and frame evidence should authorize current-root data" unless freshly_stopped.accepts?(fresh_request)
    raise "the old immutable state remains unchanged" unless state.project_generation == 0_u64
  end
end
