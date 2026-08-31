-- =============================================================
-- MatisuAuto 统一 Lua API 契约（对齐「懒人精灵 高级版 2.0.1」真实文档）
-- 跨端共享脚本 API 表面：PC(fengari) / iOS(LuaJIT+ObjC) / Android(LuaJIT+Java)
-- -------------------------------------------------------------
-- 加载方式：
--   PC      : runner.js (fengari) 加载本文件，再用真实实现覆盖全部全局函数
--   iOS     : LuaJIT 加载本文件，再用 ObjC 桥接覆盖
--   Android : LuaJIT 加载本文件，再用 Java 桥接覆盖
-- 默认实现为占位桩（打印 [STUB] 并返 nil），便于无设备时校验脚本语法/流程。
--
-- 关键约定（来自官方文档，已纠正旧 v1.3 偏差）：
--   1) 触控/图色/设备/应用/系统/交互 一律是【全局函数】（非 color.* / device.* 表）
--   2) 颜色格式为 BBGGRR（蓝绿红），多色用 "|" 分隔，偏色用 "-" 分隔
--   3) 节点是【选择器链式 + 全局工厂函数】，返回一个选择器对象：
--        id/text/desc/className/packageName 各含 eq/Contains/StartsWith/EndsWith/Matches（25）
--        + bounds/boundsInside/drawingOrder/depth/index/布尔属性（16）共 41 个全局工厂
--        选择器对象支持 sel:findOne(timeout)/sel:findAll(timeout)/sel:findOnce(index)
--   4) 节点方法 node:*() 通过冒号调用（node:text()/node:click()/node:bounds()...）
--   5) 模块表：nodeLib.* / imeLib.* / ui.*（动态UI）/ cipher.* / network.* / json.*
-- =============================================================

-- ---------- 占位桩 ----------
local function _stub(name)
  return function(...)
    local n = select("#", ...)
    local a = {}
    for i = 1, n do a[i] = tostring(select(i, ...)) end
    print("[STUB] " .. name .. "(" .. table.concat(a, ", ") .. ")")
    return nil
  end
end

-- ============================================================
-- 一、触控（全局函数）
-- ============================================================
tap          = _stub("tap")
longTap      = _stub("longTap")
swipe        = _stub("swipe")
touchDown    = _stub("touchDown")
touchMove    = _stub("touchMove")
touchMoveEx  = _stub("touchMoveEx")
touchUp      = _stub("touchUp")
inputText    = _stub("inputText")
keyPress     = _stub("keyPress")
keyDown      = _stub("keyDown")
keyUp        = _stub("keyUp")
setOnTouchListener = _stub("setOnTouchListener")

-- ============================================================
-- 二、图色与找图（全局函数，颜色 BBGGRR）
-- ============================================================
-- findColor 多点找色：ret,x,y = findColor(x1,y1,x2,y2,color,dir,sim)
findColor       = _stub("findColor")
findColorT      = _stub("findColorT")
-- findMultiColor 区域多点找色：x,y = findMultiColor(x1,y1,x2,y2,first,offset,dir,sim)
findMultiColor      = _stub("findMultiColor")
findMultiColorT     = _stub("findMultiColorT")
findMultiColorAll   = _stub("findMultiColorAll")
findMultiColorAllT  = _stub("findMultiColorAllT")
-- cmpColor 指定坐标比色：1/0 = cmpColor(x,y,color,sim)
cmpColor       = _stub("cmpColor")
-- cmpColorEx 多点比色：1/0 = cmpColorEx("x|y|color,...", sim)
cmpColorEx     = _stub("cmpColorEx")
cmpColorExT    = _stub("cmpColorExT")
-- getColorNum 区域颜色数量
getColorNum    = _stub("getColorNum")
-- colorDiff 颜色差值之和
colorDiff      = _stub("colorDiff")
-- colorToRGB 真实实现（纯计算，BBGGRR -> r,g,b；Lua 5.1 无位运算，用取模）
function colorToRGB(c)
  local v
  if type(c) == "number" then v = c
  else v = tonumber(tostring(c):gsub("^0x", ""), 16) or 0 end
  v = math.floor(v) % 0x1000000
  local r = v % 256
  local g = math.floor(v / 256) % 256
  local b = math.floor(v / 65536) % 256
  return r, g, b
