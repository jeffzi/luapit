local utils = require("pl.utils")

local quote_arg = utils.quote_arg

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
   if ENGINES[basename] then
      return basename
   end
end

--- Get the adapter module for a known engine (lazy-loaded via require).
--- @param engine_name string Engine name returned by detect().
--- @return table adapter Engine adapter module with run() function.
function M.get_adapter(engine_name)
   return require(ENGINES[engine_name])
end

--- Copy a file from src to dst using binary-safe read/write.
--- @param src string Source file path.
--- @param dst string Destination file path.
--- @return boolean ok True on success.
--- @return string|nil err Error message on failure.
function M.copy_file(src, dst)
   local sf = io.open(src, "rb")
   if not sf then
      return false, "cannot open source: " .. src
   end
   local content = sf:read("*a")
   sf:close()
   local df = io.open(dst, "wb")
   if not df then
      return false, "cannot open destination: " .. dst
   end
   df:write(content)
   df:close()
   return true
end

--- Search PATH for a command and return its absolute path.
--- @param cmd string Command name to look up.
--- @return string|nil path Absolute path if found, nil otherwise.
function M.find_command(cmd)
   local h = io.popen("command -v " .. quote_arg(cmd) .. " 2>/dev/null")
   if not h then
      return nil
   end
   local ok, result = pcall(h.read, h, "*a")
   h:close()
   if not ok or not result then
      return nil
   end
   result = result:match("^(.-)%s*$")
   if result and result ~= "" then
      return result
   end
end

--- Append the shared benchmark-loading, opts-building, and result-writing
--- lines used by all engine wrapper scripts.
--- @param parts string[] Code-line accumulator (mutated in place).
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @param result_path string Absolute path to write JSON results.
function M.append_wrapper_body(parts, bench_file, targets, spec_name, opts, result_path)
   -- Build targets table literal
   parts[#parts + 1] = "      local targets = {"
   for i = 1, #targets do
      parts[#parts + 1] =
         string.format("         { path = %q, name = %q },", targets[i].path, targets[i].name)
   end
   parts[#parts + 1] = "      }"
   parts[#parts + 1] = ""

   -- Iterate targets, load benchmark for each, extract spec
   parts[#parts + 1] = "      local funcs = {}"
   parts[#parts + 1] = "      for i = 1, #targets do"
   parts[#parts + 1] = "         local t = targets[i]"
   parts[#parts + 1] = "         local original_path = package.path"
   parts[#parts + 1] = "         local snap = {}"
   parts[#parts + 1] = "         for k in pairs(package.loaded) do snap[k] = true end"
   parts[#parts + 1] =
      '         package.path = t.path .. "/?.lua;" .. t.path .. "/?/init.lua;" .. original_path'
   parts[#parts + 1] = string.format("         local bench = dofile(%q)", bench_file)
   parts[#parts + 1] = "         if bench.fn ~= nil then bench = { [''] = bench } end"
   parts[#parts + 1] = string.format("         local spec = bench[%q]", spec_name)
   parts[#parts + 1] = "         if spec ~= nil then funcs[t.name] = spec end"
   parts[#parts + 1] = "         for k in pairs(package.loaded) do"
   parts[#parts + 1] = "            if snap[k] == nil then package.loaded[k] = nil end"
   parts[#parts + 1] = "         end"
   parts[#parts + 1] = "         package.path = original_path"
   parts[#parts + 1] = "      end"
   parts[#parts + 1] = ""

   -- Build opts table
   parts[#parts + 1] = "      local opts = {}"
   if opts.rounds then
      parts[#parts + 1] = string.format("      opts.rounds = %d", opts.rounds)
   end
   if opts.params then
      parts[#parts + 1] = "      opts.params = {"
      local param_names = {}
      for name in pairs(opts.params) do
         param_names[#param_names + 1] = name
      end
      table.sort(param_names)
      for _, name in ipairs(param_names) do
         local values = opts.params[name]
         local vals = {}
         for j = 1, #values do
            local v = values[j]
            if type(v) == "string" then
               vals[#vals + 1] = string.format("%q", v)
            else
               vals[#vals + 1] = tostring(v)
            end
         end
         parts[#parts + 1] =
            string.format("         [%q] = { %s },", name, table.concat(vals, ", "))
      end
      parts[#parts + 1] = "      }"
   end
   parts[#parts + 1] = ""

   -- Call compare_time and write results
   parts[#parts + 1] = "      local results = luamark.compare_time(funcs, opts)"
   parts[#parts + 1] = string.format("      local f = io.open(%q, 'w')", result_path)
   parts[#parts + 1] = "      if not f then error('cannot open ' .. "
      .. string.format("%q", result_path)
      .. ") end"
   parts[#parts + 1] = "      f:write(json.encode(results))"
   parts[#parts + 1] = "      f:close()"
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
