require "spec"
require "../src/adamantine/snippet_parser"
require "../src/adamantine/template_catalog"

describe Adamantine::TemplateCatalog do
  it "offers bounded Crystal and Adamas templates with unique explicit triggers" do
    %w(crystal adamas).each do |language_id|
      templates = Adamantine::TemplateCatalog.for_language(language_id)

      templates.map(&.trigger).should eq(["def", "class", "if"])
      templates.map(&.trigger).uniq.size.should eq(templates.size)
      templates.each do |template|
        template.languages.should contain(language_id)
        template.label.should_not be_empty
        template.description.should_not be_empty
      end
    end

    Adamantine::TemplateCatalog.for_language("plaintext").should be_empty
    Adamantine::TemplateCatalog.find("crystal", "missing").should be_nil
  end

  it "parses every small built-in body with the editor's bounded snippet subset" do
    Adamantine::TemplateCatalog.all.each do |template|
      template.body.bytesize.should be < 256
      template.parsed.text.should contain("end")
      template.parsed.explicit_final_stop?.should be_true
      template.parsed.tabstops.map(&.index).should contain(0)
    end
  end

  it "finds templates by exact language and trigger" do
    method = Adamantine::TemplateCatalog.find("adamas", "def").not_nil!

    method.label.should eq("Method")
    method.description.should contain("method")
    method.body.should start_with("def ")
  end

  it "keeps callers from mutating the catalog through returned collections" do
    Adamantine::TemplateCatalog.all.clear

    method = Adamantine::TemplateCatalog.find("crystal", "def").not_nil!
    method.languages.clear
    method.parsed.tabstops.clear

    method.supports_language?("crystal").should be_true
    method.parsed.tabstops.should_not be_empty
    Adamantine::TemplateCatalog.for_language("crystal").size.should eq(3)
  end

  it "treats an empty language list as a generic template" do
    template = Adamantine::TemplateCatalog::Template.new(
      "todo",
      "TODO: $0",
      "TODO",
      "Generic reminder",
      [] of String,
    )

    template.languages.should be_empty
    template.supports_language?("crystal").should be_true
    template.supports_language?("rust").should be_true
  end
end
