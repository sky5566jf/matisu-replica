#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iOS showUI 冒烟：异步 run showUI(JSON) → OCR 定位按钮 → tap 点击 → 验证返回值。
路径1：点「确认」→ 预期 1,值...（Edit/ComboBox/RadioGroup/CheckBoxGroup 各控件语义）
路径2：点「取消」→ 预期 0
协议与 Android 同构：:18182，run <base64>\\n → 4 字节大端长度 + JSON。
坐标：OCR 返回截图像素空间（MatisuCapturePNG），tap 用逻辑 UI 空间（getDisplaySize）；
      缩放比 = 显示逻辑宽 / 截图像素宽，自适应。
"""
import sys, socket, base64, json, threading, time, re, struct

HOST, CTRL_PORT = "192.69.0.38", 18182

UI_JSON = ('{"title":"测试面板","views":['
    '{"type":"Edit","caption":"账号","text":"abc","prompt":"输入账号"},'
    '{"type":"ComboBox","list":"模式A,模式B,模式C","select":2},'
    '{"type":"RadioGroup","list":"快点,慢点","select":1},'
    '{"type":"CheckBoxGroup","list":"日志,截图,震动","select":"0@2"}]}')

def run_socket(lua, timeout, out):
    try:
        s = socket.create_connection((HOST, CTRL_PORT), timeout=timeout)
        s.sendall(("run " + base64.b64encode(lua.encode("utf-8")).decode() + "\n").encode())
        s.settimeout(timeout)
        head = b""
        while len(head) < 4:
            c = s.recv(4 - len(head))
            if not c:
                break
            head += c
        n = int.from_bytes(head, "big")
        p = b""
        while len(p) < n:
            c = s.recv(n - len(p))
            if not c:
                break
            p += c
        s.close()
        out.append(p.decode("utf-8", "replace"))
    except Exception as e:
        out.append("ERR:" + str(e))

def lua_run(lua, timeout=60):
    out = []
    run_socket(lua, timeout, out)
    return out[0] if out else ""

def screencap_size():
    s = socket.create_connection((HOST, CTRL_PORT), timeout=30)
    s.sendall(b"screencap\n")
    head = b""
    while len(head) < 4:
        c = s.recv(4 - len(head))
        if not c:
            break
        head += c
    n = int.from_bytes(head, "big")
    png = b""
    while len(png) < n:
        png += s.recv(n - len(png))
    s.close()
    w, h = struct.unpack(">II", png[16:24])   # PNG IHDR
    return w, h

def ocr_tap(needle, scale):
    lua = ("local t=ocrTextEx(0,0,0,0) "
           "for i,it in ipairs(t) do if it.text:find('%s') then "
           "print('OCRPOS '..it.x..','..it.y..','..it.w..','..it.h..' '..it.text) break end end "
           "print('OCRPOS done')") % needle
    m = re.search(r"OCRPOS (\d+),(\d+),(\d+),(\d+)", lua_run(lua, 90))
    if not m:
        return None
    x, y, w, h = map(int, m.groups())
    return (round((x + w / 2) * scale), round((y + h / 2) * scale))

# 0) 就绪检查
try:
    socket.create_connection((HOST, CTRL_PORT), timeout=5).close()
except Exception:
    print("ERR: 控制端口 %s:%d 不可达（先部署并拉起 app）" % (HOST, CTRL_PORT))
    sys.exit(1)

# 1) 缩放比：截图像素空间 → tap 逻辑空间
r = lua_run("local w,h=getDisplaySize() print('DISP '..w..'x'..h)")
md = re.search(r"DISP (\d+)x(\d+)", r)
if not md:
    print("ERR: getDisplaySize 失败:", r)
    sys.exit(1)
dw, dh = int(md.group(1)), int(md.group(2))
pw, ph = screencap_size()
scale = dw / pw
print("display %dx%d, frame %dx%d, scale=%.4f" % (dw, dh, pw, ph, scale))

# ---------------- 路径 1：确认 ----------------
lua1 = ("local r1,v1,v2,v3,v4 = showUI([==[%s]==]) "
        "print('UIRET '..tostring(r1)..'|'..tostring(v1)..'|'..tostring(v2)..'|'..tostring(v3)..'|'..tostring(v4))") % UI_JSON
out1 = []
t1 = threading.Thread(target=run_socket, args=(lua1, 180, out1))
t1.start()
time.sleep(8)   # WKWebView 渲染
pos = ocr_tap("确认", scale)
print("确认按钮位置:", pos)
if pos:
    lua_run("tap(%d,%d)" % pos, 30)
t1.join(timeout=200)
print("路径1 响应:", out1[0] if out1 else "(无)")
ok1 = "UIRET 1|abc|2|1|0@2" in (out1[0] if out1 else "")

# ---------------- 路径 2：取消 ----------------
lua2 = ("local r1 = showUI([==[%s]==]) "
        "print('UIRET2 cancel='..tostring(r1))") % UI_JSON
out2 = []
t2 = threading.Thread(target=run_socket, args=(lua2, 180, out2))
t2.start()
time.sleep(8)
pos = ocr_tap("取消", scale)
print("取消按钮位置:", pos)
if pos:
    lua_run("tap(%d,%d)" % pos, 30)
t2.join(timeout=200)
print("路径2 响应:", out2[0] if out2 else "(无)")
ok2 = "UIRET2 cancel=0" in (out2[0] if out2 else "")

print("RESULT:", "PASS" if (ok1 and ok2) else f"FAIL (ok1={ok1} ok2={ok2})")
sys.exit(0 if (ok1 and ok2) else 1)
