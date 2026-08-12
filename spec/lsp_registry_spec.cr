require "spec"
require "file_utils"
require "../src/editor/lsp_registry"

def with_temp_workspace(prefix : String = "editor-lsp-registry-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::LspRegistry do
  describe ".detect_project_language" do
    it "detects crystal from shard.yml" do
      with_temp_workspace do |tmp|
        File.write((tmp / "shard.yml").to_s, "name: test\n")
        raise "expected crystal" unless CrystalEditor::LspRegistry.detect_project_language(tmp) == "crystal"
      end
    end

    it "detects go from go.mod" do
      with_temp_workspace do |tmp|
        File.write((tmp / "go.mod").to_s, "module example\n")
        raise "expected go" unless CrystalEditor::LspRegistry.detect_project_language(tmp) == "go"
      end
    end

    it "detects rust from Cargo.toml" do
      with_temp_workspace do |tmp|
        File.write((tmp / "Cargo.toml").to_s, "[package]\n")
        raise "expected rust" unless CrystalEditor::LspRegistry.detect_project_language(tmp) == "rust"
      end
    end

    it "detects python from pyproject.toml" do
      with_temp_workspace do |tmp|
        File.write((tmp / "pyproject.toml").to_s, "[project]\n")
        raise "expected python" unless CrystalEditor::LspRegistry.detect_project_language(tmp) == "python"
      end
    end

    it "detects typescript from package.json" do
      with_temp_workspace do |tmp|
        File.write((tmp / "package.json").to_s, "{}\n")
        raise "expected typescript" unless CrystalEditor::LspRegistry.detect_project_language(tmp) == "typescript"
      end
    end

    it "detects elixir from mix.exs" do
      with_temp_workspace do |tmp|
        File.write((tmp / "mix.exs").to_s, "defmodule Test do\nend\n")
        raise "expected elixir" unless CrystalEditor::LspRegistry.detect_project_language(tmp) == "elixir"
      end
    end

    it "returns nil for empty directory" do
      with_temp_workspace do |tmp|
        raise "expected nil" unless CrystalEditor::LspRegistry.detect_project_language(tmp).nil?
      end
    end
  end

  describe ".which" do
    it "returns nil for nonexistent binary" do
      raise "expected nil" unless CrystalEditor::LspRegistry.which("__nonexistent_binary_xyzzy_99__").nil?
    end

    it "returns nil for empty name" do
      raise "expected nil" unless CrystalEditor::LspRegistry.which("").nil?
    end
  end

  describe "LANGUAGE_SERVERS" do
    it "contains crystal entry" do
      raise "missing crystal" unless CrystalEditor::LspRegistry::LANGUAGE_SERVERS.has_key?("crystal")
    end

    it "contains go entry" do
      raise "missing go" unless CrystalEditor::LspRegistry::LANGUAGE_SERVERS.has_key?("go")
    end

    it "contains rust entry" do
      raise "missing rust" unless CrystalEditor::LspRegistry::LANGUAGE_SERVERS.has_key?("rust")
    end

    it "contains python entry" do
      raise "missing python" unless CrystalEditor::LspRegistry::LANGUAGE_SERVERS.has_key?("python")
    end

    it "crystal servers include crystalline" do
      servers = CrystalEditor::LspRegistry::LANGUAGE_SERVERS["crystal"]
      raise "missing crystalline" unless servers.includes?("crystalline")
    end

    it "crystal servers prefer adamas_lsp" do
      servers = CrystalEditor::LspRegistry::LANGUAGE_SERVERS["crystal"]
      raise "missing adamas_lsp" unless servers.includes?("adamas_lsp")
      raise "adamas_lsp should be first" unless servers[0] == "adamas_lsp"
    end
  end

  describe ".find_adamas_lsp" do
    it "finds bin/adamas_lsp under the project root" do
      with_temp_workspace do |tmp|
        bin = tmp / "bin"
        Dir.mkdir_p(bin)
        path = bin / "adamas_lsp"
        File.write(path.to_s, "#!/bin/sh\nexit 0\n")
        File.chmod(path.to_s, 0o755)

        found = CrystalEditor::LspRegistry.find_adamas_lsp(tmp, tmp)
        raise "expected #{path}" unless found == path.to_s
      end
    end

    it "finds Adamas/adamas/bin/adamas_lsp from a sibling root" do
      with_temp_workspace do |tmp|
        adamas_bin = tmp / "Adamas" / "adamas" / "bin"
        Dir.mkdir_p(adamas_bin)
        path = adamas_bin / "adamas_lsp"
        File.write(path.to_s, "#!/bin/sh\nexit 0\n")
        File.chmod(path.to_s, 0o755)

        project = tmp / "Crystal" / "job_hunter"
        Dir.mkdir_p(project)
        found = CrystalEditor::LspRegistry.find_adamas_lsp(project, project)
        raise "expected #{path}" unless found == path.to_s
      end
    end
  end

  describe ".find_lsp_for_language" do
    it "returns nil for unknown language" do
      raise "expected nil" unless CrystalEditor::LspRegistry.find_lsp_for_language("__unknown_lang__").nil?
    end
  end
end
