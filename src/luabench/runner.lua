local loader = require("luabench.loader")
local luamark = require("luamark")
local path = require("pl.path")

local M = {}

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

--- Run a single-Spec benchmark across targets.
--- @param id string Benchmark identity string.
--- @param funcs table<string, table> Map of target_name -> Spec.
local function run_single(id, funcs)
   io.write(string.format("\n-- %s --\n", id))
   local ok, results = pcall(luamark.compare_time, funcs)
   if not ok then
      io.stderr:write(
         string.format("luabench: warning: benchmark error in %s: %s\n", id, tostring(results))
      )
      return
   end
   io.write(luamark.render(results) .. "\n")
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
function M.run(bench_files, targets)
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
               run_single(loader.bench_id(rel_path, spec_name), funcs)
            end
         end
      end
   end
end

return M
