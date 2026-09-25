require "json"
require "./settings_config"

module Adamantine
  module KeyConfig
    alias Action = String
    alias KeyBinding = String
    alias ActionMap = Hash(Action, Array(KeyBinding))

    # A binding context is a routing scope, not a UI label. Global and
    # focused routes intentionally share one collision domain. An action can
    # belong to more than one modal context when the router reuses it there.
    enum BindingContext
      Global
      Menu
      QuickOpen
      Completion
      ProblemsModal
      LspMenu
      Popup
    end

    struct Layers
      getter effective : ActionMap
      getter overrides : ActionMap

      def initialize(effective : ActionMap, overrides : ActionMap)
        @effective = ActionMap.new
        effective.each do |action, bindings|
          @effective[action] = bindings.dup
        end

        @overrides = ActionMap.new
        overrides.each do |action, bindings|
          @overrides[action] = bindings.dup
        end
      end
    end

    MAX_KEYMAP_FILE_BYTES = 1_048_576

    DEFAULT_KEY_MAP = {
      "app.open_file_tree"    => ["ctrl+o"],
      "app.next_tab"          => ["ctrl+tab"],
      "app.previous_tab"      => ["ctrl+shift+tab"],
      "app.goto_tab_1"        => ["alt+1"],
      "app.goto_tab_2"        => ["alt+2"],
      "app.goto_tab_3"        => ["alt+3"],
      "app.goto_tab_4"        => ["alt+4"],
      "app.goto_tab_5"        => ["alt+5"],
      "app.goto_tab_6"        => ["alt+6"],
      "app.goto_tab_7"        => ["alt+7"],
      "app.goto_tab_8"        => ["alt+8"],
      "app.goto_tab_9"        => ["alt+9"],
      "app.quick_actions"     => ["shift+enter", "shift+return"],
      "app.indent"            => ["tab"],
      "app.dedent"            => ["shift+tab"],
      "lsp.goto_definition"   => ["f12"],
      "lsp.hover"             => ["f6"],
      "lsp.references"        => ["f7"],
      "lsp.signature"         => ["f8"],
      "lsp.context_menu"      => ["f9"],
      "app.save"              => ["ctrl+s"],
      "app.review_external"   => ["ctrl+shift+e"],
      "app.copy"              => ["ctrl+c"],
      "app.cut"               => ["ctrl+x"],
      "app.paste"             => ["ctrl+v"],
      "app.undo"              => ["ctrl+z"],
      "app.redo"              => ["ctrl+shift+z", "ctrl+y"],
      "app.find"              => ["ctrl+f"],
      "app.find_in_project"   => ["alt+f", "option+f", "ctrl+shift+f"],
      "app.close_tab"         => ["ctrl+w"],
      "app.split_right"       => ["ctrl+alt+r"],
      "app.focus_next_group"  => ["ctrl+alt+o"],
      "app.close_split"       => ["ctrl+alt+w"],
      "lsp.status"            => ["ctrl+l"],
      "lsp.toggle_fold"       => ["alt+/", "ctrl+shift+["],
      "app.focus_tree"        => ["f2"],
      "app.focus_editor"      => ["f3"],
      "app.refresh_tree"      => ["f4"],
      "app.help"              => ["f5"],
      "app.quick_open"        => ["ctrl+p"],
      "app.command_palette"   => ["f1", "ctrl+shift+p"],
      "lsp.problems"          => ["ctrl+shift+m"],
      "lsp.problems_next"     => ["alt+n"],
      "lsp.problems_previous" => ["alt+p"],
      "app.quit"              => ["ctrl+q"],
      "app.settings"          => ["f10"],
      "app.reload_theme"      => ["f11"],
      "app.jump_back"         => ["ctrl+[", "alt+["],
      "app.jump_forward"      => ["ctrl+]", "alt+]"],
      "app.menu_up"           => ["up", "k"],
      "app.menu_down"         => ["down", "j"],
      "app.quick_open_up"     => ["up"],
      "app.quick_open_down"   => ["down"],
      "app.menu_select"       => ["enter", "return"],
      "app.menu_close"        => ["escape"],
      "app.menu_first"        => ["home"],
      "app.menu_last"         => ["end"],
      # Completion handles Enter/Tab before generic popup routing, preserving
      # the legacy Enter/Return close keys for read-only LSP previews.
      "lsp.popup_close"          => ["escape", "enter", "return"],
      "lsp.completion_up"        => ["up"],
      "lsp.completion_down"      => ["down"],
      "lsp.completion_accept"    => ["enter", "return", "tab"],
      "lsp.completion_cancel"    => ["escape"],
      "lsp.problems_up"          => ["up"],
      "lsp.problems_down"        => ["down"],
      "lsp.problems_accept"      => ["enter", "return"],
      "lsp.problems_cancel"      => ["escape"],
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

    private def self.empty_action_map : ActionMap
      ActionMap.new
    end

    def self.load(path : String?, on_warning : Proc(String, Nil)? = nil) : ActionMap
      load_layers(path, on_warning).effective
    end

    # Load the default layer and the sparse user layer separately.  The
    # effective map is suitable for dispatch; overrides is the exact set of
    # configured actions, including explicit empty arrays.
    def self.load_layers(path : String?, on_warning : Proc(String, Nil)? = nil) : Layers
      return Layers.new(defaults, empty_action_map) if path.nil? || path.empty?
      key_file = Path.new(path)
      unless File.file?(key_file.to_s)
        warning = "Keymap file not found: #{path}"
        on_warning.try &.call(warning)
        STDERR.puts("Failed to load keymap #{path}: file not found")
        return Layers.new(defaults, empty_action_map)
      end

      load_layers_from_file(key_file, on_warning)
    rescue ex
      warning = "Failed to load keymap #{path}: #{ex.class} #{ex.message}"
      on_warning.try &.call(warning)
      STDERR.puts(warning)
      Layers.new(defaults, empty_action_map)
    end

    def self.resolve_default_path : String?
      if env_path = ENV["ADAMANTINE_CONFIG"]?
        return env_path unless env_path.empty?
      end
      if legacy_env_path = ENV["CRYSTAL_EDITOR_CONFIG"]?
        return legacy_env_path unless legacy_env_path.empty?
      end

      home = ENV["HOME"]?
      return nil unless home

      candidates = [
        Path.new(home, ".config", "adamantine", "config.json"),
        Path.new(home, ".adamantine", "config.json"),
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
      if env_path = ENV["ADAMANTINE_CONFIG"]?
        return env_path unless env_path.empty?
      end
      if legacy_env_path = ENV["CRYSTAL_EDITOR_CONFIG"]?
        return legacy_env_path unless legacy_env_path.empty?
      end

      home = ENV["HOME"]?
      return nil unless home
      Path.new(home, ".config", "adamantine", "config.json").to_s
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
        when "ctrl", "alt", "shift", "meta", "option", "opt"
          modifiers << (part == "option" || part == "opt" ? "alt" : part)
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
      # Preserve the legacy helper's first-owner behavior and all-context
      # search.  New conflict-aware callers should use actions_for_binding.
      bindings.each do |action, keys|
        keys.each do |candidate|
          return action if normalize_binding(candidate) == wanted
        end
      end
      nil
    end

    # Return every action which owns a normalized binding in the requested
    # routing scope.  Results are sorted so conflict UI and diagnostics do not
    # depend on JSON/hash insertion order.
    def self.actions_for_binding(
      bindings : ActionMap,
      binding : String,
      context : BindingContext = BindingContext::Global,
    ) : Array(Action)
      wanted = normalize_binding(binding)
      return [] of Action if wanted.empty?

      bindings.keys.sort.select do |action|
        next false unless action_in_context?(action, context)
        bindings[action].any? { |candidate| normalize_binding(candidate) == wanted }
      end
    end

    # Return all owners of a candidate binding except the action being edited.
    # Keeping the action parameter explicit prevents callers from accidentally
    # treating the first owner as the only conflict.
    def self.conflicting_actions(
      bindings : ActionMap,
      action : Action,
      binding : String,
      context : BindingContext,
    ) : Array(Action)
      actions_for_binding(bindings, binding, context).reject { |owner| owner == action }
    end

    # Infer a modal scope when the caller is editing one action.  Global and
    # focused actions remain in their shared default collision domain.
    def self.conflicting_actions(bindings : ActionMap, action : Action, binding : String) : Array(Action)
      wanted = normalize_binding(binding)
      return [] of Action if wanted.empty?

      bindings.keys.sort.select do |owner|
        next false if owner == action
        next false unless action_contexts_overlap?(action, owner)
        bindings[owner].any? { |candidate| normalize_binding(candidate) == wanted }
      end
    end

    # Return conflicts for each binding currently assigned to an action.  A
    # map retains which physical key caused each conflict, which is needed by
    # Settings to explain and remove every same-context owner.
    def self.conflicts_for_action(
      bindings : ActionMap,
      action : Action,
      context : BindingContext,
    ) : Hash(KeyBinding, Array(Action))
      result = Hash(KeyBinding, Array(Action)).new
      keys = bindings[action]?
      return result unless keys

      normalize_bindings(keys).each do |binding|
        owners = conflicting_actions(bindings, action, binding, context)
        result[binding] = owners unless owners.empty?
      end
      result
    end

    def self.conflicts_for_action(bindings : ActionMap, action : Action) : Hash(KeyBinding, Array(Action))
      result = Hash(KeyBinding, Array(Action)).new
      keys = bindings[action]?
      return result unless keys

      normalize_bindings(keys).each do |binding|
        owners = conflicting_actions(bindings, action, binding)
        result[binding] = owners unless owners.empty?
      end
      result
    end

    # Actions not explicitly assigned to a modal scope are part of the single
    # global/focused collision domain.  Context-specific action names are
    # deliberately enumerated here rather than inferred from physical keys.
    def self.action_contexts(action : Action) : Array(BindingContext)
      case action
      when "app.menu_close", "app.menu_select"
        [BindingContext::Menu, BindingContext::QuickOpen]
      when "app.quick_open_up", "app.quick_open_down"
        [BindingContext::QuickOpen]
      when "lsp.completion_up", "lsp.completion_down", "lsp.completion_accept", "lsp.completion_cancel"
        [BindingContext::Completion]
      when "lsp.problems_up", "lsp.problems_down", "lsp.problems_accept", "lsp.problems_cancel"
        [BindingContext::ProblemsModal]
      when "lsp.popup_close"
        [BindingContext::Popup]
      else
        if action.starts_with?("lsp.menu_")
          [BindingContext::LspMenu]
        elsif action.starts_with?("app.menu_")
          [BindingContext::Menu]
        else
          [BindingContext::Global]
        end
      end
    end

    private def self.action_in_context?(action : Action, context : BindingContext) : Bool
      contexts = action_contexts(action)
      contexts.includes?(context)
    end

    private def self.action_contexts_overlap?(left : Action, right : Action) : Bool
      left_contexts = action_contexts(left)
      right_contexts = action_contexts(right)

      left_contexts.any? do |left_context|
        right_contexts.any? do |right_context|
          left_context == right_context
        end
      end
    end

    def self.duplicate_binding_warnings(bindings : ActionMap) : Array(String)
      warnings = [] of String
      BindingContext.values.each do |context|
        keys = bindings.values.flat_map { |action_bindings| normalize_bindings(action_bindings) }.uniq.sort
        keys.each do |key|
          actions = actions_for_binding(bindings, key, context)
          next unless actions.size > 1
          warnings << "Key #{key} is bound to #{actions.join(", ")}"
        end
      end
      warnings.uniq.sort
    end

    # Serialize an effective map as a sparse delta from the built-in defaults.
    # Callers with provenance should use serializable_overrides_payload or
    # save_overrides so an explicit override equal to today's default is not
    # accidentally erased.
    def self.serializable_payload(bindings : ActionMap) : String
      serializable_overrides_payload(sparse_overrides(bindings))
    end

    # Serialize exactly the supplied sparse layer, including empty arrays and
    # unknown action names.
    def self.serializable_overrides_payload(overrides : ActionMap) : String
      payload = ActionMap.new
      overrides.keys.sort.each do |action|
        payload[action] = normalize_bindings(overrides[action]? || [] of KeyBinding)
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
      save_overrides(path, sparse_overrides(bindings))
    end

    # Persist an already separated sparse override layer without materializing
    # inherited defaults.  SettingsConfig owns atomic root preservation.
    def self.save_overrides(path : String, overrides : ActionMap) : Nil
      root = SettingsConfig.read_config_root_for_update(path)
      keymap = JSON.parse(serializable_overrides_payload(overrides)).as_h["keymap"]
      root["keymap"] = keymap
      SettingsConfig.write_config_root(path, root)
    end

    private def self.load_layers_from_file(path : Path, on_warning : Proc(String, Nil)? = nil) : Layers
      key_size = File.info(path.to_s).size
      if key_size > MAX_KEYMAP_FILE_BYTES
        warning = "Keymap file too large: #{path} (#{key_size} bytes)"
        on_warning.try &.call(warning)
        STDERR.puts(warning)
        return Layers.new(defaults, empty_action_map)
      end

      raw = read_json_file_with_limit(path.to_s)
      return Layers.new(defaults, empty_action_map) unless raw
      map = defaults
      keymap = raw["keymap"]?
      parsed = parse_keymap(keymap, path.to_s, on_warning)
      return Layers.new(map, empty_action_map) unless parsed
      overrides = empty_action_map
      parsed.each do |action, keys|
        copied = keys.dup
        overrides[action] = copied
        map[action] = copied.dup
      end
      Layers.new(map, overrides)
    rescue ex
      warning = "Invalid keymap #{path}: #{ex.class} #{ex.message}"
      on_warning.try &.call(warning)
      STDERR.puts(warning)
      Layers.new(defaults, empty_action_map)
    end

    private def self.parse_keymap(
      raw_keymap : JSON::Any?,
      path : String,
      on_warning : Proc(String, Nil)?,
    ) : ActionMap?
      return empty_action_map unless raw_keymap
      unless raw_hash = raw_keymap.as_h?
        warn_invalid_override(path, "keymap", on_warning)
        return nil
      end

      result = ActionMap.new
      raw_hash.each do |action, value|
        bindings, valid = parse_binding_value(value)
        if valid
          result[action] = bindings
        else
          warn_invalid_override(path, action, on_warning)
        end
      end
      result
    end

    private def self.parse_binding_value(value : JSON::Any) : Tuple(Array(KeyBinding), Bool)
      if array = value.as_a?
        # Exact [] is the one intentional unbind representation.
        return {[] of KeyBinding, true} if array.empty?

        single = array.compact_map do |entry|
          entry.as_s?.try { |entry_str| parse_binding_text(entry_str) }
        end.flatten
        normalized = normalize_bindings(single)
        return {normalized, !normalized.empty?}
      end

      if string = value.as_s?
        single = parse_binding_text(string)
        normalized = normalize_bindings(single)
        return {normalized, !normalized.empty?}
      end

      {[] of KeyBinding, false}
    end

    private def self.sparse_overrides(bindings : ActionMap) : ActionMap
      overrides = empty_action_map
      bindings.each do |action, keys|
        normalized = normalize_bindings(keys)
        defaults_for_action = DEFAULT_KEY_MAP[action]?
        default_bindings = defaults_for_action ? normalize_bindings(defaults_for_action) : nil
        if default_bindings.nil? || normalized != default_bindings
          overrides[action] = normalized
        end
      end
      overrides
    end

    private def self.warn_invalid_override(
      path : String,
      action : String,
      on_warning : Proc(String, Nil)?,
    ) : Nil
      warning = "Invalid keymap override #{action} in #{path}; expected a non-empty string/array or an explicit empty array; keeping the inherited default"
      on_warning.try &.call(warning)
      STDERR.puts(warning)
    end

    private def self.read_json_file_with_limit(path : String) : JSON::Any?
      limit = MAX_KEYMAP_FILE_BYTES + 1
      data = Bytes.new(limit)
      bytes_read = 0

      File.open(path, "r") do |file|
        bytes_read = file.read(data)
      end

      return nil if bytes_read > MAX_KEYMAP_FILE_BYTES
      JSON.parse(String.new(data[0, bytes_read]))
    rescue ex
      raise ex
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
