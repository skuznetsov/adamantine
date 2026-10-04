require "digest/sha256"
require "json"
require "file_utils"

module Adamantine::Debugging
  # The only supported source-map shape: adapter path prefix -> local path
  # prefix. This model intentionally has no extension fields.
  class DebugSourceMap
    MAX_PREFIX_BYTES = 4096

    @adapter_prefix : String
    @local_prefix : String

    def initialize(adapter_prefix : String, local_prefix : String)
      raise ArgumentError.new("adapter source prefix is empty or too long") if adapter_prefix.empty? || adapter_prefix.bytesize > MAX_PREFIX_BYTES
      raise ArgumentError.new("local source prefix is empty or too long") if local_prefix.empty? || local_prefix.bytesize > MAX_PREFIX_BYTES
      raise ArgumentError.new("source prefix is not valid UTF-8") unless adapter_prefix.valid_encoding? && local_prefix.valid_encoding?
      @adapter_prefix = adapter_prefix.dup
      @local_prefix = local_prefix.dup
    end

    def adapter_prefix : String
      @adapter_prefix.dup
    end

    def local_prefix : String
      @local_prefix.dup
    end

    def to_json_object : Hash(String, JSON::Any)
      {
        "adapter_prefix" => JSON::Any.new(@adapter_prefix),
        "local_prefix"   => JSON::Any.new(@local_prefix),
      }
    end
  end

  # A launch profile is inert data. It never resolves executables through a
  # shell and never starts, builds, downloads, or modifies a target.
  class LaunchProfile
    MAX_ID_BYTES      =  128
    MAX_NAME_BYTES    =  256
    MAX_ARG_BYTES     = 4096
    MAX_ARG_COUNT     =  128
    MAX_SOURCE_MAPS   =   32
    MAX_PROFILE_BYTES = 64 * 1024

    @id : String
    @name : String
    @adapter_argv : Array(String)
    @program : String
    @cwd : String
    @target_argv : Array(String)
    @source_maps : Array(DebugSourceMap)

    def initialize(*, id : String, name : String, adapter_argv : Array(String), program : String,
                   cwd : String, target_argv : Array(String) = [] of String,
                   source_maps : Array(DebugSourceMap) = [] of DebugSourceMap)
      raise ArgumentError.new("profile id is empty or too long") if id.empty? || id.bytesize > MAX_ID_BYTES
      raise ArgumentError.new("profile name is empty or too long") if name.empty? || name.bytesize > MAX_NAME_BYTES
      raise ArgumentError.new("adapter argv must contain an executable") if adapter_argv.empty?
      raise ArgumentError.new("too many launch arguments") if adapter_argv.size > MAX_ARG_COUNT || target_argv.size > MAX_ARG_COUNT
      raise ArgumentError.new("too many source maps") if source_maps.size > MAX_SOURCE_MAPS
      all_strings = [id, name, program, cwd] + adapter_argv + target_argv
      raise ArgumentError.new("profile contains invalid or oversized text") if all_strings.any? { |value| value.bytesize > MAX_ARG_BYTES || !value.valid_encoding? || value.includes?('\0') }
      raise ArgumentError.new("profile contains control characters") if all_strings.any? { |value| value.each_char.any? { |char| char.ord < 0x20 || char.ord == 0x7f } }
      @id = id.dup
      @name = name.dup
      @adapter_argv = adapter_argv.map(&.dup)
      @program = program.dup
      @cwd = cwd.dup
      @target_argv = target_argv.map(&.dup)
      @source_maps = source_maps.dup
      raise ArgumentError.new("profile exceeds serialized-size limit") if to_json_object.to_json.bytesize > MAX_PROFILE_BYTES
    end

    def id : String
      @id.dup
    end

    def name : String
      @name.dup
    end

    def adapter_argv : Array(String)
      @adapter_argv.map(&.dup)
    end

    def program : String
      @program.dup
    end

    def cwd : String
      @cwd.dup
    end

    def target_argv : Array(String)
      @target_argv.map(&.dup)
    end

    def source_maps : Array(DebugSourceMap)
      @source_maps.dup
    end

    # Paths that are missing or not canonical remain visible as review errors;
    # this method performs no search, shell lookup, or filesystem mutation.
    def review_errors(project_root : Path | String) : Array(String)
      errors = [] of String
      check_absolute_file(errors, "adapter executable", @adapter_argv.first, executable: true)
      check_absolute_file(errors, "debug program", @program, executable: true)
      check_absolute_directory(errors, "working directory", @cwd)
      @source_maps.each_with_index do |mapping, index|
        prefix = mapping.adapter_prefix
        unless Path.new(prefix).absolute? && clean_path_text?(prefix)
          errors << "source map #{index + 1} adapter prefix must be an explicit absolute path"
        end
        local = mapping.local_prefix
        unless Path.new(local).absolute?
          errors << "source map #{index + 1} local prefix must be an absolute path"
          next
        end
        info = File.info?(local, follow_symlinks: false)
        unless info && info.not_nil!.directory?
          errors << "source map #{index + 1} local prefix is missing or not a directory: #{local}"
          next
        end
        canonical = File.realpath(local)
        errors << "source map #{index + 1} local prefix is not canonical: #{local}" unless canonical == Path.new(local).expand.to_s
      end
      root = Path.new(project_root.to_s)
      errors << "project root is missing or not a directory" unless File.directory?(root.to_s)
      errors
    end

    def to_json_object : Hash(String, JSON::Any)
      maps = @source_maps.map { |mapping| JSON::Any.new(mapping.to_json_object) }
      {
        "id"           => JSON::Any.new(@id),
        "name"         => JSON::Any.new(@name),
        "adapter_argv" => JSON::Any.new(@adapter_argv.map { |value| JSON::Any.new(value) }),
        "program"      => JSON::Any.new(@program),
        "cwd"          => JSON::Any.new(@cwd),
        "target_argv"  => JSON::Any.new(@target_argv.map { |value| JSON::Any.new(value) }),
        "source_maps"  => JSON::Any.new(maps),
      }
    end

    private def check_absolute_file(errors : Array(String), label : String, value : String, executable : Bool) : Nil
      path = Path.new(value)
      unless path.absolute?
        errors << "#{label} must be an explicit absolute path: #{value}"
        return
      end
      info = File.info?(value, follow_symlinks: false)
      unless info && info.not_nil!.file?
        errors << "#{label} is missing or not a regular file: #{value}"
        return
      end
      errors << "#{label} is not canonical: #{value}" unless File.realpath(value) == path.expand.to_s
      if executable && (info.not_nil!.permissions.to_i & 0o111) == 0
        errors << "#{label} is not executable: #{value}"
      end
    end

    private def check_absolute_directory(errors : Array(String), label : String, value : String) : Nil
      path = Path.new(value)
      unless path.absolute?
        errors << "#{label} must be an explicit absolute path: #{value}"
        return
      end
      info = File.info?(value, follow_symlinks: false)
      unless info && info.not_nil!.directory?
        errors << "#{label} is missing or not a directory: #{value}"
        return
      end
      errors << "#{label} is not canonical: #{value}" unless File.realpath(value) == path.expand.to_s
    end

    private def clean_path_text?(value : String) : Bool
      value.valid_encoding? && value.each_char.all? { |char| char.ord >= 0x20 && char.ord != 0x7f }
    end
  end

  class DebugProfileStore
    VERSION          = 1
    MAX_STATE_BYTES  = 256 * 1024
    MAX_PROFILES     =  32
    MAX_WARNING_SIZE = 512

    @private_root : Path

    def initialize(private_root : Path | String)
      @private_root = Path.new(private_root.to_s).expand
    end

    # The path is deterministic but calculation has no filesystem side effect.
    def state_path(project_root : Path | String) : Path
      project = canonical_project(project_root) || Path.new(project_root.to_s).expand
      digest = Digest::SHA256.hexdigest(project.to_s)
      @private_root / "debug-profiles" / "#{digest}.json"
    end

    def load(project_root : Path | String) : LoadResult
      root = canonical_project(project_root)
      return LoadResult.new(false, [] of LaunchProfile, nil, ["project root is missing or not a directory"]) unless root
      path = state_path(root.not_nil!)
      return LoadResult.new(true, [] of LaunchProfile, nil) unless File.info?(path, follow_symlinks: false)
      unless safe_state_path?(path)
        return LoadResult.new(false, [] of LaunchProfile, nil, ["profile state path is symlinked or not private"])
      end
      info = File.info?(path, follow_symlinks: false)
      return LoadResult.new(false, [] of LaunchProfile, nil, ["profile state is not a private regular file"]) unless info && info.not_nil!.file? && (info.not_nil!.permissions.to_i & 0o077) == 0
      raw = read_bounded(path)
      return LoadResult.new(false, [] of LaunchProfile, nil, ["profile state exceeds #{MAX_STATE_BYTES} bytes"]) unless raw
      parse(raw.not_nil!, root.not_nil!)
    rescue
      LoadResult.new(false, [] of LaunchProfile, nil, ["profile state is malformed or unsafe"])
    end

    def save(project_root : Path | String, profiles : Array(LaunchProfile), last_profile_id : String?) : SaveResult
      root = canonical_project(project_root)
      return SaveResult.new(false, ["project root is missing or not a directory"]) unless root
      return SaveResult.new(false, ["too many launch profiles"]) if profiles.size > MAX_PROFILES
      ids = profiles.map(&.id)
      return SaveResult.new(false, ["profile ids must be unique"]) unless ids.uniq.size == ids.size
      return SaveResult.new(false, ["last profile must identify a saved profile"]) if last_profile_id && !ids.includes?(last_profile_id.not_nil!)

      payload = JSON::Any.new({
        "version"         => JSON::Any.new(VERSION),
        "project_root"    => JSON::Any.new(root.not_nil!.to_s),
        "last_profile_id" => last_profile_id ? JSON::Any.new(last_profile_id.not_nil!) : JSON::Any.new(nil),
        "profiles"        => JSON::Any.new(profiles.map { |profile| JSON::Any.new(profile.to_json_object) }),
      } of String => JSON::Any)
      serialized = payload.to_json
      return SaveResult.new(false, ["profile state exceeds #{MAX_STATE_BYTES} bytes"]) if serialized.bytesize > MAX_STATE_BYTES

      ensure_private_directory!(@private_root)
      directory = @private_root / "debug-profiles"
      ensure_private_directory!(directory)
      path = state_path(root.not_nil!)
      atomic_write(path, serialized)
      SaveResult.new(true)
    rescue ex
      SaveResult.new(false, [warning("profile state was not saved: #{ex.message || ex.class.name}")])
    end

    struct LoadResult
      @profiles : Array(LaunchProfile)
      @warnings : Array(String)
      getter last_profile_id : String?
      getter valid : Bool

      def initialize(@valid : Bool, profiles : Array(LaunchProfile), last_profile_id : String?, warnings : Array(String) = [] of String)
        @profiles = profiles.dup
        @last_profile_id = last_profile_id.try(&.dup)
        @warnings = warnings.map(&.dup)
      end

      def valid? : Bool
        @valid
      end

      def profiles : Array(LaunchProfile)
        @profiles.dup
      end

      def warnings : Array(String)
        @warnings.map(&.dup)
      end
    end

    struct SaveResult
      @warnings : Array(String)
      getter saved : Bool

      def initialize(@saved : Bool, warnings : Array(String) = [] of String)
        @warnings = warnings.map(&.dup)
      end

      def saved? : Bool
        @saved
      end

      def warnings : Array(String)
        @warnings.map(&.dup)
      end
    end

    private def canonical_project(value : Path | String) : Path?
      path = Path.new(value.to_s).expand
      info = File.info?(path, follow_symlinks: false)
      return nil unless info && info.not_nil!.directory? && !info.not_nil!.symlink?
      Path.new(File.realpath(path.to_s))
    rescue
      nil
    end

    private def parse(raw : String, project : Path) : LoadResult
      object = JSON.parse(raw).as_h?
      return invalid unless object && exact_keys?(object.not_nil!, ["version", "project_root", "last_profile_id", "profiles"])
      fields = object.not_nil!
      return invalid unless fields["version"].as_i? == VERSION
      return invalid unless fields["project_root"].as_s? == project.to_s
      last_id = fields["last_profile_id"].raw.nil? ? nil : fields["last_profile_id"].as_s?
      return invalid if !fields["last_profile_id"].raw.nil? && !last_id
      raw_profiles = fields["profiles"].as_a?
      return invalid unless raw_profiles && raw_profiles.not_nil!.size <= MAX_PROFILES
      profiles = [] of LaunchProfile
      raw_profiles.not_nil!.each do |entry|
        profile = parse_profile(entry)
        return invalid unless profile
        profiles << profile.not_nil!
      end
      ids = profiles.map(&.id)
      return invalid unless ids.uniq.size == ids.size
      return invalid if last_id && !ids.includes?(last_id.not_nil!)
      LoadResult.new(true, profiles, last_id)
    rescue
      invalid
    end

    private def parse_profile(value : JSON::Any) : LaunchProfile?
      object = value.as_h?
      keys = ["id", "name", "adapter_argv", "program", "cwd", "target_argv", "source_maps"]
      return nil unless object && exact_keys?(object.not_nil!, keys)
      fields = object.not_nil!
      id = fields["id"].as_s?
      name = fields["name"].as_s?
      program = fields["program"].as_s?
      cwd = fields["cwd"].as_s?
      adapter = parse_string_array(fields["adapter_argv"])
      target = parse_string_array(fields["target_argv"])
      raw_maps = fields["source_maps"].as_a?
      return nil unless id && name && program && cwd && adapter && target && raw_maps && raw_maps.not_nil!.size <= LaunchProfile::MAX_SOURCE_MAPS
      maps = [] of DebugSourceMap
      raw_maps.not_nil!.each do |raw_map|
        map = raw_map.as_h?
        return nil unless map && exact_keys?(map.not_nil!, ["adapter_prefix", "local_prefix"])
        adapter_prefix = map.not_nil!["adapter_prefix"].as_s?
        local_prefix = map.not_nil!["local_prefix"].as_s?
        return nil unless adapter_prefix && local_prefix
        maps << DebugSourceMap.new(adapter_prefix.not_nil!, local_prefix.not_nil!)
      end
      LaunchProfile.new(id: id.not_nil!, name: name.not_nil!, adapter_argv: adapter.not_nil!, program: program.not_nil!, cwd: cwd.not_nil!, target_argv: target.not_nil!, source_maps: maps)
    rescue
      nil
    end

    private def parse_string_array(value : JSON::Any) : Array(String)?
      entries = value.as_a?
      return nil unless entries && entries.not_nil!.size <= LaunchProfile::MAX_ARG_COUNT
      result = [] of String
      entries.not_nil!.each do |entry|
        string = entry.as_s?
        return nil unless string && string.not_nil!.bytesize <= LaunchProfile::MAX_ARG_BYTES && string.not_nil!.valid_encoding?
        result << string.not_nil!
      end
      result
    end

    private def exact_keys?(object : Hash(String, JSON::Any), expected : Array(String)) : Bool
      object.size == expected.size && expected.all? { |key| object.has_key?(key) }
    end

    private def invalid : LoadResult
      LoadResult.new(false, [] of LaunchProfile, nil, ["profile state is malformed or unsupported"])
    end

    private def read_bounded(path : Path) : String?
      String.build do |output|
        File.open(path.to_s, "rb") do |file|
          buffer = Bytes.new(8192)
          total = 0
          loop do
            count = file.read(buffer)
            break if count == 0
            total += count
            return nil if total > MAX_STATE_BYTES
            output.write(buffer[0, count])
          end
        end
      end
    rescue
      nil
    end

    private def safe_state_path?(path : Path) : Bool
      root_text = @private_root.expand.to_s
      current = Path.new("/")
      components = path.expand.to_s.split('/').reject(&.empty?)
      components.each_with_index do |component, index|
        current = current / component
        info = File.info?(current, follow_symlinks: false)
        next unless info
        return false if info.not_nil!.symlink?
        owned = current.to_s == root_text || current.to_s.starts_with?("#{root_text}/")
        next unless owned
        if index == components.size - 1
          return false unless info.not_nil!.file? && (info.not_nil!.permissions.to_i & 0o077) == 0
        else
          return false unless info.not_nil!.directory? && (info.not_nil!.permissions.to_i & 0o077) == 0
        end
      end
      true
    rescue
      false
    end

    private def ensure_private_directory!(path : Path) : Nil
      expanded = path.expand
      raise "private profile root cannot be filesystem root" if expanded.to_s == "/"
      current = Path.new("/")
      components = expanded.to_s.split('/').reject(&.empty?)
      components.each_with_index do |component, index|
        current = current / component
        info = File.info?(current, follow_symlinks: false)
        unless info
          Dir.mkdir(current.to_s, 0o700)
          info = File.info?(current, follow_symlinks: false)
        end
        raise "private profile directory is unsafe" unless info && info.not_nil!.directory? && !info.not_nil!.symlink?
        if index == components.size - 1 && (info.not_nil!.permissions.to_i & 0o077) != 0
          raise "private profile directory has permissive mode"
        end
      end
    end

    private def atomic_write(path : Path, serialized : String) : Nil
      if existing = File.info?(path, follow_symlinks: false)
        raise "profile state target is not a regular file" unless existing.file? && !existing.symlink? && (existing.permissions.to_i & 0o077) == 0
      end
      temp = File.tempfile(prefix: ".debug-profile-", suffix: ".tmp", dir: path.parent.to_s)
      temp_path = Path.new(temp.path)
      renamed = false
      begin
        File.chmod(temp_path.to_s, 0o600)
        temp.write(serialized.to_slice)
        temp.flush
        temp.fsync
        temp.close
        File.rename(temp_path.to_s, path.to_s)
        renamed = true
        begin
          directory = File.open(path.parent.to_s, "r")
          directory.fsync
          directory.close
        rescue
        end
      ensure
        temp.close unless temp.closed?
        File.delete(temp_path.to_s) unless renamed || !File.exists?(temp_path)
      end
    end

    private def warning(message : String) : String
      return message if message.bytesize <= MAX_WARNING_SIZE
      String.build do |output|
        bytes = 0
        message.each_char do |char|
          break if bytes + char.bytesize > MAX_WARNING_SIZE
          output << char
          bytes += char.bytesize
        end
      end
    end
  end
end
