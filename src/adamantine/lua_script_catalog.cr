require "digest/sha256"
require "json"

require "./editor_tools"
require "./file_revision"

module Adamantine
  module LuaScripts
    class CatalogError < Exception
    end

    # A single frozen catalog entry. The accessors return copies so picker or
    # runner code cannot mutate the bytes or grant list after review begins.
    class Entry
      getter id : String
      getter name : String
      getter digest : String

      @source : String
      @capabilities : Array(EditorTools::Capability)
      @builtin : Bool

      def initialize(@id : String, @name : String, source : String,
                     @capabilities : Array(EditorTools::Capability), @builtin : Bool)
        @source = source.dup
        @capabilities = @capabilities.dup
        @digest = Digest::SHA256.hexdigest(@source)
      end

      def source : String
        @source.dup
      end

      def capabilities : Array(EditorTools::Capability)
        @capabilities.dup
      end

      def builtin? : Bool
        @builtin
      end
    end

    # The catalog intentionally accepts only an explicit user configuration
    # directory. It has no project-root input and never scans a workspace.
    # Built-ins remain available when a user's manifest is malformed; all
    # user entries from that manifest are rejected together.
    class Catalog
      MAX_MANIFEST_BYTES = 32 * 1024
      MAX_SOURCE_BYTES   = 64 * 1024
      MAX_SCRIPTS        =  64
      MAX_ID_BYTES       =  64
      MAX_NAME_BYTES     = 128
      MAX_FILE_BYTES     = 128

      getter config_root : Path?
      @entries : Array(Entry)
      @user_error : String?

      def self.user_config_root : Path?
        home = ENV["HOME"]?
        return unless home && !home.empty?
        home_path = Path.new(home)
        return unless home_path.absolute?
        home_path / ".config" / "adamantine" / "lua"
      end

      def initialize(config_root : Path? = Catalog.user_config_root)
        @config_root = config_root
        @entries = builtin_entries
        @user_error = nil

        begin
          unless root = @config_root
            raise CatalogError.new("HOME must be absolute before loading user scripts")
          end
          unless root.absolute?
            raise CatalogError.new("user script directory must be absolute")
          end
          user_entries = load_user_entries
          @entries.concat(user_entries)
        rescue ex : CatalogError
          @user_error = "Lua user scripts ignored: #{ex.message || "invalid manifest"}"
        rescue
          @user_error = "Lua user scripts ignored: manifest or source is unavailable"
        end
      end

      def entries : Array(Entry)
        @entries.dup
      end

      def user_error : String?
        @user_error.try(&.dup)
      end

      def find(id : String) : Entry?
        @entries.find { |entry| entry.id == id }
      end

      private def builtin_entries : Array(Entry)
        [
          Entry.new(
            "list-buffers",
            "List buffers",
            "local result=editor.call(\"editor.list_buffers\",{offset=0,limit=32}); if result.status~=\"ok\" then print(result.message or result.status); return end; for _,buffer in ipairs(result.data.buffers) do print(buffer.path) end; if result.data.partial or result.data.next_offset then print(\"Buffer list is partial; more buffers or entries were omitted\") end",
            [EditorTools::Capability::ReadEditor],
            true
          ),
          Entry.new(
            "open-readme",
            "Open README",
            "local result=editor.call(\"editor.open_file\",{path=\"README.md\"}); if result.status~=\"ok\" then print(result.message or result.status) end",
            [EditorTools::Capability::Navigate],
            true
          ),
          Entry.new(
            "trim-trailing-spaces",
            "Trim trailing spaces — first 32 lines",
            "local selected=editor.context.selected_buffer; if not selected then print(\"No selected buffer\"); return end; local result=editor.call(\"editor.read_buffer\",{buffer_id=selected.buffer_id,revision=selected.revision,start_line=1,line_count=32,start_column=0,max_columns=1024}); if result.status~=\"ok\" then print(result.message or result.status); return end; local edits={}; for _,line in ipairs(result.data.lines) do if line.complete then local trimmed=line.text:gsub(\"[ \\t]+$\",\"\"); if trimmed~=line.text then table.insert(edits,{start_line=line.line,start_column=utf8.len(trimmed),end_line=line.line,end_column=utf8.len(line.text),new_text=\"\"}) end end end; local partial=result.data.partial; if #edits==0 then if partial then print(\"No changes in fully observed lines; scan was partial (first 32 lines / continuations omitted)\") else print(\"No trailing spaces in fully observed lines\") end; return end; local proposal=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits=edits}); if proposal.status~=\"ok\" then print(proposal.message or proposal.status) else if partial then print(\"Proposed \"..#edits..\" trailing-space edit(s) in fully observed lines; scan partial (first 32 lines / continuations omitted); review before accepting\") else print(\"Proposed \"..#edits..\" trailing-space edit(s); review before accepting\") end end",
            [EditorTools::Capability::ReadEditor, EditorTools::Capability::ProposeEdits],
            true
          ),
        ]
      end

      private def load_user_entries : Array(Entry)
        root = @config_root || raise CatalogError.new("user script directory is unavailable")
        manifest_path = root / "manifest.json"
        root_info = File.info?(root.to_s, follow_symlinks: false)
        return [] of Entry unless root_info
        unless root_info.not_nil!.directory? && !root_info.not_nil!.symlink?
          raise CatalogError.new("user script directory must be a real directory")
        end

        manifest_stamp = FileRevision.probe(manifest_path)
        return [] of Entry if manifest_stamp.missing?
        unless manifest_stamp.regular? && !manifest_stamp.symlink?
          raise CatalogError.new("manifest must be a regular non-symlink file")
        end
        if manifest_stamp.size > MAX_MANIFEST_BYTES
          raise CatalogError.new("manifest exceeds #{MAX_MANIFEST_BYTES} bytes")
        end

        manifest_result = FileRevision.read(manifest_path, max_bytes: MAX_MANIFEST_BYTES.to_i64,
          expected_stamp: manifest_stamp, chunk_size: 4096)
        unless manifest_result.stable?
          raise CatalogError.new("manifest changed or exceeded its read bound")
        end
        manifest_source = manifest_result.content.not_nil!
        unless manifest_source.valid_encoding? && manifest_source.bytesize <= MAX_MANIFEST_BYTES
          raise CatalogError.new("manifest is invalid UTF-8 or oversized")
        end

        manifest = begin
          EditorTools.parse_bounded_json(manifest_source).as_h?
        rescue
          nil
        end
        raise CatalogError.new("manifest is not bounded versioned JSON") unless manifest
        unless manifest.keys.to_set == Set{"version", "scripts"}
          raise CatalogError.new("manifest has an unsupported shape")
        end
        version = manifest["version"].as_i?
        raise CatalogError.new("manifest version must be 1") unless version == 1
        scripts = manifest["scripts"].as_a?
        raise CatalogError.new("manifest scripts must be an array") unless scripts
        if scripts.size > MAX_SCRIPTS
          raise CatalogError.new("manifest exceeds #{MAX_SCRIPTS} user scripts")
        end

        return [] of Entry if scripts.empty?

        source_root = root / "scripts"
        source_root_info = file_info_without_following(source_root)
        unless source_root_info.directory? && !source_root_info.symlink?
          raise CatalogError.new("script source directory must be a real directory")
        end

        seen_ids = BUILTIN_IDS.to_set
        entries = [] of Entry
        scripts.each do |raw_entry|
          entry = raw_entry.as_h?
          raise CatalogError.new("manifest script entry must be an object") unless entry
          unless entry.keys.to_set == Set{"id", "name", "file", "capabilities"}
            raise CatalogError.new("manifest script entry has an unsupported shape")
          end

          id = bounded_string(entry["id"], "script id", MAX_ID_BYTES)
          unless id.matches?(/\A[a-z0-9][a-z0-9-]*\z/)
            raise CatalogError.new("script id must use lowercase letters, digits, and hyphens")
          end
          raise CatalogError.new("duplicate or reserved script id") unless seen_ids.add?(id)

          name = bounded_string(entry["name"], "script name", MAX_NAME_BYTES)
          raise CatalogError.new("script name cannot be empty") if name.strip.empty?

          file = bounded_string(entry["file"], "script file", MAX_FILE_BYTES)
          unless file.ends_with?(".lua") && Path.new(file).basename.to_s == file &&
                 !file.includes?('/') && !file.includes?('\\') && !file.includes?("..")
            raise CatalogError.new("script file must be a direct .lua child")
          end

          capabilities = parse_capabilities(entry["capabilities"])
          source_path = source_root / file
          source_stamp = FileRevision.probe(source_path)
          unless source_stamp.regular? && !source_stamp.symlink?
            raise CatalogError.new("script source must be a regular non-symlink file")
          end
          if source_stamp.size > MAX_SOURCE_BYTES
            raise CatalogError.new("script source exceeds #{MAX_SOURCE_BYTES} bytes")
          end
          source_result = FileRevision.read(source_path, max_bytes: MAX_SOURCE_BYTES.to_i64,
            expected_stamp: source_stamp, chunk_size: 4096)
          unless source_result.stable?
            raise CatalogError.new("script source changed or exceeded its read bound")
          end
          source = source_result.content.not_nil!
          unless source.valid_encoding? && source.bytesize <= MAX_SOURCE_BYTES
            raise CatalogError.new("script source is invalid UTF-8 or oversized")
          end
          if source.each_char.any? { |char| EditorTools.control_char?(char) && !char.in?('\n', '\r', '\t') }
            raise CatalogError.new("script source contains an unsupported control character")
          end

          entries << Entry.new(id, name, source, capabilities, false)
        end

        entries
      rescue error : CatalogError
        raise error
      rescue
        raise CatalogError.new("manifest or source is unavailable")
      end

      private def file_info_without_following(path : Path) : File::Info
        File.info(path.to_s, follow_symlinks: false)
      rescue
        raise CatalogError.new("manifest or source is unavailable")
      end

      private def bounded_string(value : JSON::Any, label : String, max_bytes : Int32) : String
        text = value.as_s?
        unless text && text.valid_encoding? && !text.empty? && text.bytesize <= max_bytes
          raise CatalogError.new("#{label} is invalid or too long")
        end
        if text.each_char.any? { |char| EditorTools.control_char?(char) }
          raise CatalogError.new("#{label} contains a control character")
        end
        text
      end

      private def parse_capabilities(value : JSON::Any) : Array(EditorTools::Capability)
        raw = value.as_a?
        raise CatalogError.new("capabilities must be an array") unless raw

        seen = Set(EditorTools::Capability).new
        capabilities = [] of EditorTools::Capability
        raw.each do |item|
          name = item.as_s?
          raise CatalogError.new("capability must be a string") unless name
          capability = case name
                       when "read_editor"   then EditorTools::Capability::ReadEditor
                       when "read_debugger" then EditorTools::Capability::ReadDebugger
                       when "navigate"      then EditorTools::Capability::Navigate
                       when "propose_edits" then EditorTools::Capability::ProposeEdits
                       else
                         raise CatalogError.new("manifest requests an unknown capability")
                       end
          raise CatalogError.new("manifest repeats a capability") unless seen.add?(capability)
          capabilities << capability
        end

        capabilities
      end

      private BUILTIN_IDS = ["list-buffers", "open-readme", "trim-trailing-spaces"]
    end
  end
end
