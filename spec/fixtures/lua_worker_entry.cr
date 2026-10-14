require "../../src/adamantine/lua_script_runtime"
require "../../src/adamantine/lua_script_worker"

unless ARGV == ["--internal-lua-worker"]
  STDERR.puts "worker fixture requires the internal worker mode"
  exit 2
end

exit Adamantine::LuaScripts::Worker.run(STDIN, STDOUT, STDERR)
