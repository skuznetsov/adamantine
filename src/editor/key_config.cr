require "json"

module CrystalEditor
  module KeyConfig
    alias Action = String
    alias KeyBinding = String
    alias ActionMap = Hash(Action, Array(KeyBinding))

    DEFAULT_KEY_MAP = {
      "app.open_file_tree"       => ["ctrl+o"],
      "app.next_tab"             => ["ctrl+tab"],
      "app.previous_tab"         => ["ctrl+shift+tab"],
      "app.goto_tab_1"           => ["alt+1"],
      "app.goto_tab_2"           => ["alt+2"],
      "app.goto_tab_3"           => ["alt+3"],
      "app.goto_tab_4"           => ["alt+4"],
      "app.goto_tab_5"           => ["alt+5"],
      "app.goto_tab_6"           => ["alt+6"],
      "app.goto_tab_7"           => ["alt+7"],
      "app.goto_tab_8"           => ["alt+8"],
      "app.goto_tab_9"           => ["alt+9"],
      "app.quick_actions"        => ["shift+enter", "shift+return"],
      "lsp.goto_definition"      => ["f12"],
      "lsp.hover"                => ["f6"],
      "lsp.references"           => ["f7"],
      "lsp.signature"            => ["f8"],
      "lsp.context_menu"         => ["f9"],
      "app.save"                 => ["ctrl+s"],
      "app.close_tab"            => ["ctrl+w"],
      "lsp.status"               => ["ctrl+l"],
      "app.focus_tree"           => ["f2"],
      "app.focus_editor"         => ["f3"],
      "app.refresh_tree"         => ["f4"],
      "app.help"                 => ["f5"],
      "app.command_palette"      => ["ctrl+shift+p"],
      "app.quit"                 => ["ctrl+q"],
      "app.settings"             => ["f10"],
      "app.reload_theme"         => ["f11"],
      "app.jump_back"            => ["ctrl+["],
      "app.jump_forward"         => ["ctrl+]"],
      "app.menu_up"              => ["up", "k"],
      "app.menu_down"            => ["down", "j"],
      "app.menu_select"          => ["enter", "return"],
      "app.menu_close"           => ["escape"],
      "app.menu_first"           => ["home"],
      "app.menu_last"            => ["end"],
      "lsp.popup_close"          => ["escape", "enter", "return"],
      "lsp.menu_definition"      => ["f12"],
      "lsp.menu_declaration"     => ["d"],
      "lsp.menu_type_definition" => ["t"],
      "lsp.menu_implementation"  => ["i"],
      "lsp.menu_hover"           => ["h"],
      "lsp.menu_references"      => ["r"],
      "lsp.menu_signature"       => ["s"],
      "lsp.menu_completion"      => ["c"],
      "lsp.menu_diagnostics"     => ["x"],
      "lsp.menu_code_actions"    => ["a"],
    }

    def self.defaults : ActionMap
      ActionMap.new.tap do |map|
        DEFAULT_KEY_MAP.each do |action, bindings|
          map[action] = bindings.dup
        end
      end
    end

    def self.load(path : String?) : ActionMap
      return defaults if path.nil? || path.empty?
      key_file = Path.new(path)
      return defaults unless File.file?(key_file.to_s)
      load_from_file(key_file)
    rescue
      defaults
    end

    def self.resolve_default_path : String?
      if env_path = ENV["CRYSTAL_EDITOR_CONFIG"]?
        return env_path unless env_path.empty?
      end

      home = ENV["HOME"]?
      return nil unless home

      candidates = [
        Path.new(home, ".config", "crystal_editor", "config.json"),
        Path.new(home, ".crystal_editor", "config.json"),
        Path.new(home, ".config", "editor", "config.json"),
      ]

      candidates.each do |candidate|
        return candidate.to_s if File.file?(candidate.to_s)
      end

      nil
    end

    def self.default_save_path : String?
      if env_path = ENV["CRYSTAL_EDITOR_CONFIG"]?
        return env_path unless env_path.empty?
      end

      home = ENV["HOME"]?
      return nil unless home
      Path.new(home, ".config", "crystal_editor", "config.json").to_s
    end

    def self.normalize_binding(raw : String) : String
      parts = raw
        .downcase
        .split("+")
        .map(&.strip)
        .reject(&.empty?)

      return "" if parts.empty?

      key_part = String.new
      modifiers = [] of String
      parts.each do |part|
        case part
        when "ctrl", "alt", "shift", "meta"
          modifiers << part
        else
          key_part = part
        end
      end

      return "" if key_part.empty?
      ordered = [] of String
      %w[ctrl alt shift meta].each do |modifier|
        ordered << modifier if modifiers.includes?(modifier)
      end
      ordered << key_part
      ordered.join("+")
    end

    def self.normalize_bindings(bindings : Array(KeyBinding)) : Array(KeyBinding)
      normalized = bindings.map { |binding| normalize_binding(binding) }.reject(&.empty?)
      normalized.uniq.compact_map { |binding| binding if !binding.empty? }
    end

    def self.find_action_for_binding(bindings : ActionMap, binding : String) : Action?
      wanted = normalize_binding(binding)
      return nil if wanted.empty?
      bindings.each do |action, keys|
        keys.each do |candidate|
          return action if normalize_binding(candidate) == wanted
        end
      end
      nil
    end

    def self.serializable_payload(bindings : ActionMap) : String
      payload = ActionMap.new
      bindings.keys.sort.each do |action|
        payload[action] = normalize_bindings(bindings[action]? || [] of KeyBinding)
      end

      JSON.build do |json|
        json.object do
          json.field "keymap" do
            json.object do
              payload.each do |action, keys|
                json.field action do
                  json.array do
                    keys.each do |binding|
                      json.string binding
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def self.save(path : String, bindings : ActionMap) : Nil
      key_file = Path.new(path)
      parent = key_file.parent.to_s
      Dir.mkdir_p(parent) unless parent.empty? || parent == "."
      File.write(key_file.to_s, serializable_payload(bindings))
    end

    private def self.load_from_file(path : Path) : ActionMap
      raw = JSON.parse(File.read(path))
      map = defaults
      keymap = raw["keymap"]?
      parsed = parse_keymap(keymap)
      return map unless parsed
      parsed.each do |action, keys|
        next if keys.empty?
        map[action] = keys
      end
      map
    end

    private def self.parse_keymap(raw_keymap : JSON::Any?) : ActionMap?
      return nil unless raw_keymap
      return nil unless raw_hash = raw_keymap.as_h?

      result = ActionMap.new
      raw_hash.each do |action, value|
        bindings = parse_binding_value(value)
        result[action] = bindings if !bindings.empty?
      end
      result
    end

    private def self.parse_binding_value(value : JSON::Any) : Array(KeyBinding)
      single = parse_key_list(value)
      normalize_bindings(single)
    end

    private def self.parse_key_list(value : JSON::Any) : Array(KeyBinding)
      case
      when (single = value.as_s?)
        parse_binding_text(single)
      when array = value.as_a?
        array.compact_map do |entry|
          entry.as_s?.try { |entry_str| parse_binding_text(entry_str) }
        end.flatten
      else
        [] of KeyBinding
      end
    end

    private def self.parse_binding_text(value : String) : Array(KeyBinding)
      value
        .split(/[;,]/)
        .map(&.strip)
        .reject(&.empty?)
    end
  end
end
