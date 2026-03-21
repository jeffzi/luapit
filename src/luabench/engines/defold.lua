local dir = require("pl.dir")
local utils = require("pl.utils")

local engines = require("luabench.engines")

local quote_arg = utils.quote_arg

local M = {}

--- Defold game.project template.
--- @type string
local GAME_PROJECT = [[[project]
title = luabench

[display]
width = 960
height = 640

[bootstrap]
main_collection = /main/main.collectionc

[script]
shared_state = 1

[library]

[input]
game_binding = /input/game.input_bindingc
]]

--- Defold main.collection template.
--- @type string
local MAIN_COLLECTION = [[name: "main"
instances {
  id: "test"
  prototype: "/main/test.go"
  position { x: 0.0 y: 0.0 z: 0.0 }
  rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }
  scale3 { x: 1.0 y: 1.0 z: 1.0 }
}
]]

--- Defold test.go template.
--- @type string
local TEST_GO = [[components {
  id: "script"
  component: "/main/test.script"
  position { x: 0.0 y: 0.0 z: 0.0 }
  rotation { x: 0.0 y: 0.0 z: 0.0 w: 1.0 }
}
]]

--- Defold input/game.input_binding template.
--- @type string
local INPUT_BINDING = [[key_trigger {
  input: KEY_ESC
  action: "exit"
}
]]

