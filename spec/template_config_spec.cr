require "spec"
require "file_utils"
require "../src/adamantine/template_config"

private def with_template_config_files(&)
  root = Path.new(Dir.tempdir, "adamantine-template-config-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def write_template_config(path : Path, templates : Array(Hash(String, JSON::Any)))
  File.write(path, JSON.parse({
    "version"   => 1,
    "templates" => templates,
  }.to_json).to_json)
end

private def template_config_entry(
  trigger : String,
  body : String,
  label : String? = nil,
  description : String? = nil,
  languages : Array(String)? = nil,
) : Hash(String, JSON::Any)
  entry = {
    "trigger" => JSON::Any.new(trigger),
    "body"    => JSON::Any.new(body),
  }
  entry["label"] = JSON::Any.new(label) if label
  entry["description"] = JSON::Any.new(description) if description
  if languages
    entry["languages"] = JSON::Any.new(languages.map { |language| JSON::Any.new(language) })
  end
  entry
end

describe Adamantine::TemplateConfig do
  it "loads valid bounded snippets from user and project files with project trigger precedence" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      project_path = root / ".adamantine" / "templates.json"
      Dir.mkdir_p(project_path.parent)
      write_template_config(user_path, [
        template_config_entry("fn", "function ${1:name}() {\n  $0\n}", "Function", languages: ["crystal", "rust"]),
        template_config_entry("todo", "TODO: $0"),
      ])
      write_template_config(project_path, [
        template_config_entry("fn", "def ${1:name}\n  $0\nend", "Crystal method", "Project override", ["crystal"]),
      ])
      before_user = File.read(user_path)
      before_project = File.read(project_path)

      result = Adamantine::TemplateConfig.load(user_path.to_s, project_path.to_s)

      result.diagnostics.should be_empty
      result.entries.map(&.trigger).should eq(["fn", "fn", "todo"])
      result.entries[0].body.should eq("def ${1:name}\n  $0\nend")
      result.entries[0].parsed.text.should eq("def name\n  \nend")
      result.entries[0].label.should eq("Crystal method")
      result.entries[0].description.should eq("Project override")
      result.entries[0].languages.should eq(["crystal"])
      result.entries[1].body.should eq("function ${1:name}() {\n  $0\n}")
      result.entries[1].languages.should eq(["rust"])
      result.entries[2].body.should eq("TODO: $0")
      result.entries[2].parsed.text.should eq("TODO: ")
      result.entries[2].label.should eq("todo")
      result.entries[2].description.should eq("")
      result.entries[2].languages.should be_empty
      result.for_language("CRYSTAL").map(&.body).should eq(["def ${1:name}\n  $0\nend", "TODO: $0"])
      result.for_language("rust").map(&.body).should eq(["function ${1:name}() {\n  $0\n}", "TODO: $0"])
      File.read(user_path).should eq(before_user)
      File.read(project_path).should eq(before_project)
    end
  end

  it "keeps an all-language user template as fallback under a project language override" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      project_path = root / "project.json"
      write_template_config(user_path, [template_config_entry("fn", "user $0")])
      write_template_config(project_path, [template_config_entry("fn", "project $0", languages: ["crystal"])])

      result = Adamantine::TemplateConfig.load(user_path.to_s, project_path.to_s)

      result.for_language("crystal").map(&.body).should eq(["project $0"])
      result.for_language("rust").map(&.body).should eq(["user $0"])
    end
  end

  it "skips malformed entries and later duplicate triggers with source-scoped diagnostics" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      project_path = root / "project.json"
      write_template_config(user_path, [
        template_config_entry("ok", "hello $0"),
        template_config_entry("bad trigger", "body $0"),
        template_config_entry("unsupported", "$TM_FILENAME"),
        template_config_entry("ok", "duplicate $0"),
      ])
      write_template_config(project_path, [
        template_config_entry("project", "project $0"),
      ])

      result = Adamantine::TemplateConfig.load(user_path.to_s, project_path.to_s)

      result.entries.map(&.trigger).should eq(["project", "ok"])
      result.diagnostics.size.should eq(3)
      result.diagnostics.map(&.path).should eq([user_path.to_s, user_path.to_s, user_path.to_s])
      result.diagnostics[0].message.should contain("trigger")
      result.diagnostics[1].message.should contain("snippet")
      result.diagnostics[2].message.should contain("duplicate")
    end
  end

  it "allows disjoint language definitions but rejects overlapping duplicates" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      write_template_config(user_path, [
        template_config_entry("fmt", "crystal $0", languages: ["crystal"]),
        template_config_entry("fmt", "rust $0", languages: ["rust"]),
        template_config_entry("fmt", "duplicate $0", languages: ["CRYSTAL"]),
      ])

      result = Adamantine::TemplateConfig.load(user_path.to_s)

      result.diagnostics.size.should eq(1)
      result.diagnostics[0].message.should contain("overlapping language scope")
      result.for_language("crystal").map(&.body).should eq(["crystal $0"])
      result.for_language("rust").map(&.body).should eq(["rust $0"])
    end
  end

  it "rejects carriage returns so parsed offsets match normalized editor text" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      write_template_config(user_path, [template_config_entry("crlf", "first\r\nsecond$0")])

      result = Adamantine::TemplateConfig.load(user_path.to_s)

      result.entries.should be_empty
      result.diagnostics.size.should eq(1)
      result.diagnostics[0].message.should contain("carriage return")
    end
  end

  it "rejects terminal control characters in inserted body text" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      write_template_config(user_path, [
        template_config_entry("esc", "hello \u001b[31m$0"),
        template_config_entry("c1", "hello \u009b[31m$0"),
      ])

      result = Adamantine::TemplateConfig.load(user_path.to_s)

      result.entries.should be_empty
      result.diagnostics.size.should eq(2)
      result.diagnostics[0].message.should contain("control character")
    end
  end

  it "rejects terminal control characters in picker labels and descriptions" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      write_template_config(user_path, [
        template_config_entry("badlabel", "body $0", label: "bad\u001b[31m"),
        template_config_entry("baddescription", "body $0", description: "bad\u0007"),
        template_config_entry("c1label", "body $0", label: "bad\u009b[31m"),
      ])

      result = Adamantine::TemplateConfig.load(user_path.to_s)

      result.entries.should be_empty
      result.diagnostics.size.should eq(3)
      result.diagnostics.map(&.message).join(" ").should contain("control character")
    end
  end

  it "rejects a source with more templates than its configured count bound" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      templates = (0..Adamantine::TemplateConfig::MAX_TEMPLATES).map do |index|
        template_config_entry("t#{index}", "body $0")
      end
      write_template_config(user_path, templates)

      result = Adamantine::TemplateConfig.load(user_path.to_s)

      result.entries.should be_empty
      result.diagnostics.size.should eq(1)
      result.diagnostics[0].message.should contain("count exceeds")
    end
  end

  it "rejects JSON nesting beyond its parser depth bound" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      depth = Adamantine::TemplateConfig::MAX_JSON_DEPTH + 1
      File.write(user_path, ("[" * depth) + "0" + ("]" * depth))

      result = Adamantine::TemplateConfig.load(user_path.to_s)

      result.entries.should be_empty
      result.diagnostics.size.should eq(1)
      result.diagnostics[0].message.should contain("nesting depth")
    end
  end

  it "fails closed for invalid roots and oversized files while retaining the other source" do
    with_template_config_files do |root|
      user_path = root / "user.json"
      project_path = root / "project.json"
      File.write(user_path, %({"version":2,"templates":[]}))
      File.write(project_path, "x" * (Adamantine::TemplateConfig::MAX_FILE_BYTES + 1))

      result = Adamantine::TemplateConfig.load(user_path.to_s, project_path.to_s)

      result.entries.should be_empty
      result.diagnostics.size.should eq(2)
      result.diagnostics.map(&.path).should eq([user_path.to_s, project_path.to_s])
      result.diagnostics[0].message.should contain("version")
      result.diagnostics[1].message.should contain("exceeds")
    end
  end

  it "treats missing optional files as empty and exposes conventional paths" do
    with_template_config_files do |root|
      result = Adamantine::TemplateConfig.load((root / "missing-user.json").to_s, (root / "missing-project.json").to_s)

      result.entries.should be_empty
      result.diagnostics.should be_empty
    end

    Adamantine::TemplateConfig.user_path("/home/alice").should eq("/home/alice/.config/adamantine/templates.json")
    Adamantine::TemplateConfig.project_path("/repo").should eq("/repo/.adamantine/templates.json")
    Adamantine::TemplateConfig.user_path(nil).should be_nil
    Adamantine::TemplateConfig.project_path(nil).should be_nil
  end
end
