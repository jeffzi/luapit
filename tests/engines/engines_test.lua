---@diagnostic disable: need-check-nil, duplicate-set-field

describe("engines", function()
   local engines

   before_each(function()
      package.loaded["luabench.engines"] = nil
      engines = require("luabench.engines")
   end)

   -- detect() tests

   for _, case in ipairs({
      { input = "love", expected = "love", desc = "love name" },
      { input = "defold", expected = "defold", desc = "defold name" },
      { input = "/usr/bin/love", expected = "love", desc = "love absolute path" },
      { input = "/usr/bin/love.exe", expected = "love", desc = "love path with .exe suffix" },
   }) do
      it("detect returns " .. case.expected .. " for " .. case.desc, function()
         local result = engines.detect(case.input)

         assert.are_equal(case.expected, result)
      end)
   end

   for _, case in ipairs({
      { input = "luajit", desc = "luajit" },
      { input = "lua", desc = "lua" },
      { input = "/usr/bin/lua", desc = "lua absolute path" },
   }) do
      it("detect returns nil for unknown runtime " .. case.desc, function()
         local result = engines.detect(case.input)

         assert.is_nil(result)
      end)
   end

   -- get_adapter() tests

   it("get_adapter for love returns the love2d adapter module", function()
      local adapter = engines.get_adapter("love")

      assert.is_table(adapter)
      assert.is_function(adapter.run)
   end)

   it("get_adapter for defold returns the defold adapter module", function()
      local adapter = engines.get_adapter("defold")

      assert.is_table(adapter)
      assert.is_function(adapter.run)
   end)

   -- find_module_path() tests

   it("find_module_path returns path ending in luamark.lua for luamark", function()
      local result = engines.find_module_path("luamark")

      assert.is_string(result)
      assert.matches("luamark%.lua$", result)
   end)

   it("find_module_path returns path ending in dkjson.lua for dkjson", function()
      local result = engines.find_module_path("dkjson")

      assert.is_string(result)
      assert.matches("dkjson%.lua$", result)
   end)

   it("find_module_path returns nil and error for nonexistent module", function()
      local result, err = engines.find_module_path("nonexistent_module_xyz")

      assert.is_nil(result)
      assert.is_string(err)
      assert.matches("nonexistent_module_xyz", err)
   end)
end)
