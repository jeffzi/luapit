---@diagnostic disable: need-check-nil, duplicate-set-field, redundant-parameter, missing-parameter
local path = require("pl.path")

describe("engines.love2d", function()
   local love2d

   local CWD = path.currentdir()
   local FIXTURE_DIR = path.join(CWD, "tests", "fixtures")
   local LIBV1_DIR = path.join(FIXTURE_DIR, "targets", "libv1")
   local LIBV2_DIR = path.join(FIXTURE_DIR, "targets", "libv2")
   local SORT_BENCH = path.join(FIXTURE_DIR, "benchmarks", "sort_bench.lua")
   local DEFAULT_TARGETS = { { path = LIBV1_DIR, name = "libv1" } }

   --- Temporarily stub engines.find_module_path, run a callback, then restore.
   --- @param stub fun(original: function): function Factory receiving the original; returns the stub.
   --- @param callback function Code to run while stub is active.
   local function with_find_module_stub(stub, callback)
      local engines = require("luabench.engines")
      local original = engines.find_module_path
      engines.find_module_path = stub(original)
      local ok, err = pcall(callback)
      engines.find_module_path = original
      if not ok then
         error(err, 2)
      end
   end

   before_each(function()
      package.loaded["luabench.engines.love2d"] = nil
      love2d = require("luabench.engines.love2d")
   end)

   -- run() error handling tests

   it("run returns nil and error when scaffold fails", function()
      with_find_module_stub(function()
         return function()
            return nil, "module source not found: luamark"
         end
      end, function()
         local results, err = love2d.run("/usr/bin/love", SORT_BENCH, DEFAULT_TARGETS, "", {})

         assert.is_nil(results)
         assert.is_string(err)
         assert.matches("luamark", err)
      end)
   end)

   -- Integration test (conditional)

   it("run with actual love binary returns results", function()
      local subprocess = require("luabench.subprocess")
      local love_path = subprocess.resolve_runtime("love")
      if love_path == nil then
         pending("love not found in PATH")
         return
      end

      local results, err = love2d.run(
         love_path,
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } },
         "",
         { rounds = 1 }
      )

      assert.is_nil(err)
      assert.is_table(results)
      assert.is_true(#results >= 1)
      local r = results[1]
      assert.is_string(r.name)
      assert.is_number(r.median)
      assert.is_number(r.rounds)
   end)
end)
