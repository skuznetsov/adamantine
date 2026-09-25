require "spec"
require "../src/adamantine/clipboard"

private class ObservedClipboardBackend < Adamantine::Clipboard::SystemBackend
  def idle? : Bool
    @active_mutex.synchronize { @active_helpers.empty? }
  end
end

# Exercise subprocess plumbing without ever invoking the desktop clipboard.
describe Adamantine::Clipboard::SystemBackend do
  it "reads UTF-8 output at the exact byte limit" do
    backend = Adamantine::Clipboard::SystemBackend.new(read_command: "/usr/bin/printf", read_args: ["é界"], max_bytes: 5)
    result = backend.read
    result.status.should eq Adamantine::Clipboard::Status::Success
    result.text.should eq "é界"
  ensure
    backend.try &.close
  end

  it "preserves the size-limit result when terminating excessive output" do
    backend = Adamantine::Clipboard::SystemBackend.new(read_command: "/usr/bin/yes", max_bytes: 32)
    result = backend.read
    result.status.should eq Adamantine::Clipboard::Status::TooLarge
    result.text.should be_nil
  ensure
    backend.try &.close
  end

  it "rejects invalid UTF-8 from a helper" do
    backend = Adamantine::Clipboard::SystemBackend.new(read_command: "/usr/bin/printf", read_args: ["\\377"])
    backend.read.status.should eq Adamantine::Clipboard::Status::InvalidEncoding
  ensure
    backend.try &.close
  end

  it "reports a failed helper without returning its output" do
    backend = Adamantine::Clipboard::SystemBackend.new(read_command: "/usr/bin/false")
    result = backend.read
    result.status.should eq Adamantine::Clipboard::Status::Failed
    result.text.should be_nil
  ensure
    backend.try &.close
  end

  it "times out a helper within a bounded interval" do
    backend = ObservedClipboardBackend.new(read_command: "/bin/sleep", read_args: ["2"], timeout: 40.milliseconds)
    started = Time.instant
    backend.read.status.should eq Adamantine::Clipboard::Status::Timeout
    (Time.instant - started).should be < 1.second
    backend.idle?.should be_true
  ensure
    backend.try &.close
  end

  it "cancels an active helper when the backend closes" do
    backend = ObservedClipboardBackend.new(read_command: "/bin/sleep", read_args: ["5"], timeout: 4.seconds)
    completed = Channel(Adamantine::Clipboard::Result).new(1)
    spawn { completed.send(backend.read) }
    sleep 20.milliseconds
    backend.close
    backend.idle?.should be_true
    select
    when result = completed.receive
      result.status.should eq Adamantine::Clipboard::Status::Failed
    when timeout(1.second)
      fail "backend close did not cancel the active clipboard helper"
    end
    backend.read.status.should eq Adamantine::Clipboard::Status::Failed
  ensure
    backend.try &.close
  end

  it "validates copied data before invoking a helper" do
    backend = Adamantine::Clipboard::SystemBackend.new(write_command: "/usr/bin/tee", max_bytes: 5)
    backend.write("é界").status.should eq Adamantine::Clipboard::Status::Success
    backend.write("123456").status.should eq Adamantine::Clipboard::Status::TooLarge
    backend.write(String.new(Bytes[255_u8])).status.should eq Adamantine::Clipboard::Status::InvalidEncoding
  ensure
    backend.try &.close
  end

  it "supports a missing helper as an explicit fallback condition" do
    backend = Adamantine::Clipboard::SystemBackend.new(read_command: "/private/tmp/adamantine-absent-#{Random::Secure.hex(8)}")
    backend.read.status.should eq Adamantine::Clipboard::Status::Unsupported
  ensure
    backend.try &.close
  end
end
