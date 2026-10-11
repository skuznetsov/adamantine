require "random/secure"

require "./debug_source_store"

module Adamantine::Debugging
  enum BreakpointStatus
    Pending
    Verified
    Rejected
    Moved
    Disabled
    Outdated
  end

  class DebugBreakpointView
    @id : String
    @adapter_id : String?
    @reason : String?
    getter requested_line : Int32
    getter requested_column : Int32?
    getter enabled : Bool
    getter status : BreakpointStatus
    getter resolved_line : Int32?
    getter resolved_column : Int32?

    def initialize(id : String, @requested_line : Int32, @requested_column : Int32?, @enabled : Bool,
                   @status : BreakpointStatus, adapter_id : String? = nil, @resolved_line : Int32? = nil,
                   @resolved_column : Int32? = nil, reason : String? = nil)
      @id = id.dup
      @adapter_id = adapter_id.try(&.dup)
      @reason = reason.try(&.dup)
    end

    def id : String
      @id.dup
    end

    def adapter_id : String?
      @adapter_id.try(&.dup)
    end

    def reason : String?
      @reason.try(&.dup)
    end
  end

  class DebugBreakpointResolution
    @local_id : String
    @adapter_id : String?
    @reason : String?
    getter resolved_line : Int32?
    getter resolved_column : Int32?
    getter verified : Bool

    # Resolved coordinates are editor zero-based coordinates. DAP one-based
    # line/column conversion belongs to the controller boundary.
    def initialize(local_id : String, adapter_id : String?, resolved_line : Int32?,
                   resolved_column : Int32? = nil, verified : Bool = true, reason : String? = nil)
      raise ArgumentError.new("local breakpoint id is empty") if local_id.empty? || local_id.bytesize > 128
      raise ArgumentError.new("resolved breakpoint positions cannot be negative") if (resolved_line && resolved_line.not_nil! < 0) || (resolved_column && resolved_column.not_nil! < 0)
      @local_id = local_id.dup
      @adapter_id = adapter_id.try(&.dup)
      @reason = reason.try(&.dup)
      @resolved_line = resolved_line
      @resolved_column = resolved_column
      @verified = verified
    end

    def local_id : String
      @local_id.dup
    end

    def adapter_id : String?
      @adapter_id.try(&.dup)
    end

    def reason : String?
      @reason.try(&.dup)
    end
  end

  class DebugBreakpointBatchEntry
    @id : String
    getter requested_line : Int32
    getter requested_column : Int32?

    def initialize(id : String, @requested_line : Int32, @requested_column : Int32?)
      @id = id.dup
    end

    def id : String
      @id.dup
    end
  end

  class DebugBreakpointBatch
    @session_id : String
    @lineage : String
    @token : String
    getter generation : UInt64
    getter sequence : UInt64
    getter source_key : DebugSourceKey
    @breakpoints : Array(DebugBreakpointBatchEntry)

    def initialize(session_id : String, lineage : String, token : String, @generation : UInt64,
                   @sequence : UInt64, @source_key : DebugSourceKey,
                   breakpoints : Array(DebugBreakpointBatchEntry))
      @session_id = session_id.dup
      @lineage = lineage.dup
      @token = token.dup
      @breakpoints = breakpoints.dup
    end

    def session_id : String
      @session_id.dup
    end

    def lineage : String
      @lineage.dup
    end

    def token : String
      @token.dup
    end

    def breakpoints : Array(DebugBreakpointBatchEntry)
      @breakpoints.dup
    end
  end

  struct DebugBreakpointCompletion
    @accepted : Bool
    @applied : Bool
    @reason : String?

    def initialize(@accepted : Bool, @applied : Bool, reason : String? = nil)
      @reason = reason.try(&.dup)
    end

    def accepted? : Bool
      @accepted
    end

    def applied? : Bool
      @applied
    end

    def reason : String?
      @reason.try(&.dup)
    end
  end

  struct DebugBreakpointEventResult
    @accepted : Bool
    @reason : String?

    def initialize(@accepted : Bool, reason : String? = nil)
      @reason = reason.try(&.dup)
    end

    def accepted? : Bool
      @accepted
    end

    def reason : String?
      @reason.try(&.dup)
    end
  end

  # Desired breakpoint state and adapter bindings are separate. Every
  # setBreakpoints batch is a complete per-source snapshot; edits during an
  # in-flight request coalesce into one newest generation behind it.
  class DebugBreakpointStore
    private class Entry
      property id : String
      property requested_line : Int32
      property requested_column : Int32?
      property enabled : Bool
      property status : BreakpointStatus
      property adapter_id : String?
      property resolved_line : Int32?
      property resolved_column : Int32?
      property reason : String?

      def initialize(@id : String, @requested_line : Int32, @requested_column : Int32?, @enabled : Bool)
        @status = BreakpointStatus::Pending
        @adapter_id = nil
        @resolved_line = nil
        @resolved_column = nil
        @reason = nil
      end

      def view : DebugBreakpointView
        DebugBreakpointView.new(@id, @requested_line, @requested_column, @enabled, @status, @adapter_id, @resolved_line, @resolved_column, @reason)
      end
    end

    private class SourceState
      property entries : Array(Entry)
      property generation : UInt64
      property in_flight_token : String?
      property in_flight_generation : UInt64?
      property sequence : UInt64
      property dirty : Bool
      property submitted : Bool
      property bound : Bool
      property edited_barrier : Bool
      property edited_reason : String?
      property applied_generation : UInt64?

      def initialize
        @entries = [] of Entry
        @generation = 0_u64
        @in_flight_token = nil
        @in_flight_generation = nil
        @sequence = 0_u64
        @dirty = false
        @submitted = false
        @bound = false
        @edited_barrier = false
        @edited_reason = nil
        @applied_generation = nil
      end
    end

    @session_id : String
    @lineage : String
    @states : Hash(DebugSourceKey, SourceState)

    def initialize(session_id : String)
      validate_session_id!(session_id)
      @session_id = session_id.dup
      @lineage = Random::Secure.hex(16)
      @states = {} of DebugSourceKey => SourceState
    end

    # Adds a new stable local breakpoint, or removes an existing breakpoint at
    # the same requested editor coordinate. Lines and columns are zero-based.
    def toggle(source_key : DebugSourceKey, requested_line : Int32, requested_column : Int32? = nil) : DebugBreakpointView
      validate_position!(requested_line, requested_column)
      validate_source_key!(source_key)
      state = state_for(source_key)
      existing = state.entries.find { |entry| entry.requested_line == requested_line && entry.requested_column == requested_column }
      if existing
        state.entries.delete(existing)
        mutate!(state)
        return existing.view
      end
      entry = Entry.new(Random::Secure.hex(12), requested_line, requested_column, true)
      state.entries << entry
      mutate!(state)
      entry.view
    end

    def set_enabled(source_key : DebugSourceKey, id : String, enabled : Bool) : Bool
      state = @states[source_key]?
      return false unless state
      entry = state.not_nil!.entries.find { |candidate| candidate.id == id }
      return false unless entry
      return true if entry.not_nil!.enabled == enabled
      entry.not_nil!.enabled = enabled
      entry.not_nil!.status = enabled ? BreakpointStatus::Pending : BreakpointStatus::Disabled
      clear_binding(entry.not_nil!)
      entry.not_nil!.reason = nil
      mutate!(state.not_nil!)
      true
    end

    def remove(source_key : DebugSourceKey, id : String) : Bool
      state = @states[source_key]?
      return false unless state
      entries = state.not_nil!.entries
      entry = entries.find { |candidate| candidate.id == id }
      return false unless entry
      entries.delete(entry.not_nil!)
      mutate!(state.not_nil!)
      true
    end

    def breakpoints(source_key : DebugSourceKey) : Array(DebugBreakpointView)
      @states[source_key]?.try(&.entries.map(&.view)) || [] of DebugBreakpointView
    end

    def begin_batch(source_key : DebugSourceKey) : DebugBreakpointBatch?
      return nil unless source_key_allowed?(source_key)
      state = @states[source_key]?
      return nil unless state
      current = state.not_nil!
      return nil if current.edited_barrier || current.in_flight_token || !current.dirty
      return nil if current.entries.empty? && !current.submitted

      current.sequence += 1
      token = "#{@lineage}:#{current.sequence}:#{current.generation}"
      batch_entries = current.entries.select(&.enabled).map do |entry|
        DebugBreakpointBatchEntry.new(entry.id, entry.requested_line, entry.requested_column)
      end
      current.in_flight_token = token
      current.in_flight_generation = current.generation
      current.submitted = true
      DebugBreakpointBatch.new(@session_id, @lineage, token, current.generation, current.sequence, source_key, batch_entries)
    end

    def complete(batch : DebugBreakpointBatch, resolutions : Array(DebugBreakpointResolution), *, success : Bool = true, reason : String? = nil) : DebugBreakpointCompletion
      return DebugBreakpointCompletion.new(false, false, "batch belongs to another session or store lineage") unless batch.session_id == @session_id && batch.lineage == @lineage
      state = @states[batch.source_key]?
      return DebugBreakpointCompletion.new(false, false, "source no longer exists") unless state
      current = state.not_nil!
      unless current.in_flight_token == batch.token && current.in_flight_generation == batch.generation
        return DebugBreakpointCompletion.new(false, false, "batch is stale or already completed")
      end
      current.in_flight_token = nil
      current.in_flight_generation = nil

      if current.generation != batch.generation
        current.dirty = true
        return DebugBreakpointCompletion.new(true, false, "desired breakpoint generation changed while request was in flight")
      end

      if success
        by_id = {} of String => DebugBreakpointResolution
        duplicate = false
        resolutions.each do |resolution|
          duplicate ||= by_id.has_key?(resolution.local_id)
          by_id[resolution.local_id] = resolution
        end
        expected = batch.breakpoints.map(&.id)
        malformed = duplicate || by_id.size != expected.size || expected.any? { |id| !by_id.has_key?(id) }
        current.entries.each do |entry|
          clear_binding(entry)
          if !entry.enabled
            entry.status = BreakpointStatus::Disabled
            entry.reason = nil
            next
          end
          resolution = by_id[entry.id]?
          if malformed || resolution.nil?
            reject!(entry, "adapter response did not resolve the complete requested set")
            next
          end
          value = resolution.not_nil!
          if !value.verified || value.resolved_line.nil?
            reject!(entry, value.reason || "adapter did not verify this breakpoint")
            next
          end
          entry.adapter_id = value.adapter_id
          entry.resolved_line = value.resolved_line
          entry.resolved_column = value.resolved_column
          entry.reason = value.reason
          moved = entry.requested_line != value.resolved_line.not_nil! || (entry.requested_column && entry.requested_column != value.resolved_column)
          entry.status = moved ? BreakpointStatus::Moved : BreakpointStatus::Verified
        end
        current.bound = true
        current.applied_generation = batch.generation
        current.dirty = false
        DebugBreakpointCompletion.new(true, true, malformed ? "adapter response was incomplete or duplicated" : nil)
      else
        current.entries.each do |entry|
          clear_binding(entry)
          if entry.enabled
            reject!(entry, reason || "adapter rejected the breakpoint set")
          else
            entry.status = BreakpointStatus::Disabled
            entry.reason = nil
          end
        end
        current.bound = false
        current.applied_generation = nil
        current.dirty = false
        DebugBreakpointCompletion.new(true, true, reason || "adapter rejected the breakpoint set")
      end
    end

    # Events require the generation certificate returned by an accepted full
    # set. A session ID and adapter ID alone are not enough to revive stale UI.
    def reconcile_event(session_id : String, source_key : DebugSourceKey, generation : UInt64, adapter_id : String,
                        resolved_line : Int32, resolved_column : Int32? = nil) : DebugBreakpointEventResult
      return DebugBreakpointEventResult.new(false, "event belongs to another session") unless session_id == @session_id
      return DebugBreakpointEventResult.new(false, "event position is invalid") if resolved_line < 0 || (resolved_column && resolved_column.not_nil! < 0)
      state = @states[source_key]?
      return DebugBreakpointEventResult.new(false, "event source is no longer registered") unless state
      current = state.not_nil!
      return DebugBreakpointEventResult.new(false, "event generation is stale") unless current.applied_generation == generation && !current.edited_barrier
      entry = current.entries.find { |candidate| candidate.adapter_id == adapter_id && candidate.enabled && candidate.status.in?(BreakpointStatus::Verified, BreakpointStatus::Moved) }
      return DebugBreakpointEventResult.new(false, "event has no current verified binding") unless entry
      entry.not_nil!.resolved_line = resolved_line
      entry.not_nil!.resolved_column = resolved_column
      moved = entry.not_nil!.requested_line != resolved_line || (entry.not_nil!.requested_column && entry.not_nil!.requested_column != resolved_column)
      entry.not_nil!.status = moved ? BreakpointStatus::Moved : BreakpointStatus::Verified
      return DebugBreakpointEventResult.new(true)
    end

    def mark_source_edited(source_key : DebugSourceKey, reason : String) : Bool
      state = @states[source_key]?
      return false unless state
      current = state.not_nil!
      current.edited_barrier = true
      current.edited_reason = bounded_reason(reason)
      current.dirty = true
      current.generation += 1
      current.applied_generation = nil
      current.entries.each do |entry|
        entry.status = entry.enabled ? BreakpointStatus::Outdated : BreakpointStatus::Disabled
        entry.reason = entry.enabled ? current.edited_reason : nil
        clear_binding(entry)
      end
      true
    end

    # Explicit user/controller authority to reconcile against a newly built or
    # otherwise confirmed target; source edits never clear this barrier alone.
    def rebind_source(source_key : DebugSourceKey) : Bool
      state = @states[source_key]?
      return false unless state
      current = state.not_nil!
      current.edited_barrier = false
      current.edited_reason = nil
      current.entries.each do |entry|
        entry.status = entry.enabled ? BreakpointStatus::Pending : BreakpointStatus::Disabled
        entry.reason = nil
        clear_binding(entry)
      end
      mutate!(current)
      true
    end

    def new_session(session_id : String) : Nil
      validate_session_id!(session_id)
      @session_id = session_id.dup
      @lineage = Random::Secure.hex(16)
      stale_reference_sources = @states.keys.select { |key| key.kind == SourceKeyKind::SessionReference }
      stale_reference_sources.each { |key| @states.delete(key) }
      @states.each_value do |state|
        state.in_flight_token = nil
        state.in_flight_generation = nil
        state.applied_generation = nil
        state.bound = false
        state.submitted = false
        state.edited_barrier = false
        state.edited_reason = nil
        state.entries.each do |entry|
          entry.status = entry.enabled ? BreakpointStatus::Pending : BreakpointStatus::Disabled
          entry.reason = nil
          clear_binding(entry)
        end
        state.generation += 1
        state.dirty = state.entries.any?(&.enabled)
      end
    end

    private def state_for(key : DebugSourceKey) : SourceState
      validate_source_key!(key)
      @states[key] ||= SourceState.new
    end

    private def mutate!(state : SourceState) : Nil
      state.generation += 1
      state.dirty = true
      state.applied_generation = nil
      state.entries.each do |entry|
        if state.edited_barrier
          entry.status = entry.enabled ? BreakpointStatus::Outdated : BreakpointStatus::Disabled
          entry.reason = entry.enabled ? state.edited_reason : nil
        else
          entry.status = entry.enabled ? BreakpointStatus::Pending : BreakpointStatus::Disabled
          entry.reason = nil
        end
        clear_binding(entry)
      end
    end

    private def source_key_allowed?(key : DebugSourceKey) : Bool
      key.kind != SourceKeyKind::SessionReference || key.session_id == @session_id
    end

    private def validate_source_key!(key : DebugSourceKey) : Nil
      raise ArgumentError.new("source reference belongs to another session") unless source_key_allowed?(key)
    end

    private def clear_binding(entry : Entry) : Nil
      entry.adapter_id = nil
      entry.resolved_line = nil
      entry.resolved_column = nil
    end

    private def reject!(entry : Entry, reason : String) : Nil
      entry.status = BreakpointStatus::Rejected
      entry.reason = bounded_reason(reason)
      clear_binding(entry)
    end

    private def bounded_reason(reason : String) : String
      String.build do |output|
        bytes = 0
        reason.each_char do |char|
          break if bytes + char.bytesize > 256
          output << char if char.ord >= 0x20 && char.ord != 0x7f
          bytes += char.bytesize
        end
      end
    end

    private def validate_session_id!(session_id : String) : Nil
      raise ArgumentError.new("session id is empty or too long") if session_id.empty? || session_id.bytesize > 256
    end

    private def validate_position!(line : Int32, column : Int32?) : Nil
      raise ArgumentError.new("breakpoint position cannot be negative") if line < 0 || (column && column.not_nil! < 0)
    end
  end
end
