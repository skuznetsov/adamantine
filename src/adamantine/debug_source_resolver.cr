require "digest/sha256"

require "./debug_profile_store"
require "./debug_source_store"
require "./text_coordinates"

module Adamantine::Debugging
  enum SourceResolutionKind
    LocalFile
    SessionReference
    Unavailable
  end

  struct DebugSourcePosition
    getter line : Int32
    getter column : Int32

    def initialize(@line : Int32, @column : Int32)
    end
  end

  class DebugSourceResolution
    getter kind : SourceResolutionKind
    getter checksum_status : ChecksumStatus
    @local_path : String?
    @display_path : String?
    @source_key : DebugSourceKey?
    @reason : String?

    def initialize(@kind : SourceResolutionKind, source_key : DebugSourceKey? = nil,
                   local_path : String? = nil, reason : String? = nil,
                   @checksum_status : ChecksumStatus = ChecksumStatus::Unverified,
                   display_path : String? = nil)
      @source_key = source_key
      @local_path = local_path.try(&.dup)
      @display_path = display_path.try(&.dup)
      @reason = reason.try(&.dup)
    end

    def local_path : String?
      @local_path.try(&.dup)
    end

    # Adapter path is display-only when identity comes from sourceReference.
    # It never grants local-file read or edit authority.
    def display_path : String?
      @display_path.try(&.dup)
    end

    def source_key : DebugSourceKey?
      @source_key
    end

    def reason : String?
      @reason.try(&.dup)
    end

    def unavailable? : Bool
      @kind == SourceResolutionKind::Unavailable
    end
  end

  # Resolves only direct in-project files, explicit prefix mappings, or a
  # session-scoped positive sourceReference. It never guesses by basename and
  # performs no file reads; callers pass source contents explicitly when they
  # want checksum evidence.
  class DebugSourceResolver
    @project_root : Path
    @source_maps : Array(DebugSourceMap)
    @session_id : String?

    def initialize(project_root : Path | String, source_maps : Array(DebugSourceMap), session_id : String? = nil)
      root = Path.new(project_root.to_s).expand
      @project_root = if File.directory?(root.to_s)
                        Path.new(File.realpath(root.to_s))
                      else
                        root
                      end
      @source_maps = source_maps.dup
      @session_id = session_id.try(&.dup)
    end

    def resolve(*, adapter_path : String? = nil, source_reference : Int32? = nil,
                checksum : DebugChecksum? = nil, local_contents : String? = nil) : DebugSourceResolution
      if reference = source_reference
        return unavailable("sourceReference must not be negative") if reference < 0
        if reference > 0
          session = @session_id
          return unavailable("sourceReference has no current session identity") unless session
          key = DebugSourceKey.session(session.not_nil!, reference)
          return DebugSourceResolution.new(
            SourceResolutionKind::SessionReference,
            key,
            checksum_status: ChecksumStatus::Unverified,
            display_path: safe_display_path(adapter_path),
          )
        end
      end

      if raw = adapter_path
        return unavailable("adapter path is invalid") unless raw.valid_encoding? && raw.bytesize <= 4096 && raw.each_char.all? { |char| char.ord >= 0x20 && char.ord != 0x7f }
        mapped = resolve_map(raw, checksum, local_contents)
        return mapped.not_nil! if mapped

        path = Path.new(raw)
        if path.absolute?
          direct = safe_local_file(path)
          if direct && within?(direct.not_nil!, @project_root)
            return local_resolution(direct.not_nil!, checksum, local_contents)
          end
        end
        # For path-only and zero-reference results, an unmappable path stays
        # unavailable rather than guessing another local source.
        return unavailable("adapter source path has no safe local mapping")
      end
      unavailable("adapter supplied neither a local path nor a sourceReference")
    rescue
      unavailable("source identity could not be resolved safely")
    end

    # DAP line and column are one-based; editor positions are zero-based.
    # UTF-16 columns are converted by the existing shared coordinate helper.
    def to_editor_position(source_text : String, dap_line : Int32, dap_column : Int32) : DebugSourcePosition
      raise ArgumentError.new("DAP line and column must be positive") if dap_line <= 0 || dap_column <= 0
      raise ArgumentError.new("source text is not valid UTF-8") unless source_text.valid_encoding?
      text = source_line_at(source_text, dap_line - 1)
      raise ArgumentError.new("DAP line is outside source text") unless text
      position_on_line(text.not_nil!, dap_line, dap_column)
    end

    # Resolves from a retained session snapshot by copying only the requested
    # source line; the public whole-document `text` getter is intentionally
    # not used for stack-frame navigation.
    def to_editor_position(snapshot : DebugSourceSnapshot, dap_line : Int32, dap_column : Int32) : DebugSourcePosition
      raise ArgumentError.new("DAP line and column must be positive") if dap_line <= 0 || dap_column <= 0
      text = snapshot.line_text(dap_line - 1)
      raise ArgumentError.new("DAP line is outside source text") unless text
      position_on_line(text.not_nil!, dap_line, dap_column)
    end

    private def position_on_line(text : String, dap_line : Int32, dap_column : Int32) : DebugSourcePosition
      text = text[0...-1] if text.ends_with?('\r')
      column = Adamantine::TextCoordinates.utf16_to_codepoint(text, dap_column - 1)
      DebugSourcePosition.new(dap_line - 1, column)
    end

    private def resolve_map(adapter_path : String, checksum : DebugChecksum?, contents : String?) : DebugSourceResolution?
      normalized = normalize_adapter_path(adapter_path)
      matches = [] of Tuple(DebugSourceMap, String)
      @source_maps.each do |mapping|
        prefix = normalize_adapter_path(mapping.adapter_prefix)
        next unless prefix
        path = normalized
        next unless path
        if path.not_nil! == prefix.not_nil! || path.not_nil!.starts_with?(prefix.not_nil!.ends_with?('/') ? prefix.not_nil! : "#{prefix.not_nil!}/")
          matches << {mapping, prefix.not_nil!}
        end
      end
      return nil if matches.empty?
      longest = matches.max_of { |_, prefix| prefix.bytesize }
      best = matches.select { |_, prefix| prefix.bytesize == longest }
      destinations = best.map { |mapping, _| mapping.local_prefix }.uniq
      return unavailable("source map is ambiguous at the longest prefix") if destinations.size > 1

      mapping = best.first[0]
      prefix = best.first[1]
      path = normalized.not_nil!
      suffix = path == prefix ? "" : path.byte_slice(prefix.bytesize, path.bytesize - prefix.bytesize) || ""
      local_root = Path.new(mapping.local_prefix)
      unless local_root.absolute?
        return unavailable("source map local prefix is not absolute: #{mapping.local_prefix}")
      end
      local_root_info = File.info?(local_root, follow_symlinks: false)
      unless local_root_info && local_root_info.not_nil!.directory? && !local_root_info.not_nil!.symlink?
        return unavailable("source map local prefix is missing or unsafe: #{mapping.local_prefix}")
      end
      canonical_root = Path.new(File.realpath(local_root.to_s))
      return unavailable("source map local prefix is not canonical") unless canonical_root == local_root.expand
      candidate = suffix.empty? ? canonical_root : Path.new(canonical_root.to_s + suffix)
      canonical_file = safe_local_file(candidate)
      return unavailable("mapped local source is missing or unsafe: #{candidate}") unless canonical_file
      local_resolution(canonical_file.not_nil!, checksum, contents)
    end

    private def local_resolution(path : Path, checksum : DebugChecksum?, contents : String?) : DebugSourceResolution
      canonical = Path.new(File.realpath(path.to_s))
      key = DebugSourceKey.local(canonical)
      status = checksum_status(checksum, contents)
      DebugSourceResolution.new(SourceResolutionKind::LocalFile, key, canonical.to_s, checksum_status: status)
    end

    private def checksum_status(checksum : DebugChecksum?, contents : String?) : ChecksumStatus
      return ChecksumStatus::Unverified unless checksum && contents && contents.not_nil!.valid_encoding?
      checksum.not_nil!.compare(contents.not_nil!)
    end

    private def safe_display_path(path : String?) : String?
      return nil unless path
      value = path.not_nil!
      return nil unless value.valid_encoding? && value.bytesize <= 4096
      return nil unless value.each_char.all? { |char| char.ord >= 0x20 && char.ord != 0x7f }
      value
    end

    # Scans only through the requested line and allocates at most that line,
    # rather than materializing an array of every line in a large source file.
    private def source_line_at(source_text : String, requested_line : Int32) : String?
      start = 0
      line = 0
      index = 0
      source_text.each_byte do |byte|
        if byte == 0x0a
          return source_text.byte_slice(start, index - start) if line == requested_line
          line += 1
          start = index + 1
        end
        index += 1
      end
      return nil unless line == requested_line
      source_text.byte_slice(start, source_text.bytesize - start)
    end

    private def safe_local_file(path : Path) : Path?
      expanded = path.expand
      return nil if has_symlink_component?(expanded)
      info = File.info?(expanded, follow_symlinks: false)
      return nil unless info && info.not_nil!.file? && !info.not_nil!.symlink?
      Path.new(File.realpath(expanded.to_s))
    rescue
      nil
    end

    private def has_symlink_component?(path : Path) : Bool
      current = Path.new("/")
      path.to_s.split('/').reject(&.empty?).each do |component|
        current = current / component
        info = File.info?(current, follow_symlinks: false)
        return true if info && info.not_nil!.symlink?
      end
      false
    rescue
      true
    end

    private def normalize_adapter_path(value : String) : String?
      return nil unless value.starts_with?('/') && value.bytesize <= 4096
      components = value.split('/').reject(&.empty?)
      return "/" if components.empty?
      return nil if components.any? { |part| part == "." || part == ".." }
      "/" + components.join('/')
    end

    private def within?(path : Path, root : Path) : Bool
      value = path.expand.to_s
      base = root.expand.to_s
      value == base || value.starts_with?(base.ends_with?('/') ? base : "#{base}/")
    end

    private def unavailable(reason : String) : DebugSourceResolution
      bounded = String.build do |output|
        bytes = 0
        reason.each_char do |char|
          break if bytes + char.bytesize > 256
          output << char if char.ord >= 0x20 && char.ord != 0x7f
          bytes += char.bytesize
        end
      end
      DebugSourceResolution.new(SourceResolutionKind::Unavailable, reason: bounded)
    end
  end
end
