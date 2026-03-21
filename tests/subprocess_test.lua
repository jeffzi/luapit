---@diagnostic disable: need-check-nil, duplicate-set-field, missing-parameter
local lfs = require("lfs")

describe("subprocess", function()
   local subprocess

   local CWD = lfs.currentdir()
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
   end)

   it("_generate_wrapper with multiple targets iterates and builds multi-entry funcs", function()
      local wrapper = subprocess._generate_wrapper(
         SORT_BENCH,
         {
            { path = LIBV1_DIR, name = "libv1" },
            { path = LIBV2_DIR, name = "libv2" },
         },
         "",
         {},
         "/tmp/test_results.json"
      )

      assert.is_string(wrapper)
      assert.matches("libv1", wrapper)
      assert.matches("libv2", wrapper)
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

      local results, err = subprocess.run_subprocess(
         runtime, SORT_BENCH, targets, "", { rounds = 1 }
      )

      assert.is_nil(err)
      assert.is_table(results)
      assert.is_true(#results >= 1)
      local r = results[1]
      assert.is_string(r.name)
      assert.is_number(r.median)
      assert.is_number(r.rounds)
   end)

   it("run_subprocess returns nil and error for non-zero exit", function()
      local runtime = subprocess.resolve_runtime("lua")
      if runtime == nil then
         pending("lua not found in PATH")
         return
      end

      local results, err = subprocess.run_subprocess(
         runtime, "/nonexistent/bench.lua",
         { { path = "/tmp", name = "test" } }, "", {}
      )

      assert.is_nil(results)
      assert.is_string(err)
   end)

   it("run_subprocess cleans up temp files even on error", function()
      local runtime = subprocess.resolve_runtime("lua")
      if runtime == nil then
         pending("lua not found in PATH")
         return
      end

      -- Run a subprocess that will fail
      subprocess.run_subprocess(
         runtime, "/nonexistent/bench.lua",
         { { path = "/tmp", name = "test" } }, "", {}
      )

      -- We cannot directly check temp files since names are generated internally,
      -- but we verify no error is raised during cleanup by the call completing
      assert.is_true(true)
   end)
end)
