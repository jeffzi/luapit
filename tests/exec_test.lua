---@diagnostic disable: need-check-nil, duplicate-set-field, missing-parameter

local IS_WINDOWS = require("pl.path").is_windows

local TRUE_CMD = IS_WINDOWS and "cmd /c exit 0" or "true"
local FALSE_CMD = IS_WINDOWS and "cmd /c exit 1" or "false"

describe("exec", function()
   local exec
   local original_popen

   before_each(function()
      exec = require("luapit.exec")
      original_popen = io.popen
   end)

   after_each(function()
      io.popen = original_popen
      package.loaded["luapit.exec"] = nil
   end)

   --- Override exec._get_ppid to simulate parent-death after the first call.
   local function simulate_parent_death()
      local call_count = 0
      exec._get_ppid = function()
         call_count = call_count + 1
         return call_count <= 1 and 1000 or 1 -- reparented to init
      end
   end

   it("run when command exits 0 returns true and captured stdout", function()
      local ok, stdout, stderr = exec.run("echo hello")
      assert.is_true(ok)
      assert.matches("hello", stdout)
      assert.are_equal("", stderr)

      local ok2, stdout2, stderr2 = exec.run(TRUE_CMD)
      assert.is_true(ok2)
      assert.are_equal("", stdout2)
      assert.are_equal("", stderr2)
   end)

   it("run when command exits non-zero returns false and captured stderr", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      local ok, stdout, stderr = exec.run("sh -c 'echo oops >&2; exit 1'")

      assert.is_false(ok)
      assert.are_equal("", stdout)
      assert.matches("oops", stderr)
   end)

   it("run when given mixed output captures stdout and stderr independently", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      local ok, stdout, stderr = exec.run("sh -c 'echo out_line; echo err_line >&2'")

      assert.is_true(ok)
      assert.matches("out_line", stdout)
      assert.matches("err_line", stderr)
      assert.is_nil(stdout:find("err_line", 1, true))
      assert.is_nil(stderr:find("out_line", 1, true))
   end)

   it("run when io.popen fails returns false and empty strings", function()
      if not IS_WINDOWS then
         pending("Windows fallback only")
      end
      io.popen = function()
         return nil
      end

      local ok, stdout, stderr = exec.run("echo anything")

      assert.is_false(ok)
      assert.are_equal("", stdout)
      assert.are_equal("", stderr)
   end)

   it("run when child exits 130 throws interrupted error", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      assert.has_error(function()
         exec.run("sh -c 'exit 130'")
      end, "interrupted!")
   end)

   it("run when parent dies during execution throws interrupted error", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      simulate_parent_death()

      assert.has_error(function()
         exec.run(TRUE_CMD)
      end, "interrupted!")
   end)

   it("stream returns true on success and false on failure with no extra values", function()
      local ok, extra = exec.stream(TRUE_CMD)
      assert.is_true(ok)
      assert.is_nil(extra)

      local ok2 = exec.stream(FALSE_CMD)
      assert.is_false(ok2)
   end)

   it("stream when child exits 130 throws interrupted error", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      assert.has_error(function()
         exec.stream("sh -c 'exit 130'")
      end, "interrupted!")
   end)

   it("stream when parent dies during execution throws interrupted error", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      simulate_parent_death()

      assert.has_error(function()
         exec.stream(TRUE_CMD)
      end, "interrupted!")
   end)
end)
