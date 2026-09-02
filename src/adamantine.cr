require "crystal_tui"

require "./adamantine/app"

project_root = Path.new(Dir.current)
lsp_command : String? = nil
lsp_args = [] of String
keymap_path : String? = nil
theme_path : String? = nil

# Parse arguments:
#  adamantine [path] [--lsp COMMAND | --no-lsp] [--lsp-arg ARG] [--config PATH] [--theme PATH]
args = ARGV.dup
path_arg : String? = nil

cli_error = ->(message : String) do
  STDERR.puts "adamantine: #{message}"
  STDERR.puts "Try 'adamantine --help' for usage."
  exit 2
end

index = 0
while index < args.size
  arg = args[index]

  case arg
  when "-h", "--help"
    puts <<-USAGE
      Usage: adamantine [path] [--lsp COMMAND | --no-lsp] [--lsp-arg ARG] [--config PATH] [--theme PATH]

      Path defaults to current directory.
      Use --lsp to run an external LSP server (e.g. "crystalline").
      Use --no-lsp to disable language-server discovery.
      You can also set ADAMANTINE_LSP or EDITOR_LSP in the environment.
      Without --lsp, it discovers compatible language servers from PATH only.
      Use --config to set a JSON keymap file.
      Use --theme to load a JSON theme file or built-in preset (vscode, vscode-dark, vs-dark, vscode-light, vs-light, vscode-high-contrast, dark, light, hc, high-contrast).

      Examples:
        adamantine .
        adamantine /tmp/project --lsp crystalline
        adamantine . --lsp crystal-tool-lsp --lsp-arg --stdio
        adamantine . --config ~/.config/adamantine/config.json
        adamantine . --theme ~/.config/adamantine/theme.json
        adamantine . --theme vscode-light
        adamantine . --theme vscode-high-contrast
    USAGE
    exit 0
  when "--lsp"
    cli_error.call("--lsp expects a command value") if index + 1 >= args.size
    lsp_command = args[index + 1]
    index += 1
  when "--no-lsp"
    lsp_command = ""
  when "--lsp-arg"
    cli_error.call("--lsp-arg expects an argument value") if index + 1 >= args.size
    lsp_args << args[index + 1]
    index += 1
  when "--config"
    cli_error.call("--config expects a path value") if index + 1 >= args.size
    keymap_path = args[index + 1]
    index += 1
  when "--theme"
    cli_error.call("--theme expects a path value") if index + 1 >= args.size
    theme_path = args[index + 1]
    index += 1
  when "--"
    index += 1
    cli_error.call("-- accepts at most one project path") if index < args.size - 1
    path_arg = args[index] if index < args.size
    break
  else
    cli_error.call("unknown option: #{arg}") if arg.starts_with?('-')
    cli_error.call("multiple project paths are not supported") if path_arg
    path_arg = arg
  end

  index += 1
end

if root = path_arg
  parsed = Path.new(root)
  cli_error.call("project root does not exist or is not a directory: #{parsed}") unless File.directory?(parsed.to_s)
  project_root = parsed
end

Adamantine::App.new(
  project_root: project_root,
  lsp_command: lsp_command,
  lsp_args: lsp_args,
  keymap_path: keymap_path,
  theme_path: theme_path
).run
