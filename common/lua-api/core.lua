-- =============================================================
-- MatisuAuto 统一 Lua API 契约（对齐「懒人精灵 高级版 2.0.1」真实文档）
-- 跨端共享脚本 API 表面：PC(fengari) / iOS(LuaJIT+ObjC) / Android(LuaJ)
-- -------------------------------------------------------------
-- 加载方式：
--   PC      : runner.js (fengari) 加载本文件，再用真实实现覆盖全部全局函数
--   iOS     : 设备端 LuaEngine.mm 原生注册同名函数（本文件仅作契约/清单）
--   Android : 设备端 LuaEngine.kt 原生注册同名函数（本文件仅作契约/清单）
-- 默认实现为占位桩（打印 [STUB] 并返 nil），便于无设备时校验脚本语法/流程。
--
-- 每个函数上方紧邻的 `-- 函数名 中文描述` 注释行是 IDE「函数查询」面板的
-- 描述数据源（pc/ide/server.js /api/apis 解析），修改函数名时同步注释。
--
-- 关键约定（来自官方文档，已纠正旧 v1.3 偏差）：
--   1) 触控/图色/设备/应用/系统/交互 一律是【全局函数】（非 color.* / device.* 表）
--   2) 颜色格式为 BBGGRR（蓝绿红），多色用 "|" 分隔，偏色用 "-" 分隔
--   3) 节点是【选择器链式 + 全局工厂函数】（两端设备端暂未实现，保留契约）
--   4) 模块表：strutils / nodeLib / imeLib / ui（动态UI）/ cipher / network / jsonLib|json
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
-- 一、触控按键（全局函数）
-- ============================================================
-- tap 点击屏幕坐标
tap          = _stub("tap")
-- longTap 长按屏幕坐标（秒）
longTap      = _stub("longTap")
-- swipe 从起点滑动到终点（秒）
swipe        = _stub("swipe")
-- touchDown 按下触点
touchDown    = _stub("touchDown")
-- touchMove 移动触点
touchMove    = _stub("touchMove")
-- touchUp 抬起触点
touchUp      = _stub("touchUp")
-- keyPress 按物理按键名
keyPress     = _stub("keyPress")
-- keyDown 按下按键（组合键）
keyDown      = _stub("keyDown")
-- keyUp 抬起按键（组合键）
keyUp        = _stub("keyUp")
-- inputText 输入文本
inputText    = _stub("inputText")

-- ============================================================
-- 二、图色与找色（全局函数，颜色 BBGGRR）
-- ============================================================
-- findColor 区域找色，返回 x,y
findColor       = _stub("findColor")
-- findColorT 区域找色（table 打包参数）
findColorT      = _stub("findColorT")
-- findMultiColor 区域多点找色，返回 x,y
findMultiColor      = _stub("findMultiColor")
-- findMultiColorT 区域多点找色（table 打包参数）
findMultiColorT     = _stub("findMultiColorT")
-- findMultiColorAll 区域多点找色返回所有命中点
findMultiColorAll   = _stub("findMultiColorAll")
-- findMultiColorAllT 区域多点找色返回所有命中点（table 参数）
findMultiColorAllT  = _stub("findMultiColorAllT")
-- cmpColor 指定坐标比色：1/0 = cmpColor(x,y,color,sim)
cmpColor       = _stub("cmpColor")
-- cmpColorEx 多点比色：1/0 = cmpColorEx("x|y|color,...", sim)
cmpColorEx     = _stub("cmpColorEx")
-- cmpColorExT 多点比色（table 打包参数）
cmpColorExT    = _stub("cmpColorExT")
-- getColorNum 区域颜色数量
getColorNum    = _stub("getColorNum")
-- colorDiff 两个颜色差值之和
colorDiff      = _stub("colorDiff")
-- colorToRGB 颜色值拆解为 r,g,b 三分量（BBGGRR）
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
-- isDisplayDead 区域画面是否无变化：true/false = isDisplayDead(x1,y1,x2,y2,time)
isDisplayDead  = _stub("isDisplayDead")
-- keepCapture 保持截图缓存（设备端天然满足）
keepCapture    = _stub("keepCapture")
-- releaseCapture 释放截图缓存
releaseCapture = _stub("releaseCapture")
-- setScreenScale 设置分辨率缩放
setScreenScale = _stub("setScreenScale")
-- snapShot 截图保存：path = snapShot(path,[l,t,r,b])
snapShot       = _stub("snapShot")

