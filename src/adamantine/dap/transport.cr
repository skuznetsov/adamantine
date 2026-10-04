require "json"

require "./protocol"

module Adamantine::Dap
  # Owns exactly one adapter Process and its stdio pipes. The writer is the
  # only fiber that writes protocol frames; the reader performs framing and
  # dispatches each decoded message synchronously into the bounded client.
  class Transport
    WRITE_DEADLINE       = 2.seconds
    TERM_GRACE           = 250.milliseconds
    KILL_GRACE           = 1.second
    ACTOR_JOIN_GRACE     = 1.second
    FRAME_CHECK_INTERVAL = 10.milliseconds

    alias OnMessage = Proc(Message, Nil)
    alias ReserveDecoded = Proc(Int32, Int64, Nil)
    alias ReleaseDecoded = Proc(Int64, Nil)
    alias OnFailure = Proc(String, Nil)

    getter process_pid : Int64?

    @argv : Array(String)
    @cwd : Path
    @limits : Limits
    @on_message : OnMessage
    @reserve_decoded : ReserveDecoded
    @release_decoded : ReleaseDecoded
    @on_failure : OnFailure
    @process : Process?
    @stdin : IO?
    @stdout : IO?
    @decoder : FrameDecoder?
    @writer_queue : Array(String)
    @writer_bytes : Int64
    @writer_frames : Int32
    @active_frame_bytes : Int32
    @writer_io_tasks : Int32
    @writer_wakeup : Channel(Bool)
    @reader_done : Channel(Nil)
    @writer_done : Channel(Nil)
    @close_done : Channel(Nil)
    @reaper_done : Channel(Nil)
    @frame_watchdog_done : Channel(Nil)
    @state_mutex : Mutex
    @queue_mutex : Mutex
    @wire_bytes : Int64
    @started : Bool
    @closing : Bool
    @writer_accepting : Bool
    @closed : Bool
    @failure_reported : Bool
    @reader_retired : Bool
    @writer_retired : Bool
    @reader_spawned : Bool
    @writer_spawned : Bool
    @reaper_started : Bool
    @reaper_retired : Bool
    @process_reaped : Bool
    @frame_watchdog_spawned : Bool
    @frame_watchdog_retired : Bool

    def initialize(argv : Enumerable(String), @cwd : Path, @limits : Limits,
                   @on_message : OnMessage, @reserve_decoded : ReserveDecoded,
                   @release_decoded : ReleaseDecoded, @on_failure : OnFailure)
      @argv = argv.map(&.dup)
      raise ArgumentError.new("DAP adapter argv is empty") if @argv.empty? || @argv.first.empty?
      raise ArgumentError.new("DAP adapter argv exceeds limits") if @argv.size > 256 || @argv.any? { |part| part.bytesize > 32 * 1024 }
      @process = nil
      @stdin = nil
      @stdout = nil
      @decoder = nil
      @writer_queue = [] of String
      @writer_bytes = 0_i64
      @writer_frames = 0
      @active_frame_bytes = 0
      @writer_io_tasks = 0
      @writer_wakeup = Channel(Bool).new(1)
      @reader_done = Channel(Nil).new(1)
      @writer_done = Channel(Nil).new(1)
      @close_done = Channel(Nil).new(1)
      @reaper_done = Channel(Nil).new(1)
      @frame_watchdog_done = Channel(Nil).new(1)
      @state_mutex = Mutex.new
      @queue_mutex = Mutex.new
      @wire_bytes = 0_i64
      @started = false
      @closing = false
      @writer_accepting = false
      @closed = false
      @failure_reported = false
      @reader_retired = true
      @writer_retired = true
      @reader_spawned = false
      @writer_spawned = false
      @reaper_started = false
      @reaper_retired = true
      @process_reaped = true
      @frame_watchdog_spawned = false
      @frame_watchdog_retired = true
      @process_pid = nil
    end

    def start : Nil
      @state_mutex.synchronize do
        raise ClientError.new("DAP transport already started") if @started
        raise ClientError.new("DAP transport is closed") if @closed
        process = Process.new(@argv, chdir: @cwd.to_s,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Close)
        @process = process
        @stdin = process.input
        @stdout = process.output
        @process_pid = process.pid
        @started = true
        @reader_retired = false
        @writer_retired = false
        @reaper_started = false
        @reaper_retired = false
        @process_reaped = false
      end

      start_reaper(@process.not_nil!)

      @decoder = FrameDecoder.new(
        max_header_bytes: @limits.max_header_bytes,
        max_message_bytes: @limits.max_message_bytes,
        max_json_depth: @limits.max_json_depth,
        max_json_tokens: @limits.max_json_tokens,
        wire_delta: ->wire_delta(Int32),
        before_decode: ->reserve_message(Int32, Int64),
        release_reservation: ->release_message(Int64),
        on_message: ->dispatch_message(Message)
      )
      spawn(name: "dap-reader") { reader_loop }
      @state_mutex.synchronize { @reader_spawned = true }
      spawn(name: "dap-writer") { writer_loop }
      @state_mutex.synchronize { @writer_spawned = true }
      @queue_mutex.synchronize { @writer_accepting = true }
      @state_mutex.synchronize { @frame_watchdog_retired = false }
      begin
        spawn(name: "dap-frame-watchdog") { frame_watchdog_loop }
        @state_mutex.synchronize { @frame_watchdog_spawned = true }
      rescue ex
        @state_mutex.synchronize { @frame_watchdog_retired = true }
        @frame_watchdog_done.send(nil) rescue nil
        raise ex
      end
    rescue ex
      close
      raise ClientError.new("could not start DAP adapter (#{ex.class})")
    end

    # Enqueues a pre-encoded frame without blocking the caller. The configured
    # byte and frame ceilings include the frame currently being written.
    def enqueue(frame : String) : Bool
      return false if frame.empty? || frame.bytesize > @limits.max_message_bytes + @limits.max_header_bytes
      accepted = @queue_mutex.synchronize do
        next false if @closing || !@writer_accepting
        next false if @writer_frames >= @limits.max_writer_queue_frames
        next false if @writer_bytes + frame.bytesize > @limits.max_writer_queue_bytes
        @writer_queue << frame
        @writer_bytes += frame.bytesize
        @writer_frames += 1
        true
      end
      return false unless accepted

      # A one-slot signal is sufficient: the writer drains the array after
      # waking, so multiple queued frames may share the same wakeup.
      begin
        select
        when @writer_wakeup.send(true)
        else
        end
      rescue
        # close may race the wakeup after accepting the frame; close drains
        # accepted queue entries, and false tells the client to roll back its
        # pending ticket instead of treating it as sent.
        return false
      end
      true
    end

    def release_wire(bytes : Int32) : Nil
      @queue_mutex.synchronize do
        @wire_bytes -= bytes
        @wire_bytes = 0_i64 if @wire_bytes < 0
      end
    end

    def close : Nil
      process = nil.as(Process?)
      already_closed = @state_mutex.synchronize do
        if @closed
          true
        else
          @closed = true
          process = @process
          false
        end
      end
      if already_closed
        wait_actor(@close_done, TERM_GRACE + KILL_GRACE + ACTOR_JOIN_GRACE)
        return
      end

      @writer_wakeup.close
      begin
        process.try { |owned| start_reaper(owned) } unless @reaper_started
      rescue
      end
      @queue_mutex.synchronize do
        @closing = true
        @writer_accepting = false
        discarded_bytes = @writer_queue.sum(0_i64) { |frame| frame.bytesize.to_i64 }
        discarded_frames = @writer_queue.size
        @writer_queue.clear
        @writer_bytes -= discarded_bytes
        @writer_frames -= discarded_frames
        @writer_bytes = @active_frame_bytes.to_i64 if @writer_io_tasks > 0 && @writer_bytes < @active_frame_bytes
        @writer_frames = 1 if @writer_frames < 1 && @active_frame_bytes > 0
        @writer_frames = 0 if @active_frame_bytes == 0
      end

      if process
        begin
          @stdin.try(&.close)
        rescue
        end
        begin
          process.terminate(graceful: true) unless process.terminated?
        rescue
        end
        wait_for_process(process, TERM_GRACE)
        unless process_reaped?
          begin
            process.terminate(graceful: false)
          rescue
          end
          wait_for_process(process, KILL_GRACE)
        end
        begin
          @stdout.try(&.close)
        rescue
        end
        # Process#wait runs in the tracked reaper fiber. Close only waits a
        # bounded interval; a slow or uninterruptible child leaves retired?
        # false instead of extending shutdown without a deadline.
        wait_actor(@reaper_done, ACTOR_JOIN_GRACE)
      end

      wait_actor(@reader_done, ACTOR_JOIN_GRACE) if @state_mutex.synchronize { @reader_spawned }
      wait_actor(@writer_done, ACTOR_JOIN_GRACE) if @state_mutex.synchronize { @writer_spawned }
      wait_actor(@frame_watchdog_done, ACTOR_JOIN_GRACE) if @state_mutex.synchronize { @frame_watchdog_spawned }
      @close_done.send(nil) rescue nil
      @close_done.close
    end

    def retired? : Bool
      state_retired = @state_mutex.synchronize do
        @closed && @reader_retired && @writer_retired && @reaper_retired && @process_reaped && @frame_watchdog_retired
      end
      state_retired && @queue_mutex.synchronize { @writer_io_tasks == 0 }
    end

    def process_alive? : Bool
      @process.try { |process| process.exists? } || false
    rescue
      false
    end

    def resource_counts : NamedTuple(inbound_wire_bytes: Int64, writer_queue_bytes: Int64,
      writer_queue_frames: Int32, active_writer_io_tasks: Int32)
      @queue_mutex.synchronize do
        {
          inbound_wire_bytes:     @wire_bytes,
          writer_queue_bytes:     @writer_bytes,
          writer_queue_frames:    @writer_frames,
          active_writer_io_tasks: @writer_io_tasks,
        }
      end
    end

    private def reserve_message(wire_bytes : Int32, decoded_bytes : Int64) : Nil
      @reserve_decoded.call(wire_bytes, decoded_bytes)
    end

    private def release_message(decoded_bytes : Int64) : Nil
      @release_decoded.call(decoded_bytes)
    end

    private def dispatch_message(message : Message) : Nil
      @on_message.call(message)
    rescue
      # Client callbacks are expected to report their own failure and release
      # reservations. Do not let an exception cross the decoder boundary and
      # cause a second release of the same decoded message.
      report_failure("DAP message dispatch failed")
    end

    private def wire_delta(delta : Int32) : Nil
      failure = nil.as(String?)
      @queue_mutex.synchronize do
        if delta > 0 && @wire_bytes + delta > @limits.max_aggregate_inbound_bytes
          failure = "DAP aggregate inbound byte budget exceeded"
        else
          @wire_bytes += delta
        end
        if @wire_bytes < 0
          @wire_bytes = 0_i64
        end
      end
      raise ProtocolError.new(failure) if failure
    end

    private def reader_loop : Nil
      io = @stdout
      decoder = @decoder
      raise IO::Error.new unless io && decoder
      slice = Bytes.new(8192)
      loop do
        count = io.read(slice)
        break if count == 0
        decoder.feed(slice[0, count])
      end
      decoder.finish!
      report_failure("DAP adapter closed stdout (EOF)") unless @closing
    rescue ex : ProtocolError
      report_failure(ex.message || "DAP protocol error")
    rescue ex : IO::Error
      report_failure("DAP adapter reader I/O failure") unless @closing
    rescue
      report_failure("DAP adapter reader failed") unless @closing
    ensure
      @decoder.try(&.discard!)
      @state_mutex.synchronize { @reader_retired = true }
      @reader_done.send(nil) rescue nil
    end

    private def frame_watchdog_loop : Nil
      loop do
        break if @state_mutex.synchronize { @closed }
        if since = @decoder.try(&.incomplete_since)
          if Time.instant - since >= @limits.incomplete_frame_timeout
            report_failure("DAP incomplete frame completion deadline exceeded")
            break
          end
        end
        sleep FRAME_CHECK_INTERVAL
      end
    rescue
      report_failure("DAP frame deadline monitor failed")
    ensure
      @state_mutex.synchronize { @frame_watchdog_retired = true }
      @frame_watchdog_done.send(nil) rescue nil
    end

    private def writer_loop : Nil
      loop do
        signal = @writer_wakeup.receive?
        break unless signal
        loop do
          frame = @queue_mutex.synchronize do
            next nil if @closing
            value = @writer_queue.shift?
            @active_frame_bytes = value ? value.bytesize : 0
            value
          end
          break unless frame
          begin
            write_with_deadline(frame)
          rescue ex : IO::Error
            report_failure("DAP adapter stopped accepting protocol input")
            break
          rescue
            report_failure("DAP adapter writer failed")
            break
          end
        end
        break if @closing
      end
    rescue
      report_failure("DAP adapter writer failed") unless @closing
    ensure
      @state_mutex.synchronize { @writer_retired = true }
      @writer_done.send(nil) rescue nil
    end

    private def write_with_deadline(frame : String) : Nil
      io = @stdin || raise IO::Error.new
      result = Channel(Exception?).new(1)
      @queue_mutex.synchronize { @writer_io_tasks += 1 }
      begin
        spawn(name: "dap-writer-io") do
          error = nil.as(Exception?)
          begin
            io.write(frame.to_slice)
            io.flush
          rescue ex
            error = ex
          ensure
            release_writer_task(frame.bytesize)
          end
          result.send(error) rescue nil
        end
      rescue ex
        release_writer_task(frame.bytesize)
        raise ex
      end
      select
      when error = result.receive
        raise error if error
      when timeout(WRITE_DEADLINE)
        raise IO::Error.new("DAP adapter write deadline exceeded")
      end
    end

    private def release_writer_task(bytes : Int32) : Nil
      @queue_mutex.synchronize do
        @writer_bytes -= bytes
        @writer_frames -= 1
        @active_frame_bytes = 0
        @writer_io_tasks -= 1
        @writer_bytes = 0_i64 if @writer_bytes < 0
        @writer_frames = 0 if @writer_frames < 0
        @writer_io_tasks = 0 if @writer_io_tasks < 0
      end
    end

    private def report_failure(message : String) : Nil
      report = @state_mutex.synchronize do
        next false if @failure_reported || @closed
        @failure_reported = true
        true
      end
      return unless report
      begin
        @on_failure.call(message.byte_slice(0, 512) || "DAP transport failed")
      rescue
      ensure
        spawn(name: "dap-failure-cleanup") { close } rescue nil
      end
    rescue
    end

    private def wait_for_process(process : Process, duration : Time::Span) : Bool
      deadline = Time.instant + duration
      until process_reaped? || Time.instant >= deadline
        sleep 5.milliseconds
      end
      process_reaped?
    rescue
      false
    end

    private def process_reaped? : Bool
      @state_mutex.synchronize { @process_reaped }
    end

    private def start_reaper(process : Process) : Nil
      should_start = @state_mutex.synchronize do
        next false if @reaper_started
        @reaper_started = true
        @reaper_retired = false
        true
      end
      return unless should_start

      begin
        spawn(name: "dap-process-reaper") do
          begin
            process.wait
            @state_mutex.synchronize { @process_reaped = true }
          rescue
            # Keep process_reaped false: callers must not certify cleanup when
            # the owned process could not be joined.
          ensure
            @state_mutex.synchronize { @reaper_retired = true }
            @reaper_done.send(nil) rescue nil
          end
        end
      rescue ex
        @state_mutex.synchronize do
          @reaper_started = false
          @reaper_retired = true
        end
        raise ex
      end
    end

    private def wait_actor(channel : Channel(Nil), duration : Time::Span) : Nil
      select
      when channel.receive
      when timeout(duration)
      end
    rescue
    end
  end
end
