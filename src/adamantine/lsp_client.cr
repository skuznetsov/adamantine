require "json"
require "./semantic_tokens"
require "./folding"
require "./uri_codec"

module Adamantine
  module Lsp
    # Completion parsing is a trust boundary: a server response may carry
    # document-edit authority, so keep the accepted model small and bounded.
    COMPLETION_MAX_ITEMS                 =  100
    COMPLETION_MAX_LABEL_CODEPOINTS      =  512
    COMPLETION_MAX_DETAIL_CODEPOINTS     = 2048
    COMPLETION_MAX_FILTER_CODEPOINTS     =  512
    COMPLETION_MAX_INSERTION_BYTES       = 256 * 1024
    COMPLETION_REJECTION_SNIPPET         = "snippet_completion_unsupported"
    COMPLETION_REJECTION_INSERT_REPLACE  = "insert_replace_edit_unsupported"
    COMPLETION_REJECTION_ADDITIONAL      = "additional_text_edits_unsupported"
    COMPLETION_REJECTION_COMMAND         = "command_unsupported"
    COMPLETION_REJECTION_INSERT_MODE     = "non_default_insert_text_mode"
    COMPLETION_REJECTION_LIST_DEFAULTS   = "completion_list_item_defaults_unsupported"
    COMPLETION_REJECTION_MALFORMED       = "malformed_completion_item"
    COMPLETION_REJECTION_LABEL_LIMIT     = "label_too_long"
    COMPLETION_REJECTION_INSERTION_LIMIT = "insertion_too_large"
    DIAGNOSTIC_MAX_ITEMS                 = 1000
    DIAGNOSTIC_MAX_MESSAGE_CODEPOINTS    = 4096
    DIAGNOSTIC_MAX_SOURCE_CODEPOINTS     =  256
    DIAGNOSTIC_MAX_URI_BYTES             = 8192

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

    # The parser reports whether a publication was bounded or had malformed
    # entries. The legacy callback intentionally exposes only its accepted
    # diagnostics array; version-aware consumers use this result's partial
    # flag to distinguish an exact clear from a bounded snapshot.
    struct DiagnosticParseResult
      getter diagnostics : Array(Diagnostic)
      getter partial : Bool

      def initialize(@diagnostics : Array(Diagnostic), @partial : Bool)
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

    struct CompletionTextEdit
      property range : Range
      property new_text : String

      def initialize(@range : Range, @new_text : String)
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
      property text_edit : CompletionTextEdit?
      property insert_text_format : Int32?
      property rejection_reason : String?

      # Keep the original five-argument constructor intact for LSP fakes and
      # callers that only render read-only completion labels. New fields are
      # trailing optional arguments so adding mutation metadata is source
      # compatible with those callers.
      def initialize(
        @label : String,
        @detail : String? = nil,
        @kind : Int32? = nil,
        @insert_text : String? = nil,
        @filter_text : String? = nil,
        @text_edit : CompletionTextEdit? = nil,
        @insert_text_format : Int32? = nil,
        @rejection_reason : String? = nil,
      )
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
      READ_TIMEOUT_SECONDS              =  8
      SEMANTIC_TOKENS_TIMEOUT_SECONDS   = 15
      SHUTDOWN_TIMEOUT_SECONDS          =  1
      PROCESS_GRACE_PERIOD              = 250.milliseconds
      DEFAULT_MAX_RESPONSE_BYTES        = 16 * 1024 * 1024
      MIN_MAX_RESPONSE_BYTES            = 1 * 1024 * 1024
      MAX_MAX_RESPONSE_BYTES            = 64 * 1024 * 1024
      MAX_JSON_BUFFER                   = 4_194_304
      MAX_HEADER_LINE_BYTES             = 64 * 1024
      MAX_NOISE_LINES                   = 100
      MAX_LSP_HEADERS                   =  50
      MAX_DISCARD_BYTES                 = 256_i64 * 1024 * 1024
      DISCARD_BUFFER_BYTES              = 32 * 1024
      DISCARD_TIMEOUT_SECONDS           = 5
      MAX_COMPLETION_ITEMS              = COMPLETION_MAX_ITEMS
      MAX_COMPLETION_LABEL_CODEPOINTS   = COMPLETION_MAX_LABEL_CODEPOINTS
      MAX_COMPLETION_DETAIL_CODEPOINTS  = COMPLETION_MAX_DETAIL_CODEPOINTS
      MAX_COMPLETION_FILTER_CODEPOINTS  = COMPLETION_MAX_FILTER_CODEPOINTS
      MAX_COMPLETION_INSERTION_BYTES    = COMPLETION_MAX_INSERTION_BYTES
      MAX_DIAGNOSTIC_ITEMS              = DIAGNOSTIC_MAX_ITEMS
      MAX_DIAGNOSTIC_MESSAGE_CODEPOINTS = DIAGNOSTIC_MAX_MESSAGE_CODEPOINTS
      MAX_DIAGNOSTIC_SOURCE_CODEPOINTS  = DIAGNOSTIC_MAX_SOURCE_CODEPOINTS
      MAX_DIAGNOSTIC_URI_BYTES          = DIAGNOSTIC_MAX_URI_BYTES

      property server_capabilities : JSON::Any?
      property on_diagnostics : Proc(String, Array(Diagnostic), Nil)? = nil
      # Versioned diagnostics are the preferred publication path. Its final
      # boolean is true when malformed entries or hard bounds made the batch
      # partial. Keep on_diagnostics unchanged for existing clients/fakes.
      property on_versioned_diagnostics : Proc(String, Int32?, Array(Diagnostic), Bool, Nil)? = nil
      property on_semantic_tokens_refresh : Proc(Nil)? = nil
      property on_warning : Proc(String, Nil)? = nil
      setter connected : Bool
      getter semantic_token_legend : Array(String) = SemanticTokens::STANDARD_LEGEND.dup
      getter max_response_bytes : Int32

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
      @max_response_bytes : Int32 = DEFAULT_MAX_RESPONSE_BYTES

      def initialize(@command : String, root : Path, @args : Array(String) = [] of String)
        @root = root
        @pending = Hash(String, Channel(JSON::Any | Exception)).new
        @pending_mutex = Mutex.new
        @request_mutex = Mutex.new
        @write_mutex = Mutex.new
        @stop_mutex = Mutex.new
      end

      def max_response_bytes=(value : Int32) : Int32
        unless value >= MIN_MAX_RESPONSE_BYTES && value <= MAX_MAX_RESPONSE_BYTES
          raise ArgumentError.new("LSP response limit must be between #{MIN_MAX_RESPONSE_BYTES} and #{MAX_MAX_RESPONSE_BYTES} bytes")
        end

        @max_response_bytes = value
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
        limit = max_items.clamp(0, MAX_COMPLETION_ITEMS)
        items.first([items.size, limit].min)
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
                "relatedInformation": true,
                "versionSupport": true
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
        # A fully discarded oversized frame has no JSON object to dispatch.
        return unless message.as_h?

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
          params = message["params"]?.try(&.as_h?) || return
          uri = params["uri"]?.try(&.as_s?) || return
          return if uri.empty? || uri.bytesize > MAX_DIAGNOSTIC_URI_BYTES

          version_valid, version = parse_diagnostic_version(params)
          return unless version_valid

          raw_diagnostics = params["diagnostics"]? || return
          return unless raw_diagnostics.as_a?
          parsed = parse_diagnostics_result(raw_diagnostics)

          # A newly configured controller can reject stale publications using
          # the version and its own client identity. Legacy clients retain the
          # exact old callback shape, but are only used when no version-aware
          # consumer is installed.
          if callback = @on_versioned_diagnostics
            callback.call(uri, version, parsed.diagnostics, parsed.partial)
          elsif callback = @on_diagnostics
            callback.call(uri, parsed.diagnostics)
          end
        rescue
          # Diagnostics are advisory; an invalid notification must not take
          # down an otherwise usable transport.
        end
      end

      private def reader_failed(error : Exception) : Nil
        # Detach the failed transport before publishing disconnected state so
        # a caller that immediately starts a replacement cannot lose its new
        # pipes to this cleanup path.
        stdin = @stdin
        stdout = @stdout
        @stdin = nil
        @stdout = nil
        @connected = false
        @reader_running = false
        unless @stopping || response_warning_reported?(error)
          message = error.message || error.class.to_s
          report_warning("LSP transport failed: #{message}; connection closed")
        end
        # Do not wait on @write_mutex here. A server that stopped reading can
        # leave a writer blocked while the reader is the only fiber able to
        # observe EOF/timeout and close the pipe that would release it.
        stdin.try &.close rescue nil
        stdout.try &.close rescue nil
        clear_pending(error)
      end

      private def read_message(io : IO) : JSON::Any
        # Skip noise lines before JSON/RPC header
        first_line : String? = nil
        noise_lines = 0
        loop do
          first_line = read_bounded_line(io, MAX_HEADER_LINE_BYTES)
          raise "No response from LSP server" unless first_line
          break if first_line.starts_with?("{") || first_line.starts_with?("Content-Length:")
          noise_lines += 1
          raise "LSP server sent too many non-header lines" if noise_lines > MAX_NOISE_LINES
        end
        line = first_line.not_nil!

        if line.starts_with?("Content-Length:")
          content_length = line[15..].strip.to_i64?
          raise "Invalid Content-Length" unless content_length && content_length > 0

          # Skip remaining headers
          header_count = 0
          loop do
            header = read_bounded_line(io, MAX_HEADER_LINE_BYTES)
            raise "LSP response headers truncated before blank separator" unless header
            break if header.strip.empty?
            header_count += 1
            raise "LSP server sent too many headers" if header_count > MAX_LSP_HEADERS
          end

          if content_length > @max_response_bytes
            return discard_oversized_response(io, content_length)
          end

          payload = Bytes.new(content_length.to_i)
          begin
            io.read_fully(payload)
          rescue ex : IO::EOFError
            report_warning(
              "LSP response body truncated before #{content_length} bytes " \
              "(limit #{@max_response_bytes} bytes); connection closed; " \
              "adjust F10 Settings LSP response limit"
            )
            raise IO::EOFError.new("#{ex.message}; connection closed; adjust F10 Settings LSP response limit")
          end
          JSON.parse(String.new(payload))
        else
          # Fallback for newline-delimited JSON
          json_buffer = line
          while !json_buffer.empty? && !json_buffer.ends_with?('}')
            next_line = read_bounded_line(io, MAX_HEADER_LINE_BYTES)
            break unless next_line
            raise "LSP response too large" if json_buffer.bytesize + next_line.bytesize > @max_response_bytes
            json_buffer += next_line
          end
          raise "LSP response too large" if json_buffer.bytesize > @max_response_bytes
          JSON.parse(json_buffer)
        end
      end

      private def read_bounded_line(io : IO, max_bytes : Int32 = MAX_HEADER_LINE_BYTES) : String?
        line = io.gets(max_bytes + 1)
        raise "LSP response too large" if line && line.bytesize > max_bytes
        line
      end

      private def discard_oversized_response(io : IO, content_length : Int64) : JSON::Any
        limit = @max_response_bytes
        if content_length > MAX_DISCARD_BYTES
          report_warning(
            "LSP response body announces #{content_length} bytes, above hard discard cap #{MAX_DISCARD_BYTES} bytes; " \
            "connection closed; adjust F10 Settings LSP response limit"
          )
          raise "LSP response exceeds hard discard cap; connection closed; adjust F10 Settings LSP response limit"
        end

        discarded = 0_i64
        deadline = Time.instant + response_discard_timeout
        scratch = Bytes.new(DISCARD_BUFFER_BYTES)

        begin
          while discarded < content_length
            remaining = deadline - Time.instant
            raise IO::TimeoutError.new("LSP response discard deadline exceeded") if remaining <= Time::Span.zero

            to_read = Math.min(content_length - discarded, scratch.size.to_i64).to_i
            count = read_with_deadline(io, scratch[0, to_read], remaining)
            raise IO::EOFError.new("LSP response body truncated") if count <= 0
            discarded += count
          end
        rescue ex : IO::TimeoutError
          report_warning(
            "LSP response body discard stalled after #{discarded} of #{content_length} bytes " \
            "(limit #{limit} bytes); connection closed; adjust F10 Settings LSP response limit"
          )
          raise IO::TimeoutError.new("#{ex.message}; connection closed; adjust F10 Settings LSP response limit")
        rescue ex : IO::EOFError
          report_warning(
            "LSP response body discard truncated after #{discarded} of #{content_length} bytes " \
            "(limit #{limit} bytes); connection closed; adjust F10 Settings LSP response limit"
          )
          raise IO::EOFError.new("#{ex.message}; connection closed; adjust F10 Settings LSP response limit")
        rescue ex
          report_warning(
            "LSP response body discard failed after #{discarded} of #{content_length} bytes " \
            "(limit #{limit} bytes): #{ex.message || ex.class}; connection closed; " \
            "adjust F10 Settings LSP response limit"
          )
          raise Exception.new("#{ex.message || ex.class}; connection closed; adjust F10 Settings LSP response limit")
        end

        clear_pending(Exception.new("LSP response exceeded configured limit #{limit} bytes"))
        report_warning(
          "Skipped oversized LSP response body of #{content_length} bytes (limit #{limit} bytes); " \
          "adjust F10 Settings LSP response limit"
        )
        JSON::Any.new(nil)
      end

      private def response_discard_timeout : Time::Span
        DISCARD_TIMEOUT_SECONDS.seconds
      end

      private def response_warning_reported?(error : Exception) : Bool
        error.message.try(&.includes?("connection closed; adjust F10 Settings LSP response limit")) || false
      end

      private def read_with_deadline(io : IO, slice : Bytes, remaining : Time::Span) : Int32
        if descriptor = io.as?(IO::FileDescriptor)
          previous_timeout = descriptor.read_timeout
          descriptor.read_timeout = remaining
          begin
            io.read(slice)
          ensure
            descriptor.read_timeout = previous_timeout
          end
        else
          io.read(slice)
        end
      end

      private def report_warning(message : String) : Nil
        callback = @on_warning
        return unless callback

        # Warnings are advisory and must not block or poison the sole reader
        # fiber. In particular, a UI callback may itself enqueue work.
        spawn(name: "lsp-warning") do
          begin
            callback.call(message)
          rescue
            # Warning presentation must never tear down the transport.
          end
        end
      end

      private def parse_diagnostics(raw_diagnostics : JSON::Any?) : Array(Diagnostic)
        parse_diagnostics_result(raw_diagnostics).diagnostics
      end

      private def parse_diagnostics_result(raw_diagnostics : JSON::Any?) : DiagnosticParseResult
        return DiagnosticParseResult.new([] of Diagnostic, false) unless raw_diagnostics
        array = raw_diagnostics.as_a?
        return DiagnosticParseResult.new([] of Diagnostic, true) unless array

        result = [] of Diagnostic
        partial = false
        array.each_with_index do |item, index|
          if index >= MAX_DIAGNOSTIC_ITEMS
            partial = true
            break
          end

          item_hash = item.as_h?
          unless item_hash
            partial = true
            next
          end

          range = item_hash["range"]?.try(&.as_h?)
          start_pos = range.try { |value| value["start"]?.try(&.as_h?) }
          end_pos = range.try { |value| value["end"]?.try(&.as_h?) }
          start_line = start_pos.try { |value| parse_diagnostic_position(value["line"]?) }
          start_character = start_pos.try { |value| parse_diagnostic_position(value["character"]?) }
          end_line = end_pos.try { |value| parse_diagnostic_position(value["line"]?) }
          end_character = end_pos.try { |value| parse_diagnostic_position(value["character"]?) }

          unless start_line && start_character && end_line && end_character
            partial = true
            next
          end

          unless end_line.not_nil! > start_line.not_nil! ||
                 (end_line == start_line && end_character.not_nil! >= start_character.not_nil!)
            partial = true
            next
          end

          message = item_hash["message"]?.try(&.as_s?)
          unless message
            partial = true
            next
          end
          bounded_message, message_truncated = bound_diagnostic_text(message, MAX_DIAGNOSTIC_MESSAGE_CODEPOINTS)
          partial ||= message_truncated

          source : String? = nil
          if source_value = item_hash["source"]?
            unless source_value.raw.nil?
              if source_text = source_value.as_s?
                bounded_source, source_truncated = bound_diagnostic_text(source_text, MAX_DIAGNOSTIC_SOURCE_CODEPOINTS)
                source = bounded_source
                partial ||= source_truncated
              else
                partial = true
              end
            end
          end

          severity : Int32? = nil
          if severity_value = item_hash["severity"]?
            unless severity_value.raw.nil?
              if severity_integer = severity_value.as_i64?
                if severity_integer >= Int32::MIN && severity_integer <= Int32::MAX
                  severity = severity_integer.to_i32
                else
                  partial = true
                end
              else
                partial = true
              end
            end
          end

          result << Diagnostic.new(
            start_line.not_nil!,
            start_character.not_nil!,
            bounded_message,
            source,
            severity,
            end_line.not_nil!,
            end_character.not_nil!
          )
        end

        DiagnosticParseResult.new(result, partial)
      end

      private def parse_diagnostic_position(value : JSON::Any?) : Int32?
        return nil unless value
        integer = value.as_i64?
        return nil unless integer
        return nil if integer < 0 || integer > Int32::MAX
        integer.to_i32
      end

      private def parse_diagnostic_version(params : Hash(String, JSON::Any)) : Tuple(Bool, Int32?)
        value = params["version"]?
        return {true, nil} unless value
        return {true, nil} if value.raw.nil?

        integer = value.as_i64?
        return {false, nil} unless integer
        return {false, nil} if integer < Int32::MIN || integer > Int32::MAX
        {true, integer.to_i32}
      end

      private def bound_diagnostic_text(value : String, maximum : Int32) : Tuple(String, Bool)
        return {value, false} if value.size <= maximum

        bounded = String.build do |io|
          index = 0
          value.each_char do |char|
            break if index >= maximum
            io << char
            index += 1
          end
        end
        {bounded, true}
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

        list_defaults_rejection : String? = nil
        completion_items : Array(JSON::Any)

        if completion_hash = raw_completion.as_h?
          # `itemDefaults` can carry an edit range or another value that this
          # client cannot safely expand per item. Retain the items but mark
          # each one rejected so the UI cannot accidentally apply a subset.
          list_defaults_rejection = COMPLETION_REJECTION_LIST_DEFAULTS if completion_hash.has_key?("itemDefaults")

          if raw_items = completion_hash["items"]?
            completion_items = raw_items.as_a? || [JSON::Any.new({} of String => JSON::Any)]
          else
            return [] of CompletionItem
          end
        elsif raw_items = raw_completion.as_a?
          completion_items = raw_items
        else
          return [] of CompletionItem
        end

        result = [] of CompletionItem
        completion_items.each_with_index do |entry, index|
          break if index >= MAX_COMPLETION_ITEMS
          result << parse_completion_item(entry, list_defaults_rejection)
        end
        result
      end

      private def parse_completion_item(raw_entry : JSON::Any, list_defaults_rejection : String?) : CompletionItem
        entry = raw_entry.as_h?
        unless entry
          return CompletionItem.new(
            "",
            rejection_reason: list_defaults_rejection || COMPLETION_REJECTION_MALFORMED
          )
        end

        label, label_valid, label_oversized = bounded_completion_label(entry["label"]?)
        rejection_reason = list_defaults_rejection
        rejection_reason ||= COMPLETION_REJECTION_MALFORMED unless label_valid
        rejection_reason ||= COMPLETION_REJECTION_LABEL_LIMIT if label_oversized

        detail, detail_valid, _detail_oversized = bounded_optional_completion_string(
          entry,
          "detail",
          MAX_COMPLETION_DETAIL_CODEPOINTS
        )
        rejection_reason ||= COMPLETION_REJECTION_MALFORMED unless detail_valid

        kind, kind_valid = optional_completion_int32(entry, "kind")
        rejection_reason ||= COMPLETION_REJECTION_MALFORMED unless kind_valid

        filter_text, filter_valid, _filter_oversized = bounded_optional_completion_string(
          entry,
          "filterText",
          MAX_COMPLETION_FILTER_CODEPOINTS
        )
        rejection_reason ||= COMPLETION_REJECTION_MALFORMED unless filter_valid

        insert_text, insert_text_valid = optional_completion_string(entry, "insertText")
        rejection_reason ||= COMPLETION_REJECTION_MALFORMED unless insert_text_valid
        if insert_text
          if insert_text.bytesize > MAX_COMPLETION_INSERTION_BYTES
            insert_text = nil
            rejection_reason ||= COMPLETION_REJECTION_INSERTION_LIMIT
          end
        end

        insert_text_format = 1
        if entry.has_key?("insertTextFormat")
          parsed_format, format_valid = optional_completion_int32(entry, "insertTextFormat")
          unless format_valid && parsed_format
            rejection_reason ||= COMPLETION_REJECTION_MALFORMED
          else
            insert_text_format = parsed_format
            if insert_text_format == 2
              rejection_reason ||= COMPLETION_REJECTION_SNIPPET
            elsif insert_text_format != 1
              rejection_reason ||= COMPLETION_REJECTION_MALFORMED
            end
          end
        end

        if entry.has_key?("insertTextMode")
          insert_mode, insert_mode_valid = optional_completion_int32(entry, "insertTextMode")
          if !(insert_mode_valid && insert_mode)
            rejection_reason ||= COMPLETION_REJECTION_MALFORMED
          elsif insert_mode != 1
            rejection_reason ||= COMPLETION_REJECTION_INSERT_MODE
          end
        end

        if entry.has_key?("additionalTextEdits")
          rejection_reason ||= COMPLETION_REJECTION_ADDITIONAL
        end
        if entry.has_key?("command")
          rejection_reason ||= COMPLETION_REJECTION_COMMAND
        end

        text_edit : CompletionTextEdit? = nil
        if entry.has_key?("textEdit")
          raw_edit = entry["textEdit"]?
          if edit_hash = raw_edit.try(&.as_h?)
            if edit_hash.has_key?("insert") || edit_hash.has_key?("replace")
              # InsertReplaceEdit cannot be reduced to a single safe range.
              # Do not expose its newText as an executable fallback.
              insert_text = nil
              rejection_reason ||= COMPLETION_REJECTION_INSERT_REPLACE
            else
              parsed_edit, edit_reason, edit_new_text = parse_standard_completion_edit(edit_hash)
              text_edit = parsed_edit
              rejection_reason ||= edit_reason

              # Keep the legacy textEdit.newText fallback for callers that
              # only display `insert_text`; consumers must honor
              # rejection_reason before mutation and must prefer text_edit.
              if insert_text.nil? && edit_new_text
                insert_text = edit_new_text
              end
            end
          else
            rejection_reason ||= COMPLETION_REJECTION_MALFORMED
          end
        end

        # Preserve the historical label fallback only when the item did not
        # carry any textEdit at all. A malformed edit must not be reduced to a
        # different insertion, even though a plain label remains displayable.
        if insert_text.nil? && !entry.has_key?("insertText") && !entry.has_key?("textEdit")
          insert_text = label unless label.empty?
        end

        CompletionItem.new(
          label,
          detail,
          kind,
          insert_text,
          filter_text,
          text_edit,
          insert_text_format,
          rejection_reason
        )
      end

      private def parse_standard_completion_edit(
        edit_hash : Hash(String, JSON::Any),
      ) : Tuple(CompletionTextEdit?, String?, String?)
        raw_new_text = edit_hash["newText"]?
        new_text = raw_new_text.try(&.as_s?)

        # Check the executable payload before validating the range. Otherwise
        # a malformed/missing range could preserve an oversized legacy
        # fallback and bypass the insertion bound.
        if new_text && new_text.bytesize > MAX_COMPLETION_INSERTION_BYTES
          return {nil, COMPLETION_REJECTION_INSERTION_LIMIT, nil}
        end

        range = parse_completion_range(edit_hash["range"]?)

        unless range && new_text
          # Preserve a valid string as a display-only compatibility fallback;
          # the malformed reason prevents acceptance from applying it.
          legacy_fallback = edit_hash.has_key?("range") ? nil : new_text
          return {nil, COMPLETION_REJECTION_MALFORMED, legacy_fallback}
        end

        {CompletionTextEdit.new(range.not_nil!, new_text), nil, new_text}
      end

      private def parse_completion_range(raw_range : JSON::Any?) : Range?
        range = raw_range.try(&.as_h?) || return nil
        start = range["start"]?.try(&.as_h?) || return nil
        done = range["end"]?.try(&.as_h?) || return nil

        start_line, start_line_valid = required_completion_int32(start, "line")
        start_character, start_character_valid = required_completion_int32(start, "character")
        end_line, end_line_valid = required_completion_int32(done, "line")
        end_character, end_character_valid = required_completion_int32(done, "character")
        return nil unless start_line_valid && start_character_valid && end_line_valid && end_character_valid

        Range.new(start_line.not_nil!, start_character.not_nil!, end_line.not_nil!, end_character.not_nil!)
      end

      private def bounded_completion_label(raw_label : JSON::Any?) : Tuple(String, Bool, Bool)
        label = raw_label.try(&.as_s?) || return {"", false, false}

        bounded, oversized = bounded_completion_value(label, MAX_COMPLETION_LABEL_CODEPOINTS)
        {bounded, true, oversized}
      end

      private def bounded_optional_completion_string(
        entry : Hash(String, JSON::Any),
        key : String,
        max_codepoints : Int32,
      ) : Tuple(String?, Bool, Bool)
        raw = entry[key]?
        return {nil, true, false} unless raw
        value = raw.as_s?
        return {nil, false, false} unless value

        bounded, oversized = bounded_completion_value(value, max_codepoints)
        {bounded, true, oversized}
      end

      private def bounded_completion_value(value : String, max_codepoints : Int32) : Tuple(String, Bool)
        builder = String::Builder.new
        count = 0
        value.each_char do |char|
          if count >= max_codepoints
            return {builder.to_s, true}
          end

          builder << char
          count += 1
        end

        {builder.to_s, false}
      end

      private def optional_completion_string(
        entry : Hash(String, JSON::Any),
        key : String,
      ) : Tuple(String?, Bool)
        raw = entry[key]?
        return {nil, true} unless raw
        value = raw.as_s?
        {value, !value.nil?}
      end

      private def optional_completion_int32(
        entry : Hash(String, JSON::Any),
        key : String,
      ) : Tuple(Int32?, Bool)
        raw = entry[key]?
        return {nil, true} unless raw
        value = raw.as_i64?
        return {nil, false} unless value
        return {nil, false} if value < Int32::MIN || value > Int32::MAX

        {value.to_i32, true}
      end

      private def required_completion_int32(
        entry : Hash(String, JSON::Any),
        key : String,
      ) : Tuple(Int32?, Bool)
        return {nil, false} unless entry.has_key?(key)
        optional_completion_int32(entry, key)
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
