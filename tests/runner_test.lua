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

   -- snapshot_loaded / restore_loaded isolation

   it("with_target restores package.path after successful call", function()
      local original_path = package.path

      runner.with_target(LIBV1_DIR, function()
         return true
      end)

      assert.are_equal(original_path, package.path)
   end)

   it("with_target restores package.path even when fn errors", function()
      local original_path = package.path

      runner.with_target(LIBV1_DIR, function()
         error("intentional error")
      end)

      assert.are_equal(original_path, package.path)
   end)

   it("with_target cleans package.loaded after fn completes", function()
      runner.with_target(LIBV1_DIR, function()
         require("mylib")
      end)

      assert.is_nil(package.loaded["mylib"])
   end)

   it("with_target prepends target dir to package.path inside fn", function()
      local captured_path

      runner.with_target(LIBV1_DIR, function()
         captured_path = package.path
      end)

      assert.matches(LIBV1_DIR, captured_path)
   end)

   it("with_target returns fn result on success", function()
      local result = runner.with_target(LIBV1_DIR, function()
         return "hello"
      end)

      assert.are_equal("hello", result)
   end)

   it("with_target returns nil and error message on fn error", function()
      local result, err = runner.with_target(LIBV1_DIR, function()
         error("boom")
      end)

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

   it("run calls compare_time and render for a single-Spec benchmark", function()
      local luamark = require("luamark")
      local original_compare = luamark.compare_time
      local original_render = luamark.render
      local compare_called = false
      local compare_args
      local render_called = false

      luamark.compare_time = function(funcs)
         compare_called = true
         compare_args = funcs
         return {}
      end
      luamark.render = function()
         render_called = true
         return "rendered"
      end

      local original_write = io.write
      local output = {}
      io.write = function(s) -- luacheck: ignore 122
         output[#output + 1] = s
      end

      runner.run({ SORT_BENCH }, { LIBV1_DIR, LIBV2_DIR })

      luamark.compare_time = original_compare
      luamark.render = original_render
      io.write = original_write -- luacheck: ignore 122

      assert.is_true(compare_called)
      assert.is_true(render_called)
      assert.is_not_nil(compare_args["libv1"])
      assert.is_not_nil(compare_args["libv2"])
   end)

   it("run prints header containing benchmark identity", function()
      local luamark = require("luamark")
      local original_compare = luamark.compare_time
      local original_render = luamark.render
      luamark.compare_time = function()
         return {}
      end
      luamark.render = function()
         return "rendered"
      end

      local original_write = io.write
      local output = {}
      io.write = function(s) -- luacheck: ignore 122
         output[#output + 1] = s
      end

      runner.run({ SORT_BENCH }, { LIBV1_DIR, LIBV2_DIR })

      luamark.compare_time = original_compare
      luamark.render = original_render
      io.write = original_write -- luacheck: ignore 122

      local combined = table.concat(output)
      assert.matches("sort", combined)
   end)

   it("run skips benchmark when load_benchmark returns nil for all targets", function()
      local luamark = require("luamark")
      local original_compare = luamark.compare_time
      local compare_called = false
      luamark.compare_time = function()
         compare_called = true
         return {}
      end

      local original_stderr = io.stderr
      io.stderr = io.tmpfile()

      runner.run({ FIXTURE_DIR .. "/nonexistent_bench.lua" }, { LIBV1_DIR, LIBV2_DIR })

      io.stderr:close()
      io.stderr = original_stderr
      luamark.compare_time = original_compare

      assert.is_false(compare_called)
   end)

   it("run skips target when load fails and continues with remaining targets", function()
      local luamark = require("luamark")
      local original_compare = luamark.compare_time
      local original_render = luamark.render
      local compare_args

      luamark.compare_time = function(funcs)
         compare_args = funcs
         return {}
      end
      luamark.render = function()
         return "rendered"
      end

      local original_write = io.write
      io.write = function() end -- luacheck: ignore 122

      local original_stderr = io.stderr
      io.stderr = io.tmpfile()

      -- Use one valid target and one nonexistent target
      runner.run({ SORT_BENCH }, { LIBV1_DIR, "/nonexistent/target" })

      io.stderr:close()
      io.stderr = original_stderr
      luamark.compare_time = original_compare
      luamark.render = original_render
      io.write = original_write -- luacheck: ignore 122

      assert.is_not_nil(compare_args)
      assert.is_not_nil(compare_args["libv1"])
   end)

   it("run handles named-Specs file calling compare_time per named Spec", function()
      local luamark = require("luamark")
      local original_compare = luamark.compare_time
      local original_render = luamark.render
      local compare_call_count = 0

      luamark.compare_time = function()
         compare_call_count = compare_call_count + 1
         return {}
      end
      luamark.render = function()
         return "rendered"
      end

      local original_write = io.write
      io.write = function() end -- luacheck: ignore 122

      local multi_bench = FIXTURE_DIR .. "/benchmarks/multi_bench.lua"
      runner.run({ multi_bench }, { LIBV1_DIR, LIBV2_DIR })

      luamark.compare_time = original_compare
      luamark.render = original_render
      io.write = original_write -- luacheck: ignore 122

      -- multi_bench.lua has 2 named Specs (a and b), so compare_time should be called twice
      assert.are_equal(2, compare_call_count)
   end)

   it("run catches compare_time errors and continues", function()
      local luamark = require("luamark")
      local original_compare = luamark.compare_time
      local original_render = luamark.render
      local call_count = 0

      luamark.compare_time = function()
         call_count = call_count + 1
         if call_count == 1 then
            error("compare failed")
         end
         return {}
      end
      luamark.render = function()
         return "rendered"
      end

      local original_write = io.write
      io.write = function() end -- luacheck: ignore 122

      local original_stderr = io.stderr
      io.stderr = io.tmpfile()

      -- Two bench files: first will fail at compare_time, second should succeed
      runner.run(
         { SORT_BENCH, FIXTURE_DIR .. "/benchmarks/sort_bench.lua" },
         { LIBV1_DIR, LIBV2_DIR }
      )

      io.stderr:seek("set")
      local stderr_output = io.stderr:read("*a")
      io.stderr:close()
      io.stderr = original_stderr
      luamark.compare_time = original_compare
      luamark.render = original_render
      io.write = original_write -- luacheck: ignore 122

      assert.matches("warning", stderr_output)
   end)
end)
