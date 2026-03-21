---@diagnostic disable: need-check-nil, duplicate-set-field, missing-parameter, redundant-parameter
local path = require("pl.path")

describe("subprocess", function()
   local subprocess

   local CWD = path.currentdir()
   local FIXTURE_DIR = CWD .. "/tests/fixtures"
   local LIBV1_DIR = FIXTURE_DIR .. "/targets/libv1"
   local LIBV2_DIR = FIXTURE_DIR .. "/targets/libv2"
   local SORT_BENCH = FIXTURE_DIR .. "/benchmarks/sort_bench.lua"

   before_each(function()
      subprocess = require("luabench.subprocess")
   end)

   -- resolve_runtime tests

   it("resolve_runtime with known runtime returns a path", function()
      local result = subprocess.resolve_runtime("lua")

      assert.is_string(result)
      assert.matches("lua", result)
   end)

   it("resolve_runtime with nonexistent runtime returns nil and error", function()
      local result, err = subprocess.resolve_runtime("nonexistent_runtime_xyz_42")

      assert.is_nil(result)
      assert.is_string(err)
      assert.matches("runtime not found", err)
   end)

   it("resolve_runtime with empty string returns nil and error", function()
      local result, err = subprocess.resolve_runtime("")

      assert.is_nil(result)
      assert.is_string(err)
   end)

   -- generate_wrapper tests

   it("_generate_wrapper produces script with expected patterns", function()
      local wrapper = subprocess._generate_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {},
         "/tmp/test_results.json"
      )

      assert.is_string(wrapper)
      assert.matches("package%.path", wrapper)
      assert.matches("luamark", wrapper)
      assert.matches("dkjson", wrapper)
      assert.matches("dofile", wrapper)
      assert.matches("compare_time", wrapper)
      assert.matches("encode", wrapper)
      local has_nil_guard = wrapper:find("if not f") or wrapper:find("assert%(f")
      assert.is_not_nil(has_nil_guard, "generated wrapper must nil-check the io.open result")
   end)

   it("_generate_wrapper with multiple targets includes all target names", function()
      local wrapper = subprocess._generate_wrapper(SORT_BENCH, {
         { path = LIBV1_DIR, name = "libv1" },
         { path = LIBV2_DIR, name = "libv2" },
      }, "", {}, "/tmp/test_results.json")

      assert.is_string(wrapper)
      assert.matches("libv1", wrapper)
      assert.matches("libv2", wrapper)
   end)

   it("_generate_wrapper with multiple params emits them in sorted order", function()
      local wrapper = subprocess._generate_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         { params = { z = { 1 }, a = { 2 }, m = { 3 } } },
         "/tmp/test_results.json"
      )

      assert.is_string(wrapper)
      local pos_a = wrapper:find('["a"]', 1, true)
         or wrapper:find("%.a", 1, true)
         or wrapper:find('%["a"%]')
      local pos_m = wrapper:find('["m"]', 1, true)
         or wrapper:find("%.m", 1, true)
         or wrapper:find('%["m"%]')
      local pos_z = wrapper:find('["z"]', 1, true)
         or wrapper:find("%.z", 1, true)
         or wrapper:find('%["z"%]')
      assert.is_not_nil(pos_a, "expected param 'a' in wrapper")
      assert.is_not_nil(pos_m, "expected param 'm' in wrapper")
      assert.is_not_nil(pos_z, "expected param 'z' in wrapper")
      assert.is_true(pos_a < pos_m, "param 'a' must appear before 'm' (sorted order)")
      assert.is_true(pos_m < pos_z, "param 'm' must appear before 'z' (sorted order)")
   end)

   -- run_subprocess end-to-end test

   it("run_subprocess with multiple targets returns results with expected fields", function()
      local runtime = subprocess.resolve_runtime("lua")
      if runtime == nil then
         pending("lua not found in PATH")
         return
      end

      local targets = {
         { path = LIBV1_DIR, name = "libv1" },
         { path = LIBV2_DIR, name = "libv2" },
      }

      local results, err =
         subprocess.run_subprocess(runtime, SORT_BENCH, targets, "", { rounds = 1 })

      assert.is_nil(err)
      assert.is_table(results)
      assert.is_true(#results >= 1)
      local r = results[1]
      assert.is_string(r.name)
      assert.is_number(r.median)
      assert.is_number(r.rounds)
   end)

   it("run_subprocess cleans up temporary files after execution", function()
      local runtime = subprocess.resolve_runtime("lua")
      if runtime == nil then
         pending("lua not found in PATH")
         return
      end

      local targets = {
         { path = LIBV1_DIR, name = "libv1" },
         { path = LIBV2_DIR, name = "libv2" },
      }

      -- Intercept os.tmpname to track base temp files it creates
      local base_files = {}
      local original_tmpname = os.tmpname
      os.tmpname = function() --luacheck: ignore 122
         local name = original_tmpname()
         table.insert(base_files, name)
         return name
      end

      local ok, call_err =
         pcall(subprocess.run_subprocess, runtime, SORT_BENCH, targets, "", { rounds = 1 })

      os.tmpname = original_tmpname --luacheck: ignore 122

      assert.is_true(ok, "run_subprocess raised: " .. tostring(call_err))
      assert.is_true(#base_files >= 2, "expected at least 2 tmpname calls")

      for _, tmp in ipairs(base_files) do
         local f = io.open(tmp, "r")
         if f then
            f:close()
            os.remove(tmp)
         end
         assert.is_nil(f, "orphan temp file was not removed: " .. tmp)
      end
   end)

   it("run_subprocess returns nil and error for non-zero exit", function()
      local runtime = subprocess.resolve_runtime("lua")
      if runtime == nil then
         pending("lua not found in PATH")
         return
      end

      local results, err = subprocess.run_subprocess(
         runtime,
         "/nonexistent/bench.lua",
         { { path = "/tmp", name = "test" } },
         "",
         {}
      )

      assert.is_nil(results)
      assert.is_string(err)
      assert.matches("bench%.lua", err)
   end)
end)
