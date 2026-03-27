local path = require("pl.path")
local subprocess = require("luabench.subprocess")
local utils = require("pl.utils")

local quote_arg = utils.quote_arg

local M = {}

--- Engine registry: maps engine name to adapter module path and optional
--- runtime command override (when the binary to resolve differs from the
--- engine name itself).
--- @type table<string, {module: string, runtime_cmd: string|nil}>
local ENGINES = {
   love = { module = "luabench.engines.love2d" },
   defold = { module = "luabench.engines.defold", runtime_cmd = "dmengine_headless" },
   ["defold-html5"] = { module = "luabench.engines.defold_html5", runtime_cmd = "node" },
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
   return require(ENGINES[engine_name].module)
end

--- Return the command name to resolve for a given engine.
--- Some engines need a different binary than their own name
--- (e.g. defold resolves "dmengine_headless", defold-html5 resolves "node").
--- @param engine_name string Engine name returned by detect().
--- @return string resolve_name Command name to pass to subprocess.resolve_runtime.
function M.runtime_cmd(engine_name)
   return ENGINES[engine_name].runtime_cmd or engine_name
end

--- Copy a file from src to dst using binary-safe read/write.
--- @param src string Source file path.
--- @param dst string Destination file path.
--- @return boolean ok True on success.
--- @return string|nil err Error message on failure.
function M.copy_file(src, dst)
   local content, err = utils.readfile(src, true)
   if not content then
      return false, "cannot read source: " .. src .. ": " .. tostring(err)
   end
   local ok, write_err = utils.writefile(dst, content, true)
   if not ok then
      return false, "cannot write destination: " .. dst .. ": " .. tostring(write_err)
   end
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
   local result = h:read("*a")
   h:close()
   if not result then
      return nil
   end
   result = result:match("^(.-)%s*$")
   if result ~= "" then
      return result
   end
end

--- Append the shared benchmark-loading, opts-building, and compare_time call
--- lines used by all engine wrapper scripts.
--- @param parts string[] Code-line accumulator (mutated in place).
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
function M.append_benchmark_body(parts, bench_file, targets, spec_name, opts)
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
   parts[#parts + 1] = subprocess._build_path_line(opts.lua_path, "         ")
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

   -- Call compare_time
   parts[#parts + 1] = "      local results = luamark.compare_time(funcs, opts)"
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
   M.append_benchmark_body(parts, bench_file, targets, spec_name, opts)

   -- Write results to file
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
      if path.isfile(fpath) then
         return fpath
      end
   end
   return nil, "module source not found: " .. modname
end

return M
