---@diagnostic disable: need-check-nil, duplicate-set-field, missing-parameter, redundant-parameter, unused-local, unused-vararg
local path = require("pl.path")

describe("subprocess", function()
   local subprocess
   local exec
   local original_exec_run

   local CWD = path.currentdir()
   local FIXTURE_DIR = CWD .. "/tests/fixtures"
   local LIBV1_DIR = FIXTURE_DIR .. "/targets/libv1"
   local LIBV2_DIR = FIXTURE_DIR .. "/targets/libv2"
   local SORT_BENCH = FIXTURE_DIR .. "/benchmarks/sort_bench.lua"

   before_each(function()
      exec = require("luabench.exec")
      original_exec_run = exec.run
      subprocess = require("luabench.subprocess")
   end)

   after_each(function()
      exec.run = original_exec_run
   end)

   -- find_command tests

   it("find_command with known command returns path without CR/LF", function()
      local result = subprocess.find_command("lua")

      assert.is_string(result)
      assert.matches("lua", result)
      -- Path must not contain carriage return or newline (where.exe multi-line guard)
      assert.is_nil(result:find("\r"), "path must not contain CR")
      assert.is_nil(result:find("\n"), "path must not contain LF")
   end)

   it("find_command with nonexistent command returns nil", function()
      local result = subprocess.find_command("nonexistent_xyz_cmd_42")

      assert.is_nil(result)
   end)

   it("find_command extracts first line only from multi-line output", function()
      -- Simulate where.exe multi-line output to verify first-line extraction
      exec.run = function(_cmd)
         return true, "C:\\Windows\\System32\\lua.exe\r\nC:\\Program Files\\Lua\\lua.exe\r\n", ""
      end

      local result = subprocess.find_command("lua")

      assert.is_string(result)
      assert.are_equal("C:\\Windows\\System32\\lua.exe", result)
      assert.is_nil(result:find("\r"), "must not contain CR")
      assert.is_nil(result:find("\n"), "must not contain LF")
   end)

   -- resolve_runtime tests

   it("resolve_runtime with known runtime returns a path", function()
      local result = subprocess.resolve_runtime("lua")

      assert.is_string(result)
      assert.matches("lua", result)
   end)

   it("resolve_runtime with unknown or empty name returns nil and error", function()
      local result, err = subprocess.resolve_runtime("nonexistent_runtime_xyz_42")
      assert.is_nil(result)
      assert.is_string(err)
      assert.matches("runtime not found", err)

      local result2, err2 = subprocess.resolve_runtime("")
      assert.is_nil(result2)
      assert.is_string(err2)
   end)

   -- detect_runtime tests

   it("detect_runtime returns an absolute path to the current interpreter", function()
      local result, err = subprocess.detect_runtime()

      assert.is_nil(err)
      assert.is_string(result)
      assert.matches("lua", result)
   end)

   it("detect_runtime returns nil and error when arg table is missing", function()
      local original_arg = _G.arg
      _G.arg = nil

      local result, err = subprocess.detect_runtime()

      _G.arg = original_arg

      assert.is_nil(result)
      assert.is_string(err)
   end)

   it("detect_runtime returns nil and error when arg has no negative indices", function()
      local original_arg = _G.arg
      _G.arg = { [0] = "script.lua" }

      local result, err = subprocess.detect_runtime()

      _G.arg = original_arg

      assert.is_nil(result)
      assert.is_string(err)
      assert.matches("no interpreter found", err)
   end)

   -- run_subprocess end-to-end tests

   --- Resolve the "lua" runtime or mark the test as pending.
   --- @return string runtime Absolute path to the lua interpreter.
   local function require_lua_runtime()
      local runtime = subprocess.resolve_runtime("lua")
      if runtime == nil then
         pending("lua not found in PATH")
      end
      return runtime --[[@as string]]
   end

   local BOTH_TARGETS = {
      { path = LIBV1_DIR, name = "libv1" },
      { path = LIBV2_DIR, name = "libv2" },
   }

   it("run_subprocess with multiple targets returns results with expected fields", function()
      local runtime = require_lua_runtime()

      local results, err =
         subprocess.run_subprocess(runtime, SORT_BENCH, BOTH_TARGETS, "", { rounds = 1 })

      assert.is_nil(err)
      assert.is_table(results)
      assert.is_true(#results >= 1)
      local r = results[1]
      assert.is_string(r.name)
      assert.is_number(r.median)
      assert.is_number(r.rounds)
   end)

   it("run_subprocess cleans up temporary files after execution", function()
      local runtime = require_lua_runtime()

      -- Intercept os.tmpname to track base temp files it creates
      local base_files = {}
      local original_tmpname = os.tmpname
      os.tmpname = function()
         local name = original_tmpname()
         table.insert(base_files, name)
         return name
      end

      local ok, call_err =
         pcall(subprocess.run_subprocess, runtime, SORT_BENCH, BOTH_TARGETS, "", { rounds = 1 })

      os.tmpname = original_tmpname
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
      local runtime = require_lua_runtime()

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
