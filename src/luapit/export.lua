local json = require("dkjson")
local utils = require("pl.utils")

local M = {}

--- Write benchmark results to a JSON file with metadata envelope.
--- @param filepath string Output file path.
--- @param results table[] Flat array of {file, spec, targets} benchmark result entries.
--- @param targets {name: string, original_spec: string|nil}[] Resolved targets.
--- @param version string LuaPit version string.
--- @return true|nil ok True on success, nil on failure.
--- @return string|nil err Error message on failure.
function M.write_json(filepath, results, targets, version)
   local target_list = {}
   for i = 1, #targets do
      local t = targets[i]
      target_list[#target_list + 1] = {
         name = t.name,
         spec = t.original_spec or t.name,
      }
   end

   local envelope = {
      version = version,
      timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      targets = target_list,
      results = results,
   }

   local encoded = json.encode(envelope, {
      indent = true,
      keyorder = { "version", "timestamp", "targets", "results" },
   })

   local ok, err = utils.writefile(filepath, encoded)
   if not ok then
      return nil, err
   end

   return true
end

return M
