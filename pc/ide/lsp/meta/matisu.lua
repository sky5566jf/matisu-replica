---@meta
-- MatisuAuto 统一 Lua API 注解（由 gen_api_meta.py 从 core.lua 自动生成，勿手改）
-- 对齐「懒人精灵 高级版 2.0.1」契约；供 lua-language-server workspace.library 使用

function tap(...) end

function longTap(...) end

function swipe(...) end

function touchDown(...) end

function touchMove(...) end

function touchMoveEx(...) end

function touchUp(...) end

function inputText(...) end

function keyPress(...) end

function keyDown(...) end

function keyUp(...) end

function setOnTouchListener(...) end

---findColor 多点找色：ret,x,y = findColor(x1,y1,x2,y2,color,dir,sim)
---@param x1 any
---@param y1 any
---@param x2 any
---@param y2 any
---@param color any
---@param dir any
---@param sim any
function findColor(x1, y1, x2, y2, color, dir, sim) end

function findColorT(...) end

---findMultiColor 区域多点找色：x,y = findMultiColor(x1,y1,x2,y2,first,offset,dir,sim)
---@param x1 any
---@param y1 any
---@param x2 any
---@param y2 any
---@param first any
---@param offset any
---@param dir any
---@param sim any
function findMultiColor(x1, y1, x2, y2, first, offset, dir, sim) end

function findMultiColorT(...) end

function findMultiColorAll(...) end

function findMultiColorAllT(...) end

---cmpColor 指定坐标比色：1/0 = cmpColor(x,y,color,sim)
---@param x any
---@param y any
---@param color any
---@param sim any
function cmpColor(x, y, color, sim) end

---cmpColorEx 多点比色：1/0 = cmpColorEx("x|y|color,...", sim)
function cmpColorEx(...) end

function cmpColorExT(...) end

---getColorNum 区域颜色数量
function getColorNum(...) end

---colorDiff 颜色差值之和
function colorDiff(...) end

---colorToRGB 真实实现（纯计算，BBGGRR -> r,g,b
---Lua 5.1 无位运算，用取模）
---@param c any
function colorToRGB(c) end

---getPixelColor 指定坐标颜色：整数(type=1) 或 "BBGGRR" 字符串
function getPixelColor(...) end

---getScreenPixel 区域像素数组：w,h,arr = getScreenPixel(x1,y1,x2,y2)
---@param x1 any
---@param y1 any
---@param x2 any
---@param y2 any
function getScreenPixel(x1, y1, x2, y2) end

---isDisplayDead 区域是否无变化：true/false = isDisplayDead(x1,y1,x2,y2,time)
---@param x1 any
---@param y1 any
---@param x2 any
---@param y2 any
---@param time any
function isDisplayDead(x1, y1, x2, y2, time) end

---keepCapture / releaseCapture 截图缓存
function keepCapture(...) end

function releaseCapture(...) end

---setScreenScale 分辨率缩放：setScreenScale(type,w,h,[scale])
function setScreenScale(...) end

---snapShot 截图保存：path = snapShot(path,[l,t,r,b])
function snapShot(...) end

---ocrText OCR：text = ocrText(x1,y1,x2,y2,[lang])
function ocrText(...) end

---找图（opencv / 模板匹配 / 快速 / 圆）
function findImage(...) end

function findPic(...) end

function findPicEx(...) end

function findPicFast(...) end

function findPicAllPoint(...) end

function findCircle(...) end

---节点对象工厂（参考模式，find* 返回 nil 时不用）
function _newNode(...) end

function getCpuArch(...) end

function getSdPath(...) end

function getDisplayDpi(...) end

function getBatteryLevel(...) end

function getDeviceId(...) end

function getBrand(...) end

function getBootLoader(...) end

function getBoard(...) end

function getManufacturer(...) end

function getProduct(...) end

function getDevice(...) end

function getModel(...) end

function getHardware(...) end

function getId(...) end

function getFingerprint(...) end

function getCpuAbi(...) end

function getCpuAbi2(...) end

function getSdkVersion(...) end

function getOsVersionName(...) end

function getWifiMac(...) end

function getDisplayInfo(...) end

function getDisplaySize(...) end

function getDisplayRotate(...) end

function getPackageName(...) end

function getSubscriberId(...) end

function getSimSerialNumber(...) end

function runApp(...) end

function stopApp(...) end

function getInstalledApk(...) end

function getInstalledApps(...) end

function installApk(...) end

function getCurrentActivity(...) end

function frontAppName(...) end

function appIsFront(...) end

function appIsRunning(...) end

function readPasteboard(...) end

function writePasteboard(...) end

function scanImage(...) end

function sendSms(...) end

function phoneCall(...) end

function runIntent(...) end

function setControlBarPosNew(...) end

function showControlBar(...) end

function restartScript(...) end

function vibrate(...) end

function playAudio(...) end

function stopAudio(...) end

function rnd(...) end

function exec(...) end

function sleep(...) end

function mSleep(...) end

function lockScreen(...) end

function unLockScreen(...) end

function setBTEnable(...) end

function setWifiEnable(...) end

function setAirplaneMode(...) end

function getRunEnvType(...) end

function exitScript(...) end

function toast(...) end

function hideToast(...) end

function showUI(...) end

function showUIEx(...) end

function createHUD(...) end

function showHUD(...) end

function hideHUD(...) end

ui = {}

