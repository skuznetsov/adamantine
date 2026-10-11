require "json"
require "spec"

require "../src/adamantine/dap/protocol"

private def dap_protocol_message(seq : Int32 = 1) : JSON::Any
  JSON.parse({
    "seq"       => seq,
    "type"      => "request",
    "command"   => "launch",
    "arguments" => {
      "program" => "café.cr",
    },
  }.to_json)
end

private def dap_wire_frame(payload : String) : String
  "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}"
end

describe "DAP protocol adversaries" do
  it "validates the bounded incomplete-frame deadline" do
    Adamantine::Dap::Limits.new(incomplete_frame_timeout: 1.millisecond).incomplete_frame_timeout.should eq(1.millisecond)
    expect_raises(ArgumentError) { Adamantine::Dap::Limits.new(incomplete_frame_timeout: Time::Span.zero) }
    expect_raises(ArgumentError) { Adamantine::Dap::Limits.new(incomplete_frame_timeout: 5.minutes + 1.millisecond) }
  end

  it "encodes Content-Length as UTF-8 payload bytes, not characters" do
    message = dap_protocol_message
    frame = Adamantine::Dap::Protocol.encode_frame(message)
    payload = message.to_json

    frame.should start_with("Content-Length: #{payload.bytesize}\r\n\r\n")
    frame.bytesize.should eq("Content-Length: #{payload.bytesize}\r\n\r\n".bytesize + payload.bytesize)
  end

  it "reassembles header and body split at arbitrary byte boundaries" do
    frame = Adamantine::Dap::Protocol.encode_frame(dap_protocol_message)
    decoder = Adamantine::Dap::FrameDecoder.new
    messages = [] of Adamantine::Dap::Message
    first_incomplete = nil.as(Time::Instant?)

    decoder.incomplete_since.should be_nil

    frame.to_slice.each_with_index do |byte, index|
      decoded = decoder.feed(Bytes[byte])
      messages.concat(decoded)

      if index == 0
        first_incomplete = decoder.incomplete_since
        first_incomplete.should_not be_nil
      elsif index < frame.bytesize - 1
        decoder.incomplete_since.should eq(first_incomplete)
        decoded.should be_empty
      else
        decoder.incomplete_since.should be_nil
        decoded.size.should eq(1)
      end
    end
    decoder.finish!

    messages.size.should eq(1)
    messages.first.command.should eq("launch")
    messages.first.arguments.not_nil!["program"].as_s.should eq("café.cr")
  end

  it "rejects duplicate, missing, non-decimal, and oversized headers" do
    [
      "Content-Length: 2\r\ncontent-length: 2\r\n\r\n{}",
      "X-Test: 2\r\n\r\n{}",
      "Content-Length: +2\r\n\r\n{}",
      "Content-Length: 33\r\n\r\n",
    ].each do |wire|
      local = Adamantine::Dap::FrameDecoder.new(max_header_bytes: 64, max_message_bytes: 32)
      expect_raises(Adamantine::Dap::ProtocolError) { local.feed(wire.to_slice) }
    end

    long_header = "X" * 65
    local = Adamantine::Dap::FrameDecoder.new(max_header_bytes: 64, max_message_bytes: 32)
    expect_raises(Adamantine::Dap::ProtocolError) { local.feed(long_header.to_slice) }
  end

  it "rejects malformed JSON and invalid UTF-8 payloads" do
    malformed = Adamantine::Dap::FrameDecoder.new
    expect_raises(Adamantine::Dap::ProtocolError) do
      malformed.feed(dap_wire_frame("{not json}").to_slice)
    end

    invalid_utf8_payload = String.new(Bytes[0x7b, 0x22, 0x78, 0x22, 0x3a, 0xff, 0x7d])
    invalid_utf8 = Adamantine::Dap::FrameDecoder.new
    expect_raises(Adamantine::Dap::ProtocolError) do
      invalid_utf8.feed(dap_wire_frame(invalid_utf8_payload).to_slice)
    end
  end

  it "fails closed on truncated header or body at EOF" do
    header = Adamantine::Dap::FrameDecoder.new
    header.feed("Content-Length: 5\r\n".to_slice)
    expect_raises(Adamantine::Dap::ProtocolError) { header.finish! }

    body = Adamantine::Dap::FrameDecoder.new
    body.feed("Content-Length: 5\r\n\r\n{}".to_slice)
    expect_raises(Adamantine::Dap::ProtocolError) { body.finish! }
  end

  it "bounds JSON nesting and token count before decoding an AST" do
    deep_value = "[" * 40 + "0" + "]" * 40
    deep_payload = "{\"seq\":1,\"type\":\"event\",\"event\":\"output\",\"body\":{\"value\":#{deep_value}}}"
    Adamantine::Dap::FrameDecoder.new(max_json_depth: 64).feed(dap_wire_frame(deep_payload).to_slice).size.should eq(1)
    depth_limited = Adamantine::Dap::FrameDecoder.new(max_json_depth: 32)
    deep_error = expect_raises(Adamantine::Dap::ProtocolError) { depth_limited.feed(dap_wire_frame(deep_payload).to_slice) }
    deep_error.message.should eq("DAP JSON depth budget exceeded")

    many_tokens = {"seq" => 1, "type" => "event", "event" => "output", "body" => {"items" => (0...40).to_a}}.to_json
    Adamantine::Dap::FrameDecoder.new(max_json_tokens: 256).feed(dap_wire_frame(many_tokens).to_slice).size.should eq(1)
    token_limited = Adamantine::Dap::FrameDecoder.new(max_json_tokens: 32)
    token_error = expect_raises(Adamantine::Dap::ProtocolError) { token_limited.feed(dap_wire_frame(many_tokens).to_slice) }
    token_error.message.should eq("DAP JSON token budget exceeded")
  end

  it "requires sane DAP envelope kind, sequence and type-specific fields" do
    invalid = [
      {"seq" => 0, "type" => "event", "event" => "stopped"},
      {"seq" => Int64::MAX, "type" => "event", "event" => "stopped"},
      {"seq" => 1, "type" => "request"},
      {"seq" => 1, "type" => "response", "request_seq" => 1},
      {"seq" => 1, "type" => "event"},
      {"seq" => 1, "type" => "bogus", "event" => "stopped"},
    ]

    invalid.each do |value|
      local = Adamantine::Dap::FrameDecoder.new
      expect_raises(Adamantine::Dap::ProtocolError) do
        local.feed(dap_wire_frame(value.to_json).to_slice)
      end
    end
  end

  it "accepts a well-formed failed response but rejects missing success or command" do
    failed = JSON.parse({"seq" => 1, "type" => "response", "request_seq" => 7,
                         "command" => "launch", "success" => false,
                         "message" => "launch rejected"}.to_json)
    Adamantine::Dap::Protocol.validate_payload!(failed).success.should be_false

    [
      {"seq" => 1, "type" => "response", "request_seq" => 7, "command" => "launch"},
      {"seq" => 1, "type" => "response", "request_seq" => 7, "success" => true},
      {"seq" => 1, "type" => "response", "request_seq" => 7, "command" => "launch", "success" => "false"},
    ].each do |value|
      expect_raises(Adamantine::Dap::ProtocolError) do
        Adamantine::Dap::Protocol.validate_payload!(JSON.parse(value.to_json))
      end
    end
  end

  it "rejects duplicate JSON object keys rather than accepting the last value" do
    duplicate = %({"seq":1,"seq":2,"type":"event","event":"output"})
    error = expect_raises(Adamantine::Dap::ProtocolError) do
      Adamantine::Dap::FrameDecoder.new.feed(dap_wire_frame(duplicate).to_slice)
    end
    error.message.should eq("duplicate key in DAP JSON object")
  end

  it "does not retain input after rejecting a frame" do
    decoder = Adamantine::Dap::FrameDecoder.new(max_message_bytes: 4)
    expect_raises(Adamantine::Dap::ProtocolError) do
      decoder.feed("Content-Length: 5\r\n\r\n".to_slice)
    end
    decoder.buffered_bytes.should eq(0)
  end
end
