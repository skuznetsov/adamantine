module CrystalEditor
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

    def self.find_adamas_lsp(project_root : Path, cwd : Path = Path.new(Dir.current)) : String?
      which("adamas_lsp").try { |path| return path }

      search_roots = [
        cwd,
        project_root,
        cwd.parent,
        project_root.parent,
        cwd.parent.parent,
        project_root.parent.parent,
      ]

      if home = ENV["HOME"]?
        search_roots << Path.new(home) / "Projects" / "Adamas" / "adamas"
        search_roots << Path.new(home) / "Adamas" / "adamas"
      end

      search_roots.compact.uniq.each do |root|
        [
          root / "bin" / "adamas_lsp",
          root / "adamas" / "bin" / "adamas_lsp",
          root / "Adamas" / "adamas" / "bin" / "adamas_lsp",
        ].each do |candidate|
          return candidate.to_s if executable?(candidate.to_s)
        end
      end

      nil
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
