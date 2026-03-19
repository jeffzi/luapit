describe("luabench", function()
   local luabench

   before_each(function()
      luabench = require("luabench")
   end)

   it("exports main function and _VERSION string", function()
      assert.is_table(luabench)
      assert.is_function(luabench.main)
      assert.is_string(luabench._VERSION)
   end)

   it("_VERSION matches semver pattern", function()
      assert.matches("%d+%.%d+%.%d+", luabench._VERSION)
   end)

   it("build_parser returns a parser with parse method", function()
      local parser = luabench.build_parser()

      assert.is_table(parser)
      assert.is_function(parser.parse)
      assert.is_function(parser.pparse)
   end)

   it("parsing ref with paths succeeds", function()
      local parser = luabench.build_parser()

      local ok, args = parser:pparse({ "ref", "benchmarks/" })

      assert.is_true(ok)
      assert.are_equal("ref", args.command)
      assert.are_same({ "benchmarks/" }, args.paths)
   end)

   it("parsing ref with multiple --ref flags produces ref list", function()
      local parser = luabench.build_parser()

      local ok, args = parser:pparse({ "ref", "benchmarks/", "-r", ".#main", "-r", ".#dev" })

      assert.is_true(ok)
      assert.are_same({ ".#main", ".#dev" }, args.ref)
   end)

   it("parsing with no args raises error", function()
      local parser = luabench.build_parser()

      local ok = parser:pparse({})

      assert.is_false(ok)
   end)

   it("parsing ref with no paths raises error", function()
      local parser = luabench.build_parser()

      local ok = parser:pparse({ "ref" })

      assert.is_false(ok)
   end)
end)
