-- =============================================================
-- demo_lrun.lua —— 对齐 懒人精灵(Luarunner) v1.3 用法的演示
-- 运行: NODE_PATH=<fengari> node runner.js demo_lrun.lua
--       目标设备由 devices.json / MATISU_TARGET 决定
-- =============================================================
print("===== 懒人精灵风格 API 演示 =====")
print("OS 类型: " .. device.getOSType() .. "  设备: " .. device.getDeviceName())

-- ---- device：屏幕尺寸 / 机型 / 系统版本 ----
local w = device.getScreenWidth()
local h = device.getScreenHeight()
print(string.format("屏幕: %d x %d", w, h))
print("机型: " .. (device.getDeviceModel() or "?"))
print("系统版本: " .. (device.getSystemVersion() or "?"))

-- ---- 触控：全局函数（懒人精灵风格） ----
print("\n-- 触控 --")
click(w / 2, h / 2)            -- 单击
doubleClick(200, 200)          -- 双击
longClick(300, 300, 800)       -- 长按 800ms
swipe(100, 600, 1000, 600, 300) -- 滑动 300ms
fling(200, 400, 800, 400)      -- 快速滑动

-- 多指：touchDown/Move/Up（iOS 真多指；Android 单指合成）
touchDown(1, 400, 400)
touchMove(1, 400, 300)
touchUp(1)

-- ---- 图色 ----
print("\n-- 图色 --")
local c = color.getColor(math.floor(w / 2), math.floor(h / 2))
print(string.format("中心点颜色: 0x%06X", c or 0))
if c then
  local x, y = color.findColor(c, 0, 0, w, h, 0.9)
  if x then
    print(string.format("findColor 命中: (%d, %d)", x, y))
    local c2 = color.getColor(x, y)
    print(string.format("回读: 0x%06X  一致=%s", c2 or 0, tostring(c2 == c)))
  else
    print("findColor: 未命中")
  end
  local list = color.findColors(c, 0, 0, w, h, 0.95)
  print(string.format("findColors 命中数: %d", #list))
end
-- 区域模糊找色
local fx, fy = color.findColorInRegionFuzzy(0xFFFFFF, 0.8, 0, 0, 200, 200)
if fx then print(string.format("findColorInRegionFuzzy 命中: (%d, %d)", fx, fy)) end

-- ---- UI 节点（懒人精灵规范：node.* 表方法） ----
print("\n-- UI 节点 --")
local all = node.findNodes({})
print(string.format("node.findNodes({}) 总数: %d", #all))
local n = node.findNodeByText("设置")
if n then
  print(string.format("node.findNodeByText('设置') 中心: (%d, %d) 尺寸: %dx%d", n.cx, n.cy, n.w, n.h))
  local b = node.getNodeBounds(n)
  print(string.format("node.getNodeBounds: x=%d y=%d w=%d h=%d", b.x, b.y, b.w, b.h))
  node.clickNode(n)   -- 点击节点中心（该节点为 0 边界隐藏视图，点击落点(0,0)无副作用）
else
  print("node.findNodeByText('设置'): 未找到（当前界面可能没有该文字）")
end

-- ---- ui 交互（PC 宿主仅打印） ----
ui.toast("MatisuAuto 演示完成")

print("\n===== 演示结束 =====")
