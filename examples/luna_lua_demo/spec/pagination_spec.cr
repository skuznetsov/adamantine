require "spec"
require "../src/pagination"

describe LunaLuaDemo::Pagination do
  it "returns no more than the requested count for an interior page" do
    items = %w[red green blue amber indigo]

    LunaLuaDemo::Pagination.page(items, 1, 2).should eq(%w[green blue])
  end

  it "returns one item for an interior one-item page" do
    items = %w[red green blue amber indigo]

    LunaLuaDemo::Pagination.page(items, 2, 1).should eq(["blue"])
  end

  it "returns all remaining items when the requested count reaches past the end" do
    items = %w[red green blue amber indigo]

    LunaLuaDemo::Pagination.page(items, 3, 4).should eq(%w[amber indigo])
  end

  it "returns the final item at the end boundary" do
    LunaLuaDemo::Pagination.page(%w[red green], 1, 1).should eq(["green"])
  end

  it "returns the empty page for empty input" do
    LunaLuaDemo::Pagination.page([] of String, 0, 3).should eq([] of String)
  end

  it "returns the empty page when the offset equals the item count" do
    LunaLuaDemo::Pagination.page(%w[red green], 2, 1).should eq([] of String)
  end

  it "returns the empty page when the offset is beyond the item count" do
    LunaLuaDemo::Pagination.page(%w[red green], 3, 1).should eq([] of String)
  end

  it "returns the empty page for a zero count" do
    LunaLuaDemo::Pagination.page(%w[red green], 1, 0).should eq([] of String)
  end

  it "rejects a negative offset" do
    expect_raises(ArgumentError, "offset must be non-negative") do
      LunaLuaDemo::Pagination.page(%w[red green], -1, 1)
    end
  end

  it "rejects a negative count" do
    expect_raises(ArgumentError, "limit must be non-negative") do
      LunaLuaDemo::Pagination.page(%w[red green], 0, -1)
    end
  end
end
