local chronos = require("chronos")
require("terminal")

describe("progress", function()
   local Progress

   before_each(function()
      Progress = require("luabench.progress")
   end)

   it("new requires total option", function()
      assert.has_error(function()
         Progress({})
      end, "progress.new: 'total' is required")
   end)

   it("_format returns string containing bar, position, and total", function()
      local bar = Progress({ total = 10, disable = true })
      bar.pos = 5

      local formatted = bar:_format()

      assert.is_string(formatted)
      assert.matches("%d+/%d+", formatted)
      assert.matches("5", formatted)
      assert.matches("10", formatted)
   end)

   it("_format with custom template includes msg placeholder value", function()
      local bar = Progress({ total = 10, disable = true, template = "{msg} {pos}/{len}" })
      bar.pos = 3
      bar.msg = "hello"

      local formatted = bar:_format()

      assert.matches("hello", formatted)
      assert.matches("3", formatted)
   end)

   it("_compute_eta returns ? when pos is 0", function()
      local bar = Progress({ total = 10, disable = true })
      bar.pos = 0
      bar.start_time = nil

      local formatted = bar:_format("{eta}")

      assert.are_equal("?", formatted)
   end)

   it("_compute_eta returns 0s when pos >= total", function()
      local bar = Progress({ total = 10, disable = true })
      bar.pos = 10

      local formatted = bar:_format("{eta}")

      assert.are_equal("0s", formatted)
   end)

   it("_compute_eta returns formatted duration for partial progress", function()
      local bar = Progress({ total = 10, disable = true })
      bar.pos = 5
      bar.start_time = chronos.nanotime() - 10

      local formatted = bar:_format("{eta}")

      -- With 5/10 done in 10s, ETA should be ~10s
      assert.matches("%d+s", formatted)
   end)

   for _, case in ipairs({
      { elapsed = 45, pattern = "%d+s", desc = "seconds" },
      { elapsed = 120, pattern = "%d+%.%d+m", desc = "minutes" },
      { elapsed = 7200, pattern = "%d+%.%d+h", desc = "hours" },
   }) do
      it("_format_duration formats " .. case.desc .. " correctly", function()
         local bar = Progress({ total = 100, disable = true })
         bar.start_time = chronos.nanotime() - case.elapsed
         bar.pos = 100

         local formatted = bar:_format("{elapsed}")

         assert.matches(case.pattern, formatted)
      end)
   end

   it("_format_bar produces bar with filled and empty segments", function()
      local bar = Progress({ total = 10, width = 12, disable = true })
      bar.pos = 5

      local formatted = bar:_format("{bar}")

      -- width=12 means inner_width=10, at 50% = 5 filled + 5 empty
      assert.matches("^%[", formatted)
      assert.matches("%]$", formatted)
      assert.are_equal(12, #formatted) -- brackets + 10 inner chars
   end)

   it("when disable is true, start update stop suspend resume are no-ops", function()
      local bar = Progress({ total = 10, disable = true })

      assert.has_no_error(function()
         bar:start()
         bar:update(1, "test")
         bar:suspend()
         bar:resume()
         bar:stop()
      end)
   end)
end)
