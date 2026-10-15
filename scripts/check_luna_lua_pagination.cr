require "pagination"

module PaginationBoundaryChecker
  struct Payload
    getter tag : String

    def initialize(@tag : String)
    end

    def ==(other : self) : Bool
      @tag == other.tag
    end
  end

  def self.expected_by_indices(items : Array(T), offset : Int32, limit : Int32) : Array(T) forall T
    selected = [] of T
    items.each_with_index do |item, index|
      if index >= offset && selected.size < limit
        selected << item
      end
    end
    selected
  end

  def self.check_case(label : String, items : Array(T), offset : Int32, limit : Int32) forall T
    expected = expected_by_indices(items, offset, limit)
    actual = LunaLuaDemo::Pagination.page(items, offset, limit)
    unless actual == expected
      abort "FAIL #{label}: size=#{items.size} offset=#{offset} limit=#{limit}; expected=#{expected.inspect}; actual=#{actual.inspect}"
    end
  end

  def self.check_all_cases(label : String, items : Array(T)) forall T
    limits = [0, 1, 2, items.size, items.size + 1, Int32::MAX]
    unique_limits = [] of Int32
    limits.each do |limit|
      unique_limits << limit unless unique_limits.includes?(limit)
    end

    (0..(items.size + 2)).each do |offset|
      unique_limits.each do |limit|
        check_case(label, items, offset, limit)
      end
    end
  end

  def self.expect_argument_error(items : Array(String), offset : Int32, limit : Int32, expected_message : String)
    begin
      LunaLuaDemo::Pagination.page(items, offset, limit)
    rescue error : ArgumentError
      unless error.message == expected_message
        abort "FAIL negative-input error: expected #{expected_message.inspect}, got #{error.message.inspect}"
      end
      return
    end

    abort "FAIL negative-input error: expected ArgumentError(#{expected_message.inspect}) for offset=#{offset} limit=#{limit}"
  end

  def self.run(source_path : String)
    unless File.file?(source_path)
      abort "pagination source does not exist: #{source_path}"
    end

    # Seed the oracle with the known interior-page boundary before the matrix.
    check_case("interior-page", %w[red green blue amber indigo], 1, 2)

    (0..6).each do |size|
      int_items = Array(Int32).new(size) { |index| index * 17 + 3 }
      string_items = Array(String).new(size) { |index| "item-#{index}" }
      payload_items = Array(Payload).new(size) { |index| Payload.new("payload-#{index}") }

      check_all_cases("Int32", int_items)
      check_all_cases("String", string_items)
      check_all_cases("Payload", payload_items)
    end

    expect_argument_error([] of String, -1, 0, "offset must be non-negative")
    expect_argument_error(%w[alpha beta], -1, Int32::MAX, "offset must be non-negative")
    expect_argument_error([] of String, 0, -1, "limit must be non-negative")
    expect_argument_error(%w[alpha beta], Int32::MAX, -1, "limit must be non-negative")

    puts "PASS pagination boundary matrix for #{source_path}"
  end
end

source_path = ARGV[0]?
unless source_path
  abort "usage: CRYSTAL_PATH=<source-directory>:<Crystal lib paths> CRYSTAL_CACHE_DIR=<private-cache> crystal run --link-flags=-fuse-ld=/usr/bin/ld checker.cr -- /absolute/path/pagination.cr"
end

PaginationBoundaryChecker.run(source_path)
