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

   it("build_parser returns a parser with parse method", function()
      local parser = luabench.build_parser()

      assert.is_table(parser)
      assert.is_function(parser.parse)
      assert.is_function(parser.pparse)
   end)

   -- Parser tests for new CLI structure

   it("parsing ref with positional targets succeeds", function()
      local parser = luabench.build_parser()

      local ok, args = parser:pparse({ "ref", ".#main", ".#dev" })

      assert.is_true(ok)
      assert.are_equal("ref", args.command)
      assert.are_same({ ".#main", ".#dev" }, args.targets)
   end)

   it("parsing ref with -b flag produces bench list", function()
      local parser = luabench.build_parser()

      local ok, args = parser:pparse({ "ref", ".#main", "-b", "benchmarks/" })

      assert.is_true(ok)
      assert.are_same({ "benchmarks/" }, args.bench)
   end)

   it("parsing ref with no targets raises error", function()
      local parser = luabench.build_parser()

      local ok = parser:pparse({ "ref" })

      assert.is_false(ok)
   end)

   it("parsing with no args raises error", function()
      local parser = luabench.build_parser()

      local ok = parser:pparse({})

      assert.is_false(ok)
   end)

   it("parsing ref with multiple targets parses all", function()
      local parser = luabench.build_parser()

      local ok, args = parser:pparse({ "ref", ".#main", ".#dev", "/tmp/mylib" })

      assert.is_true(ok)
      assert.are_same({ ".#main", ".#dev", "/tmp/mylib" }, args.targets)
   end)

   it("parsing ref does not accept old -r flag", function()
      local parser = luabench.build_parser()

      local ok = parser:pparse({ "ref", ".#main", "-r", ".#dev" })

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
      runner_mod.run(
         bench_files,
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } }
      )

      luamark.compare_time = original_compare
      luamark.render = original_render
      io.write = original_write -- luacheck: ignore 122

      assert.is_true(compare_called)
      assert.is_not_nil(compare_args["libv1"])
      assert.is_not_nil(compare_args["libv2"])
   end)

   -- main() integration tests

   --- Stub helper for main() tests that mock resolve, discover, runner, etc.
   --- @return table stubs Table of stub state + originals for teardown.
   local function setup_main_stubs()
      local resolve_mod = require("luabench.resolve")
      local discover_mod = require("luabench.discover")
      local runner_mod = require("luabench.runner")
      local export_mod = require("luabench.export")

      local originals = {
         resolve_targets = resolve_mod.resolve_targets,
         cleanup = resolve_mod.cleanup,
         discover = discover_mod.discover,
         run = runner_mod.run,
         write_json = export_mod.write_json,
         exit = os.exit,
         stderr = io.stderr,
         write = io.write,
      }

      local state = {
         resolve_called_with = nil,
         cleanup_called_with = nil,
         discover_called_with = nil,
         run_called_with = nil,
         write_json_called_with = nil,
         exit_code = nil,
      }

      io.stderr = io.tmpfile()
      io.write = function() end -- luacheck: ignore 122

      local function teardown()
         resolve_mod.resolve_targets = originals.resolve_targets
         resolve_mod.cleanup = originals.cleanup
         discover_mod.discover = originals.discover
         runner_mod.run = originals.run
         export_mod.write_json = originals.write_json
         os.exit = originals.exit -- luacheck: ignore 122
         io.stderr:close()
         io.stderr = originals.stderr
         io.write = originals.write -- luacheck: ignore 122
      end

      --- Read captured stderr contents.
      --- @return string
      local function read_stderr()
         io.stderr:seek("set")
         return io.stderr:read("*a")
      end

      return {
         state = state,
         originals = originals,
         resolve_mod = resolve_mod,
         discover_mod = discover_mod,
         runner_mod = runner_mod,
         export_mod = export_mod,
         teardown = teardown,
         read_stderr = read_stderr,
      }
   end

   it("main calls resolve_targets with positional targets", function()
      local s = setup_main_stubs()

      s.resolve_mod.resolve_targets = function(specs)
         s.state.resolve_called_with = specs
         return {
            { path = LIBV1_DIR, name = "libv1", cleanup = false },
         }
      end
      s.resolve_mod.cleanup = function() end
      s.discover_mod.discover = function()
         return { "bench1.lua" }
      end
      s.runner_mod.run = function() return {} end

      luabench.main({ "ref", ".#main", ".#dev" })

      s.teardown()

      assert.are_same({ ".#main", ".#dev" }, s.state.resolve_called_with)
   end)

   it("main calls cleanup after run completes", function()
      local s = setup_main_stubs()
      local resolved = {
         { path = LIBV1_DIR, name = "libv1", cleanup = false },
      }

      s.resolve_mod.resolve_targets = function()
         return resolved
      end
      s.resolve_mod.cleanup = function(targets)
         s.state.cleanup_called_with = targets
      end
      s.discover_mod.discover = function()
         return { "bench1.lua" }
      end
      s.runner_mod.run = function() return {} end

      luabench.main({ "ref", ".#main" })

      s.teardown()

      assert.are_same(resolved, s.state.cleanup_called_with)
   end)

   it("main calls cleanup even when runner errors", function()
      local s = setup_main_stubs()
      local resolved = {
         { path = LIBV1_DIR, name = "libv1", cleanup = true },
      }

      s.resolve_mod.resolve_targets = function()
         return resolved
      end
      s.resolve_mod.cleanup = function(targets)
         s.state.cleanup_called_with = targets
      end
      s.discover_mod.discover = function()
         return { "bench1.lua" }
      end
      s.runner_mod.run = function()
         error("runner failed")
      end
      os.exit = function(code) -- luacheck: ignore 122
         s.state.exit_code = code
         error("EXIT")
      end

      pcall(luabench.main, { "ref", ".#main" })

      s.teardown()

      assert.are_same(resolved, s.state.cleanup_called_with)
      assert.are_equal(1, s.state.exit_code)
   end)

   it("main defaults bench paths to cwd when -b omitted", function()
      local s = setup_main_stubs()

      s.resolve_mod.resolve_targets = function()
         return {
            { path = LIBV1_DIR, name = "libv1", cleanup = false },
         }
      end
      s.resolve_mod.cleanup = function() end
      s.discover_mod.discover = function(paths)
         s.state.discover_called_with = paths
         return { "bench1.lua" }
      end
      s.runner_mod.run = function() return {} end

      luabench.main({ "ref", ".#main" })

      s.teardown()

      assert.are_same({ "." }, s.state.discover_called_with)
   end)

   it("main uses -b paths for discover", function()
      local s = setup_main_stubs()

      s.resolve_mod.resolve_targets = function()
         return {
            { path = LIBV1_DIR, name = "libv1", cleanup = false },
         }
      end
      s.resolve_mod.cleanup = function() end
      s.discover_mod.discover = function(paths)
         s.state.discover_called_with = paths
         return { "bench1.lua" }
      end
      s.runner_mod.run = function() return {} end

      luabench.main({ "ref", ".#main", "-b", "benchmarks/", "-b", "tests/" })

      s.teardown()

      assert.are_same({ "benchmarks/", "tests/" }, s.state.discover_called_with)
   end)

   it("main exits 1 when resolve_targets fails", function()
      local s = setup_main_stubs()

      s.resolve_mod.resolve_targets = function()
         return nil, "invalid target: bad"
      end
      os.exit = function(code) -- luacheck: ignore 122
         s.state.exit_code = code
         error("EXIT")
      end

      pcall(luabench.main, { "ref", "bad" })

      local stderr_output = s.read_stderr()
      s.teardown()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("invalid target", stderr_output)
   end)

   it("main exits 1 when no benchmark files found", function()
      local s = setup_main_stubs()
      local resolved = {
         { path = LIBV1_DIR, name = "libv1", cleanup = false },
      }

      s.resolve_mod.resolve_targets = function()
         return resolved
      end
      s.resolve_mod.cleanup = function(targets)
         s.state.cleanup_called_with = targets
      end
      s.discover_mod.discover = function()
         return {}
      end
      os.exit = function(code) -- luacheck: ignore 122
         s.state.exit_code = code
         error("EXIT")
      end

      pcall(luabench.main, { "ref", ".#main" })

      local stderr_output = s.read_stderr()
      s.teardown()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("no benchmark files found", stderr_output)
      -- cleanup should still be called even when no benchmarks found
      assert.are_same(resolved, s.state.cleanup_called_with)
   end)

   it("main passes bench_files and resolved targets to runner.run", function()
      local s = setup_main_stubs()
      local resolved = {
         { path = LIBV1_DIR, name = "libv1", cleanup = false },
         { path = LIBV2_DIR, name = "libv2", cleanup = false },
      }

      s.resolve_mod.resolve_targets = function()
         return resolved
      end
      s.resolve_mod.cleanup = function() end
      s.discover_mod.discover = function()
         return { "bench1.lua", "bench2.lua" }
      end
      s.runner_mod.run = function(files, targets)
         s.state.run_called_with = { files = files, targets = targets }
         return {}
      end

      luabench.main({ "ref", ".#main", ".#dev" })

      s.teardown()

      assert.are_same({ "bench1.lua", "bench2.lua" }, s.state.run_called_with.files)
      assert.are_same(resolved, s.state.run_called_with.targets)
   end)

   -- Export wiring tests

   it("_VERSION is 0.3.0", function()
      assert.are_equal("0.3.0", luabench._VERSION)
   end)

   it("main calls export.write_json when -o is specified", function()
      local s = setup_main_stubs()
      local resolved = {
         { path = LIBV1_DIR, name = "libv1", cleanup = false },
      }
      local run_results = {
         { file = "bench/sort", spec = "default", targets = {} },
      }

      s.resolve_mod.resolve_targets = function()
         return resolved
      end
      s.resolve_mod.cleanup = function() end
      s.discover_mod.discover = function()
         return { "bench1.lua" }
      end
      s.runner_mod.run = function()
         return run_results
      end
      s.export_mod.write_json = function(filepath, results, targets, version)
         s.state.write_json_called_with = {
            filepath = filepath,
            results = results,
            targets = targets,
            version = version,
         }
         return true
      end

      luabench.main({ "ref", ".#main", "-o", "/tmp/test_output.json" })

      s.teardown()

      assert.is_not_nil(s.state.write_json_called_with)
      assert.are_equal(
         "/tmp/test_output.json",
         s.state.write_json_called_with.filepath
      )
      assert.are_same(run_results, s.state.write_json_called_with.results)
      assert.are_same(resolved, s.state.write_json_called_with.targets)
      assert.are_equal("0.3.0", s.state.write_json_called_with.version)
   end)

   it("main does not call export.write_json when -o is omitted", function()
      local s = setup_main_stubs()

      s.resolve_mod.resolve_targets = function()
         return {
            { path = LIBV1_DIR, name = "libv1", cleanup = false },
         }
      end
      s.resolve_mod.cleanup = function() end
      s.discover_mod.discover = function()
         return { "bench1.lua" }
      end
      s.runner_mod.run = function()
         return {}
      end
      s.export_mod.write_json = function(filepath, results, targets, version)
         s.state.write_json_called_with = {
            filepath = filepath,
            results = results,
            targets = targets,
            version = version,
         }
         return true
      end

      luabench.main({ "ref", ".#main" })

      s.teardown()

      assert.is_nil(s.state.write_json_called_with)
   end)

   it("main does not call export.write_json when runner errors", function()
      local s = setup_main_stubs()

      s.resolve_mod.resolve_targets = function()
         return {
            { path = LIBV1_DIR, name = "libv1", cleanup = false },
         }
      end
      s.resolve_mod.cleanup = function() end
      s.discover_mod.discover = function()
         return { "bench1.lua" }
      end
      s.runner_mod.run = function()
         error("runner failed")
      end
      s.export_mod.write_json = function(filepath, results, targets, version)
         s.state.write_json_called_with = {
            filepath = filepath,
            results = results,
            targets = targets,
            version = version,
         }
         return true
      end
      os.exit = function(code) -- luacheck: ignore 122
         s.state.exit_code = code
         error("EXIT")
      end

      pcall(luabench.main, { "ref", ".#main", "-o", "/tmp/out.json" })

      s.teardown()

      assert.is_nil(s.state.write_json_called_with)
      assert.are_equal(1, s.state.exit_code)
   end)
end)
