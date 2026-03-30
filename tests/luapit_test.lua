---@diagnostic disable: need-check-nil, duplicate-set-field

local path = require("pl.path")

describe("luapit", function()
   local luapit

   local CWD = path.currentdir()
   local FIXTURE_DIR = path.join(CWD, "tests", "fixtures")
   local LIBV1_DIR = path.join(FIXTURE_DIR, "targets", "libv1")
   local LIBV2_DIR = path.join(FIXTURE_DIR, "targets", "libv2")

   before_each(function()
      luapit = require("luapit")
   end)

   --- Build a fresh parser and parse argv, returning (ok, args).
   local function pparse(argv)
      return luapit.build_parser():pparse(argv)
   end

   it("pparse with positional targets returns targets", function()
      local ok, args = pparse({ ".#main", ".#dev", "/tmp/mylib" })

      assert.is_true(ok)
      assert.are_same({ ".#main", ".#dev", "/tmp/mylib" }, args.targets)
   end)

   it("pparse with -b flag returns bench list", function()
      local ok, args = pparse({ ".#main", "-b", "benchmarks/" })

      assert.is_true(ok)
      assert.are_same({ "benchmarks/" }, args.bench)
   end)

   it("pparse with missing required args returns false", function()
      assert.is_false(pparse({}))
   end)

   it("pparse with multiple --filter values returns filter table", function()
      local ok, args = pparse({ ".#main", "--filter", "sort", "--filter", "hash" })

      assert.is_true(ok)
      assert.are_same({ "sort", "hash" }, args.filter)
   end)

   it("pparse with --prepare returns prepare string", function()
      local ok, args = pparse({ ".#main", "--prepare", "npm ci && npx tstl" })

      assert.is_true(ok)
      assert.are_equal("npm ci && npx tstl", args.prepare)
   end)

   it("pparse without optional flags leaves defaults", function()
      local ok, args = pparse({ ".#main" })

      assert.is_true(ok)
      assert.is_nil(args.prepare)
      assert.are_same({}, args.lua_path)
   end)

   it("pparse with --lua-path returns lua_path list", function()
      local ok, args = pparse({ ".#main", "--lua-path", "lua", "--lua-path", "lib" })

      assert.is_true(ok)
      assert.are_same({ "lua", "lib" }, args.lua_path)
   end)

   local DEFAULT_RESOLVED = {
      { path = LIBV1_DIR, name = "libv1", cleanup = false },
   }

   --- Teardown functions registered by stub helpers; called in reverse in after_each.
   local pending_teardowns = {}

   after_each(function()
      for i = #pending_teardowns, 1, -1 do
         pending_teardowns[i]()
      end
      pending_teardowns = {}
   end)

   --- Stub helper for main() tests that mock resolve, discover, runner, etc.
   --- Installs happy-path defaults; individual tests override only what they need.
   --- Teardown is registered automatically and runs in after_each.
   --- @param overrides? table Optional table of module function overrides.
   --- @return table stubs Table of stub state + originals for teardown.
   local function setup_main_stubs(overrides)
      overrides = overrides or {}

      local resolve_mod = require("luapit.resolve")
      local discover_mod = require("luapit.discover")
      local runner_mod = require("luapit.runner")
      local export_mod = require("luapit.export")
      local subprocess_mod = require("luapit.subprocess")

      local originals = {
         resolve_targets = resolve_mod.resolve_targets,
         prepare_targets = resolve_mod.prepare_targets,
         cleanup = resolve_mod.cleanup,
         discover = discover_mod.discover,
         run = runner_mod.run,
         write_json = export_mod.write_json,
         detect_runtime = subprocess_mod.detect_runtime,
         exit = os.exit,
         stderr = io.stderr,
         write = io.write,
      }

      local state = {}

      io.stderr = io.tmpfile()
      io.write = function() end

      -- Happy-path defaults (tests override via overrides table)
      resolve_mod.resolve_targets = overrides.resolve_targets
         or function()
            return DEFAULT_RESOLVED
         end
      resolve_mod.cleanup = overrides.cleanup or function() end
      if overrides.prepare_targets then
         resolve_mod.prepare_targets = overrides.prepare_targets
      end
      discover_mod.discover = overrides.discover
         or function()
            return { "bench1.lua" }
         end
      runner_mod.run = overrides.run or function()
         return {}
      end
      subprocess_mod.detect_runtime = overrides.detect_runtime
         or function()
            return "/usr/bin/lua"
         end

      if overrides.write_json then
         export_mod.write_json = overrides.write_json
      end

      if overrides.exit then
         os.exit = overrides.exit
      end

      local function teardown()
         resolve_mod.resolve_targets = originals.resolve_targets
         resolve_mod.prepare_targets = originals.prepare_targets
         resolve_mod.cleanup = originals.cleanup
         discover_mod.discover = originals.discover
         runner_mod.run = originals.run
         export_mod.write_json = originals.write_json
         subprocess_mod.detect_runtime = originals.detect_runtime
         os.exit = originals.exit
         io.stderr:close()
         io.stderr = originals.stderr
         io.write = originals.write
      end

      --- Read captured stderr contents.
      --- @return string
      local function read_stderr()
         io.stderr:seek("set")
         return io.stderr:read("*a")
      end

      pending_teardowns[#pending_teardowns + 1] = teardown

      return {
         state = state,
         read_stderr = read_stderr,
      }
   end

   it("main calls resolve_targets with positional targets", function()
      local s
      s = setup_main_stubs({
         resolve_targets = function(specs)
            s.state.resolve_called_with = specs
            return DEFAULT_RESOLVED
         end,
      })

      luapit.main({ ".#main", ".#dev" })

      assert.are_same({ ".#main", ".#dev" }, s.state.resolve_called_with)
   end)

   it("main calls cleanup after run completes", function()
      local s
      s = setup_main_stubs({
         cleanup = function(targets)
            s.state.cleanup_called_with = targets
         end,
      })

      luapit.main({ ".#main" })

      assert.are_same(DEFAULT_RESOLVED, s.state.cleanup_called_with)
   end)

   it("main calls cleanup even when runner errors", function()
      local resolved = {
         { path = LIBV1_DIR, name = "libv1", cleanup = true },
      }
      local s
      s = setup_main_stubs({
         resolve_targets = function()
            return resolved
         end,
         cleanup = function(targets)
            s.state.cleanup_called_with = targets
         end,
         run = function()
            error("runner failed")
         end,
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { ".#main" })

      assert.are_same(resolved, s.state.cleanup_called_with)
      assert.are_equal(1, s.state.exit_code)
   end)

   it("main defaults bench paths to cwd when -b omitted", function()
      local s
      s = setup_main_stubs({
         discover = function(paths)
            s.state.discover_called_with = paths
            return { "bench1.lua" }
         end,
      })

      luapit.main({ ".#main" })

      assert.are_same({ "." }, s.state.discover_called_with)
   end)

   it("main uses -b paths for discover", function()
      local s
      s = setup_main_stubs({
         discover = function(paths)
            s.state.discover_called_with = paths
            return { "bench1.lua" }
         end,
      })

      luapit.main({ ".#main", "-b", "benchmarks/", "-b", "tests/" })

      assert.are_same({ "benchmarks/", "tests/" }, s.state.discover_called_with)
   end)

   it("main exits 1 when resolve_targets fails", function()
      local s
      s = setup_main_stubs({
         resolve_targets = function()
            return nil, "invalid target: bad"
         end,
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { "bad" })

      local stderr_output = s.read_stderr()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("invalid target", stderr_output)
   end)

   it("main exits 1 when no benchmark files found", function()
      local s
      s = setup_main_stubs({
         cleanup = function(targets)
            s.state.cleanup_called_with = targets
         end,
         discover = function()
            return {}
         end,
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { ".#main" })

      local stderr_output = s.read_stderr()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("no benchmark files found", stderr_output)
      assert.are_same(DEFAULT_RESOLVED, s.state.cleanup_called_with)
   end)

   it("main passes bench_files and resolved targets to runner.run", function()
      local resolved = {
         { path = LIBV1_DIR, name = "libv1", cleanup = false },
         { path = LIBV2_DIR, name = "libv2", cleanup = false },
      }
      local s
      s = setup_main_stubs({
         resolve_targets = function()
            return resolved
         end,
         discover = function()
            return { "bench1.lua", "bench2.lua" }
         end,
         run = function(files, targets, opts)
            s.state.run_called_with = { files = files, targets = targets, opts = opts }
            return {}
         end,
      })

      luapit.main({ ".#main", ".#dev" })

      assert.are_same({ "bench1.lua", "bench2.lua" }, s.state.run_called_with.files)
      assert.are_same(resolved, s.state.run_called_with.targets)
   end)

   --- Setup stubs with a run spy, call main, and return the captured opts.
   --- @param cli_args table CLI arguments to pass to main.
   --- @return table opts The opts table passed to runner.run.
   local function run_main_capturing_opts(cli_args)
      local captured_opts
      setup_main_stubs({
         run = function(_, _, opts)
            captured_opts = opts
            return {}
         end,
      })

      luapit.main(cli_args)

      return captured_opts
   end

   it("main with -t flag passes opts.rounds=1 to runner.run", function()
      local opts = run_main_capturing_opts({ ".#main", "-t" })

      assert.are_equal(1, opts.rounds)
   end)

   it("main with --filter passes opts.filters to runner.run", function()
      local opts = run_main_capturing_opts({ ".#main", "--filter", "sort", "--filter", "hash" })

      assert.are_same({ "sort", "hash" }, opts.filters)
   end)

   it("main with -p converts numeric and boolean strings and passes params to runner", function()
      local opts = run_main_capturing_opts({
         ".#main",
         "-p",
         "n:1000",
         "-p",
         "flag:true",
         "-p",
         "other:false",
         "-p",
         "name:hello",
      })

      assert.are_same({
         n = { 1000 },
         flag = { true },
         other = { false },
         name = { "hello" },
      }, opts.params)
   end)

   it("main with repeated -p name accumulates values into list", function()
      local opts = run_main_capturing_opts({ ".#main", "-p", "n:100", "-p", "n:1000" })

      assert.are_same({ n = { 100, 1000 } }, opts.params)
   end)

   it("main without optional flags auto-detects runtime and passes it in opts", function()
      local opts = run_main_capturing_opts({ ".#main" })

      assert.is_string(opts.runtime)
      assert.is_nil(opts.rounds)
      assert.is_nil(opts.filters)
      assert.is_nil(opts.params)
   end)

   it("main with --lua-path strips trailing slashes and passes opts.lua_path", function()
      local opts =
         run_main_capturing_opts({ ".#main", "--lua-path", "lua/", "--lua-path", "lib//" })

      assert.are_same({ "lua", "lib" }, opts.lua_path)
   end)

   it("main with invalid -p format exits 1 with error", function()
      local s
      s = setup_main_stubs({
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { ".#main", "-p", "bad" })

      local stderr_output = s.read_stderr()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("invalid parameter format", stderr_output)
   end)

   it("main calls export.write_json when -o is specified", function()
      local run_results = {
         { file = "bench/sort", spec = "default", targets = {} },
      }
      local s
      s = setup_main_stubs({
         run = function()
            return run_results
         end,
         write_json = function(filepath, results, targets, version)
            s.state.write_json_called_with = {
               filepath = filepath,
               results = results,
               targets = targets,
               version = version,
            }
            return true
         end,
      })

      luapit.main({ ".#main", "-o", "/tmp/test_output.json" })

      assert.is_not_nil(s.state.write_json_called_with)
      assert.are_equal("/tmp/test_output.json", s.state.write_json_called_with.filepath)
      assert.are_same(run_results, s.state.write_json_called_with.results)
      assert.are_same(DEFAULT_RESOLVED, s.state.write_json_called_with.targets)
      assert.are_equal("0.6.0", s.state.write_json_called_with.version)
   end)

   --- Stub subprocess.resolve_runtime; teardown is registered via pending_teardowns.
   --- @param fake function Replacement function.
   local function stub_subprocess_runtime(fake)
      local subprocess_mod = require("luapit.subprocess")
      local original = subprocess_mod.resolve_runtime
      subprocess_mod.resolve_runtime = fake
      pending_teardowns[#pending_teardowns + 1] = function()
         subprocess_mod.resolve_runtime = original
      end
   end

   it("main without -R auto-detects and passes runtime to runner", function()
      local opts = run_main_capturing_opts({ ".#main" })

      assert.are_equal("/usr/bin/lua", opts.runtime)
   end)

   it("main without -R exits 1 when runtime cannot be auto-detected", function()
      local s
      s = setup_main_stubs({
         detect_runtime = function()
            return nil, "cannot detect runtime: arg table is not available"
         end,
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { ".#main" })

      local stderr_output = s.read_stderr()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("cannot detect runtime", stderr_output)
   end)

   it("main with -R resolves named runtime and passes it to runner", function()
      stub_subprocess_runtime(function(name)
         return "/usr/local/bin/" .. name
      end)
      local opts = run_main_capturing_opts({ ".#main", "-R", "luajit" })

      assert.are_equal("/usr/local/bin/luajit", opts.runtime)
   end)

   it("main with -R and invalid runtime exits 1 with error", function()
      stub_subprocess_runtime(function()
         return nil, 'runtime not found: "bad_runtime"'
      end)
      local s
      s = setup_main_stubs({
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { ".#main", "-R", "bad_runtime" })

      local stderr_output = s.read_stderr()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("runtime not found", stderr_output)
   end)

   it("main with -R -t combines runtime and test mode", function()
      stub_subprocess_runtime(function(name)
         return "/usr/bin/" .. name
      end)
      local opts = run_main_capturing_opts({ ".#main", "-R", "luajit", "-t" })

      assert.are_equal("/usr/bin/luajit", opts.runtime)
      assert.are_equal(1, opts.rounds)
   end)

   it("main exits 1 when runner errors", function()
      local s
      s = setup_main_stubs({
         run = function()
            error("runner failed")
         end,
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { ".#main" })

      assert.are_equal(1, s.state.exit_code)
   end)

   it("main when runner raises interrupt error exits 130 silently", function()
      local s
      s = setup_main_stubs({
         run = function()
            error("interrupted")
         end,
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { ".#main" })

      local stderr_output = s.read_stderr()

      assert.are_equal(130, s.state.exit_code)
      assert.are_equal("", stderr_output)
   end)

   it("main with --prepare calls prepare_targets with targets and command", function()
      local s
      s = setup_main_stubs({
         prepare_targets = function(targets, cmd)
            s.state.prepare_called_with = { targets = targets, cmd = cmd }
            return targets
         end,
      })

      luapit.main({ ".#main", "--prepare", "echo hi" })

      assert.are_same(DEFAULT_RESOLVED, s.state.prepare_called_with.targets)
      assert.are_equal("echo hi", s.state.prepare_called_with.cmd)
   end)

   it("main with --prepare updates targets from prepare_targets return value", function()
      local s
      s = setup_main_stubs({
         resolve_targets = function()
            return {
               { path = LIBV1_DIR, name = "libv1", cleanup = false },
               { path = LIBV2_DIR, name = "libv2", cleanup = true },
            }
         end,
         prepare_targets = function()
            return DEFAULT_RESOLVED
         end,
         run = function(_, targets)
            s.state.run_targets = targets
            return {}
         end,
      })

      luapit.main({ ".#main", ".#dev", "--prepare", "make build" })

      assert.are_same(DEFAULT_RESOLVED, s.state.run_targets)
   end)

   it("main with --prepare exits 1 when all targets fail preparation", function()
      local s
      s = setup_main_stubs({
         prepare_targets = function()
            return {}
         end,
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luapit.main, { ".#main", "--prepare", "false" })

      local stderr_output = s.read_stderr()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("preparation", stderr_output)
   end)
end)
