local argparse = require("argparse")

local M = {}

M._VERSION = "0.1.0-dev"

--- Build argparse parser with all CLI flags.
--- @return table parser Configured argparse parser.
function M.build_parser()
   local parser = argparse("luabench", "Compare Lua library performance across git refs.")
      :add_help(true)
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

--- Entry point for the CLI.
function M.main()
   local parser = M.build_parser()
   parser:parse()

   io.stderr:write("luabench: not yet implemented\n")
   os.exit(1)
end

return M
