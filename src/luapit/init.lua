local argparse = require("argparse")
local discover = require("luapit.discover")
local engines = require("luapit.engines")
local export = require("luapit.export")
local resolve = require("luapit.resolve")
local runner = require("luapit.runner")
local subprocess = require("luapit.subprocess")

local M = {}

M._VERSION = "0.6.0"

--- Write an error message to stderr and exit with code 1.
--- @param msg string|nil Error message (without prefix or newline).
local function die(msg)
   io.stderr:write("luapit: " .. tostring(msg) .. "\n")
   os.exit(1)
end

--- Coerce a string value to its typed representation (number, boolean, or string).
--- @param value string String value to coerce.
--- @return any Coerced value (number, boolean, or original string).
local function coerce_value(value)
   local num = tonumber(value)
   if num ~= nil then
      return num
   end
   if value == "true" then
      return true
   end
   if value == "false" then
      return false
   end
   return value
end

--- Parse raw parameter strings into a typed params table.
--- @param raw_params string[] Array of "NAME:VALUE" strings.
--- @return table<string, any[]>|nil params Parsed params, or nil on error.
--- @return string|nil err Error message if parsing failed.
local function parse_params(raw_params)
   local params = {}
   for i = 1, #raw_params do
      local name, value = raw_params[i]:match("^([^:]+):(.+)$")
      if name == nil then
         return nil,
            string.format("invalid parameter format: %q (expected NAME:VALUE)", raw_params[i])
      end
      if params[name] == nil then
         params[name] = {}
      end
      params[name][#params[name] + 1] = coerce_value(value)
   end
   return params
end

--- Build argparse parser with all CLI flags.
--- @return table parser Configured argparse parser.
function M.build_parser()
   local parser =
      argparse("luapit", "Compare Lua library performance across git refs."):add_help(true)

   parser:argument("targets", "Target specifiers: [alias=]repo#ref or local dir path."):args("+")
   parser
      :option("-b --bench", "Benchmark files or directories (repeatable; default: .).")
      :count("*")
   parser
      :option(
         "-p --param",
         "Parameter as NAME:VALUE (repeatable; numbers and booleans auto-coerced)."
      )
      :count("*")
   parser:option(
      "-R --runtime",
      "Lua runtime: luajit, lua, love, defold, or a path (default: auto-detected)."
   )
   parser:option("-o --output", "Write results to a JSON file.")
   parser:flag("-t --test", "Test mode: run 1 round per benchmark for a quick smoke test.")
   parser:option("--filter", "Filter benchmarks by Lua pattern (repeatable, OR logic)."):count("*")
   parser:option(
      "--prepare",
      "Shell command to run in each cloned target directory before benchmarking."
   )
   parser
      :option("--lua-path", "Subdirectory within each target to add to package.path (repeatable).")
      :count("*")
   parser:flag("--isolate", "Run each target in its own subprocess for heap isolation.")

   return parser
end

--- Parse CLI arguments and run the benchmark pipeline.
--- @param argv string[]|nil CLI arguments (defaults to global arg table).
function M.main(argv)
   local parser = M.build_parser()
   local args = parser:parse(argv)

   -- Resolve targets (fail fast on error)
   local targets, err = resolve.resolve_targets(args.targets)
   if targets == nil then
      die(err)
   end
   ---@cast targets -nil

   -- Run the entire pipeline under pcall so any "interrupted!" error
   -- (from resolve, prepare, runner, or subprocesses) is caught, cleanup
   -- always runs, and we exit 130 cleanly.
   local run_ok, run_err = pcall(function()
      --- Raise a structured error caught by the outer pcall; never returns.
      --- @param msg string|nil Error message.
      local function bail(msg)
         error({ bail_msg = msg }, 0)
      end

      if args.prepare ~= nil then
         local prepared = resolve.prepare_targets(targets, args.prepare)
         if #prepared == 0 then
            bail("all targets failed preparation")
         end
         targets = prepared
      end

      local bench_paths = args.bench
      if #bench_paths == 0 then
         bench_paths = { "." }
      end
      local bench_files = discover.discover(bench_paths)
      if #bench_files == 0 then
         bail("no benchmark files found")
      end

      local opts = {}
      if args.test ~= nil then
         opts.rounds = 1
      end
      if #args.filter > 0 then
         opts.filters = args.filter
      end
      if #args.param > 0 then
         local params, param_err = parse_params(args.param)
         if params == nil then
            bail(param_err)
         end
         opts.params = params
      end
      if #args.lua_path > 0 then
         local paths = {}
         for i = 1, #args.lua_path do
            paths[i] = args.lua_path[i]:gsub("/+$", "")
         end
         opts.lua_path = paths
      end
      if args.isolate then
         opts.isolate = true
         if opts.params then
            bail("--isolate cannot be combined with --param")
         end
      end

      local runtime_path, runtime_err, engine_name
      if args.runtime ~= nil then
         engine_name = engines.detect(args.runtime)
         if opts.isolate and engine_name ~= nil then
            bail("--isolate cannot be combined with engine runtimes")
         end
         local resolve_name = engine_name ~= nil and engines.runtime_cmd(engine_name)
            or args.runtime
         runtime_path, runtime_err = subprocess.resolve_runtime(resolve_name)
      else
         runtime_path, runtime_err = subprocess.detect_runtime()
      end

      if runtime_path == nil then
         bail(runtime_err)
      end

      opts.runtime = runtime_path
      if engine_name ~= nil then
         opts.engine_name = engine_name
      end

      local run_result = runner.run(bench_files, targets, opts)

      if args.output ~= nil then
         local ok, write_err = export.write_json(args.output, run_result, targets, M._VERSION)
         if not ok then
            bail("failed to write JSON: " .. tostring(write_err))
         end
      end
   end)

   resolve.cleanup(targets)

   if not run_ok then
      if type(run_err) == "table" and run_err.bail_msg ~= nil then
         die(run_err.bail_msg)
      end
      local msg = tostring(run_err)
      if msg:find("interrupted") ~= nil then
         os.exit(130)
      end
      die("benchmark error: " .. msg)
   end
end

return M
