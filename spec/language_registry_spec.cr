require "spec"
require "../src/adamantine/language_registry"

describe Adamantine::LanguageRegistry do
  describe ".detect" do
    # Backward compatibility: all 12 original extensions
    it "detects crystal from .cr" do
      raise "expected crystal" unless Adamantine::LanguageRegistry.detect(Path.new("main.cr")) == "crystal"
    end

    it "detects ruby from .rb" do
      raise "expected ruby" unless Adamantine::LanguageRegistry.detect(Path.new("app.rb")) == "ruby"
    end

    it "detects python from .py" do
      raise "expected python" unless Adamantine::LanguageRegistry.detect(Path.new("script.py")) == "python"
    end

    it "detects typescript from .ts" do
      raise "expected typescript" unless Adamantine::LanguageRegistry.detect(Path.new("index.ts")) == "typescript"
    end

    it "detects javascript from .js" do
      raise "expected javascript" unless Adamantine::LanguageRegistry.detect(Path.new("app.js")) == "javascript"
    end

    it "detects json from .json" do
      raise "expected json" unless Adamantine::LanguageRegistry.detect(Path.new("data.json")) == "json"
    end

    it "detects markdown from .md" do
      raise "expected markdown" unless Adamantine::LanguageRegistry.detect(Path.new("README.md")) == "markdown"
    end

    it "detects yaml from .yml" do
      raise "expected yaml" unless Adamantine::LanguageRegistry.detect(Path.new("config.yml")) == "yaml"
    end

    it "detects yaml from .yaml" do
      raise "expected yaml" unless Adamantine::LanguageRegistry.detect(Path.new("config.yaml")) == "yaml"
    end

    it "detects toml from .toml" do
      raise "expected toml" unless Adamantine::LanguageRegistry.detect(Path.new("Cargo.toml")) == "toml"
    end

    it "detects bash from .sh" do
      raise "expected bash" unless Adamantine::LanguageRegistry.detect(Path.new("run.sh")) == "bash"
    end

    it "detects html from .html" do
      raise "expected html" unless Adamantine::LanguageRegistry.detect(Path.new("index.html")) == "html"
    end

    it "detects css from .css" do
      raise "expected css" unless Adamantine::LanguageRegistry.detect(Path.new("style.css")) == "css"
    end

    # New languages
    it "detects go from .go" do
      raise "expected go" unless Adamantine::LanguageRegistry.detect(Path.new("main.go")) == "go"
    end

    it "detects rust from .rs" do
      raise "expected rust" unless Adamantine::LanguageRegistry.detect(Path.new("lib.rs")) == "rust"
    end

    it "detects c from .c" do
      raise "expected c" unless Adamantine::LanguageRegistry.detect(Path.new("main.c")) == "c"
    end

    it "detects cpp from .cpp" do
      raise "expected cpp" unless Adamantine::LanguageRegistry.detect(Path.new("main.cpp")) == "cpp"
    end

    it "detects java from .java" do
      raise "expected java" unless Adamantine::LanguageRegistry.detect(Path.new("App.java")) == "java"
    end

    it "detects swift from .swift" do
      raise "expected swift" unless Adamantine::LanguageRegistry.detect(Path.new("main.swift")) == "swift"
    end

    it "detects zig from .zig" do
      raise "expected zig" unless Adamantine::LanguageRegistry.detect(Path.new("build.zig")) == "zig"
    end

    it "detects csharp from .cs" do
      raise "expected csharp" unless Adamantine::LanguageRegistry.detect(Path.new("Program.cs")) == "csharp"
    end

    it "detects elixir from .ex" do
      raise "expected elixir" unless Adamantine::LanguageRegistry.detect(Path.new("app.ex")) == "elixir"
    end

    it "detects haskell from .hs" do
      raise "expected haskell" unless Adamantine::LanguageRegistry.detect(Path.new("Main.hs")) == "haskell"
    end

    # Fallback
    it "returns plaintext for unknown extension" do
      raise "expected plaintext" unless Adamantine::LanguageRegistry.detect(Path.new("file.xyz")) == "plaintext"
    end

    it "returns plaintext for no extension" do
      raise "expected plaintext" unless Adamantine::LanguageRegistry.detect(Path.new("LICENSE")) == "plaintext"
    end

    # Filename-based detection
    it "detects makefile from Makefile" do
      raise "expected makefile" unless Adamantine::LanguageRegistry.detect(Path.new("Makefile")) == "makefile"
    end

    it "detects dockerfile from Dockerfile" do
      raise "expected dockerfile" unless Adamantine::LanguageRegistry.detect(Path.new("Dockerfile")) == "dockerfile"
    end

    it "detects ruby from Rakefile" do
      raise "expected ruby" unless Adamantine::LanguageRegistry.detect(Path.new("Rakefile")) == "ruby"
    end

    it "detects ruby from Gemfile" do
      raise "expected ruby" unless Adamantine::LanguageRegistry.detect(Path.new("Gemfile")) == "ruby"
    end

    # Additional extension variants
    it "detects typescript from .tsx" do
      raise "expected typescript" unless Adamantine::LanguageRegistry.detect(Path.new("App.tsx")) == "typescript"
    end

    it "detects javascript from .jsx" do
      raise "expected javascript" unless Adamantine::LanguageRegistry.detect(Path.new("App.jsx")) == "javascript"
    end

    it "detects bash from .bash" do
      raise "expected bash" unless Adamantine::LanguageRegistry.detect(Path.new("init.bash")) == "bash"
    end

    it "detects sql from .sql" do
      raise "expected sql" unless Adamantine::LanguageRegistry.detect(Path.new("schema.sql")) == "sql"
    end
  end

  describe "EXTENSION_MAP" do
    it "contains all extensions from LANGUAGES" do
      expected_count = Adamantine::LanguageRegistry::LANGUAGES.sum { |lang| lang.extensions.size }
      actual_count = Adamantine::LanguageRegistry::EXTENSION_MAP.size
      raise "extension map size #{actual_count} does not match expected #{expected_count}" unless actual_count == expected_count
    end
  end

  describe "LANGUAGES" do
    it "has unique extension mappings" do
      seen = Set(String).new
      Adamantine::LanguageRegistry::LANGUAGES.each do |lang|
        lang.extensions.each do |ext|
          raise "duplicate extension #{ext}" if seen.includes?(ext)
          seen << ext
        end
      end
    end
  end
end
