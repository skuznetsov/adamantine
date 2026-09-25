require "crystal_tui"

require "./editable_input"

module Adamantine
  # Paints one materialized EditableInput into a single terminal row.
  #
  # EditableInput positions are codepoint offsets at grapheme boundaries. The
  # renderer keeps that coordinate system separate from terminal-cell
  # offsets, and only emits a grapheme after its complete display width fits
  # inside the horizontal viewport.
  module EditableInputRenderer
    DEFAULT_TEXT_STYLE      = Tui::Style.default
    DEFAULT_SELECTION_STYLE = Tui::Style.new(attrs: Tui::Attributes::Reverse)
    DEFAULT_CURSOR_STYLE    = Tui::Style.new(attrs: Tui::Attributes::Reverse)

    private struct Grapheme
      getter start_offset : Int32
      getter end_offset : Int32
      getter cell_start : Int32
      getter width : Int32
      getter text : String

      def initialize(
        @start_offset : Int32,
        @end_offset : Int32,
        @cell_start : Int32,
        @width : Int32,
        @text : String,
      )
      end

      def cell_end : Int32
        @cell_start + @width
      end
    end

    # Render the first row of +rect+.  +clip+ is optional so callers that
    # render through an overlay can restrict writes without changing the
    # viewport's logical width.
    def self.render(
      buffer : Tui::Buffer,
      rect : Tui::Rect,
      input : EditableInput,
      text_style : Tui::Style = DEFAULT_TEXT_STYLE,
      selection_style : Tui::Style = DEFAULT_SELECTION_STYLE,
      cursor_style : Tui::Style = DEFAULT_CURSOR_STYLE,
      clip : Tui::Rect? = nil,
    ) : Nil
      return if rect.empty?

      clipped = clip ? rect.intersect(clip) : rect
      return unless clipped
      clipped = clipped.not_nil!
      line_clip = Tui::Rect.new(clipped.x, rect.y, clipped.width, 1)
      clusters = graphemes(input.value)
      viewport_start = viewport_start(clusters, input.cursor, rect.width)
      viewport_end = viewport_start + rect.width
      selection = input.selection_range
      cursor_index = cursor_cluster_index(clusters, input.cursor)
      cursor_visible = false

      line_clip.width.times do |offset|
        set_cell(buffer, line_clip, line_clip.x + offset, rect.y, Tui::Cell.new(' ', text_style))
      end

      clusters.each_with_index do |cluster, index|
        next if cluster.width <= 0
        next if cluster.cell_start < viewport_start
        next if cluster.cell_end > viewport_end

        x = rect.x + cluster.cell_start - viewport_start
        style = if cursor_index == index
                  cursor_style
                elsif selected?(cluster, selection)
                  selection_style
                else
                  text_style
                end

        drawn = draw_grapheme(buffer, line_clip, x, rect.y, cluster, style)
        cursor_visible ||= drawn && cursor_index == index
      end

      unless cursor_visible
        cursor_cell = cursor_cell_offset(clusters, input.cursor)
        cursor_x = rect.x + cursor_cell - viewport_start
        if cursor_x >= rect.x && cursor_x < rect.right
          set_cell(buffer, line_clip, cursor_x, rect.y, Tui::Cell.new(' ', cursor_style))
        end
      end
    end

    # Instance-facing adapter for App/spec harnesses that include this module.
    def render_editable_input(
      buffer : Tui::Buffer,
      rect : Tui::Rect,
      input : EditableInput,
      text_style : Tui::Style = EditableInputRenderer::DEFAULT_TEXT_STYLE,
      selection_style : Tui::Style = EditableInputRenderer::DEFAULT_SELECTION_STYLE,
      cursor_style : Tui::Style = EditableInputRenderer::DEFAULT_CURSOR_STYLE,
      clip : Tui::Rect? = nil,
    ) : Nil
      EditableInputRenderer.render(buffer, rect, input, text_style, selection_style, cursor_style, clip)
    end

    private def self.graphemes(value : String) : Array(Grapheme)
      result = [] of Grapheme
      codepoint_offset = 0
      cell_offset = 0

      value.each_grapheme do |raw_grapheme|
        text = raw_grapheme.to_s
        width = Tui::Unicode.grapheme_width(text)
        width = 0 if width < 0
        result << Grapheme.new(
          codepoint_offset,
          codepoint_offset + text.size,
          cell_offset,
          width,
          text,
        )
        codepoint_offset += text.size
        cell_offset += width
      end

      result
    end

    private def self.cursor_cluster_index(clusters : Array(Grapheme), cursor : Int32) : Int32?
      clusters.each_with_index do |cluster, index|
        next if cluster.width <= 0
        return index if cluster.start_offset >= cursor
      end
      nil
    end

    private def self.cursor_cell_offset(clusters : Array(Grapheme), cursor : Int32) : Int32
      clusters.each do |cluster|
        return cluster.cell_start if cursor <= cluster.start_offset
        return cluster.cell_end if cursor <= cluster.end_offset
      end
      clusters.last?.try(&.cell_end) || 0
    end

    private def self.viewport_start(clusters : Array(Grapheme), cursor : Int32, width : Int32) : Int32
      return 0 if width <= 0

      cursor_cell = cursor_cell_offset(clusters, cursor)
      desired = [cursor_cell - width + 1, 0].max

      # A stateless renderer may start in the middle of a wide grapheme when
      # the caret is near the right edge.  Advance to that grapheme's end so
      # the draw pass can omit it wholesale instead of exposing half of it.
      clusters.each do |cluster|
        next if cluster.width <= 1
        if cluster.cell_start < desired && desired < cluster.cell_end
          desired = cluster.cell_end
          break
        end
      end

      [desired, cursor_cell].min
    end

    private def self.selected?(cluster : Grapheme, selection : {Int32, Int32}?) : Bool
      range = selection
      return false unless range

      cluster.start_offset >= range[0] && cluster.end_offset <= range[1] &&
        cluster.end_offset > cluster.start_offset
    end

    private def self.draw_grapheme(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      x : Int32,
      y : Int32,
      cluster : Grapheme,
      style : Tui::Style,
    ) : Bool
      return false unless cluster.width == 1 || cluster.width == 2
      return false unless x >= clip.x && x + cluster.width <= clip.right
      return false unless buffer.in_bounds?(x, y) && buffer.in_bounds?(x + cluster.width - 1, y)

      if cluster.width == 2
        set_cell(buffer, clip, x, y, Tui::Cell.text(cluster.text, style, wide: true))
        set_cell(buffer, clip, x + 1, y, Tui::Cell.continuation(style))
      else
        set_cell(buffer, clip, x, y, Tui::Cell.text(cluster.text, style))
      end
      true
    end

    private def self.set_cell(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      x : Int32,
      y : Int32,
      cell : Tui::Cell,
    ) : Nil
      return unless clip.contains?(x, y)

      old = buffer.get(x, y)
      if old.continuation? && x > 0 && !clip.contains?(x - 1, y) && buffer.get(x - 1, y).wide?
        return
      end
      if old.wide? && buffer.in_bounds?(x + 1, y) && !clip.contains?(x + 1, y) && buffer.get(x + 1, y).continuation?
        return
      end

      buffer.set(x, y, cell)
    end
  end
end
