---@diagnostic disable: need-check-nil, duplicate-set-field
local lfs = require("lfs")

describe("luabench", function()
   local luabench

   local CWD = lfs.currentdir()
   local FIXTURE_DIR = CWD .. "/tests/fixtures"
   local LIBV1_DIR = FIXTURE_DIR .. "/targets/libv1"
   local LIBV2_DIR = FIXTURE_DIR .. "/targets/libv2"

   before_each(function()
      luabench = require("luabench")
   end)

   it("exports main function and _VERSION in semver format", function()
      assert.is_table(luabench)
      assert.is_function(luabench.main)
      assert.matches("%d+%.%d+%.%d+", luabench._VERSION)
   end)

   it("build_parser returns a parser with parse method", function()
      local parser = luabench.build_parser()

      assert.is_table(parser)
      assert.is_function(parser.parse)
      assert.is_function(parser.pparse)
   end)

   it("parsing ref with paths succeeds", function()
      local parser = luabench.build_parser()

      local ok, args = parser:pparse({ "ref", "benchmarks/" })

      assert.is_true(ok)
      assert.are_equal("ref", args.command)
      assert.are_same({ "benchmarks/" }, args.paths)
   end)

   it("parsing ref with multiple --ref flags produces ref list", function()
      local parser = luabench.build_parser()

      local ok, args = parser:pparse({ "ref", "benchmarks/", "-r", ".#main", "-r", ".#dev" })

      assert.is_true(ok)
      assert.are_same({ ".#main", ".#dev" }, args.ref)
   end)

   it("parsing with no args raises error", function()
      local parser = luabench.build_parser()

      local ok = parser:pparse({})

      assert.is_false(ok)
   end)

   it("parsing ref with no paths raises error", function()
      local parser = luabench.build_parser()

      local ok = parser:pparse({ "ref" })

      assert.is_false(ok)
   end)

   -- Integration: discover -> runner pipeline

   it("discover feeds bench files into runner for full pipeline", function()
      local discover_mod = require("luabench.discover")
      local runner_mod = require("luabench.runner")
      local luamark = require("luamark")

      local original_compare = luamark.compare_time
      local original_render = luamark.render
      local compare_called = false
      local compare_args

      luamark.compare_time = function(funcs)
         compare_called = true
         compare_args = funcs
         return {}
      end
      luamark.render = function()
         return "rendered"
      end

      local original_write = io.write
      io.write = function() end -- luacheck: ignore 122

      -- Simulate the pipeline: discover -> run
      local bench_files = discover_mod.discover({
         FIXTURE_DIR .. "/benchmarks/sort_bench.lua",
      })
      runner_mod.run(bench_files, { LIBV1_DIR, LIBV2_DIR })

      luamark.compare_time = original_compare
      luamark.render = original_render
      io.write = original_write -- luacheck: ignore 122

      assert.is_true(compare_called)
      assert.is_not_nil(compare_args["libv1"])
      assert.is_not_nil(compare_args["libv2"])
   end)

   -- main() integration tests

   it("main exits with error when no benchmark files found", function()
      local discover_mod = require("luabench.discover")
      local original_discover = discover_mod.discover
      local original_exit = os.exit
      local original_stderr = io.stderr

      discover_mod.discover = function()
         return {}
      end
      local exit_code
      os.exit = function(code) -- luacheck: ignore 122
         exit_code = code
         error("EXIT")
      end
      io.stderr = io.tmpfile()

      pcall(luabench.main, { "ref", "nonexistent/", "-r", "somedir" })

      io.stderr:seek("set")
      local stderr_output = io.stderr:read("*a")
      io.stderr:close()
      discover_mod.discover = original_discover
      os.exit = original_exit -- luacheck: ignore 122
      io.stderr = original_stderr

      assert.are_equal(1, exit_code)
      assert.matches("no benchmark files found", stderr_output)
   end)

   it("main exits with error when no targets specified", function()
      local discover_mod = require("luabench.discover")
      local original_discover = discover_mod.discover
      local original_exit = os.exit
      local original_stderr = io.stderr

      discover_mod.discover = function()
         return { "fake_bench.lua" }
      end
      local exit_code
      os.exit = function(code) -- luacheck: ignore 122
         exit_code = code
         error("EXIT")
      end
      io.stderr = io.tmpfile()

      pcall(luabench.main, { "ref", "benchmarks/" })

      io.stderr:seek("set")
      local stderr_output = io.stderr:read("*a")
      io.stderr:close()
      discover_mod.discover = original_discover
      os.exit = original_exit -- luacheck: ignore 122
      io.stderr = original_stderr

      assert.are_equal(1, exit_code)
      assert.matches("no targets specified", stderr_output)
   end)

   it("main calls runner.run with discovered files and targets", function()
      local discover_mod = require("luabench.discover")
      local runner_mod = require("luabench.runner")
      local original_discover = discover_mod.discover
      local original_run = runner_mod.run
      local original_write = io.write

      discover_mod.discover = function()
         return { "bench1.lua" }
      end
      local captured_files, captured_targets
      runner_mod.run = function(files, targets)
         captured_files = files
         captured_targets = targets
      end
      io.write = function() end -- luacheck: ignore 122

      luabench.main({ "ref", "benchmarks/", "-r", "/tmp/libv1", "-r", "/tmp/libv2" })

      discover_mod.discover = original_discover
      runner_mod.run = original_run
      io.write = original_write -- luacheck: ignore 122

      assert.are_same({ "bench1.lua" }, captured_files)
      assert.are_same({ "/tmp/libv1", "/tmp/libv2" }, captured_targets)
   end)
end)
