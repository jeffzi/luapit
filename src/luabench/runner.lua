local Progress = require("luabench.progress")
local engines = require("luabench.engines")
local loader = require("luabench.loader")
local luamark = require("luamark")
local path = require("pl.path")
local subprocess = require("luabench.subprocess")
local system = require("system")

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

--- Execute fn with package.path prepended for target_dir.
--- Restores package.path and cleans package.loaded even on error.
--- @param target_dir string Directory to prepend to package.path.
--- @param fn fun(): any Function to execute in the target context.
--- @return any result Result of fn on success, or nil on error.
--- @return string|nil err Error message if fn raised an error.
function M.with_target(target_dir, fn)
   local original_path = package.path
   local snap = snapshot_loaded()

   package.path = string.format("%s/?.lua;%s/?/init.lua;%s", target_dir, target_dir, original_path)

   local ok, result = pcall(fn)

   restore_loaded(snap)
   package.path = original_path

   if not ok then
      return nil, result
   end
   return result
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

--- Run a benchmark with bar suspend/resume and output rendering.
--- @param id string Benchmark identity string.
--- @param bar ProgressBar Progress bar instance.
--- @param run_fn fun(): table[]|nil, string|nil Function that returns results or nil+err.
--- @param err_label string Label for error messages (e.g. "benchmark error", "subprocess error").
--- @return table[]|nil results Raw luamark results, or nil on error.
local function run_with_output(id, bar, run_fn, err_label)
   bar:suspend()
   io.write(string.format("\n%s %s\n", HEADER_PREFIX, id))
   local results, err = run_fn()
   if not results then
      io.stderr:write(
         string.format("luabench: warning: %s in %s: %s\n", err_label, id, tostring(err))
      )
      io.flush()
      bar:resume()
      return nil
   end
   io.write(luamark.render(results) .. "\n")
   io.flush()
   bar:resume()
   return results
end

--- Load a benchmark file from each target.
--- @param bench_file string Absolute path to a benchmark file.
--- @param targets {path: string, name: string}[] Resolved targets to benchmark against.
--- @return {name: string, path: string, result: table}[]
local function load_targets(bench_file, targets)
   local loaded = {}
   for j = 1, #targets do
      local target = targets[j]
      local result = M.with_target(target.path, function()
         return loader.load_benchmark(bench_file)
      end)
      if result then
         loaded[#loaded + 1] = {
            name = target.name,
            path = target.path,
            result = result,
         }
      else
         io.stderr:write(
            string.format("luabench: warning: skipping %s for target %s\n", bench_file, target.name)
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
         if not seen[name] then
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

--- Run benchmarks across targets.
--- @param bench_files string[] Absolute paths to benchmark files.
--- @param targets {path: string, name: string}[] Resolved targets to benchmark against.
--- @param opts table|nil Options: filters (string[]), rounds (number), params (table).
--- @return table[] all_results Flat array of {file, spec, targets} benchmark result entries.
function M.run(bench_files, targets, opts)
   opts = opts or {}
   local filters = opts.filters
   local compare_opts = {}
   for k, v in pairs(opts) do
      if k ~= "filters" and k ~= "runtime" and k ~= "engine_name" then
         compare_opts[k] = v
      end
   end

   local all_results = {}

   -- Pre-scan: load all bench files and count filtered spec executions.
   local file_info = {}
   local total = 0
   for i = 1, #bench_files do
      local bench_file = bench_files[i]
      local rel_path = path.relpath(bench_file)
      local loaded = load_targets(bench_file, targets)
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
         total = total + #spec_names
      end
      file_info[i] =
         { bench_file = bench_file, rel_path = rel_path, loaded = loaded, spec_names = spec_names }
   end

   local bar = Progress({
      total = total,
      template = "{bar} {pos}/{len} {msg} [{elapsed}<{eta}]",
      disable = not system.isatty(io.stderr),
   })
   bar:start()
   local pos = 0

   for i = 1, #file_info do
      local info = file_info[i]
      local rel_path = info.rel_path
      local loaded = info.loaded
      local spec_names = info.spec_names

      if #loaded > 0 then
         for si = 1, #spec_names do
            local spec_name = spec_names[si]
            local bench_id = loader.bench_id(rel_path, spec_name)
            if opts.runtime then
               -- Subprocess execution path
               local spec_targets = {}
               for j = 1, #loaded do
                  if loaded[j].result[spec_name] then
                     spec_targets[#spec_targets + 1] = {
                        path = loaded[j].path,
                        name = loaded[j].name,
                     }
                  end
               end
               if #spec_targets > 0 then
                  local engine_name = opts.engine_name
                  local err_label = engine_name and "engine error" or "subprocess error"
                  local results = run_with_output(bench_id, bar, function()
                     if engine_name then
                        local adapter = engines.get_adapter(engine_name)
                        return adapter.run(
                           opts.runtime,
                           info.bench_file,
                           spec_targets,
                           spec_name,
                           compare_opts
                        )
                     end
                     return subprocess.run_subprocess(
                        opts.runtime,
                        info.bench_file,
                        spec_targets,
                        spec_name,
                        compare_opts
                     )
                  end, err_label)
                  pos = pos + 1
                  bar:update(pos, bench_id)
                  if results then
                     all_results[#all_results + 1] = make_result_entry(rel_path, spec_name, results)
                  end
               end
            else
               -- In-process execution path
               local funcs = {}
               for j = 1, #loaded do
                  local entry = loaded[j]
                  if entry.result[spec_name] then
                     funcs[entry.name] = entry.result[spec_name]
                  end
               end
               if next(funcs) then
                  local results = run_with_output(bench_id, bar, function()
                     local ok, res = pcall(luamark.compare_time, funcs, compare_opts)
                     if not ok then
                        return nil, res
                     end
                     return res
                  end, "benchmark error")
                  pos = pos + 1
                  bar:update(pos, bench_id)
                  if results then
                     all_results[#all_results + 1] = make_result_entry(rel_path, spec_name, results)
                  end
               end
            end
         end
      end
   end

   bar:stop()
   return all_results
end

return M
