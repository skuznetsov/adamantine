module Adamantine
  module LanguageRegistry
    struct LanguageInfo
      getter id : String
      getter name : String
      getter extensions : Array(String)

      def initialize(@id : String, @name : String, @extensions : Array(String))
      end
    end

    LANGUAGES = [
      LanguageInfo.new("crystal", "Crystal", [".cr"]),
      LanguageInfo.new("ruby", "Ruby", [".rb", ".rake", ".gemspec"]),
      LanguageInfo.new("python", "Python", [".py", ".pyi", ".pyw"]),
      LanguageInfo.new("typescript", "TypeScript", [".ts", ".tsx"]),
      LanguageInfo.new("javascript", "JavaScript", [".js", ".jsx", ".mjs", ".cjs"]),
      LanguageInfo.new("go", "Go", [".go"]),
      LanguageInfo.new("rust", "Rust", [".rs"]),
      LanguageInfo.new("c", "C", [".c", ".h"]),
      LanguageInfo.new("cpp", "C++", [".cpp", ".cc", ".cxx", ".hpp", ".hxx", ".hh"]),
      LanguageInfo.new("java", "Java", [".java"]),
      LanguageInfo.new("kotlin", "Kotlin", [".kt", ".kts"]),
      LanguageInfo.new("swift", "Swift", [".swift"]),
      LanguageInfo.new("php", "PHP", [".php"]),
      LanguageInfo.new("lua", "Lua", [".lua"]),
      LanguageInfo.new("perl", "Perl", [".pl", ".pm"]),
      LanguageInfo.new("r", "R", [".r", ".R"]),
      LanguageInfo.new("scala", "Scala", [".scala", ".sc"]),
      LanguageInfo.new("clojure", "Clojure", [".clj", ".cljs", ".cljc", ".edn"]),
      LanguageInfo.new("elixir", "Elixir", [".ex", ".exs"]),
      LanguageInfo.new("erlang", "Erlang", [".erl", ".hrl"]),
      LanguageInfo.new("haskell", "Haskell", [".hs", ".lhs"]),
      LanguageInfo.new("ocaml", "OCaml", [".ml", ".mli"]),
      LanguageInfo.new("dart", "Dart", [".dart"]),
      LanguageInfo.new("zig", "Zig", [".zig"]),
      LanguageInfo.new("nim", "Nim", [".nim", ".nims"]),
      LanguageInfo.new("v", "V", [".v", ".vsh"]),
      LanguageInfo.new("csharp", "C#", [".cs"]),
      LanguageInfo.new("fsharp", "F#", [".fs", ".fsi", ".fsx"]),
      LanguageInfo.new("json", "JSON", [".json", ".jsonc"]),
      LanguageInfo.new("markdown", "Markdown", [".md", ".mdx"]),
      LanguageInfo.new("yaml", "YAML", [".yml", ".yaml"]),
      LanguageInfo.new("toml", "TOML", [".toml"]),
      LanguageInfo.new("bash", "Bash", [".sh", ".bash", ".zsh"]),
      LanguageInfo.new("html", "HTML", [".html", ".htm"]),
      LanguageInfo.new("css", "CSS", [".css"]),
      LanguageInfo.new("scss", "SCSS", [".scss", ".sass"]),
      LanguageInfo.new("sql", "SQL", [".sql"]),
      LanguageInfo.new("xml", "XML", [".xml", ".xsl", ".xsd"]),
      LanguageInfo.new("dockerfile", "Dockerfile", [".dockerfile"]),
      LanguageInfo.new("protobuf", "Protocol Buffers", [".proto"]),
    ]

    EXTENSION_MAP = begin
      map = {} of String => String
      LANGUAGES.each do |lang|
        lang.extensions.each { |ext| map[ext] = lang.id }
      end
      map
    end

    FILENAME_MAP = {
      "Makefile"   => "makefile",
      "Dockerfile" => "dockerfile",
      "Rakefile"   => "ruby",
      "Gemfile"    => "ruby",
      "Justfile"   => "makefile",
    }

    def self.detect(path : Path) : String
      if lang = FILENAME_MAP[path.basename]?
        return lang
      end
      EXTENSION_MAP[path.extension]? || "plaintext"
    end
  end
end
