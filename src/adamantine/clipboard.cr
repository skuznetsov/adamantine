module Adamantine
  # Clipboard access is deliberately kept behind this small boundary.  The
  # editor owns the in-memory value; a backend is only a best-effort bridge to
  # another process (or a test double).
  module Clipboard
    # Match the editor's maximum file size while still keeping helper input
    # and output explicitly bounded.
    MAX_BYTES       = 16 * 1024 * 1024
    DEFAULT_TIMEOUT = 250.milliseconds

    enum Status
      Success
      Unsupported
      Failed
      TooLarge
      InvalidEncoding
      Timeout
    end

    struct Result
      getter status : Status
      getter text : String?

      def initialize(@status : Status, @text : String? = nil)
      end

      def self.success(text : String? = nil) : self
        new(Status::Success, text)
      end

      def self.unsupported : self
        new(Status::Unsupported)
      end

      def self.failed : self
        new(Status::Failed)
      end

      def self.too_large : self
        new(Status::TooLarge)
      end

      def self.invalid_encoding : self
        new(Status::InvalidEncoding)
      end

      def self.timeout : self
        new(Status::Timeout)
      end

      def success? : Bool
        @status == Status::Success
      end

      def ok? : Bool
        success?
      end

      def unsupported? : Bool
        @status == Status::Unsupported
      end
    end

    abstract class Backend
      abstract def read : Result
      abstract def write(text : String) : Result

      def close : Nil
      end
    end

    class UnsupportedBackend < Backend
      def read : Result
        Result.unsupported
      end

      def write(text : String) : Result
        _ = text
        Result.unsupported
      end
    end

    # A fixed-command backend.  It never invokes a shell and captures at most
    # MAX_BYTES from the helper.  The default commands intentionally use
    # absolute paths; tests may provide temporary executable paths explicitly.
    class SystemBackend < Backend
      UTF8_ENV = {"LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8"}

      getter write_command : String
      getter read_command : String
      getter timeout : Time::Span
      getter max_bytes : Int32

      private record ActiveHelper, process : Process, finished : Channel(Nil)

      @active_mutex : Mutex = Mutex.new
      @active_helpers : Array(ActiveHelper) = [] of ActiveHelper
      @closed : Bool = false

      def self.default : Backend
        if executable?("/usr/bin/pbcopy") && executable?("/usr/bin/pbpaste")
          new
        else
          UnsupportedBackend.new
        end
      end

      def initialize(
        @write_command : String = "/usr/bin/pbcopy",
        @read_command : String = "/usr/bin/pbpaste",
        write_args : Array(String) = [] of String,
        read_args : Array(String) = [] of String,
        @timeout : Time::Span = DEFAULT_TIMEOUT,
        @max_bytes : Int32 = MAX_BYTES,
      )
        raise ArgumentError.new("clipboard output limit must be positive") unless @max_bytes > 0
        raise ArgumentError.new("clipboard timeout must be positive") unless @timeout > Time::Span.zero
        @write_args = write_args.dup
        @read_args = read_args.dup
      end

      def read : Result
        return Result.failed if closed?
        return Result.unsupported unless self.class.executable?(@read_command)
        invoke(@read_command, @read_args, nil, capture_output: true)
      end

      def write(text : String) : Result
        return Result.failed if closed?
        return Result.too_large if text.bytesize > @max_bytes
        return Result.invalid_encoding unless text.valid_encoding?
        return Result.unsupported unless self.class.executable?(@write_command)
        invoke(@write_command, @write_args, text, capture_output: false)
      end

      def close : Nil
        helpers = @active_mutex.synchronize do
          @closed = true
          @active_helpers.dup
        end
        helpers.each { |helper| terminate(helper.process) }
        helpers.each { |helper| helper.finished.receive? }
      end

      def self.executable?(path : String) : Bool
        info = File.info(path)
        info.file? && File::Info.executable?(path)
      rescue File::NotFoundError | File::AccessDeniedError | IO::Error
        false
      end

      private def invoke(command : String, args : Array(String), input : String?, *, capture_output : Bool) : Result
        process = begin
          Process.new(
            command,
            args,
            env: UTF8_ENV,
            clear_env: true,
            input: input ? Process::Redirect::Pipe : Process::Redirect::Close,
            output: capture_output ? Process::Redirect::Pipe : Process::Redirect::Close,
            error: Process::Redirect::Close
          )
        rescue
          return Result.failed
        end

        helper = ActiveHelper.new(process, Channel(Nil).new)
        unless register(helper)
          terminate(process)
          process.wait rescue nil
          return Result.failed
        end

        completed = Channel(Result).new(1)
        spawn(name: "clipboard-helper") do
          result = begin
            execute(process, input, capture_output)
          rescue
            Result.failed
          end
          completed.send(result) rescue nil
        ensure
          unregister(helper)
          helper.finished.close
        end

        select
        when result = completed.receive
          result
        when timeout(@timeout)
          terminate(process)
          helper.finished.receive?
          Result.timeout
        end
      end

      private def execute(process : Process, input : String?, capture_output : Bool) : Result
        output_result = Result.success
        reaped = false
        begin
          if input
            io = process.input
            return Result.failed unless io
            io.write(input.to_slice)
            io.close
          end

          if capture_output
            output = process.output
            return Result.failed unless output
            output_result = read_bounded(output, process)
            output.close
          end

          status = process.wait
          reaped = true
          return output_result unless output_result.success?
          return Result.failed unless status.success?
          output_result
        ensure
          if input
            process.input.close rescue nil
          end
          if capture_output
            process.output.close rescue nil
          end
          unless reaped
            terminate(process)
            process.wait rescue nil
          end
        end
      end

      private def read_bounded(output : IO, process : Process) : Result
        memory = IO::Memory.new
        chunk = Bytes.new(16 * 1024)
        loop do
          count = output.read(chunk)
          break if count == 0
          if memory.size + count > @max_bytes
            terminate(process)
            return Result.too_large
          end
          memory.write(chunk[0, count])
        end

        text = memory.to_s
        return Result.invalid_encoding unless text.valid_encoding?
        Result.success(text)
      end

      private def terminate(process : Process) : Nil
        process.terminate(graceful: false)
      rescue
      end

      private def register(helper : ActiveHelper) : Bool
        @active_mutex.synchronize do
          return false if @closed
          @active_helpers << helper
          true
        end
      end

      private def unregister(helper : ActiveHelper) : Nil
        @active_mutex.synchronize { @active_helpers.delete(helper) }
      end

      private def closed? : Bool
        @active_mutex.synchronize { @closed }
      end
    end

    # Keeps at most one read and one write helper operation, plus one latest
    # pending request for each direction, alive.
    # The value is updated before an external write is attempted, so a failed
    # helper can never make an editor cut lose its copied text.
    class Service
      getter backend : Backend

      private struct WriteRequest
        getter text : String
        getter generation : UInt64

        def initialize(@text : String, @generation : UInt64)
        end
      end

      @mutex : Mutex = Mutex.new
      @internal_value : String? = nil
      @pending_write : WriteRequest? = nil
      @write_running : Bool = false
      @write_generation : UInt64 = 0_u64
      @external_write_failed : Bool = false
      @pending_read : Proc(Result, Nil)? = nil
      @read_running : Bool = false
      @closed : Bool = false

      def initialize(@backend : Backend, @on_result : Proc(Result, Nil)? = nil)
      end

      def value : String?
        @mutex.synchronize { @internal_value }
      end

      def pending_write? : Bool
        @mutex.synchronize { @write_running || !@pending_write.nil? }
      end

      def external_sync_failed? : Bool
        @mutex.synchronize { @external_write_failed }
      end

      def remember(text : String) : Bool
        return false if text.empty?
        return false if text.bytesize > MAX_BYTES
        return false unless text.valid_encoding?

        start_worker = false
        @mutex.synchronize do
          return false if @closed
          @internal_value = text
          @write_generation &+= 1_u64
          @external_write_failed = false
          @pending_write = WriteRequest.new(text, @write_generation)
          unless @write_running
            @write_running = true
            start_worker = true
          end
        end
        spawn(name: "clipboard-write") { write_loop } if start_worker
        true
      end

      def read_async(&callback : Result -> Nil) : Bool
        start_worker = false
        @mutex.synchronize do
          return false if @closed
          @pending_read = callback
          unless @read_running
            @read_running = true
            start_worker = true
          end
        end
        spawn(name: "clipboard-read") { read_loop } if start_worker
        true
      end

      def close : Nil
        @mutex.synchronize do
          @closed = true
          @pending_write = nil
          @pending_read = nil
        end
        @backend.close
      end

      private def write_loop : Nil
        loop do
          request = @mutex.synchronize do
            next_request = @pending_write
            @pending_write = nil
            next_request
          end
          break unless request

          result = begin
            @backend.write(request.text)
          rescue
            Result.failed
          end
          @mutex.synchronize do
            if request.generation == @write_generation
              @external_write_failed = !result.success?
            end
          end
          notify(result)
        end

        restart = @mutex.synchronize do
          @write_running = false
          if !@closed && @pending_write
            @write_running = true
            true
          else
            false
          end
        end
        spawn(name: "clipboard-write") { write_loop } if restart
      end

      private def read_loop : Nil
        loop do
          callback = @mutex.synchronize do
            next_callback = @pending_read
            @pending_read = nil
            next_callback
          end
          break unless callback

          result = begin
            @backend.read
          rescue
            Result.failed
          end
          notify(result)
          should_call = @mutex.synchronize { !@closed }
          if should_call
            begin
              callback.call(result)
            rescue
            end
          end
        end

        restart = @mutex.synchronize do
          @read_running = false
          if !@closed && @pending_read
            @read_running = true
            true
          else
            false
          end
        end
        spawn(name: "clipboard-read") { read_loop } if restart
      end

      private def notify(result : Result) : Nil
        should_call = @mutex.synchronize { !@closed }
        return unless should_call
        begin
          @on_result.try &.call(result)
        rescue
        end
      end
    end
  end
end
