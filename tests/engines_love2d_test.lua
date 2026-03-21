---@diagnostic disable: need-check-nil, duplicate-set-field, redundant-parameter, missing-parameter
local dir = require("pl.dir")
local path = require("pl.path")

describe("engines.love2d", function()
   local love2d

   local CWD = path.currentdir()
   local FIXTURE_DIR = CWD .. "/tests/fixtures"
   local LIBV1_DIR = FIXTURE_DIR .. "/targets/libv1"
   local LIBV2_DIR = FIXTURE_DIR .. "/targets/libv2"
   local SORT_BENCH = FIXTURE_DIR .. "/benchmarks/sort_bench.lua"

   before_each(function()
      package.loaded["luabench.engines.love2d"] = nil
      love2d = require("luabench.engines.love2d")
   end)

   -- CONF_TEMPLATE tests

   it("CONF_TEMPLATE disables visual and audio modules", function()
      local conf = love2d._CONF_TEMPLATE

      assert.is_string(conf)
      assert.matches("love%.conf", conf)
      assert.matches("modules%.window = false", conf)
      assert.matches("modules%.graphics = false", conf)
      assert.matches("modules%.audio = false", conf)
      assert.matches("modules%.sound = false", conf)
      assert.matches("modules%.image = false", conf)
      assert.matches("modules%.video = false", conf)
      assert.matches("modules%.joystick = false", conf)
      assert.matches("modules%.physics = false", conf)
      assert.matches("modules%.touch = false", conf)
      assert.matches("modules%.font = false", conf)
   end)

   it("CONF_TEMPLATE enables required runtime modules", function()
      local conf = love2d._CONF_TEMPLATE

      assert.matches("modules%.timer = true", conf)
      assert.matches("modules%.event = true", conf)
      assert.matches("modules%.system = true", conf)
      assert.matches("modules%.data = true", conf)
      assert.matches("modules%.math = true", conf)
   end)

   -- generate_love_wrapper tests

   it("_generate_love_wrapper produces wrapper with love.load and love.event.quit", function()
      local wrapper = love2d._generate_love_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {},
         "/tmp/test_results.json"
      )

      assert.is_string(wrapper)
      assert.matches("function love%.load", wrapper)
      assert.matches("love%.event%.quit%(0%)", wrapper)
      assert.matches("love%.event%.quit%(1%)", wrapper)
   end)

   it("_generate_love_wrapper contains pcall error handling", function()
      local wrapper = love2d._generate_love_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {},
         "/tmp/test_results.json"
      )

      assert.matches("pcall", wrapper)
      assert.matches("io%.stderr", wrapper)
   end)

   it("_generate_love_wrapper requires luamark and dkjson with literal strings", function()
      local wrapper = love2d._generate_love_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {},
         "/tmp/test_results.json"
      )

      assert.matches('require%("luamark"%)', wrapper)
      assert.matches('require%("dkjson"%)', wrapper)
   end)

   it("_generate_love_wrapper loads benchmark via dofile with absolute path", function()
      local wrapper = love2d._generate_love_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {},
         "/tmp/test_results.json"
      )

      assert.matches("dofile", wrapper)
      assert.matches(SORT_BENCH:gsub("[%(%)%.%%+%-%*%?%[%]%^%$]", "%%%0"), wrapper)
   end)

   it("_generate_love_wrapper writes JSON to result_path via io.open", function()
      local wrapper = love2d._generate_love_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {},
         "/tmp/test_results.json"
      )

      assert.matches("io%.open", wrapper)
      assert.matches("encode", wrapper)
      assert.matches("/tmp/test_results%.json", wrapper)
   end)

   it("_generate_love_wrapper with multiple targets includes all target paths", function()
      local wrapper = love2d._generate_love_wrapper(SORT_BENCH, {
         { path = LIBV1_DIR, name = "libv1" },
         { path = LIBV2_DIR, name = "libv2" },
      }, "", {}, "/tmp/test_results.json")

      assert.matches("libv1", wrapper)
      assert.matches("libv2", wrapper)
      assert.matches("package%.path", wrapper)
   end)

   it("_generate_love_wrapper with spec_name extracts correct spec", function()
      local wrapper = love2d._generate_love_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "my_spec",
         {},
         "/tmp/test_results.json"
      )

      assert.matches("my_spec", wrapper)
   end)

   it("_generate_love_wrapper with opts.rounds includes rounds", function()
      local wrapper = love2d._generate_love_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         { rounds = 42 },
         "/tmp/test_results.json"
      )

      assert.matches("42", wrapper)
   end)

   it("_generate_love_wrapper with opts.params includes sorted params", function()
      local wrapper = love2d._generate_love_wrapper(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         { params = { z = { 1 }, a = { 2 }, m = { 3 } } },
         "/tmp/test_results.json"
      )

      local pos_a = wrapper:find('"a"', 1, true)
      local pos_m = wrapper:find('"m"', 1, true)
      local pos_z = wrapper:find('"z"', 1, true)
      assert.is_not_nil(pos_a, "expected param 'a' in wrapper")
      assert.is_not_nil(pos_m, "expected param 'm' in wrapper")
      assert.is_not_nil(pos_z, "expected param 'z' in wrapper")
      assert.is_true(pos_a < pos_m, "param 'a' must appear before 'm'")
      assert.is_true(pos_m < pos_z, "param 'm' must appear before 'z'")
   end)

   -- scaffold_project tests

   it("_scaffold_project creates temp dir with expected files", function()
      local tmpdir, result_path = love2d._scaffold_project(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {}
      )

      assert.is_string(tmpdir)
      assert.is_string(result_path)
      assert.is_true(path.isdir(tmpdir))
      assert.is_true(path.isfile(tmpdir .. "/main.lua"))
      assert.is_true(path.isfile(tmpdir .. "/conf.lua"))
      assert.is_true(path.isfile(tmpdir .. "/luamark.lua"))
      assert.is_true(path.isfile(tmpdir .. "/dkjson.lua"))

      -- cleanup
      dir.rmtree(tmpdir)
      os.remove(result_path)
      local result_base = result_path:gsub("%.json$", "")
      os.remove(result_base)
   end)

   it("_scaffold_project returns nil and error when luamark cannot be found", function()
      local engines = require("luabench.engines")
      local original = engines.find_module_path
      engines.find_module_path = function(name)
         if name == "luamark" then
            return nil, "module source not found: luamark"
         end
         return original(name)
      end

      local tmpdir, err = love2d._scaffold_project(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {}
      )

      engines.find_module_path = original

      assert.is_nil(tmpdir)
      assert.is_string(err)
      assert.matches("luamark", err)
   end)

   it("_scaffold_project returns nil and error when dkjson cannot be found", function()
      local engines = require("luabench.engines")
      local original = engines.find_module_path
      engines.find_module_path = function(name)
         if name == "dkjson" then
            return nil, "module source not found: dkjson"
         end
         return original(name)
      end

      local tmpdir, err = love2d._scaffold_project(
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {}
      )

      engines.find_module_path = original

      assert.is_nil(tmpdir)
      assert.is_string(err)
      assert.matches("dkjson", err)
   end)

   -- run() error handling tests

   it("run returns nil and error when scaffold fails", function()
      local engines = require("luabench.engines")
      local original = engines.find_module_path
      engines.find_module_path = function()
         return nil, "module source not found: luamark"
      end

      local results, err = love2d.run(
         "/usr/bin/love",
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" } },
         "",
         {}
      )

      engines.find_module_path = original

      assert.is_nil(results)
      assert.is_string(err)
      assert.matches("luamark", err)
   end)

   -- Integration test (conditional)

   it("run with actual love binary returns results", function()
      local subprocess = require("luabench.subprocess")
      local love_path = subprocess.resolve_runtime("love")
      if love_path == nil then
         pending("love not found in PATH")
         return
      end

      local results, err = love2d.run(
         love_path,
         SORT_BENCH,
         { { path = LIBV1_DIR, name = "libv1" }, { path = LIBV2_DIR, name = "libv2" } },
         "",
         { rounds = 1 }
      )

      assert.is_nil(err)
      assert.is_table(results)
      assert.is_true(#results >= 1)
      local r = results[1]
      assert.is_string(r.name)
      assert.is_number(r.median)
      assert.is_number(r.rounds)
   end)
end)
