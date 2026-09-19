require "set"

require "./lsp_client"
require "./document_types"

module Adamantine
  # The recovery coordinator is intentionally a small adapter around the
  # existing LSP controller.  It owns replacement clients and the document
  # admission gate, while the controller remains responsible for requests and
  # UI publication.
  module LspRecoveryController
    @lsp_recovery_state : RecoveryState? = nil

    RECOVERY_ATTEMPTS = 3
    RECOVERY_BACKOFF  = [250.milliseconds, 500.milliseconds, 1.second]

    class RecoveryState
      getter mutex : Mutex
      getter queue : Channel(Nil)
      getter sync_entries : Hash(String, SyncEntry)
      property command : String?
      property args : Array(String)
      property epoch : UInt64
      property retry_count : Int32
      property phase : String
      property active : Lsp::Client?
      property candidate : Lsp::Client?
      property ready : Bool
      property resyncing : Bool
      property shutdown : Bool
      property worker_started : Bool
      property pending : RecoveryRequest?
      property root : Path

      def initialize
        @mutex = Mutex.new
        @queue = Channel(Nil).new(1)
        @sync_entries = {} of String => SyncEntry
        @command = nil
        @args = [] of String
        @epoch = 0_u64
        @retry_count = 0
        @phase = "disabled"
        @active = nil
        @candidate = nil
        @ready = false
        @resyncing = false
        @shutdown = false
        @worker_started = false
        @pending = nil
        @root = Path.new(".")
      end
    end

    class SyncEntry
      getter key : String
      property buffer : OpenBuffer
      property uri : String
      property language_id : String
      property opening : Bool
      property opened : Bool
      property closed : Bool
      property sending_change : Bool
      property sent_version : Int32
      property desired_version : Int32

      def initialize(@key : String, @buffer : OpenBuffer)
        @uri = buffer.uri
        @language_id = buffer.language_id || "plaintext"
        @opening = false
        @opened = false
        @closed = false
        @sending_change = false
        @sent_version = 0
        @desired_version = buffer.version
      end
    end

    struct RecoveryRequest
      getter kind : Symbol
      getter client : Lsp::Client?
      getter epoch : UInt64

      def initialize(@kind : Symbol, @client : Lsp::Client?, @epoch : UInt64)
      end
    end

    # Stable, compact status for the header and command palette callers.
    def lsp_health_label : String
      state = lsp_recovery_state
      state.mutex.synchronize do
        if state.shutdown
          "stopped"
        elsif state.command.nil?
          "disabled"
        elsif state.ready && (client = @lsp) && client.connected?
          "connected"
        elsif state.phase == "failed"
          "failed"
        elsif state.phase == "connecting"
          "connecting"
        elsif state.phase == "retrying"
          count = state.retry_count.clamp(1, RECOVERY_ATTEMPTS)
          "retrying #{count}/#{RECOVERY_ATTEMPTS}"
        elsif state.phase == "stopped"
          "stopped"
        else
          "disconnected"
        end
      end
    end

    # Explicit restart is deliberately disabled when no configured command is
    # available.  Recovery never performs a second round of server discovery.
    def restart_lsp : Nil
      state = lsp_recovery_state
      epoch = state.mutex.synchronize do
        command = state.command
        unless command && !command.empty?
          @status_log.warning("LSP disabled; restart unavailable without a configured server")
          next nil
        end

        state.epoch &+= 1_u64
        state.retry_count = 0
        state.phase = "retrying"
        state.ready = false
        state.resyncing = false
        state.epoch
      end
      return unless epoch

      lsp_recovery_invalidate
      lsp_recovery_enqueue(:manual, nil, epoch.not_nil!)
      update_header
      wakeup
    end

    # Factory seam used by coordinator specs and embedders.  The default keeps
    # the old client construction behavior and preserves configured arguments.
    protected def new_lsp_client(command : String, root : Path, args : Array(String)) : Lsp::Client
      Lsp::Client.new(command, root, args)
    end

    private def lsp_recovery_state : RecoveryState
      state = @lsp_recovery_state
      return state if state

      created = RecoveryState.new
      @lsp_recovery_state = created
      created
    end

    private def lsp_recovery_configure(command : String?, args : Array(String)) : Nil
      state = lsp_recovery_state
      state.mutex.synchronize do
        if command && !command.empty?
          state.command = command
          state.args = args.dup
          state.root = @project_root
          state.phase = "connecting"
          state.retry_count = 0
          state.shutdown = false
        else
          state.command = nil
          state.args = [] of String
          state.phase = "disabled"
          state.ready = false
        end
      end
    end

    private def lsp_recovery_prepare_initial(client : Lsp::Client) : Nil
      state = lsp_recovery_state
      state.mutex.synchronize do
        state.root = @project_root
        state.active = client
        state.candidate = nil
        state.ready = false
        state.resyncing = false
        state.phase = "connecting"
        state.shutdown = false
      end
    end

    private def lsp_recovery_initial_connected(client : Lsp::Client) : Nil
      state = lsp_recovery_state
      state.mutex.synchronize do
        state.active = client
        state.candidate = nil
        state.ready = true
        state.resyncing = false
        state.phase = "connected"
      end
    end

    private def lsp_recovery_initial_failed(client : Lsp::Client) : Nil
      state = lsp_recovery_state
      state.mutex.synchronize do
        state.active = nil if state.active.try(&.same?(client))
        state.candidate = nil if state.candidate.try(&.same?(client))
        state.ready = false
        state.resyncing = false
        state.phase = "failed"
      end
    end

    private def lsp_recovery_attach(client : Lsp::Client) : Nil
      callback_epoch = lsp_recovery_state.mutex.synchronize { lsp_recovery_state.epoch }
      client.on_transport_failure = ->(reason : String) do
        # The reader callback is intentionally enqueue-only.  Stopping and
        # reaping the failed process belongs to the coordinator worker.
        lsp_recovery_enqueue_transport_failure(client, reason, callback_epoch)
        nil
      end
    end

    private def lsp_recovery_enqueue_transport_failure(client : Lsp::Client, _reason : String, callback_epoch : UInt64) : Nil
      state = lsp_recovery_state
      epoch = state.mutex.synchronize do
        return if state.shutdown
        return unless state.epoch == callback_epoch
        return unless state.active.try(&.same?(client))
        state.ready = false
        state.resyncing = false
        state.phase = "retrying"
        state.epoch
      end
      lsp_recovery_enqueue(:transport, client, epoch)
      update_header
      wakeup
    end

    private def lsp_recovery_enqueue(kind : Symbol, client : Lsp::Client?, epoch : UInt64) : Nil
      state = lsp_recovery_state
      state.mutex.synchronize do
        return if state.shutdown
        state.pending = RecoveryRequest.new(kind, client, epoch)
        unless state.worker_started
          state.worker_started = true
          spawn(name: "lsp-recovery-coordinator") { lsp_recovery_worker(state) }
        end
      end

      select
      when state.queue.send(nil)
      else
      end
    rescue Channel::ClosedError
      # Shutdown may race with a reader callback.  The shutdown epoch wins.
    end

    private def lsp_recovery_worker(state : RecoveryState) : Nil
      loop do
        break if state.mutex.synchronize { state.shutdown }
        request = state.mutex.synchronize { pending = state.pending; state.pending = nil; pending }
        unless request
          state.queue.receive
          next
        end
        begin
          lsp_recovery_run_request(state, request.not_nil!)
        rescue
          # A factory or callback supplied by an embedder must not kill the
          # sole coordinator fiber.  Keep it alive for a later manual restart.
          lsp_recovery_stop_active_and_candidate(state)
          lsp_recovery_clear_entries(state)
          state.mutex.synchronize do
            if !state.shutdown && state.epoch == request.not_nil!.epoch
              state.phase = "failed"
              state.ready = false
              state.resyncing = false
            end
          end
          update_header
          wakeup
        end
      end
    rescue Channel::ClosedError
      nil
    ensure
      state.mutex.synchronize do
        state.worker_started = false
      end
    end

    private def lsp_recovery_run_request(state : RecoveryState, request : RecoveryRequest) : Nil
      return unless lsp_recovery_request_current?(state, request)

      automatic = request.kind == :transport
      attempt, explicit_initial = state.mutex.synchronize do
        state.ready = false
        state.resyncing = false
        state.phase = "retrying"
        if !automatic
          state.retry_count = 0
        end
        {state.retry_count, !automatic}
      end

      lsp_recovery_invalidate
      lsp_recovery_stop_active_and_candidate(state)
      lsp_recovery_clear_entries(state)

      loop do
        return unless lsp_recovery_epoch_current_without_client?(state, request.epoch)

        # An explicit restart/root change starts one candidate immediately;
        # failures then receive the full three automatic attempts at the
        # fixed 250/500/1000ms schedule. Transport failures begin at 250ms.
        if explicit_initial
          explicit_initial = false
        else
          break if attempt >= RECOVERY_ATTEMPTS
          delay_index = attempt.clamp(0, RECOVERY_ATTEMPTS - 1)
          sleep RECOVERY_BACKOFF[delay_index]
          attempt += 1
          state.mutex.synchronize do
            return if state.shutdown || state.epoch != request.epoch
            state.retry_count = attempt
          end
          update_header
          wakeup
        end
        return unless lsp_recovery_epoch_current_without_client?(state, request.epoch)

        command, args, epoch, root = state.mutex.synchronize { {state.command, state.args.dup, state.epoch, state.root} }
        return unless command && !command.empty?
        return unless epoch == request.epoch

        client = new_lsp_client(command, root, args)
        client.max_response_bytes = SettingsConfig.max_response_bytes(@settings.max_response_mib)
        publish_candidate = state.mutex.synchronize do
          if state.shutdown || state.epoch != request.epoch || state.root != root
            false
          else
            state.candidate = client
            state.active = client
            state.ready = false
            state.resyncing = true
            state.phase = "retrying"
            @lsp = client
            true
          end
        end
        unless publish_candidate
          lsp_recovery_stop_client(state, client)
          next
        end
        configure_lsp_callbacks(client)
        lsp_recovery_attach(client)

        start_allowed = state.mutex.synchronize do
          !state.shutdown && state.epoch == request.epoch && state.root == root &&
            state.active.try(&.same?(client)) && @lsp.try(&.same?(client))
        end
        unless start_allowed
          lsp_recovery_stop_client(state, client)
          state.mutex.synchronize do
            state.active = nil if state.active.try(&.same?(client))
            state.candidate = nil if state.candidate.try(&.same?(client))
          end
          next
        end

        started = begin
          client.start
        rescue
          false
        end
        if started && client.connected? && lsp_recovery_epoch_current?(state, request.epoch, client)
          if lsp_recovery_resync(state, client, request.epoch)
            state.mutex.synchronize do
              state.active = client
              state.candidate = nil
              state.ready = true
              state.resyncing = false
              state.phase = "connected"
              state.sync_entries.clear
            end
            @document_session.open_buffers.each_value do |buffer|
              schedule_semantic_tokens(buffer, 100.milliseconds)
              schedule_folding_ranges(buffer, 120.milliseconds)
            end
            update_header
            wakeup
            @status_log.success("LSP reconnected: #{command}")
            return
          end
        end

        lsp_recovery_stop_client(state, client)
        @lsp = nil if @lsp.try(&.same?(client))
        state.mutex.synchronize do
          state.active = nil if state.active.try(&.same?(client))
          state.candidate = nil if state.candidate.try(&.same?(client))
          state.ready = false
          state.resyncing = false
          state.retry_count = attempt if state.retry_count < attempt
        end
      end

      state.mutex.synchronize do
        state.phase = "failed"
        state.ready = false
        state.resyncing = false
      end
      update_header
      wakeup
      @status_log.error("LSP recovery failed after #{RECOVERY_ATTEMPTS} automatic attempts")
    end

    private def lsp_recovery_request_current?(state : RecoveryState, request : RecoveryRequest) : Bool
      state.mutex.synchronize do
        return false if state.shutdown
        return false unless state.epoch == request.epoch
        if request.kind == :transport
          active = state.active
          return false unless active && request.client && active.same?(request.client.not_nil!)
        end
        true
      end
    end

    private def lsp_recovery_epoch_current_without_client?(state : RecoveryState, epoch : UInt64) : Bool
      state.mutex.synchronize { !state.shutdown && state.epoch == epoch }
    end

    private def lsp_recovery_stop_active_and_candidate(state : RecoveryState) : Nil
      clients = [] of Lsp::Client
      state.mutex.synchronize do
        clients << state.active.not_nil! if state.active
        candidate = state.candidate
        clients << candidate.not_nil! if candidate && !clients.any? { |client| client.same?(candidate.not_nil!) }
        if legacy = @lsp
          clients << legacy unless clients.any? { |client| client.same?(legacy) }
        end
        state.active = nil
        state.candidate = nil
        state.ready = false
      end
      clients.each { |client| lsp_recovery_stop_client(state, client) }
      @lsp = nil if clients.any? { |client| @lsp.try(&.same?(client)) }
    end

    private def lsp_recovery_stop_client(_state : RecoveryState, client : Lsp::Client) : Nil
      # Client#stop is idempotent and serializes teardown. A concurrent quit
      # must await that teardown, not mistake "stopping" for "already reaped".
      client.stop
    rescue
    end

    private def lsp_recovery_clear_entries(state : RecoveryState) : Nil
      state.mutex.synchronize { state.sync_entries.clear }
    end

    private def lsp_recovery_resync(state : RecoveryState, client : Lsp::Client, epoch : UInt64) : Bool
      state.mutex.synchronize do
        state.sync_entries.clear
        state.resyncing = true
      end

      loop do
        return false unless lsp_recovery_epoch_current?(state, epoch, client)
        entry, operation = lsp_recovery_next_sync_operation(state)
        unless entry
          state.mutex.synchronize { state.resyncing = false }
          return client.connected? && lsp_recovery_epoch_current?(state, epoch, client)
        end

        case operation
        when :open
          return false unless lsp_recovery_send_open(state, client, entry, epoch)
        when :change
          return false unless lsp_recovery_send_change(state, client, entry, epoch)
        when :close
          return false unless lsp_recovery_send_close(state, client, entry, epoch)
        end
      end
    end

    private def lsp_recovery_next_sync_operation(state : RecoveryState) : {SyncEntry?, Symbol?}
      lsp_recovery_refresh_sync_entries(state)
      state.mutex.synchronize do
        # A close is ordered before any new didOpen.  This matters when a
        # buffer is closed/reopened on the same URI while an earlier open
        # write is yielding: LSP peers must observe didClose before the next
        # didOpen for that URI.
        state.sync_entries.each_value do |entry|
          next unless entry.opened && entry.closed
          entry.sending_change = true
          return {entry, :close}
        end
        state.sync_entries.each_value do |entry|
          next if entry.opened || entry.opening || entry.closed
          entry.opening = true
          return {entry, :open}
        end
        state.sync_entries.each_value do |entry|
          next if !entry.opened || entry.closed || entry.sending_change
          next unless entry.desired_version > entry.sent_version
          entry.sending_change = true
          return {entry, :change}
        end
        {nil, nil}
      end
    end

    # Keep only identity and wire-version metadata in the coordinator. The
    # live OpenBuffer remains the source of truth for text, so a held startup
    # cannot retain one extra full String per document or replay a stale edit.
    private def lsp_recovery_refresh_sync_entries(state : RecoveryState) : Nil
      current = {} of String => OpenBuffer
      @document_session.open_buffers.each_value do |buffer|
        current[lsp_recovery_entry_key(buffer)] = buffer
      end

      state.mutex.synchronize do
        current.each do |key, buffer|
          entry = state.sync_entries[key]?
          unless entry
            entry = SyncEntry.new(key, buffer)
            state.sync_entries[key] = entry
          end
          entry.buffer = buffer
          entry.uri = buffer.uri
          entry.language_id = buffer.language_id || "plaintext"
          entry.closed = false
          entry.desired_version = buffer.version
        end

        state.sync_entries.to_a.each do |key, entry|
          next if current.has_key?(key)
          if entry.opened || entry.opening
            entry.closed = true
          else
            state.sync_entries.delete(key)
          end
        end
      end
    end

    private def lsp_recovery_send_open(state : RecoveryState, client : Lsp::Client, entry : SyncEntry, epoch : UInt64) : Bool
      version, uri, language, buffer = state.mutex.synchronize { {entry.desired_version, entry.uri, entry.language_id, entry.buffer} }
      text = buffer.editor.text
      # Admit callbacks as soon as the didOpen write begins.  A fake or a
      # peer's reader can publish diagnostics reentrantly from that write,
      # before the call returns and before the remaining buffers are opened.
      # Roll the admission back if the write itself fails.
      state.mutex.synchronize do
        entry.opening = false
        entry.opened = true
      end
      begin
        return false unless client.connected? && lsp_recovery_epoch_current?(state, epoch, client)
        client.open_text_document(uri: uri, language_id: language, version: version, text: text)
      rescue
        state.mutex.synchronize do
          entry.opening = true
          entry.opened = false
        end
        return false
      end
      state.mutex.synchronize do
        entry.opening = false
        entry.opened = true
        entry.sent_version = version
      end
      true
    end

    private def lsp_recovery_send_change(state : RecoveryState, client : Lsp::Client, entry : SyncEntry, epoch : UInt64) : Bool
      version, uri, buffer = state.mutex.synchronize { {entry.desired_version, entry.uri, entry.buffer} }
      text = buffer.editor.text
      begin
        return false unless client.connected? && lsp_recovery_epoch_current?(state, epoch, client)
        client.text_change(uri: uri, version: version, text: text)
      rescue
        return false
      end
      state.mutex.synchronize do
        entry.sending_change = false
        entry.sent_version = version if version > entry.sent_version
      end
      true
    end

    private def lsp_recovery_send_close(state : RecoveryState, client : Lsp::Client, entry : SyncEntry, epoch : UInt64) : Bool
      uri = state.mutex.synchronize { entry.uri }
      begin
        return false unless client.connected? && lsp_recovery_epoch_current?(state, epoch, client)
        client.close_text_document(uri)
      rescue
        return false
      end
      state.mutex.synchronize do
        entry.sending_change = false
        state.sync_entries.delete(entry.key)
      end
      true
    end

    private def lsp_recovery_epoch_current?(state : RecoveryState, epoch : UInt64, client : Lsp::Client) : Bool
      state.mutex.synchronize do
        !!(!state.shutdown && state.epoch == epoch && state.active.try(&.same?(client)) && @lsp.try(&.same?(client)))
      end
    end

    private def lsp_recovery_entry_key(buffer : OpenBuffer) : String
      "#{buffer.path}\u0000#{buffer.object_id}"
    end

    private def lsp_recovery_sync_open(buffer : OpenBuffer) : Bool
      state = lsp_recovery_state
      managed, resyncing = state.mutex.synchronize { {!!(state.command && !state.ready), state.resyncing} }
      return false unless managed
      return true unless resyncing
      key = lsp_recovery_entry_key(buffer)
      state.mutex.synchronize do
        entry = state.sync_entries[key]?
        if entry
          entry.closed = false
          entry.desired_version = buffer.version
          entry.buffer = buffer
          entry.uri = buffer.uri
          entry.language_id = buffer.language_id || "plaintext"
        else
          state.sync_entries[key] = SyncEntry.new(key, buffer)
        end
      end
      true
    end

    private def lsp_recovery_sync_change(buffer : OpenBuffer) : Bool
      state = lsp_recovery_state
      managed, resyncing = state.mutex.synchronize { {!!(state.command && !state.ready), state.resyncing} }
      return false unless managed
      return true unless resyncing
      key = lsp_recovery_entry_key(buffer)
      state.mutex.synchronize do
        entry = state.sync_entries[key]?
        unless entry
          entry = SyncEntry.new(key, buffer)
          state.sync_entries[key] = entry
        end
        entry.buffer = buffer
        entry.uri = buffer.uri
        entry.language_id = buffer.language_id || "plaintext"
        entry.desired_version = buffer.version
      end
      true
    end

    private def lsp_recovery_sync_close(uri : String) : Bool
      state = lsp_recovery_state
      managed, resyncing = state.mutex.synchronize { {!!(state.command && !state.ready), state.resyncing} }
      return false unless managed
      return true unless resyncing
      state.mutex.synchronize do
        state.sync_entries.each_value do |entry|
          entry.closed = true if entry.uri == uri
        end
      end
      true
    end

    private def lsp_recovery_client_ready?(client : Lsp::Client) : Bool
      state = lsp_recovery_state
      state.mutex.synchronize do
        return true if state.command.nil? && state.active.nil? && !!@lsp.try(&.same?(client)) && client.connected?
        !!(state.ready && !state.resyncing && state.active.try(&.same?(client)) && @lsp.try(&.same?(client)) && client.connected?)
      end
    end

    # Diagnostics are also used by the legacy injected-client tests and by
    # embedders which install a client without a process-backed transport.  In
    # that unmanaged mode the callback remains admissible even when
    # connected? is false; the @lsp identity check is still the stale-client
    # boundary.  Managed candidates may publish after their own didOpen while
    # the rest of the resync is yielding, but never before that document was
    # opened on this client.
    private def lsp_recovery_diagnostics_admissible?(client : Lsp::Client, uri : String) : Bool
      state = lsp_recovery_state
      state.mutex.synchronize do
        return false if state.shutdown
        return true if state.command.nil? && state.active.nil? && @lsp.try(&.same?(client))
        return false unless state.active.try(&.same?(client)) && @lsp.try(&.same?(client))
        return true if state.ready && !state.resyncing && client.connected?
        return false unless state.resyncing && client.connected?

        state.sync_entries.each_value.any? do |entry|
          entry.uri == uri && entry.opened && !entry.closed
        end
      end
    end

    # Warnings are not document publications, but the same generation boundary
    # prevents an old process from surfacing text after an explicit restart.
    # A current candidate is allowed to report warnings while it is resyncing.
    private def lsp_recovery_warning_admissible?(client : Lsp::Client) : Bool
      state = lsp_recovery_state
      state.mutex.synchronize do
        return false if state.shutdown
        return true if state.command.nil? && state.active.nil? && @lsp.try(&.same?(client))
        !!(state.active.try(&.same?(client)) && @lsp.try(&.same?(client)) && client.connected? &&
          (state.ready || state.resyncing))
      end
    end

    private def lsp_recovery_blocks_legacy_sync? : Bool
      state = lsp_recovery_state
      state.mutex.synchronize { state.command != nil && (!state.ready || state.resyncing) }
    end

    private def lsp_recovery_invalidate : Nil
      invalidate_lsp_actions
      close_lsp_popup(false)
      close_problems
      clear_all_buffer_diagnostics
      @document_session.open_buffers.each_value do |buffer|
        buffer.semantic_overlay = SemanticOverlay.empty
        buffer.semantic_generation += 1
        buffer.fold_generation += 1
        buffer.editor.clear_folds
      end
      update_header
      wakeup
    end

    private def lsp_recovery_root_changed : Nil
      state = lsp_recovery_state
      epoch = state.mutex.synchronize do
        state.epoch &+= 1_u64
        state.root = @project_root
        state.retry_count = 0
        state.ready = false
        state.resyncing = false
        if state.command
          state.phase = "retrying"
        else
          state.phase = "disabled"
        end
        state.epoch
      end
      lsp_recovery_invalidate
      if state.mutex.synchronize { state.command != nil }
        lsp_recovery_enqueue(:root, nil, epoch)
      else
        lsp_recovery_stop_active_and_candidate(state)
      end
      update_header
      wakeup
    end

    private def lsp_recovery_shutdown : Nil
      state = lsp_recovery_state
      state.mutex.synchronize do
        state.shutdown = true
        state.epoch &+= 1_u64
        state.ready = false
        state.resyncing = false
        state.phase = "stopped"
      end
      lsp_recovery_invalidate
      lsp_recovery_stop_active_and_candidate(state)
      select
      when state.queue.send(nil)
      else
      end
      update_header
      wakeup
    end
  end
end
