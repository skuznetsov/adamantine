require "json"
require "./semantic_tokens"
require "./folding"
require "./uri_codec"

module Adamantine
  module Lsp
    struct Diagnostic
      property line : Int32
      property character : Int32
      property end_line : Int32
      property end_character : Int32
      property message : String
      property source : String?
      property severity : Int32?

      def initialize(
        @line : Int32,
        @character : Int32,
        @message : String,
        @source : String? = nil,
        @severity : Int32? = nil,
        @end_line : Int32 = -1,
        @end_character : Int32 = -1,
      )
        @end_line = @line if @end_line < 0
        @end_character = @character if @end_character < 0
      end
    end

    struct Location
      property uri : String
      property line : Int32
      property character : Int32

      def initialize(@uri : String, @line : Int32, @character : Int32)
      end
    end

    struct Range
      property start_line : Int32
      property start_character : Int32
      property end_line : Int32
      property end_character : Int32

      def initialize(@start_line : Int32, @start_character : Int32, @end_line : Int32, @end_character : Int32)
      end
    end

    struct Hover
      property text : String
      property range : Range?

      def initialize(@text : String, @range : Range? = nil)
      end
    end

    struct CompletionItem
      property label : String
      property detail : String?
      property kind : Int32?
      property insert_text : String?
      property filter_text : String?

      def initialize(@label : String, @detail : String? = nil, @kind : Int32? = nil, @insert_text : String? = nil, @filter_text : String? = nil)
      end
    end

    struct SignatureHelp
      property signatures : Array(String)
      property active_signature : Int32
      property active_parameter : Int32

      def initialize(@signatures : Array(String), @active_signature : Int32 = 0, @active_parameter : Int32 = 0)
      end
    end

    class Client
      READ_TIMEOUT_SECONDS            =  8
      SEMANTIC_TOKENS_TIMEOUT_SECONDS = 15
      SHUTDOWN_TIMEOUT_SECONDS        =  1
      PROCESS_GRACE_PERIOD            = 250.milliseconds
      MAX_JSON_BUFFER                 = 4_194_304
      MAX_NOISE_LINES                 =       100
      MAX_LSP_HEADERS                 =        50

      property server_capabilities : JSON::Any?
      property on_diagnostics : Proc(String, Array(Diagnostic), Nil)? = nil
      property on_semantic_tokens_refresh : Proc(Nil)? = nil
      setter connected : Bool
      getter semantic_token_legend : Array(String) = SemanticTokens::STANDARD_LEGEND.dup

      @process : Process?
      @stdin : IO?
      @stdout : IO?
      @next_id : Int64 = 0
      @pending : Hash(String, Channel(JSON::Any | Exception))
      @pending_mutex : Mutex
      @request_mutex : Mutex
      @write_mutex : Mutex
      @stop_mutex : Mutex
      @reader : Fiber?
      @reader_done : Channel(Nil)?
      @root : Path
      @reader_running : Bool = false
      @connected : Bool = false
      @stopping : Bool = false

      def initialize(@command : String, root : Path, @args : Array(String) = [] of String)
        @root = root
        @pending = Hash(String, Channel(JSON::Any | Exception)).new
        @pending_mutex = Mutex.new
        @request_mutex = Mutex.new
        @write_mutex = Mutex.new
        @stop_mutex = Mutex.new
      end

      def start : Bool
        @stop_mutex.synchronize do
          return false if @command.empty?
          return true if connected?

          @process = Process.new(
            @command,
            @args,
            chdir: @root.to_s,
            input: Process::Redirect::Pipe,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Close
          )

          @stdin = @process.try(&.input)
          @stdout = @process.try(&.output)
          @connected = true
          @stopping = false

          start_reader
          initialize_session

          true
        end
      rescue
        stop
        false
      end

      def connected? : Bool
        @connected && !@stopping
      end

      def stop : Nil
        @stop_mutex.synchronize do
          @stopping = true
          begin
            process = @process

            # Existing callers must not keep waiting while the client is being
            # torn down. The shutdown request below gets its own pending slot.
            clear_pending(Exception.new("LSP stopped"))

            if process && @connected
              bounded_graceful_shutdown
            end

            @connected = false
            @reader_running = false
            close_transport

            if reader_done = @reader_done
              select
              when reader_done.receive
              when timeout(PROCESS_GRACE_PERIOD)
              end
            end

            stop_process(process) if process

            @process = nil
            @stdin = nil
            @stdout = nil
            @reader = nil
            @reader_done = nil
            clear_pending(Exception.new("LSP stopped"))
          ensure
            @stopping = false
          end
        end
      end

      def open_text_document(uri : String, language_id : String, version : Int32, text : String) : Nil
        return unless connected?
        params = {
          "textDocument" => {
            "uri"        => uri,
            "languageId" => language_id,
            "version"    => version,
            "text"       => text,
          },
        }
        send_notification("textDocument/didOpen", params)
      end

      def text_change(uri : String, version : Int32, text : String) : Nil
        return unless connected?
        params = {
          "textDocument" => {
            "uri"     => uri,
            "version" => version,
          },
          "contentChanges" => [
            {
              "text" => text,
            },
          ],
        }
        send_notification("textDocument/didChange", params)
      end

      def text_change(uri : String, version : Int32, range : Range, text : String) : Nil
        return unless connected?
        params = {
          "textDocument" => {
            "uri"     => uri,
            "version" => version,
          },
          "contentChanges" => [
            {
              "range" => {
                "start" => {
                  "line"      => range.start_line,
                  "character" => range.start_character,
                },
                "end" => {
                  "line"      => range.end_line,
                  "character" => range.end_character,
                },
              },
              "text" => text,
            },
          ],
        }
        send_notification("textDocument/didChange", params)
      end

      def save_text_document(uri : String) : Nil
        return unless connected?
        params = {
          "textDocument" => {
            "uri" => uri,
          },
        }
        send_notification("textDocument/didSave", params)
      end

      def close_text_document(uri : String) : Nil
        return unless connected?
        params = {
          "textDocument" => {
            "uri" => uri,
          },
        }
        send_notification("textDocument/didClose", params)
      end

      def goto_definition(uri : String, line : Int32, character : Int32) : Array(Location)
        return [] of Location unless connected?
        params = {
          "textDocument" => {
            "uri" => uri,
          },
          "position" => {
            "line"      => line,
            "character" => character,
          },
        }

        parse_locations(request("textDocument/definition", params))
      end

      def declaration(uri : String, line : Int32, character : Int32) : Array(Location)
        return [] of Location unless connected?

        parse_locations(
          request(
            "textDocument/declaration",
            text_document_position_params(uri, line, character)
          )
        )
      end

      def type_definition(uri : String, line : Int32, character : Int32) : Array(Location)
        return [] of Location unless connected?

        parse_locations(
          request(
            "textDocument/typeDefinition",
            text_document_position_params(uri, line, character)
          )
        )
      end

      def implementation(uri : String, line : Int32, character : Int32) : Array(Location)
        return [] of Location unless connected?

        parse_locations(
          request(
            "textDocument/implementation",
            text_document_position_params(uri, line, character)
          )
        )
      end

      def document_symbol(uri : String) : Array(JSON::Any)
        return [] of JSON::Any unless connected?
        request("textDocument/documentSymbol", {"textDocument" => {"uri" => uri}})
          .as_a?
          .try(&.dup) || [] of JSON::Any
      end

      def workspace_symbol(query : String) : Array(JSON::Any)
        return [] of JSON::Any unless connected?
        request("workspace/symbol", {"query" => query})
          .as_a?
          .try(&.dup) || [] of JSON::Any
      end

      def hover(uri : String, line : Int32, character : Int32) : Hover?
        return nil unless connected?

        params = {
          "textDocument" => {
            "uri" => uri,
          },
          "position" => {
            "line"      => line,
            "character" => character,
          },
        }

        parse_hover(request("textDocument/hover", params))
      end

      def completion(uri : String, line : Int32, character : Int32, max_items : Int32 = 30) : Array(CompletionItem)
        return [] of CompletionItem unless connected?

        params = {
          "textDocument" => {
            "uri" => uri,
          },
          "position" => {
            "line"      => line,
            "character" => character,
          },
        }

        items = parse_completion_items(request("textDocument/completion", params))
        items.first([items.size, max_items].min)
      end

      def signature_help(uri : String, line : Int32, character : Int32) : SignatureHelp?
        return nil unless connected?

        params = {
          "textDocument" => {
            "uri" => uri,
          },
          "position" => {
            "line"      => line,
            "character" => character,
          },
        }

        parse_signature_help(request("textDocument/signatureHelp", params))
      end

      def references(uri : String, line : Int32, character : Int32, include_declaration : Bool = true) : Array(Location)
        return [] of Location unless connected?

        parse_locations(
          request(
            "textDocument/references",
            {
              "textDocument" => {"uri" => uri},
              "position"     => {
                "line"      => line,
                "character" => character,
              },
              "context" => {
                "includeDeclaration" => include_declaration,
              },
            }
          )
        )
      end

      def document_highlight(uri : String, line : Int32, character : Int32) : Array(Location)
        return [] of Location unless connected?
        parse_locations(
          request(
            "textDocument/documentHighlight",
            text_document_position_params(uri, line, character)
          )
        )
      end

      def code_action(uri : String, line : Int32, character : Int32) : Array(JSON::Any)
        return [] of JSON::Any unless connected?

        params = text_document_position_params(uri, line, character)
        context_params = Hash(String, JSONValueLike).new
        context_params["diagnostics"] = [] of JSONValueLike
        context_params["only"] = [] of JSONValueLike
        params["context"] = context_params

        request("textDocument/codeAction", params)
          .as_a?
          .try(&.dup) || [] of JSON::Any
      end

      def formatting(uri : String) : Array(JSON::Any)
        return [] of JSON::Any unless connected?
        request(
          "textDocument/formatting",
          {
            "textDocument" => {"uri" => uri},
            "options"      => {
              "tabSize"      => 2,
              "insertSpaces" => true,
            },
          }
        ).as_a?
          .try(&.dup) || [] of JSON::Any
      end

      def range_formatting(uri : String, start_line : Int32, start_character : Int32, end_line : Int32, end_character : Int32) : Array(JSON::Any)
        return [] of JSON::Any unless connected?

        request(
          "textDocument/rangeFormatting",
          {
            "textDocument" => {"uri" => uri},
            "range"        => {
              "start" => {
                "line"      => start_line,
                "character" => start_character,
              },
              "end" => {
                "line"      => end_line,
                "character" => end_character,
              },
            },
            "options" => {
              "tabSize"      => 2,
              "insertSpaces" => true,
            },
          }
        ).as_a?
          .try(&.dup) || [] of JSON::Any
      end

      def prepare_rename(uri : String, line : Int32, character : Int32) : JSON::Any?
        return nil unless connected?
        result = request("textDocument/prepareRename", text_document_position_params(uri, line, character))
        result.raw.nil? ? nil : result
      end

      def rename(uri : String, line : Int32, character : Int32, new_name : String) : JSON::Any?
        return nil unless connected?
        params = text_document_position_params(uri, line, character)
        params["newName"] = new_name
        result = request("textDocument/rename", params)
        result.raw.nil? ? nil : result
      end

      def semantic_tokens_supported? : Bool
        SemanticTokens.supported?(server_capabilities)
      end

      # LSP permits textDocumentSync as either a numeric kind or an options
      # object. Only an explicit Incremental kind enables ranged changes; every
      # other shape retains Adamantine's established full-text fallback.
      def incremental_text_sync? : Bool
        sync = @server_capabilities.try(&.["textDocumentSync"]?)
        return false unless sync

        if kind = sync.as_i?
          kind == 2
        elsif options = sync.as_h?
          options["change"]?.try(&.as_i?) == 2
        else
          false
        end
      rescue
        false
      end

      def semantic_tokens_full(uri : String) : Array(Int32)?
        return nil unless connected? && @stdin
        return nil unless semantic_tokens_supported?

        result = request(
          "textDocument/semanticTokens/full",
          {
            "textDocument" => {
              "uri" => uri,
            },
          },
          timeout_seconds: SEMANTIC_TOKENS_TIMEOUT_SECONDS
        )
        SemanticTokens.parse_data(result)
      rescue
        nil
      end

      def folding_ranges_supported? : Bool
        Folding.supported?(server_capabilities)
      end

      def folding_ranges(uri : String) : Array(Tui::TextEditor::FoldRange)?
        return nil unless connected? && @stdin
        return nil unless folding_ranges_supported?

        result = request(
          "textDocument/foldingRange",
          {
            "textDocument" => {
              "uri" => uri,
            },
          }
        )
        Folding.parse_ranges(result)
      rescue
        nil
      end

      def execute_command(command : String, args : Array(JSON::Any) = [] of JSON::Any) : JSON::Any?
        return nil unless connected?
        result = request(
          "workspace/executeCommand",
          {
            "command"   => command,
            "arguments" => args,
          }
        )
        result.raw.nil? ? nil : result
      end

      def request_notification(method : String, params : Hash(String, JSONValueLike) = {} of String => JSONValueLike) : Nil
        send_notification(method, params)
      end

      def request_raw(method : String, params : Hash(String, JSONValueLike) = {} of String => JSONValueLike) : JSON::Any
        request(method, params)
      end

      private def initialize_session
        response = request("initialize", {
          "processId"    => Process.pid,
          "rootUri"      => UriCodec.path_to_uri(@root),
          "capabilities" => self.class.client_capabilities,
          "clientInfo"   => {
            "name"    => "adamantine",
            "version" => "0.1.0",
          },
        })
        @server_capabilities = response["capabilities"]?
        @semantic_token_legend = SemanticTokens.parse_legend(@server_capabilities)
        send_notification("initialized", {} of String => JSON::Any)
      end

      def self.client_capabilities : JSON::Any
        JSON.parse(<<-JSON
          {
            "general": {
              "positionEncodings": ["utf-16"]
            },
            "textDocument": {
              "publishDiagnostics": {
                "relatedInformation": true
              },
              "semanticTokens": {
                "dynamicRegistration": false,
                "requests": {
                  "range": false,
                  "full": {
                    "delta": false
                  }
                },
                "tokenTypes": #{SemanticTokens::STANDARD_LEGEND.to_json},
                "tokenModifiers": #{SemanticTokens::STANDARD_MODIFIERS.to_json},
                "formats": ["relative"],
                "overlappingTokenSupport": false,
                "multilineTokenSupport": false,
                "serverCancelSupport": false,
                "augmentsSyntaxTokens": true
              },
              "foldingRange": {
                "dynamicRegistration": false,
                "rangeLimit": 5000,
                "lineFoldingOnly": true
              }
            },
            "workspace": {
              "semanticTokens": {
                "refreshSupport": true
              }
            }
          }
          JSON
        )
      end

      private def request(method : String, params : Hash(String, JSONValueLike), timeout_seconds : Int32 = READ_TIMEOUT_SECONDS, allow_stopping : Bool = false) : JSON::Any
        request_key : String? = nil
        reply = Channel(JSON::Any | Exception).new(1)

        begin
          @request_mutex.synchronize do
            raise "LSP disconnected" unless @connected && (allow_stopping || !@stopping)
            @next_id += 1
            payload_id = @next_id
            request_key = pending_key(payload_id)

            @pending_mutex.synchronize do
              @pending[request_key.not_nil!] = reply
            end

            payload = {
              "jsonrpc" => "2.0",
              "id"      => payload_id,
              "method"  => method,
              "params"  => params,
            }.to_json

            send_payload(payload)
          end

          response = select
          when value = reply.receive
            value
          when timeout(timeout_seconds.seconds)
            raise "LSP request timeout"
          end

          if response.is_a?(Exception)
            raise response
          end

          if error = response.as(JSON::Any)["error"]?
            raise "LSP error: #{error["message"]?.try(&.as_s) || error.to_json}"
          end

          response.as(JSON::Any)["result"]? || JSON::Any.new(nil)
        ensure
          if key = request_key
            @pending_mutex.synchronize do
              @pending.delete(key)
            end
          end
        end
      end

      private def pending_key(id : Int64) : String
        "number:#{id}"
      end

      private def pending_key(id : JSON::Any) : String?
        if number = id.as_i64?
          pending_key(number)
        elsif string = id.as_s?
          "string:#{string}"
        end
      end

      private def handle_server_request(id : JSON::Any, method : String) : Nil
        case method
        when "workspace/semanticTokens/refresh"
          spawn(name: "lsp-semantic-refresh") do
            @on_semantic_tokens_refresh.try(&.call)
          end
          send_result(id, nil)
        else
          send_error_response(id, -32601, "Method not found: #{method}")
        end
      end

      private def send_result(id : JSON::Any, result : JSON::Any | Nil) : Nil
        payload = {
          "jsonrpc" => "2.0",
          "id"      => id,
          "result"  => result,
        }.to_json
        send_payload(payload)
      end

      private def send_error_response(id : JSON::Any, code : Int32, message : String) : Nil
        payload = {
          "jsonrpc" => "2.0",
          "id"      => id,
          "error"   => {
            "code"    => code,
            "message" => message,
          },
        }.to_json
        send_payload(payload)
      end

      private def send_notification(method : String, params : Hash(String, JSONValueLike)) : Nil
        payload = {
          "jsonrpc" => "2.0",
          "method"  => method,
          "params"  => params,
        }.to_json
        send_payload(payload)
      end

      private def graceful_shutdown : Nil
        begin
          request("shutdown", {} of String => JSONValueLike, timeout_seconds: SHUTDOWN_TIMEOUT_SECONDS, allow_stopping: true)
        rescue
          # A stalled server is handled by the bounded process termination
          # path below; still send exit so cooperative servers can finish.
        end

        begin
          send_notification("exit", {} of String => JSONValueLike)
        rescue
          # The transport may already have failed while waiting for shutdown.
        end
      end

      private def bounded_graceful_shutdown : Nil
        finished = Channel(Nil).new(1)
        spawn do
          begin
            graceful_shutdown
          ensure
            finished.send(nil) rescue nil
          end
        end

        select
        when finished.receive
        when timeout(SHUTDOWN_TIMEOUT_SECONDS.seconds + PROCESS_GRACE_PERIOD)
        end
      end

      private def close_transport : Nil
        stdin = @stdin
        stdout = @stdout
        @stdin = nil
        @stdout = nil
        stdin.try &.close rescue nil
        stdout.try &.close rescue nil
      end

      private def stop_process(process : Process) : Nil
        finished = Channel(Nil).new(1)
        spawn do
          begin
            process.wait
          rescue
          ensure
            finished.send(nil) rescue nil
          end
        end

        return if await_process(finished, PROCESS_GRACE_PERIOD)

        begin
          process.terminate(graceful: true)
        rescue
        end
        return if await_process(finished, PROCESS_GRACE_PERIOD)

        begin
          process.terminate(graceful: false)
        rescue
        end
        await_process(finished, PROCESS_GRACE_PERIOD)
      end

      private def await_process(finished : Channel(Nil), duration : Time::Span) : Bool
        select
        when finished.receive
          true
        when timeout(duration)
          false
        end
      end

      private def send_payload(payload : String) : Nil
        @write_mutex.synchronize do
          if io = @stdin
            io << "Content-Length: #{payload.bytesize}\r\n"
            io << "\r\n"
            io << payload
            io.flush
          end
        end
      end

      private def start_reader
        @reader_running = true
        reader_done = Channel(Nil).new(1)
        @reader_done = reader_done
        @reader = spawn(name: "lsp-reader") do
          io = @stdout
          begin
            while @reader_running && io
              message = read_message(io)
              handle_message(message)
            end
          rescue ex
            reader_failed(ex)
          ensure
            reader_done.send(nil) rescue nil
          end
        end
      end

      private def handle_message(message : JSON::Any) : Nil
        # JSON-RPC requests are identified by their method, even when their
        # id happens to collide with an outstanding client request. Responses
        # have an id but no method.
        if method = message["method"]?.try(&.as_s?)
          if id = message["id"]?
            handle_server_request(id, method)
          elsif method == "textDocument/publishDiagnostics"
            handle_diagnostics_notification(message)
          end
          return
        end

        if id = message["id"]?
          if key = pending_key(id)
            channel = @pending_mutex.synchronize do
              @pending.delete(key)
            end
            channel.try { |reply| reply.send(message) }
          end
        end
      end

      private def handle_diagnostics_notification(message : JSON::Any) : Nil
        begin
          params = message["params"]?.try(&.as_h?) || {} of String => JSON::Any
          uri = params["uri"]?.try(&.as_s) || ""
          diagnostics = parse_diagnostics(params["diagnostics"]?)
          @on_diagnostics.try &.call(uri, diagnostics)
        rescue
          # Diagnostics are advisory; an invalid notification must not take
          # down an otherwise usable transport.
        end
      end

      private def reader_failed(error : Exception) : Nil
        @connected = false
        @reader_running = false
        @write_mutex.synchronize do
          @stdin.try &.close rescue nil
        end
        clear_pending(error)
      end

      private def read_message(io : IO) : JSON::Any
        # Skip noise lines before JSON/RPC header
        first_line : String? = nil
        noise_lines = 0
        loop do
          first_line = read_bounded_line(io)
          raise "No response from LSP server" unless first_line
          break if first_line.starts_with?("{") || first_line.starts_with?("Content-Length:")
          noise_lines += 1
          raise "LSP server sent too many non-header lines" if noise_lines > MAX_NOISE_LINES
        end
        line = first_line.not_nil!

        if line.starts_with?("Content-Length:")
          content_length = line[15..].strip.to_i
          raise "Invalid Content-Length" if content_length <= 0
          raise "LSP response too large" if content_length > MAX_JSON_BUFFER

          # Skip remaining headers
          header_count = 0
          loop do
            header = read_bounded_line(io)
            break if header.nil? || header.strip.empty?
            header_count += 1
            raise "LSP server sent too many headers" if header_count > MAX_LSP_HEADERS
          end

          payload = Bytes.new(content_length)
          io.read_fully(payload)
          JSON.parse(String.new(payload))
        else
          # Fallback for newline-delimited JSON
          json_buffer = line
          while !json_buffer.empty? && !json_buffer.ends_with?('}')
            next_line = read_bounded_line(io)
            break unless next_line
            raise "LSP response too large" if json_buffer.bytesize + next_line.bytesize > MAX_JSON_BUFFER
            json_buffer += next_line
          end
          JSON.parse(json_buffer)
        end
      end

      private def read_bounded_line(io : IO) : String?
        line = io.gets(MAX_JSON_BUFFER + 1)
        raise "LSP response too large" if line && line.bytesize > MAX_JSON_BUFFER
        line
      end

      private def parse_diagnostics(raw_diagnostics : JSON::Any?) : Array(Diagnostic)
        return [] of Diagnostic unless raw_diagnostics
        array = raw_diagnostics.as_a? || return [] of Diagnostic

        result = [] of Diagnostic
        array.each do |item|
          range = item["range"]?.try(&.as_h)
          next unless range
          start_pos = range["start"]?.try(&.as_h)
          next unless start_pos

          line = start_pos["line"]?.try(&.as_i) || 0
          character = start_pos["character"]?.try(&.as_i) || 0
          end_pos = range["end"]?.try(&.as_h)
          if end_pos
            end_line = end_pos["line"]?.try(&.as_i) || line
            end_character = end_pos["character"]?.try(&.as_i) || character
          else
            end_line = line
            end_character = character
          end

          if end_line == line && end_character <= character
            end_character = character + 1
          end

          message = item["message"]?.try(&.as_s) || ""
          source = item["source"]?.try(&.as_s)
          severity = item["severity"]?.try(&.as_i)

          result << Diagnostic.new(
            line,
            character,
            message,
            source,
            severity,
            end_line,
            end_character
          )
        end

        result
      end

      private def parse_hover(raw_hover : JSON::Any?) : Hover?
        return nil unless raw_hover
        return nil if raw_hover.raw.nil?

        text_parts = [] of String
        contents = raw_hover["contents"]?

        if value = contents.try(&.as_s?)
          text_parts << value
        elsif array = contents.try(&.as_a?)
          array.each do |part|
            if value = part["value"]?.try(&.as_s)
              text_parts << value
            else
              string_part = part.as_s?
              text_parts << string_part if string_part
            end
          end
        elsif hash = contents.try(&.as_h?)
          value = hash["value"]?.try(&.as_s)
          text_parts << value if value
        end

        if value = raw_hover["value"]?.try(&.as_s)
          text_parts << value
        end

        text = text_parts.join("\n").strip
        return nil if text.empty?

        Hover.new(text, parse_range(raw_hover["range"]?))
      end

      private def parse_completion_items(raw_completion : JSON::Any?) : Array(CompletionItem)
        return [] of CompletionItem unless raw_completion
        return [] of CompletionItem if raw_completion.raw.nil?

        completion_items = if items = raw_completion["items"]?
                             items.as_a? || [] of JSON::Any
                           else
                             raw_completion.as_a? || [] of JSON::Any
                           end

        completion_items.compact_map do |entry|
          label = entry["label"]?.try(&.as_s)
          next unless label

          detail = entry["detail"]?.try(&.as_s)
          kind = entry["kind"]?.try(&.as_i)
          insert_text = entry["insertText"]?.try(&.as_s)
          if insert_text.nil?
            if edit = entry["textEdit"]?.try(&.as_h)
              insert_text = edit["newText"]?.try(&.as_s)
            end
          end
          filter_text = entry["filterText"]?.try(&.as_s)

          CompletionItem.new(label, detail, kind, insert_text, filter_text)
        end
      end

      private def parse_signature_help(raw_signature_help : JSON::Any?) : SignatureHelp?
        return nil unless raw_signature_help
        return nil if raw_signature_help.raw.nil?

        signatures = raw_signature_help["signatures"]?.try(&.as_a) || [] of JSON::Any
        return nil if signatures.empty?

        signature_lines = signatures.compact_map do |signature|
          signature["label"]?.try(&.as_s)
        end
        return nil if signature_lines.empty?

        active_signature = raw_signature_help["activeSignature"]?.try(&.as_i) || 0
        active_parameter = raw_signature_help["activeParameter"]?.try(&.as_i) || 0

        SignatureHelp.new(signature_lines, active_signature, active_parameter)
      end

      private def parse_locations(raw_locations : JSON::Any?) : Array(Location)
        return [] of Location unless raw_locations
        if raw_locations.raw.nil?
          return [] of Location
        end

        if raw_locations.as_h?
          return parse_location_entry(raw_locations)
        end

        if array = raw_locations.as_a?
          locations = [] of Location
          array.each do |item|
            result = parse_location_entry(item)
            result.each do |location|
              locations << location
            end
          end
          locations
        else
          [] of Location
        end
      end

      private def parse_range(raw_range : JSON::Any?) : Range?
        return nil unless raw_range
        return nil if raw_range.raw.nil?

        start = raw_range["start"]?.try(&.as_h)
        done = raw_range["end"]?.try(&.as_h)
        return nil unless start && done

        start_line = start["line"]?.try(&.as_i) || 0
        start_character = start["character"]?.try(&.as_i) || 0
        end_line = done["line"]?.try(&.as_i) || start_line
        end_character = done["character"]?.try(&.as_i) || start_character

        Range.new(start_line, start_character, end_line, end_character)
      end

      private def text_document_position_params(uri : String, line : Int32, character : Int32) : Hash(String, JSONValueLike)
        text_document = Hash(String, JSONValueLike).new
        text_document["uri"] = uri

        position = Hash(String, JSONValueLike).new
        position["line"] = line
        position["character"] = character

        params = Hash(String, JSONValueLike).new
        params["textDocument"] = text_document
        params["position"] = position
        params
      end

      private def parse_location_entry(raw_location : JSON::Any) : Array(Location)
        uri = raw_location["uri"]?.try(&.as_s)
        return [] of Location if uri.nil? || uri.empty?

        range = raw_location["range"]?.try(&.as_h?) || raw_location["targetRange"]?.try(&.as_h?)
        return [] of Location if range.nil?

        start = range["start"]?.try(&.as_h?)
        return [] of Location if start.nil?

        start_line = start["line"]?.try(&.as_i) || 0
        start_character = start["character"]?.try(&.as_i) || 0

        [Location.new(uri, start_line, start_character)]
      end

      private def clear_pending(error : Exception) : Nil
        @pending_mutex.synchronize do
          @pending.each_value do |channel|
            channel.send(error)
          end
          @pending.clear
        end
      end

      alias JSONValueLike = (Int32 | Int64 | Float64 | Bool | String | Nil | JSON::Any | Hash(String, JSONValueLike) | Array(JSONValueLike))
    end
  end
end
