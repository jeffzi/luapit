local loader = require("luabench.loader")
local luamark = require("luamark")
local path = require("pl.path")
local Progress = require("luabench.progress")
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

--- Run a single-Spec benchmark across targets.
--- @param id string Benchmark identity string.
--- @param funcs table<string, table> Map of target_name -> Spec.
--- @param bar ProgressBar|nil Progress bar instance for suspend/resume around output.
--- @param opts table|nil Options to forward to luamark.compare_time.
--- @return table[]|nil results Raw luamark compare_time results, or nil on error.
local function run_single(id, funcs, bar, opts)
   if bar then
      bar:suspend()
   end
   io.write(string.format("\n%s %s\n", HEADER_PREFIX, id))
   local ok, results = pcall(luamark.compare_time, funcs, opts)
   if not ok then
      io.stderr:write(
         string.format("luabench: warning: benchmark error in %s: %s\n", id, tostring(results))
      )
      io.flush()
      if bar then
         bar:resume()
      end
      return nil
   end
   io.write(luamark.render(results) .. "\n")
   io.flush()
   if bar then
      bar:resume()
   end
   return results
end

--- Load a benchmark file from each target.
--- @param bench_file string Absolute path to a benchmark file.
--- @param targets {path: string, name: string}[] Resolved targets to benchmark against.
--- @return {name: string, result: table}[]
local function load_targets(bench_file, targets)
   local loaded = {}
   for j = 1, #targets do
      local target = targets[j]
      local result = M.with_target(target.path, function()
         return loader.load_benchmark(bench_file)
      end)
      if result ~= nil then
         loaded[#loaded + 1] = {
            name = target.name,
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
      if k ~= "filters" and k ~= "runtime" then
         compare_opts[k] = v
      end
   end

   local all_results = {}
   local total = #bench_files * #targets
   local bar = Progress({
      total = total,
      template = "{bar} {pos}/{len} {msg} [{elapsed}<{eta}]",
      disable = not system.isatty(io.stderr),
   })
   bar:start()
   local pos = 0

   for i = 1, #bench_files do
      local bench_file = bench_files[i]
      local rel_path = path.relpath(bench_file)
      local loaded = load_targets(bench_file, targets)

      if #loaded > 0 then
         local spec_names = {}
         local seen = {}
         for j = 1, #loaded do
            for name in pairs(loaded[j].result) do
               if seen[name] == nil then
                  seen[name] = true
                  spec_names[#spec_names + 1] = name
               end
            end
         end
         table.sort(spec_names)

         for si = 1, #spec_names do
            local spec_name = spec_names[si]
            local funcs = {}
            for j = 1, #loaded do
               local entry = loaded[j]
               if entry.result[spec_name] ~= nil then
                  funcs[entry.name] = entry.result[spec_name]
               end
            end
            if next(funcs) ~= nil then
               local bench_id = loader.bench_id(rel_path, spec_name)
               if matches_filter(bench_id, filters) then
                  local results = run_single(bench_id, funcs, bar, compare_opts)
                  pos = pos + 1
                  bar:update(pos, bench_id)
                  if results ~= nil then
                     all_results[#all_results + 1] = {
                        file = rel_path:gsub("_bench%.lua$", ""),
                        spec = spec_name == "" and "default" or spec_name,
                        targets = map_results(results),
                     }
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
