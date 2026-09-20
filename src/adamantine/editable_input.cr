require "string/grapheme"

module Adamantine
  # Small, materialized single-line editing model shared by modal inputs.
  # Positions use Crystal String codepoint indexes, but every public movement
  # and deletion operation snaps to an extended grapheme boundary.
  class EditableInput
    getter value : String
    getter cursor : Int32
    getter revision : UInt64 = 0_u64
    getter max_codepoints : Int32?

    @selection_anchor : Int32? = nil

    def initialize(@value : String = "", @max_codepoints : Int32? = nil)
      validate_limit!(@value)
      @cursor = @value.size
    end

    def value=(new_value : String) : String
      replace(new_value)
      @value
    end

    def replace(new_value : String, cursor : Int32 = new_value.size) : Bool
      return false unless within_limit?(new_value)

      changed = @value != new_value
      @value = new_value
      @cursor = snap_boundary(cursor)
      @selection_anchor = nil
      bump_revision if changed
      true
    end

    def cursor=(position : Int32) : Int32
      @cursor = snap_boundary(position)
      @selection_anchor = nil
      @cursor
    end

    def max_codepoints=(limit : Int32?) : Int32?
      raise ArgumentError.new("editable input limit must be positive") if limit && limit <= 0
      raise ArgumentError.new("editable input value exceeds new limit") if limit && @value.size > limit
      @max_codepoints = limit
    end

    def selection_range : {Int32, Int32}?
      anchor = @selection_anchor
      return nil unless anchor
      return nil if anchor == @cursor

      anchor < @cursor ? {anchor, @cursor} : {@cursor, anchor}
    end

    def selected_text : String?
      range = selection_range
      return nil unless range

      @value[range[0], range[1] - range[0]]
    end

    def select_all : Nil
      @selection_anchor = 0
      @cursor = @value.size
    end

    def clear_selection : Nil
      @selection_anchor = nil
    end

    def move_home(*, extend_selection : Bool = false) : Nil
      move_to(0, extend_selection)
    end

    def move_end(*, extend_selection : Bool = false) : Nil
      move_to(@value.size, extend_selection)
    end

    def move_left(*, extend_selection : Bool = false) : Nil
      if !extend_selection && (range = selection_range)
        move_to(range[0], false)
      else
        move_to(previous_boundary(@cursor), extend_selection)
      end
    end

    def move_right(*, extend_selection : Bool = false) : Nil
      if !extend_selection && (range = selection_range)
        move_to(range[1], false)
      else
        move_to(next_boundary(@cursor), extend_selection)
      end
    end

    def move_word_left(*, extend_selection : Bool = false) : Nil
      clusters = grapheme_ranges
      index = clusters.rindex { |range| range[0] < @cursor } || -1
      while index >= 0 && grapheme_whitespace?(clusters[index])
        index -= 1
      end
      while index >= 0 && !grapheme_whitespace?(clusters[index])
        index -= 1
      end
      target = index + 1 < clusters.size ? clusters[index + 1][0] : 0
      move_to(target, extend_selection)
    end

    def move_word_right(*, extend_selection : Bool = false) : Nil
      clusters = grapheme_ranges
      index = clusters.index { |range| range[0] >= @cursor } || clusters.size
      while index < clusters.size && !grapheme_whitespace?(clusters[index])
        index += 1
      end
      while index < clusters.size && grapheme_whitespace?(clusters[index])
        index += 1
      end
      target = index < clusters.size ? clusters[index][0] : @value.size
      move_to(target, extend_selection)
    end

    def insert(text : String) : Bool
      return false if text.empty?

      range = selection_range
      start = range ? range[0] : @cursor
      finish = range ? range[1] : @cursor
      candidate = @value[0, start] + text + @value[finish..]
      return false unless within_limit?(candidate)

      @value = candidate
      @cursor = snap_boundary_forward(start + text.size)
      @selection_anchor = nil
      bump_revision
      true
    end

    def insert_paste(text : String) : Bool
      normalized = normalize_paste(text)
      return true if normalized.empty?

      insert(normalized)
    end

    def delete_selection : Bool
      range = selection_range
      return false unless range

      delete_range(range[0], range[1])
    end

    def delete_backward : Bool
      return true if delete_selection
      return false if @cursor <= 0

      delete_range(previous_boundary(@cursor), @cursor)
    end

    def delete_forward : Bool
      return true if delete_selection
      return false if @cursor >= @value.size

      delete_range(@cursor, next_boundary(@cursor))
    end

    def clear_to_beginning : Bool
      return true if delete_selection
      return false if @cursor <= 0

      delete_range(0, @cursor)
    end

    def clear_to_end : Bool
      return true if delete_selection
      return false if @cursor >= @value.size

      delete_range(@cursor, @value.size)
    end

    def delete_word_backward : Bool
      return true if delete_selection
      finish = @cursor
      move_word_left
      start = @cursor
      @cursor = finish
      delete_range(start, finish)
    end

    def delete_word_forward : Bool
      return true if delete_selection
      start = @cursor
      move_word_right
      finish = @cursor
      @cursor = start
      delete_range(start, finish)
    end

    private def move_to(position : Int32, extend_selection : Bool) : Nil
      origin = @cursor
      @selection_anchor ||= origin if extend_selection
      @selection_anchor = nil unless extend_selection
      @cursor = snap_boundary(position)
      @selection_anchor = nil if @selection_anchor == @cursor
    end

    private def delete_range(start_index : Int32, end_index : Int32) : Bool
      return false if start_index >= end_index

      @value = @value[0, start_index] + @value[end_index..]
      @cursor = start_index
      @selection_anchor = nil
      bump_revision
      true
    end

    private def normalize_paste(text : String) : String
      normalized = text.gsub("\r\n", "\n").gsub('\r', '\n')
      String.build do |builder|
        normalized.each_char do |char|
          if char == '\n' || char == '\t'
            builder << ' '
          elsif char == '\u2028' || char == '\u2029'
            builder << ' '
          elsif char.ord >= 32 && !(127..159).includes?(char.ord)
            builder << char
          end
        end
      end
    end

    private def snap_boundary(position : Int32) : Int32
      target = position.clamp(0, @value.size)
      boundary = 0
      @value.each_grapheme do |raw_grapheme|
        next_boundary = boundary + raw_grapheme.to_s.size
        return boundary if target < next_boundary
        return next_boundary if target == next_boundary
        boundary = next_boundary
      end
      @value.size
    end

    private def snap_boundary_forward(position : Int32) : Int32
      target = position.clamp(0, @value.size)
      boundary = 0
      @value.each_grapheme do |raw_grapheme|
        next_boundary = boundary + raw_grapheme.to_s.size
        return boundary if target == boundary
        return next_boundary if target <= next_boundary
        boundary = next_boundary
      end
      @value.size
    end

    private def previous_boundary(position : Int32) : Int32
      target = snap_boundary(position)
      previous = 0
      @value.each_grapheme do |raw_grapheme|
        next_boundary = previous + raw_grapheme.to_s.size
        return previous if target <= next_boundary
        previous = next_boundary
      end
      previous
    end

    private def next_boundary(position : Int32) : Int32
      target = snap_boundary(position)
      offset = 0
      @value.each_grapheme do |raw_grapheme|
        offset += raw_grapheme.to_s.size
        return offset if target < offset
      end
      @value.size
    end

    private def grapheme_ranges : Array({Int32, Int32})
      ranges = [] of {Int32, Int32}
      offset = 0
      @value.each_grapheme do |raw_grapheme|
        finish = offset + raw_grapheme.to_s.size
        ranges << {offset, finish}
        offset = finish
      end
      ranges
    end

    private def grapheme_whitespace?(range : {Int32, Int32}) : Bool
      @value[range[0], range[1] - range[0]].each_char.all?(&.whitespace?)
    end

    private def within_limit?(candidate : String) : Bool
      limit = @max_codepoints
      limit.nil? || candidate.size <= limit
    end

    private def validate_limit!(candidate : String) : Nil
      raise ArgumentError.new("editable input limit must be positive") if @max_codepoints && @max_codepoints.not_nil! <= 0
      raise ArgumentError.new("editable input value exceeds limit") unless within_limit?(candidate)
    end

    private def bump_revision : Nil
      @revision &+= 1_u64
    end
  end
end
