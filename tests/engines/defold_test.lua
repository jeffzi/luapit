local dir = require("pl.dir")
local path = require("pl.path")

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-parameter, duplicate-set-field

local defold

--- Generate a wrapper with default arguments, allowing selective overrides.
--- @param overrides? {bench_file?: string, targets?: table, spec_name?: string, opts?: table, result_path?: string}
--- @return string wrapper
local function make_wrapper(overrides)
   local o = overrides or {}
   return defold._generate_defold_wrapper(
      o.bench_file or "/tmp/bench.lua",
      o.targets or { { path = "/tmp/t", name = "v1" } },
      o.spec_name or "",
      o.opts or {},
      o.result_path or "/tmp/result.json"
   )
end

describe("engines.defold", function()
   before_each(function()
      package.loaded["luabench.engines.defold"] = nil
      defold = require("luabench.engines.defold")
   end)

   -- Template constants
   it("GAME_PROJECT contains project, bootstrap, and shared_state sections", function()
      assert.matches("%[project%]", defold._GAME_PROJECT)
      assert.matches("%[bootstrap%]", defold._GAME_PROJECT)
      assert.matches("shared_state", defold._GAME_PROJECT)
      assert.matches("title = luabench", defold._GAME_PROJECT)
   end)

   it("MAIN_COLLECTION references test.go", function()
      assert.matches('prototype: "/main/test.go"', defold._MAIN_COLLECTION, 1, true)
   end)

   it("TEST_GO references test.script", function()
      assert.matches('component: "/main/test.script"', defold._TEST_GO, 1, true)
   end)

   it("INPUT_BINDING contains ESC key trigger", function()
      assert.matches("KEY_ESC", defold._INPUT_BINDING)
   end)

   -- Wrapper generation
   it("generate_defold_wrapper contains init callback with pcall and exit codes", function()
      local wrapper = make_wrapper()

      assert.matches("function init%(self%)", wrapper)
      assert.matches("os%.exit%(0%)", wrapper)
      assert.matches("os%.exit%(1%)", wrapper)
      assert.matches("pcall", wrapper)
      assert.matches("dofile", wrapper)
      assert.matches("io%.open", wrapper)
   end)

   it("generate_defold_wrapper has static requires before init function", function()
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

   it("generate_defold_wrapper with targets includes package.path manipulation", function()
      local wrapper = make_wrapper({
         targets = { { path = "/tmp/a", name = "a" }, { path = "/tmp/b", name = "b" } },
      })

      assert.matches("package%.path", wrapper)
      assert.matches("/tmp/a", wrapper, 1, true)
      assert.matches("/tmp/b", wrapper, 1, true)
   end)

   it("generate_defold_wrapper with spec_name extracts correct spec", function()
      local wrapper = make_wrapper({ spec_name = "myspec" })

      assert.matches("myspec", wrapper, 1, true)
   end)

   it("generate_defold_wrapper with opts.rounds includes rounds", function()
      local wrapper = make_wrapper({ opts = { rounds = 42 } })

      assert.matches("42", wrapper, 1, true)
   end)

   it("generate_defold_wrapper with opts.params includes sorted params", function()
      local wrapper = make_wrapper({
         opts = { params = { z_param = { 1, 2 }, a_param = { "x" } } },
      })

      local a_pos = wrapper:find("a_param")
      local z_pos = wrapper:find("z_param")
      assert.is_not_nil(a_pos)
      assert.is_not_nil(z_pos)
      assert.is_true(a_pos < z_pos)
   end)

   it("generate_defold_wrapper writes JSON to result_path via io.open", function()
      local wrapper = make_wrapper({ result_path = "/tmp/my_result.json" })

      assert.matches("/tmp/my_result.json", wrapper, 1, true)
      assert.matches("io%.open", wrapper)
      assert.matches("json%.encode", wrapper)
   end)

   -- Scaffold project
   it("scaffold_project creates expected directory structure and files", function()
      local tmpdir, result_path = defold._scaffold_project(
         "/tmp/bench.lua",
         { { path = "/tmp/t", name = "v1" } },
         "",
         {}
      )

      assert.is_not_nil(tmpdir)
      assert.is_not_nil(result_path)
      assert.is_true(path.isdir(tmpdir))
      assert.is_true(path.isfile(tmpdir .. "/game.project"))
      assert.is_true(path.isfile(tmpdir .. "/input/game.input_binding"))
      assert.is_true(path.isfile(tmpdir .. "/main/main.collection"))
      assert.is_true(path.isfile(tmpdir .. "/main/test.go"))
      assert.is_true(path.isfile(tmpdir .. "/main/test.script"))
      assert.is_true(path.isfile(tmpdir .. "/main/luamark.lua"))
      assert.is_true(path.isfile(tmpdir .. "/main/dkjson.lua"))

      -- Cleanup
      dir.rmtree(tmpdir)
      pcall(os.remove, result_path)
   end)

   -- locate_bob
   it("locate_bob returns nil and error when BOB not set and bob.jar not in PATH", function()
      -- Temporarily unset BOB by overriding the env lookup
      local original_getenv = os.getenv
      os.getenv = function(name) --luacheck: ignore 122
         if name == "BOB" then
            return nil
         end
         return original_getenv(name)
      end

      -- Reload module to pick up env change
      package.loaded["luabench.engines.defold"] = nil
      defold = require("luabench.engines.defold")

      local result, err = defold._locate_bob()

      os.getenv = original_getenv --luacheck: ignore 122

      -- bob.jar is unlikely to be in PATH in test env
      if result ~= nil then
         pending("bob.jar found in PATH, cannot test missing bob.jar error")
         return
      end
      assert.is_nil(result)
      assert.is_string(err)
      assert.matches("bob.jar", err, 1, true)
   end)

   -- check_java
   it("check_java succeeds when java is available", function()
      -- Check if java is available
      local h = io.popen("command -v java 2>/dev/null")
      local java_path = ""
      if h then
         java_path = h:read("*a"):match("^(.-)%s*$") or ""
         h:close()
      end

      if not java_path or java_path == "" then
         pending("java not found in PATH")
         return
      end

      local ok, err = defold._check_java()

      assert.is_true(ok)
      assert.is_nil(err)
   end)

   -- Scaffold error paths
   it("scaffold_project returns nil and error when luamark module not found", function()
      -- Override find_module_path to simulate failure
      local eng = require("luabench.engines")
      local original_find = eng.find_module_path
      eng.find_module_path = function()
         return nil, "module source not found: luamark"
      end

      local tmpdir_result, err = defold._scaffold_project(
         "/tmp/bench.lua",
         { { path = "/tmp/t", name = "v1" } },
         "",
         {}
      )

      eng.find_module_path = original_find

      assert.is_nil(tmpdir_result)
      assert.is_string(err)
      assert.matches("luamark", err, 1, true)
   end)

   -- Integration test (conditional)
   it("run executes a trivial benchmark with dmengine_headless and bob.jar", function()
      -- Check for dmengine_headless
      local h1 = io.popen("command -v dmengine_headless 2>/dev/null")
      local dmengine = ""
      if h1 then
         dmengine = h1:read("*a"):match("^(.-)%s*$") or ""
         h1:close()
      end

      if not dmengine or dmengine == "" then
         pending("dmengine_headless not found in PATH")
         return
      end

      -- Check for bob.jar
      local bob = os.getenv("BOB")
      if not bob or bob == "" then
         local h2 = io.popen("command -v bob.jar 2>/dev/null")
         if h2 then
            bob = h2:read("*a"):match("^(.-)%s*$") or ""
            h2:close()
         end
      end
      if not bob or bob == "" then
         pending("bob.jar not found (set BOB env var or add to PATH)")
         return
      end

      -- Check for java
      local h3 = io.popen("command -v java 2>/dev/null")
      local java = ""
      if h3 then
         java = h3:read("*a"):match("^(.-)%s*$") or ""
         h3:close()
      end
      if not java or java == "" then
         pending("java not found in PATH")
         return
      end

      -- Create a trivial benchmark file
      local bench_path = os.tmpname() .. "_bench.lua"
      local bf = io.open(bench_path, "w")
      bf:write([[
return {
   fn = function()
      local sum = 0
      for i = 1, 100 do sum = sum + i end
   end,
}
]])
      bf:close()

      local results, err = defold.run(
         dmengine,
         bench_path,
         { { path = path.dirname(bench_path), name = "test" } },
         "",
         { rounds = 3 }
      )

      pcall(os.remove, bench_path)

      assert.is_nil(err)
      assert.is_table(results)
      assert.is_true(#results > 0)
   end)
end)
