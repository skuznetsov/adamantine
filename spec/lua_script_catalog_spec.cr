require "spec"
require "file_utils"
require "random/secure"
require "digest/sha256"

require "../src/adamantine/lua_script_catalog"

private def with_lua_script_catalog_root(&)
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-lua-catalog-#{Random::Secure.hex(8)}")
  scripts = root / "scripts"
  Dir.mkdir_p(scripts)
  yield root, scripts
ensure
  FileUtils.rm_rf(root) if root
end

describe Adamantine::LuaScripts::Catalog do
  it "provides only the three bounded built-ins when no user manifest exists" do
    with_lua_script_catalog_root do |root, _scripts|
      catalog = Adamantine::LuaScripts::Catalog.new(root)

      catalog.entries.map(&.id).should eq([
        "list-buffers",
        "open-readme",
        "trim-trailing-spaces",
      ])
      catalog.entries.map(&.name).should eq([
        "List buffers",
        "Open README",
        "Trim trailing spaces — first 32 lines",
      ])
      catalog.entries.map(&.builtin?).should eq([true, true, true])
      catalog.entries.all? { |entry| entry.digest.size == 64 }.should be_true
      catalog.user_error.should be_nil
    end
  end

  it "loads only explicitly listed user scripts and freezes the bytes and digest at catalog load" do
    with_lua_script_catalog_root do |root, scripts|
      source_path = scripts / "fixture-noop.lua"
      original_source = "print(\"fixture ran\")\n"
      File.write(source_path, original_source)
      File.write(root / "manifest.json", %({"version":1,"scripts":[{"id":"fixture-noop","name":"Fixture no-op","file":"fixture-noop.lua","capabilities":[]}] }))

      catalog = Adamantine::LuaScripts::Catalog.new(root)
      entry = catalog.entries.last

      entry.id.should eq("fixture-noop")
      entry.name.should eq("Fixture no-op")
      entry.capabilities.should be_empty
      entry.builtin?.should be_false
      entry.source.should eq(original_source)
      entry.digest.should eq(Digest::SHA256.hexdigest(original_source))

      File.write(source_path, "print(\"changed after review\")\n")
      entry.source.should eq(original_source)
      entry.digest.should eq(Digest::SHA256.hexdigest(original_source))
      mutable_capabilities = catalog.entries.last.capabilities
      mutable_capabilities.clear
      catalog.entries.last.source.should eq(original_source)
      catalog.entries.last.capabilities.should be_empty

      builtin_capabilities = catalog.entries.first.capabilities
      builtin_capabilities.clear
      catalog.entries.first.capabilities.should eq([Adamantine::EditorTools::Capability::ReadEditor])
    end
  end

  it "does not discover a workspace manifest or any unlisted source file" do
    with_lua_script_catalog_root do |root, scripts|
      File.write(scripts / "unlisted.lua", "print(\"must not run\")\n")
      File.write(root / "manifest.json", %({"version":1,"scripts":[]}))
      workspace = root / "project"
      Dir.mkdir_p(workspace / ".adamantine" / "lua")
      File.write(workspace / ".adamantine" / "lua" / "manifest.json", %({"version":1,"scripts":[{"id":"project","name":"Project script","file":"project.lua","capabilities":[]}]}))

      catalog = Adamantine::LuaScripts::Catalog.new(root)

      catalog.entries.map(&.id).should eq([
        "list-buffers",
        "open-readme",
        "trim-trailing-spaces",
      ])
      catalog.user_error.should be_nil
    end
  end

  it "rejects a whole user catalog with an unsupported version or an unknown capability" do
    with_lua_script_catalog_root do |root, scripts|
      File.write(scripts / "sample.lua", "print(\"sample\")\n")
      manifest = root / "manifest.json"

      File.write(manifest, %({"version":2,"scripts":[]}))
      catalog = Adamantine::LuaScripts::Catalog.new(root)
      catalog.entries.map(&.id).should eq(["list-buffers", "open-readme", "trim-trailing-spaces"])
      catalog.user_error.should_not be_nil

      File.write(manifest, %({"version":1,"scripts":[{"id":"sample","name":"Sample","file":"sample.lua","capabilities":["write_files"]}]}))
      catalog = Adamantine::LuaScripts::Catalog.new(root)
      catalog.entries.map(&.id).should eq(["list-buffers", "open-readme", "trim-trailing-spaces"])
      catalog.user_error.should_not be_nil
    end
  end

  it "rejects escaped, nested, duplicate, and symlinked script sources" do
    with_lua_script_catalog_root do |root, scripts|
      File.write(scripts / "sample.lua", "print(\"safe\")\n")
      manifest = root / "manifest.json"

      [
        %({"version":1,"scripts":[{"id":"escape","name":"Escape","file":"../outside.lua","capabilities":[]}]}),
        %({"version":1,"scripts":[{"id":"nested","name":"Nested","file":"nested/script.lua","capabilities":[]}]}),
        %({"version":1,"scripts":[{"id":"sample","name":"Sample","file":"sample.lua","capabilities":[]},{"id":"sample","name":"Duplicate","file":"sample.lua","capabilities":[]}]}),
      ].each do |invalid_manifest|
        File.write(manifest, invalid_manifest)
        catalog = Adamantine::LuaScripts::Catalog.new(root)
        catalog.entries.map(&.id).should eq(["list-buffers", "open-readme", "trim-trailing-spaces"])
        catalog.user_error.should_not be_nil
      end

      outside = root / "outside.lua"
      File.write(outside, "print(\"outside\")\n")
      symlink_path = scripts / "linked.lua"
      File.symlink(outside.to_s, symlink_path.to_s)
      File.write(manifest, %({"version":1,"scripts":[{"id":"linked","name":"Linked","file":"linked.lua","capabilities":[]}]}))
      catalog = Adamantine::LuaScripts::Catalog.new(root)
      catalog.entries.map(&.id).should eq(["list-buffers", "open-readme", "trim-trailing-spaces"])
      catalog.user_error.should_not be_nil
    end
  end

  it "enforces manifest, entry-count, metadata, source-size, and UTF-8 bounds" do
    with_lua_script_catalog_root do |root, scripts|
      manifest = root / "manifest.json"
      File.write(manifest, "{" + (" " * Adamantine::LuaScripts::Catalog::MAX_MANIFEST_BYTES))
      catalog = Adamantine::LuaScripts::Catalog.new(root)
      catalog.user_error.should_not be_nil

      File.write(manifest, %({"version":1,"scripts":[{"id":"sample","name":"Sample","file":"sample.lua","capabilities":[]}]}))
      File.write(scripts / "sample.lua", "x" * (Adamantine::LuaScripts::Catalog::MAX_SOURCE_BYTES + 1))
      catalog = Adamantine::LuaScripts::Catalog.new(root)
      catalog.user_error.should_not be_nil

      File.write(scripts / "sample.lua", "\xff".to_slice)
      catalog = Adamantine::LuaScripts::Catalog.new(root)
      catalog.user_error.should_not be_nil

      entries = (0..Adamantine::LuaScripts::Catalog::MAX_SCRIPTS).map do |index|
        %({"id":"script-#{index}","name":"Script #{index}","file":"script-#{index}.lua","capabilities":[]})
      end.join(",")
      File.write(manifest, %({"version":1,"scripts":[#{entries}]}))
      catalog = Adamantine::LuaScripts::Catalog.new(root)
      catalog.user_error.should_not be_nil
    end
  end

  it "does not use a relative path as an implicit user script catalog" do
    catalog = Adamantine::LuaScripts::Catalog.new(Path.new(".config/adamantine/lua"))

    catalog.entries.map(&.id).should eq([
      "list-buffers",
      "open-readme",
      "trim-trailing-spaces",
    ])
    catalog.user_error.not_nil!.should contain("must be absolute")
  end
end
