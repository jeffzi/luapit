local M = {}

--- Load a benchmark file and detect its format.
--- @param filepath string Absolute path to a `*_bench.lua` file.
--- @return {single: table}|{named: table<string, table>}|nil
function M.load_benchmark(filepath)
   local ok, result = pcall(dofile, filepath)
   if not ok then
      io.stderr:write(
         "luabench: warning: failed to load " .. filepath .. ": " .. tostring(result) .. "\n"
      )
      return nil
   end

   if type(result) ~= "table" then
      io.stderr:write("luabench: warning: " .. filepath .. " did not return a table\n")
      return nil
   end

   if result.fn ~= nil then
      return { single = result }
   else
      return { named = result }
   end
end

--- Derive benchmark identity from file path.
--- @param filepath string Path to benchmark file.
--- @param spec_name string|nil Optional Spec name for named-Spec files.
--- @return string
function M.bench_id(filepath, spec_name)
   local id = filepath:gsub("_bench%.lua$", "")
   if spec_name ~= nil then
      id = id .. "::" .. spec_name
   end
   return id
end

return M
