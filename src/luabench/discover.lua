local lfs = require("lfs")

local BENCH_PATTERN = "_bench%.lua$"

--- Walk a directory recursively, collecting files matching a pattern.
--- @param dir string Directory to walk.
--- @param pattern string Lua pattern to match filenames against.
--- @param results string[] Accumulator for matched file paths.
local function walk_dir(dir, pattern, results)
   for entry in lfs.dir(dir) do
      if entry ~= "." and entry ~= ".." then
         local path = dir .. "/" .. entry
         local attr = lfs.attributes(path)
         if attr ~= nil then
            if attr.mode == "directory" then
               walk_dir(path, pattern, results)
            elseif attr.mode == "file" and path:match(pattern) then
               results[#results + 1] = path
            end
         end
      end
   end
end

--- Resolve a path to absolute using the current working directory.
--- @param path string Path to resolve.
--- @return string absolute Absolute path.
local function to_absolute(path)
   if path:sub(1, 1) == "/" then
      return path
   end
   return lfs.currentdir() .. "/" .. path
end

--- Discover benchmark files in the given paths.
--- @param paths string[] List of files or directories to search.
--- @return string[] bench_files Sorted list of absolute paths to *_bench.lua files.
local function discover(paths)
   local files = {}
   for i = 1, #paths do
      local path = paths[i]
      local attr = lfs.attributes(path)
      if attr ~= nil then
         if attr.mode == "file" and path:match(BENCH_PATTERN) then
            files[#files + 1] = to_absolute(path)
         elseif attr.mode == "directory" then
            walk_dir(path, BENCH_PATTERN, files)
         end
      end
   end

   -- Convert relative paths from walk_dir to absolute
   for i = 1, #files do
      files[i] = to_absolute(files[i])
   end

   table.sort(files)
   return files
end

return { discover = discover }
