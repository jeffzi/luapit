local engines = require("luapit.engines")
local loader = require("luapit.loader")
local luamark = require("luamark")
local path = require("pl.path")
local subprocess = require("luapit.subprocess")

local M = {}

--- Check if a bench ID matches any filter pattern (OR logic).
--- @param bench_id string Benchmark identity string.
--- @param filters string[]|nil Filter patterns.
--- @return boolean
local function matches_filter(bench_id, filters)
   if not filters or #filters == 0 then
      return true
   end
   for i = 1, #filters do
      if bench_id:match(filters[i]) then
         return true
      end
   end
   return false
end

--- Take a snapshot of all current package.loaded keys.
--- @return table<string, true>
local function snapshot_loaded()
   local snap = {}
   for k in pairs(package.loaded) do
      snap[k] = true
   end
   return snap
end

--- Remove any package.loaded entries not present in the snapshot.
--- @param snap table<string, true> Snapshot from snapshot_loaded().
local function restore_loaded(snap)
   for k in pairs(package.loaded) do
      if snap[k] == nil then
         package.loaded[k] = nil
      end
   end
end

--- Build package.path prefix for a target directory with optional subdirectory paths.
--- @param target_dir string Base directory.
--- @param lua_paths string[]|nil Subdirectory paths to add (nil = use target root).
--- @param original_path string Original package.path to append.
--- @return string path New package.path value.
local function build_package_path(target_dir, lua_paths, original_path)
   if not lua_paths or #lua_paths == 0 then
      return string.format("%s/?.lua;%s/?/init.lua;%s", target_dir, target_dir, original_path)
   end
   local segments = {}
   for i = 1, #lua_paths do
      local base = lua_paths[i] == "." and target_dir or (target_dir .. "/" .. lua_paths[i])
      segments[#segments + 1] = base .. "/?.lua"
      segments[#segments + 1] = base .. "/?/init.lua"
   end
   segments[#segments + 1] = original_path
   return table.concat(segments, ";")
end

--- Execute fn with package.path prepended for target_dir.
--- Restores package.path and cleans package.loaded even on error.
--- @param target_dir string Directory to prepend to package.path.
--- @param fn fun(): any, any Function to execute in the target context.
--- @param lua_paths string[]|nil Subdirectory paths within target to add to package.path.
--- @return any r1 First return of fn on success, or nil on error.
--- @return any r2 Second return of fn on success, or error message on error.
function M.with_target(target_dir, fn, lua_paths)
   local original_path = package.path
   local snap = snapshot_loaded()

   package.path = build_package_path(target_dir, lua_paths, original_path)

   local ok, r1, r2 = pcall(fn)

   restore_loaded(snap)
   package.path = original_path

   if not ok then
      return nil, r1
   end
   return r1, r2
end

--- Map luamark compare_time Result[] to per-target stat entries.
--- @param results table[] Array of luamark Result objects.
--- @return table[] stats Array of {name, median, ci_lower, ci_upper, rounds, rank, ratio}.
local function map_results(results)
   local stats = {}
   for i = 1, #results do
      local r = results[i]
      stats[#stats + 1] = {
         name = r.name,
         median = r.median,
         ci_lower = r.ci_lower,
         ci_upper = r.ci_upper,
         rounds = r.rounds,
         rank = r.rank,
         ratio = r.relative,
      }
   end
   return stats
end

local HEADER_PREFIX = string.char(0xe2, 0x96, 0x8c) -- U+258C ▌

--- Run a benchmark and print header + results.
--- @param id string Benchmark identity string.
--- @param run_fn fun(): table[]|nil, string|nil Function that returns results or nil+err.
--- @param err_label string Label for error messages (e.g. "benchmark error", "subprocess error").
--- @return table[]|nil results Raw luamark results, or nil on error.
local function run_with_output(id, run_fn, err_label)
   io.write(string.format("\n%s %s\n", HEADER_PREFIX, id))
   local ok, r1, r2 = pcall(run_fn)
   if not ok then
      io.flush()
      error(r1, 0)
   end
   if r1 ~= nil then
      io.write(luamark.render(r1) .. "\n")
   elseif type(r2) == "string" and r2:find("interrupted") then
      io.flush()
      error(r2, 0)
   else
      io.stderr:write(string.format("luapit: warning: %s in %s: %s\n", err_label, id, tostring(r2)))
   end
   io.flush()
   return r1
end

--- Load a benchmark file from each target.
--- @param bench_file string Absolute path to a benchmark file.
--- @param targets {path: string, name: string}[] Resolved targets to benchmark against.
--- @param lua_paths string[]|nil Subdirectory paths within target to add to package.path.
--- @return {name: string, path: string, result: table}[]
local function load_targets(bench_file, targets, lua_paths)
   local loaded = {}
   for j = 1, #targets do
      local target = targets[j]
      local result, load_err = M.with_target(target.path, function()
         return loader.load_benchmark(bench_file)
      end, lua_paths)
      if result ~= nil then
         loaded[#loaded + 1] = {
            name = target.name,
            path = target.path,
            result = result,
         }
      else
         local detail = load_err and (": " .. tostring(load_err)) or ""
         io.stderr:write(
            string.format(
               "luapit: warning: skipping %s for target %s%s\n",
               bench_file,
               target.name,
               detail
            )
         )
      end
   end
   return loaded
end

--- Collect unique, sorted spec names across all loaded targets.
--- @param loaded {result: table}[] Loaded target entries.
--- @return string[] spec_names Sorted unique spec names.
local function collect_spec_names(loaded)
   local names = {}
   local seen = {}
   for j = 1, #loaded do
      for name in pairs(loaded[j].result) do
         if seen[name] == nil then
            seen[name] = true
            names[#names + 1] = name
         end
      end
   end
   table.sort(names)
   return names
end

--- Build a result entry for the output array.
--- @param rel_path string Relative benchmark file path.
--- @param spec_name string Spec name ("" for single-spec).
--- @param results table[] Raw luamark results.
--- @return table entry Result entry with file, spec, and targets.
local function make_result_entry(rel_path, spec_name, results)
   return {
      file = rel_path:gsub("_bench%.lua$", ""),
      spec = spec_name == "" and "default" or spec_name,
      targets = map_results(results),
   }
end

--- Keys from opts that should not be forwarded to compare_time / adapters.
local INTERNAL_OPT_KEYS = { filters = true, runtime = true, engine_name = true }

--- Build compare_opts by copying opts without internal-only keys.
--- @param opts table Full options table.
--- @return table compare_opts Options safe to pass to compare_time / adapters.
local function build_compare_opts(opts)
   local compare_opts = {}
   for k, v in pairs(opts) do
      if not INTERNAL_OPT_KEYS[k] then
         compare_opts[k] = v
      end
   end
   return compare_opts
end

--- Run a single spec via subprocess or engine adapter.
--- @param bench_id string Benchmark identity string.
--- @param info table File info entry with bench_file, loaded, rel_path.
--- @param spec_name string Spec name to run.
--- @param opts table Full options (runtime, engine_name present).
--- @param compare_opts table Options for compare_time / adapters.
--- @return table|nil entry Result entry, or nil if skipped.
local function run_spec_subprocess(bench_id, info, spec_name, opts, compare_opts)
   local spec_targets = {}
   for j = 1, #info.loaded do
      if info.loaded[j].result[spec_name] ~= nil then
         spec_targets[#spec_targets + 1] = {
            path = info.loaded[j].path,
            name = info.loaded[j].name,
         }
      end
   end
   if #spec_targets == 0 then
      return nil
   end

   local engine_name = opts.engine_name
   local err_label = engine_name and "engine error" or "subprocess error"
   local results = run_with_output(bench_id, function()
      if engine_name ~= nil then
         local adapter = engines.get_adapter(engine_name)
         return adapter.run(opts.runtime, info.bench_file, spec_targets, spec_name, compare_opts)
      end
      return subprocess.run_subprocess(
         opts.runtime,
         info.bench_file,
         spec_targets,
         spec_name,
         compare_opts
      )
   end, err_label)

   if results ~= nil then
      return make_result_entry(info.rel_path, spec_name, results)
   end
end

--- Run a single spec in-process via luamark.compare_time.
--- @param bench_id string Benchmark identity string.
--- @param info table File info entry with loaded, rel_path.
--- @param spec_name string Spec name to run.
--- @param _ table Unused (uniform call signature with run_spec_subprocess).
--- @param compare_opts table Options for compare_time.
--- @return table|nil entry Result entry, or nil if skipped.
local function run_spec_inprocess(bench_id, info, spec_name, _, compare_opts)
   local funcs = {}
   for j = 1, #info.loaded do
      local entry = info.loaded[j]
      if entry.result[spec_name] ~= nil then
         funcs[entry.name] = entry.result[spec_name]
      end
   end
   if not next(funcs) then
      return nil
   end

   local results = run_with_output(bench_id, function()
      local ok, res = pcall(luamark.compare_time, funcs, compare_opts)
      if not ok then
         if type(res) == "string" and res:find("interrupted") then
            error(res, 0)
         end
         return nil, res
      end
      return res
   end, "benchmark error")

   if results ~= nil then
      return make_result_entry(info.rel_path, spec_name, results)
   end
end

--- Run benchmarks across targets.
--- @param bench_files string[] Absolute paths to benchmark files.
--- @param targets {path: string, name: string}[] Resolved targets to benchmark against.
--- @param opts table|nil Options: filters (string[]), rounds (number), params (table).
--- @return table[] all_results Flat array of {file, spec, targets} benchmark result entries.
function M.run(bench_files, targets, opts)
   opts = opts or {}
   local filters = opts.filters
   local lua_paths = opts.lua_path
   local compare_opts = build_compare_opts(opts)
   local run_spec = opts.runtime and run_spec_subprocess or run_spec_inprocess

   local all_results = {}

   local file_info = {}
   for i = 1, #bench_files do
      local bench_file = bench_files[i]
      local rel_path = path.relpath(bench_file)
      local loaded = load_targets(bench_file, targets, lua_paths)
      local spec_names = {}
      if #loaded > 0 then
         local all_names = collect_spec_names(loaded)
         for si = 1, #all_names do
            local name = all_names[si]
            local bench_id = loader.bench_id(rel_path, name)
            if matches_filter(bench_id, filters) then
               spec_names[#spec_names + 1] = name
            end
         end
      end
      file_info[i] =
         { bench_file = bench_file, rel_path = rel_path, loaded = loaded, spec_names = spec_names }
   end

   local loop_ok, loop_err = pcall(function()
      for i = 1, #file_info do
         local info = file_info[i]
         for si = 1, #info.spec_names do
            local spec_name = info.spec_names[si]
            local bench_id = loader.bench_id(info.rel_path, spec_name)
            local entry = run_spec(bench_id, info, spec_name, opts, compare_opts)
            if entry ~= nil then
               all_results[#all_results + 1] = entry
            end
         end
      end
   end)

   if not loop_ok then
      error(loop_err, 0)
   end
   return all_results
end

return M
