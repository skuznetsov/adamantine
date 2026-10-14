require "json"
require "set"
require "c/dlfcn"
require "c/stdlib"

require "./editor_tools"
require "./lua_script_runtime"

module Adamantine
  module LuaScripts
    module Worker
      LUA_OK                =  0
      LUA_YIELD             =  1
      LUA_MULTRET           = -1
      DEFAULT_HEAP_BYTES    = 8 * 1024 * 1024
      MAX_SOURCE_BYTES      = 64 * 1024
      MAX_START_FRAME_BYTES = 640 * 1024
      # Output payloads are JSON-escaped and can expand up to sixfold.
      MAX_PROTOCOL_FRAME_BYTES = 128 * 1024
      MAX_REPLY_FRAME_BYTES    = 512 * 1024
      MAX_CONTEXT_BYTES        = 32 * 1024
      MAX_OUTPUT_BYTES         = 16 * 1024
      MAX_OUTPUT_EVENTS        = 64

      private alias LuaAllocator = Proc(Pointer(Void), Pointer(Void), LibC::SizeT, LibC::SizeT, Pointer(Void))
      # A nested Proc argument expands to Crystal's {function, closure_data}
      # pair when passed through a dynamic Proc call. lua_newstate expects one
      # raw C function pointer, so pass that pointer explicitly instead.
      private alias LuaNewState = Proc(Pointer(Void), Pointer(Void), Pointer(Void))
      private alias LuaOpenLibs = Proc(Pointer(Void), Nil)
      private alias LuaLoadBuffer = Proc(Pointer(Void), Pointer(UInt8), LibC::SizeT, Pointer(UInt8), Pointer(UInt8), Int32)
      private alias LuaPCall = Proc(Pointer(Void), Int32, Int32, Int32, Int64, Pointer(Void), Int32)
      private alias LuaResume = Proc(Pointer(Void), Pointer(Void), Int32, Pointer(Int32), Int32)
      private alias LuaPushString = Proc(Pointer(Void), Pointer(UInt8), LibC::SizeT, Pointer(UInt8))
      private alias LuaToString = Proc(Pointer(Void), Int32, Pointer(LibC::SizeT), Pointer(UInt8))
      private alias LuaToThread = Proc(Pointer(Void), Int32, Pointer(Void))
      private alias LuaSetTop = Proc(Pointer(Void), Int32, Nil)
      private alias LuaToBoolean = Proc(Pointer(Void), Int32, Int32)
      private alias LuaClose = Proc(Pointer(Void), Nil)
      private alias LuaVersion = Proc(Pointer(Void), Float64)

      private struct AllocatorState
        property used : LibC::SizeT
        property limit : LibC::SizeT
        property tripped : Bool

        def initialize(@limit : LibC::SizeT)
          @used = 0
          @tripped = false
        end
      end

      private struct Api
        getter handle : Void*
        getter newstate : LuaNewState
        getter openlibs : LuaOpenLibs
        getter loadbuffer : LuaLoadBuffer
        getter pcall : LuaPCall
        getter resume : LuaResume
        getter pushstring : LuaPushString
        getter tostring : LuaToString
        getter tothread : LuaToThread
        getter settop : LuaSetTop
        getter toboolean : LuaToBoolean
        getter close : LuaClose

        def initialize(@handle : Void*, @newstate : LuaNewState, @openlibs : LuaOpenLibs,
                       @loadbuffer : LuaLoadBuffer, @pcall : LuaPCall, @resume : LuaResume,
                       @pushstring : LuaPushString, @tostring : LuaToString,
                       @tothread : LuaToThread, @settop : LuaSetTop,
                       @toboolean : LuaToBoolean, @close : LuaClose)
        end

        def self.open(path : String) : Api
          unless Path.new(path).absolute? && File.file?(path)
            raise RuntimeError.new("lua_library_unavailable")
          end
          handle = LibC.dlopen(path.to_unsafe, LibC::RTLD_NOW | LibC::RTLD_LOCAL)
          raise RuntimeError.new("lua_library_unavailable") if handle.null?
          begin
            # lua_version changed return type after 5.3. Check for an API
            # symbol first so we never call a 5.1/5.3 function with the 5.4
            # ABI. Lua 5.5 keeps this ABI, then fails the numeric version check.
            preflight = LibC.dlsym(handle, "lua_newuserdatauv".to_unsafe)
            raise RuntimeError.new("lua_incompatible") if preflight.null?
            version_proc = symbol(LuaVersion, handle, "lua_version")
            version = version_proc.call(Pointer(Void).null)
            unless version == 504.0
              raise RuntimeError.new("lua_incompatible")
            end
            new(
              handle,
              symbol(LuaNewState, handle, "lua_newstate"),
              symbol(LuaOpenLibs, handle, "luaL_openlibs"),
              symbol(LuaLoadBuffer, handle, "luaL_loadbufferx"),
              symbol(LuaPCall, handle, "lua_pcallk"),
              symbol(LuaResume, handle, "lua_resume"),
              symbol(LuaPushString, handle, "lua_pushlstring"),
              symbol(LuaToString, handle, "lua_tolstring"),
              symbol(LuaToThread, handle, "lua_tothread"),
              symbol(LuaSetTop, handle, "lua_settop"),
              symbol(LuaToBoolean, handle, "lua_toboolean"),
              symbol(LuaClose, handle, "lua_close")
            )
          rescue ex
            LibC.dlclose(handle)
            raise ex
          end
        end

        def close_library : Nil
          LibC.dlclose(@handle)
        end

        private def self.symbol(type : T.class, handle : Void*, name : String) : T forall T
          pointer = LibC.dlsym(handle, name.to_unsafe)
          raise RuntimeError.new("Lua 5.4 library is missing a required ABI symbol") if pointer.null?
          T.new(pointer, Pointer(Void).null)
        end
      end

      def self.run(input : IO, output : IO, error : IO) : Int32
        state : Pointer(Void)? = nil
        api : Api? = nil
        allocator = AllocatorState.new(DEFAULT_HEAP_BYTES.to_u64)
        emitted_failure = false
        begin
          startup_line = bounded_line(input, MAX_START_FRAME_BYTES)
          startup = EditorTools.parse_bounded_json(startup_line).as_h?
          raise RuntimeError.new("invalid_start") unless startup
          exact_keys!(startup, %w[kind version script_id source context limits])
          raise RuntimeError.new("invalid_start") unless startup["kind"]?.try(&.as_s?) == "start"
          raise RuntimeError.new("invalid_start") unless startup["version"]?.try(&.as_i?) == 1
          script_id = startup["script_id"]?.try(&.as_s?)
          source = startup["source"]?.try(&.as_s?)
          context = startup["context"]?
          limits = startup["limits"]?.try(&.as_h?)
          raise RuntimeError.new("invalid_start") unless script_id && script_id.bytesize.in?(1..64)
          raise RuntimeError.new("invalid_start") unless source && source.valid_encoding? && source.bytesize <= MAX_SOURCE_BYTES
          raise RuntimeError.new("invalid_start") unless context && limits
          raise RuntimeError.new("invalid_start") unless context.to_json.bytesize <= MAX_CONTEXT_BYTES
          exact_keys!(limits, %w[lua_heap_bytes output_bytes output_events])
          heap_bytes = clamped_limit(limits, "lua_heap_bytes", DEFAULT_HEAP_BYTES, DEFAULT_HEAP_BYTES)
          output_bytes = clamped_limit(limits, "output_bytes", MAX_OUTPUT_BYTES, MAX_OUTPUT_BYTES)
          output_events = clamped_limit(limits, "output_events", MAX_OUTPUT_EVENTS, MAX_OUTPUT_EVENTS)

          library_path = ENV["ADAMANTINE_LUA_LIBRARY"]?
          raise RuntimeError.new("lua_unavailable") unless library_path && Path.new(library_path).absolute?
          api = Api.open(library_path)
          allocator.limit = heap_bytes.to_u64
          allocator_pointer = pointerof(allocator)
          allocator_proc = ->allocator_callback(Pointer(Void), Pointer(Void), LibC::SizeT, LibC::SizeT)
          state = api.not_nil!.newstate.call(allocator_proc.pointer, allocator_pointer.as(Void*))
          raise RuntimeError.new("lua_memory_limit") if state.null?
          api.not_nil!.openlibs.call(state)

          bootstrap = bootstrap_source
          status = api.not_nil!.loadbuffer.call(state, bootstrap.to_unsafe, bootstrap.bytesize.to_u64, "@adamantine-bootstrap".to_unsafe, "t".to_unsafe)
          raise RuntimeError.new("lua_bootstrap_failed") unless status == LUA_OK
          status = api.not_nil!.pcall.call(state, 0, 1, 0, 0_i64, Pointer(Void).null)
          raise RuntimeError.new("lua_bootstrap_failed") unless status == LUA_OK
          api.not_nil!.pushstring.call(state, source.to_unsafe, source.bytesize.to_u64)
          context_json = context.to_json
          api.not_nil!.pushstring.call(state, context_json.to_unsafe, context_json.bytesize.to_u64)
          status = api.not_nil!.pcall.call(state, 2, 1, 0, 0_i64, Pointer(Void).null)
          raise RuntimeError.new("lua_bootstrap_failed") unless status == LUA_OK
          coroutine = api.not_nil!.tothread.call(state, -1)
          raise RuntimeError.new("lua_bootstrap_failed") if coroutine.null?
          failure_code, failure_message = drive_coroutine(api.not_nil!, state, coroutine, allocator_pointer,
            input, output, output_bytes, output_events)
          api.not_nil!.close.call(state)
          state = nil
          if allocator.tripped
            failure_code = "memory_limit"
            failure_message = nil
          end
          if failure_code
            write_failure(output, failure_code, failure_message)
            emitted_failure = true
            1
          else
            write_frame(output, JSON.build { |json| json.object { json.field "kind", "complete" } })
            0
          end
        rescue ex
          code = if allocator.tripped
                   "memory_limit"
                 elsif ex.message == "lua_unavailable"
                   "lua_unavailable"
                 elsif ex.message == "lua_memory_limit"
                   "memory_limit"
                 elsif ex.message == "lua_library_unavailable"
                   "lua_library_unavailable"
                 elsif ex.message == "lua_incompatible"
                   "lua_incompatible"
                 elsif ex.message == "worker_protocol" || ex.message == "invalid_start"
                   "worker_protocol"
                 else
                   "worker_failed"
                 end
          begin
            api.try { |loaded| loaded.close.call(state.not_nil!) unless state.nil? || state.not_nil!.null? }
          rescue
          end
          state = nil
          code = "memory_limit" if allocator.tripped
          unless emitted_failure
            begin
              write_failure(output, code, nil)
            rescue
            end
          end
          1
        ensure
          api.try(&.close_library)
        end
      end

      private def self.drive_coroutine(api : Api, state : Void*, coroutine : Void*,
                                       allocator : AllocatorState*, input : IO, output : IO,
                                       output_byte_limit : Int32, output_event_limit : Int32) : {String?, String?}
        nresults = 0
        nargs = 0
        output_bytes = 0
        output_events = 0
        pending_id : String? = nil
        loop do
          status = api.resume.call(coroutine, state, nargs, pointerof(nresults))
          nargs = 0
          return {"memory_limit", nil} if allocator.value.tripped
          case status
          when LUA_YIELD
            yielded = stack_string(api, coroutine, -1)
            api.settop.call(coroutine, 0)
            frame = EditorTools.parse_bounded_json(yielded).as_h?
            raise RuntimeError.new("worker_protocol") unless frame
            kind = frame["kind"]?.try(&.as_s?)
            if kind == "output"
              exact_keys!(frame, %w[kind text])
              text = frame["text"]?.try(&.as_s?)
              raise RuntimeError.new("worker_protocol") unless text && text.valid_encoding?
              output_events += 1
              output_bytes += text.bytesize
              return {"output_limit", nil} if output_events > output_event_limit || output_bytes > output_byte_limit
              write_frame(output, yielded)
            elsif kind == "tool"
              exact_keys!(frame, %w[kind id name arguments])
              id = frame["id"]?.try(&.as_s?)
              name = frame["name"]?.try(&.as_s?)
              arguments = frame["arguments"]?.try(&.as_h?)
              raise RuntimeError.new("worker_protocol") unless id && name && arguments
              raise RuntimeError.new("worker_protocol") if pending_id
              write_frame(output, yielded)
              pending_id = id
              reply = EditorTools.parse_bounded_json(bounded_line(input, MAX_REPLY_FRAME_BYTES)).as_h?
              raise RuntimeError.new("worker_protocol") unless reply
              exact_keys!(reply, %w[kind id response])
              raise RuntimeError.new("worker_protocol") unless reply["kind"]?.try(&.as_s?) == "reply"
              raise RuntimeError.new("worker_protocol") unless reply["id"]?.try(&.as_s?) == pending_id
              response_json = reply["response"]?.try(&.as_s?)
              raise RuntimeError.new("worker_protocol") unless response_json && response_json.bytesize <= EditorTools::MAX_RESPONSE_BYTES
              EditorTools.parse_bounded_json(response_json)
              pending_id = nil
              api.pushstring.call(coroutine, response_json.to_unsafe, response_json.bytesize.to_u64)
              nargs = 1
            else
              raise RuntimeError.new("worker_protocol")
            end
          when LUA_OK
            if nresults > 0 && api.toboolean.call(coroutine, -nresults) == 0
              message = if nresults > 1
                          raw_message = stack_string(api, coroutine, -1)
                          raw_message = "@#{raw_message}" if raw_message.starts_with?("named-script:")
                          sanitize_diagnostic(raw_message)
                        end
              return {"script_error", message}
            end
            return {nil, nil}
          else
            return allocator.value.tripped ? {"memory_limit", nil} : {"script_error", nil}
          end
        end
      rescue
        {"worker_protocol", nil}
      end

      private def self.stack_string(api : Api, state : Void*, index : Int32) : String
        length = 0_u64
        pointer = api.tostring.call(state, index, pointerof(length))
        raise RuntimeError.new("worker_protocol") if pointer.null? || length > MAX_PROTOCOL_FRAME_BYTES
        String.new(pointer, length.to_i)
      end

      private def self.bounded_line(input : IO, maximum : Int32) : String
        line = input.gets(maximum + 1, chomp: false)
        raise RuntimeError.new("worker_protocol") unless line && line.ends_with?('\n') && line.bytesize <= maximum
        line[0, line.bytesize - 1]
      end

      private def self.write_frame(output : IO, line : String) : Nil
        raise RuntimeError.new("worker_protocol") if line.bytesize > MAX_PROTOCOL_FRAME_BYTES
        output << line << '\n'
        output.flush
      end

      private def self.write_failure(output : IO, code : String, message : String?) : Nil
        frame = JSON.build do |json|
          json.object do
            json.field "kind", "failed"
            json.field "code", code
            json.field "message", message.not_nil! if message
          end
        end
        write_frame(output, frame)
      end

      private def self.sanitize_diagnostic(value : String) : String
        clean = String::Builder.new(512)
        value.scrub.each_char do |char|
          emitted = EditorTools.control_char?(char) ? Char::REPLACEMENT : char
          break if clean.bytesize + emitted.bytesize > 512
          clean << emitted
        end
        clean.to_s
      end

      private def self.exact_keys!(object : Hash(String, JSON::Any), allowed : Array(String)) : Nil
        raise RuntimeError.new("worker_protocol") unless object.keys.to_set == allowed.to_set
      end

      private def self.clamped_limit(object : Hash(String, JSON::Any), key : String,
                                     maximum : Int32, default : Int32) : Int32
        value = object[key]?.try(&.as_i?)
        value ? value.clamp(1, maximum) : default
      end

      # This callback only performs non-raising, noncapturing allocator bookkeeping
      # and libc allocation. It never invokes Lua or raises across the C ABI.
      private def self.allocator_callback(data : Void*, pointer : Void*,
                                          old_size : LibC::SizeT,
                                          new_size : LibC::SizeT) : Void*
        return Pointer(Void).null if data.null?
        state = data.as(AllocatorState*)
        if new_size == 0
          unless pointer.null?
            LibC.free(pointer)
            used = state.value.used
            state.value.used = old_size > used ? 0_u64 : used - old_size
          end
          return Pointer(Void).null
        end

        used = state.value.used
        previous = pointer.null? ? 0_u64 : old_size
        retained = previous > used ? 0_u64 : used - previous
        if new_size > state.value.limit || retained > state.value.limit - new_size
          state.value.tripped = true
          return Pointer(Void).null
        end
        allocation = LibC.realloc(pointer, new_size)
        if allocation.null?
          state.value.tripped = true
          return Pointer(Void).null
        end
        state.value.used = retained + new_size
        allocation
      end

      private def self.bootstrap_source : String
        <<-LUA
          local coroutine_yield = coroutine.yield
          local base_assert, base_error = assert, error
          local base_ipairs, base_pairs, base_next = ipairs, pairs, next
          local base_pcall, base_xpcall = pcall, xpcall
          local base_select, base_tonumber, base_tostring, base_type = select, tonumber, tostring, type
          local base_rawget, base_rawset, base_rawequal = rawget, rawset, rawequal
          local base_getmetatable, base_setmetatable = getmetatable, setmetatable
          local string_byte, string_char = string.byte, string.char
          local string_find, string_format, string_sub = string.find, string.format, string.sub
          local table_concat = table.concat
          local utf8_char = utf8.char

          local function quote(value)
            local out = {'"'}
            for index = 1, #value do
              local byte = string_byte(value, index)
              if byte == 34 then out[#out + 1] = string_char(92, 34)
              elseif byte == 92 then out[#out + 1] = string_char(92, 92)
              elseif byte == 8 then out[#out + 1] = string_char(92, 98)
              elseif byte == 9 then out[#out + 1] = string_char(92, 116)
              elseif byte == 10 then out[#out + 1] = string_char(92, 110)
              elseif byte == 12 then out[#out + 1] = string_char(92, 102)
              elseif byte == 13 then out[#out + 1] = string_char(92, 114)
              elseif byte < 32 then out[#out + 1] = string_char(92) .. string_format('u%04x', byte)
              else out[#out + 1] = string_sub(value, index, index) end
            end
            out[#out + 1] = '"'
            return table_concat(out)
          end

          local function encode(value, seen, depth)
            if depth > 16 then base_error("JSON nesting is too deep") end
            local kind = base_type(value)
            if kind == "nil" then return "null"
            elseif kind == "boolean" then return value and "true" or "false"
            elseif kind == "number" then
              if value ~= value or value == math.huge or value == -math.huge then base_error("non-finite JSON number") end
              return string_format("%.17g", value)
            elseif kind == "string" then return quote(value)
            elseif kind ~= "table" then base_error("tool arguments must contain JSON values") end
            if seen[value] then base_error("cyclic tool arguments") end
            seen[value] = true
            local count, max_index, array = 0, 0, true
            for key in base_next, value do
              count = count + 1
              if base_type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false
              elseif key > max_index then max_index = key end
            end
            local out = {}
            if count == 0 then
              seen[value] = nil
              return "{}"
            elseif array and max_index == count then
              for index = 1, max_index do
                if index > 1 then out[#out + 1] = "," end
                out[#out + 1] = encode(value[index], seen, depth + 1)
              end
              seen[value] = nil
              return "[" .. table_concat(out) .. "]"
            end
            for key, item in base_next, value do
              if base_type(key) ~= "string" then base_error("tool argument object keys must be strings") end
              out[#out + 1] = quote(key) .. ":" .. encode(item, seen, depth + 1)
            end
            seen[value] = nil
            return "{" .. table_concat(out, ",") .. "}"
          end

          local function decode(source)
            local position, length = 1, #source
            local function whitespace()
              while position <= length do
                local byte = string_byte(source, position)
                if byte == 32 or byte == 9 or byte == 10 or byte == 13 then position = position + 1 else break end
              end
            end
            local parse
            local function parse_string()
              if string_byte(source, position) ~= 34 then base_error("expected JSON string") end
              position = position + 1
              local out, start = {}, position
              while position <= length do
                local byte = string_byte(source, position)
                if byte == 34 then
                  out[#out + 1] = string_sub(source, start, position - 1)
                  position = position + 1
                  return table_concat(out)
                elseif byte == 92 then
                  out[#out + 1] = string_sub(source, start, position - 1)
                  position = position + 1
                  local escape = string_sub(source, position, position)
                  local slash = string_char(92)
                  local simple = {[string_char(34)]=string_char(34), [slash]=slash, [string_char(47)]=string_char(47), b=string_char(8), f=string_char(12), n=string_char(10), r=string_char(13), t=string_char(9)}
                  if simple[escape] then
                    out[#out + 1] = simple[escape]
                    position = position + 1
                  elseif escape == "u" then
                    local digits = string_sub(source, position + 1, position + 4)
                    local code = tonumber(digits, 16)
                    if not code then base_error("invalid JSON unicode escape") end
                    position = position + 5
                    if code >= 0xd800 and code <= 0xdbff and string_sub(source, position, position + 1) == slash .. "u" then
                      local low = tonumber(string_sub(source, position + 2, position + 5), 16)
                      if low and low >= 0xdc00 and low <= 0xdfff then
                        code = 0x10000 + (code - 0xd800) * 0x400 + (low - 0xdc00)
                        position = position + 6
                      end
                    end
                    out[#out + 1] = utf8_char(code)
                  else
                    base_error("invalid JSON escape")
                  end
                  start = position
                elseif byte < 32 then
                  base_error("control character in JSON string")
                else
                  position = position + 1
                end
              end
              base_error("unterminated JSON string")
            end
            parse = function(depth)
              if depth > 16 then base_error("JSON nesting is too deep") end
              whitespace()
              local byte = string_byte(source, position)
              if byte == 34 then return parse_string()
              elseif byte == 123 then
                position = position + 1
                local object = {}
                whitespace()
                if string_byte(source, position) == 125 then position = position + 1; return object end
                while true do
                  whitespace()
                  local key = parse_string()
                  whitespace()
                  if string_byte(source, position) ~= 58 then base_error("expected colon") end
                  position = position + 1
                  object[key] = parse(depth + 1)
                  whitespace()
                  local next_byte = string_byte(source, position)
                  if next_byte == 125 then position = position + 1; return object end
                  if next_byte ~= 44 then base_error("expected comma") end
                  position = position + 1
                end
              elseif byte == 91 then
                position = position + 1
                local array = {}
                whitespace()
                if string_byte(source, position) == 93 then position = position + 1; return array end
                while true do
                  array[#array + 1] = parse(depth + 1)
                  whitespace()
                  local next_byte = string_byte(source, position)
                  if next_byte == 93 then position = position + 1; return array end
                  if next_byte ~= 44 then base_error("expected comma") end
                  position = position + 1
                end
              elseif string_sub(source, position, position + 3) == "true" then position = position + 4; return true
              elseif string_sub(source, position, position + 4) == "false" then position = position + 5; return false
              elseif string_sub(source, position, position + 3) == "null" then position = position + 4; return nil
              else
                local token = string_sub(source, position):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
                local number = token and tonumber(token)
                if not number then base_error("invalid JSON value") end
                position = position + #token
                return number
              end
            end
            local result = parse(0)
            whitespace()
            if position <= length then base_error("trailing JSON data") end
            return result
          end

          local function start(source, context_json)
            local context = decode(context_json)
            local call_index = 0
            local editor = {context = context}
            editor.call = function(name, arguments)
              if base_type(name) ~= "string" then base_error("tool name must be a string") end
              call_index = call_index + 1
              local request = encode({kind = "tool", id = base_tostring(call_index), name = name, arguments = arguments or {}}, {}, 0)
              local response_json = coroutine_yield(request)
              return decode(response_json)
            end
            local function script_print(...)
              local pieces = {}
              for index = 1, base_select("#", ...) do
                pieces[index] = base_tostring(base_select(index, ...))
              end
              coroutine_yield(encode({kind = "output", text = table_concat(pieces, string_char(9)) .. string_char(10)}, {}, 0))
            end
            local environment = {
              assert = base_assert, error = base_error,
              ipairs = base_ipairs, pairs = base_pairs, next = base_next,
              pcall = base_pcall, xpcall = base_xpcall,
              select = base_select, tonumber = base_tonumber, tostring = base_tostring, type = base_type,
              rawget = base_rawget, rawset = base_rawset, rawequal = base_rawequal,
              getmetatable = base_getmetatable, setmetatable = base_setmetatable,
              print = script_print, editor = editor,
              math = math, string = string, table = table, utf8 = utf8,
            }
            local chunk, compile_error = load(source, "@named-script", "t", environment)
            if not chunk then return false, compile_error end
            local ok, run_error = base_pcall(chunk)
            if not ok then return false, base_tostring(run_error) end
            return true
          end

          return function(source, context_json)
            return coroutine.create(function() return start(source, context_json) end)
          end
        LUA
      end
    end
  end
end
