local dir = require("pl.dir")
local engines = require("luabench.engines")
local utils = require("pl.utils")

local M = {}

local quote_arg = utils.quote_arg

--- Headless Love2D configuration template.
--- Disables all visual/audio modules for CI/benchmark operation.
--- @type string
local CONF_TEMPLATE = [[
function love.conf(t)
   t.title = "luabench"
   t.console = true
   t.modules.window = false
   t.modules.graphics = false
   t.modules.audio = false
   t.modules.sound = false
   t.modules.image = false
   t.modules.video = false
   t.modules.joystick = false
   t.modules.physics = false
   t.modules.touch = false
   t.modules.font = false
   t.modules.timer = true
   t.modules.event = true
   t.modules.system = true
   t.modules.data = true
   t.modules.math = true
end
]]

--- Generate the Love2D main.lua wrapper script.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @param result_path string Absolute path to write JSON results.
--- @return string script Generated Love2D main.lua content.
local function generate_love_wrapper(bench_file, targets, spec_name, opts, result_path)
   local parts = {}

   parts[#parts + 1] = "function love.load()"
   parts[#parts + 1] = "   local ok, err = pcall(function()"
   parts[#parts + 1] = '      local luamark = require("luamark")'
   parts[#parts + 1] = '      local json = require("dkjson")'
   parts[#parts + 1] = ""

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
   parts[#parts + 1] = '         package.path = t.path .. "/?.lua;" .. t.path'
      .. ' .. "/?/init.lua;" .. original_path'
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
   parts[#parts + 1] = "   end)"
   parts[#parts + 1] = "   if not ok then"
   parts[#parts + 1] =
      '      io.stderr:write("luabench: engine error: " .. tostring(err) .. "\\n")'
   parts[#parts + 1] = "      love.event.quit(1)"
   parts[#parts + 1] = "      return"
   parts[#parts + 1] = "   end"
   parts[#parts + 1] = "   love.event.quit(0)"
   parts[#parts + 1] = "end"

   return table.concat(parts, "\n")
end

--- Copy a file from src to dst using binary-safe read/write.
--- @param src string Source file path.
--- @param dst string Destination file path.
--- @return boolean ok True on success.
--- @return string|nil err Error message on failure.
local function copy_file(src, dst)
   local rf = io.open(src, "rb")
   if not rf then
      return false, "cannot read: " .. src
   end
   local content = rf:read("*a")
   rf:close()

   local wf = io.open(dst, "wb")
   if not wf then
      return false, "cannot write: " .. dst
   end
   wf:write(content)
   wf:close()

   return true
end

--- Create a temporary Love2D project directory with all required files.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return string|nil tmpdir Temporary project directory, or nil on error.
--- @return string|nil result_path_or_err Result file path on success, error message on failure.
local function scaffold_project(bench_file, targets, spec_name, opts)
   -- Locate luamark.lua
   local luamark_path, luamark_err = engines.find_module_path("luamark")
   if not luamark_path then
      return nil, luamark_err
   end

   -- Locate dkjson.lua
   local dkjson_path, dkjson_err = engines.find_module_path("dkjson")
   if not dkjson_path then
      return nil, dkjson_err
   end

   -- Create temp directory
   local base = os.tmpname()
   os.remove(base)
   local tmpdir = base .. "_love"
   local ok = dir.makepath(tmpdir)
   if not ok then
      return nil, "failed to create temp directory: " .. tmpdir
   end

   -- Copy luamark.lua
   local cp_ok, cp_err = copy_file(luamark_path, tmpdir .. "/luamark.lua")
   if not cp_ok then
      dir.rmtree(tmpdir)
      return nil, cp_err
   end

   -- Copy dkjson.lua
   cp_ok, cp_err = copy_file(dkjson_path, tmpdir .. "/dkjson.lua")
   if not cp_ok then
      dir.rmtree(tmpdir)
      return nil, cp_err
   end

   -- Write conf.lua
   local cf = io.open(tmpdir .. "/conf.lua", "w")
   if not cf then
      dir.rmtree(tmpdir)
      return nil, "failed to write conf.lua"
   end
   cf:write(CONF_TEMPLATE)
   cf:close()

   -- Generate result path (absolute, outside tmpdir)
   local result_base = os.tmpname()
   local result_path = result_base .. ".json"
   os.remove(result_base)

   -- Write main.lua
   local wrapper = generate_love_wrapper(bench_file, targets, spec_name, opts, result_path)
   local mf = io.open(tmpdir .. "/main.lua", "w")
   if not mf then
      dir.rmtree(tmpdir)
      os.remove(result_path)
      os.remove(result_base)
      return nil, "failed to write main.lua"
   end
   mf:write(wrapper)
   mf:close()

   return tmpdir, result_path
end

--- Run a benchmark inside the Love2D runtime.
--- Scaffolds a temporary Love2D project, invokes love, reads JSON results, cleans up.
--- @param runtime_path string Resolved path to the love binary.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return table[]|nil results Parsed luamark results, or nil on error.
--- @return string|nil err Error message on failure.
function M.run(runtime_path, bench_file, targets, spec_name, opts)
   local tmpdir, result_path = scaffold_project(bench_file, targets, spec_name, opts)
   if not tmpdir then
      return nil, result_path -- result_path is the error message here
   end
   ---@cast result_path string

   -- Derive result_base for cleanup (result_path = result_base .. ".json")
   local result_base = result_path:gsub("%.json$", "")

   --- Clean up all temporary files.
   local function cleanup()
      pcall(dir.rmtree, tmpdir)
      pcall(os.remove, result_path)
      pcall(os.remove, result_base)
   end

   -- Execute love <tmpdir>
   local cmd = quote_arg(runtime_path) .. " " .. quote_arg(tmpdir)
   local ok, _, stdout, stderr = utils.executeex(cmd)

   if not ok then
      cleanup()
      local output = (stderr or stdout or ""):match("^(.-)%s*$") or ""
      if output ~= "" then
         return nil, "engine failed: " .. output
      end
      return nil, "engine failed"
   end

   -- Read results
   local rf = io.open(result_path, "r")
   if not rf then
      cleanup()
      return nil, "engine did not produce results"
   end
   local content = rf:read("*a")
   rf:close()

   cleanup()

   -- Parse JSON
   local json = require("dkjson")
   local results, _, err = json.decode(content)
   if not results then
      return nil, "failed to parse engine results: " .. tostring(err)
   end

   return results
end

M._CONF_TEMPLATE = CONF_TEMPLATE
M._generate_love_wrapper = generate_love_wrapper
M._scaffold_project = scaffold_project

return M
