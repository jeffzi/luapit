return {
   fn = function()
      local t = {}
      for i = 1, 100 do
         t[#t + 1] = tostring(i)
      end
      local _ = table.concat(t, ",")
   end,
}
