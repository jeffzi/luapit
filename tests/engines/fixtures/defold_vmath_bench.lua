return {
   fn = function()
      local v1 = vmath.vector3(1, 2, 3)
      local v2 = vmath.vector3(4, 5, 6)
      for _ = 1, 100 do
         local _ = v1 + v2
      end
   end,
}
