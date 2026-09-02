require "crystal_tui"

require "./editor/app"

project_root = Path.new(Dir.current)
lsp_command : String? = nil
lsp_args = [] of String
keymap_path : String? = nil
theme_path : String? = nil

# Parse arguments:
#  editor [path] [--lsp COMMAND | --no-lsp] [--lsp-arg ARG] [--config PATH] [--theme PATH]
args = ARGV.dup
path_arg : String? = nil
index = 0
while index < args.size
  arg = args[index]

  case arg
  when "-h", "--help"
    puts <<-USAGE
      Usage: editor [path] [--lsp COMMAND | --no-lsp] [--lsp-arg ARG] [--config PATH] [--theme PATH]

      Path defaults to current directory.
      Use --lsp to run an external LSP server (e.g. "crystalline").
      Use --no-lsp to disable language-server discovery.
      You can also set EDITOR_LSP or CRYSTAL_EDITOR_LSP in environment.
      Without --lsp, it tries ../crystal_lsp, ../crystal-lsp, ../crystal_v2_repo/bin/crystal_v2_lsp, or ../crystal.
      Use --config to set a JSON keymap file.
      Use --theme to load a JSON theme file or built-in preset (vscode, vscode-dark, vs-dark, vscode-light, vs-light, vscode-high-contrast, dark, light, hc, high-contrast).

      Examples:
        editor .
        editor /tmp/project --lsp crystalline
        editor . --lsp crystal-tool-lsp --lsp-arg --stdio
        editor . --config ~/.config/crystal_editor/config.json
        editor . --theme ~/.config/crystal_editor/theme.json
        editor . --theme vscode-light
        editor . --theme vscode-high-contrast
    USAGE
    exit 0
  when "--lsp"
    if index + 1 >= args.size
      raise "--lsp expects a command value"
    end
    lsp_command = args[index + 1]
    index += 1
  when "--no-lsp"
    lsp_command = ""
  when "--lsp-arg"
    if index + 1 >= args.size
      raise "--lsp-arg expects an argument value"
    end
    lsp_args << args[index + 1]
    index += 1
  when "--config"
    if index + 1 >= args.size
      raise "--config expects a path value"
    end
    keymap_path = args[index + 1]
    index += 1
  when "--theme"
    if index + 1 >= args.size
      raise "--theme expects a path value"
    end
    theme_path = args[index + 1]
    index += 1
  when "--"
    path_arg = nil
    # all subsequent args are ignored for now
    break
  else
    unless arg.starts_with?('-')
      path_arg = arg
    end
  end

  index += 1
end

if root = path_arg
  parsed = Path.new(root)
  raise "Project root path does not exist or is not a directory: #{parsed}" unless File.directory?(parsed.to_s)
  project_root = parsed
end

CrystalEditor::App.new(
  project_root: project_root,
  lsp_command: lsp_command,
  lsp_args: lsp_args,
  keymap_path: keymap_path,
  theme_path: theme_path
).run
