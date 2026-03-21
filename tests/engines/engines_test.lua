---@diagnostic disable: need-check-nil, duplicate-set-field

describe("engines", function()
   local engines

   local TWO_TARGETS = {
      { path = "/tmp/bench/a", name = "target_a" },
      { path = "/tmp/bench/b", name = "target_b" },
   }
   local DEFAULT_OPTS = { rounds = 5 }

   --- Call append_benchmark_body with standard fixtures, return concatenated output.
   --- @param targets? table Target list (defaults to TWO_TARGETS).
   --- @return string output Generated code joined by newlines.
   local function run_append_benchmark(targets)
      local parts = {}
      engines.append_benchmark_body(
         parts,
         "bench_file.lua",
         targets or TWO_TARGETS,
         "my_spec",
         DEFAULT_OPTS
      )
      return table.concat(parts, "\n")
   end

   --- Assert that output contains the benchmark-body patterns shared by both
   --- append_benchmark_body and append_wrapper_body.
   --- @param output string Generated code to check.
   local function assert_benchmark_patterns(output)
      assert.matches("compare_time", output)
      assert.matches("target_a", output)
      assert.matches("target_b", output)
      assert.matches("package%.path", output)
      assert.matches("dofile", output)
   end

   before_each(function()
      package.loaded["luabench.engines"] = nil
      engines = require("luabench.engines")
   end)

   -- detect() tests

   for _, case in ipairs({
      { input = "love", expected = "love", desc = "love name" },
      { input = "defold", expected = "defold", desc = "defold name" },
      { input = "defold-html5", expected = "defold-html5", desc = "defold-html5 name" },
      { input = "/usr/bin/love", expected = "love", desc = "love absolute path" },
      { input = "/usr/bin/love.exe", expected = "love", desc = "love path with .exe suffix" },
   }) do
      it("detect returns " .. case.expected .. " for " .. case.desc, function()
         local result = engines.detect(case.input)

         assert.are_equal(case.expected, result)
      end)
   end

   for _, case in ipairs({
      { input = "luajit", desc = "luajit" },
      { input = "lua", desc = "lua" },
      { input = "/usr/bin/lua", desc = "lua absolute path" },
   }) do
      it("detect returns nil for unknown runtime " .. case.desc, function()
         local result = engines.detect(case.input)

         assert.is_nil(result)
      end)
   end

   -- get_adapter() tests

   for _, case in ipairs({
      { engine = "love", desc = "love2d" },
      { engine = "defold", desc = "defold" },
      { engine = "defold-html5", desc = "defold_html5" },
   }) do
      it(
         "get_adapter for " .. case.engine .. " returns the " .. case.desc .. " adapter module",
         function()
            local adapter = engines.get_adapter(case.engine)

            assert.is_table(adapter)
            assert.is_function(adapter.run)
         end
      )
   end

   -- append_benchmark_body() tests

   it("append_benchmark_body generates benchmark loading code with compare_time", function()
      local output = run_append_benchmark()

      assert_benchmark_patterns(output)
   end)

   it("append_benchmark_body does not generate file-write code", function()
      local output = run_append_benchmark({ { path = "/tmp/bench/a", name = "target_a" } })

      assert.is_nil(string.find(output, "io%.open"))
      assert.is_nil(string.find(output, "result_path"))
   end)

   -- append_wrapper_body() backward compatibility tests

   it("append_wrapper_body generates both compare_time and file-write code", function()
      local parts = {}
      engines.append_wrapper_body(
         parts,
         "bench_file.lua",
         TWO_TARGETS,
         "my_spec",
         DEFAULT_OPTS,
         "/tmp/results.json"
      )

      local output = table.concat(parts, "\n")
      assert_benchmark_patterns(output)
      assert.matches("io%.open", output)
   end)

   -- find_module_path() tests

   for _, modname in ipairs({ "luamark", "dkjson" }) do
      it("find_module_path returns path ending in " .. modname .. ".lua for " .. modname, function()
         local result = engines.find_module_path(modname)

         assert.is_string(result)
         assert.matches(modname .. "%.lua$", result)
      end)
   end

   it("find_module_path returns nil and error for nonexistent module", function()
      local result, err = engines.find_module_path("nonexistent_module_xyz")

      assert.is_nil(result)
      assert.is_string(err)
      assert.matches("nonexistent_module_xyz", err)
   end)
end)
