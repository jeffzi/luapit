local m = require("mylib")
local specs = {
   common = { fn = function() end },
}
if m.value() == 2 then
   specs.v2_only = { fn = function() end }
end
return specs
