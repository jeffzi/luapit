local path = require("pl.path")

describe("discover", function()
   local discover

   local FIXTURES_DIR = "tests/fixtures/benchmarks"
   local ABS_FIXTURES = path.abspath(FIXTURES_DIR)

   before_each(function()
      discover = require("luapit.discover").discover
   end)

   it("discover with empty input returns empty table", function()
      local result = discover({})

      assert.are_same({}, result)
   end)

   it("discover with a single bench file returns its absolute path", function()
      local result = discover({ path.join(FIXTURES_DIR, "sort_bench.lua") })

      assert.are_same({ path.join(ABS_FIXTURES, "sort_bench.lua") }, result)
   end)

   it("discover ignores non-benchmark lua files", function()
      local result = discover({ path.join(FIXTURES_DIR, "helper.lua") })

      assert.are_same({}, result)
   end)

   it("discover with nonexistent path returns empty table", function()
      local result = discover({ "nonexistent/path" })

      assert.are_same({}, result)
   end)

   it("discover with a directory finds nested bench files recursively", function()
      local result = discover({ FIXTURES_DIR })

      assert.is_true(#result >= 3)
      local non_bench = {}
      for _, p in ipairs(result) do
         if not p:match("_bench%.lua$") then
            non_bench[#non_bench + 1] = p
         end
      end
      assert.are_same({}, non_bench)
   end)

   it("discover returns results sorted alphabetically", function()
      local result = discover({ FIXTURES_DIR })

      local sorted = {}
      for i = 1, #result do
         sorted[i] = result[i]
      end
      table.sort(sorted)
      assert.are_same(sorted, result)
   end)

   it("discover with mixed files and directories returns all bench files", function()
      local result = discover({
         path.join(FIXTURES_DIR, "sort_bench.lua"),
         path.join(FIXTURES_DIR, "sub"),
      })

      assert.are_equal(2, #result)
      assert.matches("sort_bench%.lua$", result[1])
      assert.matches("nested_bench%.lua$", result[2])
   end)
end)
