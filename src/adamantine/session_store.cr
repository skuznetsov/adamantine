require "digest/sha256"
require "json"
require "set"

module Adamantine
  # Bounded, metadata-only persistence for the editor's last UI state.
  #
  # SessionStore deliberately has no filesystem side effects in its
  # constructor.  The application opts into persistence at the session
  # lifecycle boundary by calling #save; ordinary startup only calls #load.
  class SessionStore
    VERSION           =   1
    MAX_TABS          = 128
    MAX_STATE_BYTES   = 1_i64 * 1024 * 1024
    MAX_PATH_BYTES    = 4096
    MAX_WARNING_BYTES =  512

    STATE_DIRECTORY   = "adamantine"
    SESSION_DIRECTORY = "sessions"
    SESSION_ENV       = "ADAMANTINE_SESSION"
    STATE_HOME_ENV    = "ADAMANTINE_STATE_HOME"

    struct Position
      getter line : Int32
      getter column : Int32

      def initialize(@line : Int32, @column : Int32)
      end

      # Names used by editor adapters that speak in row/character terms.
      def row : Int32
        @line
      end

      def character : Int32
        @column
      end
    end

    struct TabState
      getter path : Path
      getter cursor : Position
      getter scroll : Position

      def initialize(path : Path | String, @cursor : Position = Position.new(0, 0), @scroll : Position = Position.new(0, 0))
        @path = Path.new(path.to_s)
      end

      def cursor_line : Int32
        @cursor.line
      end

      def cursor_column : Int32
        @cursor.column
      end

      def scroll_line : Int32
        @scroll.line
      end

      def scroll_column : Int32
        @scroll.column
      end
    end

    struct Snapshot
      getter project_root : Path
      getter tabs : Array(TabState)
      getter active_tab : Int32?

      def initialize(project_root : Path | String, tabs : Array(TabState), @active_tab : Int32? = nil)
        @project_root = Path.new(project_root.to_s)
        @tabs = tabs.dup
      end

      # Adapter aliases keep the persisted model independent of controller
      # vocabulary while preserving one canonical field in the wire format.
      def root : Path
        @project_root
      end

      def active_index : Int32?
        @active_tab
      end
    end

    alias SessionState = Snapshot
    alias Tab = TabState

    struct LoadResult
      getter state : Snapshot?
      getter warnings : Array(String)

      def initialize(@state : Snapshot?, @warnings : Array(String) = [] of String)
      end

      def snapshot : Snapshot?
        @state
      end

      def valid? : Bool
        !@state.nil?
      end

      def empty? : Bool
        @state.nil?
      end
    end

    struct SaveResult
      getter saved : Bool
      getter warnings : Array(String)

      def initialize(@saved : Bool, @warnings : Array(String) = [] of String)
      end

      def saved? : Bool
        @saved
      end

      def success? : Bool
        @saved
      end

      def ok? : Bool
        @saved
      end

      def error? : Bool
        !@saved
      end
    end

    getter state_root : Path

    @enabled : Bool
    @configuration_warnings : Array(String)

    # `state_root` is an explicit test/runtime override.  When omitted, the
    # environment override wins, then the platform state directory is used.
    # `enabled` is intentionally injectable so App construction/tests do not
    # need to mutate process-wide environment state.
    def initialize(state_root : Path | String | Nil = nil, enabled : Bool? = nil)
      @configuration_warnings = [] of String
      @enabled = enabled.nil? ? ENV[SESSION_ENV]? != "0" : enabled.not_nil!
      @state_root = resolve_state_root(state_root)
    end

    def enabled? : Bool
      @enabled
    end

    # Returns the project-keyed path without creating the directory or file.
    # The project is canonicalized when possible so aliases share one state.
    def state_path(project_root : Path | String) : Path
      canonical = canonical_project_root(project_root) || Path.new(project_root.to_s).expand
      digest = Digest::SHA256.hexdigest(canonical.to_s)
      @state_root / SESSION_DIRECTORY / "#{digest}.json"
    end

    def load(project_root : Path | String) : LoadResult
      warnings = @configuration_warnings.dup
      unless @enabled
        warnings << warning("session persistence is disabled")
        return LoadResult.new(nil, warnings)
      end

      root = canonical_project_root(project_root)
      unless root
        warnings << warning("project root is unavailable or not a directory")
        return LoadResult.new(nil, warnings)
      end

      path = state_path(root)
      unless safe_state_path?(path)
        warnings << warning("session state path contains a symlink or is not private")
        return LoadResult.new(nil, warnings)
      end
      info = File.info?(path, follow_symlinks: false)
      return LoadResult.new(nil, warnings) unless info

      unless private_file?(path, info)
        warnings << warning("session state target is not a private regular file")
        return LoadResult.new(nil, warnings)
      end

      raw = read_bounded(path)
      unless raw
        warnings << warning("session state exceeds #{MAX_STATE_BYTES} bytes")
        return LoadResult.new(nil, warnings)
      end

      state = parse_snapshot(raw.not_nil!, root)
      unless state
        warnings << warning("session state is malformed or unsupported")
        return LoadResult.new(nil, warnings)
      end

      LoadResult.new(state, warnings)
    rescue
      fallback_warnings = @configuration_warnings.dup
      fallback_warnings << warning("session state could not be read")
      LoadResult.new(nil, fallback_warnings)
    end

    def save(snapshot : Snapshot) : SaveResult
      warnings = @configuration_warnings.dup
      unless @enabled
        warnings << warning("session persistence is disabled")
        return SaveResult.new(false, warnings)
      end

      root = canonical_project_root(snapshot.project_root)
      unless root
        warnings << warning("project root is unavailable or not a directory")
        return SaveResult.new(false, warnings)
      end

      normalized = normalize_snapshot(snapshot, root)
      unless normalized
        warnings << warning("session snapshot is outside bounds or contains an unsafe path")
        return SaveResult.new(false, warnings)
      end

      serialized = serialize_snapshot(normalized.not_nil!)
      if serialized.bytesize.to_i64 > MAX_STATE_BYTES
        warnings << warning("session state exceeds #{MAX_STATE_BYTES} bytes")
        return SaveResult.new(false, warnings)
      end

      path = state_path(root)
      begin
        ensure_state_layout!
        atomic_write(path, serialized)
        SaveResult.new(true, warnings)
      rescue ex
        # The old file remains in place until the fully-written temporary file
        # is renamed.  Report the failure and never turn it into an empty
        # snapshot.
        warnings << warning("session state was not written: #{ex.message || ex.class.name}")
        SaveResult.new(false, warnings)
      end
    end

    # Hook for a focused atomic-write fault test in a subclass.  It runs after
    # the temporary file is flushed/fsynced and before the final rename.
    protected def before_state_rename(_path : Path) : Nil
    end

    private def resolve_state_root(explicit : Path | String | Nil) : Path
      value = explicit.try(&.to_s)
      if value.nil? || value.not_nil!.empty?
        value = ENV[STATE_HOME_ENV]?
      end
      if value.nil? || value.not_nil!.empty?
        state_home = ENV["XDG_STATE_HOME"]?
        base = if state_home && !state_home.empty? && Path.new(state_home.not_nil!).absolute?
                 Path.new(state_home.not_nil!)
               else
                 Path.home / ".local" / "state"
               end
        return (base / "adamantine").expand
      end

      raw = value.not_nil!
      candidate = Path.new(raw)
      unless candidate.absolute?
        @configuration_warnings << warning("session state root must be absolute")
        @enabled = false
        return Path.new("/") / ".adamantine-invalid-state-root"
      end
      candidate.expand
    rescue
      @configuration_warnings << warning("session state root is invalid")
      @enabled = false
      Path.new("/") / ".adamantine-invalid-state-root"
    end

    private def canonical_project_root(value : Path | String) : Path?
      expanded = Path.new(value.to_s).expand
      return nil if expanded.to_s.bytesize > MAX_PATH_BYTES
      info = File.info?(expanded, follow_symlinks: false)
      return nil unless info

      real = Path.new(File.realpath(expanded.to_s))
      real_info = File.info?(real, follow_symlinks: false)
      return nil unless real_info && real_info.directory? && !real_info.symlink?
      real
    rescue
      nil
    end

    private def normalize_snapshot(snapshot : Snapshot, root : Path) : Snapshot?
      return nil unless canonical_project_root(snapshot.project_root) == root
      return nil if snapshot.tabs.size > MAX_TABS
      active = snapshot.active_tab
      if active
        return nil if active.not_nil! < 0 || active.not_nil! >= snapshot.tabs.size
      end

      normalized_tabs = [] of TabState
      seen_paths = Set(String).new
      snapshot.tabs.each do |tab|
        return nil unless valid_position?(tab.cursor) && valid_position?(tab.scroll)
        path = canonical_source_path(tab.path, root)
        return nil unless path
        return nil unless seen_paths.add?(path.not_nil!.to_s)
        normalized_tabs << TabState.new(path.not_nil!, tab.cursor, tab.scroll)
      end
      Snapshot.new(root, normalized_tabs, active)
    end

    private def valid_position?(position : Position) : Bool
      position.line >= 0 && position.column >= 0
    end

    private def serialize_snapshot(snapshot : Snapshot) : String
      JSON.build do |json|
        json.object do
          json.field "version", VERSION
          json.field "project_root", snapshot.project_root.to_s
          if active = snapshot.active_tab
            json.field "active_tab", active
          else
            json.field "active_tab", nil
          end
          json.field "tabs" do
            json.array do
              snapshot.tabs.each do |tab|
                json.object do
                  json.field "path", tab.path.to_s
                  json.field "cursor" do
                    json.object do
                      json.field "line", tab.cursor.line
                      json.field "column", tab.cursor.column
                    end
                  end
                  json.field "scroll" do
                    json.object do
                      json.field "line", tab.scroll.line
                      json.field "column", tab.scroll.column
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    private def parse_snapshot(text : String, root : Path) : Snapshot?
      raw = JSON.parse(text)
      object = raw.as_h?
      return nil unless object && exact_keys?(object.not_nil!, ["version", "project_root", "active_tab", "tabs"])
      fields = object.not_nil!

      version = fields["version"].as_i64?
      return nil unless version == VERSION
      persisted_root = fields["project_root"].as_s?
      return nil unless persisted_root && valid_path_text?(persisted_root.not_nil!)
      return nil unless Path.new(persisted_root.not_nil!).expand.to_s == root.to_s

      active_ok, active = parse_active(fields["active_tab"])
      return nil unless active_ok

      raw_tabs = fields["tabs"].as_a?
      return nil unless raw_tabs && raw_tabs.not_nil!.size <= MAX_TABS
      tabs = [] of TabState
      seen_paths = Set(String).new
      raw_tabs.not_nil!.each do |raw_tab|
        tab_hash = raw_tab.as_h?
        return nil unless tab_hash && exact_keys?(tab_hash.not_nil!, ["path", "cursor", "scroll"])
        tab = tab_hash.not_nil!

        path_text = tab["path"].as_s?
        return nil unless path_text && valid_path_text?(path_text.not_nil!)
        path = canonical_source_path(path_text.not_nil!, root)
        return nil unless path
        return nil unless seen_paths.add?(path.not_nil!.to_s)

        cursor = parse_position(tab["cursor"])
        scroll = parse_position(tab["scroll"])
        return nil unless cursor && scroll
        tabs << TabState.new(path.not_nil!, cursor.not_nil!, scroll.not_nil!)
      end

      if active
        return nil if active.not_nil! < 0 || active.not_nil! >= tabs.size
      end
      Snapshot.new(root, tabs, active)
    rescue
      nil
    end

    private def parse_active(value : JSON::Any) : Tuple(Bool, Int32?)
      return {true, nil} if value.raw.nil?
      integer = value.as_i64?
      return {false, nil} unless integer
      return {false, nil} if integer.not_nil! < 0 || integer.not_nil! > Int32::MAX
      {true, integer.not_nil!.to_i32}
    end

    private def parse_position(value : JSON::Any) : Position?
      object = value.as_h?
      return nil unless object && exact_keys?(object.not_nil!, ["line", "column"])
      fields = object.not_nil!
      line = fields["line"].as_i64?
      column = fields["column"].as_i64?
      return nil unless line && column
      return nil if line.not_nil! < 0 || line.not_nil! > Int32::MAX
      return nil if column.not_nil! < 0 || column.not_nil! > Int32::MAX
      Position.new(line.not_nil!.to_i32, column.not_nil!.to_i32)
    end

    private def exact_keys?(object : Hash(String, JSON::Any), keys : Array(String)) : Bool
      return false unless object.size == keys.size
      keys.all? { |key| object.has_key?(key) }
    end

    private def canonical_source_path(value : Path | String, root : Path) : Path?
      raw = value.to_s
      return nil unless valid_path_text?(raw)
      candidate = Path.new(raw)
      return nil unless candidate.absolute?
      expanded = candidate.expand
      return nil unless path_within?(expanded, root)
      return nil if symlink_component?(expanded)

      if info = File.info?(expanded, follow_symlinks: false)
        return nil if info.symlink?
        real = Path.new(File.realpath(expanded.to_s))
        return path_within?(real, root) ? real : nil
      end

      # A missing file is valid metadata, but resolve its nearest existing
      # parent so a symlinked directory cannot smuggle an outside path in.
      parent = expanded.parent
      while parent.to_s != "/"
        if info = File.info?(parent, follow_symlinks: false)
          return nil if info.symlink? || !info.directory?
          real_parent = Path.new(File.realpath(parent.to_s))
          return nil unless path_within?(real_parent, root)
          return expanded
        end
        next_parent = parent.parent
        break if next_parent == parent
        parent = next_parent
      end
      expanded
    rescue
      nil
    end

    private def path_within?(path : Path, root : Path) : Bool
      path_text = path.expand.to_s
      root_text = root.expand.to_s
      return true if root_text == "/" && path_text.starts_with?("/")
      path_text == root_text || path_text.starts_with?("#{root_text}/")
    end

    private def valid_path_text?(text : String) : Bool
      return false if text.bytesize > MAX_PATH_BYTES
      return false unless text.valid_encoding?
      text.each_char.all? do |char|
        codepoint = char.ord
        codepoint >= 0x20 && codepoint != 0x7f && !(codepoint >= 0x80 && codepoint <= 0x9f)
      end
    end

    private def symlink_component?(path : Path) : Bool
      current = Path.new("/")
      path.expand.to_s.split('/').reject(&.empty?).each do |component|
        current = current / component
        info = File.info?(current, follow_symlinks: false)
        return true if info && info.symlink?
      end
      false
    rescue
      true
    end

    private def safe_state_path?(path : Path) : Bool
      current = Path.new("/")
      components = path.expand.to_s.split('/').reject(&.empty?)
      state_root_text = @state_root.expand.to_s
      components.each_with_index do |component, index|
        current = current / component
        info = File.info?(current, follow_symlinks: false)
        next unless info
        return false if info.symlink?

        current_text = current.to_s
        owned = current_text == state_root_text || current_text.starts_with?("#{state_root_text}/")
        next unless owned
        if index < components.size - 1
          return false unless info.directory?
          return false if (info.permissions.to_i & 0o077) != 0
        else
          return false unless info.file?
          return false if (info.permissions.to_i & 0o077) != 0
        end
      end
      true
    rescue
      false
    end

    private def read_bounded(path : Path) : String?
      capacity = (MAX_STATE_BYTES + 1).to_i
      String.build(capacity) do |output|
        File.open(path.to_s, "rb") do |file|
          chunk = Bytes.new(16 * 1024)
          total = 0_i64
          loop do
            count = file.read(chunk)
            break if count == 0
            total += count
            return nil if total > MAX_STATE_BYTES
            output.write(chunk[0, count])
          end
        end
      end
    rescue
      nil
    end

    private def ensure_state_layout! : Nil
      ensure_private_directory!(@state_root)
      ensure_private_directory!(@state_root / SESSION_DIRECTORY)
    end

    private def ensure_private_directory!(path : Path) : Nil
      expanded = path.expand
      raise "state root must not be filesystem root" if expanded.to_s == "/"
      components = expanded.to_s.split('/').reject(&.empty?)
      current = Path.new("/")
      components.each_with_index do |component, index|
        current = current / component
        info = File.info?(current, follow_symlinks: false)
        if info.nil?
          Dir.mkdir(current.to_s, 0o700)
          info = File.info?(current, follow_symlinks: false)
        end
        raise "state path component is a symlink" unless info
        raise "state path component is a symlink" if info.not_nil!.symlink?
        raise "state path component is not a directory" unless info.not_nil!.directory?
        if index == components.size - 1 && (info.not_nil!.permissions.to_i & 0o077) != 0
          raise "state directory is not private"
        end
      end
    end

    private def atomic_write(path : Path, serialized : String) : Nil
      existing = File.info?(path, follow_symlinks: false)
      if existing && (existing.not_nil!.symlink? || !existing.not_nil!.file?)
        raise "session state target is not a regular file"
      end

      temporary = File.tempfile(prefix: ".session-", suffix: ".tmp", dir: path.parent.to_s)
      temporary_path = Path.new(temporary.path)
      committed = false
      begin
        # Set the final private mode before any bytes are written. A failure
        # after rename must never be reported as a failed save after it has
        # already replaced the previous valid state.
        File.chmod(temporary_path.to_s, 0o600)
        temporary.write(serialized.to_slice)
        temporary.flush
        temporary.fsync
        temporary.close
        before_state_rename(path)
        File.rename(temporary_path.to_s, path.to_s)
        fsync_directory(path.parent)
        committed = true
      ensure
        temporary.close unless temporary.closed?
        File.delete(temporary_path.to_s) unless committed || !File.exists?(temporary_path)
      end
    end

    private def private_file?(path : Path, info : File::Info) : Bool
      info.file? && !info.symlink? && (info.permissions.to_i & 0o077) == 0
    end

    private def fsync_directory(path : Path) : Nil
      directory = File.open(path.to_s, "r")
      begin
        directory.fsync
      rescue
        # Directory fsync is unavailable on some macOS/filesystem variants;
        # the temporary file itself was already fsynced before rename.
      ensure
        directory.close unless directory.closed?
      end
    rescue
      nil
    end

    private def warning(message : String) : String
      return message if message.bytesize <= MAX_WARNING_BYTES
      String.build do |output|
        count = 0
        message.each_char do |char|
          break if count + char.bytesize > MAX_WARNING_BYTES
          output << char
          count += char.bytesize
        end
      end
    end
  end
end
