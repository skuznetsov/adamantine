module Adamantine
  module TemplateCatalog
    struct Template
      getter trigger : String
      getter body : String
      getter label : String
      getter description : String
      @parsed : Snippet::ParseResult
      @languages : Array(String)

      def initialize(
        @trigger : String,
        @body : String,
        @label : String,
        @description : String,
        languages : Array(String),
      )
        outcome = Snippet::Parser.parse(@body)
        parsed = outcome.result || raise "invalid template body for '#{@trigger}': #{outcome.error}"
        initialize(@trigger, @body, parsed, @label, @description, languages)
      end

      def initialize(
        @trigger : String,
        @body : String,
        parsed : Snippet::ParseResult,
        @label : String,
        @description : String,
        languages : Array(String),
      )
        @parsed = Snippet::ParseResult.new(parsed.text, parsed.tabstops.dup, parsed.explicit_final_stop?)
        @languages = languages.dup
      end

      def parsed : Snippet::ParseResult
        Snippet::ParseResult.new(@parsed.text, @parsed.tabstops.dup, @parsed.explicit_final_stop?)
      end

      def languages : Array(String)
        @languages.dup
      end

      def supports_language?(language_id : String) : Bool
        @languages.empty? || @languages.includes?(language_id)
      end
    end

    private def self.build_template(
      trigger : String,
      body : String,
      label : String,
      description : String,
    ) : Template
      Template.new(trigger, body, label, description, ["crystal", "adamas"] of String)
    end

    # These templates are plain editor data. Their bodies are parsed by the
    # bounded snippet parser and are never evaluated as code by the catalog.
    private TEMPLATES = [
      build_template(
        "def",
        "def ${1:name}(${2:args})\n  $0\nend",
        "Method",
        "Define a method with placeholders for its name and arguments.",
      ),
      build_template(
        "class",
        "class ${1:ClassName}\n  $0\nend",
        "Class",
        "Define a class with an editable name and body.",
      ),
      build_template(
        "if",
        "if ${1:condition}\n  $0\nend",
        "If statement",
        "Add a conditional block with an editable condition and body.",
      ),
    ] of Template

    def self.builtins : Array(Template)
      TEMPLATES.dup
    end

    def self.all : Array(Template)
      builtins
    end

    def self.for_language(language_id : String) : Array(Template)
      TEMPLATES.select(&.supports_language?(language_id))
    end

    def self.find(language_id : String, trigger : String) : Template?
      TEMPLATES.find do |template|
        template.supports_language?(language_id) && template.trigger == trigger
      end
    end
  end
end
