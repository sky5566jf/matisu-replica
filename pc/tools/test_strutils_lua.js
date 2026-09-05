// strutils Lua 片段行为验证（fengari，与两端嵌入源码逐字一致）
const fengari = require('fengari');
const lua = fengari.lua, lauxlib = fengari.lauxlib, lualib = fengari.lualib;
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const SRC = `
strutils = {}
function strutils.bin2Hex(data, ishex)
  data = tostring(data or "")
  local parts = {}
  for i = 1, #data do
    local b = string.byte(data, i)
    if ishex then parts[i] = string.format("%02x", b)
    else parts[i] = tostring(b) end
  end
  return table.concat(parts, ishex and "" or " ")
end
function strutils.split(str, delimiter, limit)
  str = tostring(str or "")
  delimiter = delimiter == nil and " " or tostring(delimiter)
  limit = tonumber(limit) or 0
  local out = {}
  if delimiter == "" then
    for i = 1, #str do out[i] = string.sub(str, i, i) end
    return out
  end
  local pos = 1
  while true do
    if limit > 0 and #out >= limit then break end
    local s, e = string.find(str, delimiter, pos, true)
    if not s then break end
    out[#out + 1] = string.sub(str, pos, s - 1)
    pos = e + 1
  end
  out[#out + 1] = string.sub(str, pos)
  return out
end
function strutils.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
function strutils.replace(s, a, b)
  s = tostring(s or ""); a = tostring(a or ""); b = tostring(b or "")
  if a == "" then return s end
  local out, pos = {}, 1
  while true do
    local i, j = string.find(s, a, pos, true)
    if not i then break end
    out[#out + 1] = string.sub(s, pos, i - 1) .. b
    pos = j + 1
  end
  out[#out + 1] = string.sub(s, pos)
  return table.concat(out)
end
function strutils.startswith(s, p)
  s = tostring(s or ""); p = tostring(p or "")
  return string.sub(s, 1, #p) == p
end
function strutils.endswith(s, p)
  s = tostring(s or ""); p = tostring(p or "")
  if p == "" then return true end
  return string.sub(s, -#p) == p
end
function strutils.upper(s) return string.upper(tostring(s or "")) end
function strutils.lower(s) return string.lower(tostring(s or "")) end
`;

const TESTS = `
local out = {}
local ok, err = pcall(function()
  assert(strutils.bin2Hex("hello", true) == "68656c6c6f", "bin2Hex hex")
  assert(strutils.bin2Hex("AB", false) == "65 66", "bin2Hex dec")
  local w = strutils.split("a,b,c", ",")
  assert(w[1] == "a" and w[2] == "b" and w[3] == "c" and #w == 3, "split csv")
  local p = strutils.split("usr/local/bin", "/", 2)
  assert(p[1] == "usr" and p[2] == "local" and p[3] == "bin" and #p == 3, "split limit")
  local sp = strutils.split("hello world")
  assert(sp[1] == "hello" and sp[2] == "world", "split default")
  assert(strutils.trim("  x y  ") == "x y", "trim")
  assert(strutils.replace("a-b-c", "-", "+") == "a+b+c", "replace")
  assert(strutils.replace("abc", "", "z") == "abc", "replace empty pattern")
  assert(strutils.startswith("hello", "he") == true, "startswith true")
  assert(strutils.startswith("hello", "he!") == false, "startswith false")
  assert(strutils.endswith("hello", "lo") == true, "endswith true")
  assert(strutils.endswith("hello", "") == true, "endswith empty")
  assert(strutils.upper("aB1") == "AB1", "upper")
  assert(strutils.lower("aB1") == "ab1", "lower")
end)
if not ok then print("FAIL " .. tostring(err)) else print("PASS") end
`;

let rc = 0;
if (lauxlib.luaL_dostring(L, fengari.to_luastring(SRC)) !== 0) {
  console.error('CHUNK LOAD FAIL:', fengari.to_jsstring(lua.lua_tostring(L, -1)));
  rc = 1;
} else if (lauxlib.luaL_dostring(L, fengari.to_luastring(TESTS)) !== 0) {
  console.error('TEST FAIL:', fengari.to_jsstring(lua.lua_tostring(L, -1)));
  rc = 1;
} else {
  const s = lua.lua_tostring(L, -1);
  console.log(s ? fengari.to_jsstring(s) : '(test chunk printed PASS)');
}
process.exit(rc);
