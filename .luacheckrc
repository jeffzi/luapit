std = "min"
include_files = { "src", "tests" }
exclude_files = { "tests/fixtures/syntax_error_bench.lua", "tests/engines/*.sh" }
globals = {
   "_G",
   "jit", -- LuaJIT
   "warn", -- Lua 5.4+
}
max_comment_line_length = 200

files["tests/**/*.lua"] = {
   std = "+busted",
}

files["tests/*_test.lua"] = {
   ignore = { "122" }, -- setting read-only field (io.stderr capture in tests)
}

files["tests/engines/fixtures/love2d_math_bench.lua"] = {
   globals = { "love" },
}

files["tests/engines/fixtures/defold_vmath_bench.lua"] = {
   globals = { "vmath" },
}
