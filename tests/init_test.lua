---@diagnostic disable: need-check-nil, duplicate-set-field, missing-parameter, redundant-parameter, unused-local, different-requires

local path = require("pl.path")

describe("init", function()
   local init
   local resolve
   local discover
   local subprocess
   local runner
   local engines

   local originals = {}
   local pending_restores = {}

   local CWD = path.currentdir()
   local FIXTURE_DIR = path.join(CWD, "tests", "fixtures")
   local LIBV1_DIR = path.join(FIXTURE_DIR, "targets", "libv1")

   before_each(function()
      init = require("luapit.init")
      resolve = require("luapit.resolve")
      discover = require("luapit.discover")
      subprocess = require("luapit.subprocess")
      runner = require("luapit.runner")
      engines = require("luapit.engines")

      -- Save originals for restoration
      originals = {
         resolve_targets = resolve.resolve_targets,
         prepare_targets = resolve.prepare_targets,
         discover = discover.discover,
         resolve_runtime = subprocess.resolve_runtime,
         detect_runtime = subprocess.detect_runtime,
         run = runner.run,
         cleanup = resolve.cleanup,
         detect = engines.detect,
      }
   end)

   after_each(function()
      -- Restore all originals
      resolve.resolve_targets = originals.resolve_targets
      resolve.prepare_targets = originals.prepare_targets
      discover.discover = originals.discover
      subprocess.resolve_runtime = originals.resolve_runtime
      subprocess.detect_runtime = originals.detect_runtime
      runner.run = originals.run
      resolve.cleanup = originals.cleanup
      engines.detect = originals.detect

      -- Run pending restores in reverse
      for i = #pending_restores, 1, -1 do
         pending_restores[i]()
      end
      pending_restores = {}
   end)

   --- Stub os.exit and io.stderr; teardown is registered via pending_restores.
   --- @return table state Table to capture exit code and read stderr output.
   local function capture_exit_and_stderr()
      local original_exit = os.exit
      local original_stderr = io.stderr
      local state = {}

      io.stderr = {
         write = function(_self, msg)
            state.stderr = (state.stderr or "") .. msg
         end,
      }

      os.exit = function(code)
         state.exit_code = code
         error("exit called")
      end

      pending_restores[#pending_restores + 1] = function()
         os.exit = original_exit
         io.stderr = original_stderr
      end

      return state
   end

   -- build_parser tests

   it("build_parser includes --isolate flag", function()
      local parser = init.build_parser()
      local args = parser:parse({ "target1", "--isolate" })

      assert.is_true(args.isolate)
   end)

   it("build_parser when --isolate is absent sets isolate to falsy", function()
      local parser = init.build_parser()
      local args = parser:parse({ "target1" })

      assert.is_nil(args.isolate)
   end)

   it("build_parser allows multiple targets with --isolate", function()
      local parser = init.build_parser()
      local args = parser:parse({ "target1", "target2", "--isolate" })

      assert.is_true(args.isolate)
      assert.are_same({ "target1", "target2" }, args.targets)
   end)

   for _, flag in ipairs({ "-v", "--version" }) do
      it("build_parser when " .. flag .. " is passed exits with code 0", function()
         local state = capture_exit_and_stderr()

         local parser = init.build_parser()
         pcall(function()
            parser:parse({ "target1", flag })
         end)

         assert.are_equal(0, state.exit_code)
      end)
   end

   it("_VERSION is a semver string", function()
      assert.is_string(init._VERSION)
      assert.truthy(init._VERSION:match("^%d+%.%d+%.%d+$"))
   end)

   -- main validation tests

   it("main with --isolate sets opts.isolate to true in runner.run call", function()
      resolve.resolve_targets = function()
         return { { path = LIBV1_DIR, name = "target1" } }
      end
      discover.discover = function()
         return { path.join(FIXTURE_DIR, "benchmarks", "sort_bench.lua") }
      end
      subprocess.detect_runtime = function()
         return "/usr/bin/lua"
      end

      local captured_opts
      runner.run = function(_files, _targets, opts)
         captured_opts = opts
         return {}
      end
      resolve.cleanup = function() end

      init.main({ "target1", "--isolate" })

      assert.is_not_nil(captured_opts)
      assert.is_true(captured_opts.isolate)
   end)

   it("main with --isolate and --param exits with error about incompatibility", function()
      resolve.resolve_targets = function()
         return { { path = LIBV1_DIR, name = "target1" } }
      end
      discover.discover = function()
         return { path.join(FIXTURE_DIR, "benchmarks", "sort_bench.lua") }
      end
      subprocess.detect_runtime = function()
         return "/usr/bin/lua"
      end

      local state = capture_exit_and_stderr()

      local ok = pcall(function()
         init.main({ "target1", "--isolate", "--param", "foo:bar" })
      end)

      assert.is_false(ok)
      assert.are_equal(1, state.exit_code)
      assert.matches("isolate", state.stderr)
      assert.matches("cannot", state.stderr)
      assert.matches("combined", state.stderr)
      assert.matches("param", state.stderr)
   end)

   it("main with --isolate and engine runtime exits with error about incompatibility", function()
      resolve.resolve_targets = function()
         return { { path = LIBV1_DIR, name = "target1" } }
      end
      discover.discover = function()
         return { path.join(FIXTURE_DIR, "benchmarks", "sort_bench.lua") }
      end

      local state = capture_exit_and_stderr()

      local ok = pcall(function()
         init.main({ "target1", "--isolate", "--runtime", "love" })
      end)

      assert.is_false(ok)
      assert.are_equal(1, state.exit_code)
      assert.matches("isolate", state.stderr)
      assert.matches("cannot", state.stderr)
      assert.matches("combined", state.stderr)
      assert.matches("engine", state.stderr)
   end)
end)
