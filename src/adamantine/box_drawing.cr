module Adamantine
  module BoxDrawing
    private def draw_box_border(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      x : Int32,
      y : Int32,
      width : Int32,
      height : Int32,
      border_style : Tui::Style,
      fill_style : Tui::Style,
      title : String? = nil,
      title_style : Tui::Style? = nil,
    ) : Nil
      return if width < 2 || height < 2

      # Top border: ┌─────┐
      buffer.set(x, y, '┌', border_style) if clip.contains?(x, y)
      (1...width - 1).each do |dx|
        buffer.set(x + dx, y, '─', border_style) if clip.contains?(x + dx, y)
      end
      buffer.set(x + width - 1, y, '┐', border_style) if clip.contains?(x + width - 1, y)

      # Title overlay on top border
      if title && !title.empty?
        t_style = title_style || border_style
        title_x = x + 1
        title_right = x + width - 1
        title.each_grapheme do |grapheme|
          glyph = grapheme.to_s
          glyph_width = Tui::Unicode.grapheme_width(glyph)
          break if glyph_width > 0 && title_x + glyph_width > title_right
          buffer.set(title_x, y, glyph, t_style) if title_x < title_right && clip.contains?(title_x, y)
          title_x += glyph_width
        end
      end

      # Middle rows: │     │ with fill
      (1...height - 1).each do |dy|
        row_y = y + dy
        break if row_y >= clip.bottom
        buffer.set(x, row_y, '│', border_style) if clip.contains?(x, row_y)
        (1...width - 1).each do |dx|
          buffer.set(x + dx, row_y, ' ', fill_style) if clip.contains?(x + dx, row_y)
        end
        buffer.set(x + width - 1, row_y, '│', border_style) if clip.contains?(x + width - 1, row_y)
      end

      # Bottom border: └─────┘
      bottom_y = y + height - 1
      if bottom_y < clip.bottom
        buffer.set(x, bottom_y, '└', border_style) if clip.contains?(x, bottom_y)
        (1...width - 1).each do |dx|
          buffer.set(x + dx, bottom_y, '─', border_style) if clip.contains?(x + dx, bottom_y)
        end
        buffer.set(x + width - 1, bottom_y, '┘', border_style) if clip.contains?(x + width - 1, bottom_y)
      end
    end

    private def draw_text_line(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      x : Int32,
      y : Int32,
      text : String,
      style : Tui::Style,
      max_width : Int32,
    ) : Nil
      return if max_width <= 0

      max_width.times do |offset|
        cell_x = x + offset
        buffer.set(cell_x, y, ' ', style) if clip.contains?(cell_x, y)
      end

      text_x = x
      used_width = 0
      text.each_grapheme do |grapheme|
        glyph = grapheme.to_s
        glyph_width = Tui::Unicode.grapheme_width(glyph)
        break if glyph_width > 0 && used_width + glyph_width > max_width
        buffer.set(text_x, y, glyph, style) if clip.contains?(text_x, y)
        text_x += glyph_width
        used_width += glyph_width
      end
    end
  end
end
