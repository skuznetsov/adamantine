require "set"
require "./template_catalog"
require "./template_config"
require "./template_session"
require "./template_selection_adapter"

module Adamantine
  # Template insertion remains an editor-local operation. In particular, the
  # LSP completion capability and response grammar are deliberately unchanged.
  module TemplateController
    private struct TemplateTarget
      getter buffer : OpenBuffer
      getter editor : EditingTextEditor
      getter root : Path
      getter version : Int32
      getter line : Int32
      getter col : Int32
      getter language : String

      def initialize(@buffer : OpenBuffer, @editor : EditingTextEditor, @root : Path)
        @version = @buffer.version
        @line = @editor.cursor_line
        @col = @editor.cursor_col
        @language = @buffer.language_id || ""
      end
    end

    private def reload_template_config : Nil
      @template_config = TemplateConfig.load(
        TemplateConfig.user_path,
        TemplateConfig.project_path(@project_root.to_s),
      )
      @template_config.diagnostics.each do |diagnostic|
        @status_log.warning("Template #{diagnostic.source}: #{diagnostic.message} (#{diagnostic.path})")
      end
    end

    private def available_templates(language : String) : Array(TemplateCatalog::Template)
      templates = @template_config.for_language(language).map do |entry|
        TemplateCatalog::Template.new(
          entry.trigger, entry.body, entry.parsed,
          entry.label, entry.description, entry.languages,
        )
      end
      seen = Set(String).new
      templates.each { |template| seen.add(template.trigger) }
      TemplateCatalog.for_language(language).each do |builtin|
        templates << builtin if seen.add?(builtin.trigger)
      end
      templates
    end

    private def open_template_picker(argument : String = "") : Nil
      buffer = current_buffer
      editor = current_editor.try(&.as?(EditingTextEditor))
      unless buffer && editor
        @status_log.warning("Open a file before inserting a template")
        return
      end
      if editor.selection_present?
        @status_log.warning("Clear the selection before inserting a template")
        return
      end

      reload_template_config
      target = TemplateTarget.new(buffer, editor, @project_root)
      templates = available_templates(target.language)
      if templates.empty?
        @status_log.warning("No templates for #{target.language}; add .adamantine/templates.json")
        return
      end

      trigger = argument.strip
      unless trigger.empty?
        if template = templates.find { |item| item.trigger == trigger }
          insert_template(template, target)
        else
          @status_log.warning("Unknown template '#{trigger}' for #{target.language}")
        end
        return
      end

      actions = templates.map do |template|
        LspContextAction.new(
          "#{template.trigger} — #{template.label}",
          "",
          -> { insert_template(template, target) },
        )
      end
      open_context_menu("Templates", actions)
    end

    private def insert_template(template : TemplateCatalog::Template, target : TemplateTarget) : Nil
      buffer = current_buffer
      editor = current_editor
      unless buffer && buffer.same?(target.buffer) && editor && editor.same?(target.editor) &&
             target.buffer.editor.same?(target.editor) && @project_root == target.root &&
             target.buffer.version == target.version && target.editor.cursor_line == target.line &&
             target.editor.cursor_col == target.col && !target.editor.selection_present? &&
             (target.buffer.language_id || "") == target.language
        @status_log.warning("Template not inserted: the target editor changed")
        return
      end

      indentation = target.editor.template_leading_indentation
      unless indentation
        @status_log.warning("Template not inserted: line indentation is too wide")
        return
      end
      parsed = indented_template(template.parsed, indentation)
      unless parsed
        @status_log.warning("Template not inserted: expanded text exceeds the safe limit")
        return
      end

      start_col = if target.editor.template_trigger_before_cursor?(template.trigger)
                    target.col - template.trigger.size
                  else
                    target.col
                  end
      @template_session.try(&.cancel)
      @template_session = nil
      target.editor.apply_completion_edit(
        target.line, start_col, target.line, target.col,
        target.line, target.col, parsed.text,
      )
      focus_active_editor
      session = TemplateSession.new(target.editor, target.line, start_col, parsed)
      session.select_first
      @template_session = session if session.active?
      @status_log.info("Inserted template: #{template.label}")
      mark_dirty!
    end

    # Offset remapping is on Unicode codepoints, like TextEditor positions.
    # A parser body containing CR is rejected by the config loader because the
    # editor normalizes CRLF during insertion, which would invalidate offsets.
    private def indented_template(parsed : Snippet::ParseResult, indent : String) : Snippet::ParseResult?
      return nil if parsed.text.includes?('\r')
      return parsed if indent.empty?

      offsets = [0] of Int32
      output = String::Builder.new
      codepoints = 0
      bytes = 0
      parsed.text.each_char do |char|
        output << char
        codepoints += 1
        bytes += char.bytesize
        if char == '\n'
          output << indent
          codepoints += indent.size
          bytes += indent.bytesize
        end
        return nil if bytes > Snippet::Parser::MAX_EXPANDED_TEXT_BYTES
        offsets << codepoints
      end

      stops = parsed.tabstops.map do |stop|
        Snippet::Tabstop.new(
          stop.index,
          offsets[stop.start_offset],
          offsets[stop.end_offset],
        )
      end
      Snippet::ParseResult.new(output.to_s, stops, parsed.explicit_final_stop?)
    end

    private def template_buffer_changed(buffer : OpenBuffer, change : Tui::TextEditor::TextChange) : Nil
      if session = @template_session
        if session.editor.same?(buffer.editor)
          @template_session = nil unless session.apply_change(change)
        end
      end
    end

    private def template_fields_active? : Bool
      session = @template_session
      return false unless session && session.active?
      return false unless current_editor.same?(session.editor)
      return false unless current_key_context == InputRouter::KeyContext::Editor
      unless session.contains_cursor?
        session.cancel
        @template_session = nil
        return false
      end
      true
    end

    private def handle_template_field_input(event : Tui::KeyEvent) : Bool
      session = @template_session
      return false unless session
      case
      when event.matches?("tab")
        @template_session = nil unless session.next
      when event.matches?("shift+tab")
        @template_session = nil unless session.previous
      when event.matches?("escape") || event.matches?("esc")
        session.cancel
        @template_session = nil
      else
        return false
      end
      mark_dirty!
      true
    end
  end
end
