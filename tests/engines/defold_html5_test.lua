local dir = require("pl.dir")
local path = require("pl.path")

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-parameter, duplicate-set-field

local defold_html5

local CWD = path.currentdir()
local FIXTURE_DIR = CWD .. "/tests/engines/fixtures"
local TRIVIAL_BENCH = FIXTURE_DIR .. "/trivial_bench.lua"

--- Generate an HTML5 wrapper with default arguments, allowing selective overrides.
--- @param overrides? {bench_file?: string, targets?: table, spec_name?: string, opts?: table}
--- @return string wrapper
local function make_wrapper(overrides)
   local o = overrides or {}
   return defold_html5._generate_html5_wrapper(
      o.bench_file or "/tmp/bench.lua",
      o.targets or { { path = "/tmp/t", name = "v1" } },
      o.spec_name or "",
      o.opts or {}
   )
end

--- Check that a command exists in PATH; call pending() and return false if absent.
--- @param cmd string Command name to look up.
--- @param msg string Pending message if not found.
--- @return string|false path Absolute path on success, false when skipped.
local function require_command(cmd, msg)
   local h = io.popen("command -v " .. cmd .. " 2>/dev/null")
   local result = ""
   if h then
      result = h:read("*a"):match("^(.-)%s*$") or ""
      h:close()
   end
   if result == "" then
      pending(msg)
      return false
   end
   return result
end

describe("engines.defold_html5", function()
   before_each(function()
      package.loaded["luabench.engines.defold_html5"] = nil
      defold_html5 = require("luabench.engines.defold_html5")
   end)

   -- HTML5 wrapper generation

   it(
      "generate_html5_wrapper uses html5.run and document.title instead of os.exit and io.open",
      function()
         local wrapper = make_wrapper()

         assert.matches("html5%.run", wrapper)
         assert.matches("document%.title", wrapper)
         assert.is_nil(string.find(wrapper, "os%.exit"))
         assert.is_nil(string.find(wrapper, "io%.open"))
      end
   )

   it("generate_html5_wrapper has static requires before init function", function()
      local wrapper = make_wrapper()

      local luamark_pos = wrapper:find('require%("luamark"%)')
      local dkjson_pos = wrapper:find('require%("dkjson"%)')
      local init_pos = wrapper:find("function init%(self%)")

      assert.is_not_nil(luamark_pos)
      assert.is_not_nil(dkjson_pos)
      assert.is_not_nil(init_pos)
      assert.is_true(luamark_pos < init_pos)
      assert.is_true(dkjson_pos < init_pos)
   end)

   it("generate_html5_wrapper with targets includes package.path manipulation", function()
      local wrapper = make_wrapper({
         targets = { { path = "/tmp/a", name = "a" }, { path = "/tmp/b", name = "b" } },
      })

      assert.matches("package%.path", wrapper)
      assert.matches("/tmp/a", wrapper, 1, true)
      assert.matches("/tmp/b", wrapper, 1, true)
   end)

   it("generate_html5_wrapper with spec_name extracts correct spec", function()
      local wrapper = make_wrapper({ spec_name = "myspec" })

      assert.matches("myspec", wrapper, 1, true)
   end)

   it("generate_html5_wrapper with opts.rounds includes rounds", function()
      local wrapper = make_wrapper({ opts = { rounds = 42 } })

      assert.matches("42", wrapper, 1, true)
   end)

   it("generate_html5_wrapper with opts.params includes sorted params", function()
      local wrapper = make_wrapper({
         opts = { params = { z_param = { 1, 2 }, a_param = { "x" } } },
      })

      local a_pos = wrapper:find("a_param")
      local z_pos = wrapper:find("z_param")
      assert.is_not_nil(a_pos)
      assert.is_not_nil(z_pos)
      assert.is_true(a_pos < z_pos)
   end)

   -- Scaffold

   it("scaffold_html5_project creates expected files with correct wrapper content", function()
      local tmpdir = defold_html5._scaffold_html5_project(
         "/tmp/bench.lua",
         { { path = "/tmp/t", name = "v1" } },
         "",
         {}
      )

      assert.is_not_nil(tmpdir)
      assert.is_true(path.isdir(tmpdir))
      assert.is_true(path.isfile(tmpdir .. "/game.project"))
      assert.is_true(path.isfile(tmpdir .. "/main/test.go"))
      assert.is_true(path.isfile(tmpdir .. "/main/test.script"))
      assert.is_true(path.isfile(tmpdir .. "/main/main.collection"))

      -- Verify the written script uses html5.run (not os.exit)
      local f = io.open(tmpdir .. "/main/test.script", "r")
      local content = f:read("*a")
      f:close()

      assert.matches("html5%.run", content)
      assert.is_nil(string.find(content, "os%.exit"))

      -- Cleanup
      dir.rmtree(tmpdir)
   end)

   -- Prerequisite checks

   it("check_playwright returns nil and error when playwright is not available", function()
      local result, err = defold_html5._check_playwright("/nonexistent/path/to/node")

      assert.is_nil(result)
      assert.is_string(err)
   end)

   it("locate_harness returns nil and error when luabench-html5-harness is not in PATH", function()
      -- Override find_command to simulate harness not found
      local engines = require("luabench.engines")
      local original_find_command = engines.find_command
      engines.find_command = function(cmd)
         if cmd == "luabench-html5-harness" then
            return nil
         end
         return original_find_command(cmd)
      end

      -- Reload module to pick up stubbed find_command
      package.loaded["luabench.engines.defold_html5"] = nil
      defold_html5 = require("luabench.engines.defold_html5")

      local result, err = defold_html5._locate_harness()

      engines.find_command = original_find_command

      assert.is_nil(result)
      assert.is_string(err)
   end)

   -- Integration: full run orchestration

   it("run executes a trivial benchmark with defold html5 build", function()
      if not require_command("java", "java not found in PATH") then
         return
      end

      local bob = os.getenv("BOB") --luacheck: ignore 311
      if not bob or bob == "" then
         local found =
            require_command("bob.jar", "bob.jar not found (set BOB env var or add to PATH)")
         if not found then
            return
         end
         bob = found --luacheck: ignore 311
      end

      local node = require_command("node", "node not found in PATH")
      if not node then
         return
      end

      -- Check for playwright (no binary to locate -- probe via node require)
      local h = io.popen(node .. " -e \"require('playwright')\" 2>&1")
      if h then
         local pw_output = h:read("*a")
         h:close()
         if pw_output and pw_output:match("%S") then
            pending("playwright not installed")
            return
         end
      end

      if
         not require_command("luabench-html5-harness", "luabench-html5-harness not found in PATH")
      then
         return
      end

      local results, err = defold_html5.run(
         node,
         TRIVIAL_BENCH,
         { { path = FIXTURE_DIR, name = "test" } },
         "",
         { rounds = 3 }
      )

      assert.is_nil(err)
      assert.is_table(results)
      assert.is_true(#results > 0)
   end)
end)
