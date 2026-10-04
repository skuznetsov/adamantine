require "base64"

module Adamantine::Debugging
  # Source is embedded at Crystal compile time so launches never discover or
  # import arbitrary project files at runtime.
  PROVIDER_SOURCE = {{ read_file("#{__DIR__}/../../tools/lldb/adamantine_crystal.py") }}

  module DebugNativeValues
    def self.init_command : String
      encoded = Base64.strict_encode(PROVIDER_SOURCE)
      "!script import base64 as _adamantine_base64, sys as _adamantine_sys, types as _adamantine_types; adamantine_crystal = _adamantine_types.ModuleType(\"adamantine_crystal\"); adamantine_crystal.__dict__[\"__file__\"] = \"<adamantine bundled provider>\"; adamantine_crystal.__dict__[\"__package__\"] = None; _adamantine_sys.modules[\"adamantine_crystal\"] = adamantine_crystal; exec(compile(_adamantine_base64.b64decode(\"#{encoded}\").decode(\"utf-8\"), \"<adamantine bundled provider>\", \"exec\"), adamantine_crystal.__dict__); adamantine_crystal.register(lldb.debugger)"
    end
  end
end
