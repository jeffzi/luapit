local dir = require("pl.dir")
local utils = require("pl.utils")

local engines = require("luabench.engines")

local quote_arg = utils.quote_arg

local M = {}

--- Generate a Defold HTML5 test.script wrapper for benchmark execution.
--- Uses html5.run() to pass results via JS globals and signal completion
--- via document.title instead of filesystem I/O or os.exit().
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return string script Generated Defold test.script content.
local function generate_html5_wrapper(bench_file, targets, spec_name, opts)
   local parts = {}

   -- Static top-level requires so Defold's build system detects and bundles them
   parts[#parts + 1] = 'local luamark = require("luamark")'
   parts[#parts + 1] = 'local json = require("dkjson")'
   parts[#parts + 1] = ""
   parts[#parts + 1] = "function init(self)"
   parts[#parts + 1] = "   local ok, err = pcall(function()"

   engines.append_benchmark_body(parts, bench_file, targets, spec_name, opts)

   -- Encode results and pass to browser via JS global (inside pcall)
   parts[#parts + 1] = "      local json_str = json.encode(results)"
   parts[#parts + 1] = [[      local safe = json_str]]
      .. [[:gsub("\\", "\\\\"):gsub("'", "\\'")]]
      .. [[:gsub("\n", "\\n"):gsub("\r", "\\r")]]
   parts[#parts + 1] = [[      html5.run("window.__luabench_result = '" .. safe .. "'")]]
   parts[#parts + 1] = [[      html5.run("document.title = 'DONE'")]]

   parts[#parts + 1] = "   end)"
   parts[#parts + 1] = "   if not ok then"
   -- HTML5: signal error via document.title (no io.stderr, no os.exit)
   parts[#parts + 1] =
      "      html5.run(\"document.title = 'FAIL: ' .. tostring(err):gsub('[\\\\']', '')\")"
   parts[#parts + 1] = "      return"
   parts[#parts + 1] = "   end"
   parts[#parts + 1] = "end"

   return table.concat(parts, "\n")
end

--- Scaffold a minimal Defold HTML5 project in a temp directory.
--- Reuse the desktop scaffold, then overwrite test.script with the HTML5 variant.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return string|nil tmpdir Path to scaffolded project directory.
--- @return string|nil err Error message on failure.
local function scaffold_html5_project(bench_file, targets, spec_name, opts)
   local defold = require("luabench.engines.defold")
   local tmpdir, result_path = defold._scaffold_project(bench_file, targets, spec_name, opts)
   if not tmpdir then
      return nil, result_path
   end

   -- Clean up the desktop result_path (not needed for HTML5)
   if result_path then
      pcall(os.remove, result_path)
   end

   -- Overwrite test.script with HTML5 version
   local wrapper = generate_html5_wrapper(bench_file, targets, spec_name, opts)
   local ok, err = utils.writefile(tmpdir .. "/main/test.script", wrapper)
   if not ok then
      dir.rmtree(tmpdir)
      return nil, "cannot write HTML5 test.script: " .. tostring(err)
   end

   return tmpdir
end

--- Check if Playwright is available via node.
--- @param node_path string Path to node binary.
--- @return true|nil ok True if playwright found.
--- @return string|nil err Error message if not found.
local function check_playwright(node_path)
   local cmd = quote_arg(node_path) .. " -e \"require('playwright')\" 2>&1"
   local h = io.popen(cmd)
   if not h then
      return nil, "cannot check playwright availability"
   end
   local output = h:read("*a")
   local ok = h:close()
   -- Lua 5.1 pclose() always returns true, so also check for any output
   -- (a successful require produces no output; errors produce stderr text)
   if not ok or (output and output ~= "" and output:match("%S")) then
      return nil,
         "playwright not found"
            .. " (install with: npm install playwright"
            .. " && npx playwright install chromium)"
   end
   return true
end

--- Locate the luabench-html5-harness script in PATH.
--- @return string|nil path Absolute path if found.
--- @return string|nil err Error message if not found.
local function locate_harness()
   local found = engines.find_command("luabench-html5-harness")
   if found then
      return found
   end
   return nil, "luabench-html5-harness not found in PATH"
end

--- Run a benchmark inside the Defold HTML5 runtime.
--- Scaffolds a Defold project, builds and bundles with bob.jar for js-web,
--- executes the bundle via a Playwright harness, and parses JSON results.
--- @param runtime_path string Resolved path to node.
--- @param bench_file string Absolute path to benchmark file.
--- @param targets {path: string, name: string}[] Target directories.
--- @param spec_name string Spec name to extract ("" for single-spec).
--- @param opts table Options for compare_time (rounds, params).
--- @return table[]|nil results Parsed luamark results, or nil on error.
--- @return string|nil err Error message on failure.
function M.run(runtime_path, bench_file, targets, spec_name, opts)
   -- Check java availability
   local defold = require("luabench.engines.defold")
   local java_ok, java_err = defold._check_java()
   if not java_ok then
      return nil, java_err
   end

   -- Locate bob.jar
   local bob, bob_err = defold._locate_bob()
   if not bob then
      return nil, bob_err
   end

   -- Check playwright availability
   local pw_ok, pw_err = check_playwright(runtime_path)
   if not pw_ok then
      return nil, pw_err
   end

   -- Locate harness script
   local harness_path, harness_err = locate_harness()
   if not harness_path then
      return nil, harness_err
   end

   -- Scaffold HTML5 project
   local tmpdir, scaffold_err = scaffold_html5_project(bench_file, targets, spec_name, opts)
   if not tmpdir then
      return nil, scaffold_err
   end

   --- Clean up temporary directory.
   local function cleanup()
      pcall(dir.rmtree, tmpdir)
   end

   --- Run a shell command; on failure clean up and return nil + error message.
   --- @param cmd string Shell command to execute.
   --- @param label string Human-readable label for error messages.
   --- @return string|nil stdout Captured stdout on success, nil on failure.
   --- @return string|nil err Error message on failure.
   local function exec_step(cmd, label)
      local ok, _, stdout, stderr = utils.executeex(cmd)
      if not ok then
         local output = ((stderr or stdout or ""):match("^(.-)%s*$")) or ""
         cleanup()
         if output ~= "" then
            return nil, label .. " failed: " .. output
         end
         return nil, label .. " failed"
      end
      return stdout
   end

   -- Build with bob.jar for js-web
   local _, build_err = exec_step(
      string.format(
         "java -jar %s --root %s --platform js-web resolve build --archive",
         quote_arg(bob),
         quote_arg(tmpdir)
      ),
      "Defold HTML5 build"
   )
   if build_err then
      return nil, build_err
   end

   -- Bundle for js-web
   local bundle_dir = tmpdir .. "/bundle"
   local _, bundle_err = exec_step(
      string.format(
         "java -jar %s --root %s --platform js-web bundle --bundle-output %s",
         quote_arg(bob),
         quote_arg(tmpdir),
         quote_arg(bundle_dir)
      ),
      "Defold HTML5 bundle"
   )
   if bundle_err then
      return nil, bundle_err
   end

   -- The bundle output structure is: bundle_dir/<project_title>/
   local game_dir = bundle_dir .. "/luabench"

   -- Execute harness: node <harness_path> <game_dir>
   local run_stdout, run_err = exec_step(
      string.format(
         "%s %s %s",
         quote_arg(runtime_path),
         quote_arg(harness_path),
         quote_arg(game_dir)
      ),
      "HTML5 harness"
   )
   if run_err then
      return nil, run_err
   end

   cleanup()

   -- Parse JSON results from stdout
   local json = require("dkjson")
   local results, _, parse_err = json.decode(run_stdout)
   if not results then
      return nil, "failed to parse HTML5 results: " .. tostring(parse_err)
   end

   return results
end

-- Expose internals for testing
M._generate_html5_wrapper = generate_html5_wrapper
M._scaffold_html5_project = scaffold_html5_project
M._check_playwright = check_playwright
M._locate_harness = locate_harness

return M
