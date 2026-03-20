local lfs = require("lfs")

describe("discover", function()
   local discover

   local fixtures_dir = "tests/fixtures/benchmarks"
   local abs_fixtures

   before_each(function()
      discover = require("luabench.discover").discover
      abs_fixtures = lfs.currentdir() .. "/" .. fixtures_dir
   end)

   it("returns empty table for empty input", function()
      local result = discover({})

      assert.are_same({}, result)
   end)

   it("returns absolute path for a single bench file", function()
      local result = discover({ fixtures_dir .. "/sort_bench.lua" })

      assert.are_same({ abs_fixtures .. "/sort_bench.lua" }, result)
   end)

   it("ignores non-benchmark lua files", function()
      local result = discover({ fixtures_dir .. "/helper.lua" })

      assert.are_same({}, result)
   end)

   it("skips nonexistent paths gracefully", function()
      local result = discover({ "nonexistent/path" })

      assert.are_same({}, result)
   end)

   it("finds nested bench files recursively in directories", function()
      local result = discover({ fixtures_dir })

      assert.is_true(#result >= 3)
      for i = 1, #result do
         assert.matches("_bench%.lua$", result[i])
      end
   end)

   it("returns results sorted alphabetically", function()
      local result = discover({ fixtures_dir })

      for i = 2, #result do
         assert.is_true(result[i - 1] <= result[i])
      end
   end)

   it("accepts a mix of files and directories", function()
      local result = discover({
         fixtures_dir .. "/sort_bench.lua",
         fixtures_dir .. "/sub",
      })

      assert.are_equal(2, #result)
      assert.matches("sort_bench%.lua$", result[1])
      assert.matches("nested_bench%.lua$", result[2])
   end)

   it("returns absolute paths for relative inputs", function()
      local result = discover({ fixtures_dir .. "/sort_bench.lua" })

      assert.matches("^/", result[1])
   end)
end)
