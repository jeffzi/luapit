local M = {}

--- Map engine names to adapter module paths (loaded lazily).
--- @type table<string, string>
local ENGINES = {
   love = "luabench.engines.love2d",
   defold = "luabench.engines.defold",
}

--- Check if a runtime name or path matches a known engine adapter.
--- Extract basename from path, strip .exe suffix, look up in ENGINES table.
--- @param name string Runtime name or absolute path.
--- @return string|nil engine_name Matched engine name, or nil for unknown runtimes.
function M.detect(name)
   local basename = name:match("([^/\\]+)$") or name
   basename = basename:gsub("%.exe$", "")
   if ENGINES[basename] ~= nil then
      return basename
   end
   return nil
end

--- Get the adapter module for a known engine (lazy-loaded via require).
--- @param engine_name string Engine name returned by detect().
--- @return table adapter Engine adapter module with run() function.
function M.get_adapter(engine_name)
   return require(ENGINES[engine_name])
end

--- Locate an installed Lua module's source file on disk.
--- Try package.searchpath first (Lua 5.2+, LuaJIT), fall back to manual
--- iteration of package.path templates for Lua 5.1 compatibility.
--- @param modname string Module name (e.g. "luamark", "dkjson").
--- @return string|nil path Absolute path to the module source file.
--- @return string|nil err Error message if module source not found.
function M.find_module_path(modname)
   ---@diagnostic disable-next-line: deprecated
   if package.searchpath then --luacheck: ignore 143
      ---@diagnostic disable-next-line: deprecated
      local found = package.searchpath(modname, package.path) --luacheck: ignore 143
      if found then
         return found
      end
   end
   local sep = package.config:sub(1, 1)
   local mod_file = modname:gsub("%.", sep)
   for template in package.path:gmatch("[^;]+") do
      local fpath = template:gsub("%?", mod_file)
      local f = io.open(fpath, "r")
      if f then
         f:close()
         return fpath
      end
   end
   return nil, "module source not found: " .. modname
end

return M
