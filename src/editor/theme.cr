# VS Code-inspired theme configuration with runtime loading.
require "json"

module CrystalEditor
  module Theme
    class Palette
      # Editor (TextEditor)
      property editor_text_fg : Tui::Color
      property editor_text_bg : Tui::Color
      property editor_cursor_fg : Tui::Color
      property editor_cursor_bg : Tui::Color
      property editor_selection_fg : Tui::Color
      property editor_selection_bg : Tui::Color
      property editor_line_number_fg : Tui::Color
      property editor_line_number_bg : Tui::Color
      property editor_current_line_bg : Tui::Color

      # Diagnostics
      property lsp_error_fg : Tui::Color
      property lsp_error_bg : Tui::Color
      property lsp_warning_fg : Tui::Color
      property lsp_warning_bg : Tui::Color
      property lsp_info_fg : Tui::Color
      property lsp_info_bg : Tui::Color
      property lsp_hint_fg : Tui::Color
      property lsp_hint_bg : Tui::Color
      property lsp_use_underline : Bool

      # Tree / file panel
      property file_panel_border_color : Tui::Color
      property file_panel_active_border_color : Tui::Color
      property file_panel_title_color : Tui::Color
      property file_panel_bg_color : Tui::Color
      property file_panel_dir_color : Tui::Color
      property file_panel_file_color : Tui::Color
      property file_panel_cursor_color : Tui::Color
      property file_panel_cursor_bg : Tui::Color
      property file_panel_selected_color : Tui::Color
      property file_panel_filter_color : Tui::Color
      property file_panel_filter_bg : Tui::Color

      # Header / footer / split container
      property header_bg : Tui::Color
      property header_title : Tui::Color
      property header_subtitle : Tui::Color
      property header_clock : Tui::Color

      property footer_key_fg : Tui::Color
      property footer_key_bg : Tui::Color
      property footer_label_fg : Tui::Color
      property footer_label_bg : Tui::Color

      property split_border : Tui::Color
      property split_splitter : Tui::Color
      property split_splitter_drag : Tui::Color
      property split_focus_border : Tui::Color
      property split_focus_title : Tui::Color
      property split_title : Tui::Color
      property split_title_bg : Tui::Color

      # Log
      property status_bg : Tui::Color
      property status_debug : Tui::Color
      property status_info : Tui::Color
      property status_warning : Tui::Color
      property status_error : Tui::Color
      property status_success : Tui::Color
      property status_timestamp : Tui::Color
      property status_source : Tui::Color

      # Popups / menus / dialogs
      property popup_border : Tui::Color
      property popup_title : Tui::Color
      property popup_text : Tui::Color
      property popup_active_fg : Tui::Color
      property popup_active_bg : Tui::Color

      def initialize(
        @editor_text_fg : Tui::Color,
        @editor_text_bg : Tui::Color,
        @editor_cursor_fg : Tui::Color,
        @editor_cursor_bg : Tui::Color,
        @editor_selection_fg : Tui::Color,
        @editor_selection_bg : Tui::Color,
        @editor_line_number_fg : Tui::Color,
        @editor_line_number_bg : Tui::Color,
        @editor_current_line_bg : Tui::Color,
        @lsp_error_fg : Tui::Color,
        @lsp_error_bg : Tui::Color,
        @lsp_warning_fg : Tui::Color,
        @lsp_warning_bg : Tui::Color,
        @lsp_info_fg : Tui::Color,
        @lsp_info_bg : Tui::Color,
        @lsp_hint_fg : Tui::Color,
        @lsp_hint_bg : Tui::Color,
        @lsp_use_underline : Bool,
        @file_panel_border_color : Tui::Color,
        @file_panel_active_border_color : Tui::Color,
        @file_panel_title_color : Tui::Color,
        @file_panel_bg_color : Tui::Color,
        @file_panel_dir_color : Tui::Color,
        @file_panel_file_color : Tui::Color,
        @file_panel_cursor_color : Tui::Color,
        @file_panel_cursor_bg : Tui::Color,
        @file_panel_selected_color : Tui::Color,
        @file_panel_filter_color : Tui::Color,
        @file_panel_filter_bg : Tui::Color,
        @header_bg : Tui::Color,
        @header_title : Tui::Color,
        @header_subtitle : Tui::Color,
        @header_clock : Tui::Color,
        @footer_key_fg : Tui::Color,
        @footer_key_bg : Tui::Color,
        @footer_label_fg : Tui::Color,
        @footer_label_bg : Tui::Color,
        @split_border : Tui::Color,
        @split_splitter : Tui::Color,
        @split_splitter_drag : Tui::Color,
        @split_focus_border : Tui::Color,
        @split_focus_title : Tui::Color,
        @split_title : Tui::Color,
        @split_title_bg : Tui::Color,
        @status_bg : Tui::Color,
        @status_debug : Tui::Color,
        @status_info : Tui::Color,
        @status_warning : Tui::Color,
        @status_error : Tui::Color,
        @status_success : Tui::Color,
        @status_timestamp : Tui::Color,
        @status_source : Tui::Color,
        @popup_border : Tui::Color,
        @popup_title : Tui::Color,
        @popup_text : Tui::Color,
        @popup_active_fg : Tui::Color,
        @popup_active_bg : Tui::Color,
      )
      end

      def self.vscode_dark : Palette
        Palette.new(
          editor_text_fg: Tui::Color.rgb(212, 212, 212),
          editor_text_bg: Tui::Color.rgb(30, 30, 30),
          editor_cursor_fg: Tui::Color.black,
          editor_cursor_bg: Tui::Color.rgb(220, 220, 220),
          editor_selection_fg: Tui::Color.black,
          editor_selection_bg: Tui::Color.rgb(51, 99, 120),
          editor_line_number_fg: Tui::Color.rgb(113, 113, 113),
          editor_line_number_bg: Tui::Color.rgb(30, 30, 30),
          editor_current_line_bg: Tui::Color.rgb(37, 37, 38),
          lsp_error_fg: Tui::Color.rgb(248, 113, 113),
          lsp_error_bg: Tui::Color.rgb(82, 26, 26),
          lsp_warning_fg: Tui::Color.rgb(247, 210, 120),
          lsp_warning_bg: Tui::Color.rgb(90, 68, 0),
          lsp_info_fg: Tui::Color.rgb(122, 202, 255),
          lsp_info_bg: Tui::Color.rgb(10, 45, 85),
          lsp_hint_fg: Tui::Color.rgb(200, 200, 200),
          lsp_hint_bg: Tui::Color.rgb(45, 45, 48),
          lsp_use_underline: true,
          file_panel_border_color: Tui::Color.rgb(0, 122, 204),
          file_panel_active_border_color: Tui::Color.rgb(0, 122, 204),
          file_panel_title_color: Tui::Color.rgb(0, 122, 204),
          file_panel_bg_color: Tui::Color.rgb(30, 30, 30),
          file_panel_dir_color: Tui::Color.rgb(150, 150, 170),
          file_panel_file_color: Tui::Color.rgb(200, 200, 220),
          file_panel_cursor_color: Tui::Color.black,
          file_panel_cursor_bg: Tui::Color.rgb(51, 99, 120),
          file_panel_selected_color: Tui::Color.rgb(253, 190, 66),
          file_panel_filter_color: Tui::Color.black,
          file_panel_filter_bg: Tui::Color.rgb(120, 120, 130),
          header_bg: Tui::Color.rgb(45, 45, 48),
          header_title: Tui::Color.rgb(204, 204, 204),
          header_subtitle: Tui::Color.rgb(189, 189, 189),
          header_clock: Tui::Color.rgb(255, 206, 84),
          footer_key_fg: Tui::Color.rgb(255, 255, 255),
          footer_key_bg: Tui::Color.rgb(0, 122, 204),
          footer_label_fg: Tui::Color.rgb(255, 255, 255),
          footer_label_bg: Tui::Color.rgb(37, 37, 38),
          split_border: Tui::Color.rgb(120, 120, 120),
          split_splitter: Tui::Color.rgb(120, 120, 120),
          split_splitter_drag: Tui::Color.rgb(255, 215, 0),
          split_focus_border: Tui::Color.rgb(0, 122, 204),
          split_focus_title: Tui::Color.rgb(0, 122, 204),
          split_title: Tui::Color.rgb(120, 120, 120),
          split_title_bg: Tui::Color.rgb(37, 37, 38),
          status_bg: Tui::Color.rgb(10, 10, 10),
          status_debug: Tui::Color.rgb(161, 161, 170),
          status_info: Tui::Color.rgb(212, 212, 212),
          status_warning: Tui::Color.rgb(240, 220, 130),
          status_error: Tui::Color.rgb(255, 128, 128),
          status_success: Tui::Color.rgb(132, 255, 144),
          status_timestamp: Tui::Color.rgb(120, 120, 120),
          status_source: Tui::Color.rgb(120, 220, 255),
          popup_border: Tui::Color.rgb(120, 120, 120),
          popup_title: Tui::Color.rgb(78, 201, 249),
          popup_text: Tui::Color.rgb(220, 220, 220),
          popup_active_fg: Tui::Color.black,
          popup_active_bg: Tui::Color.rgb(0, 122, 204)
        )
      end

      def self.vscode_light : Palette
        Palette.new(
          editor_text_fg: Tui::Color.rgb(30, 30, 30),
          editor_text_bg: Tui::Color.white,
          editor_cursor_fg: Tui::Color.white,
          editor_cursor_bg: Tui::Color.rgb(0, 120, 215),
          editor_selection_fg: Tui::Color.white,
          editor_selection_bg: Tui::Color.rgb(173, 214, 255),
          editor_line_number_fg: Tui::Color.rgb(102, 102, 102),
          editor_line_number_bg: Tui::Color.white,
          editor_current_line_bg: Tui::Color.rgb(238, 238, 238),
          lsp_error_fg: Tui::Color.rgb(193, 0, 0),
          lsp_error_bg: Tui::Color.rgb(255, 237, 237),
          lsp_warning_fg: Tui::Color.rgb(168, 114, 0),
          lsp_warning_bg: Tui::Color.rgb(255, 250, 230),
          lsp_info_fg: Tui::Color.rgb(0, 91, 170),
          lsp_info_bg: Tui::Color.rgb(230, 244, 255),
          lsp_hint_fg: Tui::Color.rgb(80, 80, 80),
          lsp_hint_bg: Tui::Color.rgb(236, 236, 236),
          lsp_use_underline: true,
          file_panel_border_color: Tui::Color.rgb(0, 120, 215),
          file_panel_active_border_color: Tui::Color.rgb(0, 120, 215),
          file_panel_title_color: Tui::Color.rgb(0, 120, 215),
          file_panel_bg_color: Tui::Color.white,
          file_panel_dir_color: Tui::Color.rgb(0, 100, 0),
          file_panel_file_color: Tui::Color.rgb(40, 40, 40),
          file_panel_cursor_color: Tui::Color.white,
          file_panel_cursor_bg: Tui::Color.rgb(0, 120, 215),
          file_panel_selected_color: Tui::Color.rgb(196, 113, 0),
          file_panel_filter_color: Tui::Color.rgb(255, 255, 255),
          file_panel_filter_bg: Tui::Color.rgb(51, 102, 204),
          header_bg: Tui::Color.rgb(0, 120, 215),
          header_title: Tui::Color.white,
          header_subtitle: Tui::Color.rgb(220, 220, 220),
          header_clock: Tui::Color.rgb(255, 250, 200),
          footer_key_fg: Tui::Color.white,
          footer_key_bg: Tui::Color.rgb(0, 120, 215),
          footer_label_fg: Tui::Color.white,
          footer_label_bg: Tui::Color.rgb(240, 240, 240),
          split_border: Tui::Color.rgb(160, 160, 160),
          split_splitter: Tui::Color.rgb(160, 160, 160),
          split_splitter_drag: Tui::Color.rgb(255, 153, 0),
          split_focus_border: Tui::Color.rgb(0, 120, 215),
          split_focus_title: Tui::Color.rgb(0, 120, 215),
          split_title: Tui::Color.rgb(160, 160, 160),
          split_title_bg: Tui::Color.rgb(238, 238, 238),
          status_bg: Tui::Color.rgb(240, 240, 240),
          status_debug: Tui::Color.rgb(96, 96, 96),
          status_info: Tui::Color.rgb(40, 40, 40),
          status_warning: Tui::Color.rgb(181, 137, 0),
          status_error: Tui::Color.rgb(196, 49, 0),
          status_success: Tui::Color.rgb(0, 123, 61),
          status_timestamp: Tui::Color.rgb(110, 110, 110),
          status_source: Tui::Color.rgb(0, 120, 215),
          popup_border: Tui::Color.rgb(160, 160, 160),
          popup_title: Tui::Color.rgb(0, 120, 215),
          popup_text: Tui::Color.rgb(30, 30, 30),
          popup_active_fg: Tui::Color.white,
          popup_active_bg: Tui::Color.rgb(0, 120, 215)
        )
      end

      def self.vscode_high_contrast : Palette
        Palette.new(
          editor_text_fg: Tui::Color.rgb(240, 240, 240),
          editor_text_bg: Tui::Color.black,
          editor_cursor_fg: Tui::Color.black,
          editor_cursor_bg: Tui::Color.rgb(255, 255, 0),
          editor_selection_fg: Tui::Color.black,
          editor_selection_bg: Tui::Color.rgb(0, 120, 215),
          editor_line_number_fg: Tui::Color.rgb(181, 181, 181),
          editor_line_number_bg: Tui::Color.black,
          editor_current_line_bg: Tui::Color.rgb(24, 24, 24),
          lsp_error_fg: Tui::Color.rgb(255, 102, 102),
          lsp_error_bg: Tui::Color.rgb(82, 0, 0),
          lsp_warning_fg: Tui::Color.rgb(255, 214, 102),
          lsp_warning_bg: Tui::Color.rgb(83, 58, 0),
          lsp_info_fg: Tui::Color.rgb(80, 158, 248),
          lsp_info_bg: Tui::Color.rgb(0, 24, 78),
          lsp_hint_fg: Tui::Color.rgb(230, 230, 230),
          lsp_hint_bg: Tui::Color.rgb(20, 20, 20),
          lsp_use_underline: true,
          file_panel_border_color: Tui::Color.rgb(0, 120, 215),
          file_panel_active_border_color: Tui::Color.rgb(0, 120, 215),
          file_panel_title_color: Tui::Color.rgb(0, 120, 215),
          file_panel_bg_color: Tui::Color.black,
          file_panel_dir_color: Tui::Color.rgb(173, 214, 255),
          file_panel_file_color: Tui::Color.rgb(220, 220, 220),
          file_panel_cursor_color: Tui::Color.black,
          file_panel_cursor_bg: Tui::Color.rgb(0, 120, 215),
          file_panel_selected_color: Tui::Color.rgb(255, 255, 0),
          file_panel_filter_color: Tui::Color.black,
          file_panel_filter_bg: Tui::Color.rgb(0, 120, 215),
          header_bg: Tui::Color.rgb(30, 30, 30),
          header_title: Tui::Color.rgb(248, 248, 248),
          header_subtitle: Tui::Color.rgb(181, 181, 181),
          header_clock: Tui::Color.rgb(255, 255, 0),
          footer_key_fg: Tui::Color.black,
          footer_key_bg: Tui::Color.rgb(0, 120, 215),
          footer_label_fg: Tui::Color.black,
          footer_label_bg: Tui::Color.rgb(240, 240, 240),
          split_border: Tui::Color.rgb(120, 120, 120),
          split_splitter: Tui::Color.rgb(120, 120, 120),
          split_splitter_drag: Tui::Color.rgb(255, 255, 0),
          split_focus_border: Tui::Color.rgb(0, 120, 215),
          split_focus_title: Tui::Color.rgb(0, 120, 215),
          split_title: Tui::Color.rgb(120, 120, 120),
          split_title_bg: Tui::Color.rgb(30, 30, 30),
          status_bg: Tui::Color.black,
          status_debug: Tui::Color.rgb(186, 186, 186),
          status_info: Tui::Color.rgb(240, 240, 240),
          status_warning: Tui::Color.rgb(255, 204, 102),
          status_error: Tui::Color.rgb(255, 128, 128),
          status_success: Tui::Color.rgb(153, 255, 153),
          status_timestamp: Tui::Color.rgb(140, 140, 140),
          status_source: Tui::Color.rgb(120, 220, 255),
          popup_border: Tui::Color.rgb(120, 120, 120),
          popup_title: Tui::Color.rgb(78, 201, 249),
          popup_text: Tui::Color.rgb(220, 220, 220),
          popup_active_fg: Tui::Color.black,
          popup_active_bg: Tui::Color.rgb(0, 120, 215)
        )
      end
    end

    PRESETS = {
      "vscode"               => Palette.vscode_dark,
      "vscode-dark"          => Palette.vscode_dark,
      "vscode-high-contrast" => Palette.vscode_high_contrast,
      "vs-dark"              => Palette.vscode_dark,
      "vs-light"             => Palette.vscode_light,
      "default"              => Palette.vscode_dark,
      "vscode_light"         => Palette.vscode_light,
      "vscode-light"         => Palette.vscode_light,
    }

    @@palette : Palette = Palette.vscode_dark
    @@name : String = "vscode-dark"

    def self.name : String
      @@name
    end

    def self.preset_names : Array(String)
      PRESETS.keys
        .map(&.gsub("_", "-"))
        .uniq
        .sort
    end

    private def self.resolve_named_preset(raw : String?) : {Palette, String}?
      return nil unless raw
      normalized = raw.strip.downcase
      return nil if normalized.empty?
      return nil if normalized.includes?('/') || normalized.includes?('\\') || normalized.includes?('.')

      normalized = normalized.gsub('_', '-')
      normalized = case normalized
                   when "default"                             then "default"
                   when "vs", "dark+"                         then "vscode"
                   when "dark"                                then "vscode-dark"
                   when "light"                               then "vscode-light"
                   when "hc", "high-contrast", "highcontrast" then "vscode-high-contrast"
                   else                                            normalized
                   end

      palette = PRESETS[normalized]?
      return nil unless palette
      {palette, normalized}
    end

    module Editor
      def self.text_fg : Tui::Color
        Theme.color("editor.text_fg")
      end

      def self.text_bg : Tui::Color
        Theme.color("editor.text_bg")
      end

      def self.cursor_fg : Tui::Color
        Theme.color("editor.cursor_fg")
      end

      def self.cursor_bg : Tui::Color
        Theme.color("editor.cursor_bg")
      end

      def self.selection_fg : Tui::Color
        Theme.color("editor.selection_fg")
      end

      def self.selection_bg : Tui::Color
        Theme.color("editor.selection_bg")
      end

      def self.line_number_fg : Tui::Color
        Theme.color("editor.line_number_fg")
      end

      def self.line_number_bg : Tui::Color
        Theme.color("editor.line_number_bg")
      end

      def self.current_line_bg : Tui::Color
        Theme.color("editor.current_line_bg")
      end
    end

    module Lsp
      def self.diagnostic_style(base_style : Tui::Style, severity : Int32?) : Tui::Style
        Theme.editor_diagnostic_style(base_style, severity)
      end
    end

    module FilePanel
      def self.border_color : Tui::Color
        Theme.color("file_panel.border_color")
      end

      def self.active_border_color : Tui::Color
        Theme.color("file_panel.active_border_color")
      end

      def self.title_color : Tui::Color
        Theme.color("file_panel.title_color")
      end

      def self.bg_color : Tui::Color
        Theme.color("file_panel.bg_color")
      end

      def self.dir_color : Tui::Color
        Theme.color("file_panel.dir_color")
      end

      def self.file_color : Tui::Color
        Theme.color("file_panel.file_color")
      end

      def self.cursor_color : Tui::Color
        Theme.color("file_panel.cursor_color")
      end

      def self.cursor_bg : Tui::Color
        Theme.color("file_panel.cursor_bg")
      end

      def self.selected_color : Tui::Color
        Theme.color("file_panel.selected_color")
      end

      def self.filter_color : Tui::Color
        Theme.color("file_panel.filter_color")
      end

      def self.filter_bg : Tui::Color
        Theme.color("file_panel.filter_bg")
      end
    end

    module Header
      def self.bg : Tui::Color
        Theme.color("header.bg")
      end

      def self.title : Tui::Color
        Theme.color("header.title")
      end

      def self.subtitle : Tui::Color
        Theme.color("header.subtitle")
      end

      def self.clock : Tui::Color
        Theme.color("header.clock")
      end
    end

    module Footer
      def self.key_fg : Tui::Color
        Theme.color("footer.key_fg")
      end

      def self.key_bg : Tui::Color
        Theme.color("footer.key_bg")
      end

      def self.label_fg : Tui::Color
        Theme.color("footer.label_fg")
      end

      def self.label_bg : Tui::Color
        Theme.color("footer.label_bg")
      end
    end

    module Split
      def self.border : Tui::Color
        Theme.color("split.border")
      end

      def self.splitter : Tui::Color
        Theme.color("split.splitter")
      end

      def self.splitter_drag : Tui::Color
        Theme.color("split.splitter_drag")
      end

      def self.focus_border : Tui::Color
        Theme.color("split.focus_border")
      end

      def self.focus_title : Tui::Color
        Theme.color("split.focus_title")
      end

      def self.title : Tui::Color
        Theme.color("split.title")
      end
    end

    module Status
      def self.bg : Tui::Color
        Theme.color("status.bg")
      end

      def self.debug : Tui::Color
        Theme.color("status.debug")
      end

      def self.info : Tui::Color
        Theme.color("status.info")
      end

      def self.warning : Tui::Color
        Theme.color("status.warning")
      end

      def self.error : Tui::Color
        Theme.color("status.error")
      end

      def self.success : Tui::Color
        Theme.color("status.success")
      end

      def self.timestamp : Tui::Color
        Theme.color("status.timestamp")
      end

      def self.source : Tui::Color
        Theme.color("status.source")
      end
    end

    module Popup
      def self.border : Tui::Color
        Theme.color("popup.border")
      end

      def self.title : Tui::Color
        Theme.color("popup.title")
      end

      def self.text : Tui::Color
        Theme.color("popup.text")
      end

      def self.active_fg : Tui::Color
        Theme.color("popup.active_fg")
      end

      def self.active_bg : Tui::Color
        Theme.color("popup.active_bg")
      end
    end

    def self.load(path : String?) : Bool
      palette, loaded = load_palette(path)
      if loaded
        @@palette = palette
        true
      else
        @@palette = Palette.vscode_dark
        @@name = "vscode-dark"
        false
      end
    end

    def self.resolve_path(path : String?) : String?
      return path if path && !path.empty?
      return ENV["CRYSTAL_EDITOR_THEME"]? if ENV["CRYSTAL_EDITOR_THEME"]?.presence
      return ENV["EDITOR_THEME"]? if ENV["EDITOR_THEME"]?.presence
      default_path
    end

    def self.color(key : String) : Tui::Color
      case key
      when "editor.text_fg"
        @@palette.editor_text_fg
      when "editor.text_bg"
        @@palette.editor_text_bg
      when "editor.cursor_fg"
        @@palette.editor_cursor_fg
      when "editor.cursor_bg"
        @@palette.editor_cursor_bg
      when "editor.selection_fg"
        @@palette.editor_selection_fg
      when "editor.selection_bg"
        @@palette.editor_selection_bg
      when "editor.line_number_fg"
        @@palette.editor_line_number_fg
      when "editor.line_number_bg"
        @@palette.editor_line_number_bg
      when "editor.current_line_bg"
        @@palette.editor_current_line_bg
      when "lsp.error_fg"
        @@palette.lsp_error_fg
      when "lsp.error_bg"
        @@palette.lsp_error_bg
      when "lsp.warning_fg"
        @@palette.lsp_warning_fg
      when "lsp.warning_bg"
        @@palette.lsp_warning_bg
      when "lsp.info_fg"
        @@palette.lsp_info_fg
      when "lsp.info_bg"
        @@palette.lsp_info_bg
      when "lsp.hint_fg"
        @@palette.lsp_hint_fg
      when "lsp.hint_bg"
        @@palette.lsp_hint_bg
      when "file_panel.border_color"
        @@palette.file_panel_border_color
      when "file_panel.active_border_color"
        @@palette.file_panel_active_border_color
      when "file_panel.title_color"
        @@palette.file_panel_title_color
      when "file_panel.bg_color"
        @@palette.file_panel_bg_color
      when "file_panel.dir_color"
        @@palette.file_panel_dir_color
      when "file_panel.file_color"
        @@palette.file_panel_file_color
      when "file_panel.cursor_color"
        @@palette.file_panel_cursor_color
      when "file_panel.cursor_bg"
        @@palette.file_panel_cursor_bg
      when "file_panel.selected_color"
        @@palette.file_panel_selected_color
      when "file_panel.filter_color"
        @@palette.file_panel_filter_color
      when "file_panel.filter_bg"
        @@palette.file_panel_filter_bg
      when "header.bg"
        @@palette.header_bg
      when "header.title"
        @@palette.header_title
      when "header.subtitle"
        @@palette.header_subtitle
      when "header.clock"
        @@palette.header_clock
      when "footer.key_fg"
        @@palette.footer_key_fg
      when "footer.key_bg"
        @@palette.footer_key_bg
      when "footer.label_fg"
        @@palette.footer_label_fg
      when "footer.label_bg"
        @@palette.footer_label_bg
      when "split.border"
        @@palette.split_border
      when "split.splitter"
        @@palette.split_splitter
      when "split.splitter_drag"
        @@palette.split_splitter_drag
      when "split.focus_border"
        @@palette.split_focus_border
      when "split.focus_title"
        @@palette.split_focus_title
      when "split.title"
        @@palette.split_title
      when "split.title_bg"
        @@palette.split_title_bg
      when "status.bg"
        @@palette.status_bg
      when "status.debug"
        @@palette.status_debug
      when "status.info"
        @@palette.status_info
      when "status.warning"
        @@palette.status_warning
      when "status.error"
        @@palette.status_error
      when "status.success"
        @@palette.status_success
      when "status.timestamp"
        @@palette.status_timestamp
      when "status.source"
        @@palette.status_source
      when "popup.border"
        @@palette.popup_border
      when "popup.title"
        @@palette.popup_title
      when "popup.text"
        @@palette.popup_text
      when "popup.active_fg"
        @@palette.popup_active_fg
      when "popup.active_bg"
        @@palette.popup_active_bg
      else
        Tui::Color.default
      end
    end

    def self.editor_diagnostic_style(base_style : Tui::Style, severity : Int32?) : Tui::Style
      result = case severity
               when 1
                 Tui::Style.new(fg: color("lsp.error_fg"), bg: color("lsp.error_bg"), attrs: base_style.attrs)
               when 2
                 Tui::Style.new(fg: color("lsp.warning_fg"), bg: color("lsp.warning_bg"), attrs: base_style.attrs)
               when 3
                 Tui::Style.new(fg: color("lsp.info_fg"), bg: color("lsp.info_bg"), attrs: base_style.attrs)
               when 4
                 Tui::Style.new(fg: color("lsp.hint_fg"), bg: color("lsp.hint_bg"), attrs: base_style.attrs)
               else
                 Tui::Style.new(fg: color("lsp.hint_fg"), bg: color("lsp.hint_bg"), attrs: base_style.attrs)
               end

      if lsp_underline?
        Tui::Style.new(fg: result.fg, bg: result.bg, attrs: result.attrs | Tui::Attributes::Underline)
      else
        result
      end
    end

    def self.lsp_underline? : Bool
      @@palette.lsp_use_underline
    end

    def self.reset : Nil
      @@palette = Palette.vscode_dark
      @@name = "vscode-dark"
    end

    private def self.parse_color(value : JSON::Any) : Tui::Color?
      case value.raw
      when String
        parse_color_string(value.as_s)
      when Int32
        Tui::Color.palette(value.as_i)
      when Int64
        Tui::Color.palette(value.as_i.to_i32)
      when Float64
        idx = value.as_f.to_i
        idx < 0 ? nil : Tui::Color.palette(idx)
      when Array
        array = value.as_a
        return nil unless array.size >= 3

        r = array[0]?.try(&.as_i?)
        g = array[1]?.try(&.as_i?)
        b = array[2]?.try(&.as_i?)
        return nil unless r && g && b

        Tui::Color.rgb(r, g, b)
      when Hash
        obj = value.as_h
        r = obj["r"]?.try(&.as_i?) || obj["red"]?.try(&.as_i?)
        g = obj["g"]?.try(&.as_i?) || obj["green"]?.try(&.as_i?)
        b = obj["b"]?.try(&.as_i?) || obj["blue"]?.try(&.as_i?)
        return nil unless r && g && b

        Tui::Color.rgb(r, g, b)
      else
        nil
      end
    end

    private def self.parse_color_string(value : String) : Tui::Color?
      return nil if value.empty?
      return nil unless value.starts_with?("#")
      return nil unless value.size == 7

      r = value[1..2].to_i(base: 16)
      g = value[3..4].to_i(base: 16)
      b = value[5..6].to_i(base: 16)
      Tui::Color.rgb(r, g, b)
    rescue
      nil
    end

    private def self.load_palette(path : String?) : {Palette, Bool}
      palette = Palette.vscode_dark
      name = "vscode-dark"
      loaded = false

      if named_preset = resolve_named_preset(path)
        palette, name = named_preset
        @@name = name
        loaded = true
        return {palette, loaded}
      end

      theme_file = resolve_path(path)
      return {palette, false} unless theme_file
      return {palette, false} unless File.file?(theme_file)

      root = JSON.parse(File.read(theme_file))
      root_hash = root.as_h?
      return {palette, false} unless root_hash

      source = root["theme"]?.try(&.as_h?) || root_hash
      return {palette, false} unless source

      configured_name = source["name"]?.try(&.as_s)
      if configured_name && (candidate = PRESETS[configured_name]?)
        palette = candidate
        name = configured_name
      elsif configured_name
        name = configured_name
      end

      source.each do |group, value|
        value_hash = value.as_h?
        next unless value_hash

        case group
        when "editor"
          apply_editor_palette(palette, value_hash)
        when "lsp"
          apply_lsp_palette(palette, value_hash)
        when "file_panel"
          apply_file_panel_palette(palette, value_hash)
        when "header"
          apply_header_palette(palette, value_hash)
        when "footer"
          apply_footer_palette(palette, value_hash)
        when "split"
          apply_split_palette(palette, value_hash)
        when "status", "log", "terminal"
          apply_status_palette(palette, value_hash)
        when "popup", "overlay", "menu", "context_menu"
          apply_popup_palette(palette, value_hash)
        when "name"
          # handled above
        end
      end

      # support flat keys: lsp.error_fg, file_panel.bg_color, ...
      apply_plain_palette_values(palette, source)
      apply_diag_flags(palette, source)

      @@name = name
      loaded = true
      {palette, loaded}
    rescue
      {Palette.vscode_dark, false}
    end

    private def self.apply_plain_palette_values(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |k, v|
        next unless color = parse_color(v)
        case k
        when "name"
          next
        when "editor_text_fg"
          palette.editor_text_fg = color
        when "editor_text_bg"
          palette.editor_text_bg = color
        when "editor_cursor_fg"
          palette.editor_cursor_fg = color
        when "editor_cursor_bg"
          palette.editor_cursor_bg = color
        when "editor_selection_fg"
          palette.editor_selection_fg = color
        when "editor_selection_bg"
          palette.editor_selection_bg = color
        when "editor_line_number_fg"
          palette.editor_line_number_fg = color
        when "editor_line_number_bg"
          palette.editor_line_number_bg = color
        when "editor_current_line_bg"
          palette.editor_current_line_bg = color
        when "lsp_error_fg"
          palette.lsp_error_fg = color
        when "lsp_error_bg"
          palette.lsp_error_bg = color
        when "lsp_warning_fg"
          palette.lsp_warning_fg = color
        when "lsp_warning_bg"
          palette.lsp_warning_bg = color
        when "lsp_info_fg"
          palette.lsp_info_fg = color
        when "lsp_info_bg"
          palette.lsp_info_bg = color
        when "lsp_hint_fg"
          palette.lsp_hint_fg = color
        when "lsp_hint_bg"
          palette.lsp_hint_bg = color
        when "file_panel_border_color"
          palette.file_panel_border_color = color
        when "file_panel_active_border_color"
          palette.file_panel_active_border_color = color
        when "file_panel_title_color"
          palette.file_panel_title_color = color
        when "file_panel_bg_color"
          palette.file_panel_bg_color = color
        when "file_panel_dir_color"
          palette.file_panel_dir_color = color
        when "file_panel_file_color"
          palette.file_panel_file_color = color
        when "file_panel_cursor_color"
          palette.file_panel_cursor_color = color
        when "file_panel_cursor_bg"
          palette.file_panel_cursor_bg = color
        when "file_panel_selected_color"
          palette.file_panel_selected_color = color
        when "file_panel_filter_color"
          palette.file_panel_filter_color = color
        when "file_panel_filter_bg"
          palette.file_panel_filter_bg = color
        when "header_bg"
          palette.header_bg = color
        when "header_title"
          palette.header_title = color
        when "header_subtitle"
          palette.header_subtitle = color
        when "header_clock"
          palette.header_clock = color
        when "footer_key_fg"
          palette.footer_key_fg = color
        when "footer_key_bg"
          palette.footer_key_bg = color
        when "footer_label_fg"
          palette.footer_label_fg = color
        when "footer_label_bg"
          palette.footer_label_bg = color
        when "split_border"
          palette.split_border = color
        when "split_splitter"
          palette.split_splitter = color
        when "split_splitter_drag"
          palette.split_splitter_drag = color
        when "split_focus_border"
          palette.split_focus_border = color
        when "split_focus_title"
          palette.split_focus_title = color
        when "split_title"
          palette.split_title = color
        when "split_title_bg"
          palette.split_title_bg = color
        when "status_bg"
          palette.status_bg = color
        when "status_debug"
          palette.status_debug = color
        when "status_info"
          palette.status_info = color
        when "status_warning"
          palette.status_warning = color
        when "status_error"
          palette.status_error = color
        when "status_success"
          palette.status_success = color
        when "status_timestamp"
          palette.status_timestamp = color
        when "status_source"
          palette.status_source = color
        when "popup_border"
          palette.popup_border = color
        when "popup_title"
          palette.popup_title = color
        when "popup_text"
          palette.popup_text = color
        when "popup_active_fg"
          palette.popup_active_fg = color
        when "popup_active_bg"
          palette.popup_active_bg = color
        end
      end
    end

    private def self.apply_editor_palette(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |key, raw|
        color = parse_color(raw)
        next unless color
        case key
        when "text_fg"
          palette.editor_text_fg = color
        when "text_bg"
          palette.editor_text_bg = color
        when "cursor_fg"
          palette.editor_cursor_fg = color
        when "cursor_bg"
          palette.editor_cursor_bg = color
        when "selection_fg"
          palette.editor_selection_fg = color
        when "selection_bg"
          palette.editor_selection_bg = color
        when "line_number_fg"
          palette.editor_line_number_fg = color
        when "line_number_bg"
          palette.editor_line_number_bg = color
        when "current_line_bg"
          palette.editor_current_line_bg = color
        end
      end
    end

    private def self.apply_lsp_palette(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |key, raw|
        color = parse_color(raw)
        next unless color
        case key
        when "error_fg"
          palette.lsp_error_fg = color
        when "error_bg"
          palette.lsp_error_bg = color
        when "warning_fg"
          palette.lsp_warning_fg = color
        when "warning_bg"
          palette.lsp_warning_bg = color
        when "info_fg"
          palette.lsp_info_fg = color
        when "info_bg"
          palette.lsp_info_bg = color
        when "hint_fg"
          palette.lsp_hint_fg = color
        when "hint_bg"
          palette.lsp_hint_bg = color
        when "use_underline"
          palette.lsp_use_underline = raw.as_bool
        end
      end
    end

    private def self.apply_file_panel_palette(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |key, raw|
        color = parse_color(raw)
        next unless color

        case key
        when "border_color"
          palette.file_panel_border_color = color
        when "active_border_color"
          palette.file_panel_active_border_color = color
        when "title_color"
          palette.file_panel_title_color = color
        when "bg_color"
          palette.file_panel_bg_color = color
        when "dir_color"
          palette.file_panel_dir_color = color
        when "file_color"
          palette.file_panel_file_color = color
        when "cursor_color"
          palette.file_panel_cursor_color = color
        when "cursor_bg"
          palette.file_panel_cursor_bg = color
        when "selected_color"
          palette.file_panel_selected_color = color
        when "filter_color"
          palette.file_panel_filter_color = color
        when "filter_bg"
          palette.file_panel_filter_bg = color
        end
      end
    end

    private def self.apply_header_palette(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |key, raw|
        color = parse_color(raw)
        next unless color

        case key
        when "bg", "bg_color"
          palette.header_bg = color
        when "title", "title_color"
          palette.header_title = color
        when "subtitle", "subtitle_color"
          palette.header_subtitle = color
        when "clock", "clock_color"
          palette.header_clock = color
        end
      end
    end

    private def self.apply_footer_palette(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |key, raw|
        color = parse_color(raw)
        next unless color

        case key
        when "key_fg"
          palette.footer_key_fg = color
        when "key_bg"
          palette.footer_key_bg = color
        when "label_fg"
          palette.footer_label_fg = color
        when "label_bg"
          palette.footer_label_bg = color
        end
      end
    end

    private def self.apply_split_palette(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |key, raw|
        color = parse_color(raw)
        next unless color

        case key
        when "border"
          palette.split_border = color
        when "splitter"
          palette.split_splitter = color
        when "splitter_drag"
          palette.split_splitter_drag = color
        when "focus_border"
          palette.split_focus_border = color
        when "focus_title"
          palette.split_focus_title = color
        when "title"
          palette.split_title = color
        when "title_bg"
          palette.split_title_bg = color
        end
      end
    end

    private def self.apply_status_palette(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |key, raw|
        color = parse_color(raw)
        next unless color

        case key
        when "bg", "background"
          palette.status_bg = color
        when "debug"
          palette.status_debug = color
        when "info"
          palette.status_info = color
        when "warning"
          palette.status_warning = color
        when "error"
          palette.status_error = color
        when "success"
          palette.status_success = color
        when "timestamp"
          palette.status_timestamp = color
        when "source"
          palette.status_source = color
        end
      end
    end

    private def self.apply_popup_palette(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      source.each do |key, raw|
        color = parse_color(raw)
        next unless color

        case key
        when "border"
          palette.popup_border = color
        when "title"
          palette.popup_title = color
        when "text"
          palette.popup_text = color
        when "active_fg"
          palette.popup_active_fg = color
        when "active_bg"
          palette.popup_active_bg = color
        end
      end
    end

    private def self.apply_diag_flags(palette : Palette, source : Hash(String, JSON::Any)) : Nil
      if lsp = source["lsp"]?.try(&.as_h?)
        if value = lsp["use_underline"]?
          palette.lsp_use_underline = value.as_bool
        end
      end
    end

    private def self.default_path : String?
      home = ENV["HOME"]?
      return nil unless home

      candidates = [
        Path.new(home, ".config", "crystal_editor", "theme.json"),
        Path.new(home, ".config", "crystal_editor", "theme", "vscode.json"),
        Path.new(home, ".crystal_editor", "theme.json"),
      ]

      candidates.each do |candidate|
        return candidate.to_s if File.file?(candidate.to_s)
      end

      nil
    end
  end
end
