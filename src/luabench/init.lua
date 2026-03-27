local argparse = require("argparse")
local discover = require("luabench.discover")
local engines = require("luabench.engines")
local export = require("luabench.export")
local resolve = require("luabench.resolve")
local runner = require("luabench.runner")
local subprocess = require("luabench.subprocess")

local M = {}

M._VERSION = "0.5.0"

--- Write an error message to stderr and exit with code 1.
--- @param msg string|nil Error message (without prefix or newline).
local function die(msg)
   io.stderr:write("luabench: " .. tostring(msg) .. "\n")
   os.exit(1)
end

--- Parse raw parameter strings into a typed params table.
--- @param raw_params string[] Array of "NAME:VALUE" strings.
--- @return table<string, any[]>|nil params Parsed params, or nil on error.
--- @return string|nil err Error message if parsing failed.
local function parse_params(raw_params)
   local params = {}
   for i = 1, #raw_params do
      local name, value = raw_params[i]:match("^([^:]+):(.+)$")
      if not name then
         return nil,
            string.format("invalid parameter format: %q (expected NAME:VALUE)", raw_params[i])
      end
      local num = tonumber(value)
      if num then
         value = num
      elseif value == "true" then
         value = true
      elseif value == "false" then
         value = false
      end
      if not params[name] then
         params[name] = {}
      end
      params[name][#params[name] + 1] = value
   end
   return params
end

M._parse_params = parse_params

--- Build argparse parser with all CLI flags.
--- @return table parser Configured argparse parser.
function M.build_parser()
   local parser =
      argparse("luabench", "Compare Lua library performance across git refs."):add_help(true)
   parser:command_target("command")
   parser:require_command(true)

   local ref = parser:command("ref", "Compare a library across git references.")
   ref:argument("targets", "Target specifiers ([alias=]repo#ref or local dir)."):args("+")
   ref:option("-b --bench", "Benchmark files or directories."):count("*")
   ref:option("-p --param", "Parameter in format NAME:VALUE."):count("*")
   ref:option("-R --runtime", "Lua runtime (e.g. luajit, lua, love, defold).")
   ref:option("-o --output", "Output file path.")
   ref:flag("-t --test", "Run in test mode (minimal rounds).")
   ref:option("--filter", "Filter benchmarks by name pattern."):count("*")
   ref:option(
      "--prepare",
      "Shell command to run in each cloned target directory before benchmarking."
   )
   ref:option("--lua-path", "Subdirectory within each target to add to package.path."):count("*")

   return parser
end

--- Parse CLI arguments and dispatch the requested command.
--- @param argv string[]|nil CLI arguments (defaults to global arg table).
function M.main(argv)
   local parser = M.build_parser()
   local args = parser:parse(argv)

   if args.command == "ref" then
      -- Resolve targets (fail fast on error)
      local targets, err = resolve.resolve_targets(args.targets)
      if not targets then
         die(err)
      end
      ---@cast targets -nil

      --- Clean up temp directories and exit with an error.
      --- @param msg string|nil Error message.
      local function cleanup_and_die(msg)
         resolve.cleanup(targets)
         die(msg)
      end

      -- Run preparation command if --prepare specified
      if args.prepare then
         local prepared = resolve.prepare_targets(targets, args.prepare)
         if #prepared == 0 then
            cleanup_and_die("all targets failed preparation")
         end
         targets = prepared
      end

      -- Discover benchmarks (default to cwd)
      local bench_paths = args.bench
      if #bench_paths == 0 then
         bench_paths = { "." }
      end
      local bench_files = discover.discover(bench_paths)
      if #bench_files == 0 then
         cleanup_and_die("no benchmark files found")
      end

      -- Build opts from CLI flags
      local opts = {}
      if args.test then
         opts.rounds = 1
      end
      if args.filter and #args.filter > 0 then
         opts.filters = args.filter
      end
      if args.param and #args.param > 0 then
         local params, param_err = parse_params(args.param)
         if not params then
            cleanup_and_die(param_err)
         end
         opts.params = params
      end
      if args.lua_path and #args.lua_path > 0 then
         local paths = {}
         for i = 1, #args.lua_path do
            paths[i] = args.lua_path[i]:gsub("/+$", "")
         end
         opts.lua_path = paths
      end

      -- Resolve runtime if -R specified (fail fast on error)
      if args.runtime then
         local engine_name = engines.detect(args.runtime)
         local resolve_name = engine_name and engines.runtime_cmd(engine_name) or args.runtime
         local runtime_path, runtime_err = subprocess.resolve_runtime(resolve_name)
         if not runtime_path then
            cleanup_and_die(runtime_err)
         end
         opts.runtime = runtime_path
         if engine_name then
            opts.engine_name = engine_name
         end
      end

      -- Run benchmarks then cleanup (cleanup always runs)
      local run_ok, run_result = pcall(runner.run, bench_files, targets, opts)
      resolve.cleanup(targets)
      if not run_ok then
         local msg = tostring(run_result)
         if msg:find("interrupted") then
            os.exit(130)
         end
         die("benchmark error: " .. msg)
      end

      if args.output then
         local ok, write_err = export.write_json(args.output, run_result, targets, M._VERSION)
         if not ok then
            die("failed to write JSON: " .. tostring(write_err))
         end
      end
   end
end

return M