function ui.newLayout(...) end

function ui.addButton(...) end

function ui.addEditText(...) end

function ui.addTextView(...) end

function ui.addCheckBox(...) end

function ui.addRadioBox(...) end

function ui.addComboBox(...) end

function ui.setOnClick(...) end

function ui.show(...) end

nodeLib = {}

function nodeLib.getNodeXml(...) end

function nodeLib.saveNode(...) end

function nodeLib.saveNodeNew(...) end

function nodeLib.lockNode(...) end

function nodeLib.unlockNode(...) end

function nodeLib.openAccessibility(...) end

function nodeLib.closeAccessibility(...) end

imeLib = {}

function imeLib.lock(...) end

function imeLib.unlock(...) end

function imeLib.setText(...) end

function imeLib.deleteChar(...) end

function imeLib.finishInput(...) end

function imeLib.keyEvent(...) end

cipher = {}

function cipher.md5(...) end

function cipher.sha1(...) end

function cipher.base64(...) end

function cipher.aes(...) end

network = {}

function network.httpGet(...) end

function network.httpPost(...) end

function network.download(...) end

json = {}

function json.encode(...) end

function json.decode(...) end

-- ============================================================
-- 节点选择器（链式）与节点对象
-- ============================================================

---@class MaNode 界面节点对象（由选择器 findOne/findAll/findOnce 取得）
local _MaNode = {}
function _MaNode:text() end

function _MaNode:id() end

function _MaNode:desc() end

function _MaNode:className() end

function _MaNode:packageName() end

---@return integer, integer, integer, integer
function _MaNode:bounds() end

---@return integer, integer, integer, integer
function _MaNode:boundsInParent() end

---@return integer
function _MaNode:childCount() end

---@return table
function _MaNode:childs() end

function _MaNode:parent() end

---@return integer
function _MaNode:drawingOrder() end

---@return integer
function _MaNode:depth() end

---@return string
function _MaNode:toJson() end

---@param s any
---@return boolean
function _MaNode:setText(s) end

---@param r any
---@param c any
---@return boolean
function _MaNode:scrollTo(r, c) end

---@return boolean
function _MaNode:scrollUp() end

---@return boolean
function _MaNode:scrollDown() end

---@return boolean
function _MaNode:scrollLeft() end

---@return boolean
function _MaNode:scrollRight() end

---@return boolean
function _MaNode:scrollForward() end

---@return boolean
function _MaNode:scrollBackward() end

---@return boolean
function _MaNode:click() end

---@return boolean
function _MaNode:longClick() end

---@return boolean
function _MaNode:focus() end

---@return boolean
function _MaNode:clearFocus() end

---@return boolean
function _MaNode:copy() end

---@return boolean
function _MaNode:paste() end

---@return boolean
function _MaNode:cut() end

---@return boolean
function _MaNode:select() end

---@param a any
---@param b any
---@return boolean
function _MaNode:setSelection(a, b) end

---@param p any
---@return boolean
function _MaNode:setProgress(p) end

---@return boolean
function _MaNode:collapse() end

---@return boolean
function _MaNode:expand() end

---@return boolean
function _MaNode:contextClick() end

---@class MaSelector 节点选择器（全局工厂函数创建，谓词链式叠加）
local _MaSelector = {}
---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:id(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:idContains(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:idStartsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:idEndsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:idMatches(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:text(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:textContains(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:textStartsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:textEndsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:textMatches(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:desc(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:descContains(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:descStartsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:descEndsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:descMatches(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:className(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:classNameContains(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:classNameStartsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:classNameEndsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:classNameMatches(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:packageName(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:packageNameContains(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:packageNameStartsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:packageNameEndsWith(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:packageNameMatches(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:bounds(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:boundsInside(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:drawingOrder(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:depth(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:index(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:visibleToUser(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:selected(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:clickable(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:longClickable(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:enabled(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:password(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:scrollable(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:checked(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:checkable(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:focusable(v) end

---@param v any
---@return MaSelector self 链式返回自身
function _MaSelector:focused(v) end

---@param timeout integer? 毫秒
---@return MaNode? node 找到的节点，超时为 nil
function _MaSelector:findOne(timeout) end

---@param timeout integer? 毫秒
---@return MaNode[] nodes 节点数组
function _MaSelector:findAll(timeout) end

---@param index integer? 第几个匹配（默认 0）
---@return MaNode? node
function _MaSelector:findOnce(index) end

-- 41 个全局选择器工厂函数
---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function id(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function idContains(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function idStartsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function idEndsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function idMatches(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function text(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function textContains(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function textStartsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function textEndsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function textMatches(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function desc(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function descContains(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function descStartsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function descEndsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function descMatches(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function className(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function classNameContains(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function classNameStartsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function classNameEndsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function classNameMatches(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function packageName(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function packageNameContains(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function packageNameStartsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function packageNameEndsWith(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function packageNameMatches(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function bounds(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function boundsInside(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function drawingOrder(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function depth(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function index(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function visibleToUser(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function selected(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function clickable(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function longClickable(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function enabled(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function password(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function scrollable(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function checked(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function checkable(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function focusable(v) end

---@param v any 匹配值
---@return MaSelector sel 新选择器（已含首个谓词）
function focused(v) end

console = {
  ---@param ... any
  log = function(...) end,
  ---@param ... any
  error = function(...) end,
}

---@param ... any
function log(...) end
