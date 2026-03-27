---@diagnostic disable: need-check-nil, duplicate-set-field

local path = require("pl.path")
require("terminal")

describe("luabench", function()
   local luabench

   local CWD = path.currentdir()
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

   --- Build a fresh parser and parse argv, returning (ok, args).
   local function pparse(argv)
      return luabench.build_parser():pparse(argv)
   end

   it("parsing ref with positional targets succeeds", function()
      local ok, args = pparse({ "ref", ".#main", ".#dev", "/tmp/mylib" })

      assert.is_true(ok)
      assert.are_equal("ref", args.command)
      assert.are_same({ ".#main", ".#dev", "/tmp/mylib" }, args.targets)
   end)

   it("parsing ref with -b flag produces bench list", function()
      local ok, args = pparse({ "ref", ".#main", "-b", "benchmarks/" })

      assert.is_true(ok)
      assert.are_same({ "benchmarks/" }, args.bench)
   end)

   it("parsing ref with no targets raises error", function()
      local ok = pparse({ "ref" })

      assert.is_false(ok)
   end)

   it("parsing with no args raises error", function()
      local ok = pparse({})

      assert.is_false(ok)
   end)

   it("parsing ref with multiple --filter values produces table", function()
      local ok, args = pparse({ "ref", ".#main", "--filter", "sort", "--filter", "hash" })

      assert.is_true(ok)
      assert.are_same({ "sort", "hash" }, args.filter)
   end)

   it("parsing ref does not accept old -r flag", function()
      local ok = pparse({ "ref", ".#main", "-r", ".#dev" })

      assert.is_false(ok)
   end)

   it("parsing ref with --prepare produces prepare string", function()
      local ok, args = pparse({ "ref", ".#main", "--prepare", "npm ci && npx tstl" })

      assert.is_true(ok)
      assert.are_equal("npm ci && npx tstl", args.prepare)
   end)

   it("parsing ref without optional flags leaves defaults", function()
      local ok, args = pparse({ "ref", ".#main" })

      assert.is_true(ok)
      assert.is_nil(args.prepare)
      assert.are_same({}, args.lua_path)
   end)

   it("parsing ref with --lua-path produces lua_path list", function()
      local ok, args = pparse({ "ref", ".#main", "--lua-path", "lua" })

      assert.is_true(ok)
      assert.are_same({ "lua" }, args.lua_path)
   end)

   it("parsing ref with multiple --lua-path values produces list", function()
      local ok, args = pparse({ "ref", ".#main", "--lua-path", "lua", "--lua-path", "lib" })

      assert.is_true(ok)
      assert.are_same({ "lua", "lib" }, args.lua_path)
   end)

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

   local DEFAULT_RESOLVED = {
      { path = LIBV1_DIR, name = "libv1", cleanup = false },
   }

   --- Stub helper for main() tests that mock resolve, discover, runner, etc.
   --- Installs happy-path defaults; individual tests override only what they need.
   --- @param overrides? table Optional table of module function overrides.
   --- @return table stubs Table of stub state + originals for teardown.
   local function setup_main_stubs(overrides)
      overrides = overrides or {}

      local resolve_mod = require("luabench.resolve")
      local discover_mod = require("luabench.discover")
      local runner_mod = require("luabench.runner")
      local export_mod = require("luabench.export")

      local originals = {
         resolve_targets = resolve_mod.resolve_targets,
         prepare_targets = resolve_mod.prepare_targets,
         cleanup = resolve_mod.cleanup,
         discover = discover_mod.discover,
         run = runner_mod.run,
         write_json = export_mod.write_json,
         exit = os.exit,
         stderr = io.stderr,
         write = io.write,
      }

      local state = {}

      io.stderr = io.tmpfile()
      io.write = function() end -- luacheck: ignore 122

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

      if overrides.write_json then
         export_mod.write_json = overrides.write_json
      end

      if overrides.exit then
         os.exit = overrides.exit -- luacheck: ignore 122
      end

      local function teardown()
         resolve_mod.resolve_targets = originals.resolve_targets
         resolve_mod.prepare_targets = originals.prepare_targets
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
         teardown = teardown,
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

      luabench.main({ "ref", ".#main", ".#dev" })

      s.teardown()

      assert.are_same({ ".#main", ".#dev" }, s.state.resolve_called_with)
   end)

   it("main calls cleanup after run completes", function()
      local s
      s = setup_main_stubs({
         cleanup = function(targets)
            s.state.cleanup_called_with = targets
         end,
      })

      luabench.main({ "ref", ".#main" })

      s.teardown()

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

      pcall(luabench.main, { "ref", ".#main" })

      s.teardown()

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

      luabench.main({ "ref", ".#main" })

      s.teardown()

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

      luabench.main({ "ref", ".#main", "-b", "benchmarks/", "-b", "tests/" })

      s.teardown()

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

      pcall(luabench.main, { "ref", "bad" })

      local stderr_output = s.read_stderr()
      s.teardown()

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

      pcall(luabench.main, { "ref", ".#main" })

      local stderr_output = s.read_stderr()
      s.teardown()

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

      luabench.main({ "ref", ".#main", ".#dev" })

      s.teardown()

      assert.are_same({ "bench1.lua", "bench2.lua" }, s.state.run_called_with.files)
      assert.are_same(resolved, s.state.run_called_with.targets)
   end)

   it("_parse_params coerces numbers booleans and passes strings through", function()
      local params = luabench._parse_params({ "n:1000", "flag:true", "other:false", "name:hello" })

      assert.are_same({
         n = { 1000 },
         flag = { true },
         other = { false },
         name = { "hello" },
      }, params)
   end)

   it("_parse_params with repeated name accumulates values", function()
      local params = luabench._parse_params({ "n:100", "n:1000" })

      assert.are_same({ n = { 100, 1000 } }, params)
   end)

   it("_parse_params with invalid format returns nil and error", function()
      local params, err = luabench._parse_params({ "bad" })

      assert.is_nil(params)
      assert.matches("invalid parameter format", err)
   end)

   --- Helper: setup stubs with a run spy that captures args, call main, teardown.
   --- @param cli_args table CLI arguments to pass to main.
   --- @return table opts The opts table passed to runner.run.
   local function run_main_capturing_opts(cli_args)
      local captured_opts
      local s = setup_main_stubs({
         run = function(_, _, opts)
            captured_opts = opts
            return {}
         end,
      })

      luabench.main(cli_args)
      s.teardown()

      return captured_opts
   end

   it("main with -t flag passes opts.rounds=1 to runner.run", function()
      local opts = run_main_capturing_opts({ "ref", ".#main", "-t" })

      assert.are_equal(1, opts.rounds)
   end)

   it("main with --filter passes opts.filters to runner.run", function()
      local opts = run_main_capturing_opts({ "ref", ".#main", "--filter", "sort" })

      assert.are_same({ "sort" }, opts.filters)
   end)

   it("main with multiple --filter values passes all to opts.filters", function()
      local opts =
         run_main_capturing_opts({ "ref", ".#main", "--filter", "sort", "--filter", "hash" })

      assert.are_same({ "sort", "hash" }, opts.filters)
   end)

   it("main with -p passes opts.params to runner.run", function()
      local opts = run_main_capturing_opts({ "ref", ".#main", "-p", "n:1000" })

      assert.are_same({ n = { 1000 } }, opts.params)
   end)

   it("main with combined flags passes combined opts", function()
      local opts =
         run_main_capturing_opts({ "ref", ".#main", "-t", "--filter", "sort", "-p", "n:100" })

      assert.are_equal(1, opts.rounds)
      assert.are_same({ "sort" }, opts.filters)
      assert.are_same({ n = { 100 } }, opts.params)
   end)

   it("main without optional flags passes empty opts to runner.run", function()
      local opts = run_main_capturing_opts({ "ref", ".#main" })

      assert.are_same({}, opts)
   end)

   it("main with --lua-path passes opts.lua_path to runner.run", function()
      local opts = run_main_capturing_opts({ "ref", ".#main", "--lua-path", "lua" })

      assert.are_same({ "lua" }, opts.lua_path)
   end)

   it("main with --lua-path strips trailing slashes", function()
      local opts =
         run_main_capturing_opts({ "ref", ".#main", "--lua-path", "lua/", "--lua-path", "lib//" })

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

      pcall(luabench.main, { "ref", ".#main", "-p", "bad" })

      local stderr_output = s.read_stderr()
      s.teardown()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("invalid parameter format", stderr_output)
   end)

   it("_VERSION is 0.5.0", function()
      assert.are_equal("0.5.0", luabench._VERSION)
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

      luabench.main({ "ref", ".#main", "-o", "/tmp/test_output.json" })

      s.teardown()

      assert.is_not_nil(s.state.write_json_called_with)
      assert.are_equal("/tmp/test_output.json", s.state.write_json_called_with.filepath)
      assert.are_same(run_results, s.state.write_json_called_with.results)
      assert.are_same(DEFAULT_RESOLVED, s.state.write_json_called_with.targets)
      assert.are_equal("0.5.0", s.state.write_json_called_with.version)
   end)

   it("main does not call export.write_json when -o is omitted", function()
      local s
      s = setup_main_stubs({
         write_json = function()
            s.state.write_json_called = true
            return true
         end,
      })

      luabench.main({ "ref", ".#main" })

      s.teardown()

      assert.is_nil(s.state.write_json_called)
   end)

   --- Helper: stub subprocess.resolve_runtime for -R tests, returning restore fn.
   local function stub_subprocess_runtime(fake_resolve)
      local subprocess_mod = require("luabench.subprocess")
      local original = subprocess_mod.resolve_runtime
      subprocess_mod.resolve_runtime = fake_resolve
      return function()
         subprocess_mod.resolve_runtime = original
      end
   end

   it("main with -R calls subprocess.resolve_runtime and sets opts.runtime", function()
      local restore = stub_subprocess_runtime(function(name)
         return "/usr/local/bin/" .. name
      end)
      local opts = run_main_capturing_opts({ "ref", ".#main", "-R", "luajit" })
      restore()

      assert.are_equal("/usr/local/bin/luajit", opts.runtime)
   end)

   it("main with -R and invalid runtime exits 1 with error", function()
      local restore = stub_subprocess_runtime(function()
         return nil, 'runtime not found: "bad_runtime"'
      end)
      local s
      s = setup_main_stubs({
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luabench.main, { "ref", ".#main", "-R", "bad_runtime" })

      local stderr_output = s.read_stderr()
      restore()
      s.teardown()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("runtime not found", stderr_output)
   end)

   it("main with -R -t combines runtime and test mode", function()
      local restore = stub_subprocess_runtime(function(name)
         return "/usr/bin/" .. name
      end)
      local opts = run_main_capturing_opts({ "ref", ".#main", "-R", "luajit", "-t" })
      restore()

      assert.are_equal("/usr/bin/luajit", opts.runtime)
      assert.are_equal(1, opts.rounds)
   end)

   it("main does not call export.write_json when runner errors", function()
      local s
      s = setup_main_stubs({
         run = function()
            error("runner failed")
         end,
         write_json = function()
            s.state.write_json_called = true
            return true
         end,
         exit = function(code)
            s.state.exit_code = code
            error("EXIT")
         end,
      })

      pcall(luabench.main, { "ref", ".#main", "-o", "/tmp/out.json" })

      s.teardown()

      assert.is_nil(s.state.write_json_called)
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

      pcall(luabench.main, { "ref", ".#main" })

      local stderr_output = s.read_stderr()
      s.teardown()

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

      luabench.main({ "ref", ".#main", "--prepare", "echo hi" })

      s.teardown()

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

      luabench.main({ "ref", ".#main", ".#dev", "--prepare", "make build" })

      s.teardown()

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

      pcall(luabench.main, { "ref", ".#main", "--prepare", "false" })

      local stderr_output = s.read_stderr()
      s.teardown()

      assert.are_equal(1, s.state.exit_code)
      assert.matches("preparation", stderr_output)
   end)

   it("main without --prepare does not call prepare_targets", function()
      local s
      s = setup_main_stubs({
         prepare_targets = function(targets)
            s.state.prepare_called = true
            return targets
         end,
      })

      luabench.main({ "ref", ".#main" })

      s.teardown()

      assert.is_nil(s.state.prepare_called)
   end)
end)
