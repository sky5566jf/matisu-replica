-- MatisuAuto demo (Phase 0)
-- 模拟"打开某 App 并点击登录"的脚本流程，验证统一 API 调用链路。

print("脚本启动")

local size = device.getScreenSize()
print("屏幕分辨率: " .. size[1] .. "x" .. size[2])
print("运行环境: " .. device.getOSType())

ui.toast("开始自动化")

-- 点击登录按钮坐标（Phase 0 触控由 PC 桥接打印）
touch.tap(540, 1200)
device.sleep(800)
touch.tap(540, 1600, 100)
device.sleep(500)

-- 找色（Phase 0 返回 nil，演示调用链路；真机需在截图后实现）
local p = color.findColor("0xFF0000")
if p then
  print("找到颜色 @ " .. p[1] .. "," .. p[2])
else
  print("findColor 暂未实现（需真机截图）")
end

log("脚本执行完毕")

-- 未实现的 API 仍以 STUB 打印，证明降级可用：
node.findNode("设置")