--- Generate a Defold test.script wrapper for benchmark execution.
--- Static requires for luamark and dkjson are placed at file top level
--- so Defold's build system detects and bundles them.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @param result_path string Absolute path to write JSON results.
--- @return string script Generated Defold test.script content.
local function generate_defold_wrapper(bench_file, targets, spec_name, opts, result_path)
   local parts = {}

   -- Static top-level requires (Defold bundling per Pitfall 2)
   parts[#parts + 1] = 'local luamark = require("luamark")'
   parts[#parts + 1] = 'local json = require("dkjson")'
   parts[#parts + 1] = ""
   parts[#parts + 1] = "function init(self)"
   parts[#parts + 1] = "   local ok, err = pcall(function()"

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

   parts[#parts + 1] = "   end)"
   parts[#parts + 1] = "   if not ok then"
   parts[#parts + 1] =
      '      io.stderr:write("luabench: engine error: " .. tostring(err) .. "\\n")'
   parts[#parts + 1] = "      os.exit(1)"
   parts[#parts + 1] = "      return"
   parts[#parts + 1] = "   end"
   parts[#parts + 1] = "   os.exit(0)"
   parts[#parts + 1] = "end"

   return table.concat(parts, "\n")
end

--- Locate bob.jar for the Defold build step.
--- Check $BOB env var first, fall back to command -v bob.jar.
--- @return string|nil path Path to bob.jar.
--- @return string|nil err Error message if not found.
local function locate_bob()
   local bob = os.getenv("BOB")
   if bob and bob ~= "" then
      return bob
   end
   local h = io.popen("command -v bob.jar 2>/dev/null")
   if h then
      local result = h:read("*a")
      h:close()
      result = result:match("^(.-)%s*$")
      if result and result ~= "" then
         return result
      end
   end
   return nil,
      "bob.jar not found: set BOB environment variable or add bob.jar to PATH"
end

--- Check that java is available in PATH.
--- @return true|nil ok True if java found.
--- @return string|nil err Error message if not found.
local function check_java()
   local h = io.popen("command -v java 2>/dev/null")
   if h then
      local result = h:read("*a")
      h:close()
      result = result:match("^(.-)%s*$")
      if result and result ~= "" then
         return true
      end
   end
   return nil, "java not found in PATH (required by Defold bob.jar)"
end

--- Copy a file from src to dst.
--- @param src string Source file path.
--- @param dst string Destination file path.
--- @return boolean ok True on success.
--- @return string|nil err Error message on failure.
local function copy_file(src, dst)
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

--- Scaffold a minimal Defold project in a temp directory.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return string|nil tmpdir Path to scaffolded project directory.
--- @return string|nil result_path_or_err Result JSON path on success, error on failure.
local function scaffold_project(bench_file, targets, spec_name, opts)
   local base = os.tmpname()
   os.remove(base)
   local tmpdir = base .. "_defold"

   -- Create directories
   local ok, err = dir.makepath(tmpdir .. "/input")
   if not ok then
      return nil, "failed to create input dir: " .. tostring(err)
   end
   ok, err = dir.makepath(tmpdir .. "/main")
   if not ok then
      return nil, "failed to create main dir: " .. tostring(err)
   end

   -- Write static project files
   local function write_file(fpath, content)
      local f = io.open(fpath, "w")
      if not f then
         return nil, "cannot write: " .. fpath
      end
      f:write(content)
      f:close()
      return true
   end

   ok, err = write_file(tmpdir .. "/game.project", GAME_PROJECT)
   if not ok then
      return nil, err
   end
   ok, err = write_file(tmpdir .. "/input/game.input_binding", INPUT_BINDING)
   if not ok then
      return nil, err
   end
   ok, err = write_file(tmpdir .. "/main/main.collection", MAIN_COLLECTION)
   if not ok then
      return nil, err
   end
   ok, err = write_file(tmpdir .. "/main/test.go", TEST_GO)
   if not ok then
      return nil, err
   end

   -- Copy luamark.lua and dkjson.lua into main/
   local luamark_path, luamark_err = engines.find_module_path("luamark")
   if not luamark_path then
      dir.rmtree(tmpdir)
      return nil, "cannot locate luamark: " .. tostring(luamark_err)
   end

   local dkjson_path, dkjson_err = engines.find_module_path("dkjson")
   if not dkjson_path then
      dir.rmtree(tmpdir)
      return nil, "cannot locate dkjson: " .. tostring(dkjson_err)
   end

   ok, err = copy_file(luamark_path, tmpdir .. "/main/luamark.lua")
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end

   ok, err = copy_file(dkjson_path, tmpdir .. "/main/dkjson.lua")
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end

   -- Generate result path
   local result_base = os.tmpname()
   os.remove(result_base)
   local result_path = result_base .. ".json"

   -- Generate and write wrapper script
   local wrapper = generate_defold_wrapper(bench_file, targets, spec_name, opts, result_path)
   ok, err = write_file(tmpdir .. "/main/test.script", wrapper)
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end

   return tmpdir, result_path
end

--- Run a benchmark inside Defold's runtime.
--- Scaffolds a Defold project, builds with bob.jar, executes dmengine_headless,
--- reads JSON results, and cleans up.
--- @param runtime_path string Resolved path to dmengine_headless.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return table[]|nil results Parsed luamark results, or nil on error.
--- @return string|nil err Error message on failure.
function M.run(runtime_path, bench_file, targets, spec_name, opts)
   -- Check java availability
   local java_ok, java_err = check_java()
   if not java_ok then
      return nil, java_err
   end

   -- Locate bob.jar
   local bob, bob_err = locate_bob()
   if not bob then
      return nil, bob_err
   end

   -- Scaffold project
   local tmpdir, result_path = scaffold_project(bench_file, targets, spec_name, opts)
   if not tmpdir then
      return nil, result_path -- result_path holds error message on failure
   end
   --- @cast result_path string

   -- Build with bob.jar
   local build_cmd = string.format(
      "java -jar %s --root %s resolve build --archive 2>&1",
      quote_arg(bob),
      quote_arg(tmpdir)
   )
   local build_ok, _, build_stdout, build_stderr = utils.executeex(build_cmd)
   if not build_ok then
      local output = (build_stderr or build_stdout or ""):match("^(.-)%s*$") or ""
      dir.rmtree(tmpdir)
      pcall(os.remove, result_path)
      if output ~= "" then
         return nil, "Defold build failed: " .. output
      end
      return nil, "Defold build failed"
   end

   -- Run dmengine_headless from project directory
   local run_cmd = string.format(
      "cd %s && %s 2>&1",
      quote_arg(tmpdir),
      quote_arg(runtime_path)
   )
   local run_ok, _, run_stdout, run_stderr = utils.executeex(run_cmd)
   if not run_ok then
      local output = (run_stderr or run_stdout or ""):match("^(.-)%s*$") or ""
      dir.rmtree(tmpdir)
      pcall(os.remove, result_path)
      if output ~= "" then
         return nil, "dmengine_headless failed: " .. output
      end
      return nil, "dmengine_headless failed"
   end

   -- Read results
   local rf = io.open(result_path, "r")
   if not rf then
      dir.rmtree(tmpdir)
      pcall(os.remove, result_path)
      return nil, "Defold process did not produce results"
   end
   local content = rf:read("*a")
   rf:close()

   -- Cleanup
   dir.rmtree(tmpdir)
   pcall(os.remove, result_path)
   -- Remove the base tmpname files if they exist
   local result_base = result_path:gsub("%.json$", "")
   pcall(os.remove, result_base)

   -- Parse JSON
   local json = require("dkjson")
   local results, _, parse_err = json.decode(content)
   if not results then
      return nil, "failed to parse Defold results: " .. tostring(parse_err)
   end

   return results
end

-- Expose internals for testing
M._GAME_PROJECT = GAME_PROJECT
M._MAIN_COLLECTION = MAIN_COLLECTION
M._TEST_GO = TEST_GO
M._INPUT_BINDING = INPUT_BINDING
M._generate_defold_wrapper = generate_defold_wrapper
M._scaffold_project = scaffold_project
M._locate_bob = locate_bob
M._check_java = check_java

return M
