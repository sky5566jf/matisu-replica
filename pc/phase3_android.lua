-- Phase 3 Android 图色/UI 查询验证脚本
-- 运行: MATISU_TARGET=android node runner.js phase3_android.lua
print("=== Phase 3 Android 图色/UI 验证 ===")
local sz = device.getScreenSize()
local w, h = sz[1], sz[2]
print(string.format("screen = %d x %d", w, h))

-- 1) 读中心像素
local c = color.getColor(math.floor(w / 2), math.floor(h / 2))
if not c then print("getColor 失败"); return end
print(string.format("getColor(center) = 0x%06X", c))

-- 2) 用读到的颜色做 findColor（相似度 0.9），应命中某同色像素
local p = color.findColor(c, 0.9)
if p then
  print(string.format("findColor(0.9) hit @ (%d, %d)", p.x, p.y))
else
  print("findColor(0.9): NOT FOUND (异常)")
end

-- 2b) 精确匹配（sim=1.0）应命中我们读取的那个像素，回读一致（自洽闭环）
local p3 = color.findColor(c, 1.0)
if p3 then
  local c2 = color.getColor(p3.x, p3.y)
  print(string.format("findColor(1.0) hit @ (%d, %d), round-trip 0x%06X match=%s",
    p3.x, p3.y, c2, tostring(c2 == c)))
else
  print("findColor(1.0): NOT FOUND (异常)")
end

-- 3) 区域找色（上半屏）
local p2 = color.findColor(c, 0.9, { 0, 0, w, math.floor(h / 2) })
if p2 then print(string.format("region findColor hit @ (%d, %d)", p2.x, p2.y)) end

-- 4) UI 节点查询：取第一个有文字的节点，并点击其中心（验证 node->touch 集成）
local n = node.findNode("")
if n then
  print(string.format("findNode(first) text='%s' bounds=(%d,%d,%d,%d) center=(%d,%d)",
    n.text, n.x, n.y, n.w, n.h, n.cx, n.cy))
  touch.tap(n.cx, n.cy)
  print("tapped node center via Android input tap")
else
  print("findNode: 当前屏幕无带文字节点")
end

-- 5) dump UI 树
local tree = node.dump()
if tree then print(string.format("node.dump() 返回 %d 字节 XML", #tree)) end

print("=== done ===")
