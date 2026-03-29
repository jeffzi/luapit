local exec = require("luabench.exec")
local path = require("pl.path")
local stringx = require("pl.stringx")
local tablex = require("pl.tablex")
local utils = require("pl.utils")

local M = {}

local IS_WINDOWS = path.is_windows
local quote_arg = utils.quote_arg

--- Build a Lua code expression that sets package.path for a target.
--- @param lua_paths string[]|nil Subdirectory paths (nil = use target root).
--- @param indent string Indentation prefix for the generated line.
--- @return string line Generated Lua code line.
local function build_path_line(lua_paths, indent)
   local segs = {}
   if lua_paths and #lua_paths > 0 then
      for i = 1, #lua_paths do
         local sub = lua_paths[i] == "." and "" or ("/" .. lua_paths[i])
         segs[#segs + 1] = string.format('t.path .. "%s/?.lua"', sub)
         segs[#segs + 1] = string.format('t.path .. "%s/?/init.lua"', sub)
      end
   else
      segs[#segs + 1] = 't.path .. "/?.lua"'
      segs[#segs + 1] = 't.path .. "/?/init.lua"'
   end
   segs[#segs + 1] = "original_path"
   return indent .. "package.path = " .. table.concat(segs, ' .. ";" .. ')
end

--- Search PATH for a command and return its absolute path.
--- Uses `where.exe` on Windows and `command -v` on POSIX.
--- @param cmd string Command name to look up.
--- @return string|nil path Absolute path if found, nil otherwise.
local function find_command(cmd)
   local ok, stdout
   if IS_WINDOWS then
      ok, stdout = exec.run("where.exe " .. quote_arg(cmd))
   else
      ok, stdout = exec.run("command -v " .. quote_arg(cmd) .. " 2>/dev/null")
   end
   if not ok or stdout == nil then
      return nil
   end
   -- where.exe returns multiple matches separated by \r\n; take the first line only.
   -- Handles both POSIX (single line with \n) and Windows (\r\n multi-line output).
   local trimmed = stdout:match("^([^\r\n]-)[%s]*\r?\n") or stdout:match("^([^\r\n]-)$")
   if not trimmed or trimmed == "" then
      return nil
   end
   return trimmed
end

--- Resolve a runtime name or path to an absolute path.
--- @param name_or_path string Runtime name (e.g. "luajit") or path (e.g. "/usr/bin/lua").
--- @return string|nil path Resolved absolute path, or nil on failure.
--- @return string|nil err Error message if resolution failed.
local function resolve_runtime(name_or_path)
   if not name_or_path or name_or_path == "" then
      return nil, "runtime not specified"
   end
   local found = find_command(name_or_path)
   if found == nil then
      return nil,
         string.format("runtime not found: %q (not in PATH and not a valid path)", name_or_path)
   end
   return found
end

--- Read a JSON result file, call cleanup, and parse the JSON.
--- Shared by subprocess.run_subprocess and engine adapters after execution.
--- @param result_path string Path to the JSON result file.
--- @param cleanup fun() Cleanup function to call (always called on both paths).
--- @param label string Label for error messages (e.g. "subprocess", "engine").
--- @return table[]|nil results Parsed results, or nil on error.
--- @return string|nil err Error message on failure.
local function read_json_results(result_path, cleanup, label)
   local content, read_err = utils.readfile(result_path)
   if content == nil then
      cleanup()
      return nil, label .. " did not produce results: " .. tostring(read_err)
   end
   cleanup()
   local json = require("dkjson")
   local results, _, parse_err = json.decode(content)
   if results == nil then
      return nil, "failed to parse " .. label .. " results: " .. tostring(parse_err)
   end
   return results
end

--- Generate a wrapper Lua script for subprocess execution.
--- The wrapper loads a benchmark file under each target's package.path,
--- builds a multi-target funcs table, calls compare_time once, and writes
--- JSON results to the output path.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @param result_path string Path to write JSON results.
--- @return string script Generated Lua script content.
local function generate_wrapper(bench_file, targets, spec_name, opts, result_path)
   local parts = {}

   parts[#parts + 1] = 'local luamark = require("luamark")'
   parts[#parts + 1] = 'local json = require("dkjson")'
   parts[#parts + 1] = ""

   -- Build targets table literal
   parts[#parts + 1] = "local targets = {"
   for i = 1, #targets do
      parts[#parts + 1] =
         string.format("   { path = %q, name = %q },", targets[i].path, targets[i].name)
   end
   parts[#parts + 1] = "}"
   parts[#parts + 1] = ""

   -- Iterate targets, load benchmark for each, extract spec
   parts[#parts + 1] = "local funcs = {}"
   parts[#parts + 1] = "for i = 1, #targets do"
   parts[#parts + 1] = "   local t = targets[i]"
   parts[#parts + 1] = "   local original_path = package.path"
   parts[#parts + 1] = "   local snap = {}"
   parts[#parts + 1] = "   for k in pairs(package.loaded) do snap[k] = true end"
   parts[#parts + 1] = build_path_line(opts.lua_path, "   ")
   parts[#parts + 1] = string.format("   local bench = dofile(%q)", bench_file)
   parts[#parts + 1] = "   if bench.fn ~= nil then bench = { [''] = bench } end"
   parts[#parts + 1] = string.format("   local spec = bench[%q]", spec_name)
   parts[#parts + 1] = "   if spec ~= nil then funcs[t.name] = spec end"
   parts[#parts + 1] = "   for k in pairs(package.loaded) do"
   parts[#parts + 1] = "      if snap[k] == nil then package.loaded[k] = nil end"
   parts[#parts + 1] = "   end"
   parts[#parts + 1] = "   package.path = original_path"
   parts[#parts + 1] = "end"
   parts[#parts + 1] = ""

   -- Build opts table
   parts[#parts + 1] = "local opts = {}"
   if opts.rounds ~= nil then
      parts[#parts + 1] = string.format("opts.rounds = %d", opts.rounds)
   end
   if opts.params ~= nil then
      parts[#parts + 1] = "opts.params = {"
      local param_names = tablex.keys(opts.params)
      table.sort(param_names)
      for i = 1, #param_names do
         local name = param_names[i]
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
         parts[#parts + 1] = string.format("   [%q] = { %s },", name, table.concat(vals, ", "))
      end
      parts[#parts + 1] = "}"
   end
   parts[#parts + 1] = ""

   -- Call compare_time and write results
   parts[#parts + 1] = "local results = luamark.compare_time(funcs, opts)"
   parts[#parts + 1] = string.format("local f = io.open(%q, 'w')", result_path)
   parts[#parts + 1] = "if not f then error('cannot open ' .. "
      .. string.format("%q", result_path)
      .. ") end"
   parts[#parts + 1] = "f:write(json.encode(results))"
   parts[#parts + 1] = "f:close()"

   return table.concat(parts, "\n")
end

--- Run a benchmark in a subprocess under the specified runtime.
--- @param runtime_path string Absolute path to the Lua interpreter.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return table[]|nil results Parsed luamark results, or nil on error.
--- @return string|nil err Error message on failure.
local function run_subprocess(runtime_path, bench_file, targets, spec_name, opts)
   local wrapper_base = os.tmpname()
   local result_base = os.tmpname()
   local wrapper_path = wrapper_base .. ".lua"
   local result_path = result_base .. ".json"
   -- os.tmpname() creates actual files on POSIX; remove the originals since we use suffixed paths.
   os.remove(wrapper_base)
   os.remove(result_base)

   local function cleanup()
      pcall(os.remove, wrapper_path)
      pcall(os.remove, result_path)
   end

   local wrapper = generate_wrapper(bench_file, targets, spec_name, opts, result_path)

   -- Write wrapper to temp file
   local ok, write_err = utils.writefile(wrapper_path, wrapper)
   if not ok then
      cleanup()
      return nil, "failed to create wrapper script: " .. tostring(write_err)
   end

   -- Execute subprocess
   local cmd = quote_arg(runtime_path) .. " " .. quote_arg(wrapper_path)
   local stdout, stderr
   ok, stdout, stderr = exec.run(cmd)

   if not ok then
      cleanup()
      local output = stringx.strip(stderr or stdout or "")
      if output ~= "" then
         return nil, "subprocess failed: " .. output
      end
      return nil, "subprocess failed"
   end

   return read_json_results(result_path, cleanup, "subprocess")
end

M.find_command = find_command
M.resolve_runtime = resolve_runtime
M.run_subprocess = run_subprocess
M.read_json_results = read_json_results
M._generate_wrapper = generate_wrapper
M._build_path_line = build_path_line

return M