-- ============================================================
-- 三、找图（全局函数，opencv / 模板匹配 / 快速 / 圆）
-- ============================================================
-- findImage 区域找图（findPic 别名）
findImage      = _stub("findImage")
-- findPic 区域找图，返回 x,y
findPic        = _stub("findPic")
-- findPicEx 区域找图（扩展变体）
findPicEx      = _stub("findPicEx")
-- findPicFast 快速找图
findPicFast    = _stub("findPicFast")
-- findPicAllPoint 找图返回所有命中坐标表
findPicAllPoint= _stub("findPicAllPoint")
-- findCircle 区域找圆，返回 圆心x,圆心y,半径
findCircle     = _stub("findCircle")

-- ============================================================
-- 四、OCR 文字识别（全局函数）
-- ============================================================
-- ocrText 识别区域文字（换行分隔），区域 0,0,0,0 = 全屏
ocrText        = _stub("ocrText")
-- ocrTextEx 识别区域文字并返回明细表 {text=,x=,y=,w=,h=,score=}
ocrTextEx      = _stub("ocrTextEx")
-- findStr 在区域内查找文字，命中返回中心坐标 x,y
findStr        = _stub("findStr")

-- ============================================================
-- 五、节点选择器（全局工厂函数 + 选择器对象，两端设备端暂未实现）
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
-- 六、字符串处理（strutils 模块表，两端同源 Lua 实现）
-- ============================================================
strutils = {
  -- strutils.bin2Hex 二进制字符串转 16/10 进制显示
  bin2Hex    = _stub("strutils.bin2Hex"),
  -- strutils.split 字符串分割
  split      = _stub("strutils.split"),
  -- strutils.trim 字符串修剪
  trim       = _stub("strutils.trim"),
  -- strutils.replace 字符串替换
  replace    = _stub("strutils.replace"),
  -- strutils.startswith 检查字符串前缀
  startswith = _stub("strutils.startswith"),
  -- strutils.endswith 检查字符串后缀
  endswith   = _stub("strutils.endswith"),
  -- strutils.upper 转换为大写
  upper      = _stub("strutils.upper"),
  -- strutils.lower 转换为小写
  lower      = _stub("strutils.lower"),
}

-- ============================================================
-- 七、设备信息（全局函数）
-- ============================================================
-- getCpuArch 获取 CPU 架构
getCpuArch       = _stub("getCpuArch")
-- getDisplayDpi 获取屏幕 DPI
getDisplayDpi    = _stub("getDisplayDpi")
-- getBatteryLevel 获取电池电量百分比
getBatteryLevel  = _stub("getBatteryLevel")
-- getDeviceId 获取设备唯一标识
getDeviceId      = _stub("getDeviceId")
-- getModel 获取设备型号
getModel         = _stub("getModel")
-- getDeviceName 获取设备名称
getDeviceName    = _stub("getDeviceName")
-- getSysVer 获取系统版本号
getSysVer        = _stub("getSysVer")
-- getOsVersionName 获取系统版本名称
getOsVersionName = _stub("getOsVersionName")
-- isCharging 是否正在充电
isCharging       = _stub("isCharging")
-- getScreenDirection 获取屏幕方向
getScreenDirection = _stub("getScreenDirection")
-- getSysLang 获取系统语言
getSysLang       = _stub("getSysLang")
-- getSysTimezone 获取系统时区
getSysTimezone   = _stub("getSysTimezone")
-- getDeviceType 获取设备类型（iphone/ipad）
getDeviceType    = _stub("getDeviceType")
-- getEngineVersion 获取引擎版本号
getEngineVersion = _stub("getEngineVersion")
-- getScreenFrame 获取屏幕安全区边框 x,y,w,h
getScreenFrame   = _stub("getScreenFrame")
-- getScreenResolution 获取屏幕物理分辨率 w,h
getScreenResolution = _stub("getScreenResolution")
-- getDisplaySize 获取屏幕逻辑分辨率 w,h
getDisplaySize   = _stub("getDisplaySize")
-- frontAppName 获取前台应用包名
frontAppName     = _stub("frontAppName")

