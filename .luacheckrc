-- Luacheck configuration for KOReader Bookshelf Hybrid plugin (Lua 5.1 / LuaJIT)
std = "luajit"
max_line_length = false

read_globals = {
    "G_reader_settings",
}

-- Ignore unused loop/callback placeholders prefixed with _
unused_args = true
ignore = {
    "212/_.*", -- unused argument starting with _
    "213/_.*", -- unused loop variable starting with _
}
