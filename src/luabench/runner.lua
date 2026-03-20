local lfs = require("lfs")
local loader = require("luabench.loader")
local luamark = require("luamark")

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
      if not snap[k] then
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

   package.path = target_dir .. "/?.lua;" .. target_dir .. "/?/init.lua;" .. original_path

   local ok, result = pcall(fn)

   restore_loaded(snap)
   package.path = original_path

   if not ok then
      return nil, result
   end
   return result
end

--- Extract basename from a directory path.
--- @param dir string Directory path.
--- @return string
local function dir_basename(dir)
   return dir:match("([^/]+)$") or dir
end

--- Compute relative path from current working directory.
--- @param filepath string Absolute or relative file path.
--- @return string
local function relative_path(filepath)
   local cwd = lfs.currentdir()
   if cwd ~= nil and filepath:sub(1, #cwd) == cwd then
      return filepath:sub(#cwd + 2)
   end
   return filepath
end

--- Run a single-Spec benchmark across targets.
--- @param id string Benchmark identity string.
--- @param funcs table<string, table> Map of target_name -> Spec.
local function run_single(id, funcs)
   io.write("\n-- " .. id .. " --\n")
   local ok, results = pcall(luamark.compare_time, funcs)
   if not ok then
      io.stderr:write(
         "luabench: warning: benchmark error in " .. id .. ": " .. tostring(results) .. "\n"
      )
      return
   end
   io.write(luamark.render(results) .. "\n")
end

--- Run benchmarks across target directories.
--- @param bench_files string[] Absolute paths to benchmark files.
--- @param targets string[] Directory paths to benchmark against.
function M.run(bench_files, targets)
   for i = 1, #bench_files do
      local bench_file = bench_files[i]
      local rel_path = relative_path(bench_file)

      -- Collect specs from each target
      local loaded = {}
      for j = 1, #targets do
         local target_dir = targets[j]
         local result = M.with_target(target_dir, function()
            return loader.load_benchmark(bench_file)
         end)
         if result ~= nil then
            loaded[#loaded + 1] = {
               name = dir_basename(target_dir),
               result = result,
            }
         else
            io.stderr:write(
               "luabench: warning: skipping " .. bench_file .. " for target " .. target_dir .. "\n"
            )
         end
      end

      -- Skip if no targets loaded successfully
      if #loaded > 0 then
         local first_result = loaded[1].result

         if first_result.single then
            -- Single-Spec file: one compare_time call
            local funcs = {}
            for j = 1, #loaded do
               funcs[loaded[j].name] = loaded[j].result.single
            end
            local id = loader.bench_id(rel_path)
            run_single(id, funcs)
         else
            -- Named-Specs file: one compare_time call per named Spec
            local spec_names = {}
            for name in pairs(first_result.named) do
               spec_names[#spec_names + 1] = name
            end
            table.sort(spec_names)

            for _, spec_name in ipairs(spec_names) do
               local funcs = {}
               local has_any = false
               for j = 1, #loaded do
                  local entry = loaded[j]
                  if entry.result.named[spec_name] ~= nil then
                     funcs[entry.name] = entry.result.named[spec_name]
                     has_any = true
                  end
               end
               if has_any then
                  local id = loader.bench_id(rel_path, spec_name)
                  run_single(id, funcs)
               end
            end
         end
      end
   end
end

return M
