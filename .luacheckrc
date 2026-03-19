std = "min"
include_files = { "src", "tests" }
globals = {
   "_G",
   "jit", -- LuaJIT
   "warn", -- Lua 5.4+
}
max_comment_line_length = 200

files["tests/**/*.lua"] = {
   std = "+busted",
}
