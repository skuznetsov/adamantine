require "json"
require "random/secure"

require "./protocol"
require "./transport"

module Adamantine::Dap
  enum ResultStatus
    Success
    AdapterError
    TimedOut
    TransportError
    Cancelled
  end

  struct Ticket
    getter sequence : Int32
    @session_id : String

    def initialize(@sequence : Int32, session_id : String)
      @session_id = session_id.dup
    end

    def session_id : String
      @session_id.dup
    end

    def belongs_to?(session_id : String) : Bool
      @session_id == session_id
    end
  end

  # A bounded scalar sample of transport reservations. Fields are sampled
  # under their owning subsystem locks; the snapshot is not a globally atomic
  # instant, and decoded bytes are logical allocation credits rather than RSS.
  struct ResourceSnapshot
    getter inbound_wire_bytes : Int64
    getter decoded_queue_items : Int32
    getter decoded_queue_bytes : Int64
    getter writer_queue_bytes : Int64
    getter writer_queue_frames : Int32
    getter active_writer_io_tasks : Int32

    def initialize(@inbound_wire_bytes : Int64, @decoded_queue_items : Int32,
                   @decoded_queue_bytes : Int64, @writer_queue_bytes : Int64,
                   @writer_queue_frames : Int32, @active_writer_io_tasks : Int32)
    end
  end

  struct RequestResult
    getter ticket : Ticket
    getter status : ResultStatus
    getter response : Message?
    getter message : String?

    def initialize(@ticket : Ticket, @status : ResultStatus,
                   @response : Message? = nil, @message : String? = nil)
    end

    def success? : Bool
      @status.success?
    end

    def timed_out? : Bool
      @status.timed_out?
    end

    def transport_error? : Bool
      @status.transport_error?
    end

    def body : JSON::Any?
      @response.try(&.body)
    end
  end

  private struct PendingRequest
    getter command : String
    getter deadline : Time::Instant
    getter execution : Bool

    def initialize(@command : String, @deadline : Time::Instant, @execution : Bool)
    end
  end

  private struct ExpiredRequest
    getter command : String

    def initialize(@command : String)
    end
  end

  # Any close can discard terminal event payloads already queued but not yet
  # polled. Keep only the small validated facts needed to replay those events
  # once; never retain adapter JSON or its decoded/wire reservations through
  # cleanup. Frames not yet received and facts already consumed are excluded.
  private struct TerminalEventCertificate
    getter sequence : Int32
    getter event : String
    getter exit_code : Int32?

    def initialize(@sequence : Int32, @event : String, @exit_code : Int32? = nil)
    end

    def to_message : Message
      body_fields = {} of String => JSON::Any
      body_fields["exitCode"] = JSON::Any.new(@exit_code.not_nil!) if @exit_code
      body = JSON::Any.new(body_fields)
      payload = JSON::Any.new({
        "seq"   => JSON::Any.new(@sequence),
        "type"  => JSON::Any.new("event"),
        "event" => JSON::Any.new(@event),
        "body"  => body,
      })
      Message.new(@sequence, "event", nil, @event, nil, nil, nil, nil,
        body, payload, 0, 0_i64)
    end
  end

  # Asynchronous stdio DAP client. Construction is inert; start owns only the
  # adapter process, while initialize/launch and all protocol requests require
  # explicit method calls by the application layer.
  class Client
    DEFAULT_REQUEST_TIMEOUT = 10.seconds
    MAX_REQUEST_TIMEOUT     = 5.minutes
    DEADLINE_POLL_INTERVAL  = 10.milliseconds
    MAX_POLL_EVENTS         = 64
    EXECUTION_COMMANDS      = %w[continue next stepIn stepOut stepBack reverseContinue pause restartFrame goto terminate terminateThreads restart disconnect]

    @argv : Array(String)
    @cwd : Path
    @limits : Limits
    @session_id : String
    @transport : Transport?
    @mutex : Mutex
    @lifecycle_mutex : Mutex
    @outgoing_mutex : Mutex
    @pending : Hash(Int32, PendingRequest)
    @results : Hash(Int32, RequestResult)
    @events : Array(Message)
    @discarded_terminal_events : Array(TerminalEventCertificate)
    @tombstones : Hash(Int32, ExpiredRequest)
    @decoded_queue_items : Int32
    @decoded_queue_bytes : Int64
    @next_client_sequence : Int64
    @next_adapter_sequence : Int64
    @initialize_ticket : Int32?
    @initialize_succeeded : Bool
    @initialized_event_seen : Bool
    @execution_sequence : Int32?
    @failure_message : String?
    @started : Bool
    @starting : Bool
    @closed : Bool
    @close_started : Bool
    @deadline_done : Channel(Nil)
    @deadline_retired : Bool
    @deadline_started : Bool
    @failure_cleanup_started : Bool
    @failure_cleanup_retired : Bool

    def initialize(argv : Enumerable(String), @cwd : Path,
                   @limits : Limits = Limits.new)
      @argv = argv.map(&.dup)
      raise ArgumentError.new("DAP adapter argv is empty") if @argv.empty? || @argv.first.empty?
      @mutex = Mutex.new
      @lifecycle_mutex = Mutex.new
      @outgoing_mutex = Mutex.new
      @session_id = Random::Secure.hex(16)
      @transport = nil
      @pending = {} of Int32 => PendingRequest
      @results = {} of Int32 => RequestResult
      @events = [] of Message
      @discarded_terminal_events = [] of TerminalEventCertificate
      @tombstones = {} of Int32 => ExpiredRequest
      @decoded_queue_items = 0
      @decoded_queue_bytes = 0_i64
      @next_client_sequence = 1_i64
      @next_adapter_sequence = 1_i64
      @initialize_ticket = nil
      @initialize_succeeded = false
      @initialized_event_seen = false
      @execution_sequence = nil
      @failure_message = nil
      @started = false
      @starting = false
      @closed = false
      @close_started = false
      @deadline_done = Channel(Nil).new(1)
      @deadline_retired = true
      @deadline_started = false
      @failure_cleanup_started = false
      @failure_cleanup_retired = true
    end

    # Starts the adapter without sending initialize, launch, or any other DAP
    # request. argv is passed directly to Process.new; no shell is involved.
    def start : Nil
      @lifecycle_mutex.synchronize do
        @mutex.synchronize do
          raise ClientError.new("DAP client is closed") if @closed
          raise ClientError.new("DAP client already started or starting") if @started || @starting
          @starting = true
        end

        transport = Transport.new(
          @argv, @cwd, @limits,
          ->handle_message(Message),
          ->reserve_decoded(Int32, Int64),
          ->release_decoded(Int64),
          ->transport_failed(String)
        )
        @transport = transport
        begin
          transport.start
          startup_failure = @mutex.synchronize do
            @starting = false
            @started = @failure_message.nil?
            @deadline_retired = !@started
            @failure_message
          end
          raise ClientError.new("DAP adapter failed during startup") if startup_failure
          @mutex.synchronize { @deadline_started = true }
          spawn(name: "dap-deadlines") { deadline_loop }
        rescue ex
          @mutex.synchronize do
            @starting = false
            @started = false
            @deadline_retired = true
          end
          signal_deadline_done
          transport.close
          raise ClientError.new("could not start DAP client (#{ex.class})")
        end
      end
    end

    def initialize_adapter(client_id : String, adapter_id : String,
                           timeout : Time::Span = DEFAULT_REQUEST_TIMEOUT,
                           *, supports_variable_paging : Bool = false,
                           supports_variable_type : Bool = false) : Ticket
      unless valid_identifier?(client_id) && valid_identifier?(adapter_id)
        raise ArgumentError.new("DAP initialize identifiers must be bounded non-empty strings")
      end
      reserved_sequence = nil.as(Int32?)
      @mutex.synchronize do
        raise ClientError.new("DAP initialize already requested") if @initialize_ticket || @next_client_sequence > Int32::MAX
        @initialize_ticket = @next_client_sequence.to_i32
        reserved_sequence = @initialize_ticket
      end

      arguments = JSON.parse({
        "clientID"           => client_id,
        "adapterID"          => adapter_id,
        "locale"             => "en-US",
        "linesStartAt1"      => true,
        "columnsStartAt1"    => true,
        "pathFormat"         => "path",
        "clientCapabilities" => {} of String => String,
      }.to_json)
      if supports_variable_paging
        arguments.as_h["supportsVariablePaging"] = JSON::Any.new(true)
      end
      if supports_variable_type
        arguments.as_h["supportsVariableType"] = JSON::Any.new(true)
      end
      request_internal("initialize", arguments, timeout, execution: false, initializing: true)
    rescue ex
      if sequence = reserved_sequence
        @mutex.synchronize do
          if @initialize_ticket == sequence && !@initialize_succeeded &&
             !@pending.has_key?(sequence) && !@results.has_key?(sequence)
            @initialize_ticket = nil
          end
        end
      end
      raise ex
    end

    def request(command : String, arguments : JSON::Any? = nil,
                timeout : Time::Span = DEFAULT_REQUEST_TIMEOUT) : Ticket
      raise ClientError.new("initialize must use initialize_adapter") if command == "initialize"
      raise ClientError.new("execution commands must use request_execution") if execution_command?(command)
      request_internal(command, arguments, timeout, execution: false, initializing: false)
    end

    # Execution requests share one serialized slot. A timed-out request releases
    # the slot but its sequence remains tombstoned so a bounded late response
    # can be consumed without being mistaken for a later execution result.
    def request_execution(command : String, arguments : JSON::Any? = nil,
                          timeout : Time::Span = DEFAULT_REQUEST_TIMEOUT) : Ticket
      unless execution_command?(command)
        raise ClientError.new("unsupported DAP execution command")
      end
      request_internal(command, arguments, timeout, execution: true, initializing: false)
    end

    # Polling consumes a result exactly once and releases the client's logical
    # decoded/wire reservation. The returned decoded Message is caller-owned.
    def poll_result(ticket : Ticket) : RequestResult?
      raise ClientError.new("DAP ticket belongs to another client session") unless ticket.belongs_to?(@session_id)
      result = @mutex.synchronize { @results.delete(ticket.sequence) }
      release_message(result.response.not_nil!) if result && result.response
      result
    end

    def poll_events(limit : Int32 = MAX_POLL_EVENTS) : Array(Message)
      raise ArgumentError.new("DAP event poll limit out of range") unless limit.in?(1..MAX_POLL_EVENTS)
      messages, certificates = @mutex.synchronize do
        count = Math.min(limit, @events.size)
        queued_messages = @events.shift(count)
        remaining = limit - queued_messages.size
        event_certificates = @discarded_terminal_events.shift(Math.min(remaining, @discarded_terminal_events.size))
        {queued_messages, event_certificates}
      end
      messages.each { |message| release_message(message) }
      certificates.each { |certificate| messages << certificate.to_message }
      messages
    end

    def failure_message : String?
      @mutex.synchronize { @failure_message }
    end

    def failed? : Bool
      !failure_message.nil?
    end

    def owned_adapter_pid : Int64?
      @transport.try(&.process_pid)
    end

    def session_id : String
      @session_id.dup
    end

    def resource_snapshot : ResourceSnapshot
      decoded_items, decoded_bytes = @mutex.synchronize do
        {@decoded_queue_items, @decoded_queue_bytes}
      end
      transport_counts = if transport = @transport
                           transport.resource_counts
                         else
                           {
                             inbound_wire_bytes:     0_i64,
                             writer_queue_bytes:     0_i64,
                             writer_queue_frames:    0,
                             active_writer_io_tasks: 0,
                           }
                         end
      ResourceSnapshot.new(
        transport_counts[:inbound_wire_bytes], decoded_items, decoded_bytes,
        transport_counts[:writer_queue_bytes], transport_counts[:writer_queue_frames],
        transport_counts[:active_writer_io_tasks]
      )
    end

    def owned_adapter_alive? : Bool
      @transport.try(&.process_alive?) || false
    end

    def transport_retired? : Bool
      @transport.try(&.retired?) || false
    end

    def retired? : Bool
      closed = @mutex.synchronize { @closed && @deadline_retired && @failure_cleanup_retired }
      return false unless closed
      @transport ? transport_retired? : true
    end

    def close : Nil
      @lifecycle_mutex.synchronize do
        should_close = @outgoing_mutex.synchronize do
          @mutex.synchronize do
            if @close_started
              nil
            else
              @close_started = true
              @closed = true
              @pending.each do |sequence, _pending|
                @results[sequence] = RequestResult.new(Ticket.new(sequence, @session_id), ResultStatus::Cancelled,
                  nil, "DAP client closed; target exit is unknown")
              end
              @pending.clear
              @execution_sequence = nil
              queued = @events.dup
              @results.each_value do |result|
                queued << result.response.not_nil! if result.response
              end
              capture_discarded_terminal_events
              normalize_discarded_disconnect_results
              @events.clear
              @results.keys.each do |sequence|
                @results.delete(sequence) if @results[sequence].response
              end
              queued
            end
          end
        end

        if queued = should_close
          queued.each { |message| release_message(message) }
          @transport.try(&.close)
          if @deadline_started
            select
            when @deadline_done.receive
            when timeout(1.second)
            end
          else
            @mutex.synchronize { @deadline_retired = true }
            signal_deadline_done
          end
        end
      end
    end

    private def request_internal(command : String, arguments : JSON::Any?, timeout : Time::Span,
                                 *, execution : Bool, initializing : Bool) : Ticket
      unless timeout > Time::Span.zero && timeout <= MAX_REQUEST_TIMEOUT
        raise ArgumentError.new("DAP request timeout must be positive and at most five minutes")
      end
      unless command.matches?(/\A[A-Za-z][A-Za-z0-9]{0,63}\z/)
        raise ArgumentError.new("DAP command is invalid")
      end
      if arguments && !arguments.as_h?
        raise ArgumentError.new("DAP request arguments must be an object")
      end

      sequence = nil.as(Int32?)
      accepted = @outgoing_mutex.synchronize do
        candidate = @mutex.synchronize do
          raise ClientError.new("DAP client is not started") unless @started && !@starting
          raise ClientError.new("DAP client is closed") if @closed
          raise ClientError.new(@failure_message.not_nil!) if @failure_message
          if @pending.size + @results.size >= @limits.max_decoded_queue_items
            raise ClientError.new("DAP ticket result queue budget exceeded")
          end
          if !initializing && !@initialize_succeeded
            raise ClientError.new("DAP initialize must succeed before requests")
          end
          if command == "configurationDone" && (!@initialize_succeeded || !@initialized_event_seen)
            raise ClientError.new("DAP initialized event must arrive before configurationDone")
          end
          if initializing && @initialize_ticket != @next_client_sequence.to_i32
            raise ClientError.new("DAP initialize ticket changed")
          end
          if execution && @execution_sequence
            raise ClientError.new("another DAP execution request is still in flight")
          end
          if @pending.size >= @limits.max_pending_requests
            raise ClientError.new("DAP pending request budget exceeded")
          end
          raise ClientError.new("DAP client sequence exhausted") if @next_client_sequence > Int32::MAX
          @next_client_sequence.to_i32
        end
        sequence = candidate

        payload_hash = {
          "seq"     => JSON::Any.new(candidate),
          "type"    => JSON::Any.new("request"),
          "command" => JSON::Any.new(command),
        }
        payload_hash["arguments"] = arguments if arguments
        frame = Protocol.encode_frame(JSON::Any.new(payload_hash), max_message_bytes: @limits.max_message_bytes)
        transport = @transport || raise ClientError.new("DAP transport unavailable")

        @mutex.synchronize do
          raise ClientError.new("DAP client is closed") if @closed
          raise ClientError.new(@failure_message.not_nil!) if @failure_message
          raise ClientError.new("DAP client sequence changed before enqueue") if @next_client_sequence != candidate
          @next_client_sequence += 1
          @pending[candidate] = PendingRequest.new(command, Time.instant + timeout, execution)
          @execution_sequence = candidate if execution
        end

        transport.enqueue(frame)
      end

      unless accepted
        rollback_pending(sequence.not_nil!)
        transport_failed("DAP writer queue budget exceeded or transport closed")
        raise ClientError.new("DAP writer queue budget exceeded or transport closed")
      end
      Ticket.new(sequence.not_nil!, @session_id)
    rescue ex : ProtocolError
      rollback_pending(sequence.not_nil!) if sequence
      raise ClientError.new(ex.message || "invalid DAP request")
    rescue ex : ClientError
      rollback_pending(sequence.not_nil!) if sequence
      raise ex
    end

    private def rollback_pending(sequence : Int32) : Nil
      released = @mutex.synchronize do
        @pending.delete(sequence)
        result = @results.delete(sequence)
        @execution_sequence = nil if @execution_sequence == sequence
        result.try(&.response)
      end
      release_message(released.not_nil!) if released
    end

    private def handle_message(message : Message) : Nil
      retained = false
      reverse_request = false
      protocol_failure = nil.as(String?)
      @mutex.synchronize do
        if @closed || @failure_message
          protocol_failure = "DAP message received after client shutdown"
        elsif message.sequence.to_i64 != @next_adapter_sequence
          protocol_failure = "DAP adapter sequence is not monotonic"
        else
          @next_adapter_sequence += 1
          case message.kind
          when "response"
            request_sequence = message.request_sequence.not_nil!
            if pending = @pending[request_sequence]?
              if pending.command != message.command
                protocol_failure = "DAP response command does not match its request"
              else
                @pending.delete(request_sequence)
                if request_sequence == @initialize_ticket
                  @initialize_succeeded = message.success == true
                end
                @execution_sequence = nil if @execution_sequence == request_sequence
                status = message.success ? ResultStatus::Success : ResultStatus::AdapterError
                result_message = message.success ? nil : (message.message || "DAP adapter rejected request")
                @results[request_sequence] = RequestResult.new(Ticket.new(request_sequence, @session_id), status,
                  message, result_message)
                retained = true
              end
            elsif expired = @tombstones.delete(request_sequence)
              if expired.command != message.command
                protocol_failure = "late DAP response command does not match its timed-out request"
              end
            else
              protocol_failure = "DAP response has unknown or duplicate request_seq"
            end
          when "event"
            @initialized_event_seen = true if message.event == "initialized"
            if @events.size >= @limits.max_decoded_queue_items
              protocol_failure = "DAP event queue budget exceeded"
            else
              @events << message
              retained = true
            end
          when "request"
            reverse_request = true
          else
            protocol_failure = "unsupported DAP message kind"
          end
        end
      end

      if protocol_failure
        release_message(message)
        transport_failed(protocol_failure)
        return
      end

      if reverse_request
        reject_reverse_request(message)
        release_message(message)
      elsif !retained
        release_message(message)
      end
    rescue
      release_message(message) unless retained
      transport_failed("DAP client dispatch failed")
    end

    private def reject_reverse_request(message : Message) : Nil
      failure = nil.as(String?)
      accepted = @outgoing_mutex.synchronize do
        sequence = @mutex.synchronize do
          if @closed || @failure_message
            nil
          elsif @next_client_sequence > Int32::MAX
            failure = "DAP response sequence exhausted while rejecting adapter request"
            nil
          else
            @next_client_sequence.to_i32
          end
        end
        if sequence
          response = JSON::Any.new({
            "seq"         => JSON::Any.new(sequence),
            "type"        => JSON::Any.new("response"),
            "request_seq" => JSON::Any.new(message.sequence),
            "command"     => JSON::Any.new(message.command.not_nil!),
            "success"     => JSON::Any.new(false),
            "message"     => JSON::Any.new("unsupported adapter request"),
          })
          frame = Protocol.encode_frame(response, max_message_bytes: @limits.max_message_bytes)
          can_enqueue = @mutex.synchronize do
            if @closed || @failure_message
              false
            elsif @next_client_sequence != sequence
              failure = "DAP response sequence changed while rejecting adapter request"
              false
            else
              @next_client_sequence += 1
              true
            end
          end
          result = false
          if can_enqueue
            result = @transport.try(&.enqueue(frame)) || false
            failure = "DAP writer queue exhausted while rejecting adapter request" unless result
          end
          result
        else
          false
        end
      end
      transport_failed(failure) if failure
    rescue
      transport_failed("could not reject unsupported adapter request")
    end

    private def reserve_decoded(_wire_bytes : Int32, decoded_bytes : Int64) : Nil
      @mutex.synchronize do
        if @decoded_queue_items + 1 > @limits.max_decoded_queue_items
          raise ProtocolError.new("DAP decoded queue item budget exceeded")
        end
        if @decoded_queue_bytes + decoded_bytes > @limits.max_decoded_queue_bytes
          raise ProtocolError.new("DAP decoded queue byte budget exceeded")
        end
        @decoded_queue_items += 1
        @decoded_queue_bytes += decoded_bytes
      end
    end

    private def release_decoded(decoded_bytes : Int64) : Nil
      @mutex.synchronize do
        @decoded_queue_items -= 1
        @decoded_queue_bytes -= decoded_bytes
        @decoded_queue_items = 0 if @decoded_queue_items < 0
        @decoded_queue_bytes = 0_i64 if @decoded_queue_bytes < 0
      end
    end

    private def release_message(message : Message) : Nil
      @transport.try(&.release_wire(message.wire_bytes))
      release_decoded(message.decoded_charge)
    end

    private def transport_failed(message : String) : Nil
      schedule_cleanup = @mutex.synchronize do
        if @failure_message || @closed
          false
        else
          @failure_message = message.byte_slice(0, 512) || "DAP transport failed"
          @pending.each_key do |sequence|
            @results[sequence] = RequestResult.new(Ticket.new(sequence, @session_id), ResultStatus::TransportError,
              nil, "DAP transport failed; target exit is unknown")
          end
          @pending.clear
          @execution_sequence = nil
          @tombstones.clear
          unless @failure_cleanup_started
            @failure_cleanup_started = true
            @failure_cleanup_retired = false
            true
          else
            false
          end
        end
      end
      return unless schedule_cleanup

      begin
        spawn(name: "dap-client-failure-cleanup") do
          begin
            close
          rescue
          ensure
            @mutex.synchronize { @failure_cleanup_retired = true }
          end
        end
      rescue
        @mutex.synchronize { @failure_cleanup_retired = true }
        close
      end
    end

    # Called only under @mutex by close, immediately before queued messages are
    # released. These certificates include only terminal events actually in
    # @events at that instant, and are bounded to one `terminated` and one
    # well-formed `exited` event.
    private def capture_discarded_terminal_events : Nil
      @events.each do |message|
        next unless message.kind == "event"
        event_name = message.event
        next unless event_name
        event_name = event_name.not_nil!
        next unless event_name == "terminated" || event_name == "exited"
        next if @discarded_terminal_events.any? { |certificate| certificate.event == event_name }

        exit_code = nil.as(Int32?)
        if event_name == "exited"
          raw_exit_code = message.body.try(&.as_h?).try { |body| body["exitCode"]?.try(&.as_i?) }
          next unless raw_exit_code && raw_exit_code.not_nil!.in?(Int32::MIN.to_i64..Int32::MAX.to_i64)
          exit_code = raw_exit_code.not_nil!.to_i32
        end
        @discarded_terminal_events << TerminalEventCertificate.new(message.sequence, event_name, exit_code)
      end
    end

    # A successful disconnect response is already correlated by handle_message.
    # Replace only that discarded response with its ticket result so polling
    # remains one-shot while response JSON and its queue charge are released.
    private def normalize_discarded_disconnect_results : Nil
      acknowledged = @results.compact_map do |sequence, result|
        response = result.response
        if result.success? && result.ticket.belongs_to?(@session_id) && response &&
           response.not_nil!.kind == "response" && response.not_nil!.command == "disconnect" &&
           response.not_nil!.success == true && response.not_nil!.request_sequence == sequence
          sequence
        end
      end
      acknowledged.each do |sequence|
        result = @results[sequence]
        @results[sequence] = RequestResult.new(result.ticket, ResultStatus::Success)
      end
    end

    private def expire_due_requests : Nil
      expired = [] of Tuple(Int32, PendingRequest)
      overflow = false
      now = Time.instant
      @mutex.synchronize do
        @pending.each do |sequence, pending|
          expired << {sequence, pending} if pending.deadline <= now
        end
        expired.each do |sequence, pending|
          next unless @pending.has_key?(sequence)
          if @tombstones.size >= @limits.max_timeout_tombstones
            overflow = true
            next
          end
          @pending.delete(sequence)
          @tombstones[sequence] = ExpiredRequest.new(pending.command)
          @results[sequence] = RequestResult.new(Ticket.new(sequence, @session_id), ResultStatus::TimedOut,
            nil, "DAP request timed out; target exit is unknown")
          @execution_sequence = nil if @execution_sequence == sequence
        end
      end
      transport_failed("DAP timed-out response tracking budget exceeded") if overflow
    end

    private def deadline_loop : Nil
      loop do
        stop = @mutex.synchronize { @closed }
        break if stop
        expire_due_requests
        sleep DEADLINE_POLL_INTERVAL
      end
    rescue
      transport_failed("DAP request deadline monitor failed")
    ensure
      @mutex.synchronize { @deadline_retired = true }
      signal_deadline_done
    end

    private def valid_identifier?(value : String) : Bool
      !value.empty? && value.bytesize <= 128 && value.valid_encoding? &&
        !value.includes?('\0')
    end

    private def execution_command?(command : String) : Bool
      EXECUTION_COMMANDS.includes?(command)
    end

    private def signal_deadline_done : Nil
      select
      when @deadline_done.send(nil)
      else
      end
    rescue
    end
  end
end
