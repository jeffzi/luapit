---@diagnostic disable: need-check-nil, duplicate-set-field, missing-parameter

local IS_WINDOWS = require("pl.path").is_windows

describe("exec", function()
   local exec
   local original_popen

   before_each(function()
      exec = require("luabench.exec")
      original_popen = io.popen
   end)

   after_each(function()
      io.popen = original_popen
      package.loaded["luabench.exec"] = nil
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

   it("run when command produces no output returns true and empty strings", function()
      local ok, stdout, stderr = exec.run("true")

      assert.is_true(ok)
      assert.are_equal("", stdout)
      assert.are_equal("", stderr)
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

   it("run throws interrupted when child exits 130", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      assert.has_error(function()
         exec.run("sh -c 'exit 130'")
      end, "interrupted!")
   end)

   it("run throws interrupted when parent dies during execution", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      simulate_parent_death()

      assert.has_error(function()
         exec.run("true")
      end, "interrupted!")
   end)

   it("stream when command exits 0 returns true", function()
      local ok = exec.stream("true")

      assert.is_true(ok)
   end)

   it("stream when command exits non-zero returns false", function()
      local ok = exec.stream("false")

      assert.is_false(ok)
   end)

   it("stream when command succeeds returns no additional values", function()
      local ok, extra = exec.stream("echo hello")

      assert.is_true(ok)
      assert.is_nil(extra)
   end)

   it("stream throws interrupted when child exits 130", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      assert.has_error(function()
         exec.stream("sh -c 'exit 130'")
      end, "interrupted!")
   end)

   it("stream throws interrupted when parent dies during execution", function()
      if IS_WINDOWS then
         pending("POSIX only")
      end
      simulate_parent_death()

      assert.has_error(function()
         exec.stream("true")
      end, "interrupted!")
   end)
end)
