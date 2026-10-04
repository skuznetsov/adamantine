require "crystal_tui"
require "./debug_variable_tree"

module Adamantine::Debugging
  # Bounded, language-neutral formatting for the Variables pane and detail
  # modal. It deliberately treats adapter text as opaque display input.
  class DebugVariablePresenter
    ELLIPSIS         = "…"
    MAX_INDENT_CELLS =    8
    MAX_DETAIL_LINES = 4096

    def self.row(node : DebugVariableNode, depth : Int32, expanded : Bool, max_cells : Int32) : String
      width = max_cells.clamp(0, 4096)
      return "" if width == 0
      return ELLIPSIS if width <= 3

      # Keep indentation decorative: even a deeply nested node retains cells
      # for its name/value, status and (when space permits) type.
      indent_width = {depth.clamp(0, 32) * 2, MAX_INDENT_CELLS, Math.max(width - 10, 0) // 4}.min
      indent = " " * indent_width
      marker = node.expandable? ? (expanded ? "▾" : "▸") : " "
      lead = "#{indent}#{marker} "
      lead_width = Tui::Unicode.display_width(lead)
      return truncate(lead, width) if lead_width >= width

      if node.parent_id.nil?
        scope_row(node, lead, lead_width, width)
      else
        value_row(node, lead, lead_width, width)
      end
    end

    # Returns wrapped, display-safe lines and whether only a bounded prefix was
    # retained. Newlines are layout; other controls are shown as escapes.
    def self.wrap(value : String, max_cells : Int32, max_lines : Int32 = MAX_DETAIL_LINES) : Tuple(Array(String), Bool)
      width = max_cells.clamp(1, 4096)
      line_limit = max_lines.clamp(1, MAX_DETAIL_LINES)
      lines = [] of String
      line_parts = [] of String
      line_width = 0
      truncated = false

      flush = -> do
        if lines.size < line_limit
          lines << line_parts.join
          line_parts.clear
          line_width = 0
        else
          truncated = true
        end
      end

      append = ->(text : String) do
        text.each_grapheme do |raw|
          grapheme = raw.to_s
          grapheme_width = Tui::Unicode.grapheme_width(grapheme)
          if grapheme_width > width
            flush.call unless line_parts.empty?
            if lines.size < line_limit
              lines << ELLIPSIS
            end
            truncated = true
            break
          end
          if line_width + grapheme_width > width
            flush.call
            break if truncated
          end
          line_parts << grapheme
          line_width += grapheme_width
        end
      end

      unless value.valid_encoding?
        value = "[invalid text]"
      end
      value.each_grapheme do |raw|
        grapheme = raw.to_s
        if grapheme == "\n" || grapheme == "\r\n" || grapheme == "\r"
          flush.call
          break if truncated
          next
        end
        append.call(visible_controls(grapheme))
        break if truncated
      end
      flush.call unless truncated || line_parts.empty?
      lines << ELLIPSIS if lines.empty?
      if truncated
        lines[-1] = ELLIPSIS
      end
      {lines, truncated}
    end

    def self.truncate(value : String, max_cells : Int32) : String
      truncate(value, max_cells, false)
    end

    def self.truncate(value : String, max_cells : Int32, force_ellipsis : Bool) : String
      width = max_cells.clamp(0, 4096)
      return "" if width == 0
      ellipsis_width = Tui::Unicode.display_width(ELLIPSIS)
      retained = [] of String
      used = 0
      omitted = force_ellipsis
      value.each_grapheme do |raw|
        safe = visible_controls(raw.to_s)
        grapheme_width = Tui::Unicode.display_width(safe)
        if used + grapheme_width > width
          omitted = true
          break
        end
        retained << safe
        used += grapheme_width
      end
      return retained.join unless omitted
      return ELLIPSIS if width <= ellipsis_width

      target = width - ellipsis_width
      output = [] of String
      prefix_width = 0
      retained.each do |grapheme|
        grapheme_width = Tui::Unicode.display_width(grapheme)
        break if prefix_width + grapheme_width > target
        output << grapheme
        prefix_width += grapheme_width
      end
      output << ELLIPSIS
      output.join
    end

    private def self.scope_row(node : DebugVariableNode, lead : String, lead_width : Int32, width : Int32) : String
      status = case node.load_state
               when .unloaded? then width >= 36 ? "Enter: load" : "load"
               when .loading?  then "Loading…"
               when .partial?  then width >= 40 ? "Partial · m: more" : "m: more"
               when .loaded?
                 node.child_ids.empty? ? (width >= 28 ? "Empty scope" : "empty") : ""
               when .failed? then node.reason || "unavailable"
               when .cycle?  then "Cycle"
               when .limit?  then node.reason || "Limit"
               else               "unavailable"
               end
      name = node.name
      if status.empty?
        return lead + truncate(name, width - lead_width)
      end

      separator = " · "
      suffix_budget = {width - lead_width - 1, 0}.max
      status = compact_status(status, {suffix_budget - Tui::Unicode.display_width(separator), 0}.max)
      status_width = Tui::Unicode.display_width(status)
      separator_width = Tui::Unicode.display_width(separator)
      name_width = width - lead_width - separator_width - status_width
      if name_width <= 0
        return lead + truncate(status, width - lead_width)
      end
      lead + truncate(name, name_width) + separator + status
    end

    private def self.value_row(node : DebugVariableNode, lead : String, lead_width : Int32, width : Int32) : String
      raw_status = case node.load_state
                   when .unloaded? then width >= 36 ? "Enter: load" : "load"
                   when .loading?  then "Loading…"
                   when .partial?  then "m: more"
                   when .failed?   then node.reason || "unavailable"
                   when .cycle?    then "Cycle"
                   when .limit?    then node.reason || "Limit"
                   else                 ""
                   end
      name = node.name
      value = node.value
      raw_type = node.type
      if value.empty?
        return empty_summary_row(name, raw_type, raw_status, lead, lead_width, width)
      end

      # Keep the partial/load affordance and a minimally readable name/value
      # before spending cells on an optional type annotation. Source-clipped
      # summaries receive a marker even when their retained prefix fits.
      minimum_expression = 5 # one name cell, " = ", one value cell
      suffix_room = {width - lead_width - minimum_expression, 0}.max
      status = compact_status(raw_status, {suffix_room - 3, 0}.max)
      status_suffix = status.empty? ? "" : " · #{status}"
      room_after_status = width - lead_width - Tui::Unicode.display_width(status_suffix)
      # Preserve room for a visible name, separator, and value before any
      # optional type annotation is admitted.
      type_suffix = optional_type_suffix(raw_type, room_after_status - 7)
      expression_room = room_after_status - Tui::Unicode.display_width(type_suffix)

      if expression_room < minimum_expression
        type_suffix = ""
        expression_room = room_after_status
      end
      if expression_room < minimum_expression
        # At a severely constrained width, retain the adapter's summary prefix
        # and its clipping marker; optional labels/status yield first.
        return lead + truncate(value, width - lead_width, node.value_truncated)
      end

      preferred_name_budget = {expression_room // 3, 16}.min
      name_budget = {preferred_name_budget, expression_room - 5}.min.clamp(1, 16)
      rendered_name = truncate(name, name_budget)
      value_budget = expression_room - Tui::Unicode.display_width(rendered_name) - 3
      value_budget = {value_budget, 1}.max
      rendered_value = truncate(value, value_budget, node.value_truncated)
      "#{lead}#{rendered_name} = #{rendered_value}#{type_suffix}#{status_suffix}"
    end

    private def self.empty_summary_row(name : String, raw_type : String?, raw_status : String,
                                       lead : String, lead_width : Int32, width : Int32) : String
      # An absent adapter summary is UI state, not the fabricated language
      # value `""`; an adapter that supplied the literal characters `""`
      # follows the ordinary nonempty-value path above.
      empty_label = "empty summary"
      status = compact_status(raw_status, {width - lead_width - 3 - Tui::Unicode.display_width(empty_label) - 1, 0}.max)
      status_suffix = status.empty? ? "" : " · #{status}"
      fixed_width = 3 + Tui::Unicode.display_width(empty_label) + Tui::Unicode.display_width(status_suffix)
      name_budget = width - lead_width - fixed_width
      if name_budget <= 0
        return truncate("#{lead}#{empty_label}#{status_suffix}", width)
      end
      type_suffix = optional_type_suffix(raw_type, name_budget - 1)
      name_budget -= Tui::Unicode.display_width(type_suffix)
      return truncate("#{lead}#{empty_label}#{status_suffix}", width) if name_budget <= 0
      "#{lead}#{truncate(name, name_budget)} · #{empty_label}#{type_suffix}#{status_suffix}"
    end

    private def self.optional_type_suffix(raw_type : String?, available_cells : Int32) : String
      return "" unless raw_type && !raw_type.not_nil!.empty?
      budget = {available_cells, 15}.min
      return "" if budget < 5
      text_budget = budget - 3
      " (#{truncate(raw_type.not_nil!, text_budget)})"
    end

    private def self.compact_status(status : String, max_cells : Int32) : String
      return "" if max_cells <= 0
      return status if Tui::Unicode.display_width(status) <= max_cells
      compact = if status.starts_with?("Partial")
                  "Partial · m: more"
                elsif status.starts_with?("Enter:")
                  "load"
                elsif status.starts_with?("m:")
                  "m: more"
                elsif status.starts_with?("Empty")
                  "empty"
                elsif status.starts_with?("Loading")
                  "Loading…"
                else
                  "unavailable"
                end
      truncate(compact, max_cells)
    end

    private def self.visible_controls(value : String) : String
      return "[invalid text]" unless value.valid_encoding?
      String.build do |builder|
        value.each_grapheme do |raw|
          grapheme = raw.to_s
          if grapheme == "\n"
            builder << "\\n"
          elsif grapheme == "\r"
            builder << "\\r"
          elsif grapheme == "\t"
            builder << "\\t"
          else
            grapheme.each_char do |char|
              codepoint = char.ord
              if codepoint < 0x20 || codepoint.in?(0x7f..0x9f) ||
                 codepoint.in?(0x202a..0x202e) || codepoint.in?(0x2066..0x2069) ||
                 codepoint == 0x061c || codepoint == 0x200b ||
                 codepoint.in?(0x200e..0x200f) || codepoint == 0xfeff
                builder << "\\u#{codepoint.to_s(16).rjust(4, '0')}"
              else
                builder << char
              end
            end
          end
        end
      end
    end
  end
end
