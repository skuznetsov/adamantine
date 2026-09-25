# App-owned Unicode layout primitives.
#
# The pinned TUI dependency exposes a piece-tree line slice in codepoint
# coordinates and a grapheme-aware display-width helper.  Keep the bridge here
# so the editor can stream a line in bounded chunks without asking the
# dependency for a materialized line or changing its public cursor contract.
module Adamantine
  module UnicodeLayout
    CHUNK_CODEPOINTS = 1024
    # Deep cursor mapping must not allocate one String for every ASCII cell.
    # These immutable strings also cover tabs, whose width is position-dependent.
    ASCII_GLYPHS = Array.new(128) { |value| value.chr.to_s }

    struct Cluster
      getter start_col : Int32
      getter end_col : Int32
      getter cell_start : Int32
      getter width : Int32
      getter text : String

      def initialize(
        @start_col : Int32,
        @end_col : Int32,
        @cell_start : Int32,
        @width : Int32,
        @text : String,
      )
      end

      def cell_end : Int32
        @cell_start + @width
      end
    end

    # A scan can stop as soon as the viewport is known to be past the next
    # cluster.  +cell_width+ is exact only for a complete scan.
    struct ScanResult
      getter complete : Bool
      getter cell_width : Int32

      def initialize(@complete : Bool, @cell_width : Int32)
      end
    end

    # Visit grapheme clusters in one logical line.  Segmentation state and a
    # single in-progress builder cross chunk boundaries, so a combining or ZWJ
    # sequence split at a read boundary is never exposed as two clusters.
    # Returning false from the block stops the scan after the current prefix.
    def self.each_cluster(
      buffer : Tui::PieceTreeBuffer,
      line : Int32,
      tab_size : Int32,
      limit_cell : Int32? = nil,
      &block : Cluster -> Bool
    ) : ScanResult
      length = buffer.line_character_length(line)
      return ScanResult.new(true, 0) if length == 0

      tab_width = tab_size.clamp(1, 8)
      codepoint_offset = 0
      cell_offset = 0
      stopped = false
      cluster_start = 0
      cluster_first_char : Char? = nil
      cluster_builder : String::Builder? = nil
      previous_property : String::Grapheme::Property? = nil
      grapheme_state = String::Grapheme::Property::Start

      while codepoint_offset < length
        take = Math.min(CHUNK_CODEPOINTS, length - codepoint_offset)
        chunk = buffer.line_slice(line, codepoint_offset, take)
        chunk.each_char do |char|
          property = String::Grapheme::Property.from(char)

          if previous_property
            boundary, grapheme_state = String::Grapheme.break?(previous_property.not_nil!, property, grapheme_state)
            if boundary
              text = if builder = cluster_builder
                       builder.to_s
                     else
                       single_character_text(cluster_first_char.not_nil!)
                     end
              cluster_end = codepoint_offset
              cluster = Cluster.new(
                cluster_start,
                cluster_end,
                cell_offset,
                cluster_width(text, cell_offset, tab_width),
                text
              )

              if limit_cell && cluster.cell_start >= limit_cell
                stopped = true
                break
              end

              cell_offset += cluster.width
              unless yield cluster
                stopped = true
                break
              end

              cluster_start = codepoint_offset
              cluster_first_char = nil
              cluster_builder = nil
            end
          end

          if builder = cluster_builder
            builder << char
          elsif first_char = cluster_first_char
            builder = String::Builder.new(16)
            builder << first_char
            builder << char
            cluster_builder = builder
          else
            cluster_first_char = char
          end
          previous_property = property
          codepoint_offset += 1
        end

        break if stopped
      end

      return ScanResult.new(false, cell_offset) if stopped

      unless cluster_first_char.nil? && cluster_builder.nil?
        text = if builder = cluster_builder
                 builder.to_s
               else
                 single_character_text(cluster_first_char.not_nil!)
               end
        cluster = Cluster.new(
          cluster_start,
          length,
          cell_offset,
          cluster_width(text, cell_offset, tab_width),
          text
        )

        if limit_cell && cluster.cell_start >= limit_cell
          return ScanResult.new(false, cell_offset)
        end

        cell_offset += cluster.width
        return ScanResult.new(false, cell_offset) unless yield cluster
      end

      ScanResult.new(true, cell_offset)
    end

    private def self.single_character_text(char : Char) : String
      char.ascii? ? ASCII_GLYPHS[char.ord] : char.to_s
    end

    def self.cell_offset_for_column(
      buffer : Tui::PieceTreeBuffer,
      line : Int32,
      column : Int32,
      tab_size : Int32,
    ) : Int32
      target = column.clamp(0, buffer.line_character_length(line))
      result = 0

      each_cluster(buffer, line, tab_size) do |cluster|
        if target < cluster.end_col
          result = cluster.cell_start
          false
        elsif target == cluster.end_col
          result = cluster.cell_end
          false
        else
          true
        end
      end

      result
    end

    # Return the grapheme interval containing +column+, or an empty interval
    # when the column is already on a cluster boundary.  The latter distinction
    # is important for forward delete: a caret at the boundary before `b` must
    # remove `b`, not the preceding `a`.
    def self.cluster_bounds_at(
      buffer : Tui::PieceTreeBuffer,
      line : Int32,
      column : Int32,
      tab_size : Int32,
    ) : {Int32, Int32}
      target = column.clamp(0, buffer.line_character_length(line))
      result = {target, target}

      each_cluster(buffer, line, tab_size) do |cluster|
        if target < cluster.end_col
          result = {cluster.start_col, cluster.end_col}
          false
        elsif target == cluster.end_col
          result = {target, target}
          false
        else
          true
        end
      end

      result
    end

    def self.column_at_cell(
      buffer : Tui::PieceTreeBuffer,
      line : Int32,
      cell : Int32,
      tab_size : Int32,
    ) : Int32
      length = buffer.line_character_length(line)
      target = cell.clamp(0, Int32::MAX)
      result = length

      each_cluster(buffer, line, tab_size) do |cluster|
        if target < cluster.cell_start
          result = cluster.start_col
          false
        elsif cluster.width == 0
          if target == cluster.cell_start
            result = cluster.end_col
            false
          else
            true
          end
        elsif target < cluster.cell_end
          offset = target - cluster.cell_start
          midpoint = (cluster.width + 1) // 2
          result = offset < midpoint ? cluster.start_col : cluster.end_col
          false
        elsif target == cluster.cell_end
          result = cluster.end_col
          false
        else
          true
        end
      end

      result.clamp(0, length)
    end

    def self.previous_boundary(
      buffer : Tui::PieceTreeBuffer,
      line : Int32,
      column : Int32,
      tab_size : Int32,
    ) : Int32
      target = column.clamp(0, buffer.line_character_length(line))
      result = 0

      each_cluster(buffer, line, tab_size) do |cluster|
        if target <= cluster.start_col
          false
        elsif target <= cluster.end_col
          result = cluster.start_col
          false
        else
          result = cluster.end_col
          true
        end
      end

      result
    end

    def self.next_boundary(
      buffer : Tui::PieceTreeBuffer,
      line : Int32,
      column : Int32,
      tab_size : Int32,
    ) : Int32
      target = column.clamp(0, buffer.line_character_length(line))
      result = buffer.line_character_length(line)

      each_cluster(buffer, line, tab_size) do |cluster|
        if target < cluster.end_col
          result = cluster.end_col
          false
        else
          true
        end
      end

      result
    end

    private def self.cluster_width(text : String, cell_start : Int32, tab_size : Int32) : Int32
      return tab_size - (cell_start % tab_size) if text == "\t"
      Tui::Unicode.grapheme_width(text)
    end
  end
end
