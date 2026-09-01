-- MatisuAuto iOS 端到端演示（目标 MATISU_TARGET=ios，连 Mock 或真机 18182）
-- 覆盖：设备信息 / 颜色 / 截图图色 / UI 节点链式查询+点击 / 触控 / 扩展库

print("==== MatisuAuto iOS 演示 ====")

-- 设备信息
local w, h = getDisplaySize()
print(string.format("分辨率: %dx%d", w, h))
print("机型: " .. getModel())
print("设备名: " .. getDevice())
print("系统版本: " .. getOsVersionName() .. " (SDK=" .. getSdkVersion() .. ")")
print("电量: " .. getBatteryLevel() .. "%")
print("CPU架构: " .. getCpuArch() .. " / abi=" .. getCpuAbi())
print("DPI: " .. getDisplayDpi() .. "  旋转: " .. getDisplayRotate())
print("设备ID: " .. getDeviceId())
print("前台App: " .. frontAppName())
print("运行环境: " .. getRunEnvType())  -- 0 = root/激活等价

-- 颜色（BBGGRR）
local r, g, b = colorToRGB(0xaabbcc)
print(string.format("colorToRGB(0xaabbcc) = %d,%d,%d", r, g, b))

-- 截图 + 图色（截图逻辑在 PC 桥接层，iOS 端 ControlServer 负责回传 PNG）
keepCapture()
local c = getPixelColor(120, 220)
print("getPixelColor(120,220) = " .. c)  -- 期望 0000FF（红块）

local ret, x, y = findColor(0, 0, 0, 0, "0000FF", 0, 0.9)
print(string.format("findColor(红) -> ret=%d x=%d y=%d", ret, x, y))

local ret2, x2, y2 = findColor(0, 0, 0, 0, "00FF00", 0, 0.9)
print(string.format("findColor(绿) -> ret=%d x=%d y=%d", ret2, x2, y2))

local num = getColorNum(0, 0, 0, 0, "0000FF", 0.9)
print("getColorNum(红) = " .. num)  -- 红块像素数

local cd = colorDiff(0xFF0000, 0x0000FF)
print("colorDiff(0xFF0000, 0x0000FF) = " .. cd)

-- UI 节点链式查询（与 Android 完全一致的选择器 API）
print("---- 节点查询 ----")
local btn = clickable(true):findOne(10000)
if btn then
  print("findOne 命中: text=" .. tostring(btn:text())
    .. " className=" .. tostring(btn:className())
    .. " id=" .. tostring(btn:id()))
  local l, t, r2, b2 = btn:bounds()
  print(string.format("  bounds=(%d,%d,%d,%d) center=(%d,%d)",
    l, t, r2, b2, math.floor((l + r2) / 2), math.floor((t + b2) / 2)))
  print("  childCount=" .. btn:childCount())
  print("  depth=" .. btn:depth() .. " drawingOrder=" .. btn:drawingOrder())
  local ok = btn:click()  -- 真实点击（iOS 端走 MatisuTouchTap）
  print("  node:click() = " .. tostring(ok))
else
  print("findOne 未命中（设备无前台 App 或无障碍授权缺失）")
end

-- 多属性过滤
local list = text("首页"):findOne(5000)
if list then print("text('首页'):findOne -> " .. list:className()) end

-- 触控（iOS 端 IOHID 注入）
print("---- 触控 ----")
tap(100, 200)
swipe(50, 600, 300, 300, 300)
longTap(200, 200, 800)
touchDown(0, 150, 150)
touchMove(0, 200, 250)
touchUp(0, 200, 250)     -- 显式坐标
touchDown(1, 300, 400)
touchMove(1, 320, 420)
touchUp(1)               -- 省略坐标：应在最后落点 (320,420) 抬起

-- 扩展库
print("---- 扩展库 ----")
print("md5('hello') = " .. cipher.md5("hello"))
print("base64('hi') = " .. cipher.base64("hi"))
local j = json.encode({a = 1, b = "x"})
print("json.encode = " .. j)
local t = json.decode(j)
print("json.decode.a = " .. t.a)

toast("iOS 演示完成")
print("==== iOS 演示结束 ====")
