---@diagnostic disable: need-check-nil, duplicate-set-field
local lfs = require("lfs")

describe("runner", function()
   local runner

   local CWD = lfs.currentdir()
   local FIXTURE_DIR = CWD .. "/tests/fixtures"
   local LIBV1_DIR = FIXTURE_DIR .. "/targets/libv1"
   local LIBV2_DIR = FIXTURE_DIR .. "/targets/libv2"
   local SORT_BENCH = FIXTURE_DIR .. "/benchmarks/sort_bench.lua"

   before_each(function()
      runner = require("luabench.runner")
   end)

   it(
      "with_target on success prepends path, cleans loaded, restores path, and returns result",
      function()
         local original_path = package.path
         local captured_path

         local result = runner.with_target(LIBV1_DIR, function()
            captured_path = package.path
            require("mylib")
            return "hello"
         end)

         assert.matches(LIBV1_DIR, captured_path)
         assert.is_nil(package.loaded["mylib"])
         assert.are_equal(original_path, package.path)
         assert.are_equal("hello", result)
      end
   )

   it("with_target on error restores path and returns nil with error message", function()
      local original_path = package.path

      local result, err = runner.with_target(LIBV1_DIR, function()
         error("boom")
      end)

      assert.are_equal(original_path, package.path)
      assert.is_nil(result)
      assert.matches("boom", err)
   end)

   -- Target isolation: different targets load different modules

   it("with_target loads different modules from different target dirs", function()
      local v1_result
      runner.with_target(LIBV1_DIR, function()
         v1_result = require("mylib").value()
      end)

      local v2_result
      runner.with_target(LIBV2_DIR, function()
         v2_result = require("mylib").value()
      end)

      assert.are_equal(1, v1_result)
      assert.are_equal(2, v2_result)
   end)

   -- run() orchestration with stubs

   --- Set up luamark and io stubs for run() tests.
   --- @return table spy_state, fun() teardown
   local function setup_run_stubs()
      local luamark = require("luamark")
      local originals = {
         compare = luamark.compare_time,
         render = luamark.render,
         write = io.write,
         stderr = io.stderr,
      }

      local spy_state = { compare_calls = {}, output = {} }

      luamark.compare_time = function(funcs)
         spy_state.compare_calls[#spy_state.compare_calls + 1] = funcs
         return {
            {
               name = "libv1",
               median = 0.001,
               ci_lower = 0.0009,
               ci_upper = 0.0011,
               rounds = 100,
               rank = 1,
               relative = 1.0,
            },
            {
               name = "libv2",
               median = 0.002,
               ci_lower = 0.0019,
               ci_upper = 0.0021,
               rounds = 100,
               rank = 2,
               relative = 2.0,
            },
         }
      end
      luamark.render = function()
         return "rendered"
      end
      io.write = function(s) -- luacheck: ignore 122
         spy_state.output[#spy_state.output + 1] = s
      end
      io.stderr = io.tmpfile()

      local function teardown()
         luamark.compare_time = originals.compare
         luamark.render = originals.render
         io.write = originals.write -- luacheck: ignore 122
         io.stderr:close()
         io.stderr = originals.stderr
      end

      return spy_state, teardown
   end

   --- Read captured stderr contents.
   --- @return string
   local function read_stderr()
      io.stderr:seek("set")
      return io.stderr:read("*a")
   end

   it("run calls compare_time with target specs and renders output with header", function()
      local spy_state, teardown = setup_run_stubs()

      local results = runner.run(
         { SORT_BENCH },
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } }
      )

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
      local compare_args = spy_state.compare_calls[1]
      assert.is_not_nil(compare_args["libv1"])
      assert.is_not_nil(compare_args["libv2"])
      local combined = table.concat(spy_state.output)
      local header_prefix = string.char(0xe2, 0x96, 0x8c) -- U+258C ▌
      assert.matches(header_prefix, combined)
      assert.matches("sort", combined)
      assert.matches("rendered", combined)
      assert.is_not_nil(results)
      assert.is_table(results)
   end)

   it("run skips benchmark when load_benchmark returns nil for all targets", function()
      local spy_state, teardown = setup_run_stubs()

      local targets = {
         { path = LIBV1_DIR, name = "libv1" },
         { path = LIBV2_DIR, name = "libv2" },
      }
      runner.run({ FIXTURE_DIR .. "/nonexistent_bench.lua" }, targets)

      teardown()

      assert.are_equal(0, #spy_state.compare_calls)
   end)

   it("run skips target when load fails and continues with remaining targets", function()
      local spy_state, teardown = setup_run_stubs()

      local targets = {
         { path = LIBV1_DIR, name = "libv1" },
         { path = "/nonexistent/target", name = "bad" },
      }
      runner.run({ SORT_BENCH }, targets)

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
      assert.is_not_nil(spy_state.compare_calls[1]["libv1"])
   end)

   it("run handles named-Specs file calling compare_time per named Spec", function()
      local spy_state, teardown = setup_run_stubs()
      local multi_bench = FIXTURE_DIR .. "/benchmarks/multi_bench.lua"

      runner.run(
         { multi_bench },
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } }
      )

      teardown()

      assert.are_equal(2, #spy_state.compare_calls)
   end)

   it("run forwards Spec hook fields to compare_time", function()
      local spy_state, teardown = setup_run_stubs()
      local hooks_bench = FIXTURE_DIR .. "/benchmarks/hooks_bench.lua"

      runner.run({ hooks_bench }, { { path = LIBV1_DIR, name = "libv1" } })

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
      local spec = spy_state.compare_calls[1]["libv1"]
      assert.is_function(spec.fn)
      assert.is_function(spec.before)
      assert.is_function(spec.after)
      assert.is_true(spec.baseline)
   end)

   it("run collects spec names from all targets, not just the first", function()
      local spy_state, teardown = setup_run_stubs()
      local asym_bench = FIXTURE_DIR .. "/benchmarks/asymmetric_bench.lua"

      runner.run(
         { asym_bench },
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } }
      )

      teardown()

      assert.are_equal(2, #spy_state.compare_calls)
   end)

   it("run catches compare_time errors and continues", function()
      local _, teardown = setup_run_stubs()
      local luamark = require("luamark")
      local call_count = 0
      luamark.compare_time = function()
         call_count = call_count + 1
         if call_count == 1 then
            error("compare failed")
         end
         return {
            {
               name = "libv1",
               median = 0.001,
               ci_lower = 0.0009,
               ci_upper = 0.0011,
               rounds = 100,
               rank = 1,
               relative = 1.0,
            },
         }
      end

      runner.run(
         { SORT_BENCH, FIXTURE_DIR .. "/benchmarks/sort_bench.lua" },
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } }
      )

      local stderr_output = read_stderr()
      teardown()

      assert.matches("warning", stderr_output)
   end)

   it("run returns flat results array with file, spec, and targets fields", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run(
         { SORT_BENCH },
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } }
      )

      teardown()

      assert.is_table(results)
      assert.are_equal(1, #results)
      local entry = results[1]
      assert.is_string(entry.file)
      assert.matches("sort", entry.file)
      assert.is_string(entry.spec)
      assert.is_table(entry.targets)
      assert.are_equal(2, #entry.targets)
   end)

   it("run maps luamark Result fields to stat entries with ratio field", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run(
         { SORT_BENCH },
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } }
      )

      teardown()

      local stat = results[1].targets[1]
      assert.is_string(stat.name)
      assert.is_number(stat.median)
      assert.is_number(stat.ci_lower)
      assert.is_number(stat.ci_upper)
      assert.is_number(stat.rounds)
      assert.is_number(stat.rank)
      assert.is_number(stat.ratio)
      assert.are_equal(1.0, stat.ratio)
      local stat2 = results[1].targets[2]
      assert.are_equal(2.0, stat2.ratio)
   end)

   it("run maps empty spec name to default in returned results", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run(
         { SORT_BENCH },
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } }
      )

      teardown()

      assert.are_equal("default", results[1].spec)
   end)
end)
