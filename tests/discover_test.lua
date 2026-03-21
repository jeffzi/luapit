local path = require("pl.path")

describe("discover", function()
   local discover

   local FIXTURES_DIR = "tests/fixtures/benchmarks"
   local ABS_FIXTURES = path.currentdir() .. "/" .. FIXTURES_DIR

   before_each(function()
      discover = require("luabench.discover").discover
   end)

   it("returns empty table for empty input", function()
      local result = discover({})

      assert.are_same({}, result)
   end)

   it("returns absolute path for a single bench file", function()
      local result = discover({ FIXTURES_DIR .. "/sort_bench.lua" })

      assert.are_same({ ABS_FIXTURES .. "/sort_bench.lua" }, result)
   end)

   it("ignores non-benchmark lua files", function()
      local result = discover({ FIXTURES_DIR .. "/helper.lua" })

      assert.are_same({}, result)
   end)

   it("skips nonexistent paths gracefully", function()
      local result = discover({ "nonexistent/path" })

      assert.are_same({}, result)
   end)

   it("finds nested bench files recursively in directories", function()
      local result = discover({ FIXTURES_DIR })

      assert.is_true(#result >= 3)
      for i = 1, #result do
         assert.matches("_bench%.lua$", result[i])
      end
   end)

   it("returns results sorted alphabetically", function()
      local result = discover({ FIXTURES_DIR })

      for i = 2, #result do
         assert.is_true(result[i - 1] <= result[i])
      end
   end)

   it("accepts a mix of files and directories", function()
      local result = discover({
         FIXTURES_DIR .. "/sort_bench.lua",
         FIXTURES_DIR .. "/sub",
      })

      assert.are_equal(2, #result)
      assert.matches("sort_bench%.lua$", result[1])
      assert.matches("nested_bench%.lua$", result[2])
   end)
end)
