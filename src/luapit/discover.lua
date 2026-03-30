local dir = require("pl.dir")
local path = require("pl.path")

local BENCH_PATTERN = "_bench%.lua$"

--- Discover benchmark files in the given paths.
--- @param paths string[] List of files or directories to search.
--- @return string[] bench_files Sorted list of absolute paths to *_bench.lua files.
local function discover(paths)
   local files = {}
   for i = 1, #paths do
      local p = paths[i]
      if path.isfile(p) and p:match(BENCH_PATTERN) then
         files[#files + 1] = path.abspath(p)
      elseif path.isdir(p) then
         local found = dir.getallfiles(p, "*_bench.lua")
         for j = 1, #found do
            files[#files + 1] = path.abspath(found[j])
         end
      end
   end

   table.sort(files)
   return files
end

return { discover = discover }
