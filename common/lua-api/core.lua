-- =============================================================
-- MatisuAuto 统一 Lua API 契约（Phase 0 草案 v0.1）
-- 跨端共享脚本 API 表面：PC / iOS / Android 三端共用
-- -------------------------------------------------------------
-- 加载方式：
--   PC      : runner.js (fengari) 加载并覆盖为 JS 实现
--   iOS     : LuaJIT 加载并覆盖为 ObjC 桥接 (ffi / trampoline)
--   Android : LuaJIT / AndroLua 加载并覆盖为 Java 桥接
-- 默认实现仅打印调用日志，便于无设备时验证脚本流程。
-- 宿主引擎在加载本文件后，把具体函数替换为真实实现即可。
-- =============================================================

-- 生成占位桩：打印 [STUB] 模块.函数(参数)，返回 nil
local function _stub(mod, fn)
  return function(...)
    local args, n = {}, select("#", ...)
    for i = 1, n do args[i] = tostring(select(i, ...)) end
    print(string.format("[STUB] %s.%s(%s)", mod, fn, table.concat(args, ", ")))
    return nil
  end
end

-- ---------------- touch 触控 ----------------
touch = {
  tap       = _stub("touch", "tap"),        -- tap(x, y[, delay])
  doubleTap = _stub("touch", "doubleTap"),  -- doubleTap(x, y)
  longPress = _stub("touch", "longPress"),  -- longPress(x, y[, ms])
  swipe     = _stub("touch", "swipe"),      -- swipe(x1,y1,x2,y2[, duration])
  touchDown = _stub("touch", "touchDown"),  -- touchDown(id, x, y)
  touchMove = _stub("touch", "touchMove"),  -- touchMove(id, x, y)
  touchUp   = _stub("touch", "touchUp"),    -- touchUp(id, x, y)
  inputText = _stub("touch", "inputText"),  -- inputText(text)
  key       = _stub("touch", "key"),        -- key(code)
}

-- ---------------- device 设备 ----------------
device = {
  -- 真实端用 usleep / Handler 睡眠；此处为占位，宿主会覆盖
  sleep = function(ms)
    print(string.format("[STUB] device.sleep(%s)", tostring(ms)))
  end,
  getScreenSize  = _stub("device", "getScreenSize"),  -- -> {w, h}
  getOSType      = function() return "unknown" end,   -- "ios" | "android" | "pc"
  getDeviceName  = _stub("device", "getDeviceName"),
  getVersion     = _stub("device", "getVersion"),
  screenshot     = _stub("device", "screenshot"),     -- screenshot(path) -> path
  vibrate        = _stub("device", "vibrate"),
  clipboard      = _stub("device", "clipboard"),      -- clipboard([text])
}

-- ---------------- color 图色 ----------------
color = {
  findColor      = _stub("color", "findColor"),      -- findColor(color, sim[, region]) -> {x,y}|nil
  findColorEx    = _stub("color", "findColorEx"),    -- 多点找色
  findImage      = _stub("color", "findImage"),      -- findImage(imgPath, sim[, region]) -> {x,y}
  findMultiColor = _stub("color", "findMultiColor"),
  ocr            = _stub("color", "ocr"),            -- ocr([region]) -> string
  getColor       = _stub("color", "getColor"),        -- getColor(x,y) -> 0xRRGGBB
}

-- ---------------- node UI 节点 ----------------
node = {
  findNode = _stub("node", "findNode"),   -- findNode(text[, cls]) -> node|nil
  clickNode = _stub("node", "clickNode"), -- clickNode(text)
  getBounds = _stub("node", "getBounds"), -- getBounds(node) -> {x,y,w,h}
  dump      = _stub("node", "dump"),      -- dump() -> tree(string)
  waitNode  = _stub("node", "waitNode"),  -- waitNode(text[, timeout])
}

-- ---------------- ui 交互 ----------------
ui = {
  alert   = _stub("ui", "alert"),    -- alert(msg)
  toast   = _stub("ui", "toast"),    -- toast(msg)
  input   = _stub("ui", "input"),    -- input(prompt) -> string
  confirm = _stub("ui", "confirm"),  -- confirm(msg) -> bool
  show    = _stub("ui", "show"),     -- show(view/html)
}

-- ---------------- network ----------------
network = {
  httpGet  = _stub("network", "httpGet"),   -- httpGet(url) -> body
  httpPost = _stub("network", "httpPost"),  -- httpPost(url, data) -> body
  download = _stub("network", "download"),  -- download(url, path)
}

-- ---------------- cipher 加解密 ----------------
cipher = {
  md5    = _stub("cipher", "md5"),
  sha1   = _stub("cipher", "sha1"),
  base64 = _stub("cipher", "base64"),  -- base64(str[, decode])
  aes    = _stub("cipher", "aes"),     -- aes(data, key, mode)
}

-- ---------------- json ----------------
json = {
  encode = _stub("json", "encode"),  -- encode(table) -> string
  decode = _stub("json", "decode"),  -- decode(string) -> table
}

-- ---------------- console（各端覆盖） ----------------
console = {
  log   = print,
  error = function(...) print("[ERROR]", ...) end,
}

-- 全局简写
log = console.log

print("[MatisuAuto] 统一 API 契约 core.lua 已加载 (Phase 0)")
