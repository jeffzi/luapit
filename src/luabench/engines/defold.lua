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

   -- Static top-level requires so Defold's build system detects and bundles them
   parts[#parts + 1] = 'local luamark = require("luamark")'
   parts[#parts + 1] = 'local json = require("dkjson")'
   parts[#parts + 1] = ""
   parts[#parts + 1] = "function init(self)"
   parts[#parts + 1] = "   local ok, err = pcall(function()"

   engines.append_wrapper_body(parts, bench_file, targets, spec_name, opts, result_path)

   parts[#parts + 1] = "   end)"
   parts[#parts + 1] = "   if not ok then"
   parts[#parts + 1] = '      io.stderr:write("luabench: engine error: " .. tostring(err) .. "\\n")'
   parts[#parts + 1] = "      os.exit(1)"
   parts[#parts + 1] = "      return"
   parts[#parts + 1] = "   end"
   parts[#parts + 1] = "   os.exit(0)"
   parts[#parts + 1] = "end"

   return table.concat(parts, "\n")
end

--- Locate bob.jar for the Defold build step.
--- Check $BOB env var first, fall back to PATH lookup.
--- @return string|nil path Path to bob.jar.
--- @return string|nil err Error message if not found.
local function locate_bob()
   local bob = os.getenv("BOB")
   if bob and bob ~= "" then
      return bob
   end
   local found = engines.find_command("bob.jar")
   if found then
      return found
   end
   return nil, "bob.jar not found: set BOB environment variable or add bob.jar to PATH"
end

--- Check that java is available in PATH.
--- @return true|nil ok True if java found.
--- @return string|nil err Error message if not found.
local function check_java()
   if engines.find_command("java") then
      return true
   end
   return nil, "java not found in PATH (required by Defold bob.jar)"
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
      dir.rmtree(tmpdir)
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
      dir.rmtree(tmpdir)
      return nil, err
   end
   ok, err = write_file(tmpdir .. "/input/game.input_binding", INPUT_BINDING)
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end
   ok, err = write_file(tmpdir .. "/main/main.collection", MAIN_COLLECTION)
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end
   ok, err = write_file(tmpdir .. "/main/test.go", TEST_GO)
   if not ok then
      dir.rmtree(tmpdir)
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

   ok, err = engines.copy_file(luamark_path, tmpdir .. "/main/luamark.lua")
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end

   ok, err = engines.copy_file(dkjson_path, tmpdir .. "/main/dkjson.lua")
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

   --- Clean up all temporary files.
   local function cleanup()
      pcall(dir.rmtree, tmpdir)
      pcall(os.remove, result_path)
   end

   --- Extract trimmed error output from executeex stderr/stdout.
   local function trim_output(stderr, stdout)
      return ((stderr or stdout or ""):match("^(.-)%s*$")) or ""
   end

   -- Build with bob.jar
   local build_cmd = string.format(
      "java -jar %s --root %s resolve build --archive",
      quote_arg(bob),
      quote_arg(tmpdir)
   )
   local build_ok, _, build_stdout, build_stderr = utils.executeex(build_cmd)
   if not build_ok then
      local output = trim_output(build_stderr, build_stdout)
      cleanup()
      if output ~= "" then
         return nil, "Defold build failed: " .. output
      end
      return nil, "Defold build failed"
   end

   -- Run dmengine_headless from project directory
   local run_cmd = string.format("cd %s && %s", quote_arg(tmpdir), quote_arg(runtime_path))
   local run_ok, _, run_stdout, run_stderr = utils.executeex(run_cmd)
   if not run_ok then
      local output = trim_output(run_stderr, run_stdout)
      cleanup()
      if output ~= "" then
         return nil, "dmengine_headless failed: " .. output
      end
      return nil, "dmengine_headless failed"
   end

   -- Read results
   local rf = io.open(result_path, "r")
   if not rf then
      cleanup()
      return nil, "Defold process did not produce results"
   end
   local content = rf:read("*a")
   rf:close()

   cleanup()

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