end
-- getPixelColor 指定坐标颜色：整数(type=1) 或 "BBGGRR" 字符串
getPixelColor  = _stub("getPixelColor")
-- getScreenPixel 区域像素数组：w,h,arr = getScreenPixel(x1,y1,x2,y2)
getScreenPixel = _stub("getScreenPixel")
-- isDisplayDead 区域是否无变化：true/false = isDisplayDead(x1,y1,x2,y2,time)
isDisplayDead  = _stub("isDisplayDead")
-- keepCapture / releaseCapture 截图缓存
keepCapture    = _stub("keepCapture")
releaseCapture = _stub("releaseCapture")
-- setScreenScale 分辨率缩放：setScreenScale(type,w,h,[scale])
setScreenScale = _stub("setScreenScale")
-- snapShot 截图保存：path = snapShot(path,[l,t,r,b])
snapShot       = _stub("snapShot")
-- ocrText OCR：text = ocrText(x1,y1,x2,y2,[lang])
ocrText        = _stub("ocrText")
-- 找图（opencv / 模板匹配 / 快速 / 圆）
findImage      = _stub("findImage")
findPic        = _stub("findPic")
findPicEx      = _stub("findPicEx")
findPicFast    = _stub("findPicFast")
findPicAllPoint= _stub("findPicAllPoint")
findCircle     = _stub("findCircle")

-- ============================================================
-- 三、节点选择器（全局工厂函数 + 选择器对象）
-- ============================================================
local SELECTOR_SPECS = {
  { fn = "id",                k = "id",          m = "eq" },
  { fn = "idContains",        k = "id",          m = "contains" },
  { fn = "idStartsWith",      k = "id",          m = "startsWith" },
  { fn = "idEndsWith",        k = "id",          m = "endsWith" },
  { fn = "idMatches",         k = "id",          m = "matches" },
  { fn = "text",              k = "text",        m = "eq" },
  { fn = "textContains",      k = "text",        m = "contains" },
  { fn = "textStartsWith",    k = "text",        m = "startsWith" },
  { fn = "textEndsWith",      k = "text",        m = "endsWith" },
  { fn = "textMatches",       k = "text",        m = "matches" },
  { fn = "desc",              k = "desc",        m = "eq" },
  { fn = "descContains",      k = "desc",        m = "contains" },
  { fn = "descStartsWith",    k = "desc",        m = "startsWith" },
  { fn = "descEndsWith",      k = "desc",        m = "endsWith" },
  { fn = "descMatches",       k = "desc",        m = "matches" },
  { fn = "className",         k = "className",   m = "eq" },
  { fn = "classNameContains",  k = "className",   m = "contains" },
  { fn = "classNameStartsWith",k = "className",   m = "startsWith" },
  { fn = "classNameEndsWith",  k = "className",   m = "endsWith" },
  { fn = "classNameMatches",   k = "className",   m = "matches" },
  { fn = "packageName",        k = "packageName", m = "eq" },
  { fn = "packageNameContains",k = "packageName", m = "contains" },
  { fn = "packageNameStartsWith",k = "packageName",m = "startsWith" },
  { fn = "packageNameEndsWith",k = "packageName", m = "endsWith" },
  { fn = "packageNameMatches", k = "packageName", m = "matches" },
  { fn = "bounds",             k = "bounds",      m = nil },
  { fn = "boundsInside",       k = "boundsInside",m = nil },
  { fn = "drawingOrder",       k = "drawingOrder",m = nil },
  { fn = "depth",              k = "depth",       m = nil },
  { fn = "index",              k = "index",       m = nil },
  { fn = "visibleToUser",      k = "visibleToUser",m = nil },
  { fn = "selected",           k = "selected",    m = nil },
  { fn = "clickable",          k = "clickable",   m = nil },
  { fn = "longClickable",      k = "longClickable",m = nil },
  { fn = "enabled",            k = "enabled",     m = nil },
  { fn = "password",           k = "password",    m = nil },
  { fn = "scrollable",         k = "scrollable",  m = nil },
  { fn = "checked",            k = "checked",     m = nil },
  { fn = "checkable",          k = "checkable",   m = nil },
  { fn = "focusable",          k = "focusable",   m = nil },
  { fn = "focused",            k = "focused",     m = nil },
}

