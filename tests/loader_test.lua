---@diagnostic disable: need-check-nil
local path = require("pl.path")

local loader = require("luabench.loader")

local FIXTURE_DIR = path.currentdir() .. "/tests/fixtures"

describe("loader", function()
   local original_stderr

   before_each(function()
      original_stderr = io.stderr
      io.stderr = io.tmpfile()
   end)

   after_each(function()
      io.stderr:close()
      io.stderr = original_stderr
   end)

   --- Read captured stderr contents.
   --- @return string
   local function read_stderr()
      io.stderr:seek("set")
      return io.stderr:read("*a")
   end

   -- load_benchmark: normalized spec map

   it("load_benchmark with single Spec file returns spec keyed by empty string", function()
      local filepath = FIXTURE_DIR .. "/benchmarks/sort_bench.lua"

      local result = loader.load_benchmark(filepath)

      assert.is_not_nil(result)
      assert.is_not_nil(result[""])
      assert.is_function(result[""].fn)
   end)

   it("load_benchmark with named Specs file returns specs keyed by name", function()
      local filepath = FIXTURE_DIR .. "/benchmarks/multi_bench.lua"

      local result = loader.load_benchmark(filepath)

      assert.is_not_nil(result)
      assert.is_not_nil(result.a)
      assert.is_not_nil(result.b)
      assert.is_function(result.a.fn)
      assert.is_function(result.b.fn)
   end)

   -- load_benchmark: error handling (pcall failure path)

   for _, case in ipairs({
      {
         file = "/syntax_error_bench.lua",
         pattern = "syntax_error_bench%.lua",
         desc = "syntax error",
      },
      {
         file = "/nonexistent_bench.lua",
         pattern = "nonexistent_bench%.lua",
         desc = "nonexistent file",
      },
   }) do
      it("load_benchmark with " .. case.desc .. " returns nil and warns to stderr", function()
         local result = loader.load_benchmark(FIXTURE_DIR .. case.file)

         assert.is_nil(result)
         local err = read_stderr()
         assert.matches("warning", err)
         assert.matches(case.pattern, err)
      end)
   end

   -- load_benchmark: non-table return path

   for _, case in ipairs({
      { file = "/nil_return_bench.lua", desc = "nil return" },
      { file = "/string_return_bench.lua", desc = "string return" },
   }) do
      it("load_benchmark with " .. case.desc .. " returns nil and warns to stderr", function()
         local result = loader.load_benchmark(FIXTURE_DIR .. case.file)

         assert.is_nil(result)
         assert.matches("did not return a table", read_stderr())
      end)
   end

   -- bench_id: identity derivation

   for _, case in ipairs({
      {
         filepath = "bench/sort_bench.lua",
         spec_name = "",
         expected = "bench/sort",
         desc = "strips _bench.lua suffix with empty spec name",
      },
      {
         filepath = "sort_bench.lua",
         spec_name = "",
         expected = "sort",
         desc = "strips suffix from bare filename",
      },
      {
         filepath = "bench/sort_bench.lua",
         spec_name = "insertion",
         expected = "bench/sort::insertion",
         desc = "appends ::spec_name for named Specs",
      },
      {
         filepath = "deep/path/algo_bench.lua",
         spec_name = "quick",
         expected = "deep/path/algo::quick",
         desc = "handles deep paths with spec name",
      },
   }) do
      it("bench_id " .. case.desc, function()
         local result = loader.bench_id(case.filepath, case.spec_name)

         assert.are_equal(case.expected, result)
      end)
   end
end)
