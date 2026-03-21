local argparse = require("argparse")
local discover = require("luabench.discover")
local export = require("luabench.export")
local resolve = require("luabench.resolve")
local runner = require("luabench.runner")

local M = {}

M._VERSION = "0.3.0"

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
   ref:option("-R --runtime", "Lua runtime [default: luajit].")
   ref:option("-o --output", "Output file path.")
   ref:flag("-t --test", "Run in test mode (minimal rounds).")
   ref:option("--filter", "Filter benchmarks by name pattern.")

   return parser
end

--- Parse CLI arguments and dispatch the requested command.
--- @param argv string[]|nil CLI arguments (defaults to global arg table).
function M.main(argv)
   local parser = M.build_parser()
   local args = parser:parse(argv)

   if args.command == "ref" then
      -- Resolve targets (fail fast per D-11)
      local targets, err = resolve.resolve_targets(args.targets)
      if targets == nil then
         io.stderr:write("luabench: " .. err .. "\n")
         os.exit(1)
      end

      -- Discover benchmarks (default to cwd per D-02)
      local bench_paths = args.bench
      if #bench_paths == 0 then
         bench_paths = { "." }
      end
      local bench_files = discover.discover(bench_paths)
      if #bench_files == 0 then
         resolve.cleanup(targets)
         io.stderr:write("luabench: no benchmark files found\n")
         os.exit(1)
      end

      -- Run benchmarks then cleanup (cleanup always runs per D-14)
      local run_ok, run_result = pcall(runner.run, bench_files, targets)
      resolve.cleanup(targets)
      if not run_ok then
         io.stderr:write("luabench: benchmark error: " .. tostring(run_result) .. "\n")
         os.exit(1)
      end

      if run_ok and args.output then
         local ok, write_err = export.write_json(args.output, run_result, targets, M._VERSION)
         if not ok then
            io.stderr:write("luabench: failed to write JSON: " .. tostring(write_err) .. "\n")
            os.exit(1)
         end
      end
   end
end

return M
