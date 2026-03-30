local dir = require("pl.dir")
local engines = require("luapit.engines")
local exec = require("luapit.exec")
local stringx = require("pl.stringx")
local subprocess = require("luapit.subprocess")
local utils = require("pl.utils")

local M = {}

local quote_arg = utils.quote_arg

--- Headless Love2D configuration template.
--- Disables all visual/audio modules for CI/benchmark operation.
--- @type string
local CONF_TEMPLATE = [[
function love.conf(t)
   t.title = "luapit"
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

   engines.append_wrapper_body(parts, bench_file, targets, spec_name, opts, result_path)

   parts[#parts + 1] = "   end)"
   parts[#parts + 1] = "   if not ok then"
   parts[#parts + 1] = '      io.stderr:write("luapit: engine error: " .. tostring(err) .. "\\n")'
   parts[#parts + 1] = "      love.event.quit(1)"
   parts[#parts + 1] = "      return"
   parts[#parts + 1] = "   end"
   parts[#parts + 1] = "   love.event.quit(0)"
   parts[#parts + 1] = "end"

   return table.concat(parts, "\n")
end

--- Create a temporary Love2D project directory with all required files.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return string|nil tmpdir Temporary project directory, or nil on error.
--- @return string|nil result_path_or_err Result file path on success, error message on failure.
local function scaffold_project(bench_file, targets, spec_name, opts)
   local luamark_path, luamark_err = engines.find_module_path("luamark")
   if luamark_path == nil then
      return nil, luamark_err
   end

   local dkjson_path, dkjson_err = engines.find_module_path("dkjson")
   if dkjson_path == nil then
      return nil, dkjson_err
   end

   local base = os.tmpname()
   os.remove(base)
   local tmpdir = base .. "_love"
   local ok = dir.makepath(tmpdir)
   if not ok then
      return nil, "failed to create temp directory: " .. tmpdir
   end

   local copy_ok, copy_err = engines.copy_file(luamark_path, tmpdir .. "/luamark.lua")
   if not copy_ok then
      dir.rmtree(tmpdir)
      return nil, copy_err
   end

   copy_ok, copy_err = engines.copy_file(dkjson_path, tmpdir .. "/dkjson.lua")
   if not copy_ok then
      dir.rmtree(tmpdir)
      return nil, copy_err
   end

   local write_ok, write_err = utils.writefile(tmpdir .. "/conf.lua", CONF_TEMPLATE)
   if not write_ok then
      dir.rmtree(tmpdir)
      return nil, "failed to write conf.lua: " .. tostring(write_err)
   end

   local result_base = os.tmpname()
   local result_path = result_base .. ".json"
   os.remove(result_base)

   local wrapper = generate_love_wrapper(bench_file, targets, spec_name, opts, result_path)
   write_ok, write_err = utils.writefile(tmpdir .. "/main.lua", wrapper)
   if not write_ok then
      dir.rmtree(tmpdir)
      return nil, "failed to write main.lua: " .. tostring(write_err)
   end

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
   if tmpdir == nil then
      return nil, result_path -- result_path holds the error message on failure
   end
   ---@cast result_path string

   local function cleanup()
      pcall(dir.rmtree, tmpdir)
      pcall(os.remove, result_path)
   end

   local cmd = quote_arg(runtime_path) .. " " .. quote_arg(tmpdir)
   local ok, stdout, stderr = exec.run(cmd)

   if not ok then
      cleanup()
      local output = stringx.strip(stderr or stdout or "")
      if output ~= "" then
         return nil, "engine failed: " .. output
      end
      return nil, "engine failed"
   end

   return subprocess.read_json_results(result_path, cleanup, "engine")
end

return M
