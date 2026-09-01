-- =============================================================
-- MatisuAuto demo（对齐「懒人精灵 高级版 2.0.1」真实 API 表面）
-- 真机运行: MATISU_TARGET=android node runner.js demo.lua
-- 脚本全程使用【全局函数】风格（非 color.* / device.* 表），
-- 颜色格式 BBGGRR，节点使用【选择器链式 + 全局工厂】。
-- =============================================================

print("==== MatisuAuto 真实 API 演示 ====")

-- -------------------------------------------------------------
-- 一、设备信息（全局函数，无表前缀）
-- -------------------------------------------------------------
local w, h = getDisplaySize()
print(string.format("屏幕分辨率: %dx%d", w, h))
print("机型: " .. getModel())
print("SDK: " .. getSdkVersion() .. "  电量: " .. getBatteryLevel() .. "%")
print("CPU 架构 getCpuArch: " .. getCpuArch() .. " (0=x86 1=arm 2=arm64 3=x86_64)")
print("运行环境 getRunEnvType: " .. getRunEnvType() .. " (0=root 1=无障碍)")

-- -------------------------------------------------------------
-- 二、颜色（BBGGRR），colorToRGB 纯计算
-- -------------------------------------------------------------
local r, g, b = colorToRGB(0xaabbcc)
print(string.format("colorToRGB(0xaabbcc) = %d,%d,%d  (BBGGRR->RGB)", r, g, b))

-- -------------------------------------------------------------
-- 三、图色（全局函数，颜色 BBGGRR 字符串）
-- -------------------------------------------------------------
local cx, cy = math.floor(w / 2), math.floor(h / 2)
local col = getPixelColor(cx, cy)                 -- 默认返回 BBGGRR 字符串
print("中心像素 getPixelColor = " .. tostring(col))
local ret, fx, fy = findColor(0, 0, w, h, col, 0, 0.9)
if ret == 1 then
  print(string.format("findColor 命中: (%d, %d)", fx, fy))
else
  print("findColor 未命中（屏幕可能纯色或比对阈值不匹配）")
end
local num = getColorNum(0, 0, w, h, col, 0.9)
print("同色像素数 getColorNum = " .. num)
local diff = colorDiff(0xff0000, 0x00ff00)
print("colorDiff(0xff0000, 0x00ff00) = " .. diff)

-- -------------------------------------------------------------
-- 四、节点选择器（链式全局工厂 + sel:findOne/findAll/findOnce）
-- -------------------------------------------------------------
local node = clickable(true):findOne(8000)        -- 找第一个可点击节点
if node then
  print("选择器 clickable(true):findOne 命中节点")
  print("  text      = " .. tostring(node:text()))
  print("  className = " .. node:className())
  print("  id        = " .. tostring(node:id()))
  local x1, y1, x2, y2 = node:bounds()
  print(string.format("  bounds    = (%d,%d,%d,%d)", x1, y1, x2, y2))
  print("  childCount= " .. node:childCount())
  -- 通过桥接执行真实点击，验证 node:click()
  local ok = node:click()
  print("  node:click() -> " .. tostring(ok))
else
  print("未找到可点击节点（当前界面无匹配，属正常）")
end

-- -------------------------------------------------------------
-- 五、触控（全局函数）
-- -------------------------------------------------------------
toast("MatisuAuto 真机演示开始", 10, 10, 16)
tap(cx, cy)
sleep(500)
swipe(100, h - 100, w - 100, h - 100, 300)
sleep(500)
longTap(cx, math.floor(h / 2))

-- 多点触控拖拽：按下 -> 移动 -> 抬起（finger 0）
touchDown(0, 300, 300)
sleep(80)
touchMove(0, 360, 360)
sleep(80)
touchUp(0)

-- -------------------------------------------------------------
-- 六、模块表（PC 原生扩展库能力，跨端通用）
-- -------------------------------------------------------------
print("cipher.md5('matisu')  = " .. cipher.md5("matisu"))
print("cipher.base64('hi')   = " .. cipher.base64("hi"))
local j = json.encode({ name = "matisu", v = 1, list = { 10, 20, 30 } })
print("json.encode = " .. j)
local t = json.decode(j)
print("json.decode.name = " .. t.name .. ", list[2] = " .. t.list[2])

log("脚本执行完毕")
print("==== demo 结束 ====")
