require "random/secure"

module Adamantine::Debugging
  enum DebugVariableLoadState
    Unloaded
    Loading
    Partial
    Loaded
    Failed
    Cycle
    Limit
  end

  class DebugScopeInput
    @name : String
    getter variables_reference : Int32
    getter named_variables : Int32?
    getter indexed_variables : Int32?

    def initialize(*, name : String, variables_reference : Int32,
                   named_variables : Int32? = nil, indexed_variables : Int32? = nil)
      @name = name.dup
      @variables_reference = Math.max(0, variables_reference)
      @named_variables = bounded_count(named_variables)
      @indexed_variables = bounded_count(indexed_variables)
    end

    def name : String
      @name.dup
    end

    private def bounded_count(value : Int32?) : Int32?
      value.try { |count| Math.max(0, Math.min(count, DebugVariableTree::MAX_NODES)) }
    end
  end

  class DebugVariableInput
    MAX_NAME_BYTES          = 1024
    MAX_VALUE_BYTES         = 64 * 1024
    MAX_TYPE_BYTES          = 256
    MAX_EVALUATE_NAME_BYTES = 256

    @name : String
    @value : String
    @type : String?
    @evaluate_name : String?
    getter format_identity_complete : Bool
    getter value_complete : Bool
    getter variables_reference : Int32
    getter named_variables : Int32?
    getter indexed_variables : Int32?

    def initialize(*, name : String, value : String, variables_reference : Int32 = 0,
                   type : String? = nil, named_variables : Int32? = nil,
                   indexed_variables : Int32? = nil, evaluate_name : String? = nil,
                   identity_complete : Bool = true)
      @name, name_complete = bounded_copy(name, MAX_NAME_BYTES)
      @value, @value_complete = bounded_copy(value, MAX_VALUE_BYTES)
      @type, type_complete = optional_bounded_copy(type, MAX_TYPE_BYTES)
      @evaluate_name, evaluate_complete = optional_bounded_copy(evaluate_name, MAX_EVALUATE_NAME_BYTES)
      # A formatted refetch changes the value itself. Its identity is established
      # by the other bounded fields and the source page offset, not by summary
      # completeness.
      @format_identity_complete = identity_complete && name_complete && type_complete && evaluate_complete
      @variables_reference = Math.max(0, variables_reference)
      @named_variables = bounded_count(named_variables)
      @indexed_variables = bounded_count(indexed_variables)
    end

    def name : String
      @name.dup
    end

    def value : String
      @value.dup
    end

    def type : String?
      @type.try(&.dup)
    end

    def evaluate_name : String?
      @evaluate_name.try(&.dup)
    end

    private def bounded_count(value : Int32?) : Int32?
      value.try { |count| Math.max(0, Math.min(count, DebugVariableTree::MAX_NODES)) }
    end

    private def optional_bounded_copy(value : String?, limit : Int32) : Tuple(String?, Bool)
      return {nil, true} unless value
      bounded_copy(value.not_nil!, limit)
    end

    private def bounded_copy(value : String, limit : Int32) : Tuple(String, Bool)
      return {"?", false} unless value.valid_encoding?
      return {value.dup, true} if value.bytesize <= limit
      clipped = String.build do |builder|
        used = 0
        value.each_char do |char|
          break if used + char.bytesize > limit
          builder << char
          used += char.bytesize
        end
      end
      {clipped, false}
    end
  end

  # Bounded identity for the exact DAP variables page that produced a node.
  # It is used only to validate an explicit formatted-value refetch.
  class DebugVariableOrigin
    getter variables_reference : Int32
    getter page_start : Int32
    getter page_count : Int32
    getter index : Int32
    getter child_variables_reference : Int32
    getter named_variables : Int32?
    getter indexed_variables : Int32?
    @filter : String?
    @name : String
    @type : String?
    @evaluate_name : String?

    def initialize(@variables_reference : Int32, @page_start : Int32, @page_count : Int32,
                   @index : Int32, name : String, type : String?, evaluate_name : String?,
                   @child_variables_reference : Int32, @named_variables : Int32?,
                   @indexed_variables : Int32?, filter : String? = nil)
      @name = name.dup
      @type = type.try(&.dup)
      @evaluate_name = evaluate_name.try(&.dup)
      @filter = filter.try(&.dup)
    end

    def name : String
      @name.dup
    end

    def type : String?
      @type.try(&.dup)
    end

    def evaluate_name : String?
      @evaluate_name.try(&.dup)
    end

    def filter : String?
      @filter.try(&.dup)
    end
  end

  class DebugVariablePage
    getter generation : UInt64
    getter start : Int32
    getter count : Int32
    getter variables_reference : Int32
    @token : String
    @parent_id : String
    @filter : String?

    def initialize(@generation : UInt64, @start : Int32, @count : Int32,
                   @variables_reference : Int32, token : String, parent_id : String,
                   filter : String? = nil)
      @token = token.dup
      @parent_id = parent_id.dup
      @filter = filter.try(&.dup)
    end

    def token : String
      @token.dup
    end

    def parent_id : String
      @parent_id.dup
    end

    def filter : String?
      @filter.try(&.dup)
    end
  end

  class DebugVariableNode
    @id : String
    @parent_id : String?
    @name : String
    @value : String
    @type : String?
    @reason : String?
    @json_source : String?
    @origin : DebugVariableOrigin?
    @child_ids : Array(String)
    getter variables_reference : Int32
    getter named_variables : Int32?
    getter indexed_variables : Int32?
    getter depth : Int32
    getter load_state : DebugVariableLoadState
    getter value_truncated : Bool

    def initialize(id : String, parent_id : String?, name : String, value : String,
                   type : String?, @variables_reference : Int32, @named_variables : Int32?,
                   @indexed_variables : Int32?, @depth : Int32,
                   @load_state : DebugVariableLoadState, child_ids : Array(String),
                   reason : String? = nil, json_source : String? = nil,
                   @origin : DebugVariableOrigin? = nil, @value_truncated : Bool = false)
      @id = id.dup
      @parent_id = parent_id.try(&.dup)
      @name = name.dup
      @value = value.dup
      @type = type.try(&.dup)
      @child_ids = child_ids.map(&.dup)
      @reason = reason.try(&.dup)
      @json_source = json_source.try(&.dup)
    end

    def id : String
      @id.dup
    end

    def parent_id : String?
      @parent_id.try(&.dup)
    end

    def name : String
      @name.dup
    end

    def value : String
      @value.dup
    end

    def type : String?
      @type.try(&.dup)
    end

    def reason : String?
      @reason.try(&.dup)
    end

    def json_source : String?
      @json_source.try(&.dup)
    end

    def origin : DebugVariableOrigin?
      @origin
    end

    def child_ids : Array(String)
      @child_ids.map(&.dup)
    end

    def expandable? : Bool
      @variables_reference > 0 && !@load_state.in?(DebugVariableLoadState::Cycle, DebugVariableLoadState::Limit, DebugVariableLoadState::Failed)
    end
  end

  class DebugVariableSnapshot
    @nodes : Array(DebugVariableNode)
    @roots : Array(DebugVariableNode)
    @truncation_reason : String?
    getter retained_node_count : Int32
    getter retained_display_bytes : Int64

    def initialize(nodes : Array(DebugVariableNode), roots : Array(DebugVariableNode),
                   @retained_node_count : Int32, @retained_display_bytes : Int64,
                   truncation_reason : String? = nil)
      @nodes = nodes.dup
      @roots = roots.dup
      @truncation_reason = truncation_reason.try(&.dup)
    end

    def nodes : Array(DebugVariableNode)
      @nodes.dup
    end

    def roots : Array(DebugVariableNode)
      @roots.dup
    end

    def node(id : String) : DebugVariableNode?
      @nodes.find { |candidate| candidate.id == id }
    end

    def truncation_reason : String?
      @truncation_reason.try(&.dup)
    end

    def truncated? : Bool
      !@truncation_reason.nil?
    end

    def partial? : Bool
      truncated? || @nodes.any? { |node| node.load_state.in?(DebugVariableLoadState::Partial, DebugVariableLoadState::Limit, DebugVariableLoadState::Failed) }
    end
  end

  # Lazy bounded tree of adapter-provided structure. No child request is
  # created until begin_children/load_more is called explicitly.
  class DebugVariableTree
    DEFAULT_PAGE_SIZE         =   100
    DEFAULT_MAX_NODES         = 5_000
    DEFAULT_MAX_DISPLAY_BYTES = 8 * 1024 * 1024
    DEFAULT_MAX_VALUE_BYTES   = 64 * 1024
    DEFAULT_MAX_DEPTH         = 32

    MAX_NODES = DEFAULT_MAX_NODES

    private class Entry
      property id : String
      property parent_id : String?
      property name : String
      property value : String
      property type : String?
      property variables_reference : Int32
      property named_variables : Int32?
      property indexed_variables : Int32?
      property depth : Int32
      property load_state : DebugVariableLoadState
      property child_ids : Array(String)
      property active_token : String?
      property total_count : Int32?
      property reason : String?
      property json_source : String?
      property origin : DebugVariableOrigin?
      property value_truncated : Bool

      def initialize(@id : String, @parent_id : String?, @name : String, @value : String,
                     @type : String?, @variables_reference : Int32,
                     @named_variables : Int32?, @indexed_variables : Int32?, @depth : Int32,
                     @load_state : DebugVariableLoadState, @total_count : Int32? = nil,
                     @json_source : String? = nil, @origin : DebugVariableOrigin? = nil,
                     @value_truncated : Bool = false)
        @child_ids = [] of String
        @active_token = nil
        @reason = nil
      end

      def view : DebugVariableNode
        DebugVariableNode.new(@id, @parent_id, @name, @value, @type, @variables_reference,
          @named_variables, @indexed_variables, @depth, @load_state, @child_ids, @reason,
          @json_source, @origin, @value_truncated)
      end
    end

    getter page_size : Int32
    getter max_nodes : Int32
    getter max_display_bytes : Int64
    getter max_value_bytes : Int32
    getter max_depth : Int32

    @entries : Hash(String, Entry)
    @roots : Array(String)
    @generation : UInt64
    @next_id : UInt64
    @display_bytes : Int64
    @general_reason : String?
    @truncation_reason : String?

    def initialize(page_size : Int32 = DEFAULT_PAGE_SIZE, max_nodes : Int32 = DEFAULT_MAX_NODES,
                   max_display_bytes : Int32 = DEFAULT_MAX_DISPLAY_BYTES,
                   max_value_bytes : Int32 = DEFAULT_MAX_VALUE_BYTES,
                   max_depth : Int32 = DEFAULT_MAX_DEPTH)
      unless page_size.in?(1..100) && max_nodes.in?(1..DEFAULT_MAX_NODES) &&
             max_display_bytes.in?(64..DEFAULT_MAX_DISPLAY_BYTES) &&
             max_value_bytes.in?(1..DEFAULT_MAX_VALUE_BYTES) && max_depth.in?(1..DEFAULT_MAX_DEPTH)
        raise ArgumentError.new("invalid debugger variable tree limits")
      end
      @page_size = page_size
      @max_nodes = max_nodes
      @max_display_bytes = max_display_bytes.to_i64
      @max_value_bytes = max_value_bytes
      @max_depth = max_depth
      @entries = {} of String => Entry
      @roots = [] of String
      @generation = 0_u64
      @next_id = 0_u64
      @display_bytes = 0_i64
      @general_reason = nil
      @truncation_reason = nil
    end

    def replace_scopes(scopes : Array(DebugScopeInput)) : DebugVariableSnapshot
      retire("stopped frame changed")
      @truncation_reason = nil
      scopes.each do |scope|
        break if @entries.size >= @max_nodes
        id = next_id
        name, name_clipped = fit(scope.name)
        entry = Entry.new(id, nil, name, "", nil, scope.variables_reference,
          scope.named_variables, scope.indexed_variables, 0,
          scope.variables_reference > 0 ? DebugVariableLoadState::Unloaded : DebugVariableLoadState::Loaded,
          combined_count(scope.named_variables, scope.indexed_variables))
        entry.reason = "scope name clipped to fit the display budget" if name_clipped
        @truncation_reason ||= entry.reason if name_clipped
        unless retain_entry(entry)
          entry.load_state = DebugVariableLoadState::Limit
          entry.reason = "display byte budget reached"
          @general_reason = entry.reason
          @truncation_reason ||= entry.reason
          break
        end
        @roots << id
      end
      if scopes.size > @roots.size
        @general_reason = "scope list was clipped by the variable node budget"
        @truncation_reason ||= @general_reason
      end
      snapshot
    end

    def begin_children(node_id : String, filter : String? = nil) : DebugVariablePage?
      entry = @entries[node_id]?
      return nil unless entry && entry.not_nil!.variables_reference > 0
      current = entry.not_nil!
      return nil if current.active_token
      return nil if current.load_state.in?(DebugVariableLoadState::Cycle, DebugVariableLoadState::Limit, DebugVariableLoadState::Failed, DebugVariableLoadState::Loaded)
      if current.depth >= @max_depth
        current.load_state = DebugVariableLoadState::Limit
        current.reason = "maximum variable depth reached"
        return nil
      end
      start = current.child_ids.size
      remaining = @max_nodes - @entries.size
      if remaining <= 0
        current.load_state = DebugVariableLoadState::Limit
        current.reason = "variable node budget reached"
        return nil
      end
      count = Math.min(@page_size, remaining)
      if total = current.total_count
        count = Math.min(count, total - start)
      end
      if count <= 0
        current.load_state = DebugVariableLoadState::Loaded
        return nil
      end
      token = Random::Secure.hex(12)
      current.active_token = token
      current.load_state = DebugVariableLoadState::Loading
      DebugVariablePage.new(@generation, start, count, current.variables_reference, token, current.id, filter)
    end

    def load_more(node_id : String) : DebugVariablePage?
      entry = @entries[node_id]?
      return nil unless entry && entry.not_nil!.load_state == DebugVariableLoadState::Partial
      begin_children(node_id)
    end

    def complete(page : DebugVariablePage, variables : Array(DebugVariableInput),
                 total_count : Int32? = nil) : Bool
      return false unless page.generation == @generation
      parent = @entries[page.parent_id]?
      return false unless parent && parent.not_nil!.active_token == page.token
      current = parent.not_nil!
      current.active_token = nil
      total = total_count || current.total_count
      total = Math.max(0, Math.min(total.not_nil!, @max_nodes)) if total
      current.total_count = total
      current.named_variables = total if total && current.indexed_variables.nil?

      accepted = variables.first(page.count)
      clipped_page = accepted.size < variables.size
      retention_limited = false
      accepted.each_with_index do |input, page_offset|
        break if @entries.size >= @max_nodes
        child_id = next_id
        original_name = input.name
        original_value = input.value
        original_type = input.type
        original_evaluate_name = input.evaluate_name
        name, name_clipped = fit(original_name)
        value, value_clipped = fit(original_value)
        type, type_clipped = optional_fit(original_type)
        eval_name, eval_clipped = optional_fit(original_evaluate_name)
        origin = if input.format_identity_complete && !name_clipped && !type_clipped && !eval_clipped
                   DebugVariableOrigin.new(page.variables_reference, page.start, page.count,
                     page.start + page_offset, original_name, original_type, original_evaluate_name,
                     input.variables_reference, input.named_variables, input.indexed_variables,
                     page.filter)
                 end
        json_source = input.value_complete ? original_value : nil
        child = Entry.new(child_id, current.id, name, value, type,
          input.variables_reference, input.named_variables, input.indexed_variables,
          current.depth + 1, input.variables_reference > 0 ? DebugVariableLoadState::Unloaded : DebugVariableLoadState::Loaded,
          combined_count(input.named_variables, input.indexed_variables), json_source, origin,
          value_clipped || !input.value_complete)
        if name_clipped || value_clipped || type_clipped || eval_clipped
          child.reason = "adapter value clipped to the display byte budget"
        end
        if ancestor_reference?(current, input.variables_reference)
          child.load_state = DebugVariableLoadState::Cycle
          child.reason = "adapter child references an ancestor"
        elsif child.depth >= @max_depth && child.variables_reference > 0
          child.load_state = DebugVariableLoadState::Limit
          child.reason = "maximum variable depth reached"
        end
        unless retain_entry(child)
          current.load_state = DebugVariableLoadState::Limit
          current.reason = "variable display byte budget reached"
          @general_reason = current.reason
          @truncation_reason ||= current.reason
          retention_limited = true
          break
        end
        current.child_ids << child_id
      end

      if retention_limited
        # Preserve the terminal Limit state installed by retain_entry failure.
      elsif current.child_ids.size == page.start && (total.nil? || current.child_ids.size < total.not_nil!)
        current.load_state = DebugVariableLoadState::Failed
        current.reason = "adapter variable page made no progress; further pagination is unavailable"
      elsif @entries.size >= @max_nodes && current.child_ids.size < (total || page.start + accepted.size)
        current.load_state = DebugVariableLoadState::Limit
        current.reason = "variable node budget reached"
      elsif clipped_page
        current.load_state = DebugVariableLoadState::Partial
        current.reason = "adapter returned more values than the requested page"
      elsif total.nil?
        if accepted.size < page.count
          current.load_state = DebugVariableLoadState::Loaded
          current.reason = "short final page ended; adapter omitted total child count"
        else
          current.load_state = DebugVariableLoadState::Partial
          current.reason = "adapter omitted total child count"
        end
      elsif current.child_ids.size >= total.not_nil!
        current.load_state = DebugVariableLoadState::Loaded
        current.reason = nil
      else
        current.load_state = DebugVariableLoadState::Partial
        current.reason = nil
      end
      true
    end

    def fail(page : DebugVariablePage, reason : String) : Bool
      return false unless page.generation == @generation
      entry = @entries[page.parent_id]?
      return false unless entry && entry.not_nil!.active_token == page.token
      entry.not_nil!.active_token = nil
      entry.not_nil!.load_state = DebugVariableLoadState::Failed
      entry.not_nil!.reason = bounded_reason(reason)
      true
    end

    def retire(reason : String = "variable handles retired") : Nil
      @generation += 1_u64
      @entries.clear
      @roots.clear
      @display_bytes = 0_i64
      @general_reason = bounded_reason(reason)
      @truncation_reason = nil
    end

    def snapshot : DebugVariableSnapshot
      nodes = @entries.values.map(&.view)
      roots = @roots.compact_map { |id| @entries[id]?.try(&.view) }
      DebugVariableSnapshot.new(nodes, roots, nodes.size, @display_bytes, @truncation_reason)
    end

    private def next_id : String
      @next_id += 1_u64
      "v#{@generation}-#{@next_id}"
    end

    private def retain_entry(entry : Entry) : Bool
      charge = entry.name.bytesize + entry.value.bytesize + (entry.type.try(&.bytesize) || 0) +
               (entry.json_source.try(&.bytesize) || 0)
      return false if @display_bytes + charge > @max_display_bytes
      @entries[entry.id] = entry
      @display_bytes += charge
      true
    end

    private def ancestor_reference?(entry : Entry, reference : Int32) : Bool
      return false if reference <= 0
      current : Entry? = entry
      while current
        return true if current.not_nil!.variables_reference == reference
        current = current.not_nil!.parent_id.try { |id| @entries[id]? }
      end
      false
    end

    private def fit(value : String) : Tuple(String, Bool)
      limit = Math.min(@max_value_bytes.to_i64, @max_display_bytes).to_i32
      sanitize_and_clip(value, limit)
    end

    private def optional_fit(value : String?) : Tuple(String?, Bool)
      return {nil, false} unless value
      clipped, trunc = fit(value.not_nil!)
      {clipped, trunc}
    end

    private def sanitize_and_clip(value : String, limit : Int32) : Tuple(String, Bool)
      return {"?", true} unless value.valid_encoding?
      dropped = false
      output = String.build do |builder|
        used = 0
        value.each_char do |char|
          visible = case char.ord
                    when 0x1b                                     then "␛"
                    when 0x00..0x08, 0x0b..0x1f, 0x7f, 0x80..0x9f then "�"
                    else                                               char.to_s
                    end
          if used + visible.bytesize > limit
            dropped = true
            break
          end
          builder << visible
          used += visible.bytesize
        end
      end
      {output, dropped}
    end

    private def bounded_reason(reason : String) : String
      sanitize_and_clip(reason, 256)[0]
    end

    private def combined_count(named : Int32?, indexed : Int32?) : Int32?
      if named && indexed
        Math.min(named.not_nil!.to_i64 + indexed.not_nil!.to_i64, @max_nodes.to_i64).to_i32
      else
        named || indexed
      end
    end
  end
end
