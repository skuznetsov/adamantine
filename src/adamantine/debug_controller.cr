require "json"
require "random/secure"
require "set"

require "./dap/client"
require "./debug_session_state"
require "./debug_profile_store"
require "./debug_source_store"
require "./debug_source_resolver"
require "./debug_breakpoint_store"
require "./debug_variable_tree"
require "./debug_value_detail"

module Adamantine
  # UI-agnostic owner of a single explicitly reviewed DAP launch. Construction,
  # snapshots and rendering are inert; poll is a nonblocking event pump.
  class DebugController
    alias ClientFactory = Proc(Array(String), Path, Dap::Client)

    enum Action
      Start
      Continue
      Pause
      StepOver
      StepInto
      StepOut
      Stop
      SelectThread
      SelectFrame
      ToggleBreakpoint
      OpenScopes
      ExpandVariable
      AddWatch
      EvaluateWatch
      OpenSource
    end

    enum WatchStatus
      NotEvaluated
      Pending
      Available
      Unavailable
    end

    class ActionAvailability
      getter enabled : Bool
      @reason : String?

      def initialize(@enabled : Bool, reason : String? = nil)
        @reason = reason.try(&.dup)
      end

      def enabled? : Bool
        @enabled
      end

      def reason : String?
        @reason.try(&.dup)
      end
    end

    class ActionSubmission
      getter local_request_id : UInt64?
      @accepted : Bool
      @reason : String?

      def initialize(@accepted : Bool, reason : String? = nil, @local_request_id : UInt64? = nil)
        @reason = reason.try(&.dup)
      end

      def accepted? : Bool
        @accepted
      end

      def reason : String?
        @reason.try(&.dup)
      end
    end

    class SourceBaseline
      MAX_BYTES = 32 * 1024 * 1024
      @path : String
      @text : String
      getter checksum : Debugging::DebugChecksum?

      def initialize(path : Path | String, text : String, @checksum : Debugging::DebugChecksum? = nil)
        raise ArgumentError.new("source baseline exceeds 32 MiB") if text.bytesize > MAX_BYTES
        raise ArgumentError.new("source baseline is not valid UTF-8") unless text.valid_encoding?
        @path = path.to_s.dup
        @text = text.dup
      end

      def path : String
        @path.dup
      end

      def text : String
        @text.dup
      end

      def bytesize : Int32
        @text.bytesize
      end
    end

    class LaunchReview
      getter valid : Bool
      @owner_id : String
      @token : String
      @project_root : String
      @profile : Debugging::LaunchProfile
      @errors : Array(String)
      @baselines : Array(SourceBaseline)
      getter project_generation : UInt64

      protected def initialize(@owner_id : String, @token : String, @project_root : String,
                               @profile : Debugging::LaunchProfile, @project_generation : UInt64,
                               errors : Array(String), baselines : Array(SourceBaseline))
        @errors = errors.map(&.dup)
        @baselines = baselines.dup
        @valid = @errors.empty?
      end

      def valid? : Bool
        @valid
      end

      def errors : Array(String)
        @errors.map(&.dup)
      end

      def profile_name : String
        @profile.name
      end

      protected def owner_id : String
        @owner_id.dup
      end

      protected def token : String
        @token.dup
      end

      protected def project_root : String
        @project_root.dup
      end

      protected def profile : Debugging::LaunchProfile
        @profile
      end

      protected def baselines : Array(SourceBaseline)
        @baselines.dup
      end
    end

    struct Capabilities
      getter configuration_done : Bool
      getter single_thread_execution : Bool
      getter terminate_request : Bool
      getter support_terminate_debuggee : Bool
      getter value_formatting_options : Bool

      def initialize(@configuration_done : Bool = false,
                     @single_thread_execution : Bool = false,
                     @terminate_request : Bool = false,
                     @support_terminate_debuggee : Bool = false,
                     @value_formatting_options : Bool = false)
      end
    end

    class FrameView
      getter id : Int64
      getter dap_line : Int32?
      getter dap_column : Int32?
      getter editor_line : Int32?
      getter editor_column : Int32?
      getter source_reference : Int32?
      getter source_key : Debugging::DebugSourceKey?
      getter selected : Bool
      @name : String
      @source_name : String?
      @source_path : String?
      @unavailable_reason : String?

      def initialize(@id : Int64, name : String, @dap_line : Int32?, @dap_column : Int32?,
                     @editor_line : Int32?, @editor_column : Int32?,
                     @source_reference : Int32?, @source_key : Debugging::DebugSourceKey?,
                     source_name : String?, source_path : String?, unavailable_reason : String? = nil,
                     @selected : Bool = false)
        @name = name.dup
        @source_name = source_name.try(&.dup)
        @source_path = source_path.try(&.dup)
        @unavailable_reason = unavailable_reason.try(&.dup)
      end

      def name : String
        @name.dup
      end

      def source_name : String?
        @source_name.try(&.dup)
      end

      def source_path : String?
        @source_path.try(&.dup)
      end

      def unavailable_reason : String?
        @unavailable_reason.try(&.dup)
      end
    end

    class SourceBreakpointView
      getter source_key : Debugging::DebugSourceKey
      getter breakpoint : Debugging::DebugBreakpointView

      def initialize(@source_key : Debugging::DebugSourceKey,
                     @breakpoint : Debugging::DebugBreakpointView)
      end
    end

    class ThreadView
      getter id : Int64
      getter execution : DebugSessionState::ThreadExecution
      @name : String

      def initialize(@id : Int64, @execution : DebugSessionState::ThreadExecution, name : String)
        @name = name.dup
      end

      def name : String
        @name.dup
      end
    end

    class OutputEntry
      getter category : String
      getter timestamp : Time
      @text : String

      def initialize(@category : String, @timestamp : Time, text : String)
        @text = text.dup
      end

      def text : String
        @text.dup
      end
    end

    class SourceView
      getter key : Debugging::DebugSourceKey
      getter origin : Debugging::SourceOrigin
      getter checksum_status : Debugging::ChecksumStatus
      getter outdated : Bool
      @text : String
      @reason : String?
      @display_path : String?

      def initialize(@key : Debugging::DebugSourceKey, @origin : Debugging::SourceOrigin,
                     @checksum_status : Debugging::ChecksumStatus, @outdated : Bool,
                     text : String, reason : String? = nil, display_path : String? = nil)
        @text = text.dup
        @reason = reason.try(&.dup)
        @display_path = display_path.try(&.dup)
      end

      def text : String
        @text.dup
      end

      def reason : String?
        @reason.try(&.dup)
      end

      def display_path : String?
        @display_path.try(&.dup)
      end
    end

    class WatchView
      @id : String
      @expression : String
      @result : String?
      @type : String?
      @reason : String?
      getter status : WatchStatus

      def initialize(id : String, expression : String, @status : WatchStatus,
                     result : String? = nil, type : String? = nil, reason : String? = nil)
        @id = id.dup
        @expression = expression.dup
        @result = result.try(&.dup)
        @type = type.try(&.dup)
        @reason = reason.try(&.dup)
      end

      def id : String
        @id.dup
      end

      def expression : String
        @expression.dup
      end

      def result : String?
        @result.try(&.dup)
      end

      def type : String?
        @type.try(&.dup)
      end

      def reason : String?
        @reason.try(&.dup)
      end
    end

    class Snapshot
      getter state : DebugSessionState
      getter capabilities : Capabilities
      getter output_dropped : Int64
      getter cleanup_pending : Bool
      getter target_exit_code : Int32?
      getter generation : UInt64
      getter variable_generation : UInt64
      getter source_generation : UInt64
      getter breakpoint_generation : UInt64
      getter variables : Debugging::DebugVariableSnapshot
      @frames : Array(FrameView)
      @threads : Array(ThreadView)
      @breakpoints : Array(SourceBreakpointView)
      @output : Array(OutputEntry)
      @sources : Array(SourceView)
      @watches : Array(WatchView)
      @last_error : String?
      @availability : Hash(Action, ActionAvailability)

      def initialize(@state : DebugSessionState, @capabilities : Capabilities,
                     @output_dropped : Int64, @cleanup_pending : Bool,
                     @target_exit_code : Int32?,
                     @generation : UInt64, @variable_generation : UInt64,
                     @source_generation : UInt64, @breakpoint_generation : UInt64,
                     variables : Debugging::DebugVariableSnapshot,
                     frames : Array(FrameView), threads : Array(ThreadView),
                     breakpoints : Array(SourceBreakpointView),
                     output : Array(OutputEntry), sources : Array(SourceView),
                     watches : Array(WatchView), last_error : String?,
                     availability : Hash(Action, ActionAvailability))
        @variables = variables
        @frames = frames.dup
        @threads = threads.dup
        @breakpoints = breakpoints.dup
        @output = output.dup
        @sources = sources.dup
        @watches = watches.dup
        @last_error = last_error.try(&.dup)
        @availability = availability.dup
      end

      def frames : Array(FrameView)
        @frames.dup
      end

      def threads : Array(ThreadView)
        @threads.dup
      end

      def breakpoints : Array(SourceBreakpointView)
        @breakpoints.dup
      end

      def output : Array(OutputEntry)
        @output.dup
      end

      def sources : Array(SourceView)
        @sources.dup
      end

      def watches : Array(WatchView)
        @watches.dup
      end

      def last_error : String?
        @last_error.try(&.dup)
      end

      def availability(action : Action) : ActionAvailability
        @availability[action]? || ActionAvailability.new(false, "action is not available")
      end

      def available?(action : Action) : Bool
        availability(action).enabled?
      end
    end

    # A UI-safe constructor; callers never need to import or invoke Dap::Client.
    def self.default(project_generation : UInt64 = 0_u64,
                     max_message_mib_provider : Proc(Int32)? = nil) : DebugController
      provider = max_message_mib_provider
      factory : ClientFactory = ->(argv : Array(String), cwd : Path) do
        mib = provider ? provider.not_nil!.call : 16
        raise ArgumentError.new("DAP message limit must be between 1 and 64 MiB") unless mib.in?(1..64)
        message_bytes = mib * 1024 * 1024
        limits = Dap::Limits.new(
          max_message_bytes: message_bytes,
          max_aggregate_inbound_bytes: message_bytes.to_i64 * 2,
          max_decoded_queue_bytes: message_bytes.to_i64 * 4,
          max_writer_queue_bytes: message_bytes.to_i64
        )
        Dap::Client.new(argv, cwd, limits)
      end
      new(factory, project_generation)
    end

    enum PendingKind
      Initialize
      Launch
      ExceptionBreakpoints
      ConfigurationDone
      SetBreakpoints
      Threads
      StackTrace
      Scopes
      Variables
      Resume
      Pause
      Watch
      Source
      Disconnect
      ValueFormat
    end

    enum ValueFormatStatus
      Pending
      Available
      Unavailable
      Retired
    end

    private class ValueFormatState
      getter node_id : String
      getter generation : UInt64
      getter variable_generation : UInt64
      getter status : ValueFormatStatus
      @value : String?
      @reason : String?

      def initialize(node_id : String, @generation : UInt64, @variable_generation : UInt64,
                     @status : ValueFormatStatus, value : String? = nil, reason : String? = nil)
        @node_id = node_id.dup
        @value = value.try(&.dup)
        @reason = reason.try(&.dup)
      end

      def value : String?
        @value.try(&.dup)
      end

      def reason : String?
        @reason.try(&.dup)
      end
    end

    private class PendingRequest
      getter ticket : Dap::Ticket
      getter kind : PendingKind
      getter certificate : DebugSessionState::RequestCertificate?
      getter resume_ticket : DebugSessionState::ResumeTicket?
      getter pause_ticket : DebugSessionState::PauseTicket?
      getter thread_id : Int64?
      getter frame_id : Int64?
      getter page : Debugging::DebugVariablePage?
      getter batch : Debugging::DebugBreakpointBatch?
      getter source_key : Debugging::DebugSourceKey?
      getter watch_id : String?
      getter request_id : UInt64
      getter format_node_id : String?
      getter format_origin : Debugging::DebugVariableOrigin?
      getter format_generation : UInt64?
      getter format_variable_generation : UInt64?

      def initialize(@ticket : Dap::Ticket, @kind : PendingKind,
                     @certificate : DebugSessionState::RequestCertificate? = nil,
                     @resume_ticket : DebugSessionState::ResumeTicket? = nil,
                     @pause_ticket : DebugSessionState::PauseTicket? = nil,
                     @thread_id : Int64? = nil, @frame_id : Int64? = nil,
                     @page : Debugging::DebugVariablePage? = nil,
                     @batch : Debugging::DebugBreakpointBatch? = nil,
                     @source_key : Debugging::DebugSourceKey? = nil,
                     @watch_id : String? = nil, @request_id : UInt64 = 0_u64,
                     @format_node_id : String? = nil,
                     @format_origin : Debugging::DebugVariableOrigin? = nil,
                     @format_generation : UInt64? = nil,
                     @format_variable_generation : UInt64? = nil)
      end
    end

    private class WatchEntry
      property id : String
      property expression : String
      property display_expression : String
      property status : WatchStatus
      property result : String?
      property type : String?
      property reason : String?

      def initialize(@id : String, @expression : String, @display_expression : String)
        @status = WatchStatus::NotEvaluated
        @result = nil
        @type = nil
        @reason = nil
      end

      def view : WatchView
        WatchView.new(@id, @display_expression, @status, @result, @type, @reason)
      end
    end

    MAX_BASELINE_ROOTS = 32
    MAX_BASELINE_BYTES = 32_i64 * 1024 * 1024
    MAX_OUTPUT_ENTRIES = 256
    MAX_OUTPUT_BYTES   = 64 * 1024
    MAX_OUTPUT_ENTRY   = 4096
    MAX_SOURCE_REQUEST = 4 * 1024 * 1024
    MAX_WATCHES        = 128
    MAX_WATCH_BYTES    = 16 * 1024
    MAX_SCOPES         = 128

    @factory : ClientFactory
    @project_generation : UInt64
    @bound_project_root : Path?
    @controller_id : String
    @state : DebugSessionState
    @client : Dap::Client?
    @profile : Debugging::LaunchProfile?
    @review_id : String?
    @review_consumed : Bool
    @resolver : Debugging::DebugSourceResolver?
    @source_store : Debugging::DebugSourceStore?
    @breakpoint_store : Debugging::DebugBreakpointStore
    @variable_tree : Debugging::DebugVariableTree
    @variable_snapshot : Debugging::DebugVariableSnapshot
    @frames : Array(FrameView)
    @threads : Array(ThreadView)
    @sources : Hash(Debugging::DebugSourceKey, SourceView)
    @source_resolutions : Hash(Debugging::DebugSourceKey, Debugging::DebugSourceResolution)
    @watches : Array(WatchEntry)
    @output : Array(OutputEntry)
    @output_bytes : Int32
    @output_dropped : Int64
    @capabilities : Capabilities
    @pending : Hash(Int32, PendingRequest)
    @last_error : String?
    @init_ticket : Dap::Ticket?
    @launch_ticket : Dap::Ticket?
    @initialized_seen : Bool
    @launch_succeeded : Bool
    @config_done_supported : Bool
    @config_done_sent : Bool
    @config_done_succeeded : Bool
    @exception_config_succeeded : Bool
    @config_setup_dispatched : Bool
    @config_requests : Int32
    @execution_in_flight : Bool
    @stop_requested : Bool
    @disconnect_sent : Bool
    @cleanup_pending : Bool
    @close_started : Bool
    @target_exit_code : Int32?
    @next_local_request_id : UInt64
    @pending_stop_ticket : DebugSessionState::PauseTicket?
    @pending_stop_deadline : Time::Span?
    @stop_deadline : Time::Span?
    @applied_breakpoint_generations : Hash(Debugging::DebugSourceKey, UInt64)
    @breakpoint_keys : Set(Debugging::DebugSourceKey)
    @generation : UInt64
    @variable_generation : UInt64
    @source_generation : UInt64
    @breakpoint_generation : UInt64
    @value_format_generation : UInt64
    @value_format_state : ValueFormatState?
    @value_format_pending_sequence : Int32?
    @cached_breakpoint_views : Array(SourceBreakpointView)?
    @cached_source_views : Array(SourceView)?
    @review_root : String?
    @init_body : JSON::Any?
    @launch_sent : Bool

    def initialize(@factory : ClientFactory, @project_generation : UInt64 = 0_u64)
      @bound_project_root = nil
      @controller_id = Random::Secure.hex(16)
      @state = DebugSessionState.initial(@project_generation)
      @client = nil
      @profile = nil
      @review_id = nil
      @review_consumed = false
      @resolver = nil
      @source_store = nil
      @breakpoint_store = Debugging::DebugBreakpointStore.new(@controller_id)
      @variable_tree = Debugging::DebugVariableTree.new
      @variable_snapshot = @variable_tree.snapshot
      @frames = [] of FrameView
      @threads = [] of ThreadView
      @sources = {} of Debugging::DebugSourceKey => SourceView
      @source_resolutions = {} of Debugging::DebugSourceKey => Debugging::DebugSourceResolution
      @watches = [] of WatchEntry
      @output = [] of OutputEntry
      @output_bytes = 0
      @output_dropped = 0_i64
      @capabilities = Capabilities.new
      @pending = {} of Int32 => PendingRequest
      @last_error = nil
      @init_ticket = nil
      @launch_ticket = nil
      @initialized_seen = false
      @launch_succeeded = false
      @config_done_supported = false
      @config_done_sent = false
      @config_done_succeeded = false
      @exception_config_succeeded = false
      @config_setup_dispatched = false
      @config_requests = 0
      @execution_in_flight = false
      @stop_requested = false
      @disconnect_sent = false
      @cleanup_pending = false
      @close_started = false
      @target_exit_code = nil
      @next_local_request_id = 0_u64
      @pending_stop_ticket = nil
      @pending_stop_deadline = nil
      @stop_deadline = nil
      @applied_breakpoint_generations = {} of Debugging::DebugSourceKey => UInt64
      @breakpoint_keys = Set(Debugging::DebugSourceKey).new
      @generation = 0_u64
      @variable_generation = 0_u64
      @source_generation = 0_u64
      @breakpoint_generation = 0_u64
      @value_format_generation = 0_u64
      @value_format_state = nil
      @value_format_pending_sequence = nil
      @cached_breakpoint_views = nil
      @cached_source_views = nil
      @review_root = nil
      @init_body = nil
      @launch_sent = false
    end

    def state : DebugSessionState
      @state
    end

    def prepare_launch(profile : Debugging::LaunchProfile, project_root : Path | String,
                       baselines : Array(SourceBaseline) = [] of SourceBaseline) : LaunchReview
      errors = profile.review_errors(project_root)
      root_candidate = Path.new(project_root.to_s).expand
      root = if File.directory?(root_candidate.to_s)
               Path.new(File.realpath(root_candidate.to_s))
             else
               root_candidate
             end
      @bound_project_root = root if File.directory?(root.to_s)
      errors << "at most #{MAX_BASELINE_ROOTS} launch source baselines may be retained" if baselines.size > MAX_BASELINE_ROOTS
      total = 0_i64
      baselines.first(MAX_BASELINE_ROOTS).each do |baseline|
        total += baseline.bytesize
        path = Path.new(baseline.path).expand
        unless path.absolute? && File.file?(path.to_s) && within_project?(path, root)
          errors << "source baseline path must be an existing file inside the reviewed project"
        end
      end
      errors << "launch source baselines exceed 32 MiB" if total > MAX_BASELINE_BYTES
      review_id = Random::Secure.hex(16)
      @review_id = review_id
      @review_consumed = false
      @review_root = root.to_s
      safe_baselines = errors.empty? ? baselines.first(MAX_BASELINE_ROOTS) : [] of SourceBaseline
      LaunchReview.new(@controller_id, review_id, root.to_s, profile, @project_generation,
        errors.uniq.first(64), safe_baselines)
    rescue
      LaunchReview.new(@controller_id, Random::Secure.hex(16), project_root.to_s,
        profile, @project_generation, ["launch review could not be prepared safely"], [] of SourceBaseline)
    end

    def project_changed(project_generation : UInt64) : Nil
      return unless project_generation > @project_generation
      @project_generation = project_generation
      @state = @state.project_changed(project_generation)
      @review_id = nil
      @review_consumed = true
      retire_inspection("project changed")
      @generation += 1_u64
    end

    # Explicit inert binding used by breakpoint actions before a launch is
    # reviewed. It canonicalizes an existing project directory but performs no
    # adapter or source-file IO.
    def bind_project(project_root : Path | String, project_generation : UInt64) : Bool
      candidate = Path.new(project_root.to_s).expand
      return false unless candidate.absolute? && File.directory?(candidate.to_s)
      canonical = Path.new(File.realpath(candidate.to_s))
      if project_generation > @project_generation
        project_changed(project_generation)
      elsif project_generation < @project_generation
        return false
      end
      @bound_project_root = canonical
      true
    rescue
      false
    end

    def start(review : LaunchReview) : ActionSubmission
      return rejected("launch review is invalid") unless review.valid?
      return rejected("launch review belongs to another controller") unless review.owner_id == @controller_id
      return rejected("launch review is stale or already consumed") unless @review_id == review.token && !@review_consumed
      return rejected("project changed since launch review") unless review.project_generation == @project_generation
      return rejected("a debugger session is already active or cleaning up") unless restartable?
      root = Path.new(review.project_root)
      return rejected("project root changed since launch review") unless @review_root == review.project_root && File.directory?(root.to_s) && File.realpath(root.to_s) == root.to_s
      current_errors = review.profile.review_errors(root)
      return rejected("launch profile changed or became invalid after review") unless current_errors.empty?

      @review_consumed = true
      @review_id = nil
      profile = review.profile
      @last_error = nil
      @init_body = nil
      @launch_sent = false
      client = @factory.call(profile.adapter_argv, Path.new(profile.cwd))
      @client = client
      @profile = profile
      session_id = client.session_id
      @breakpoint_store.new_session(session_id)
      @source_store = Debugging::DebugSourceStore.new(session_id)
      @resolver = Debugging::DebugSourceResolver.new(review.project_root, profile.source_maps, session_id)
      review.baselines.each do |baseline|
        key = Debugging::DebugSourceKey.local(baseline.path)
        capture = @source_store.not_nil!.capture_baseline(key, baseline.text, pin: true, checksum: baseline.checksum)
        @last_error = capture.reason unless capture.retained?
      end
      @sources.clear
      @source_resolutions.clear
      @frames.clear
      @threads.clear
      @pending.clear
      @generation += 1_u64
      @source_generation += 1_u64
      @breakpoint_generation += 1_u64
      @cached_source_views = nil
      @cached_breakpoint_views = nil
      @initialized_seen = false
      @launch_succeeded = false
      @config_done_supported = false
      @config_done_sent = false
      @config_done_succeeded = false
      @exception_config_succeeded = false
      @config_setup_dispatched = false
      @config_requests = 0
      @execution_in_flight = false
      @stop_requested = false
      @disconnect_sent = false
      @cleanup_pending = false
      @close_started = false
      @target_exit_code = nil
      @applied_breakpoint_generations.clear
      retire_value_format
      @value_format_pending_sequence = nil
      @state = @state.begin_session(File.basename(profile.adapter_argv.first), session_id, @project_generation)
      client.start
      ticket = client.initialize_adapter("adamantine", "lldb-dap",
        supports_variable_paging: true, supports_variable_type: true)
      @init_ticket = ticket
      @pending[ticket.sequence] = PendingRequest.new(ticket, PendingKind::Initialize)
      accepted(nil, next_request_id)
    rescue ex
      @last_error = safe_error(ex.message || "debug adapter could not be started")
      @state = @state.disconnected(@state.session_stamp.not_nil!) if @state.session_stamp
      begin_async_close
      rejected(@last_error || "debug adapter could not be started")
    end

    # Nonblocking explicit pump. It consumes bounded client queues and never
    # waits for a response or process cleanup.
    def poll : Snapshot
      if client = @client
        client.poll_events.each { |message| handle_event(message) }
        @pending.keys.each do |sequence|
          pending = @pending[sequence]?
          next unless pending
          result = client.poll_result(pending.not_nil!.ticket)
          handle_result(pending.not_nil!, result.not_nil!) if result
        end
        if client.failed? && !@state.lifecycle.in?(DebugSessionState::Lifecycle::Ended, DebugSessionState::Lifecycle::Failed)
          fail_session(client.failure_message || "debug adapter transport failed")
        end
        if @cleanup_pending && client.retired?
          @cleanup_pending = false
        end
      end
      if ticket = @pending_stop_ticket
        if deadline = @pending_stop_deadline
          if Time.monotonic >= deadline.not_nil!
            @state = @state.pause_unconfirmed(ticket.not_nil!)
            @pending_stop_ticket = nil
            @pending_stop_deadline = nil
            @execution_in_flight = false
            @stop_deadline = nil
            retire_inspection("pause was not followed by stop evidence")
          end
        end
      end
      maybe_dispatch_stop
      snapshot
    rescue ex
      fail_session(ex.message || "debugger poll failed")
      snapshot
    end

    def snapshot : Snapshot
      Snapshot.new(@state, @capabilities, @output_dropped, @cleanup_pending,
        @target_exit_code,
        @generation, @variable_generation, @source_generation, @breakpoint_generation,
        @variable_snapshot, @frames, @threads, breakpoint_views, @output,
        source_views, @watches.map(&.view), @last_error, build_availability)
    end

    def toggle_breakpoint(source_key : Debugging::DebugSourceKey, line : Int32,
                          column : Int32? = nil) : ActionSubmission
      return rejected("column breakpoints require source-backed UTF-16 conversion") if column
      return rejected("breakpoints require a reviewed project source") unless safe_source_key?(source_key)
      view = @breakpoint_store.toggle(source_key, line, column)
      @breakpoint_keys << source_key
      invalidate_breakpoint_views
      dispatch_breakpoint_batch(source_key) if configuring_or_active?
      accepted(view.id)
    rescue ex
      rejected(safe_error(ex.message || "breakpoint change was rejected"))
    end

    def set_breakpoint_enabled(source_key : Debugging::DebugSourceKey, breakpoint_id : String,
                               enabled : Bool) : ActionSubmission
      return rejected("breakpoints require a reviewed project source") unless safe_source_key?(source_key)
      return rejected("breakpoint was not found") unless @breakpoint_store.set_enabled(source_key, breakpoint_id, enabled)
      @breakpoint_keys << source_key
      invalidate_breakpoint_views
      dispatch_breakpoint_batch(source_key) if configuring_or_active?
      accepted(breakpoint_id)
    rescue ex
      rejected(safe_error(ex.message || "breakpoint change was rejected"))
    end

    def remove_breakpoint(source_key : Debugging::DebugSourceKey, breakpoint_id : String) : ActionSubmission
      return rejected("breakpoints require a reviewed project source") unless safe_source_key?(source_key)
      return rejected("breakpoint was not found") unless @breakpoint_store.remove(source_key, breakpoint_id)
      @breakpoint_keys << source_key
      invalidate_breakpoint_views
      dispatch_breakpoint_batch(source_key) if configuring_or_active?
      accepted(breakpoint_id)
    rescue ex
      rejected(safe_error(ex.message || "breakpoint change was rejected"))
    end

    # Editor integrations call this when shared document text changes. It
    # invalidates prior verification without reading the file or sending DAP
    # requests; explicit rebind remains the authority to submit a new set.
    def mark_source_edited(source_key : Debugging::DebugSourceKey,
                           reason : String = "source changed after debug capture") : Bool
      return false unless safe_source_key?(source_key)
      breakpoint_changed = @breakpoint_store.mark_source_edited(source_key, reason)
      source_changed = @source_store.try(&.mark_outdated(source_key, reason)) || false
      return false unless breakpoint_changed || source_changed

      @breakpoint_keys << source_key if breakpoint_changed
      invalidate_breakpoint_views if breakpoint_changed
      if source_changed
        if store = @source_store
          if source = store.not_nil!.fetch(source_key)
            display_path = @sources[source_key]?.try(&.display_path)
            retain_source_view(source.not_nil!, display_path)
          end
        end
      end
      touch_generation
      true
    rescue ex
      @last_error = safe_error(ex.message || "source edit could not invalidate debug evidence")
      touch_generation
      false
    end

    def select_thread(thread_id : Int64) : ActionSubmission
      return rejected("thread is not known") unless @state.tracked_thread_ids.includes?(thread_id)
      @state = @state.select_thread(thread_id)
      @frames.clear
      retire_inspection("thread selection changed")
      request_stack(thread_id) if stopped_thread?(thread_id)
      accepted(nil, next_request_id)
    end

    def select_frame(frame_id : Int64) : ActionSubmission
      frame = @frames.find { |item| item.id == frame_id }
      return rejected("frame is not in the current stack") unless frame
      @state = @state.select_frame(frame_id)
      @frames = @frames.map do |item|
        FrameView.new(item.id, item.name, item.dap_line, item.dap_column,
          item.editor_line, item.editor_column, item.source_reference, item.source_key,
          item.source_name, item.source_path, item.unavailable_reason, item.id == frame_id)
      end
      retire_inspection("frame selection changed")
      accepted(nil, next_request_id)
    end

    def continue(thread_id : Int64? = nil) : ActionSubmission
      submit_resume("continue", thread_id)
    end

    def step_over(thread_id : Int64? = nil) : ActionSubmission
      submit_resume("next", thread_id)
    end

    def step_into(thread_id : Int64? = nil) : ActionSubmission
      submit_resume("stepIn", thread_id)
    end

    def step_out(thread_id : Int64? = nil) : ActionSubmission
      submit_resume("stepOut", thread_id)
    end

    def pause(thread_id : Int64? = nil) : ActionSubmission
      client = @client
      return rejected("debug adapter is not available") unless client
      tid = thread_id || @state.selected_thread_id
      return rejected("no real target thread is selected") unless tid
      return rejected("another execution request is pending") if @execution_in_flight
      request_id = next_request_id
      new_state, ticket = @state.begin_pause(request_id, tid.not_nil!)
      return rejected("pause is unavailable in the current state") unless ticket
      @state = new_state
      @execution_in_flight = true
      args = json_object({"threadId" => JSON::Any.new(tid.not_nil!)})
      dap_ticket = client.request_execution("pause", args)
      @pending[dap_ticket.sequence] = PendingRequest.new(dap_ticket, PendingKind::Pause,
        pause_ticket: ticket, thread_id: tid, request_id: request_id)
      accepted(nil, request_id)
    rescue ex
      @state = @state.pause_failed(ticket.not_nil!) if ticket
      @execution_in_flight = false
      rejected(safe_error(ex.message || "pause request could not be sent"))
    end

    def open_scopes : ActionSubmission
      client = @client
      thread_id = @state.selected_thread_id
      frame_id = @state.selected_frame_id
      return rejected("debugger is not stopped on a selected frame") unless client && thread_id && frame_id
      request_id = next_request_id
      certificate = @state.certificate(request_id, DebugSessionState::RequestScope::Frame, thread_id)
      return rejected("selected frame is stale") unless @state.accepts?(certificate)
      args = json_object({"threadId" => JSON::Any.new(thread_id.not_nil!), "frameId" => JSON::Any.new(frame_id.not_nil!)})
      ticket = client.request("scopes", args)
      @pending[ticket.sequence] = PendingRequest.new(ticket, PendingKind::Scopes, certificate,
        thread_id: thread_id, frame_id: frame_id, request_id: request_id)
      accepted(nil, request_id)
    rescue ex
      rejected(safe_error(ex.message || "scope request could not be sent"))
    end

    def expand_variable(node_id : String) : ActionSubmission
      client = @client
      thread_id = @state.selected_thread_id
      return rejected("debugger is not stopped on a selected thread") unless client && thread_id
      node = @variable_snapshot.node(node_id)
      return rejected("variable is not expandable") unless node && node.not_nil!.expandable?
      page = @variable_tree.begin_children(node_id)
      return rejected("variable has no remaining bounded child page") unless page
      refresh_variables
      request_id = next_request_id
      certificate = @state.certificate(request_id, DebugSessionState::RequestScope::Frame, thread_id)
      unless @state.accepts?(certificate)
        @variable_tree.fail(page.not_nil!, "stopped frame changed before request")
        refresh_variables
        return rejected("selected frame is stale")
      end
      args = json_object({
        "variablesReference" => JSON::Any.new(page.not_nil!.variables_reference),
        "start"              => JSON::Any.new(page.not_nil!.start),
        "count"              => JSON::Any.new(page.not_nil!.count),
      })
      if filter = page.not_nil!.filter
        args.as_h["filter"] = JSON::Any.new(filter.not_nil!)
      end
      ticket = client.request("variables", args)
      @pending[ticket.sequence] = PendingRequest.new(ticket, PendingKind::Variables,
        certificate, thread_id: thread_id, frame_id: @state.selected_frame_id,
        page: page, request_id: request_id)
      accepted(nil, request_id)
    rescue ex
      @variable_tree.fail(page.not_nil!, safe_error(ex.message || "variables request could not be sent")) if page
      refresh_variables
      rejected(safe_error(ex.message || "variables request could not be sent"))
    end

    def add_watch(expression : String) : ActionSubmission
      text = expression.strip
      return rejected("watch expression is empty") if text.empty?
      return rejected("watch expression exceeds 128 UTF-8 bytes") if text.bytesize > 128 || !text.valid_encoding?
      return rejected("watch expression contains terminal controls") if text.each_char.any? { |char| char.ord < 0x20 || char.ord.in?(0x7f..0x9f) }
      return rejected("watch list is at its bounded limit") if @watches.size >= MAX_WATCHES
      id = Random::Secure.hex(12)
      @watches << WatchEntry.new(id, text.dup, safe_display(text, MAX_WATCH_BYTES))
      touch_generation
      accepted(id)
    end

    def evaluate_watch(watch_id : String) : ActionSubmission
      client = @client
      watch = @watches.find { |item| item.id == watch_id }
      return rejected("watch was not found") unless watch
      return rejected("watch evaluation is already pending") if watch.not_nil!.status == WatchStatus::Pending
      thread_id = @state.selected_thread_id
      frame_id = @state.selected_frame_id
      return rejected("evaluation requires a current stopped frame") unless client && thread_id && frame_id && stopped_thread?(thread_id.not_nil!)
      request_id = next_request_id
      certificate = @state.certificate(request_id, DebugSessionState::RequestScope::Frame, thread_id)
      return rejected("selected frame is stale") unless @state.accepts?(certificate)
      args = json_object({
        "expression" => JSON::Any.new(watch.not_nil!.expression),
        "frameId"    => JSON::Any.new(frame_id.not_nil!),
        "context"    => JSON::Any.new("watch"),
      })
      ticket = client.request("evaluate", args)
      watch.not_nil!.status = WatchStatus::Pending
      watch.not_nil!.result = nil
      watch.not_nil!.type = nil
      watch.not_nil!.reason = nil
      @pending[ticket.sequence] = PendingRequest.new(ticket, PendingKind::Watch, certificate,
        thread_id: thread_id, frame_id: frame_id, watch_id: watch_id, request_id: request_id)
      touch_generation
      accepted(nil, request_id)
    rescue ex
      reject_watch(watch.not_nil!, safe_error(ex.message || "watch could not be evaluated")) if watch
      rejected(safe_error(ex.message || "watch could not be evaluated"))
    end

    def open_source(source_key : Debugging::DebugSourceKey) : ActionSubmission
      if store = @source_store
        if source = store.fetch(source_key)
          retain_source_view(source.not_nil!, nil)
          return accepted(source_key.to_s)
        end
      end
      reference = source_key.source_reference
      return rejected("local source content is not retained; no file read was requested") unless reference && reference.not_nil! > 0 && source_key.session_id == @client.try(&.session_id)
      client = @client || return rejected("debug adapter is not available")
      request_id = next_request_id
      certificate = @state.certificate(request_id, DebugSessionState::RequestScope::Session)
      args = json_object({"source" => json_object({"sourceReference" => JSON::Any.new(reference.not_nil!)})})
      ticket = client.request("source", args)
      @pending[ticket.sequence] = PendingRequest.new(ticket, PendingKind::Source, certificate,
        source_key: source_key, request_id: request_id)
      accepted(source_key.to_s, request_id)
    rescue ex
      rejected(safe_error(ex.message || "source request could not be sent"))
    end

    def render_value(node_id : String,
                     format : Debugging::DebugValueFormat = Debugging::DebugValueFormat::Summary) : Debugging::DebugValueRender
      node = @variable_snapshot.node(node_id)
      return Debugging::DebugValueRender.new(Debugging::DebugValueAvailability::Unavailable,
        format, "Unavailable", "", false, "variable node is not retained") unless node
      retained = node.not_nil!
      case format
      when .hex?
        detail_state = @value_format_state
        if detail_state && detail_state.not_nil!.node_id == node_id &&
           detail_state.not_nil!.variable_generation == @variable_generation
          case detail_state.not_nil!.status
          when .pending?
            return unavailable_detail(format, "formatted value request is pending")
          when .unavailable?
            return unavailable_detail(format, detail_state.not_nil!.reason || "formatted value is unavailable")
          when .retired?
            return unavailable_detail(format, detail_state.not_nil!.reason || "variable data refreshed; request Hex again")
          when .available?
            return Debugging::DebugValueDetail.new(retained.value,
              supports_hex: true, hex_value: detail_state.not_nil!.value).render(format)
          end
        end
        reason = if @capabilities.value_formatting_options
                   "no adapter Hex value is retained for this variable; request Hex explicitly"
                 else
                   "adapter did not advertise value-formatting support"
                 end
        return unavailable_detail(format, reason)
      when .raw?
        # DAP defines Hex as an explicit VariablesArguments format, but has no
        # generic raw-value field. Never invent Raw bytes from the summary.
      else
        # Summary and local JSON interpretation are pure projections of the
        # exact bounded response value retained by the variable tree.
      end
      Debugging::DebugValueDetail.new(retained.value,
        json_source: retained.json_source,
        json_source_complete: retained.json_source != nil,
        summary_truncated: retained.value_truncated).render(format)
    end

    # Request an adapter-provided representation only after an explicit user
    # action. Rendering never causes DAP I/O. One in-flight formatted request
    # is allowed so cancelling a local view cannot accumulate stale requests.
    def request_value_format(node_id : String,
                             format : Debugging::DebugValueFormat = Debugging::DebugValueFormat::Hex) : ActionSubmission
      return rejected("only the standard DAP Hex representation is supported") unless format == Debugging::DebugValueFormat::Hex
      client = @client
      return rejected("debug adapter is not available") unless client
      return rejected("adapter did not advertise value-formatting support") unless @capabilities.value_formatting_options
      return rejected("a formatted-value request is still pending") if @value_format_pending_sequence
      thread_id = @state.selected_thread_id
      frame_id = @state.selected_frame_id
      return rejected("formatted values require a current stopped frame") unless thread_id && frame_id && stopped_thread?(thread_id.not_nil!)
      node = @variable_snapshot.node(node_id)
      return rejected("variable is no longer retained") unless node
      origin = node.not_nil!.origin
      return rejected("variable identity or originating page is unavailable") unless origin
      exact_origin = origin.not_nil!
      unless exact_origin.variables_reference > 0 && exact_origin.page_start >= 0 &&
             exact_origin.page_count.in?(1..@variable_tree.page_size) &&
             exact_origin.index >= exact_origin.page_start &&
             exact_origin.index < exact_origin.page_start + exact_origin.page_count
        return rejected("variable origin is outside its bounded DAP page")
      end
      request_id = next_request_id
      certificate = @state.certificate(request_id, DebugSessionState::RequestScope::Frame, thread_id)
      return rejected("selected frame is stale") unless @state.accepts?(certificate)

      generation = @value_format_generation + 1_u64
      @value_format_generation = generation
      @value_format_state = ValueFormatState.new(node_id, generation, @variable_generation,
        ValueFormatStatus::Pending, reason: "adapter Hex request is pending")
      arguments = {
        "variablesReference" => JSON::Any.new(exact_origin.variables_reference),
        "start"              => JSON::Any.new(exact_origin.page_start),
        "count"              => JSON::Any.new(exact_origin.page_count),
        "format"             => json_object({"hex" => JSON::Any.new(true)}),
      } of String => JSON::Any
      if filter = exact_origin.filter
        arguments["filter"] = JSON::Any.new(filter.not_nil!)
      end
      ticket = send_request("variables", json_object(arguments), PendingKind::ValueFormat,
        certificate: certificate, thread_id: thread_id, frame_id: frame_id,
        format_node_id: node_id, format_origin: exact_origin,
        format_generation: generation, format_variable_generation: @variable_generation,
        request_id: request_id)
      @value_format_pending_sequence = ticket.sequence
      touch_generation
      accepted(node_id, request_id)
    rescue ex
      fail_value_format(nil, safe_error(ex.message || "formatted value request could not be sent")) if @value_format_state
      rejected(safe_error(ex.message || "formatted value request could not be sent"))
    end

    # Retires only the local formatted view. DAP has no generic cancellation
    # for variables requests, so the bounded in-flight ticket remains owned
    # until its response is consumed and is then discarded by its certificate.
    def cancel_value_format(node_id : String? = nil) : Nil
      current = @value_format_state
      return unless current
      return if node_id && current.not_nil!.node_id != node_id.not_nil!
      retire_value_format
      touch_generation
    end

    private def unavailable_detail(format : Debugging::DebugValueFormat, reason : String) : Debugging::DebugValueRender
      Debugging::DebugValueRender.new(Debugging::DebugValueAvailability::Unavailable,
        format, "Unavailable", "", false, safe_display(reason, 256))
    end

    private def accept_value_format(pending : PendingRequest, body : JSON::Any?) : Nil
      current = current_value_format_request?(pending)
      @value_format_pending_sequence = nil if @value_format_pending_sequence == pending.ticket.sequence
      return unless current
      origin = pending.format_origin || return
      page = field(body, "variables").try(&.as_a?) || [] of JSON::Any
      relative_index = origin.not_nil!.index - origin.not_nil!.page_start
      if page.not_nil!.size > origin.not_nil!.page_count || relative_index < 0 || relative_index >= page.not_nil!.size
        fail_value_format(pending, "adapter formatted page did not contain the requested child", check_current: false)
        return
      end
      child = page.not_nil![relative_index]
      unless formatted_child_matches?(child, origin.not_nil!)
        fail_value_format(pending, "adapter formatted page returned a different child at the requested offset", check_current: false)
        return
      end
      value = string_field(child, "value")
      unless value && value.not_nil!.valid_encoding? && value.not_nil!.bytesize <= Debugging::DebugValueDetail::MAX_BYTES
        fail_value_format(pending, "adapter formatted value is missing or exceeds the local byte limit", check_current: false)
        return
      end
      generation = pending.format_generation || return
      variable_generation = pending.format_variable_generation || return
      @value_format_state = ValueFormatState.new(pending.format_node_id.not_nil!, generation.not_nil!,
        variable_generation.not_nil!, ValueFormatStatus::Available, value: value.not_nil!)
      touch_generation
    end

    private def formatted_child_matches?(child : JSON::Any,
                                         origin : Debugging::DebugVariableOrigin) : Bool
      name = string_field(child, "name")
      return false unless name && name.not_nil! == origin.name
      return false unless optional_string_field_matches?(child, "type", origin.type)
      return false unless optional_string_field_matches?(child, "evaluateName", origin.evaluate_name)
      return false unless int32(field(child, "variablesReference")) == origin.child_variables_reference
      return false unless optional_int_field_matches?(child, "namedVariables", origin.named_variables)
      return false unless optional_int_field_matches?(child, "indexedVariables", origin.indexed_variables)
      true
    end

    private def optional_string_field_matches?(object : JSON::Any, key : String,
                                               expected : String?) : Bool
      raw = field(object, key)
      return raw.nil? if expected.nil?
      value = raw.try(&.as_s?)
      !!(value && value.not_nil! == expected.not_nil!)
    end

    private def optional_int_field_matches?(object : JSON::Any, key : String,
                                            expected : Int32?) : Bool
      raw = field(object, key)
      return raw.nil? if expected.nil?
      value = int32(raw)
      !!(value && value.not_nil! == expected.not_nil!)
    end

    private def current_value_format_request?(pending : PendingRequest) : Bool
      return false unless pending.kind.value_format?
      return false unless @value_format_pending_sequence == pending.ticket.sequence
      return false unless pending.format_generation == @value_format_generation
      return false unless pending.format_variable_generation == @variable_generation
      state = @value_format_state
      return false unless state && state.not_nil!.status == ValueFormatStatus::Pending &&
                          state.not_nil!.generation == pending.format_generation &&
                          state.not_nil!.variable_generation == pending.format_variable_generation &&
                          state.not_nil!.node_id == pending.format_node_id
      certificate = pending.certificate
      return false unless certificate && @state.accepts?(certificate.not_nil!)
      node = @variable_snapshot.node(pending.format_node_id.not_nil!)
      return false unless node && origin_matches?(node.not_nil!.origin, pending.format_origin)
      true
    end

    private def origin_matches?(current : Debugging::DebugVariableOrigin?, expected : Debugging::DebugVariableOrigin?) : Bool
      return false unless current && expected
      left = current.not_nil!
      right = expected.not_nil!
      left.variables_reference == right.variables_reference && left.page_start == right.page_start &&
        left.page_count == right.page_count && left.index == right.index && left.name == right.name &&
        left.type == right.type && left.evaluate_name == right.evaluate_name &&
        left.filter == right.filter && left.child_variables_reference == right.child_variables_reference &&
        left.named_variables == right.named_variables && left.indexed_variables == right.indexed_variables
    end

    private def fail_value_format(pending : PendingRequest?, reason : String,
                                  check_current : Bool = true) : Nil
      if pending
        return if check_current && !current_value_format_request?(pending.not_nil!)
        generation = pending.not_nil!.format_generation || return
        variable_generation = pending.not_nil!.format_variable_generation || return
        node_id = pending.not_nil!.format_node_id || return
        @value_format_state = ValueFormatState.new(node_id.not_nil!, generation.not_nil!,
          variable_generation.not_nil!, ValueFormatStatus::Unavailable, reason: safe_display(reason, 256))
      elsif state = @value_format_state
        @value_format_state = ValueFormatState.new(state.not_nil!.node_id, state.not_nil!.generation,
          state.not_nil!.variable_generation, ValueFormatStatus::Unavailable, reason: safe_display(reason, 256))
      end
      touch_generation
    end

    private def retire_value_format : Nil
      @value_format_generation += 1_u64
      @value_format_state = nil
    end

    def stop : ActionSubmission
      return rejected("no debugger session is active") unless @client
      return accepted("stop already requested") if @stop_requested
      @stop_requested = true
      @state = @state.begin_disconnect
      retire_inspection("debugger stopping")
      @stop_deadline = Time.monotonic + 2.seconds if @execution_in_flight
      maybe_dispatch_stop
      accepted("stop requested", next_request_id)
    end

    def close : Nil
      begin_async_close
    end

    def cleanup_pending? : Bool
      @cleanup_pending
    end

    private def within_project?(path : Path, root : Path) : Bool
      return false unless path.absolute? && root.absolute?
      return false unless File.file?(path.to_s) && File.directory?(root.to_s)
      candidate = Path.new(File.realpath(path.to_s)).to_s
      canonical_root = Path.new(File.realpath(root.to_s)).to_s
      candidate.starts_with?(canonical_root.ends_with?("/") ? canonical_root : "#{canonical_root}/")
    rescue
      false
    end

    private def restartable? : Bool
      return false if @cleanup_pending
      return true unless @client
      client = @client.not_nil!
      client.retired? && @state.lifecycle.in?(DebugSessionState::Lifecycle::Ended, DebugSessionState::Lifecycle::Failed)
    end

    private def safe_source_key?(key : Debugging::DebugSourceKey) : Bool
      case key.kind
      when Debugging::SourceKeyKind::Local
        root = @bound_project_root
        path = key.local_path
        !!(root && path && within_project?(Path.new(path.not_nil!), root.not_nil!))
      when Debugging::SourceKeyKind::SessionReference
        key.session_id == @client.try(&.session_id)
      else
        false
      end
    end

    private def configuring_or_active? : Bool
      @state.lifecycle.in?(DebugSessionState::Lifecycle::Starting,
        DebugSessionState::Lifecycle::Configuring, DebugSessionState::Lifecycle::Active)
    end

    private def accepted(id : String? = nil, request_id : UInt64? = nil) : ActionSubmission
      ActionSubmission.new(true, id, request_id)
    end

    private def rejected(reason : String) : ActionSubmission
      ActionSubmission.new(false, safe_display(reason, 512))
    end

    private def reject_watch(watch : WatchEntry, reason : String) : ActionSubmission
      watch.status = WatchStatus::Unavailable
      watch.result = nil
      watch.type = nil
      watch.reason = safe_display(reason, 512)
      rejected(reason)
    end

    private def safe_error(message : String) : String
      safe_display(message, 512)
    end

    private def safe_display(value : String, max_bytes : Int32) : String
      return "" if max_bytes <= 0
      source = value.valid_encoding? ? value : "[invalid UTF-8]"
      output = String::Builder.new
      used = 0
      source.each_char do |char|
        code = char.ord
        rendered = if code == 0x1b
                     "\\x1B"
                   elsif code < 0x20 || code == 0x7f || code.in?(0x80..0x9f)
                     " "
                   else
                     char.to_s
                   end
        break if used + rendered.bytesize > max_bytes
        output << rendered
        used += rendered.bytesize
      end
      output.to_s
    end

    private def json_object(fields : Hash(String, JSON::Any)) : JSON::Any
      JSON::Any.new(fields)
    end

    private def json_array(values : Array(JSON::Any)) : JSON::Any
      JSON::Any.new(values)
    end

    private def field(value : JSON::Any?, key : String) : JSON::Any?
      return nil unless value
      object = value.not_nil!.as_h?
      object.try { |fields| fields[key]? }
    end

    private def string_field(value : JSON::Any?, key : String) : String?
      field(value, key).try(&.as_s?)
    end

    private def int_field(value : JSON::Any?, key : String) : Int64?
      field(value, key).try(&.as_i64?)
    end

    private def bool_field(value : JSON::Any?, key : String) : Bool?
      field(value, key).try(&.as_bool?)
    end

    private def int32(value : JSON::Any?) : Int32?
      integer = value.try(&.as_i64?)
      return nil unless integer && integer.not_nil! >= Int32::MIN && integer.not_nil! <= Int32::MAX
      integer.not_nil!.to_i32
    end

    private def next_request_id : UInt64
      @next_local_request_id += 1_u64
      @next_local_request_id
    end

    private def send_request(command : String, arguments : JSON::Any, kind : PendingKind,
                             *, certificate : DebugSessionState::RequestCertificate? = nil,
                             batch : Debugging::DebugBreakpointBatch? = nil,
                             page : Debugging::DebugVariablePage? = nil,
                             watch_id : String? = nil,
                             source_key : Debugging::DebugSourceKey? = nil,
                             thread_id : Int64? = nil, frame_id : Int64? = nil,
                             execution : Bool = false,
                             resume_ticket : DebugSessionState::ResumeTicket? = nil,
                             pause_ticket : DebugSessionState::PauseTicket? = nil,
                             format_node_id : String? = nil,
                             format_origin : Debugging::DebugVariableOrigin? = nil,
                             format_generation : UInt64? = nil,
                             format_variable_generation : UInt64? = nil,
                             request_id : UInt64 = 0_u64) : Dap::Ticket
      client = @client || raise Dap::ClientError.new("debug adapter is not available")
      ticket = execution ? client.request_execution(command, arguments) : client.request(command, arguments)
      @pending[ticket.sequence] = PendingRequest.new(ticket, kind, certificate,
        resume_ticket: resume_ticket, pause_ticket: pause_ticket,
        thread_id: thread_id, frame_id: frame_id, page: page, batch: batch,
        source_key: source_key, watch_id: watch_id, request_id: request_id,
        format_node_id: format_node_id, format_origin: format_origin,
        format_generation: format_generation,
        format_variable_generation: format_variable_generation)
      ticket
    end

    private def handle_event(message : Dap::Message) : Nil
      return unless message.kind == "event"
      stamp = @state.session_stamp
      return unless stamp
      body = message.body
      case message.event
      when "initialized"
        @initialized_seen = true
        @state = @state.configuring
        configure_after_initialized
      when "process"
        @state = @state.process_started(stamp.not_nil!)
      when "stopped"
        thread_id = int_field(body, "threadId")
        reason = string_field(body, "reason") || "stopped"
        all_stopped = bool_field(body, "allThreadsStopped")
        @state = @state.stopped(stamp.not_nil!, thread_id, all_stopped)
        @execution_in_flight = false
        @pending_stop_ticket = nil
        @pending_stop_deadline = nil
        @stop_deadline = nil
        retire_inspection("target stop changed")
        @frames.clear
        @generation += 1_u64
        if thread_id && thread_id.not_nil! > 0
          tid = thread_id.not_nil!
          @state = @state.thread_seen(stamp.not_nil!, tid)
          @state = @state.select_thread(tid)
          request_stack(tid)
        else
          request_threads
        end
        @last_error = nil if reason == "breakpoint" || reason == "step" || reason == "pause"
      when "continued"
        thread_id = int_field(body, "threadId")
        @state = @state.continued(stamp.not_nil!, thread_id, bool_field(body, "allThreadsContinued"))
        @execution_in_flight = false
        @pending_stop_ticket = nil
        @pending_stop_deadline = nil
        @stop_deadline = nil
        retire_inspection("target continued")
        @generation += 1_u64
      when "thread"
        thread_id = int_field(body, "threadId")
        if thread_id && thread_id.not_nil! > 0
          if string_field(body, "reason") == "exited"
            exited_id = thread_id.not_nil!
            @state = @state.thread_exited(stamp.not_nil!, exited_id)
            @threads.reject! { |thread| thread.id == exited_id }
            @frames.clear
            if @pending_stop_ticket.try(&.thread_id) == exited_id
              @execution_in_flight = false
              @pending_stop_ticket = nil
              @pending_stop_deadline = nil
            end
            retire_inspection("thread exited")
          else
            @state = @state.thread_seen(stamp.not_nil!, thread_id.not_nil!)
          end
        end
      when "exited"
        @state = @state.exited(stamp.not_nil!)
        @target_exit_code = int32(field(body, "exitCode"))
        @execution_in_flight = false
        @pending_stop_ticket = nil
        @pending_stop_deadline = nil
        @stop_deadline = nil
        retire_inspection("target exited")
        @generation += 1_u64
      when "terminated"
        @state = @state.terminated(stamp.not_nil!)
        @execution_in_flight = false
        @pending_stop_ticket = nil
        @pending_stop_deadline = nil
        @stop_deadline = nil
        retire_inspection("debug adapter terminated the session")
        begin_async_close
        @generation += 1_u64
      when "invalidated"
        raw_areas = field(body, "areas").try(&.as_a?)
        areas = raw_areas ? raw_areas.not_nil!.compact_map(&.as_s?) : nil
        @state = @state.invalidated(stamp.not_nil!, areas)
        retire_inspection("adapter invalidated inspection handles")
      when "output"
        category = string_field(body, "category") || "console"
        text = string_field(body, "output") || ""
        append_output(category, text)
      when "breakpoint"
        reconcile_breakpoint_event(body)
      else
        # Unknown events do not establish lifecycle or target evidence.
      end
      refresh_thread_views
      touch_generation
    rescue ex
      fail_session(ex.message || "debugger event was invalid")
    end

    private def handle_result(pending : PendingRequest, result : Dap::RequestResult) : Nil
      @pending.delete(pending.ticket.sequence)
      unless result.success?
        handle_failed_result(pending, result)
        return
      end
      body = result.body
      case pending.kind
      when .initialize?
        @init_body = body
        parse_capabilities(body)
        configure_after_initialized if @initialized_seen
        launch_target unless @launch_sent
      when .launch?
        @launch_succeeded = true
        activate_if_ready
      when .exception_breakpoints?
        @exception_config_succeeded = true
        @config_requests = Math.max(0, @config_requests - 1)
        send_configuration_done_if_ready
      when .configuration_done?
        @config_done_succeeded = true
        @config_requests = Math.max(0, @config_requests - 1)
        activate_if_ready
      when .set_breakpoints?
        complete_breakpoint_batch(pending, body)
        @config_requests = Math.max(0, @config_requests - 1) if @state.lifecycle.in?(DebugSessionState::Lifecycle::Starting, DebugSessionState::Lifecycle::Configuring)
        send_configuration_done_if_ready
      when .threads?
        accept_threads(pending, body)
      when .stack_trace?
        accept_stack(pending, body)
      when .scopes?
        accept_scopes(pending, body)
      when .variables?
        accept_variables(pending, body)
      when .value_format?
        accept_value_format(pending, body)
      when .resume?
        if ticket = pending.resume_ticket
          @state = @state.resume_succeeded(ticket, bool_field(body, "allThreadsContinued"))
        end
        @execution_in_flight = false
        @generation += 1_u64
        maybe_dispatch_stop
      when .pause?
        if ticket = pending.pause_ticket
          @state = @state.pause_succeeded(ticket)
          if @execution_in_flight
            @pending_stop_ticket = ticket
            @pending_stop_deadline = Time.monotonic + 2.seconds
          end
        end
      when .watch?
        accept_watch(pending, body)
      when .source?
        accept_source(pending, body)
      when .disconnect?
        # A successful disconnect ends this debugger session even if the
        # adapter closes its output immediately after the response. Do not
        # infer target exit from disconnect; `terminated` preserves Exited
        # only when an actual `exited` event was observed earlier.
        if stamp = @state.session_stamp
          @state = @state.terminated(stamp.not_nil!)
        end
        begin_async_close
      end
      touch_generation
    rescue ex
      fail_session(ex.message || "debug adapter response was invalid")
    end

    private def handle_failed_result(pending : PendingRequest, result : Dap::RequestResult) : Nil
      message = safe_error(result.message || "debug adapter rejected #{pending.ticket.sequence}")
      if pending.kind.watch?
        certificate = pending.certificate
        return unless certificate && @state.accepts?(certificate.not_nil!)
      end
      if pending.kind.value_format?
        current = current_value_format_request?(pending)
        fail_value_format(pending, message, check_current: false) if current
        @value_format_pending_sequence = nil if @value_format_pending_sequence == pending.ticket.sequence
        return
      end
      @last_error = message
      case pending.kind
      when .initialize?, .launch?
        fail_session(message)
      when .resume?
        @state = @state.resume_failed(pending.resume_ticket.not_nil!) if pending.resume_ticket
        @execution_in_flight = false
        maybe_dispatch_stop
      when .pause?
        @state = @state.pause_failed(pending.pause_ticket.not_nil!) if pending.pause_ticket
        @execution_in_flight = false
      when .set_breakpoints?
        if batch = pending.batch
          completion = @breakpoint_store.complete(batch.not_nil!, [] of Debugging::DebugBreakpointResolution,
            success: false, reason: message)
          if completion.applied?
            @breakpoint_generation += 1_u64
            @cached_breakpoint_views = nil
          end
        end
        @config_requests = Math.max(0, @config_requests - 1)
        send_configuration_done_if_ready
      when .exception_breakpoints?
        @exception_config_succeeded = false
        @config_requests = Math.max(0, @config_requests - 1)
        fail_session(message)
      when .configuration_done?
        fail_session(message)
      when .watch?
        # A failed response can be just as stale as a successful value. In
        # particular, an older evaluation for this watch must not clear a
        # newer Pending evaluation after the inspected frame changed.
        if watch_id = pending.watch_id
          if watch = @watches.find { |entry| entry.id == watch_id.not_nil! }
            reject_watch(watch.not_nil!, message)
          end
        end
      when .variables?
        if page = pending.page
          @variable_tree.fail(page.not_nil!, message)
          refresh_variables
        end
      when .disconnect?
        fail_session(message)
      else
        # Read-only inspection failures remain local to that request.
      end
      touch_generation
    end

    private def parse_capabilities(body : JSON::Any?) : Nil
      capabilities = field(body, "capabilities") || body
      @config_done_supported = bool_field(capabilities, "supportsConfigurationDoneRequest") == true
      @capabilities = Capabilities.new(
        @config_done_supported,
        bool_field(capabilities, "supportsSingleThreadExecutionRequests") == true,
        bool_field(capabilities, "supportsTerminateRequest") == true,
        bool_field(capabilities, "supportTerminateDebuggee") == true,
        bool_field(capabilities, "supportsValueFormattingOptions") == true
      )
    end

    private def launch_target : Nil
      return if @launch_sent
      client = @client || return
      profile = @profile || return
      @launch_sent = true
      args = json_object({
        "program" => JSON::Any.new(profile.program),
        "args"    => json_array(profile.target_argv.map { |arg| JSON::Any.new(arg) }),
        "cwd"     => JSON::Any.new(profile.cwd),
      })
      ticket = client.request("launch", args)
      @launch_ticket = ticket
      @pending[ticket.sequence] = PendingRequest.new(ticket, PendingKind::Launch)
      configure_after_initialized if @initialized_seen
    end

    private def configure_after_initialized : Nil
      return unless @initialized_seen && @init_body
      return unless @launch_sent
      return if @config_setup_dispatched
      client = @client || return
      @config_setup_dispatched = true
      @state = @state.configuring
      filters = [] of JSON::Any
      raw_filters = field(@init_body, "exceptionBreakpointFilters").try(&.as_a?)
      if raw_filters
        raw_filters.not_nil!.each do |filter|
          next unless bool_field(filter, "default") == true
          name = string_field(filter, "filter")
          filters << JSON::Any.new(name.not_nil!) if name && !name.not_nil!.empty?
        end
      end
      @config_requests += 1
      send_request("setExceptionBreakpoints", json_object({"filters" => json_array(filters)}), PendingKind::ExceptionBreakpoints)
      @breakpoint_keys.each { |key| dispatch_breakpoint_batch(key) }
      send_configuration_done_if_ready
    end

    private def send_configuration_done_if_ready : Nil
      return unless @config_setup_dispatched
      return unless @exception_config_succeeded
      return unless @config_requests == 0
      return if @config_done_sent || @config_done_succeeded
      if @config_done_supported
        @config_done_sent = true
        @config_requests += 1
        send_request("configurationDone", json_object({} of String => JSON::Any), PendingKind::ConfigurationDone)
      else
        @config_done_succeeded = true
      end
      activate_if_ready
    end

    private def activate_if_ready : Nil
      return unless @launch_succeeded && @initialized_seen
      return unless @exception_config_succeeded && @config_done_succeeded && @config_requests == 0
      was_active = @state.lifecycle == DebugSessionState::Lifecycle::Active
      @state = @state.activate
      unless was_active
        @generation += 1_u64
        if thread_id = @state.selected_thread_id
          request_stack(thread_id.not_nil!) if stopped_thread?(thread_id.not_nil!)
        else
          request_threads
        end
      end
    end

    private def dispatch_breakpoint_batch(key : Debugging::DebugSourceKey) : Nil
      configuration_request_counted = false
      return unless configuring_or_active? && safe_source_key?(key)
      batch = @breakpoint_store.begin_batch(key)
      return unless batch
      source_fields = {} of String => JSON::Any
      if path = key.local_path
        source_fields["path"] = JSON::Any.new(path.not_nil!)
      elsif reference = key.source_reference
        source_fields["sourceReference"] = JSON::Any.new(reference.not_nil!)
      else
        return
      end
      requested = batch.not_nil!.breakpoints.map do |entry|
        fields = {"line" => JSON::Any.new(entry.requested_line + 1)} of String => JSON::Any
        if column = entry.requested_column
          fields["column"] = JSON::Any.new(column.not_nil! + 1)
        end
        JSON::Any.new(fields)
      end
      args = json_object({"source" => json_object(source_fields), "breakpoints" => json_array(requested)})
      if @state.lifecycle.in?(DebugSessionState::Lifecycle::Starting, DebugSessionState::Lifecycle::Configuring)
        @config_requests += 1
        configuration_request_counted = true
      end
      send_request("setBreakpoints", args, PendingKind::SetBreakpoints, batch: batch)
    rescue ex
      if batch
        @breakpoint_store.complete(batch.not_nil!, [] of Debugging::DebugBreakpointResolution,
          success: false, reason: safe_error(ex.message || "breakpoint request could not be sent"))
      end
      @last_error = safe_error(ex.message || "breakpoint request could not be sent")
      if configuration_request_counted
        @config_requests = Math.max(0, @config_requests - 1)
        send_configuration_done_if_ready
      end
    end

    private def complete_breakpoint_batch(pending : PendingRequest, body : JSON::Any?) : Nil
      batch = pending.batch || return
      raw = field(body, "breakpoints").try(&.as_a?) || [] of JSON::Any
      resolutions = [] of Debugging::DebugBreakpointResolution
      entries = batch.not_nil!.breakpoints
      raw.not_nil!.each_with_index do |item, index|
        entry = entries[index]?
        next unless entry
        line = int_field(item, "line")
        column = int_field(item, "column")
        id = int_field(item, "id")
        adapter_id = id ? id.not_nil!.to_s : nil
        resolutions << Debugging::DebugBreakpointResolution.new(
          entry.not_nil!.id, adapter_id,
          line && line.not_nil! > 0 ? line.not_nil!.to_i32 - 1 : nil,
          nil,
          bool_field(item, "verified") == true,
          string_field(item, "message")
        )
      end
      completion = @breakpoint_store.complete(batch.not_nil!, resolutions)
      if completion.applied?
        @applied_breakpoint_generations[batch.not_nil!.source_key] = batch.not_nil!.generation
        @breakpoint_generation += 1_u64
        @cached_breakpoint_views = nil
      elsif completion.accepted? && completion.reason == "desired breakpoint generation changed while request was in flight"
        # Mutations coalesce in the store while a full-set request is in flight.
        # Once that response releases the store token, send the newest full set.
        dispatch_breakpoint_batch(batch.not_nil!.source_key)
      end
    end

    private def request_threads : Nil
      client = @client || return
      request_id = next_request_id
      certificate = @state.certificate(request_id, DebugSessionState::RequestScope::Stop)
      return unless @state.accepts?(certificate)
      send_request("threads", json_object({} of String => JSON::Any), PendingKind::Threads,
        certificate: certificate, request_id: request_id)
    rescue ex
      @last_error = safe_error(ex.message || "threads request could not be sent")
    end

    private def accept_threads(pending : PendingRequest, body : JSON::Any?) : Nil
      certificate = pending.certificate || return
      return unless @state.accepts?(certificate.not_nil!)
      stamp = @state.session_stamp || return
      raw_threads = field(body, "threads").try(&.as_a?) || [] of JSON::Any
      ids = [] of Int64
      rows = [] of ThreadView
      raw_threads.not_nil!.first(DebugSessionState::MAX_TRACKED_THREADS).each do |item|
        id = int_field(item, "id")
        next unless id && id.not_nil! > 0
        name = safe_display(string_field(item, "name") || "Thread #{id}", 256)
        ids << id.not_nil!
        @state = @state.thread_seen(stamp.not_nil!, id.not_nil!)
        execution = @state.thread_execution(id.not_nil!) || DebugSessionState::ThreadExecution::Unknown
        rows << ThreadView.new(id.not_nil!, execution, name)
      end
      @state = @state.threads_listed(stamp.not_nil!, ids, certificate.not_nil!)
      rows = ids.map do |id|
        ThreadView.new(id, @state.thread_execution(id) || DebugSessionState::ThreadExecution::Unknown,
          rows.find { |row| row.id == id }.try(&.name) || "Thread #{id}")
      end
      @threads = rows
      if @state.selected_thread_id.nil? && ids.size == 1
        @state = @state.select_thread(ids.first)
        request_stack(ids.first)
      end
      touch_generation
    end

    private def refresh_thread_views : Nil
      previous = @threads
      @threads = @state.tracked_thread_ids.first(DebugSessionState::MAX_TRACKED_THREADS).map do |thread_id|
        name = previous.find { |thread| thread.id == thread_id }.try(&.name) || "Thread #{thread_id}"
        execution = @state.thread_execution(thread_id) || DebugSessionState::ThreadExecution::Unknown
        ThreadView.new(thread_id, execution, name)
      end
    end

    private def request_stack(thread_id : Int64) : Nil
      return unless stopped_thread?(thread_id)
      client = @client || return
      request_id = next_request_id
      certificate = @state.certificate(request_id, DebugSessionState::RequestScope::Thread, thread_id)
      return unless @state.accepts?(certificate)
      args = json_object({
        "threadId"   => JSON::Any.new(thread_id),
        "startFrame" => JSON::Any.new(0),
        "levels"     => JSON::Any.new(64),
      })
      send_request("stackTrace", args, PendingKind::StackTrace, certificate: certificate,
        thread_id: thread_id, request_id: request_id)
    rescue ex
      @last_error = safe_error(ex.message || "stack request could not be sent")
    end

    private def accept_stack(pending : PendingRequest, body : JSON::Any?) : Nil
      certificate = pending.certificate || return
      return unless @state.accepts?(certificate.not_nil!)
      resolver = @resolver || return
      raw_frames = field(body, "stackFrames").try(&.as_a?) || [] of JSON::Any
      rows = [] of FrameView
      raw_frames.not_nil!.first(64).each do |item|
        frame_id = int_field(item, "id")
        next unless frame_id && frame_id.not_nil! >= 0
        name = safe_display(string_field(item, "name") || "<unnamed frame>", 256)
        dap_line = int_field(item, "line")
        dap_column = int_field(item, "column")
        source = field(item, "source")
        adapter_path = string_field(source, "path")
        source_name = string_field(source, "name")
        source_reference = int32(field(source, "sourceReference"))
        resolution = resolver.resolve(adapter_path: adapter_path, source_reference: source_reference)
        source_key = resolution.source_key
        editor_line = nil.as(Int32?)
        editor_column = nil.as(Int32?)
        reason = resolution.reason
        if key = source_key
          @source_resolutions[key.not_nil!] = resolution
          if key.not_nil!.kind == Debugging::SourceKeyKind::Local
            if store = @source_store
              if retained = store.not_nil!.fetch(key.not_nil!)
                snapshot = retained.not_nil!
                if checksum = stack_source_checksum(source)
                  snapshot = store.not_nil!.certify_baseline_checksum(key.not_nil!, checksum) || snapshot
                end
                retain_source_view(snapshot, resolution.display_path) if snapshot.origin == Debugging::SourceOrigin::LaunchBaseline
              end
            end
          end
          if line = dap_line
            if column = dap_column
              if retained = @source_store.try(&.fetch(key.not_nil!))
                begin
                  position = resolver.to_editor_position(retained.not_nil!, line.not_nil!.to_i32, column.not_nil!.to_i32)
                  editor_line = position.line
                  editor_column = position.column
                rescue
                  reason = "frame position is not mappable within retained source"
                end
              else
                editor_line = line.not_nil!.to_i32 - 1 if line.not_nil! > 0
                reason ||= "frame column is unmapped without retained source text"
              end
            end
          end
        end
        rows << FrameView.new(frame_id.not_nil!, name,
          dap_line.try(&.to_i32), dap_column.try(&.to_i32), editor_line, editor_column,
          source_reference, source_key, source_name.try { |value| safe_display(value, 256) },
          resolution.display_path, reason)
      end
      @frames = rows
      if first = rows.first?
        @state = @state.select_frame(first.id)
        @frames = rows.map do |item|
          FrameView.new(item.id, item.name, item.dap_line, item.dap_column,
            item.editor_line, item.editor_column, item.source_reference, item.source_key,
            item.source_name, item.source_path, item.unavailable_reason, item.id == first.id)
        end
      end
      @generation += 1_u64
      touch_generation
    end

    # Only a bounded SHA256 entry is actionable. Unknown algorithms, malformed
    # arrays, duplicate SHA256 entries, and oversized values remain unverified.
    private def stack_source_checksum(source : JSON::Any?) : Debugging::DebugChecksum?
      raw_checksums = field(source, "checksums")
      return nil unless raw_checksums
      checksums = raw_checksums.not_nil!.as_a?
      return nil unless checksums
      entries = checksums.not_nil!
      return nil if entries.size > 8

      sha256_entries = entries.select { |item| string_field(item, "algorithm") == "SHA256" }
      return nil if sha256_entries.size != 1
      entry = sha256_entries.first
      value = string_field(entry, "checksum")
      return nil unless value && value.not_nil!.bytesize <= 256
      Debugging::DebugChecksum.new("SHA256", value.not_nil!)
    rescue
      nil
    end

    private def accept_scopes(pending : PendingRequest, body : JSON::Any?) : Nil
      certificate = pending.certificate || return
      return unless @state.accepts?(certificate.not_nil!)
      inputs = [] of Debugging::DebugScopeInput
      raw_scopes = field(body, "scopes").try(&.as_a?) || [] of JSON::Any
      # Retain one bounded witness past the visible cap so the tree can expose
      # that scope output was clipped without materializing an unbounded list.
      raw_scopes.not_nil!.first(MAX_SCOPES + 1).each do |item|
        reference = int_field(item, "variablesReference") || 0_i64
        next unless reference >= 0 && reference <= Int32::MAX
        inputs << Debugging::DebugScopeInput.new(
          name: safe_display(string_field(item, "name") || "Scope", 128),
          variables_reference: reference.to_i32,
          named_variables: int_field(item, "namedVariables").try(&.to_i32),
          indexed_variables: int_field(item, "indexedVariables").try(&.to_i32)
        )
      end
      @variable_snapshot = @variable_tree.replace_scopes(inputs)
      @variable_generation += 1_u64
      roots = @variable_snapshot.roots
      roots.first(128).each do |root|
        next unless root.expandable?
        page = @variable_tree.begin_children(root.id)
        request_variable_page(page.not_nil!, pending) if page
      end
      touch_generation
    end

    private def request_variable_page(page : Debugging::DebugVariablePage,
                                      parent : PendingRequest? = nil) : Nil
      thread_id = parent.try(&.thread_id) || @state.selected_thread_id
      frame_id = parent.try(&.frame_id) || @state.selected_frame_id
      return unless thread_id && frame_id
      request_id = next_request_id
      certificate = @state.certificate(request_id, DebugSessionState::RequestScope::Frame, thread_id)
      unless @state.accepts?(certificate)
        @variable_tree.fail(page, "stopped frame changed before request")
        refresh_variables
        return
      end
      args = json_object({
        "variablesReference" => JSON::Any.new(page.variables_reference),
        "start"              => JSON::Any.new(page.start),
        "count"              => JSON::Any.new(page.count),
      })
      if filter = page.filter
        args.as_h["filter"] = JSON::Any.new(filter.not_nil!)
      end
      send_request("variables", args, PendingKind::Variables, certificate: certificate,
        page: page, thread_id: thread_id, frame_id: frame_id, request_id: request_id)
    rescue ex
      @variable_tree.fail(page, safe_error(ex.message || "variables request could not be sent"))
      refresh_variables
    end

    private def accept_variables(pending : PendingRequest, body : JSON::Any?) : Nil
      page = pending.page || return
      certificate = pending.certificate || return
      unless @state.accepts?(certificate.not_nil!)
        @variable_tree.fail(page.not_nil!, "stopped frame changed before response")
        refresh_variables
        return
      end
      raw_variables = field(body, "variables").try(&.as_a?) || [] of JSON::Any
      variables = [] of Debugging::DebugVariableInput
      # One overflow witness lets the tree mark an adapter that ignored the
      # requested page size, while all retained mapping stays page-bounded.
      raw_variables.not_nil!.first(page.not_nil!.count + 1).each do |item|
        reference = int_field(item, "variablesReference") || 0_i64
        reference = 0_i64 unless reference.in?(0_i64..Int32::MAX.to_i64)
        variables << Debugging::DebugVariableInput.new(
          name: string_field(item, "name") || "<unnamed>",
          value: string_field(item, "value") || "",
          type: string_field(item, "type"),
          variables_reference: reference.to_i32,
          named_variables: int_field(item, "namedVariables").try(&.to_i32),
          indexed_variables: int_field(item, "indexedVariables").try(&.to_i32),
          evaluate_name: string_field(item, "evaluateName")
        )
      end
      total = int_field(body, "totalVariables").try(&.to_i32)
      @variable_tree.complete(page.not_nil!, variables, total_count: total)
      refresh_variables
    end

    private def accept_watch(pending : PendingRequest, body : JSON::Any?) : Nil
      watch_id = pending.watch_id || return
      watch = @watches.find { |entry| entry.id == watch_id.not_nil! } || return
      certificate = pending.certificate || return
      return unless @state.accepts?(certificate.not_nil!)
      watch.not_nil!.status = WatchStatus::Available
      watch.not_nil!.result = safe_display(string_field(body, "result") || "", MAX_WATCH_BYTES)
      watch.not_nil!.type = string_field(body, "type").try { |value| safe_display(value, 256) }
      watch.not_nil!.reason = nil
      touch_generation
    end

    private def accept_source(pending : PendingRequest, body : JSON::Any?) : Nil
      key = pending.source_key || return
      certificate = pending.certificate || return
      return unless @state.accepts?(certificate.not_nil!)
      content = string_field(body, "content")
      unless content && content.not_nil!.valid_encoding? && content.not_nil!.bytesize <= MAX_SOURCE_REQUEST
        @last_error = "adapter source is missing, invalid UTF-8, or exceeds 4 MiB"
        touch_generation
        return
      end
      captured = @source_store.try(&.capture_adapter_source(key.not_nil!, content.not_nil!, pin: true))
      if captured && captured.not_nil!.retained?
        if source = captured.not_nil!.snapshot
          resolution = @source_resolutions[key.not_nil!]?.try(&.display_path)
          retain_source_view(source.not_nil!, resolution)
        end
      else
        @last_error = captured.try(&.reason) || "adapter source could not be retained"
      end
      touch_generation
    end

    private def retain_source_view(source : Debugging::DebugSourceSnapshot, display_path : String?) : Nil
      if existing = @sources[source.key]?
        return if existing.origin == source.origin &&
                  existing.checksum_status == source.checksum_status &&
                  existing.outdated == source.outdated? &&
                  existing.reason == source.reason &&
                  existing.display_path == display_path
      end
      @sources[source.key] = SourceView.new(source.key, source.origin, source.checksum_status,
        source.outdated?, source.text, source.reason, display_path)
      @cached_source_views = nil
      @source_generation += 1_u64
      @generation += 1_u64
    end

    private def submit_resume(command : String, requested_thread_id : Int64?) : ActionSubmission
      client = @client
      thread_id = requested_thread_id || @state.selected_thread_id
      return rejected("debug adapter is not available") unless client
      return rejected("no real stopped thread is selected") unless thread_id && stopped_thread?(thread_id.not_nil!)
      return rejected("another execution request is pending") if @execution_in_flight
      request_id = next_request_id
      all_threads = !@capabilities.single_thread_execution
      new_state, resume_ticket = @state.begin_resume(request_id, thread_id.not_nil!, all_threads)
      return rejected("execution action is unavailable in the current state") unless resume_ticket
      @state = new_state
      @execution_in_flight = true
      # Retire cached handles and displayed watch values before dispatch. The
      # reducer certificate has already been invalidated; this keeps the UI's
      # copied view aligned with that boundary as well.
      retire_inspection("target resume requested")
      args_fields = {"threadId" => JSON::Any.new(thread_id.not_nil!)} of String => JSON::Any
      args_fields["singleThread"] = JSON::Any.new(true) unless all_threads
      send_request(command, json_object(args_fields), PendingKind::Resume,
        execution: true, resume_ticket: resume_ticket, thread_id: thread_id,
        request_id: request_id)
      @generation += 1_u64
      touch_generation
      accepted(nil, request_id)
    rescue ex
      @state = @state.resume_failed(resume_ticket.not_nil!) if resume_ticket
      @execution_in_flight = false
      rejected(safe_error(ex.message || "execution request could not be sent"))
    end

    private def stopped_thread?(thread_id : Int64) : Bool
      @state.lifecycle == DebugSessionState::Lifecycle::Active &&
        @state.thread_execution(thread_id) == DebugSessionState::ThreadExecution::Stopped
    end

    private def maybe_dispatch_stop : Nil
      return unless @stop_requested && !@disconnect_sent
      return if @state.lifecycle.in?(DebugSessionState::Lifecycle::Ended, DebugSessionState::Lifecycle::Failed)
      if @execution_in_flight
        if deadline = @stop_deadline
          if Time.monotonic >= deadline.not_nil!
            fail_session("stop could not safely wait for the pending execution request; target exit is unknown")
          end
        end
        return
      end
      client = @client || return
      args = {} of String => JSON::Any
      if @capabilities.support_terminate_debuggee
        args["terminateDebuggee"] = JSON::Any.new(true)
      end
      @disconnect_sent = true
      args_any = json_object(args)
      send_request("disconnect", args_any, PendingKind::Disconnect, execution: true,
        request_id: next_request_id)
    rescue ex
      fail_session(safe_error(ex.message || "disconnect could not be sent"))
    end

    private def begin_async_close : Nil
      client = @client
      unless client
        @cleanup_pending = false
        return
      end
      return if @close_started
      @close_started = true
      @cleanup_pending = true
      owned_client = client.not_nil!
      spawn(name: "debug-controller-close") do
        owned_client.close
      end
    rescue
      @cleanup_pending = false
    end

    private def fail_session(reason : String) : Nil
      @last_error = safe_error(reason)
      if stamp = @state.session_stamp
        @state = @state.disconnected(stamp.not_nil!)
      end
      @pending.clear
      @execution_in_flight = false
      @stop_deadline = nil
      retire_inspection(@last_error || "debugger session failed")
      begin_async_close
      touch_generation
    end

    private def retire_inspection(reason : String) : Nil
      @variable_tree.retire(safe_display(reason, 256))
      refresh_variables
      @watches.each do |watch|
        next unless watch.status.in?(WatchStatus::Pending, WatchStatus::Available)
        watch.status = WatchStatus::Unavailable
        watch.result = nil
        watch.type = nil
        watch.reason = safe_display(reason, 256)
      end
      @pending.each do |sequence, pending|
        if pending.kind.in?(PendingKind::Scopes, PendingKind::Variables, PendingKind::Watch)
          # Keep client tickets bounded until they are consumed; their local
          # certificates prevent stale results from being published.
        end
      end
      touch_generation
    end

    private def refresh_variables : Nil
      retired_node_id = nil.as(String?)
      retired_reason = nil.as(String?)
      if @capabilities.value_formatting_options
        if previous = @value_format_state
          if previous.not_nil!.status.in?(ValueFormatStatus::Pending, ValueFormatStatus::Available, ValueFormatStatus::Retired)
            retired_node_id = previous.not_nil!.node_id
            retired_reason = previous.not_nil!.status == ValueFormatStatus::Retired ? previous.not_nil!.reason : "variable data refreshed; wait for loading to settle and request Hex again"
          end
        end
      end
      retire_value_format
      @variable_snapshot = @variable_tree.snapshot
      @variable_generation += 1_u64
      if node_id = retired_node_id
        if @variable_snapshot.node(node_id.not_nil!)
          @value_format_state = ValueFormatState.new(node_id.not_nil!, @value_format_generation,
            @variable_generation, ValueFormatStatus::Retired,
            reason: retired_reason || "variable data refreshed; request Hex again")
        end
      end
      @generation += 1_u64
    end

    private def append_output(category : String, text : String) : Nil
      safe_category = safe_display(category, 64)
      safe_text = safe_display(text, MAX_OUTPUT_ENTRY)
      @output << OutputEntry.new(safe_category, Time.utc, safe_text)
      @output_bytes += safe_text.bytesize
      while @output.size > MAX_OUTPUT_ENTRIES || @output_bytes > MAX_OUTPUT_BYTES
        removed = @output.shift
        @output_bytes -= removed.text.bytesize
        @output_dropped += 1_i64
      end
      touch_generation
    end

    private def reconcile_breakpoint_event(_body : JSON::Any?) : Nil
      # The store only accepts an event when an exact current generation and
      # adapter binding are known. This minimal controller does not infer that
      # certificate from an event-only payload.
    end

    private def breakpoint_views : Array(SourceBreakpointView)
      if cached = @cached_breakpoint_views
        return cached.not_nil!.dup
      end
      rows = [] of SourceBreakpointView
      @breakpoint_keys.each do |key|
        @breakpoint_store.breakpoints(key).each do |breakpoint|
          rows << SourceBreakpointView.new(key, breakpoint)
        end
      end
      @cached_breakpoint_views = rows
      rows.dup
    end

    private def source_views : Array(SourceView)
      if cached = @cached_source_views
        return cached.not_nil!.dup
      end
      @cached_source_views = @sources.values.to_a
      @cached_source_views.not_nil!.dup
    end

    private def invalidate_breakpoint_views : Nil
      @cached_breakpoint_views = nil
      @breakpoint_generation += 1_u64
      touch_generation
    end

    private def build_availability : Hash(Action, ActionAvailability)
      available = {} of Action => ActionAvailability
      active = @state.lifecycle == DebugSessionState::Lifecycle::Active
      thread_id = @state.selected_thread_id
      stopped = thread_id && stopped_thread?(thread_id.not_nil!)
      frame_ready = stopped && @state.selected_frame_id && @frames.any? { |frame| frame.id == @state.selected_frame_id }
      available[Action::Start] = ActionAvailability.new(restartable?, restartable? ? nil : "a debugger session is active or cleaning up")
      available[Action::Continue] = ActionAvailability.new(!!stopped && active && !@execution_in_flight, "requires a stopped selected thread")
      available[Action::StepOver] = ActionAvailability.new(!!stopped && active && !@execution_in_flight, "requires a stopped selected thread")
      available[Action::StepInto] = ActionAvailability.new(!!stopped && active && !@execution_in_flight, "requires a stopped selected thread")
      available[Action::StepOut] = ActionAvailability.new(!!stopped && active && !@execution_in_flight, "requires a stopped selected thread")
      can_pause = active && @state.target_liveness == DebugSessionState::TargetLiveness::Alive && thread_id && !@execution_in_flight
      available[Action::Pause] = ActionAvailability.new(!!can_pause, "requires a known live target thread")
      available[Action::Stop] = ActionAvailability.new(!!@client && !@stop_requested, "no stoppable debugger session")
      available[Action::SelectThread] = ActionAvailability.new(@threads.size > 1, "no alternative known thread")
      available[Action::SelectFrame] = ActionAvailability.new(@frames.size > 1, "no alternative current frame")
      available[Action::ToggleBreakpoint] = ActionAvailability.new(@bound_project_root != nil, "bind a project before setting source breakpoints")
      available[Action::OpenScopes] = ActionAvailability.new(!!frame_ready, "requires a current stopped frame")
      available[Action::ExpandVariable] = ActionAvailability.new(!!frame_ready, "requires a current stopped frame")
      available[Action::AddWatch] = ActionAvailability.new(@watches.size < MAX_WATCHES, "watch list is at its bounded limit")
      available[Action::EvaluateWatch] = ActionAvailability.new(!!frame_ready && !@execution_in_flight, "requires a current stopped frame")
      available[Action::OpenSource] = ActionAvailability.new(!@frames.empty?, "no current source frame")
      available
    end

    private def touch_generation : Nil
      @generation += 1_u64
    end
  end
end
