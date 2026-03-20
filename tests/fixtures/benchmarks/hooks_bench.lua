local m = require("mylib")
return {
   fn = function(ctx)
      m.value()
      return ctx
   end,
   before = function()
      return { ready = true }
   end,
   after = function() end,
   baseline = true,
}
