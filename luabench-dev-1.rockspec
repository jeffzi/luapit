package = "luabench"

local package_version = "dev"
local rockspec_revision = "1"

version = package_version .. "-" .. rockspec_revision

source = {
   url = "git+https://github.com/jeffzi/luabench.git",
}

if package_version == "dev" then
   source.branch = "main"
else
   source.tag = "v" .. package_version
end

description = {
   summary = "Compare Lua library performance across git refs.",
   detailed = [[
      LuaBench orchestrates running LuaMark benchmarks across git references
      and local implementations, then compares the results.
   ]],
   homepage = "https://github.com/jeffzi/luabench",
   license = "MIT",
}

dependencies = {
   "lua >= 5.1",
   "argparse >= 0.7.1",
   "luamark >= 1.0.0",
   "penlight >= 1.11.0",
   "dkjson >= 2.5",
   "chronos >= 0.2",
   "terminal",
   "luasystem >= 0.6.3",
}

build = {
   type = "builtin",
   modules = {
      luabench = "src/luabench/init.lua",
      ["luabench.discover"] = "src/luabench/discover.lua",
      ["luabench.export"] = "src/luabench/export.lua",
      ["luabench.loader"] = "src/luabench/loader.lua",
      ["luabench.resolve"] = "src/luabench/resolve.lua",
      ["luabench.progress"] = "src/luabench/progress.lua",
      ["luabench.runner"] = "src/luabench/runner.lua",
      ["luabench.subprocess"] = "src/luabench/subprocess.lua",
      ["luabench.engines"] = "src/luabench/engines/init.lua",
      ["luabench.engines.love2d"] = "src/luabench/engines/love2d.lua",
      ["luabench.engines.defold"] = "src/luabench/engines/defold.lua",
      ["luabench.engines.defold_html5"] = "src/luabench/engines/defold_html5.lua",
   },
   install = {
      bin = {
         luabench = "bin/luabench",
         ["luabench-html5-harness"] = "src/luabench/engines/defold_html5_harness.mjs",
      },
   },
}
