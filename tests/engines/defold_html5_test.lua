local path = require("pl.path")

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-parameter, duplicate-set-field

local defold_html5

local CWD = path.currentdir()
local FIXTURE_DIR = CWD .. "/tests/engines/fixtures"
local TRIVIAL_BENCH = FIXTURE_DIR .. "/trivial_bench.lua"

--- Check that a command exists in PATH; call pending() and return false if absent.
--- @param cmd string Command name to look up.
--- @param msg string Pending message if not found.
--- @return string|false path Absolute path on success, false when skipped.
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

describe("engines.defold_html5", function()
   before_each(function()
      package.loaded["luabench.engines.defold_html5"] = nil
      defold_html5 = require("luabench.engines.defold_html5")
   end)

   -- Integration: full run orchestration

   it("run executes a trivial benchmark with defold html5 build", function()
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

      local node = require_command("node", "node not found in PATH")
      if not node then
         return
      end

      -- Check for playwright (no binary to locate -- probe via node require)
      local h = io.popen(node .. " -e \"require('playwright')\" 2>&1")
      if h then
         local pw_output = h:read("*a")
         h:close()
         if pw_output and pw_output:match("%S") then
            pending("playwright not installed")
            return
         end
      end

      if
         not require_command("luabench-html5-harness", "luabench-html5-harness not found in PATH")
      then
         return
      end

      local results, err = defold_html5.run(
         node,
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
