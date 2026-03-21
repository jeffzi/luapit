local M = {}

--- Wrap value in single quotes for POSIX-safe shell quoting,
--- escaping any embedded single quotes.
--- @param s string Value to quote for shell interpolation.
--- @return string quoted Shell-safe quoted string.
local function shellquote(s)
   return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Execute a shell command and return whether it succeeded.
--- Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--- @param cmd string Shell command to execute.
--- @return boolean ok True if command exited with code 0.
local function exec_ok(cmd)
   local r1, r2 = os.execute(cmd)
   if r2 ~= nil then
      return r1 == true
   end
   return r1 == 0
end

--- Resolve a runtime name or path to an absolute path.
--- @param name_or_path string Runtime name (e.g. "luajit") or path (e.g. "/usr/bin/lua").
--- @return string|nil path Resolved absolute path, or nil on failure.
--- @return string|nil err Error message if resolution failed.
local function resolve_runtime(name_or_path)
   if not name_or_path or name_or_path == "" then
      return nil, "runtime not specified"
   end
   local cmd = "command -v " .. shellquote(name_or_path) .. " 2>/dev/null"
   local h = io.popen(cmd)
   if not h then
      return nil, "failed to check runtime: " .. name_or_path
   end
   local result = h:read("*a")
   h:close()
   result = result:match("^(.-)%s*$")
   if not result or result == "" then
      return nil,
         string.format(
            "runtime not found: %q (not in PATH and not a valid path)",
            name_or_path
         )
   end
   return result
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
      parts[#parts + 1] = string.format(
         "   { path = %q, name = %q },",
         targets[i].path,
         targets[i].name
      )
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
   parts[#parts + 1] = '   package.path = t.path .. "/?.lua;" .. t.path .. "/?/init.lua;" .. original_path'
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
   if opts.rounds then
      parts[#parts + 1] = string.format("opts.rounds = %d", opts.rounds)
   end
   if opts.params then
      parts[#parts + 1] = "opts.params = {"
      for name, values in pairs(opts.params) do
         local vals = {}
         for j = 1, #values do
            local v = values[j]
            if type(v) == "string" then
               vals[#vals + 1] = string.format("%q", v)
            elseif type(v) == "boolean" then
               vals[#vals + 1] = tostring(v)
            else
               vals[#vals + 1] = tostring(v)
            end
         end
         parts[#parts + 1] = string.format(
            "   [%q] = { %s },", name, table.concat(vals, ", ")
         )
      end
      parts[#parts + 1] = "}"
   end
   parts[#parts + 1] = ""

   -- Call compare_time and write results
   parts[#parts + 1] = "local results = luamark.compare_time(funcs, opts)"
   parts[#parts + 1] = string.format("local f = io.open(%q, 'w')", result_path)
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
   local wrapper_path = os.tmpname() .. ".lua"
   local result_path = os.tmpname() .. ".json"

   local wrapper = generate_wrapper(bench_file, targets, spec_name, opts, result_path)

   -- Write wrapper to temp file
   local wf = io.open(wrapper_path, "w")
   if not wf then
      pcall(os.remove, wrapper_path)
      pcall(os.remove, result_path)
      return nil, "failed to create wrapper script"
   end
   wf:write(wrapper)
   wf:close()

   -- Execute subprocess
   local cmd = shellquote(runtime_path) .. " " .. shellquote(wrapper_path) .. " 2>&1"
   local ok = exec_ok(cmd)

   if not ok then
      pcall(os.remove, wrapper_path)
      pcall(os.remove, result_path)
      return nil, "subprocess exited with non-zero status"
   end

   -- Read results
   local rf = io.open(result_path, "r")
   if not rf then
      pcall(os.remove, wrapper_path)
      pcall(os.remove, result_path)
      return nil, "subprocess did not produce results"
   end
   local content = rf:read("*a")
   rf:close()

   -- Cleanup temp files
   pcall(os.remove, wrapper_path)
   pcall(os.remove, result_path)

   -- Parse JSON
   local json = require("dkjson")
   local results, _, err = json.decode(content)
   if not results then
      return nil, "failed to parse subprocess results: " .. tostring(err)
   end

   return results
end

M.resolve_runtime = resolve_runtime
M.run_subprocess = run_subprocess
M._generate_wrapper = generate_wrapper

return M
