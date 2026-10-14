require "json"
require "mutex"
require "./chat_submission"
require "./editor_tools"

module Adamantine
  module Chat
    MAX_DRAFT_BYTES      = 16 * 1024
    MAX_MESSAGE_BYTES    = 64 * 1024
    MAX_TRANSCRIPT_BYTES = 256 * 1024
    MAX_MESSAGES         = 128
    MAX_PENDING_EVENTS   = 128
    MAX_PENDING_BYTES    = 128 * 1024

    UNAVAILABLE_STATUS      = "No model connected; draft retained."
    GENERATING_STATUS       = "Generating…"
    CANCELLED_STATUS        = "Request cancelled."
    QUEUE_LIMIT_STATUS      = "Chat callback queue limit reached; request cancelled."
    INVALID_EVENT_STATUS    = "Chat event contained invalid UTF-8."
    DRAFT_UTF8_STATUS       = "Input contains invalid UTF-8."
    TRANSCRIPT_LIMIT_STATUS = "Older chat messages removed to stay within transcript limit."
    MESSAGE_LIMIT_STATUS    = "Message truncated at 64 KiB."

    enum TurnState
      Idle
      Generating
      Complete
      Cancelled
      Failed
    end

    enum Role
      User
      Assistant
    end

    class Message
      getter role : Role

      @text : String

      def initialize(@role : Role, text : String)
        @text = text.dup
      end

      def text : String
        @text.dup
      end

      def bytesize : Int32
        @text.bytesize
      end

      def valid_encoding? : Bool
        @text.valid_encoding?
      end
    end

    struct Request
      getter turn_id : UInt64
      @text : String
      @context : SubmissionContext
      @history : Array(Message)

      def initialize(@turn_id : UInt64,
                     text : String,
                     context : SubmissionContext = SubmissionContext.none,
                     history : Array(Message) = [] of Message)
        raise ArgumentError.new("request prompt must be valid UTF-8") unless text.valid_encoding?
        if text.bytesize > MAX_DRAFT_BYTES
          raise ArgumentError.new("request prompt exceeds 16 KiB")
        end
        @text = text.dup
        @context = SubmissionContext.new(context.mode, context.label, context.text,
          context.buffer_id, context.revision, context.lua_script_grant)
        if history.size > MAX_HISTORY_MESSAGES
          raise ArgumentError.new("chat history exceeds 16 messages")
        end
        total = 0_i64
        history.each do |message|
          raise ArgumentError.new("chat history must be valid UTF-8") unless message.valid_encoding?
          total += message.bytesize.to_i64
          if total > MAX_HISTORY_BYTES.to_i64
            raise ArgumentError.new("chat history exceeds 64 KiB")
          end
        end
        @history = history.map { |message| Message.new(message.role, message.text) }
      end

      def text : String
        @text.dup
      end

      def context : SubmissionContext
        SubmissionContext.new(@context.mode, @context.label, @context.text,
          @context.buffer_id, @context.revision, @context.lua_script_grant)
      end

      def history : Array(Message)
        @history.map { |message| Message.new(message.role, message.text) }
      end

      def history_bytes : Int32
        @history.sum(&.bytesize)
      end
    end

    class Event
      enum Kind
        Delta
        Complete
        Failure
        ToolRequest
      end

      getter kind : Kind
      getter text : String?
      getter call_id : String?
      getter request_json : String?

      private def initialize(@kind : Kind, text : String? = nil,
                             call_id : String? = nil, request_json : String? = nil)
        @text = text.try(&.dup)
        @call_id = call_id.try(&.dup)
        @request_json = request_json.try(&.dup)
      end

      def self.delta(text : String) : Event
        new(Kind::Delta, text: text)
      end

      def self.complete : Event
        new(Kind::Complete)
      end

      def self.failure(message : String) : Event
        new(Kind::Failure, text: message)
      end

      def self.tool_request(call_id : String, request_json : String) : Event
        new(Kind::ToolRequest, call_id: call_id, request_json: request_json)
      end

      def byte_size : Int32
        16 + (@text.try(&.bytesize) || 0) + (@call_id.try(&.bytesize) || 0) + (@request_json.try(&.bytesize) || 0)
      end
    end

    abstract class Handle
      abstract def cancel : Nil
      abstract def deliver_tool_result(call_id : String, result_json : String) : Nil
    end

    abstract class Transport
      abstract def available? : Bool

      def external? : Bool
        false
      end

      abstract def start(request : Request,
                         on_event : Proc(Event, Nil)) : Handle
    end

    class UnavailableTransport < Transport
      def available? : Bool
        false
      end

      def start(request : Request, on_event : Proc(Event, Nil)) : Handle
        raise "no chat model is connected"
      end
    end

    # Transport callbacks only enqueue typed events. The App owner calls drain,
    # which is the only path that mutates transcript state or invokes a tool
    # session. External providers receive only the approved immutable request
    # snapshot; injected local transports retain their historical control seam.
    class Frontend
      alias SessionFactory = Proc(EditorTools::Session)
      alias ContextSessionFactory = Proc(SubmissionContext, EditorTools::Session)
      alias DeferredToolHandler = Proc(EditorTools::DeferredCall, SubmissionContext, Nil)
      alias DeferredToolRetirement = Proc(EditorTools::DeferredCall, Nil)
      alias Wakeup = Proc(Nil)
      alias PendingEvent = {UInt64, Event}
      alias PendingDeferred = {UInt64, EditorTools::DeferredCall, Handle, EditorTools::Session}

      @transport : Transport
      @session_factory : SessionFactory?
      @context_session_factory : ContextSessionFactory?
      property deferred_tool_handler : DeferredToolHandler?
      property deferred_tool_retirement : DeferredToolRetirement?
      @wakeup : Wakeup?
      @queue_lock = Mutex.new
      @pending = [] of PendingEvent
      @pending_bytes = 0
      @overflow_generation : UInt64?
      @accepting_generation : UInt64?
      @next_generation : UInt64 = 0
      @lifetime_revision : UInt64 = 0
      @history_revision : UInt64 = 0
      @starting_generation : UInt64?

      @draft = ""
      @messages = [] of Message
      @transcript_bytes = 0
      @transcript_evictions : UInt64 = 0
      @state = TurnState::Idle
      @status = UNAVAILABLE_STATUS
      @active_generation : UInt64?
      @handle : Handle?
      @session : EditorTools::Session?
      @context_session_construction : {UInt64, SubmissionContext}?
      @pending_deferred = {} of String => PendingDeferred
      @submission_context = SubmissionContext.none
      @tool_attempts = 0
      @proposal_attempts = 0
      @proposal_revision = 0_u64
      @assistant_text = ""
      @assistant_truncated = false
      @transcript_evicted = false
      @resetting_conversation = false
      @shutdown = false

      def initialize(@transport : Transport = UnavailableTransport.new,
                     @session_factory : SessionFactory? = nil,
                     @wakeup : Wakeup? = nil,
                     @context_session_factory : ContextSessionFactory? = nil)
      end

      def draft : String
        @draft.dup
      end

      def set_draft(text : String) : Bool
        normalized = normalize_input(text)
        unless normalized
          @status = DRAFT_UTF8_STATUS
          return false
        end
        if normalized.bytesize > MAX_DRAFT_BYTES
          @status = "Draft exceeds 16 KiB."
          return false
        end

        @draft = normalized
        true
      end

      def messages : Array(Message)
        @messages.map { |message| Message.new(message.role, message.text) }
      end

      def state : TurnState
        @state
      end

      def status : String
        @status.dup
      end

      # Owner-readable token for fencing delayed UI work across lifecycle
      # boundaries. It intentionally exposes no session or transport state.
      def lifetime_revision : UInt64
        @queue_lock.synchronize { @lifetime_revision }
      end

      # A separate owner-visible fence survives a successful Complete so a
      # staged proposal can be published into manual review after tool-session
      # teardown. It changes at replacement/cancellation boundaries.
      def proposal_revision : UInt64
        @queue_lock.synchronize { @proposal_revision }
      end

      def active? : Bool
        @state == TurnState::Generating && !@active_generation.nil?
      end

      # True only while the external context-session factory is synchronously
      # constructing a Session for this exact turn context. This is a
      # construction/lifetime hint, not authorization to invoke tools.
      def constructing_context_session?(context : SubmissionContext) : Bool
        construction = @context_session_construction
        return false unless construction
        generation, captured_context = construction
        @starting_generation == generation && captured_context == context && !@shutdown
      end

      def available? : Bool
        !@shutdown && @transport.available?
      end

      def external? : Bool
        @transport.external?
      end

      # Static, side-effect-free explanation for why an external Send review
      # cannot be opened. It never resolves a credential reference or starts a
      # provider request.
      def review_unavailable_reason : String?
        return "Chat provider is disabled or invalid; open Chat settings." unless external? && available?
        return "Chat is clearing the conversation; try again shortly." if @resetting_conversation
        return "A Chat request is already active; cancel it before sending." if active? || @starting_generation
        return "Enter a prompt before sending." if @draft.empty?
        return "Prompt exceeds 16 KiB; shorten it before sending." if !@draft.valid_encoding? || @draft.bytesize > MAX_DRAFT_BYTES
        return "Visible history exceeds 16 messages or 64 KiB; start a new conversation." if @messages.size > MAX_HISTORY_MESSAGES

        total = 0_i64
        @messages.each do |message|
          return "Visible history contains invalid text; start a new conversation." unless message.valid_encoding?
          total += message.bytesize.to_i64
          return "Visible history exceeds 16 messages or 64 KiB; start a new conversation." if total > MAX_HISTORY_BYTES.to_i64
        end
        nil
      end

      # Build the exact, bounded export candidate for a Send review without
      # changing draft, transcript, generation, or tool-session state.
      def review_request(context : SubmissionContext = SubmissionContext.none) : Request?
        return if @shutdown || @resetting_conversation || review_unavailable_reason
        history = @messages.map { |message| Message.new(message.role, message.text) }
        Request.new(@next_generation + 1_u64, @draft, context, history)
      rescue
        nil
      end

      def submit(context : SubmissionContext = SubmissionContext.none) : Bool
        return false if @shutdown || @resetting_conversation
        unless @transport.available?
          @status = UNAVAILABLE_STATUS
          return false
        end
        return false if active? || @starting_generation

        prompt = @draft
        if prompt.empty?
          @status = "Enter a message first."
          return false
        end

        history = [] of Message
        if @transport.external?
          return reject_history_limit if @messages.size > MAX_HISTORY_MESSAGES
          total = 0_i64
          @messages.each do |message|
            total += message.bytesize.to_i64
            return reject_history_limit if total > MAX_HISTORY_BYTES.to_i64
          end
          history = @messages.map { |message| Message.new(message.role, message.text) }
        end
        request = begin
          Request.new(@next_generation + 1_u64, prompt, context, history)
        rescue
          @status = "Chat context or history is invalid or exceeds its limit."
          return false
        end

        generation = advance_generation
        @starting_generation = generation
        @assistant_truncated = false
        @transcript_evicted = false
        session : EditorTools::Session? = nil
        begin
          if @transport.external?
            if context.mode.buffer_tools? || context.mode.buffer_proposals?
              factory = @context_session_factory || raise "approved read-buffer tool session is unavailable"
              @context_session_construction = {generation, context}
              begin
                session = factory.call(context)
              ensure
                current = @context_session_construction
                @context_session_construction = nil if current && current[0] == generation
              end
            end
          else
            session = @session_factory.try(&.call)
          end
        rescue ex
          if starting_generation?(generation)
            message = if @transport.external?
                        "Approved chat tools are unavailable; draft retained."
                      else
                        safe_status("Could not open chat tool session: #{ex.message}")
                      end
            terminate_generation(generation, TurnState::Failed,
              message, cancel_handle: false)
          end
          return false
        end

        # The factory is an owner-side boundary and can reenter shutdown,
        # retirement, cancellation, or new-conversation. Do not install a
        # session or start transport work for a generation it revoked.
        unless starting_generation?(generation) && !@shutdown
          safe_close_session(session)
          return false
        end

        @starting_generation = nil
        @session = session
        @active_generation = generation
        set_accepting_generation(generation)
        @state = TurnState::Generating
        @status = GENERATING_STATUS
        @submission_context = request.context
        @tool_attempts = 0
        @proposal_attempts = 0
        @assistant_text = ""

        request = Request.new(generation, prompt, context, history)
        callback = ->(event : Event) { enqueue(generation, event) }
        start_history_revision = @history_revision
        start_message_index = @messages.size
        start_transcript_evictions = @transcript_evictions
        handle = begin
          @transport.start(request, callback)
        rescue ex
          message = if @transport.external?
                      "Chat provider could not start the request; draft retained."
                    else
                      "Chat transport failed to start: #{ex.message}"
                    end
          fail_generation(generation, message)
          return false
        end

        # start may synchronously cause cancellation or retirement before it
        # returns the handle. Never resurrect that turn; retire the late handle.
        if active_generation?(generation)
          @handle = handle
        else
          safe_cancel(handle)
        end

        # A transport start is transactional with respect to exportable chat
        # history. In particular, a synchronous environment/preflight failure
        # must leave the prompt retryable without recording an unsent user turn.
        # A reentrant lifecycle action during start also revokes this commit.
        if @history_revision == start_history_revision && !@shutdown
          @draft = "" if @draft == prompt
          evicted_before_commit = @transcript_evictions - start_transcript_evictions
          commit_index = if evicted_before_commit >= start_message_index.to_u64
                           0
                         else
                           start_message_index - evicted_before_commit.to_i
                         end
          insert_message(commit_index, Role::User, prompt)
        end
        true
      end

      # Called on the App owner only. Returns true if visible state changed.
      def drain : Bool
        queued, overflow = take_pending
        changed = false

        if generation = overflow
          if active_generation?(generation)
            fail_generation(generation, QUEUE_LIMIT_STATUS)
            return true
          end
        end

        queued.each do |entry|
          generation, event = entry
          next unless active_generation?(generation)
          unless event_valid?(event)
            fail_generation(generation, INVALID_EVENT_STATUS)
            changed = true
            next
          end

          begin
            case event.kind
            when Event::Kind::Delta
              append_delta(generation, event.text.not_nil!)
              changed = true
            when Event::Kind::Complete
              complete_generation(generation)
              changed = true
            when Event::Kind::Failure
              fail_generation(generation, safe_status(event.text || "Chat request failed."))
              changed = true
            when Event::Kind::ToolRequest
              dispatch_tool_request(generation, event.call_id.not_nil!, event.request_json.not_nil!)
              changed = true
            end
          rescue ex
            fail_generation(generation, "Chat callback failed: #{safe_status(ex.message || "unknown error")}")
            changed = true
          end
        end

        changed
      end

      def cancel : Bool
        generation = @active_generation || @starting_generation
        return false unless generation

        terminate_generation(generation, TurnState::Cancelled, CANCELLED_STATUS, cancel_handle: true)
        true
      end

      # Deferred child completions are accepted only for the still-current
      # ticket/turn/session/transport tuple. Stale callbacks cannot write into
      # a newer provider round.
      def complete_deferred_tool(ticket : EditorTools::DeferredCall,
                                 data : JSON::Any) : Bool
        complete_deferred_tool_outcome(ticket, data)[0]
      end

      # Returns the actual charged outer result, not merely whether the ticket
      # matched the pending turn. Hosts must require `ok?` before publishing a
      # child preview or treating completion as successful.
      def complete_deferred_tool_result(ticket : EditorTools::DeferredCall,
                                        data : JSON::Any) : EditorTools::Result?
        complete_deferred_tool_outcome(ticket, data)[1]
      end

      # Cancel only the provider generation that owns this exact pending ticket.
      # Hosts use this after revoking root authority when a context receipt goes
      # stale; it is deliberately not a general-purpose turn cancellation API.
      def cancel_deferred_turn(ticket : EditorTools::DeferredCall) : Bool
        pending = @pending_deferred[ticket.id]?
        return false unless pending && pending[1].same?(ticket)
        generation = pending[0]
        return false unless active_generation?(generation)

        terminate_generation(generation, TurnState::Failed,
          "Approved script context changed; request cancelled.", cancel_handle: true)
        true
      rescue
        false
      end

      private def complete_deferred_tool_outcome(ticket : EditorTools::DeferredCall,
                                                 data : JSON::Any) : {Bool, EditorTools::Result?}
        pending = @pending_deferred[ticket.id]?
        return {false, nil} unless pending && pending[1].same?(ticket)
        return {false, nil} unless ticket.active?
        generation, _ticket, handle, session = pending
        return {false, nil} unless dispatch_generation_current?(generation, handle, session)
        begin
          result = ticket.complete(data)
          deliver_deferred_result(generation, ticket.id, handle, session, result)
          {true, result}
        rescue ex
          fail_generation(generation,
            "Deferred tool result delivery failed: #{safe_status(ex.message || "unknown error")}")
          # Acceptance reports whether this exact live ticket was consumed;
          # the result accessor remains nil because no deliverable result exists.
          {true, nil}
        ensure
          @pending_deferred.delete(ticket.id) if @pending_deferred[ticket.id]?.try(&.[1].same?(ticket))
        end
      rescue
        {false, nil}
      end

      def fail_deferred_tool(ticket : EditorTools::DeferredCall,
                             status : EditorTools::Status,
                             message : String) : Bool
        pending = @pending_deferred[ticket.id]?
        return false unless pending && pending[1].same?(ticket)
        return false unless ticket.active?
        generation, _ticket, handle, session = pending
        return false unless dispatch_generation_current?(generation, handle, session)
        begin
          result = ticket.fail(status, message)
          deliver_deferred_result(generation, ticket.id, handle, session, result)
        rescue ex
          fail_generation(generation,
            "Deferred tool result delivery failed: #{safe_status(ex.message || "unknown error")}")
        ensure
          @pending_deferred.delete(ticket.id) if @pending_deferred[ticket.id]?.try(&.[1].same?(ticket))
        end
        true
      rescue
        false
      end

      def new_conversation : Nil
        return if @resetting_conversation
        bump_lifetime_revision
        bump_proposal_revision
        @history_revision &+= 1_u64
        @resetting_conversation = true
        begin
          cancel
          @messages.clear
          @transcript_bytes = 0
          @draft = ""
          @assistant_text = ""
          @assistant_truncated = false
          @transcript_evicted = false
          @state = TurnState::Idle
          @status = available? ? "New conversation." : UNAVAILABLE_STATUS
        ensure
          @resetting_conversation = false
        end
      end

      # Root retirement and quit revoke this turn's tools and event generation.
      # The in-memory transcript/draft survive root changes; shutdown forbids new work.
      def retire_context : Nil
        bump_lifetime_revision
        bump_proposal_revision
        @history_revision &+= 1_u64
        if generation = @active_generation || @starting_generation
          terminate_generation(generation, TurnState::Cancelled,
            "Tool session retired; request cancelled.", cancel_handle: true)
        else
          close_session
        end
      end

      # Root/provider retirement removes exportable conversation text without
      # discarding the user's unsent composer draft.
      def clear_exportable_history : Nil
        bump_proposal_revision
        @history_revision &+= 1_u64
        @messages.clear
        @transcript_bytes = 0
        @assistant_text = ""
        @assistant_truncated = false
        @transcript_evicted = false
      end

      def replace_transport(transport : Transport) : Nil
        retire_context
        @transport = transport
        clear_exportable_history
        @state = TurnState::Idle unless @shutdown
        @status = available? ? "Chat provider changed; conversation cleared." : UNAVAILABLE_STATUS
      end

      def shutdown : Nil
        return if @shutdown
        @shutdown = true
        bump_lifetime_revision
        bump_proposal_revision
        retire_context
      end

      private def enqueue(generation : UInt64, event : Event) : Nil
        notify = false
        @queue_lock.synchronize do
          next unless @accepting_generation == generation

          size = event.byte_size
          if @pending.size >= MAX_PENDING_EVENTS || @pending_bytes + size > MAX_PENDING_BYTES
            @overflow_generation = generation
            notify = true
          elsif @overflow_generation != generation
            @pending << {generation, event}
            @pending_bytes += size
            notify = true
          end
        end
        wake_owner if notify
      rescue
        # The callback boundary must not let a transport fiber raise into the App.
        wake_owner
      end

      private def take_pending : {Array(PendingEvent), UInt64?}
        @queue_lock.synchronize do
          entries = @pending
          overflow = @overflow_generation
          @pending = [] of PendingEvent
          @pending_bytes = 0
          @overflow_generation = nil
          {entries, overflow}
        end
      end

      private def advance_generation : UInt64
        @queue_lock.synchronize do
          @next_generation += 1
          @lifetime_revision += 1
          @proposal_revision += 1
          @accepting_generation = nil
          @pending.clear
          @pending_bytes = 0
          @overflow_generation = nil
          @next_generation
        end
      end

      private def set_accepting_generation(generation : UInt64?) : Nil
        @queue_lock.synchronize do
          @accepting_generation = generation
          unless generation
            @pending.clear
            @pending_bytes = 0
            @overflow_generation = nil
          end
        end
      end

      private def active_generation?(generation : UInt64) : Bool
        @active_generation == generation && @state == TurnState::Generating
      end

      private def starting_generation?(generation : UInt64) : Bool
        @starting_generation == generation
      end

      private def event_valid?(event : Event) : Bool
        [event.text, event.call_id, event.request_json].compact.all?(&.valid_encoding?)
      end

      private def dispatch_tool_request(generation : UInt64, call_id : String,
                                        request_json : String) : Nil
        return unless active_generation?(generation)
        handle = @handle
        # A synchronous callback can arrive before start returns a Handle. Requeue
        # the request; drain will revisit it after submit assigns that Handle.
        unless handle
          enqueue(generation, Event.tool_request(call_id, request_json))
          return
        end

        session = @session
        if @transport.external?
          @tool_attempts += 1
          if @tool_attempts > MAX_TOOL_ATTEMPTS
            terminate_generation(generation, TurnState::Failed,
              "Chat tool-attempt limit exceeded; request cancelled.", cancel_handle: true)
            return
          end
        end

        outcome = if @transport.external?
                    production_tool_result(session, call_id, request_json)
                  elsif session
                    session.invoke_json(request_json)
                  else
                    EditorTools::Result.new(nil, EditorTools::Status::Unavailable,
                      nil, "tool session is unavailable")
                  end
        return unless dispatch_generation_current?(generation, handle, session)
        if deferred = outcome.as?(EditorTools::DeferredCall)
          @pending_deferred[call_id] = {generation, deferred, handle, session.not_nil!}
          if handler = @deferred_tool_handler
            handler.call(deferred, @submission_context)
          else
            fail_deferred_tool(deferred, EditorTools::Status::Unavailable,
              "approved named-script execution is unavailable")
          end
          return
        end
        result = outcome.as(EditorTools::Result)
        handle.deliver_tool_result(call_id, result.to_json)
        return unless dispatch_generation_current?(generation, handle, session)

        if session && session.exhausted?
          terminate_generation(generation, TurnState::Failed,
            "Tool session budget exhausted; request cancelled.", cancel_handle: true)
        end
      end

      private def production_tool_result(session : EditorTools::Session?,
                                         call_id : String,
                                         request_json : String) : EditorTools::DeferredCall | EditorTools::Result
        unless session
          return EditorTools::Result.new(call_id, EditorTools::Status::Denied, nil,
            "only approved selected-buffer tools are available")
        end

        if request_name(request_json) == "lua.run_script"
          script_guard : Proc(EditorTools::RunScriptRequest, Nil) = ->(request : EditorTools::RunScriptRequest) {
            grant = @submission_context.lua_script_grant
            unless grant && (@submission_context.mode.buffer_tools? || @submission_context.mode.buffer_proposals?) &&
                   grant.id == request.script_id
              raise EditorTools::Failure.new(EditorTools::Status::Denied,
                "named script is outside the approved Chat grant")
            end
          }
          session.defer_json(request_json, expected_call_id: call_id, request_guard: script_guard)
        else
          buffer_guard : Proc(EditorTools::Request, Nil) = ->(request : EditorTools::Request) {
            guard_selected_buffer_request!(request)
          }
          session.invoke_json(request_json, expected_call_id: call_id, request_guard: buffer_guard)
        end
      end

      private def request_name(request_json : String) : String?
        parsed = EditorTools.parse_bounded_json(request_json)
        envelope = parsed.as_h?
        envelope.try { |object| EditorTools.string_value(object["name"]?, "tool name") }
      rescue
        nil
      end

      private def guard_selected_buffer_request!(request : EditorTools::Request) : Nil
        context = @submission_context
        case request
        when EditorTools::ReadBufferRequest
          unless (context.mode.buffer_tools? || context.mode.buffer_proposals?) &&
                 context.buffer_id == request.buffer_id && context.revision == request.revision
            raise EditorTools::Failure.new(EditorTools::Status::Denied,
              "buffer is outside the approved turn scope")
          end
        when EditorTools::ProposeEditsRequest
          unless context.mode.buffer_proposals? &&
                 context.buffer_id == request.buffer_id && context.revision == request.revision
            raise EditorTools::Failure.new(EditorTools::Status::Denied,
              "proposals are outside the approved turn scope")
          end
          if @proposal_attempts >= 1
            raise EditorTools::Failure.new(EditorTools::Status::Denied,
              "only one proposal is allowed per turn")
          end
          @proposal_attempts += 1
        else
          raise EditorTools::Failure.new(EditorTools::Status::Denied,
            "only selected-buffer tools are available")
        end
        nil
      end

      private def deliver_deferred_result(generation : UInt64, call_id : String,
                                          handle : Handle, session : EditorTools::Session,
                                          result : EditorTools::Result) : Nil
        return unless dispatch_generation_current?(generation, handle, session)
        handle.deliver_tool_result(call_id, result.to_json)
        return unless dispatch_generation_current?(generation, handle, session)
        if session.exhausted?
          terminate_generation(generation, TurnState::Failed,
            "Tool session budget exhausted; request cancelled.", cancel_handle: true)
        end
      end

      private def dispatch_generation_current?(generation : UInt64, handle : Handle,
                                               session : EditorTools::Session?) : Bool
        return false unless active_generation?(generation)
        return false unless @handle.try(&.same?(handle))
        if session
          @session.try(&.same?(session)) || false
        else
          @session.nil?
        end
      end

      private def append_delta(generation : UInt64, raw : String) : Nil
        return unless active_generation?(generation)
        return if @assistant_truncated

        clean = sanitize_text(raw)
        remaining = MAX_MESSAGE_BYTES - @assistant_text.bytesize
        if clean.bytesize > remaining
          @assistant_text += prefix_bytes(clean, remaining)
          @assistant_truncated = true
          @status = MESSAGE_LIMIT_STATUS
        else
          @assistant_text += clean
        end
        replace_stream_message
      end

      private def replace_stream_message : Nil
        if @messages.last?.try(&.role) == Role::Assistant
          previous = @messages.pop
          @transcript_bytes -= previous.bytesize
        end
        append_message(Role::Assistant, @assistant_text) unless @assistant_text.empty?
      end

      private def append_message(role : Role, raw : String) : Nil
        insert_message(@messages.size, role, raw)
      end

      private def insert_message(index : Int32, role : Role, raw : String) : Nil
        clean = sanitize_text(raw)
        if clean.bytesize > MAX_MESSAGE_BYTES
          clean = prefix_bytes(clean, MAX_MESSAGE_BYTES)
          @status = MESSAGE_LIMIT_STATUS
        end
        return if clean.empty?

        message = Message.new(role, clean)
        @messages.insert(index.clamp(0, @messages.size), message)
        @transcript_bytes += message.bytesize
        while @messages.size > MAX_MESSAGES || @transcript_bytes > MAX_TRANSCRIPT_BYTES
          removed = @messages.shift
          @transcript_bytes -= removed.bytesize
          @transcript_evictions &+= 1_u64
          @transcript_evicted = true
          @status = TRANSCRIPT_LIMIT_STATUS
        end
      end

      private def reject_history_limit : Bool
        @status = "Chat history exceeds 64 KiB / 16 messages; start a new conversation."
        false
      end

      private def complete_generation(generation : UInt64) : Nil
        return unless active_generation?(generation)
        if @pending_deferred.any? { |_id, pending| pending[0] == generation }
          fail_generation(generation,
            "Provider completed while a deferred tool was still running; request cancelled.")
          return
        end
        terminate_generation(generation, TurnState::Complete, "Response complete.", cancel_handle: false)
      end

      private def fail_generation(generation : UInt64, message : String) : Nil
        return unless active_generation?(generation)
        terminate_generation(generation, TurnState::Failed, safe_status(message), cancel_handle: true)
      end

      private def terminate_generation(generation : UInt64, state : TurnState,
                                       message : String, cancel_handle : Bool) : Nil
        active = @active_generation == generation
        starting = @starting_generation == generation
        return unless active || starting

        bump_lifetime_revision
        bump_proposal_revision unless state == TurnState::Complete
        set_accepting_generation(nil)
        @active_generation = nil if active
        @starting_generation = nil if starting
        handle = active ? @handle : nil
        session = active ? @session : nil
        @handle = nil if active
        @session = nil if active
        deferred = [] of EditorTools::DeferredCall
        deferred_ids = [] of String
        @pending_deferred.each do |call_id, pending|
          if pending[0] == generation
            deferred << pending[1]
            deferred_ids << call_id
          end
        end
        deferred_ids.each { |call_id| @pending_deferred.delete(call_id) }

        # Commit and detach the old generation before invoking either boundary:
        # cancel may call back into submit, and must not let this teardown
        # overwrite or close resources from the newer turn.
        @state = state
        @status = with_retention_notices(message)
        safe_close_session(session)
        deferred.each do |ticket|
          ticket.revoke
          begin
            @deferred_tool_retirement.try(&.call(ticket))
          rescue
            # Session/ticket revocation already fenced late results; retirement
            # callbacks may only request owner-side process cleanup.
          end
        end
        safe_cancel(handle) if handle && cancel_handle
      end

      private def with_retention_notices(message : String) : String
        notices = [] of String
        notices << MESSAGE_LIMIT_STATUS if @assistant_truncated
        notices << TRANSCRIPT_LIMIT_STATUS if @transcript_evicted
        notices.empty? ? message : "#{message} #{notices.join(" ")}"
      end

      private def bump_lifetime_revision : Nil
        @queue_lock.synchronize { @lifetime_revision += 1 }
      end

      private def bump_proposal_revision : Nil
        @queue_lock.synchronize { @proposal_revision += 1 }
      end

      private def close_session : Nil
        session = @session
        @session = nil
        safe_close_session(session)
      end

      private def safe_close_session(session : EditorTools::Session?) : Nil
        session.try(&.close)
      rescue
        # Session revocation is best effort; generation fencing remains authoritative.
      end

      private def safe_cancel(handle : Handle) : Nil
        handle.cancel
      rescue
        # Cancellation is best effort; the generation fence remains authoritative.
      end

      private def wake_owner : Nil
        @wakeup.try(&.call)
      rescue
        # Queue state is retained and will be picked up on the next App poll.
      end

      private def normalize_input(text : String) : String?
        return unless text.valid_encoding?
        normalized = text.gsub("\r\n", "\n").gsub('\r', '\n')
        sanitize_text(normalized)
      end

      private def sanitize_text(text : String) : String
        String.build do |io|
          text.each_char do |char|
            if char == '\n' || char == '\t' || !char.control?
              io << char
            end
          end
        end
      end

      private def prefix_bytes(text : String, limit : Int32) : String
        return "" if limit <= 0
        return text.dup if text.bytesize <= limit

        String.build do |io|
          used = 0
          text.each_char do |char|
            width = char.bytesize
            break if used + width > limit
            io << char
            used += width
          end
        end
      end

      private def safe_status(message : String?) : String
        return "Chat request failed." unless message
        return "Chat request failed." unless message.valid_encoding?
        clean = sanitize_text(message).gsub('\n', ' ').gsub('\t', ' ')
        prefix_bytes(clean, 512)
      end
    end
  end
end
