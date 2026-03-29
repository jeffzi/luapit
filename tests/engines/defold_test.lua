local path = require("pl.path")

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-parameter, duplicate-set-field

local defold

local CWD = path.currentdir()
local FIXTURE_DIR = path.join(CWD, "tests", "engines", "fixtures")
local TRIVIAL_BENCH = path.join(FIXTURE_DIR, "trivial_bench.lua")

--- Check that a command exists in PATH; call pending() and return false if absent.
--- @param cmd string Command name to look up.
--- @param msg string Pending message if not found.
--- @return string|false
local function require_command(cmd, msg)
   local h = io.popen("command -v " .. cmd .. " 2>/dev/null")
   local result = ""
   if h then
      result = h:read("*a"):match("^(.-)%s*$") or ""
      h:close()
   end
   if result == "" then
      pending(msg)
      return false
   end
   return result
end

describe("engines.defold", function()
   before_each(function()
      package.loaded["luabench.engines.defold"] = nil
      defold = require("luabench.engines.defold")
   end)

   -- Integration test (conditional)
   it("run executes a trivial benchmark with dmengine_headless and bob.jar", function()
      local dmengine = require_command("dmengine_headless", "dmengine_headless not found in PATH")
      if not dmengine then
         return
      end

      if not require_command("java", "java not found in PATH") then
         return
      end

      if not os.getenv("BOB") or os.getenv("BOB") == "" then
         if
            not require_command("bob.jar", "bob.jar not found (set BOB env var or add to PATH)")
         then
            return
         end
      end

      local results, err = defold.run(
         dmengine,
         TRIVIAL_BENCH,
         { { path = FIXTURE_DIR, name = "test" } },
         "",
         { rounds = 3 }
      )

      assert.is_nil(err)
      assert.is_table(results)
      assert.is_true(#results > 0)
   end)
end)
