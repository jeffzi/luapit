local dir = require("pl.dir")
local exec = require("luabench.exec")
local subprocess = require("luabench.subprocess")
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
function M.locate_bob()
   local bob = os.getenv("BOB")
   if bob ~= nil and bob ~= "" then
      return bob
   end
   local found = engines.find_command("bob.jar")
   if found ~= nil then
      return found
   end
   return nil, "bob.jar not found: set BOB environment variable or add bob.jar to PATH"
end

--- Check that java is available in PATH.
--- @return true|nil ok True if java found.
--- @return string|nil err Error message if not found.
function M.check_java()
   if engines.find_command("java") ~= nil then
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
function M.scaffold_project(bench_file, targets, spec_name, opts)
   local base = os.tmpname()
   os.remove(base)
   local tmpdir = base .. "_defold"

   local ok, err = dir.makepath(tmpdir .. "/input")
   if not ok then
      return nil, "failed to create input dir: " .. tostring(err)
   end
   ok, err = dir.makepath(tmpdir .. "/main")
   if not ok then
      dir.rmtree(tmpdir)
      return nil, "failed to create main dir: " .. tostring(err)
   end

   ok, err = utils.writefile(tmpdir .. "/game.project", GAME_PROJECT)
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end
   ok, err = utils.writefile(tmpdir .. "/input/game.input_binding", INPUT_BINDING)
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end
   ok, err = utils.writefile(tmpdir .. "/main/main.collection", MAIN_COLLECTION)
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end
   ok, err = utils.writefile(tmpdir .. "/main/test.go", TEST_GO)
   if not ok then
      dir.rmtree(tmpdir)
      return nil, err
   end

   local luamark_path, luamark_err = engines.find_module_path("luamark")
   if luamark_path == nil then
      dir.rmtree(tmpdir)
      return nil, "cannot locate luamark: " .. tostring(luamark_err)
   end

   local dkjson_path, dkjson_err = engines.find_module_path("dkjson")
   if dkjson_path == nil then
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

   local result_base = os.tmpname()
   os.remove(result_base)
   local result_path = result_base .. ".json"

   local wrapper = generate_defold_wrapper(bench_file, targets, spec_name, opts, result_path)
   ok, err = utils.writefile(tmpdir .. "/main/test.script", wrapper)
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
   local java_ok, java_err = M.check_java()
   if java_ok == nil then
      return nil, java_err
   end

   local bob, bob_err = M.locate_bob()
   if bob == nil then
      return nil, bob_err
   end

   local tmpdir, result_path = M.scaffold_project(bench_file, targets, spec_name, opts)
   if tmpdir == nil then
      return nil, result_path -- result_path holds error message on failure
   end
   --- @cast result_path string

   --- Clean up all temporary files.
   local function cleanup()
      pcall(dir.rmtree, tmpdir)
      pcall(os.remove, result_path)
   end

   local exec_step = engines.make_exec_step(exec, cleanup)

   local _, build_err = exec_step(
      string.format(
         "java -jar %s --root %s resolve build --archive",
         quote_arg(bob),
         quote_arg(tmpdir)
      ),
      "Defold build"
   )
   if build_err ~= nil then
      return nil, build_err
   end

   local _, run_err = exec_step(
      string.format("cd %s && %s", quote_arg(tmpdir), quote_arg(runtime_path)),
      "dmengine_headless"
   )
   if run_err ~= nil then
      return nil, run_err
   end

   return subprocess.read_json_results(result_path, cleanup, "Defold process")
end

return M
