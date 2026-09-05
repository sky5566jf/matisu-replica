#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Android OCR 真帧冒烟：模拟器 192.69.0.34:18183。
前置：新 APK 已装、无障碍已开、投影已授权、模型已 push 到
/sdcard/Android/data/com.matisu.auto/files/ocr/（det/rec.onnx + dict.txt）。
"""
import sys, socket, base64, json

HOST, CTRL_PORT = "192.69.0.34", 18183

LUA = (
    "local r={} "
    "local function ck(n,f) local ok,err=pcall(f) r[#r+1]=n..(ok and '=OK' or '=FAIL:'..tostring(err)) end "
    "ck('ocrText.full',function() local s=ocrText(0,0,0,0) assert(type(s)=='string' and #s>0, 'empty') end) "
    "ck('ocrTextEx.shape',function() local t=ocrTextEx(0,0,0,0) assert(type(t)=='table' and #t>=1) local it=t[1] assert(type(it.text)=='string' and type(it.x)=='number' and type(it.score)=='number') end) "
    "ck('ocrText.region',function() local s=ocrText(0,0,200,120) assert(type(s)=='string') end) "
    "local ex=ocrTextEx(0,0,0,0) "
    "if #ex>0 then local sub=ex[1].text:sub(1,1) "
    "ck('findStr.hit',function() local ret,x,y=findStr(0,0,0,0,sub) assert(ret>=1 and x>=0, 'not found:'..sub) end) "
    "else r[#r+1]='findStr.hit=SKIP' end "
    "print('OCRSMOKE ' .. table.concat(r, ' '))"
)

s = socket.create_connection((HOST, CTRL_PORT), timeout=300)
s.sendall(("run " + base64.b64encode(LUA.encode("utf-8")).decode() + "\n").encode("utf-8"))
head = b""
while len(head) < 4:
    chunk = s.recv(4 - len(head))
    if not chunk:
        break
    head += chunk
length = int.from_bytes(head, "big")
payload = b""
while len(payload) < length:
    chunk = s.recv(length - len(payload))
    if not chunk:
        break
    payload += chunk
s.close()
txt = payload.decode("utf-8", "replace")
print("RAW:", txt[:3000])
try:
    j = json.loads(txt)
    out = j.get("output", "")
    print("ok:", j.get("ok"), "error:", j.get("error"))
    line = ""
    for l in out.splitlines():
        if "OCRSMOKE " in l:
            line = l.split("OCRSMOKE ", 1)[1]
    print(line or "(no smoke line)")
    if "FAIL" in line or "SKIP" in line:
        sys.exit(1)
    if line.count("=OK") < 3:
        sys.exit(1)
    print("PASS")
except Exception as e:
    print("parse err", e)
    sys.exit(1)
