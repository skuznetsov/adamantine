module Adamantine
  module LspRegistry
    LANGUAGE_SERVERS = {
      "crystal"    => ["adamas_lsp", "crystalline", "crystal-lsp"],
      "ruby"       => ["solargraph", "ruby-lsp"],
      "python"     => ["pyright", "pylsp"],
      "typescript" => ["typescript-language-server"],
      "javascript" => ["typescript-language-server"],
      "go"         => ["gopls"],
      "rust"       => ["rust-analyzer"],
      "c"          => ["clangd"],
      "cpp"        => ["clangd"],
      "java"       => ["jdtls"],
      "kotlin"     => ["kotlin-language-server"],
      "swift"      => ["sourcekit-lsp"],
      "lua"        => ["lua-language-server"],
      "elixir"     => ["elixir-ls", "lexical"],
      "haskell"    => ["haskell-language-server"],
      "ocaml"      => ["ocamllsp"],
      "zig"        => ["zls"],
      "nim"        => ["nimlangserver"],
      "csharp"     => ["omnisharp", "csharp-ls"],
      "bash"       => ["bash-language-server"],
      "yaml"       => ["yaml-language-server"],
      "scala"      => ["metals"],
      "dart"       => ["dart"],
    }

    PROJECT_MARKERS = {
      "shard.yml"        => "crystal",
      "Gemfile"          => "ruby",
      "Cargo.toml"       => "rust",
      "go.mod"           => "go",
      "package.json"     => "typescript",
      "pyproject.toml"   => "python",
      "setup.py"         => "python",
      "requirements.txt" => "python",
      "pom.xml"          => "java",
      "build.gradle"     => "java",
      "build.gradle.kts" => "kotlin",
      "Package.swift"    => "swift",
      "mix.exs"          => "elixir",
      "stack.yaml"       => "haskell",
      "dune-project"     => "ocaml",
      "pubspec.yaml"     => "dart",
      "build.zig"        => "zig",
    }

    def self.detect_project_language(root : Path) : String?
      PROJECT_MARKERS.each do |file, lang|
        return lang if File.exists?((root / file).to_s)
      end
      nil
    end

    # Resolve the bundled Adamas server only when it is explicitly exposed on
    # PATH. Project trees and their ancestors are untrusted input; walking
    # them for executable files would turn merely opening a project into code
    # execution.
    def self.find_adamas_lsp(_project_root : Path, _cwd : Path = Path.new(Dir.current)) : String?
      which("adamas_lsp")
    end

    def self.executable?(path : String) : Bool
      info = File.info(path)
      info.file? && File::Info.executable?(path)
    rescue File::NotFoundError | File::AccessDeniedError | IO::Error
      false
    end

    def self.find_lsp_for_language(language_id : String) : String?
      binaries = LANGUAGE_SERVERS[language_id]?
      return nil unless binaries

      binaries.each do |name|
        path = which(name)
        return path if path
      end

      nil
    end

    def self.which(name : String) : String?
      return nil if name.empty?

      ENV["PATH"]?.try do |path_var|
        path_var.split(Process::PATH_DELIMITER).each do |dir|
          candidate = Path.new(dir, name)
          begin
            if File.file?(candidate.to_s) && File::Info.executable?(candidate.to_s)
              return candidate.to_s
            end
          rescue
            next
          end
        end
      end

      nil
    end
  end
end
