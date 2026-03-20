local argparse = require("argparse")
local discover = require("luabench.discover")
local runner = require("luabench.runner")

local M = {}

M._VERSION = "0.1.0-dev"

--- Build argparse parser with all CLI flags.
--- @return table parser Configured argparse parser.
function M.build_parser()
   local parser =
      argparse("luabench", "Compare Lua library performance across git refs."):add_help(true)
   parser:command_target("command")
   parser:require_command(true)

   local ref = parser:command("ref", "Compare a library across git references.")
   ref:argument("paths", "Benchmark files or directories."):args("+")
   ref:option("-r --ref", "Git reference ([alias=]repo#ref)."):count("*")
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
      local bench_files = discover.discover(args.paths)
      if #bench_files == 0 then
         io.stderr:write("luabench: no benchmark files found\n")
         os.exit(1)
      end

      -- Phase 2: treat -r values as local directory targets
      -- Phase 3 will add git ref resolution
      local targets = args.ref or {}
      if #targets == 0 then
         io.stderr:write("luabench: no targets specified (use -r <directory>)\n")
         os.exit(1)
      end

      runner.run(bench_files, targets)
   end
end

return M