-- ============================================================
-- 八、应用管理（全局函数）
-- ============================================================
-- runApp 启动应用
runApp            = _stub("runApp")
-- stopApp 停止应用进程
stopApp           = _stub("stopApp")
-- appIsRunning 应用是否在运行
appIsRunning      = _stub("appIsRunning")
-- openUrl 打开 URL 链接
openUrl           = _stub("openUrl")
-- readPasteboard 读取剪贴板文本
readPasteboard    = _stub("readPasteboard")
-- writePasteboard 写入剪贴板文本
writePasteboard   = _stub("writePasteboard")

-- ============================================================
-- 九、系统控制（全局函数）
-- ============================================================
-- sleep 秒级休眠（可被停止中断）
sleep               = _stub("sleep")
-- mSleep 毫秒级休眠（可被停止中断）
mSleep              = _stub("mSleep")
-- rnd 返回整数区间随机数
rnd                 = _stub("rnd")
-- vibrate 设备振动
vibrate             = _stub("vibrate")
-- restartScript 重启当前脚本
restartScript       = _stub("restartScript")
-- exitScript 退出/终止脚本
exitScript          = _stub("exitScript")
-- setStopCallBack 注册脚本停止回调
setStopCallBack     = _stub("setStopCallBack")
-- lockScreen 锁屏
lockScreen          = _stub("lockScreen")
-- unLockScreen 解锁屏幕
unLockScreen        = _stub("unLockScreen")

-- ============================================================
-- 九.五、动态 UI（showUI：WebView 参数配置面板）
-- ============================================================
-- showUI 弹出参数配置界面（JSON 字符串或 table），确认返回 1,值1,值2...，取消返回 0
showUI              = _stub("showUI")
-- closeWindow 关闭 UI 窗口（无回调模式下自动关闭，保留兼容）
closeWindow         = _stub("closeWindow")

-- ============================================================
-- 十、日志控制台（全局函数）
-- ============================================================
-- logPrint 打印日志（INFO 级）
logPrint   = _stub("logPrint")
-- logDebug 打印 DEBUG 级日志
logDebug   = _stub("logDebug")
-- logInfo 打印 INFO 级日志
logInfo    = _stub("logInfo")
-- logWarn 打印 WARN 级日志
logWarn    = _stub("logWarn")
-- logError 打印 ERROR 级日志
logError   = _stub("logError")
-- vvLog 打印 TRACE 级日志
vvLog      = _stub("vvLog")
-- clearCLog 清空控制台日志
clearCLog  = _stub("clearCLog")

-- ============================================================
-- 十一、网络请求（network 模块表 + 全局别名）
-- ============================================================
-- network.httpGet HTTP GET 请求
network = {
  httpGet  = _stub("network.httpGet"),
  -- network.httpPost HTTP POST 请求
  httpPost = _stub("network.httpPost"),
  -- network.download 下载文件到本地
  download = _stub("network.download"),
}
-- httpGet HTTP GET 请求（network.httpGet 全局别名）
httpGet     = _stub("httpGet")
-- httpPost HTTP POST 请求（network.httpPost 全局别名）
httpPost    = _stub("httpPost")
-- downloadFile 下载文件（network.download 全局别名）
downloadFile = _stub("downloadFile")

-- ============================================================
-- 十二、加解密与编码（cipher 模块表 + 全局别名）
-- ============================================================
-- cipher.md5 计算 MD5
cipher = {
  md5    = _stub("cipher.md5"),
  -- cipher.sha1 计算 SHA1
  sha1   = _stub("cipher.sha1"),
  -- cipher.base64 Base64 编码/解码
  base64 = _stub("cipher.base64"),
}
-- MD5 计算 MD5（全局别名）
MD5          = _stub("MD5")
-- sha1 计算 SHA1（全局别名）
sha1         = _stub("sha1")
-- encodeBase64 Base64 编码（全局别名）
encodeBase64 = _stub("encodeBase64")
-- decodeBase64 Base64 解码（全局别名）
decodeBase64 = _stub("decodeBase64")

-- ============================================================
-- 十三、JSON（jsonLib / json 别名表）
-- ============================================================
-- json.encode 表编码为 JSON 字符串
jsonLib = {
  encode = _stub("jsonLib.encode"),
  -- json.decode JSON 字符串解码为表
  decode = _stub("jsonLib.decode"),
}
json = jsonLib

-- ============================================================
-- 十四、控制台
-- ============================================================
console = { log = print, error = function(...) print("[ERROR]", ...) end }
log = console.log

print("[MatisuAuto] 统一 API 契约 core.lua 已加载 (对齐 懒人精灵 高级版 2.0.1 真实文档)")
