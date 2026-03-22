local M = {}

--- Load a benchmark file and return a normalized spec map.
--- Single-Spec files (with a top-level `fn`) are keyed by `""`.
--- Named-Spec files are returned as-is (keyed by spec name).
--- @param filepath string Absolute path to a `*_bench.lua` file.
--- @return table<string, table>|nil specs Spec map, or nil on error.
function M.load_benchmark(filepath)
   local ok, result = pcall(dofile, filepath)
   if not ok then
      io.stderr:write(
         string.format("luabench: warning: failed to load %s: %s\n", filepath, tostring(result))
      )
      return nil
   end

   if type(result) ~= "table" then
      io.stderr:write("luabench: warning: " .. filepath .. " did not return a table\n")
      return nil
   end

   if result.fn then
      return { [""] = result }
   else
      return result
   end
end

--- Derive benchmark identity from file path.
--- @param filepath string Path to benchmark file.
--- @param spec_name string|nil Optional Spec name for named-Spec files.
--- @return string
function M.bench_id(filepath, spec_name)
   local id = filepath:gsub("_bench%.lua$", "")
   if spec_name and spec_name ~= "" then
      id = id .. "::" .. spec_name
   end
   return id
end

return M
