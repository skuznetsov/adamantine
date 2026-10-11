# Pure, transport-independent state reduction for one local DAP session.
# Every transition returns an owned snapshot; this module performs no IO.
require "set"

module Adamantine
  class DebugSessionState
    enum Lifecycle
      Idle
      Starting
      Configuring
      Active
      Disconnecting
      Ended
      Failed
    end

    enum Execution
      Unknown
      Running
      Stopped
      Partial
      ResumePending
      PausePending
    end

    enum TargetLiveness
      Unknown
      Alive
      Exited
    end

    enum ThreadExecution
      Unknown
      Running
      Stopped
      ResumePending
      PausePending
    end

    enum RequestScope
      Session
      Stop
      Thread
      Frame
      Format
    end

    # This is a deliberate per-session cap. Overflow is retained as an
    # explicit state flag and prevents actions against untracked threads.
    MAX_TRACKED_THREADS = 256

    struct SessionStamp
      getter generation : UInt64
      getter project_generation : UInt64

      def initialize(
        @generation : UInt64,
        adapter_id : String,
        client_instance_id : String,
        @project_generation : UInt64,
      )
        @adapter_id = adapter_id.dup
        @client_instance_id = client_instance_id.dup
      end

      def adapter_id : String
        @adapter_id.dup
      end

      def client_instance_id : String
        @client_instance_id.dup
      end

      def ==(other : self) : Bool
        @generation == other.generation &&
          @adapter_id == other.adapter_id &&
          @client_instance_id == other.client_instance_id &&
          @project_generation == other.project_generation
      end
    end

    # A certificate is a local freshness guard, not a DAP request ID or an
    # authorization token. The controller still owns request correlation.
    struct RequestCertificate
      getter request_id : UInt64
      getter stamp : SessionStamp
      getter scope : RequestScope
      getter stop_epoch : UInt64
      getter handle_generation : UInt64
      getter thread_selection_generation : UInt64
      getter thread_id : Int64?
      getter thread_state_generation : UInt64?
      getter frame_selection_generation : UInt64
      getter frame_id : Int64?
      getter format_generation : UInt64

      def initialize(
        @request_id : UInt64,
        @stamp : SessionStamp,
        @scope : RequestScope,
        @stop_epoch : UInt64,
        @handle_generation : UInt64,
        @thread_selection_generation : UInt64,
        @thread_id : Int64?,
        @thread_state_generation : UInt64?,
        @frame_selection_generation : UInt64,
        @frame_id : Int64?,
        @format_generation : UInt64,
      )
      end
    end

    struct ResumeTicket
      getter request_id : UInt64
      getter stamp : SessionStamp
      getter thread_id : Int64
      # Effective wire scope after capability negotiation: true means the
      # dispatched request can resume all threads; false means one thread.
      getter all_threads : Bool
      getter command_generation : UInt64
      getter stop_epoch : UInt64
      getter thread_stop_epoch : UInt64
      getter broadcast_stop_epoch : UInt64
      getter unattributed_stop_epoch : UInt64

      def initialize(
        @request_id : UInt64,
        @stamp : SessionStamp,
        @thread_id : Int64,
        @all_threads : Bool,
        @command_generation : UInt64,
        @stop_epoch : UInt64,
        @thread_stop_epoch : UInt64,
        @broadcast_stop_epoch : UInt64,
        @unattributed_stop_epoch : UInt64,
      )
      end

      def ==(other : self) : Bool
        @request_id == other.request_id && @stamp == other.stamp &&
          @thread_id == other.thread_id && @all_threads == other.all_threads &&
          @command_generation == other.command_generation && @stop_epoch == other.stop_epoch &&
          @thread_stop_epoch == other.thread_stop_epoch &&
          @broadcast_stop_epoch == other.broadcast_stop_epoch &&
          @unattributed_stop_epoch == other.unattributed_stop_epoch
      end
    end

    struct PauseTicket
      getter request_id : UInt64
      getter stamp : SessionStamp
      getter thread_id : Int64
      getter command_generation : UInt64
      getter stop_epoch : UInt64
      getter thread_stop_epoch : UInt64
      getter broadcast_stop_epoch : UInt64
      getter unattributed_stop_epoch : UInt64

      def initialize(
        @request_id : UInt64,
        @stamp : SessionStamp,
        @thread_id : Int64,
        @command_generation : UInt64,
        @stop_epoch : UInt64,
        @thread_stop_epoch : UInt64,
        @broadcast_stop_epoch : UInt64,
        @unattributed_stop_epoch : UInt64,
      )
      end

      def ==(other : self) : Bool
        @request_id == other.request_id && @stamp == other.stamp &&
          @thread_id == other.thread_id && @command_generation == other.command_generation &&
          @stop_epoch == other.stop_epoch && @thread_stop_epoch == other.thread_stop_epoch &&
          @broadcast_stop_epoch == other.broadcast_stop_epoch &&
          @unattributed_stop_epoch == other.unattributed_stop_epoch
      end
    end

    private struct ThreadSnapshot
      getter id : Int64
      getter execution : ThreadExecution
      getter state_generation : UInt64
      getter stop_epoch : UInt64

      def initialize(
        @id : Int64,
        @execution : ThreadExecution,
        @state_generation : UInt64,
        @stop_epoch : UInt64,
      )
      end

      def update(
        execution : ThreadExecution = @execution,
        stop_epoch : UInt64 = @stop_epoch,
      ) : ThreadSnapshot
        ThreadSnapshot.new(@id, execution, @state_generation + 1_u64, stop_epoch)
      end
    end

    private struct Data
      property lifecycle : Lifecycle
      property execution : Execution
      property target_liveness : TargetLiveness
      property session_generation : UInt64
      property adapter_id : String?
      property client_instance_id : String?
      property project_generation : UInt64
      property stop_epoch : UInt64
      property handle_generation : UInt64
      property thread_selection_generation : UInt64
      property frame_selection_generation : UInt64
      property format_generation : UInt64
      property selected_thread_id : Int64?
      property selected_frame_id : Int64?
      property format_key : String
      property threads : Array(ThreadSnapshot)
      property thread_tracking_limited : Bool
      property command_generation : UInt64
      property pending_resume : ResumeTicket?
      property pending_pause : PauseTicket?
      property pause_response_received : Bool
      property broadcast_stop_epoch : UInt64
      property unattributed_stop_epoch : UInt64
      property last_all_stopped_epoch : UInt64

      def initialize(
        @lifecycle : Lifecycle = Lifecycle::Idle,
        @execution : Execution = Execution::Unknown,
        @target_liveness : TargetLiveness = TargetLiveness::Unknown,
        @session_generation : UInt64 = 0_u64,
        @adapter_id : String? = nil,
        @client_instance_id : String? = nil,
        @project_generation : UInt64 = 0_u64,
        @stop_epoch : UInt64 = 0_u64,
        @handle_generation : UInt64 = 0_u64,
        @thread_selection_generation : UInt64 = 0_u64,
        @frame_selection_generation : UInt64 = 0_u64,
        @format_generation : UInt64 = 0_u64,
        @selected_thread_id : Int64? = nil,
        @selected_frame_id : Int64? = nil,
        @format_key : String = "summary",
        @threads : Array(ThreadSnapshot) = [] of ThreadSnapshot,
        @thread_tracking_limited : Bool = false,
        @command_generation : UInt64 = 0_u64,
        @pending_resume : ResumeTicket? = nil,
        @pending_pause : PauseTicket? = nil,
        @pause_response_received : Bool = false,
        @broadcast_stop_epoch : UInt64 = 0_u64,
        @unattributed_stop_epoch : UInt64 = 0_u64,
        @last_all_stopped_epoch : UInt64 = 0_u64,
      )
      end

      def copy : Data
        Data.new(
          @lifecycle, @execution, @target_liveness, @session_generation,
          @adapter_id.try(&.dup), @client_instance_id.try(&.dup),
          @project_generation, @stop_epoch, @handle_generation,
          @thread_selection_generation, @frame_selection_generation,
          @format_generation, @selected_thread_id, @selected_frame_id,
          @format_key.dup, @threads.dup, @thread_tracking_limited,
          @command_generation, @pending_resume, @pending_pause,
          @pause_response_received, @broadcast_stop_epoch,
          @unattributed_stop_epoch, @last_all_stopped_epoch
        )
      end
    end

    private getter data : Data

    def self.initial(project_generation : UInt64 = 0_u64) : DebugSessionState
      new(Data.new(project_generation: project_generation))
    end

    def initialize(@data : Data)
      # Take ownership of the thread array so no caller can mutate reducer
      # storage through an alias.
      @data = @data.copy
    end

    getter lifecycle : Lifecycle do
      @data.lifecycle
    end

    getter execution : Execution do
      @data.execution
    end

    getter target_liveness : TargetLiveness do
      @data.target_liveness
    end

    getter session_generation : UInt64 do
      @data.session_generation
    end

    getter project_generation : UInt64 do
      @data.project_generation
    end

    getter stop_epoch : UInt64 do
      @data.stop_epoch
    end

    getter handle_generation : UInt64 do
      @data.handle_generation
    end

    getter thread_selection_generation : UInt64 do
      @data.thread_selection_generation
    end

    getter frame_selection_generation : UInt64 do
      @data.frame_selection_generation
    end

    getter format_generation : UInt64 do
      @data.format_generation
    end

    getter selected_thread_id : Int64? do
      @data.selected_thread_id
    end

    getter selected_frame_id : Int64? do
      @data.selected_frame_id
    end

    getter format_key : String do
      @data.format_key.dup
    end

    getter tracked_thread_count : Int32 do
      @data.threads.size
    end

    def thread_tracking_limited? : Bool
      @data.thread_tracking_limited
    end

    # Returns a new array; mutating it cannot mutate this reducer snapshot.
    def tracked_thread_ids : Array(Int64)
      @data.threads.map(&.id)
    end

    def thread_execution(thread_id : Int64) : ThreadExecution?
      find_thread(thread_id).try(&.execution)
    end

    def session_stamp : SessionStamp?
      adapter = @data.adapter_id
      instance = @data.client_instance_id
      return nil unless adapter && instance
      SessionStamp.new(@data.session_generation, adapter, instance, @data.project_generation)
    end

    def matches_session?(stamp : SessionStamp) : Bool
      current_stamp?(stamp)
    end

    # `client_instance_id` must be allocated by the caller per reducer/client
    # lineage; an adapter brand such as "lldb-dap" is not unique identity.
    def begin_session(
      adapter_id : String,
      client_instance_id : String,
      project_generation : UInt64 = @data.project_generation,
    ) : DebugSessionState
      return self unless restartable?

      DebugSessionState.new(Data.new(
        lifecycle: Lifecycle::Starting,
        execution: Execution::Unknown,
        target_liveness: TargetLiveness::Unknown,
        session_generation: @data.session_generation + 1_u64,
        adapter_id: adapter_id,
        client_instance_id: client_instance_id,
        project_generation: project_generation,
        thread_selection_generation: @data.thread_selection_generation + 1_u64,
        frame_selection_generation: @data.frame_selection_generation + 1_u64,
        format_generation: @data.format_generation,
        command_generation: @data.command_generation + 1_u64
      ))
    end

    def configuring : DebugSessionState
      return self unless @data.lifecycle == Lifecycle::Starting
      data = @data.copy
      data.lifecycle = Lifecycle::Configuring
      DebugSessionState.new(data)
    end

    def activate : DebugSessionState
      return self unless @data.lifecycle.in?(Lifecycle::Starting, Lifecycle::Configuring)
      data = @data.copy
      data.lifecycle = Lifecycle::Active
      DebugSessionState.new(data)
    end

    def begin_disconnect : DebugSessionState
      return self if terminal?
      data = retire_all_handles
      data.lifecycle = Lifecycle::Disconnecting
      data.execution = Execution::Unknown
      data.target_liveness = TargetLiveness::Unknown
      data.pending_resume = nil
      data.pending_pause = nil
      data.pause_response_received = false
      DebugSessionState.new(data)
    end

    # DAP stop events may precede configuration completion. A missing
    # allThreadsStopped field is deliberately not normalized to true.
    def stopped(
      stamp : SessionStamp,
      thread_id : Int64? = nil,
      all_threads_stopped : Bool? = nil,
    ) : DebugSessionState
      return self unless current_event?(stamp)

      data = retire_all_handles
      data.stop_epoch += 1_u64
      data.target_liveness = TargetLiveness::Alive
      data.selected_frame_id = nil

      if all_threads_stopped == true
        data.broadcast_stop_epoch = data.stop_epoch
        data.last_all_stopped_epoch = data.stop_epoch
        data.unattributed_stop_epoch = data.stop_epoch if thread_id.nil?
        data.threads = data.threads.map { |thread| thread.update(execution: ThreadExecution::Stopped, stop_epoch: data.stop_epoch) }
        if thread_id
          data = upsert_thread(data, thread_id, ThreadExecution::Stopped, data.stop_epoch)
        end
        data.execution = Execution::Stopped
        data.pending_resume = nil
        data.pending_pause = nil
        data.pause_response_received = false
      elsif thread_id
        data = upsert_thread(data, thread_id, ThreadExecution::Stopped, data.stop_epoch)
        if pause_targets?(data.pending_pause, thread_id)
          data.pending_pause = nil
          data.pause_response_received = false
        end
        data.execution = pending_execution(data, fallback: Execution::Partial)
      else
        data.broadcast_stop_epoch = data.stop_epoch
        data.unattributed_stop_epoch = data.stop_epoch
        data.execution = pending_execution(data, fallback: Execution::Partial)
      end

      DebugSessionState.new(data)
    end

    # DAP defines an omitted allThreadsContinued as true. This is different
    # from StoppedEvent.allThreadsStopped, whose omission is not proof of all.
    def continued(
      stamp : SessionStamp,
      thread_id : Int64? = nil,
      all_threads_continued : Bool? = nil,
    ) : DebugSessionState
      return self unless current_event?(stamp)
      return self if @data.lifecycle == Lifecycle::Disconnecting

      data = retire_all_handles
      data.target_liveness = TargetLiveness::Alive
      data.selected_frame_id = nil
      if all_threads_continued != false
        data.threads = data.threads.map { |thread| thread.update(execution: ThreadExecution::Running) }
        if thread_id
          data = upsert_thread(data, thread_id, ThreadExecution::Running, data.stop_epoch)
        end
        data.execution = Execution::Running
        data.pending_resume = nil
        data.pending_pause = nil
        data.pause_response_received = false
      elsif thread_id
        data = upsert_thread(data, thread_id, ThreadExecution::Running, data.stop_epoch)
        if resume_targets?(data.pending_resume, thread_id)
          data.pending_resume = nil
        end
        if pause_targets?(data.pending_pause, thread_id)
          data.pending_pause = nil
          data.pause_response_received = false
        end
        data.execution = pending_execution(data, fallback: Execution::Partial)
      else
        data.threads = data.threads.map { |thread| thread.update(execution: ThreadExecution::Unknown) }
        data.execution = Execution::Unknown
        data.pending_resume = nil
        data.pending_pause = nil
        data.pause_response_received = false
      end

      DebugSessionState.new(data)
    end

    # A threads response or `thread` event can establish an ID without
    # inventing execution status. Unknown entries cannot receive a step.
    def thread_seen(stamp : SessionStamp, thread_id : Int64) : DebugSessionState
      return self unless current_event?(stamp)
      return self if find_thread(thread_id)
      data = @data.copy
      if data.threads.size >= MAX_TRACKED_THREADS
        data.thread_tracking_limited = true
        data.execution = Execution::Unknown
      else
        data.threads << ThreadSnapshot.new(thread_id, ThreadExecution::Unknown, 0_u64, 0_u64)
      end
      if data.last_all_stopped_epoch == data.stop_epoch &&
         data.execution.in?(Execution::Stopped, Execution::Partial) &&
         find_thread_in(data, thread_id).try(&.execution) == ThreadExecution::Unknown
        data.execution = Execution::Partial
      end
      DebugSessionState.new(data)
    end

    # An exited thread event removes known membership and retires all derived
    # inspection handles. It is not evidence that the debuggee process exited.
    def thread_exited(stamp : SessionStamp, thread_id : Int64) : DebugSessionState
      return self unless current_event?(stamp)
      return self unless find_thread(thread_id)

      data = @data.copy
      data.threads.reject! { |thread| thread.id == thread_id }
      data = retire_all_handles(data)

      if data.selected_thread_id == thread_id
        data.thread_selection_generation += 1_u64
        data.selected_thread_id = nil
      end

      pending_target_exited = false
      if ticket = data.pending_resume
        if ticket.thread_id == thread_id
          data.pending_resume = nil
          pending_target_exited = true
        end
      end
      if ticket = data.pending_pause
        if ticket.thread_id == thread_id
          data.pending_pause = nil
          pending_target_exited = true
        end
      end

      if pending_target_exited
        data.execution = Execution::Unknown
        data.pause_response_received = false
      elsif data.threads.empty?
        data.execution = Execution::Unknown
      end

      DebugSessionState.new(data)
    end

    # A current Stop certificate permits a full `threads` response to
    # reconcile membership after either a global or thread-specific stop.
    # Only current all-threads-stop evidence promotes newly listed IDs to
    # Stopped; partial-stop listings preserve known states and leave new IDs
    # Unknown. Unsolicited thread events remain Unknown.
    def threads_listed(
      stamp : SessionStamp,
      thread_ids : Array(Int64),
      stop_certificate : RequestCertificate,
    ) : DebugSessionState
      return self unless current_event?(stamp)
      return self unless stop_certificate.scope == RequestScope::Stop && accepts?(stop_certificate)

      all_threads_stopped = @data.last_all_stopped_epoch == @data.stop_epoch
      data = @data.copy
      listed_threads = [] of ThreadSnapshot
      listed_ids = Set(Int64).new
      data.thread_tracking_limited = false
      thread_ids.each do |thread_id|
        next if listed_ids.includes?(thread_id)
        if listed_threads.size >= MAX_TRACKED_THREADS
          data.thread_tracking_limited = true
          next
        end
        listed_ids << thread_id

        existing = find_thread_in(@data, thread_id)
        if !all_threads_stopped
          listed_threads << (existing || ThreadSnapshot.new(thread_id, ThreadExecution::Unknown, 0_u64, 0_u64))
        elsif existing && existing.execution == ThreadExecution::Stopped && existing.stop_epoch == data.stop_epoch
          listed_threads << existing
        elsif existing
          listed_threads << existing.update(execution: ThreadExecution::Stopped, stop_epoch: data.stop_epoch)
        else
          listed_threads << ThreadSnapshot.new(thread_id, ThreadExecution::Stopped, 1_u64, data.stop_epoch)
        end
      end

      membership_changed = data.thread_tracking_limited || @data.threads.size != listed_ids.size ||
                           @data.threads.any? { |thread| !listed_ids.includes?(thread.id) }
      selected_thread_missing = data.selected_thread_id && !listed_threads.any? { |thread| thread.id == data.selected_thread_id }
      data = retire_all_handles(data) if membership_changed || selected_thread_missing
      if selected_thread_missing
        data.thread_selection_generation += 1_u64
        data.selected_thread_id = nil
        data.selected_frame_id = nil
      end
      data.threads = listed_threads
      if all_threads_stopped
        data.execution = Execution::Stopped
      else
        data.execution = listed_threads.any? { |thread| thread.execution == ThreadExecution::Stopped } ? Execution::Partial : Execution::Unknown
      end
      DebugSessionState.new(data)
    end

    # DAP's process event proves target liveness, not whether execution is
    # running or stopped.
    def process_started(stamp : SessionStamp) : DebugSessionState
      return self unless current_event?(stamp)
      return self if @data.target_liveness == TargetLiveness::Exited
      data = @data.copy
      data.target_liveness = TargetLiveness::Alive
      DebugSessionState.new(data)
    end

    # The `all_threads` argument is the effective dispatched scope, not a UI
    # preference. The controller may set it false only after capability
    # negotiation permits DAP's singleThread execution option.
    def begin_resume(
      request_id : UInt64,
      thread_id : Int64,
      all_threads : Bool,
    ) : Tuple(DebugSessionState, ResumeTicket?)
      thread = find_thread(thread_id)
      unless resumable?(thread)
        return {thread_limit_failure(thread_id), nil}
      end
      return {self, nil} unless @data.lifecycle == Lifecycle::Active
      return {self, nil} unless @data.pending_resume.nil? && @data.pending_pause.nil?
      return {self, nil} unless @data.execution.in?(Execution::Stopped, Execution::Partial)
      return {self, nil} unless thread.not_nil!.execution == ThreadExecution::Stopped

      stamp = session_stamp
      return {self, nil} unless stamp
      command_generation = @data.command_generation + 1_u64
      ticket = ResumeTicket.new(
        request_id, stamp, thread_id, all_threads, command_generation,
        @data.stop_epoch, thread.not_nil!.stop_epoch,
        @data.broadcast_stop_epoch, @data.unattributed_stop_epoch
      )

      # Invalidate frame/variable references before the caller writes Continue
      # or Step to the adapter.
      data = retire_all_handles
      data.command_generation = command_generation
      data.pending_resume = ticket
      data.execution = Execution::ResumePending
      data.selected_frame_id = nil
      if all_threads
        data.threads = data.threads.map { |known| known.update(execution: ThreadExecution::ResumePending) }
      else
        data = update_thread(data, thread_id, ThreadExecution::ResumePending)
      end
      {DebugSessionState.new(data), ticket}
    end

    def resume_succeeded(
      ticket : ResumeTicket,
      all_threads_continued : Bool? = nil,
    ) : DebugSessionState
      return self unless current_resume?(ticket)

      data = @data.copy
      data.pending_resume = nil
      continued_all = all_threads_continued != false

      if data.last_all_stopped_epoch > ticket.stop_epoch
        data.execution = Execution::Stopped
        return DebugSessionState.new(data)
      end
      if data.unattributed_stop_epoch > ticket.unattributed_stop_epoch
        data.execution = Execution::Unknown
        data.threads = data.threads.map { |thread| thread.update(execution: ThreadExecution::Unknown) }
        return DebugSessionState.new(data)
      end

      if continued_all
        mixed_stop = false
        data.threads = data.threads.map do |thread|
          if thread.stop_epoch > ticket.stop_epoch
            mixed_stop ||= thread.execution == ThreadExecution::Stopped
            thread
          else
            thread.update(execution: ThreadExecution::Running)
          end
        end
        data.execution = mixed_stop ? Execution::Partial : Execution::Running
      else
        target = find_thread_in(data, ticket.thread_id)
        if target && target.stop_epoch > ticket.thread_stop_epoch
          data.execution = Execution::Partial
        else
          data = update_thread(data, ticket.thread_id, ThreadExecution::Running)
          if ticket.all_threads
            data.threads = data.threads.map do |thread|
              if thread.id == ticket.thread_id || thread.stop_epoch > ticket.stop_epoch
                thread
              else
                thread.update(execution: ThreadExecution::Unknown)
              end
            end
          end
          data.execution = Execution::Partial
        end
      end

      DebugSessionState.new(data)
    end

    # Failure and timeout are ambiguous target outcomes. Do not restore the
    # pre-dispatch handles or claim Paused based on the error response.
    def resume_failed(ticket : ResumeTicket) : DebugSessionState
      return self unless current_resume?(ticket)
      data = @data.copy
      data.pending_resume = nil

      if data.last_all_stopped_epoch > ticket.stop_epoch
        data.execution = Execution::Stopped
      elsif data.unattributed_stop_epoch > ticket.unattributed_stop_epoch
        data.execution = Execution::Unknown
        data.threads = data.threads.map { |thread| thread.update(execution: ThreadExecution::Unknown) }
      elsif ticket.all_threads
        newer_stopped = false
        data.threads = data.threads.map do |thread|
          if thread.stop_epoch > ticket.stop_epoch && thread.execution == ThreadExecution::Stopped
            newer_stopped = true
            thread
          else
            thread.update(execution: ThreadExecution::Unknown)
          end
        end
        data.execution = newer_stopped ? Execution::Partial : Execution::Unknown
      elsif target = find_thread_in(data, ticket.thread_id)
        if target.stop_epoch > ticket.thread_stop_epoch && target.execution == ThreadExecution::Stopped
          data.execution = Execution::Partial
        else
          data = update_thread(data, ticket.thread_id, ThreadExecution::Unknown)
          data.execution = Execution::Unknown
        end
      else
        data.execution = Execution::Unknown
      end
      DebugSessionState.new(data)
    end

    def begin_pause(request_id : UInt64, thread_id : Int64) : Tuple(DebugSessionState, PauseTicket?)
      thread = find_thread(thread_id)
      return {self, nil} unless @data.lifecycle == Lifecycle::Active
      return {self, nil} unless @data.target_liveness == TargetLiveness::Alive
      return {self, nil} unless @data.pending_resume.nil? && @data.pending_pause.nil?
      # Pause is also an explicit recovery action after an ambiguous Resume.
      # Require a tracked ID and an active, last-known-live local target; do
      # not fabricate a thread or claim the Pause has already stopped it.
      return {self, nil} unless @data.execution.in?(Execution::Running, Execution::Partial, Execution::Unknown)
      return {self, nil} unless thread && thread.execution.in?(ThreadExecution::Running, ThreadExecution::Unknown)
      stamp = session_stamp
      return {self, nil} unless stamp

      command_generation = @data.command_generation + 1_u64
      ticket = PauseTicket.new(
        request_id, stamp, thread_id, command_generation, @data.stop_epoch,
        thread.stop_epoch, @data.broadcast_stop_epoch, @data.unattributed_stop_epoch
      )
      data = @data.copy
      data.command_generation = command_generation
      data.pending_pause = ticket
      data.pause_response_received = false
      data.execution = Execution::PausePending
      data = update_thread(data, thread_id, ThreadExecution::PausePending)
      {DebugSessionState.new(data), ticket}
    end

    # A successful Pause response acknowledges the request, not a stop.
    def pause_succeeded(ticket : PauseTicket) : DebugSessionState
      return self unless current_pause?(ticket)
      return self if @data.pause_response_received
      data = @data.copy
      data.pause_response_received = true
      DebugSessionState.new(data)
    end

    def pause_failed(ticket : PauseTicket) : DebugSessionState
      return self unless current_pause?(ticket)
      return self if @data.pause_response_received
      data = @data.copy
      data.pending_pause = nil
      data.pause_response_received = false
      target = find_thread_in(data, ticket.thread_id)
      if data.last_all_stopped_epoch > ticket.stop_epoch
        data.execution = Execution::Stopped
      elsif data.unattributed_stop_epoch > ticket.unattributed_stop_epoch
        data.execution = Execution::Unknown
        data.threads = data.threads.map { |thread| thread.update(execution: ThreadExecution::Unknown) }
      elsif target && target.stop_epoch > ticket.thread_stop_epoch
        data.execution = Execution::Partial
      else
        data = update_thread(data, ticket.thread_id, ThreadExecution::Unknown)
        data.execution = Execution::Unknown
        data = retire_all_handles(data)
      end
      DebugSessionState.new(data)
    end

    # The controller calls this at its bounded stop-event deadline. A Pause
    # acknowledgement is not stop evidence, so expiry leaves execution
    # Unknown unless a newer stop event already cleared the pending ticket.
    def pause_unconfirmed(ticket : PauseTicket) : DebugSessionState
      return self unless current_pause?(ticket)
      data = @data.copy
      data.pending_pause = nil
      data.pause_response_received = false
      target = find_thread_in(data, ticket.thread_id)
      if target && target.stop_epoch > ticket.thread_stop_epoch && target.execution == ThreadExecution::Stopped
        data.execution = Execution::Partial
      else
        data = update_thread(data, ticket.thread_id, ThreadExecution::Unknown)
        data.execution = Execution::Unknown
      end
      data = retire_all_handles(data)
      DebugSessionState.new(data)
    end

    def certificate(
      request_id : UInt64,
      scope : RequestScope,
      thread_id : Int64? = @data.selected_thread_id,
    ) : RequestCertificate
      stamp = session_stamp || SessionStamp.new(@data.session_generation, "", "", @data.project_generation)
      thread = thread_id.try { |id| find_thread(id) }
      RequestCertificate.new(
        request_id, stamp, scope, @data.stop_epoch, @data.handle_generation,
        @data.thread_selection_generation, thread_id,
        thread.try(&.state_generation), @data.frame_selection_generation,
        @data.selected_frame_id, @data.format_generation
      )
    end

    def accepts?(certificate : RequestCertificate) : Bool
      return false unless current_stamp?(certificate.stamp)
      if certificate.scope == RequestScope::Session
        return @data.lifecycle.in?(Lifecycle::Starting, Lifecycle::Configuring, Lifecycle::Active, Lifecycle::Disconnecting)
      end
      return false unless inspection_ready?
      return false unless certificate.stop_epoch == @data.stop_epoch
      return false unless certificate.handle_generation == @data.handle_generation
      return true if certificate.scope == RequestScope::Stop
      return false unless certificate.thread_selection_generation == @data.thread_selection_generation
      return false unless certificate.thread_id == @data.selected_thread_id
      thread_id = certificate.thread_id
      return false unless thread_id
      thread = find_thread(thread_id)
      return false unless thread
      return false unless certificate.thread_state_generation == thread.state_generation
      return false unless thread.execution == ThreadExecution::Stopped
      return true if certificate.scope == RequestScope::Thread
      return false unless certificate.frame_selection_generation == @data.frame_selection_generation
      return false unless certificate.frame_id == @data.selected_frame_id
      return false unless certificate.frame_id
      return true if certificate.scope == RequestScope::Frame
      certificate.format_generation == @data.format_generation
    end

    def select_thread(thread_id : Int64?) : DebugSessionState
      return self if @data.selected_thread_id == thread_id
      data = retire_all_handles
      data.thread_selection_generation += 1_u64
      data.frame_selection_generation += 1_u64
      data.selected_thread_id = thread_id
      data.selected_frame_id = nil
      DebugSessionState.new(data)
    end

    def select_frame(frame_id : Int64?) : DebugSessionState
      return self if @data.selected_thread_id.nil?
      return self if @data.selected_frame_id == frame_id
      data = retire_all_handles
      data.frame_selection_generation += 1_u64
      data.selected_frame_id = frame_id
      DebugSessionState.new(data)
    end

    def change_format(format_key : String) : DebugSessionState
      return self if @data.format_key == format_key
      data = @data.copy
      data.format_key = format_key
      data.format_generation += 1_u64
      DebugSessionState.new(data)
    end

    def project_changed(project_generation : UInt64) : DebugSessionState
      return self unless project_generation > @data.project_generation
      data = retire_all_handles
      data.project_generation = project_generation
      data.thread_selection_generation += 1_u64
      data.frame_selection_generation += 1_u64
      data.threads.clear
      data.thread_tracking_limited = false
      data.selected_thread_id = nil
      data.selected_frame_id = nil
      data.execution = Execution::Unknown
      data.target_liveness = TargetLiveness::Unknown
      data.pending_resume = nil
      data.pending_pause = nil
      data.pause_response_received = false
      DebugSessionState.new(data)
    end

    # Any unfamiliar area fails closed by retiring all inspection handles.
    # The area list is consumed synchronously and is never retained.
    def invalidated(
      stamp : SessionStamp,
      areas : Array(String)? = nil,
    ) : DebugSessionState
      return self unless current_event?(stamp)
      known = areas && !areas.empty? && areas.all? { |area| area.in?("threads", "stacks", "variables") }
      data = retire_all_handles
      # Missing, empty, or future invalidation areas cannot safely be treated
      # as a no-op: retire every handle and conservatively forget execution.
      unless known
        data.threads = data.threads.map { |thread| thread.update(execution: ThreadExecution::Unknown) }
        data.execution = Execution::Unknown
        data.selected_thread_id = nil
        data.thread_selection_generation += 1_u64
        data.frame_selection_generation += 1_u64
        return DebugSessionState.new(data)
      end
      if areas.not_nil!.includes?("stacks")
        data.frame_selection_generation += 1_u64
        data.selected_frame_id = nil
      end
      if areas.not_nil!.includes?("threads")
        data.threads = data.threads.map { |thread| thread.update(execution: ThreadExecution::Unknown) }
        data.execution = Execution::Unknown
      end
      DebugSessionState.new(data)
    end

    def exited(stamp : SessionStamp) : DebugSessionState
      return self unless current_stamp?(stamp)
      return self if @data.target_liveness == TargetLiveness::Exited
      data = retire_all_handles
      data.target_liveness = TargetLiveness::Exited
      data.execution = Execution::Unknown
      data.pending_resume = nil
      data.pending_pause = nil
      data.pause_response_received = false
      DebugSessionState.new(data)
    end

    def terminated(stamp : SessionStamp) : DebugSessionState
      return self unless current_stamp?(stamp)
      return self if @data.lifecycle == Lifecycle::Ended
      data = retire_all_handles
      data.lifecycle = Lifecycle::Ended
      data.execution = Execution::Unknown
      data.target_liveness = TargetLiveness::Unknown unless data.target_liveness == TargetLiveness::Exited
      data.pending_resume = nil
      data.pending_pause = nil
      data.pause_response_received = false
      DebugSessionState.new(data)
    end

    def disconnected(stamp : SessionStamp) : DebugSessionState
      return self unless current_stamp?(stamp)
      return self if @data.lifecycle == Lifecycle::Ended
      data = retire_all_handles
      data.lifecycle = Lifecycle::Failed unless data.lifecycle == Lifecycle::Failed
      data.execution = Execution::Unknown
      data.target_liveness = TargetLiveness::Unknown unless data.target_liveness == TargetLiveness::Exited
      data.pending_resume = nil
      data.pending_pause = nil
      data.pause_response_received = false
      DebugSessionState.new(data)
    end

    private def restartable? : Bool
      @data.lifecycle.in?(Lifecycle::Idle, Lifecycle::Ended, Lifecycle::Failed)
    end

    private def terminal? : Bool
      @data.lifecycle.in?(Lifecycle::Ended, Lifecycle::Failed)
    end

    private def inspection_ready? : Bool
      @data.lifecycle == Lifecycle::Active &&
        @data.execution.in?(Execution::Stopped, Execution::Partial)
    end

    private def current_stamp?(stamp : SessionStamp) : Bool
      adapter = @data.adapter_id
      client_instance = @data.client_instance_id
      !!adapter && !!client_instance &&
        stamp.generation == @data.session_generation &&
        stamp.adapter_id == adapter &&
        stamp.client_instance_id == client_instance &&
        stamp.project_generation == @data.project_generation
    end

    private def current_event?(stamp : SessionStamp) : Bool
      current_stamp?(stamp) &&
        @data.lifecycle.in?(Lifecycle::Starting, Lifecycle::Configuring, Lifecycle::Active) &&
        @data.target_liveness != TargetLiveness::Exited
    end

    private def current_resume?(ticket : ResumeTicket) : Bool
      @data.lifecycle == Lifecycle::Active &&
        @data.pending_resume == ticket &&
        current_stamp?(ticket.stamp)
    end

    private def current_pause?(ticket : PauseTicket) : Bool
      @data.lifecycle == Lifecycle::Active &&
        @data.pending_pause == ticket &&
        current_stamp?(ticket.stamp)
    end

    private def resumable?(thread : ThreadSnapshot?) : Bool
      !!thread && @data.execution.in?(Execution::Stopped, Execution::Partial) &&
        thread.not_nil!.execution == ThreadExecution::Stopped
    end

    private def thread_limit_failure(thread_id : Int64) : DebugSessionState
      return self if find_thread(thread_id) || @data.threads.size < MAX_TRACKED_THREADS
      data = @data.copy
      data.thread_tracking_limited = true
      data.execution = Execution::Unknown
      DebugSessionState.new(data)
    end

    private def find_thread(thread_id : Int64) : ThreadSnapshot?
      find_thread_in(@data, thread_id)
    end

    private def find_thread_in(data : Data, thread_id : Int64) : ThreadSnapshot?
      data.threads.find { |thread| thread.id == thread_id }
    end

    private def upsert_thread(
      data : Data,
      thread_id : Int64,
      execution : ThreadExecution,
      stop_epoch : UInt64,
    ) : Data
      index = data.threads.index { |thread| thread.id == thread_id }
      if index
        data.threads[index] = data.threads[index].update(execution: execution, stop_epoch: stop_epoch)
      elsif data.threads.size < MAX_TRACKED_THREADS
        data.threads << ThreadSnapshot.new(thread_id, execution, 1_u64, stop_epoch)
      else
        data.thread_tracking_limited = true
        data.execution = Execution::Unknown
      end
      data
    end

    private def update_thread(data : Data, thread_id : Int64, execution : ThreadExecution) : Data
      index = data.threads.index { |thread| thread.id == thread_id }
      if index
        data.threads[index] = data.threads[index].update(execution: execution)
      else
        data.thread_tracking_limited = true if data.threads.size >= MAX_TRACKED_THREADS
        data.execution = Execution::Unknown
      end
      data
    end

    private def retire_all_handles(data : Data = @data.copy) : Data
      data.handle_generation += 1_u64
      data.frame_selection_generation += 1_u64
      data.selected_frame_id = nil
      data
    end

    private def pending_execution(data : Data, fallback : Execution) : Execution
      return Execution::ResumePending if data.pending_resume
      return Execution::PausePending if data.pending_pause
      fallback
    end

    private def resume_targets?(ticket : ResumeTicket?, thread_id : Int64) : Bool
      !!ticket && (ticket.all_threads || ticket.thread_id == thread_id)
    end

    private def pause_targets?(ticket : PauseTicket?, thread_id : Int64) : Bool
      !!ticket && ticket.thread_id == thread_id
    end
  end
end
