-- verify_p0.lua —— P0 新增 API 真机验收（iOS 192.69.0.38）
-- 覆盖：原生分辨率 / 取色比色 / 找图三兄弟 / 网络 / 编码 / jsonLib / 停止回调
local pass, fail = 0, 0
local function ok(name, cond, extra)
    local tag = cond and "[PASS]" or "[FAIL]"
    if cond then pass = pass + 1 else fail = fail + 1 end
    print(tag .. " " .. name .. (extra ~= nil and ("  ->  " .. tostring(extra)) or ""))
end

print("===== P0 验收开始 =====")

-- 1. 屏幕尺寸（iOS 显示缩放机 320x568；Android 模拟器 720x1280 竖屏）
local w, h = getDisplaySize()
ok("getDisplaySize 有效", w ~= nil and h ~= nil and w > 0 and h > 0, w .. "x" .. h)

-- 2. 取色 → 比色 闭环（字符串格式与 cmpColor 兼容即过）
local cs = getPixelColor(100, 300)
ok("getPixelColor 返回颜色串", type(cs) == "string" and #cs >= 6, cs)
ok("cmpColor 同色比对", cmpColor(100, 300, cs, 0.95) == 1)
local ci = getPixelColor(100, 300, 1)
ok("getPixelColor(type=1) 返回整数", type(ci) == "number", ci)

-- 3. snapShot 截模板 → findPic 回找（屏幕未动，必中）
local tp = "tpl_verify.png"
local sp = snapShot(tp, 60, 150, 120, 210)
ok("snapShot 截模板", sp ~= nil, sp)
mSleep(300)
local fx, fy = findPic(0, 0, w, h, tp, nil, 0, 0.95)
ok("findPic 找回模板位置", fx ~= nil and math.abs(fx - 60) <= 4 and math.abs(fy - 150) <= 4,
   fx and (fx .. "," .. fy) or "nil")
local ex, ey = findPicEx(0, 0, w, h, tp, nil, 0, 0.95)
ok("findPicEx 找回模板位置", ex ~= nil and math.abs(ex - 60) <= 4 and math.abs(ey - 150) <= 4,
   ex and (ex .. "," .. ey) or "nil")

-- 4. 网络函数（PC 侧 curl）
local body, code = httpGet("https://www.baidu.com", 15)
ok("httpGet code=200", code == 200, code)
ok("httpGet body 非空", type(body) == "string" and #body > 100, body and (#body .. "B") or "nil")

-- 5. 编码函数
ok("MD5(abc)", MD5("abc") == "900150983cd24fb0d6963f7d28e17f72", MD5("abc"))
ok("encodeBase64(hello)", encodeBase64("hello") == "aGVsbG8=")
ok("decodeBase64 回环", decodeBase64("aGVsbG8=") == "hello")

-- 6. jsonLib
local js = jsonLib.encode({a = 1, b = "x"})
local tbl = jsonLib.decode(js)
ok("jsonLib 编解码回环", tbl ~= nil and tbl.a == 1 and tbl.b == "x", js)

-- 7. 键盘注入（效果已人工验证：HOME 回桌面、Spotlight 输入 sileo）
ok("keyPress(home) 返回成功", keyPress("home") == true or keyPress("home") == 1)
mSleep(1500)
ok("inputText(ASCII) 返回成功", inputText("abc123") == true or inputText("abc123") == 1)
keyPress("escape")   -- 关掉可能弹出的键盘/界面

-- 8. P1：getScreenDirection / findPicFast / ImageUtil 内存图色
ok("getScreenDirection 返回值域", getScreenDirection() >= 0 and getScreenDirection() <= 3, getScreenDirection())
local ffx, ffy = findPicFast(0, 0, w, h, tp, 0.9)
ok("findPicFast 找回模板", ffx ~= nil and math.abs(ffx - 60) <= 6 and math.abs(ffy - 150) <= 6,
   ffx and (ffx .. "," .. ffy) or "nil")
local img = ImageUtil.new(tp)
ok("ImageUtil.new 加载模板", img ~= nil and img > 0, img)
if img and img > 0 then
    local ic = ImageUtil.getPixelColor(img, 0, 0)
    ok("ImageUtil.getPixelColor", type(ic) == "string" and #ic >= 6, ic)
    local ix, iy = ImageUtil.findColor(img, 0, 0, 60, 60, ic, 0, 0.95)
    ok("ImageUtil.findColor 找回 (0,0)", ix == 0 and iy == 0, ix .. "," .. iy)
    ok("ImageUtil.cmpColorEx 单点", ImageUtil.cmpColorEx(img, "0|0|" .. ic, 0.95) == 1)
    local px, py = ImageUtil.findPic(img, 0, 0, 60, 60, tp, 0.95)
    ok("ImageUtil.findPic 自匹配", px ~= nil and px <= 2 and py <= 2, px and (px .. "," .. py) or "nil")
    local cp = ImageUtil.crop(img, 0, 0, 30, 30, "tpl_crop.png")
    ok("ImageUtil.crop 存盘", cp ~= nil, cp)
    ImageUtil.free(img)
end

-- 9. setStopCallBack + exitScript（回调打出标记即过）
setStopCallBack(function()
    print("[PASS] setStopCallBack 回调触发")
end)
print("===== 主体结束: PASS=" .. pass .. " FAIL=" .. fail .. " =====")
exitScript()
