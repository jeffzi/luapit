---@diagnostic disable: need-check-nil, duplicate-set-field, unused-local

local path = require("pl.path")

describe("runner", function()
   local runner

   local CWD = path.currentdir()
   local FIXTURE_DIR = path.join(CWD, "tests", "fixtures")
   local LIBV1_DIR = path.join(FIXTURE_DIR, "targets", "libv1")
   local LIBV2_DIR = path.join(FIXTURE_DIR, "targets", "libv2")
   local SORT_BENCH = path.join(FIXTURE_DIR, "benchmarks", "sort_bench.lua")

   local TARGET_V1 = { path = LIBV1_DIR, name = "libv1" }
   local TARGET_V2 = { path = LIBV2_DIR, name = "libv2" }
   local TARGETS_PAIR = { TARGET_V1, TARGET_V2 }
   local TARGETS_V1 = { TARGET_V1 }

   --- Minimal luamark Result for a single target.
   --- @param name string Target name.
   --- @param rank number Rank (1-based).
   --- @param relative number Relative slowdown factor.
   --- @return table
   local function fake_result(name, rank, relative)
      return {
         name = name,
         median = 0.001 * rank,
         ci_lower = 0.001 * rank - 0.0001,
         ci_upper = 0.001 * rank + 0.0001,
         rounds = 100,
         rank = rank,
         relative = relative,
      }
   end

   local FAKE_V1 = fake_result("libv1", 1, 1.0)
   local FAKE_V2 = fake_result("libv2", 2, 2.0)
   local FAKE_RESULTS_PAIR = { FAKE_V1, FAKE_V2 }
   local FAKE_RESULTS_V1 = { FAKE_V1 }

   before_each(function()
      runner = require("luabench.runner")
   end)

   it(
      "with_target on success prepends path, cleans loaded, restores path, and returns result",
      function()
         local original_path = package.path
         local captured_path

         local result = runner.with_target(LIBV1_DIR, function()
            captured_path = package.path
            require("mylib")
            return "hello"
         end)

         assert.matches(LIBV1_DIR, captured_path)
         assert.is_nil(package.loaded["mylib"])
         assert.are_equal(original_path, package.path)
         assert.are_equal("hello", result)
      end
   )

   it("with_target on error restores path and returns nil with error message", function()
      local original_path = package.path

      local result, err = runner.with_target(LIBV1_DIR, function()
         error("boom")
      end)

      assert.are_equal(original_path, package.path)
      assert.is_nil(result)
      assert.matches("boom", err)
   end)

   it("with_target propagates fn second return value on success", function()
      local r1, r2 = runner.with_target(LIBV1_DIR, function()
         return nil, "load failed"
      end)

      assert.is_nil(r1)
      assert.are_equal("load failed", r2)
   end)

   it("with_target loads different modules from different target dirs", function()
      local v1_result
      runner.with_target(LIBV1_DIR, function()
         v1_result = require("mylib").value()
      end)

      local v2_result
      runner.with_target(LIBV2_DIR, function()
         v2_result = require("mylib").value()
      end)

      assert.are_equal(1, v1_result)
      assert.are_equal(2, v2_result)
   end)

   it("with_target with lua_paths resolves modules from subdirectory", function()
      local LIB_SUB_DIR = path.join(FIXTURE_DIR, "targets", "lib_sub")

      local result
      runner.with_target(LIB_SUB_DIR, function()
         result = require("mylib").value()
      end, { "sub" })

      assert.are_equal(3, result)
   end)

   it("with_target with lua_paths dot behaves like default", function()
      local captured_path
      runner.with_target(LIBV1_DIR, function()
         captured_path = package.path
      end, { "." })

      assert.matches(LIBV1_DIR .. "/%?%.lua", captured_path)
      assert.matches(LIBV1_DIR .. "/%?/init%.lua", captured_path)
   end)

   it("with_target with multiple lua_paths prepends all", function()
      local captured_path
      runner.with_target(LIBV1_DIR, function()
         captured_path = package.path
      end, { "a", "b" })

      local a_pos = captured_path:find(LIBV1_DIR .. "/a/?.lua", 1, true)
      local b_pos = captured_path:find(LIBV1_DIR .. "/b/?.lua", 1, true)
      assert.is_not_nil(a_pos)
      assert.is_not_nil(b_pos)
      assert.is_true(a_pos < b_pos)
   end)

   it("with_target without lua_paths preserves current behavior", function()
      local captured_with_nil
      runner.with_target(LIBV1_DIR, function()
         captured_with_nil = package.path
      end)

      local captured_without
      runner.with_target(LIBV1_DIR, function()
         captured_without = package.path
      end, nil)

      assert.are_equal(captured_with_nil, captured_without)
   end)

   --- Stub subprocess and io for run() tests.
   --- @param fake_subprocess function|nil Custom subprocess stub (defaults to returning FAKE_RESULTS_PAIR).
   --- @return table spy_state, fun() teardown, fun() read_stderr
   local function setup_run_stubs(fake_subprocess)
      local luamark = require("luamark")
      local subprocess = require("luabench.subprocess")
      local originals = {
         render = luamark.render,
         run_subprocess = subprocess.run_subprocess,
         write = io.write,
         stderr = io.stderr,
      }

      local spy_state = { subprocess_calls = {}, output = {} }

      subprocess.run_subprocess = fake_subprocess
         or function(runtime_path, bench_file, targets, spec_name, opts)
            spy_state.subprocess_calls[#spy_state.subprocess_calls + 1] = {
               runtime_path = runtime_path,
               bench_file = bench_file,
               targets = targets,
               spec_name = spec_name,
               opts = opts,
            }
            return FAKE_RESULTS_PAIR
         end
      luamark.render = function()
         return "rendered"
      end
      io.write = function(s)
         spy_state.output[#spy_state.output + 1] = s
      end
      io.stderr = io.tmpfile()

      local function teardown()
         subprocess.run_subprocess = originals.run_subprocess
         luamark.render = originals.render
         io.write = originals.write
         io.stderr:close()
         io.stderr = originals.stderr
      end

      --- Read captured stderr contents.
      --- @return string
      local function read_stderr()
         io.stderr:seek("set")
         return io.stderr:read("*a")
      end

      return spy_state, teardown, read_stderr
   end

   local RUNTIME = "/usr/bin/lua"
   local RUNTIME_OPTS = { runtime = RUNTIME }

   it("run when given a bench file renders output with section header", function()
      local spy_state, teardown = setup_run_stubs()

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      local combined = table.concat(spy_state.output)
      local header_prefix = string.char(0xe2, 0x96, 0x8c) -- U+258C ▌
      assert.matches(header_prefix, combined)
      assert.matches("sort", combined)
      assert.matches("rendered", combined)
      assert.is_table(results)
   end)

   it("run when load_benchmark returns nil for all targets returns empty results", function()
      local _, teardown = setup_run_stubs()

      local results =
         runner.run({ path.join(FIXTURE_DIR, "nonexistent_bench.lua") }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      assert.are_same({}, results)
   end)

   it("run when one target fails to load runs with remaining valid targets", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run(
         { SORT_BENCH },
         { TARGET_V1, { path = "/nonexistent/target", name = "bad" } },
         RUNTIME_OPTS
      )

      teardown()

      assert.are_equal(1, #results)
   end)

   it("run when a target fails to load includes error reason in stderr warning", function()
      local _, teardown, read_stderr = setup_run_stubs()
      local loader = require("luabench.loader")
      local original_load = loader.load_benchmark
      loader.load_benchmark = function()
         error("deliberate load error")
      end

      runner.run({ SORT_BENCH }, TARGETS_V1, RUNTIME_OPTS)

      local stderr_output = read_stderr()
      loader.load_benchmark = original_load
      teardown()

      assert.matches("deliberate load error", stderr_output)
   end)

   it("run when bench file has named specs returns results for each spec", function()
      local _, teardown = setup_run_stubs()
      local multi_bench = path.join(FIXTURE_DIR, "benchmarks", "multi_bench.lua")

      local results = runner.run({ multi_bench }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      assert.are_equal(2, #results)
   end)

   it("run collects spec names from all targets not just the first", function()
      local _, teardown = setup_run_stubs()
      local asym_bench = path.join(FIXTURE_DIR, "benchmarks", "asymmetric_bench.lua")

      local results = runner.run({ asym_bench }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      assert.are_equal(2, #results)
   end)

   it("run when one subprocess fails logs warning and continues with remaining", function()
      local call_count = 0
      local _, teardown, read_stderr = setup_run_stubs(function()
         call_count = call_count + 1
         if call_count == 1 then
            return nil, "subprocess failed"
         end
         return FAKE_RESULTS_V1
      end)

      runner.run(
         { SORT_BENCH, path.join(FIXTURE_DIR, "benchmarks", "sort_bench.lua") },
         TARGETS_PAIR,
         RUNTIME_OPTS
      )

      local stderr_output = read_stderr()
      teardown()

      assert.matches("warning", stderr_output)
   end)

   it("run returns flat results array with file, spec, and targets fields", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      assert.is_table(results)
      assert.are_equal(1, #results)
      local entry = results[1]
      assert.is_string(entry.file)
      assert.matches("sort", entry.file)
      assert.is_string(entry.spec)
      assert.is_table(entry.targets)
      assert.are_equal(2, #entry.targets)
   end)

   it("run maps benchmark measurements to stat entries with ratio field", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      local stat = results[1].targets[1]
      assert.is_string(stat.name)
      assert.is_number(stat.median)
      assert.is_number(stat.ci_lower)
      assert.is_number(stat.ci_upper)
      assert.is_number(stat.rounds)
      assert.is_number(stat.rank)
      assert.is_number(stat.ratio)
      assert.are_equal(1.0, stat.ratio)
      local stat2 = results[1].targets[2]
      assert.are_equal(2.0, stat2.ratio)
   end)

   it("run maps empty spec name to default in returned results", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      assert.are_equal("default", results[1].spec)
   end)

   it("run with multiple bench files returns results for all specs", function()
      local _, teardown = setup_run_stubs()
      local multi_bench = path.join(FIXTURE_DIR, "benchmarks", "multi_bench.lua")

      local results = runner.run({ SORT_BENCH, multi_bench }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      assert.are_equal(3, #results)
   end)

   it("run with opts.filters matching a pattern only runs matching benchmarks", function()
      local _, teardown = setup_run_stubs()
      local multi_bench = path.join(FIXTURE_DIR, "benchmarks", "multi_bench.lua")

      local results = runner.run(
         { SORT_BENCH, multi_bench },
         TARGETS_PAIR,
         { runtime = RUNTIME, filters = { "sort" } }
      )

      teardown()

      assert.are_equal(1, #results)
   end)

   it("run with multiple filters uses OR logic", function()
      local _, teardown = setup_run_stubs()
      local multi_bench = path.join(FIXTURE_DIR, "benchmarks", "multi_bench.lua")

      local results = runner.run(
         { SORT_BENCH, multi_bench },
         TARGETS_PAIR,
         { runtime = RUNTIME, filters = { "sort", "::a$" } }
      )

      teardown()

      assert.are_equal(2, #results)
   end)

   it("run with empty filters runs all benchmarks", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR, { runtime = RUNTIME, filters = {} })

      teardown()

      assert.are_equal(1, #results)
   end)

   it("run with filters eliminating all specs returns empty results without error", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run(
         { SORT_BENCH },
         TARGETS_PAIR,
         { runtime = RUNTIME, filters = { "nonexistent_pattern" } }
      )

      teardown()

      assert.are_same({}, results)
   end)

   it("run forwards rounds and params opts to subprocess", function()
      local spy_state, teardown = setup_run_stubs()

      runner.run(
         { SORT_BENCH },
         TARGETS_PAIR,
         { runtime = RUNTIME, rounds = 1, params = { n = { 100 } } }
      )

      teardown()

      local opts = spy_state.subprocess_calls[1].opts
      assert.are_equal(1, opts.rounds)
      assert.are_same({ n = { 100 } }, opts.params)
   end)

   it("run does not forward internal-only keys to subprocess", function()
      local spy_state, teardown = setup_run_stubs()

      runner.run(
         { SORT_BENCH },
         TARGETS_PAIR,
         { runtime = RUNTIME, rounds = 1, filters = { "sort" } }
      )

      teardown()

      local opts = spy_state.subprocess_calls[1].opts
      assert.are_equal(1, opts.rounds)
      assert.is_nil(opts.filters)
      assert.is_nil(opts.runtime)
   end)

   it("run passes targets with path and name to subprocess", function()
      local spy_state, teardown = setup_run_stubs()

      runner.run({ SORT_BENCH }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      local targets = spy_state.subprocess_calls[1].targets
      assert.is_table(targets)
      assert.are_equal(LIBV1_DIR, targets[1].path)
      assert.are_equal("libv1", targets[1].name)
      assert.are_equal(LIBV2_DIR, targets[2].path)
      assert.are_equal("libv2", targets[2].name)
   end)

   it("run when subprocess returns an error logs warning and returns empty results", function()
      local _, teardown, read_stderr = setup_run_stubs(function()
         return nil, "subprocess failed"
      end)

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR, RUNTIME_OPTS)

      local stderr_output = read_stderr()
      teardown()

      assert.are_same({}, results)
      assert.matches("subprocess error", stderr_output)
   end)

   it("run when subprocess raises an interrupted error re-raises it", function()
      local _, teardown = setup_run_stubs(function()
         return nil, "subprocess failed: interrupted!"
      end)

      local ok, err = pcall(runner.run, { SORT_BENCH }, TARGETS_PAIR, RUNTIME_OPTS)

      teardown()

      assert.is_false(ok)
      assert.matches("interrupted", tostring(err))
   end)

   --- Stub engines.get_adapter to return a mock adapter.
   --- @param mock_adapter table Mock adapter with a run method.
   --- @return fun() restore Restores the original function.
   local function stub_engine_adapter(mock_adapter)
      local engines = require("luabench.engines")
      local original = engines.get_adapter
      engines.get_adapter = function()
         return mock_adapter
      end
      return function()
         engines.get_adapter = original
      end
   end

   it("run with opts.engine_name uses the engine adapter and returns results", function()
      local _, teardown = setup_run_stubs()

      local restore_engine = stub_engine_adapter({
         run = function()
            return FAKE_RESULTS_V1
         end,
      })

      local results = runner.run(
         { SORT_BENCH },
         TARGETS_V1,
         { runtime = "/usr/bin/love", engine_name = "love", rounds = 1 }
      )

      restore_engine()
      teardown()

      assert.are_equal(1, #results)
   end)

   it("run when using engine adapter does not forward engine_name in opts", function()
      local _, teardown = setup_run_stubs()
      local captured_opts

      local restore = stub_engine_adapter({
         run = function(_, _, _, _, opts)
            captured_opts = opts
            return FAKE_RESULTS_V1
         end,
      })

      runner.run(
         { SORT_BENCH },
         TARGETS_V1,
         { runtime = "/usr/bin/love", engine_name = "love", rounds = 1 }
      )

      restore()
      teardown()

      assert.is_not_nil(captured_opts)
      assert.is_nil(captured_opts.engine_name)
      assert.are_equal(1, captured_opts.rounds)
   end)
end)
