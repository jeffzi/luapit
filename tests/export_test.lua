---@diagnostic disable: need-check-nil
describe("export", function()
   local export
   local json

   before_each(function()
      export = require("luabench.export")
      json = require("dkjson")
   end)

   --- Write JSON to a temp file, read it back as a parsed table, and clean up.
   --- @param results table
   --- @param targets table
   --- @param version string
   --- @return table data Decoded JSON envelope.
   --- @return boolean ok True if write_json succeeded.
   local function write_and_read(results, targets, version)
      local filepath = os.tmpname()
      local ok = export.write_json(filepath, results, targets, version)
      local f = io.open(filepath, "r")
      local content = f:read("*a")
      f:close()
      os.remove(filepath)
      return json.decode(content), ok
   end

   it("write_json produces a file containing valid JSON with envelope keys", function()
      local results = {
         {
            file = "bench/sort",
            spec = "insertion",
            targets = {
               {
                  name = "v1",
                  median = 0.001,
                  ci_lower = 0.0009,
                  ci_upper = 0.0011,
                  rounds = 100,
                  rank = 1,
                  ratio = 1.0,
               },
            },
         },
      }
      local targets = {
         { name = "v1", original_spec = ".#v1.0.0" },
      }

      local data, ok = write_and_read(results, targets, "0.3.0")

      assert.is_true(ok)
      assert.is_not_nil(data)
      assert.is_not_nil(data.version)
      assert.is_not_nil(data.timestamp)
      assert.is_not_nil(data.targets)
      assert.is_not_nil(data.results)
   end)

   it("write_json envelope contains the provided version string", function()
      local data = write_and_read({}, {}, "1.2.3")

      assert.are_equal("1.2.3", data.version)
   end)

   it("write_json timestamp matches ISO 8601 format", function()
      local data = write_and_read({}, {}, "0.3.0")

      assert.matches("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$", data.timestamp)
   end)

   it("write_json targets array maps target names correctly", function()
      local targets = {
         { name = "v1", original_spec = ".#v1.0.0" },
         { name = "v2", original_spec = ".#v2.0.0" },
      }

      local data = write_and_read({}, targets, "0.3.0")

      assert.are_same({
         { name = "v1", spec = ".#v1.0.0" },
         { name = "v2", spec = ".#v2.0.0" },
      }, data.targets)
   end)

   it("write_json targets array falls back to name when original_spec is absent", function()
      local targets = {
         { name = "mylib", path = "/tmp/mylib" },
      }

      local data = write_and_read({}, targets, "0.3.0")

      assert.are_same({
         { name = "mylib", spec = "mylib" },
      }, data.targets)
   end)

   it("write_json results array is preserved as-is from input", function()
      local results = {
         {
            file = "bench/sort",
            spec = "insertion",
            targets = {
               {
                  name = "v1",
                  median = 0.001,
                  ci_lower = 0.0009,
                  ci_upper = 0.0011,
                  rounds = 100,
                  rank = 1,
                  ratio = 1.0,
               },
               {
                  name = "v2",
                  median = 0.002,
                  ci_lower = 0.0018,
                  ci_upper = 0.0022,
                  rounds = 100,
                  rank = 2,
                  ratio = 2.0,
               },
            },
         },
      }

      local data = write_and_read(results, {}, "0.3.0")

      assert.are_equal(1, #data.results)
      assert.are_equal("bench/sort", data.results[1].file)
      assert.are_equal("insertion", data.results[1].spec)
      assert.are_equal(2, #data.results[1].targets)
      assert.are_equal("v1", data.results[1].targets[1].name)
      assert.are_equal("v2", data.results[1].targets[2].name)
   end)

   it("write_json returns nil and error string when filepath is not writable", function()
      local ok, err = export.write_json("/nonexistent/dir/file.json", {}, {}, "0.3.0")

      assert.is_nil(ok)
      assert.is_string(err)
   end)

   it("write_json produces indented output", function()
      local filepath = os.tmpname()

      export.write_json(filepath, {}, {}, "0.3.0")

      local f = io.open(filepath, "r")
      local content = f:read("*a")
      f:close()
      os.remove(filepath)

      -- Indented JSON contains newlines and leading spaces
      assert.matches("\n ", content)
   end)
end)
