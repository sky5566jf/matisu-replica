#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Android showUI 冒烟：异步 run showUI(JSON) → adb OCR 定位按钮 tap → 验证返回值。
路径1：点「确认」→ 预期 1,值...（Edit/ComboBox/RadioGroup/CheckBoxGroup 各控件语义）
路径2：点「取消」→ 预期 0
"""
import sys, socket, base64, json, threading, time, re

HOST, CTRL_PORT = "192.69.0.34", 18183

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

def ocr_tap(needle):
    """OCR 找含 needle 的文本并 tap 中心"""
    lua = ("local t=ocrTextEx(0,0,0,0) "
           "for i,it in ipairs(t) do if it.text:find('%s') then "
           "print('OCRPOS '..it.x..','..it.y..','..it.w..','..it.h..' '..it.text) break end end "
           "print('OCRPOS done')") % needle
    out = []
    run_socket(lua, 60, out)
    txt = out[0] if out else ""
    m = re.search(r"OCRPOS (\d+),(\d+),(\d+),(\d+)", txt)
    if not m:
        return None
    x, y, w, h = map(int, m.groups())
    return (x + w // 2, y + h // 2)

def adb_tap(x, y):
    import subprocess
    subprocess.run(["/d/LDPlayer9.0.79.2/adb.exe", "-s", "192.69.0.34:5555",
                    "shell", f"input tap {x} {y}"], capture_output=True, timeout=30)

# ---------------- 路径 1：确认 ----------------
lua1 = ("local r1,v1,v2,v3,v4 = showUI([==[%s]==]) "
        "print('UIRET '..tostring(r1)..'|'..tostring(v1)..'|'..tostring(v2)..'|'..tostring(v3)..'|'..tostring(v4))") % UI_JSON
out1 = []
t1 = threading.Thread(target=run_socket, args=(lua1, 180, out1))
t1.start()
time.sleep(5)   # WebView 渲染
pos = ocr_tap("确认")
print("确认按钮位置:", pos)
if pos:
    adb_tap(*pos)
t1.join(timeout=200)
print("路径1 响应:", out1[0] if out1 else "(无)")
ok1 = "UIRET 1|abc|2|1|0@2" in (out1[0] if out1 else "")

# ---------------- 路径 2：取消 ----------------
lua2 = ("local r1 = showUI([==[%s]==]) "
        "print('UIRET2 cancel='..tostring(r1))") % UI_JSON
out2 = []
t2 = threading.Thread(target=run_socket, args=(lua2, 180, out2))
t2.start()
time.sleep(5)
pos = ocr_tap("取消")
print("取消按钮位置:", pos)
if pos:
    adb_tap(*pos)
t2.join(timeout=200)
print("路径2 响应:", out2[0] if out2 else "(无)")
ok2 = "UIRET2 cancel=0" in (out2[0] if out2 else "")

print("RESULT:", "PASS" if (ok1 and ok2) else f"FAIL (ok1={ok1} ok2={ok2})")
sys.exit(0 if (ok1 and ok2) else 1)