local Node = {}
Node.__index = Node
-- 节点方法（冒号调用）：参考模式下只返回 nil，真机由宿主桥接覆盖
Node.text            = function(self) return nil end
Node.id              = function(self) return nil end
Node.desc            = function(self) return nil end
Node.className       = function(self) return nil end
Node.packageName     = function(self) return nil end
Node.bounds          = function(self) return 0, 0, 0, 0 end
Node.boundsInParent  = function(self) return 0, 0, 0, 0 end
Node.childCount      = function(self) return 0 end
Node.childs          = function(self) return {} end
Node.parent          = function(self) return nil end
Node.drawingOrder    = function(self) return 0 end
Node.depth           = function(self) return 0 end
Node.toJson          = function(self) return "{}" end
Node.setText         = function(self, s) return false end
Node.scrollTo        = function(self, r, c) return false end
Node.scrollUp        = function(self) return false end
Node.scrollDown      = function(self) return false end
Node.scrollLeft      = function(self) return false end
Node.scrollRight     = function(self) return false end
Node.scrollForward   = function(self) return false end
Node.scrollBackward  = function(self) return false end
Node.click           = function(self) return false end
Node.longClick       = function(self) return false end
Node.focus           = function(self) return false end
Node.clearFocus      = function(self) return false end
Node.copy            = function(self) return false end
Node.paste           = function(self) return false end
Node.cut             = function(self) return false end
Node.select          = function(self) return false end
Node.setSelection    = function(self, a, b) return false end
Node.setProgress     = function(self, p) return false end
Node.collapse        = function(self) return false end
Node.expand          = function(self) return false end
Node.contextClick    = function(self) return false end

local function newSelector()
  local s = { _preds = {} }
  local mt = { __index = {} }
  for _, spec in ipairs(SELECTOR_SPECS) do
    mt.__index[spec.fn] = function(self, v)
      table.insert(self._preds, { k = spec.k, m = spec.m, v = v })
      return self
    end
  end
  mt.__index.findOne    = function(self, timeout) return nil end
  mt.__index.findAll    = function(self, timeout) return {} end
  mt.__index.findOnce   = function(self, index) return nil end
  setmetatable(s, mt)
  return s
end

local function selStarter(spec)
  return function(v)
    local s = newSelector()
    table.insert(s._preds, { k = spec.k, m = spec.m, v = v })
    return s
  end
end

for _, spec in ipairs(SELECTOR_SPECS) do
  _G[spec.fn] = selStarter(spec)
end

-- 节点对象工厂（参考模式，find* 返回 nil 时不用）
function _newNode()
  return setmetatable({}, Node)
end

-- ============================================================
-- 四、设备信息（全局函数）
-- ============================================================
getCpuArch       = _stub("getCpuArch")
getSdPath        = _stub("getSdPath")
getDisplayDpi    = _stub("getDisplayDpi")
getBatteryLevel  = _stub("getBatteryLevel")
getDeviceId      = _stub("getDeviceId")
getBrand         = _stub("getBrand")
getBootLoader    = _stub("getBootLoader")
getBoard         = _stub("getBoard")
getManufacturer  = _stub("getManufacturer")
getProduct       = _stub("getProduct")
getDevice        = _stub("getDevice")
getModel         = _stub("getModel")
getHardware      = _stub("getHardware")
getId            = _stub("getId")
getFingerprint   = _stub("getFingerprint")
getCpuAbi        = _stub("getCpuAbi")
getCpuAbi2       = _stub("getCpuAbi2")
getSdkVersion    = _stub("getSdkVersion")
getOsVersionName = _stub("getOsVersionName")
getWifiMac       = _stub("getWifiMac")
getDisplayInfo   = _stub("getDisplayInfo")
getDisplaySize   = _stub("getDisplaySize")
getDisplayRotate = _stub("getDisplayRotate")
getPackageName   = _stub("getPackageName")
getSubscriberId  = _stub("getSubscriberId")
getSimSerialNumber = _stub("getSimSerialNumber")

