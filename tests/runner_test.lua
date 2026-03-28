---@diagnostic disable: need-check-nil, duplicate-set-field, unused-local

local path = require("pl.path")

describe("runner", function()
   local runner

   local CWD = path.currentdir()
   local FIXTURE_DIR = CWD .. "/tests/fixtures"
   local LIBV1_DIR = FIXTURE_DIR .. "/targets/libv1"
   local LIBV2_DIR = FIXTURE_DIR .. "/targets/libv2"
   local SORT_BENCH = FIXTURE_DIR .. "/benchmarks/sort_bench.lua"

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
      local LIB_SUB_DIR = FIXTURE_DIR .. "/targets/lib_sub"

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

   --- Set up luamark and io stubs for run() tests.
   --- @return table spy_state, fun() teardown, fun() read_stderr
   local function setup_run_stubs()
      local luamark = require("luamark")
      local originals = {
         compare = luamark.compare_time,
         render = luamark.render,
         write = io.write,
         stderr = io.stderr,
      }

      local spy_state = { compare_calls = {}, output = {} }

      luamark.compare_time = function(funcs, opts)
         spy_state.compare_calls[#spy_state.compare_calls + 1] = { funcs = funcs, opts = opts }
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
         luamark.compare_time = originals.compare
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

   it("run calls compare_time with target specs and renders output with header", function()
      local spy_state, teardown = setup_run_stubs()

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR)

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
      local compare_args = spy_state.compare_calls[1].funcs
      assert.is_not_nil(compare_args["libv1"])
      assert.is_not_nil(compare_args["libv2"])
      local combined = table.concat(spy_state.output)
      local header_prefix = string.char(0xe2, 0x96, 0x8c) -- U+258C ▌
      assert.matches(header_prefix, combined)
      assert.matches("sort", combined)
      assert.matches("rendered", combined)
      assert.is_table(results)
   end)

   it("run skips benchmark when load_benchmark returns nil for all targets", function()
      local spy_state, teardown = setup_run_stubs()

      runner.run({ FIXTURE_DIR .. "/nonexistent_bench.lua" }, TARGETS_PAIR)

      teardown()

      assert.are_equal(0, #spy_state.compare_calls)
   end)

   it("run skips target when load fails and continues with remaining targets", function()
      local spy_state, teardown = setup_run_stubs()

      runner.run({ SORT_BENCH }, { TARGET_V1, { path = "/nonexistent/target", name = "bad" } })

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
      assert.is_not_nil(spy_state.compare_calls[1].funcs["libv1"])
   end)

   it("run includes error reason in skip warning when with_target errors", function()
      local _, teardown, read_stderr = setup_run_stubs()
      local loader = require("luabench.loader")
      local original_load = loader.load_benchmark
      loader.load_benchmark = function()
         error("deliberate load error")
      end

      runner.run({ SORT_BENCH }, TARGETS_V1)

      local stderr_output = read_stderr()
      loader.load_benchmark = original_load
      teardown()

      assert.matches("deliberate load error", stderr_output)
   end)

   it("run handles named-Specs file calling compare_time per named Spec", function()
      local spy_state, teardown = setup_run_stubs()
      local multi_bench = FIXTURE_DIR .. "/benchmarks/multi_bench.lua"

      runner.run({ multi_bench }, TARGETS_PAIR)

      teardown()

      assert.are_equal(2, #spy_state.compare_calls)
   end)

   it("run forwards Spec hook fields to compare_time", function()
      local spy_state, teardown = setup_run_stubs()
      local hooks_bench = FIXTURE_DIR .. "/benchmarks/hooks_bench.lua"

      runner.run({ hooks_bench }, TARGETS_V1)

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
      local spec = spy_state.compare_calls[1].funcs["libv1"]
      assert.is_function(spec.fn)
      assert.is_function(spec.before)
      assert.is_function(spec.after)
      assert.is_true(spec.baseline)
   end)

   it("run collects spec names from all targets, not just the first", function()
      local spy_state, teardown = setup_run_stubs()
      local asym_bench = FIXTURE_DIR .. "/benchmarks/asymmetric_bench.lua"

      runner.run({ asym_bench }, TARGETS_PAIR)

      teardown()

      assert.are_equal(2, #spy_state.compare_calls)
   end)

   it("run catches compare_time errors and continues", function()
      local _, teardown, read_stderr = setup_run_stubs()
      local luamark = require("luamark")
      local call_count = 0
      luamark.compare_time = function()
         call_count = call_count + 1
         if call_count == 1 then
            error("compare failed")
         end
         return FAKE_RESULTS_V1
      end

      runner.run({ SORT_BENCH, FIXTURE_DIR .. "/benchmarks/sort_bench.lua" }, TARGETS_PAIR)

      local stderr_output = read_stderr()
      teardown()

      assert.matches("warning", stderr_output)
   end)

   it("run returns flat results array with file, spec, and targets fields", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR)

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

   it("run maps luamark Result fields to stat entries with ratio field", function()
      local _, teardown = setup_run_stubs()

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR)

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

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR)

      teardown()

      assert.are_equal("default", results[1].spec)
   end)

   it("run with multiple bench files returns results for all specs", function()
      local spy_state, teardown = setup_run_stubs()
      local multi_bench = FIXTURE_DIR .. "/benchmarks/multi_bench.lua"

      local results = runner.run({ SORT_BENCH, multi_bench }, TARGETS_PAIR)

      teardown()

      -- sort_bench has 1 spec, multi_bench has 2 specs = 3 compare_time calls
      assert.are_equal(3, #spy_state.compare_calls)
      assert.are_equal(3, #results)
   end)

   it("run with opts.filters matching a pattern only runs matching benchmarks", function()
      local spy_state, teardown = setup_run_stubs()
      local multi_bench = FIXTURE_DIR .. "/benchmarks/multi_bench.lua"

      runner.run({ SORT_BENCH, multi_bench }, TARGETS_PAIR, { filters = { "sort" } })

      teardown()

      -- sort_bench matches "sort", multi_bench specs (alpha, beta) do not
      assert.are_equal(1, #spy_state.compare_calls)
   end)

   it("run with multiple filters uses OR logic", function()
      local spy_state, teardown = setup_run_stubs()
      local multi_bench = FIXTURE_DIR .. "/benchmarks/multi_bench.lua"

      runner.run({ SORT_BENCH, multi_bench }, TARGETS_PAIR, { filters = { "sort", "::a$" } })

      teardown()

      -- sort_bench matches "sort", multi_bench::a matches "::a$", multi_bench::b does not
      assert.are_equal(2, #spy_state.compare_calls)
   end)

   it("run with empty filters runs all benchmarks", function()
      local spy_state, teardown = setup_run_stubs()

      runner.run({ SORT_BENCH }, TARGETS_PAIR, { filters = {} })

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
   end)

   it("run with filters eliminating all specs returns empty results without error", function()
      local spy_state, teardown = setup_run_stubs()

      local results = runner.run(
         { SORT_BENCH },
         TARGETS_PAIR,
         { filters = { "nonexistent_pattern" } }
      )

      teardown()

      assert.are_equal(0, #spy_state.compare_calls)
      assert.are_same({}, results)
   end)

   it("run forwards rounds and params opts to compare_time", function()
      local spy_state, teardown = setup_run_stubs()

      runner.run({ SORT_BENCH }, TARGETS_PAIR, { rounds = 1, params = { n = { 100 } } })

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
      assert.are_equal(1, spy_state.compare_calls[1].opts.rounds)
      assert.are_same({ n = { 100 } }, spy_state.compare_calls[1].opts.params)
   end)

   it("run does not forward internal-only keys to compare_time", function()
      local spy_state, teardown = setup_run_stubs()

      runner.run({ SORT_BENCH }, TARGETS_PAIR, { rounds = 1, filters = { "sort" } })

      teardown()

      assert.are_equal(1, #spy_state.compare_calls)
      local opts = spy_state.compare_calls[1].opts
      assert.are_equal(1, opts.rounds)
      assert.is_nil(opts.filters)
      assert.is_nil(opts.runtime)
   end)

   --- Stub subprocess.run_subprocess for the duration of a test.
   --- @param fake_fn function Replacement for subprocess.run_subprocess.
   --- @return fun() restore Restores the original function.
   local function stub_subprocess(fake_fn)
      local subprocess = require("luabench.subprocess")
      local original = subprocess.run_subprocess
      subprocess.run_subprocess = fake_fn
      return function()
         subprocess.run_subprocess = original
      end
   end

   it("run with opts.runtime calls subprocess.run_subprocess instead of compare_time", function()
      local spy_state, teardown = setup_run_stubs()
      local subprocess_calls = {}

      local restore = stub_subprocess(function(runtime_path, bench_file, targets, spec_name, opts)
         subprocess_calls[#subprocess_calls + 1] = {
            runtime_path = runtime_path,
            bench_file = bench_file,
            targets = targets,
            spec_name = spec_name,
            opts = opts,
         }
         return FAKE_RESULTS_PAIR
      end)

      local results = runner.run(
         { SORT_BENCH },
         TARGETS_PAIR,
         { runtime = "/usr/bin/lua", rounds = 1 }
      )

      restore()
      teardown()

      assert.are_equal(0, #spy_state.compare_calls)
      assert.are_equal(1, #subprocess_calls)
      assert.are_equal("/usr/bin/lua", subprocess_calls[1].runtime_path)
      assert.is_table(subprocess_calls[1].targets)
      assert.are_equal(2, #subprocess_calls[1].targets)
      assert.is_table(results)
      assert.are_equal(1, #results)
   end)

   it("run with opts.runtime receives spec_targets with path and name", function()
      local _, teardown = setup_run_stubs()
      local captured_targets

      local restore = stub_subprocess(function(_, _, targets)
         captured_targets = targets
         return FAKE_RESULTS_V1
      end)

      runner.run({ SORT_BENCH }, TARGETS_PAIR, { runtime = "/usr/bin/lua" })

      restore()
      teardown()

      assert.is_table(captured_targets)
      assert.are_equal(LIBV1_DIR, captured_targets[1].path)
      assert.are_equal("libv1", captured_targets[1].name)
      assert.are_equal(LIBV2_DIR, captured_targets[2].path)
      assert.are_equal("libv2", captured_targets[2].name)
   end)

   it("run with opts.runtime handles subprocess error gracefully", function()
      local _, teardown, read_stderr = setup_run_stubs()

      local restore = stub_subprocess(function()
         return nil, "subprocess failed"
      end)

      local results = runner.run({ SORT_BENCH }, TARGETS_PAIR, { runtime = "/usr/bin/lua" })

      local stderr_output = read_stderr()
      restore()
      teardown()

      assert.are_same({}, results)
      assert.matches("subprocess error", stderr_output)
   end)

   it("run with opts.runtime re-raises subprocess interrupted error", function()
      local _, teardown = setup_run_stubs()

      local restore = stub_subprocess(function()
         return nil, "subprocess failed: interrupted!"
      end)

      local ok, err = pcall(runner.run, { SORT_BENCH }, TARGETS_PAIR, { runtime = "/usr/bin/lua" })

      restore()
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

   it("run with opts.engine_name calls adapter run instead of subprocess.run_subprocess", function()
      local spy_state, teardown = setup_run_stubs()
      local adapter_calls = {}
      local subprocess_calls = {}

      local restore_engine = stub_engine_adapter({
         run = function(runtime_path, bench_file, targets, spec_name, opts)
            adapter_calls[#adapter_calls + 1] = {
               runtime_path = runtime_path,
               bench_file = bench_file,
               targets = targets,
               spec_name = spec_name,
               opts = opts,
            }
            return FAKE_RESULTS_V1
         end,
      })
      local restore_subprocess = stub_subprocess(function(...)
         subprocess_calls[#subprocess_calls + 1] = { ... }
         return FAKE_RESULTS_V1
      end)

      runner.run(
         { SORT_BENCH },
         TARGETS_V1,
         { runtime = "/usr/bin/love", engine_name = "love", rounds = 1 }
      )

      restore_engine()
      restore_subprocess()
      teardown()

      assert.are_equal(1, #adapter_calls)
      assert.are_equal(0, #subprocess_calls)
      assert.are_equal(0, #spy_state.compare_calls)
   end)

   it("run without opts.engine_name and with opts.runtime uses subprocess path", function()
      local spy_state, teardown = setup_run_stubs()
      local subprocess_calls = {}

      local restore = stub_subprocess(function(...)
         subprocess_calls[#subprocess_calls + 1] = { ... }
         return FAKE_RESULTS_V1
      end)

      runner.run({ SORT_BENCH }, TARGETS_V1, { runtime = "/usr/bin/luajit", rounds = 1 })

      restore()
      teardown()

      assert.are_equal(1, #subprocess_calls)
      assert.are_equal(0, #spy_state.compare_calls)
   end)

   it("run with opts.engine_name does not forward engine_name to compare_opts", function()
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

   it("run re-raises interrupt errors from compare_time", function()
      local _, teardown = setup_run_stubs()
      local luamark = require("luamark")
      luamark.compare_time = function()
         error("interrupted!")
      end

      local ok, err = pcall(runner.run, { SORT_BENCH }, TARGETS_PAIR)

      teardown()

      assert.is_false(ok)
      assert.matches("interrupted", tostring(err))
   end)
end)
