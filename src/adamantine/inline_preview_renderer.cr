require "crystal_tui"

require "../adamantine/inline_edit_preview"
require "../adamantine/theme"

module Adamantine
  # Paints a detached document-edit model over the active editor pane.  The
  # renderer deliberately knows nothing about applying an edit: it only reads
  # bounded rows from the model and writes cells inside the editor/clip
  # intersection.
  module InlinePreviewRenderer
    INLINE_PREVIEW_FOOTER         = "Enter Accept all | Esc Reject"
    INLINE_PREVIEW_NARROW         = "Enter=Accept Esc=Reject"
    INLINE_PREVIEW_COMPACT        = "Enter+ Esc-"
    INLINE_PREVIEW_TINY           = "↵+ Esc-"
    INLINE_PREVIEW_SELECT_FOOTER  = "Enter Apply selected | Space Toggle | A All | N None | Esc Reject"
    INLINE_PREVIEW_SELECT_NARROW  = "Enter=Apply Space=Toggle A=All N=None Esc=Reject"
    INLINE_PREVIEW_SELECT_COMPACT = "Enter Apply · Space Toggle · A All · N None · Esc Reject"
    INLINE_PREVIEW_SELECT_TINY    = "↵Apply ␠Toggle A All N None Esc-"
    INLINE_PREVIEW_RESIZE_FULL    = "Resize editor to review | Esc Reject"
    INLINE_PREVIEW_RESIZE_NARROW  = "Resize=Review Esc=Reject"
    # `Esc-` mirrors the compact accept/reject legend (`Enter+ Esc-`).
    INLINE_PREVIEW_RESIZE_COMPACT = "Resize Esc-"
    INLINE_PREVIEW_RESIZE_TINY    = "Resize"
    INLINE_PREVIEW_SCOPE          = "buffer only; not saved"

    private def render_inline_edit_preview(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      preview : InlineEditPreview::Model,
      title : String? = nil,
      scope : String? = nil,
      footer_controls : String? = nil,
      footer_controls_narrow : String? = nil,
      footer_controls_compact : String? = nil,
      footer_controls_tiny : String? = nil,
      target_rect : Tui::Rect? = nil,
      tab_size : Int32? = nil,
    ) : Nil
      editor = current_editor
      editor_rect = target_rect || editor.try(&.rect)
      return unless editor_rect
      reviewable = inline_preview_reviewable?(preview, editor_rect)
      if !reviewable
        footer_controls = INLINE_PREVIEW_RESIZE_FULL
        footer_controls_narrow = INLINE_PREVIEW_RESIZE_NARROW
        footer_controls_compact = INLINE_PREVIEW_RESIZE_COMPACT
        footer_controls_tiny = INLINE_PREVIEW_RESIZE_TINY
      elsif preview.selective_acceptance_available? && footer_controls.nil?
        footer_controls = INLINE_PREVIEW_SELECT_FOOTER
        footer_controls_narrow ||= INLINE_PREVIEW_SELECT_NARROW
        footer_controls_compact ||= INLINE_PREVIEW_SELECT_COMPACT
        footer_controls_tiny ||= INLINE_PREVIEW_SELECT_TINY
      end
      paint_clip = editor_rect.intersect(clip)
      return unless paint_clip
      return if paint_clip.empty?

      base_style = Tui::Style.new(fg: Theme::Editor.text_fg, bg: Theme::Editor.text_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, bg: Theme::Editor.text_bg, attrs: Tui::Attributes::Bold)
      footer_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Editor.text_bg)
      context_style = base_style
      removed_style = Tui::Style.new(fg: Theme::Status.error, bg: Theme::Editor.text_bg)
      added_style = Tui::Style.new(fg: Theme::Status.success, bg: Theme::Editor.text_bg)

      # Replace the active editor projection completely.  The fill is scoped
      # to the intersection, so overlays cannot erase a neighboring panel when
      # the terminal supplies a smaller clip.
      paint_clip.each_cell do |x, y|
        inline_preview_set_cell(buffer, paint_clip, x, y, Tui::Cell.new(' ', base_style))
      end

      title = inline_preview_title(preview.title, title, scope)
      if preview.selective_acceptance_available?
        selected = preview.selected_group_count
        total = preview.source_edit_group_count
        focus = preview.focused_edit_group_index + 1
        title = "selected #{selected}/#{total} · group #{focus}/#{total} · #{title}"
      end

      if editor_rect.height == 1
        # At one row the action affordance is the safety-critical content.
        # Put it first so clipping cannot leave a user with a title and no
        # visible way to accept or reject the proposal.
        actions = inline_preview_action_labels(
          editor_rect.width,
          footer_controls,
          footer_controls_narrow,
          footer_controls_compact,
          footer_controls_tiny
        )
        draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, editor_rect.y, "#{actions} · #{title}", footer_style, editor_rect.width)
        return
      end

      draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, editor_rect.y, title, title_style, editor_rect.width)

      body_rows = editor_rect.height - 2
      if body_rows > 0
        row_count = preview.row_count
        max_top = [row_count - body_rows, 0].max
        preview.scroll_top = preview.top.clamp(0, max_top)
        top = preview.top
        line_digits = [row_count, 1].max.to_s.size
        # Always show both source and candidate line coordinates.  A single
        # number becomes ambiguous when an insertion shifts following context.
        selectable = preview.selective_acceptance_available?
        gutter_width = (line_digits * 2) + 4
        resolved_tab_size = (tab_size || editor.try(&.tab_size) || 4).clamp(1, 8)
        available = editor_rect.width - gutter_width
        preview.horizontal_step = [available - 1, 1].max

        body_rows.times do |offset|
          y = editor_rect.y + 1 + offset
          index = top + offset
          row = index < row_count ? preview.row_at(index) : nil
          unless row
            draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, y, "", base_style, editor_rect.width)
            next
          end

          style = if row.removed?
                    removed_style
                  elsif row.added?
                    added_style
                  else
                    context_style
                  end

          marker = row.prefix.to_s
          old_number = row.old_line ? row.old_line.not_nil!.to_s.rjust(line_digits) : "-".rjust(line_digits)
          new_number = row.new_line ? row.new_line.not_nil!.to_s.rjust(line_digits) : "-".rjust(line_digits)
          group_marker = if selectable && preview.edit_group_index_for_row(index) != nil
                           focused = preview.focused_edit_group_for_row?(index)
                           selected = preview.selected_edit_group_for_row?(index)
                           focused ? (selected ? ">" : "!") : (selected ? "x" : " ")
                         else
                           ""
                         end
          gutter = "#{marker}#{old_number}/#{new_number} #{group_marker}"
          gutter = gutter.ljust(gutter_width)

          text = inline_preview_row_text(row, resolved_tab_size, preview.row_text_window(index))
          draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, y, gutter, style, editor_rect.width)
          if available > 0
            draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x + gutter_width, y, text, style, available)
          end
        end
      end

      footer_y = editor_rect.bottom - 1
      visible_end = [preview.top + [editor_rect.height - 2, 0].max, preview.row_count].min
      position = reviewable && preview.row_count > 0 ? "#{preview.top + 1}-#{visible_end}/#{preview.row_count} · cp #{preview.horizontal_offset.to_i64 + 1}" : ""
      footer = inline_preview_footer(
        position,
        editor_rect.width,
        footer_controls,
        footer_controls_narrow,
        footer_controls_compact,
        footer_controls_tiny,
        append_navigation: preview.selective_acceptance_available? && footer_controls == INLINE_PREVIEW_SELECT_FOOTER
      )
      draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, footer_y, footer, footer_style, editor_rect.width)
    end

    # Acceptance is enabled only when at least one row exposes proposed source
    # text. Keep this predicate shared with the modal's Enter guard so the
    # visible affordance and behavior use the same geometry rule.
    private def inline_preview_reviewable?(preview : InlineEditPreview::Model, editor_rect : Tui::Rect) : Bool
      return false if editor_rect.height - 2 <= 0

      row_count = preview.row_count
      return false if row_count <= 0
      line_digits = [row_count, 1].max.to_s.size
      gutter_width = (line_digits * 2) + 4
      editor_rect.width - gutter_width > 0
    end

    # Render an unavailable candidate without manufacturing an empty disk
    # document.  This shares the same bounded pane/controls path as a real
    # projection, so the safety affordance stays visible at narrow sizes.
    private def render_inline_preview_message(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      title : String,
      message : String,
      scope : String? = nil,
      footer_controls : String? = nil,
      footer_controls_narrow : String? = nil,
      footer_controls_compact : String? = nil,
      footer_controls_tiny : String? = nil,
      target_rect : Tui::Rect? = nil,
      tab_size : Int32? = nil,
    ) : Nil
      editor = current_editor
      editor_rect = target_rect || editor.try(&.rect)
      return unless editor_rect
      paint_clip = editor_rect.intersect(clip)
      return unless paint_clip
      return if paint_clip.empty?

      base_style = Tui::Style.new(fg: Theme::Editor.text_fg, bg: Theme::Editor.text_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, bg: Theme::Editor.text_bg, attrs: Tui::Attributes::Bold)
      footer_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Editor.text_bg)

      paint_clip.each_cell do |x, y|
        inline_preview_set_cell(buffer, paint_clip, x, y, Tui::Cell.new(' ', base_style))
      end

      rendered_title = inline_preview_title(title, title, scope)
      if editor_rect.height == 1
        controls = inline_preview_action_labels(
          editor_rect.width,
          footer_controls,
          footer_controls_narrow,
          footer_controls_compact,
          footer_controls_tiny
        )
        draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, editor_rect.y, "#{controls} · #{rendered_title}", footer_style, editor_rect.width)
        return
      end

      draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, editor_rect.y, rendered_title, title_style, editor_rect.width)
      body_rows = editor_rect.height - 2
      if body_rows > 0
        safe_message = inline_preview_sanitize(message)
        draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, editor_rect.y + 1, safe_message, base_style, editor_rect.width)
        (1...body_rows).each do |offset|
          draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, editor_rect.y + 1 + offset, "", base_style, editor_rect.width)
        end
      end
      footer_y = editor_rect.bottom - 1
      footer = inline_preview_footer(
        "",
        editor_rect.width,
        footer_controls,
        footer_controls_narrow,
        footer_controls_compact,
        footer_controls_tiny
      )
      draw_inline_preview_text(buffer, editor_rect, paint_clip, editor_rect.x, footer_y, footer, footer_style, editor_rect.width)
    end

    private def inline_preview_title(default_title : String, requested_title : String?, requested_scope : String?) : String
      title = requested_title || default_title
      effective_scope = if requested_scope.nil?
                          downcased = title.downcase
                          if downcased.includes?("buffer only") || downcased.includes?("not saved")
                            nil
                          else
                            INLINE_PREVIEW_SCOPE
                          end
                        elsif requested_scope.empty?
                          nil
                        else
                          requested_scope
                        end
      effective_scope ? "#{title} · #{effective_scope}" : title
    end

    private def inline_preview_footer(
      position : String,
      width : Int32,
      footer_controls : String? = nil,
      footer_controls_narrow : String? = nil,
      footer_controls_compact : String? = nil,
      footer_controls_tiny : String? = nil,
      append_navigation : Bool = false,
    ) : String
      custom_controls = !footer_controls.nil?
      controls = inline_preview_action_labels(
        width,
        footer_controls,
        footer_controls_narrow,
        footer_controls_compact,
        footer_controls_tiny
      )
      result = controls
      unless position.empty?
        candidate = "#{result} | #{position}"
        result = candidate if Tui::Unicode.display_width(candidate) <= width
      end
      if !custom_controls || append_navigation
        navigations = append_navigation ? ["←→ Page", "Shift-←→ 1cp", "Tab Next", "Shift-Tab Previous"] : ["Tab Next", "Shift-Tab Previous", "←→ Page", "Shift-←→ 1cp"]
        navigations.each do |navigation|
          candidate = "#{result} | #{navigation}"
          result = candidate if Tui::Unicode.display_width(candidate) <= width
        end
      end
      result
    end

    private def inline_preview_action_labels(
      width : Int32,
      full : String? = nil,
      narrow : String? = nil,
      compact : String? = nil,
      tiny : String? = nil,
    ) : String
      if full
        candidates = [full, narrow, compact, tiny].compact
        candidates.each do |candidate|
          return candidate if Tui::Unicode.display_width(candidate) <= width
        end
        # A custom footer must never fall back to Enter Accept/Esc Reject. If
        # the pane is narrower than every supplied variant, clip the smallest
        # custom affordance by display cells instead.
        return inline_preview_truncate(candidates.last? || full, width)
      end

      if Tui::Unicode.display_width(INLINE_PREVIEW_FOOTER) <= width
        INLINE_PREVIEW_FOOTER
      elsif Tui::Unicode.display_width(INLINE_PREVIEW_NARROW) <= width
        INLINE_PREVIEW_NARROW
      elsif Tui::Unicode.display_width(INLINE_PREVIEW_COMPACT) <= width
        INLINE_PREVIEW_COMPACT
      else
        INLINE_PREVIEW_TINY
      end
    end

    private def inline_preview_row_text(row : InlineEditPreview::Row, tab_size : Int32, source_text : String = row.text) : String
      text = inline_preview_expand_tabs(source_text, tab_size.clamp(1, 8))
      return text unless row.removed? || row.added? || row.eol_changed?

      "#{text} #{inline_preview_eol_label(row.line_ending)}"
    end

    private def inline_preview_eol_label(line_ending : String) : String
      label = case line_ending
              when "\r\n"      then "CRLF"
              when "\n"        then "LF"
              when "\r"        then "CR"
              when ""          then "EOF"
              when "<changed>" then "changed"
              else                  "other"
              end
      "[EOL:#{label}]"
    end

    private def inline_preview_expand_tabs(text : String, tab_size : Int32) : String
      column = 0
      String.build do |builder|
        text.each_grapheme do |grapheme|
          glyph = grapheme.to_s
          if glyph == "\t"
            spaces = tab_size - (column % tab_size)
            spaces.times { builder << ' ' }
            column += spaces
          else
            safe_glyph = inline_preview_sanitize(glyph)
            glyph_width = Tui::Unicode.grapheme_width(safe_glyph)
            # A bounded head/tail slice can begin with a combining cluster.
            # Give it a visible base so it cannot attach to the gutter or to a
            # terminal cell painted by the neighboring widget.
            if column == 0 && glyph_width == 0
              builder << "◌"
              column += 1
            end
            builder << safe_glyph
            column += glyph_width
          end
        end
      end
    end

    private def inline_preview_sanitize(text : String) : String
      String.build do |builder|
        text.each_char do |char|
          codepoint = char.ord
          if codepoint == 0x1B
            builder << "␛"
          elsif codepoint <= 0x1F || (codepoint >= 0x7F && codepoint <= 0x9F)
            builder << '�'
          elsif (0x202A..0x202E).includes?(codepoint) || (0x2066..0x2069).includes?(codepoint) ||
                {0x061C, 0x200E, 0x200F}.includes?(codepoint)
            builder << '�'
          else
            builder << char
          end
        end
      end
    end

    private def draw_inline_preview_text(
      buffer : Tui::Buffer,
      editor_rect : Tui::Rect,
      paint_clip : Tui::Rect,
      x : Int32,
      y : Int32,
      text : String,
      style : Tui::Style,
      width : Int32,
    ) : Nil
      return if width <= 0 || y < editor_rect.y || y >= editor_rect.bottom

      clipped = inline_preview_truncate(inline_preview_sanitize(text), width)
      current_x = x
      clipped.each_grapheme do |grapheme|
        glyph = grapheme.to_s
        glyph_width = Tui::Unicode.grapheme_width(glyph)
        if glyph_width == 1
          buffer.set(current_x, y, Tui::Cell.text(glyph, style)) if paint_clip.contains?(current_x, y)
        elsif glyph_width == 2
          # Write each cell independently. Buffer#set_wide would always write
          # the continuation cell too, which could cross a partial clip.
          if paint_clip.contains?(current_x, y)
            # The terminal cannot paint half a glyph: a leading wide cell
            # at the right clip edge would physically overwrite its neighbor
            # even if the buffer's continuation cell were not updated.
            cell = paint_clip.contains?(current_x + 1, y) ? Tui::Cell.text(glyph, style, wide: true) : Tui::Cell.new(' ', style)
            inline_preview_set_cell(buffer, paint_clip, current_x, y, cell)
          end
          if paint_clip.contains?(current_x + 1, y)
            inline_preview_set_cell(buffer, paint_clip, current_x + 1, y, Tui::Cell.continuation(style))
          end
        elsif glyph_width > 0 && paint_clip.contains?(current_x, y)
          inline_preview_set_cell(buffer, paint_clip, current_x, y, Tui::Cell.text(glyph, style))
        end
        current_x += glyph_width
      end
    end

    private def inline_preview_set_cell(
      buffer : Tui::Buffer,
      paint_clip : Tui::Rect,
      x : Int32,
      y : Int32,
      cell : Tui::Cell,
    ) : Nil
      return unless paint_clip.contains?(x, y)

      # Buffer#set repairs a wide lead when a continuation cell is replaced.
      # If that lead is just outside this clip, restore it so a partial
      # overlay cannot mutate a neighboring widget's existing cell.
      previous = x > 0 ? buffer.get(x - 1, y) : Tui::Cell.empty
      old = buffer.get(x, y)
      buffer.set(x, y, cell)
      if x > 0 && !paint_clip.contains?(x - 1, y) && old.continuation? && !cell.continuation? && previous.wide?
        buffer.set(x - 1, y, previous)
      end
    end

    # Truncate by terminal cells rather than bytes/codepoints.  A visible
    # ellipsis is part of the review contract whenever the candidate row is
    # wider than the pane.
    private def inline_preview_truncate(text : String, max_width : Int32) : String
      return "" if max_width <= 0

      text_width = Tui::Unicode.display_width(text)
      return text if text_width <= max_width

      marker = "…"
      marker_width = Tui::Unicode.grapheme_width(marker)
      return marker if marker_width >= max_width

      String.build do |builder|
        used = 0
        text.each_grapheme do |grapheme|
          glyph = grapheme.to_s
          glyph_width = Tui::Unicode.grapheme_width(glyph)
          break if used + glyph_width + marker_width > max_width
          builder << glyph
          used += glyph_width
        end
        builder << marker
      end
    end
  end
end
