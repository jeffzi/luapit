local exec = require("luapit.exec")
local path = require("pl.path")
local stringx = require("pl.stringx")
local utils = require("pl.utils")

local M = {}

local IS_WINDOWS = path.is_windows
local quote_arg = utils.quote_arg

--- Build a Lua code expression that sets package.path for a target.
--- @param lua_paths string[]|nil Subdirectory paths (nil = use target root).
--- @param indent string Indentation prefix for the generated line.
--- @return string line Generated Lua code line.
function M.build_path_line(lua_paths, indent)
   local segs = {}
   if lua_paths ~= nil and #lua_paths > 0 then
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
function M.find_command(cmd)
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
   if trimmed == nil or trimmed == "" then
      return nil
   end
   return trimmed
end

--- Resolve a runtime name or path to an absolute path.
--- @param name_or_path string Runtime name (e.g. "luajit") or path (e.g. "/usr/bin/lua").
--- @return string|nil path Resolved absolute path, or nil on failure.
--- @return string|nil err Error message if resolution failed.
function M.resolve_runtime(name_or_path)
   if name_or_path == nil or name_or_path == "" then
      return nil, "runtime not specified"
   end
   local found = M.find_command(name_or_path)
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
function M.read_json_results(result_path, cleanup, label)
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

--- Serialize an opts table (rounds, params) as Lua source lines.
--- @param opts table Options for compare_time.
--- @return string block Lua source declaring `local opts`.
local function build_opts_block(opts)
   local lines = { "local opts = {}" }
   if opts.rounds ~= nil then
      lines[#lines + 1] = string.format("opts.rounds = %d", opts.rounds)
   end
   if opts.params == nil then
      return table.concat(lines, "\n")
   end
   lines[#lines + 1] = "opts.params = {"
   local names = {}
   for name in pairs(opts.params) do
      names[#names + 1] = name
   end
   table.sort(names)
   for i = 1, #names do
      local values = opts.params[names[i]]
      local vals = {}
      for j = 1, #values do
         local v = values[j]
         vals[#vals + 1] = type(v) == "string" and string.format("%q", v) or tostring(v)
      end
      lines[#lines + 1] = string.format("   [%q] = { %s },", names[i], table.concat(vals, ", "))
   end
   lines[#lines + 1] = "}"
   return table.concat(lines, "\n")
end

-- Template for the Lua script that runs in the subprocess.
-- %s placeholders (in order): targets, path_line, bench_file, spec_name,
-- opts_block, result_path, result_path.
local WRAPPER_TEMPLATE = [=[
local luamark = require("luamark")
local json = require("dkjson")

local targets = {
%s
}

local funcs = {}
for i = 1, #targets do
   local t = targets[i]
   local original_path = package.path
   local snap = {}
   for k in pairs(package.loaded) do snap[k] = true end
%s
   local bench = dofile(%s)
   if bench.fn ~= nil then bench = { [''] = bench } end
   local spec = bench[%s]
   if spec ~= nil then funcs[t.name] = spec end
   for k in pairs(package.loaded) do
      if snap[k] == nil then package.loaded[k] = nil end
   end
   package.path = original_path
end

%s

local results = luamark.compare_time(funcs, opts)
local f = io.open(%s, 'w')
if not f then error('cannot open ' .. %s) end
f:write(json.encode(results))
f:close()]=]

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
   local target_entries = {}
   for i = 1, #targets do
      target_entries[i] =
         string.format("   { path = %q, name = %q },", targets[i].path, targets[i].name)
   end

   return string.format(
      WRAPPER_TEMPLATE,
      table.concat(target_entries, "\n"),
      M.build_path_line(opts.lua_path, "   "),
      string.format("%q", bench_file),
      string.format("%q", spec_name),
      build_opts_block(opts),
      string.format("%q", result_path),
      string.format("%q", result_path)
   )
end

--- Run a benchmark in a subprocess under the specified runtime.
--- @param runtime_path string Absolute path to the Lua interpreter.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return table[]|nil results Parsed luamark results, or nil on error.
--- @return string|nil err Error message on failure.
function M.run_subprocess(runtime_path, bench_file, targets, spec_name, opts)
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

   return M.read_json_results(result_path, cleanup, "subprocess")
end

--- Detect the current Lua interpreter and resolve to an absolute path.
--- The interpreter is at the most negative index in the global `arg` table
--- (e.g. `arg[-1]` for plain `lua script.lua`, `arg[-3]` when luarocks
--- injects `-e code` before the script).
--- @return string|nil path Resolved absolute path, or nil on failure.
--- @return string|nil err Error message if detection failed.
function M.detect_runtime()
   if _G.arg == nil then
      return nil, "cannot detect runtime: arg table is not available"
   end
   local min_idx
   for k in pairs(_G.arg) do
      if type(k) == "number" and k < 0 then
         if min_idx == nil or k < min_idx then
            min_idx = k
         end
      end
   end
   if min_idx == nil then
      return nil, "cannot detect runtime: no interpreter found in arg table"
   end
   local interpreter = _G.arg[min_idx]
   return M.resolve_runtime(interpreter)
end

return M