-- ============================================================
-- 五、应用管理（全局函数）
-- ============================================================
runApp            = _stub("runApp")
stopApp           = _stub("stopApp")
getInstalledApk   = _stub("getInstalledApk")
getInstalledApps  = _stub("getInstalledApps")
installApk        = _stub("installApk")
getCurrentActivity = _stub("getCurrentActivity")
frontAppName      = _stub("frontAppName")
appIsFront        = _stub("appIsFront")
appIsRunning      = _stub("appIsRunning")
readPasteboard    = _stub("readPasteboard")
writePasteboard   = _stub("writePasteboard")
scanImage         = _stub("scanImage")
sendSms           = _stub("sendSms")
phoneCall         = _stub("phoneCall")
runIntent         = _stub("runIntent")

-- ============================================================
-- 六、系统控制（全局函数）
-- ============================================================
setControlBarPosNew = _stub("setControlBarPosNew")
showControlBar      = _stub("showControlBar")
restartScript       = _stub("restartScript")
vibrate             = _stub("vibrate")
playAudio           = _stub("playAudio")
stopAudio           = _stub("stopAudio")
rnd                 = _stub("rnd")
exec                = _stub("exec")
sleep               = _stub("sleep")
mSleep              = _stub("mSleep")
lockScreen          = _stub("lockScreen")
unLockScreen        = _stub("unLockScreen")
setBTEnable         = _stub("setBTEnable")
setWifiEnable       = _stub("setWifiEnable")
setAirplaneMode     = _stub("setAirplaneMode")
getRunEnvType       = _stub("getRunEnvType")
exitScript          = _stub("exitScript")

-- ============================================================
-- 七、交互（全局函数 + ui 动态UI 模块表）
-- ============================================================
toast      = _stub("toast")
hideToast  = _stub("hideToast")
showUI     = _stub("showUI")
showUIEx   = _stub("showUIEx")
createHUD  = _stub("createHUD")
showHUD    = _stub("showHUD")
hideHUD    = _stub("hideHUD")

ui = {
  newLayout   = _stub("ui.newLayout"),
  addButton   = _stub("ui.addButton"),
  addEditText = _stub("ui.addEditText"),
  addTextView = _stub("ui.addTextView"),
  addCheckBox = _stub("ui.addCheckBox"),
  addRadioBox = _stub("ui.addRadioBox"),
  addComboBox = _stub("ui.addComboBox"),
  setOnClick  = _stub("ui.setOnClick"),
  show        = _stub("ui.show"),
}

-- ============================================================
-- 八、节点库 / 输入法 模块表
-- ============================================================
nodeLib = {
  getNodeXml         = _stub("nodeLib.getNodeXml"),
  saveNode           = _stub("nodeLib.saveNode"),
  saveNodeNew        = _stub("nodeLib.saveNodeNew"),
  lockNode           = _stub("nodeLib.lockNode"),
  unlockNode         = _stub("nodeLib.unlockNode"),
  openAccessibility  = _stub("nodeLib.openAccessibility"),
  closeAccessibility = _stub("nodeLib.closeAccessibility"),
}

imeLib = {
  lock        = _stub("imeLib.lock"),
  unlock      = _stub("imeLib.unlock"),
  setText     = _stub("imeLib.setText"),
  deleteChar  = _stub("imeLib.deleteChar"),
  finishInput = _stub("imeLib.finishInput"),
  keyEvent    = _stub("imeLib.keyEvent"),
}

-- ============================================================
-- 九、加解密 / 网络 / JSON 模块表（标准扩展库）
-- ============================================================
cipher = {
  md5    = _stub("cipher.md5"),
  sha1   = _stub("cipher.sha1"),
  base64 = _stub("cipher.base64"),
  aes    = _stub("cipher.aes"),
}

network = {
  httpGet  = _stub("network.httpGet"),
  httpPost = _stub("network.httpPost"),
  download = _stub("network.download"),
}

json = {
  encode = _stub("json.encode"),
  decode = _stub("json.decode"),
}

-- ============================================================
-- 十、控制台
-- ============================================================
console = { log = print, error = function(...) print("[ERROR]", ...) end }
log = console.log

print("[MatisuAuto] 统一 API 契约 core.lua 已加载 (对齐 懒人精灵 高级版 2.0.1 真实文档)")
