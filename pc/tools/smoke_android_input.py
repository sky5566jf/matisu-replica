#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Android 输入类冒烟：inputText 全链（设置搜索框）+ keyPress 通路 + lockScreen。
lockScreen 放最后单独跑（锁屏会打断投屏），本脚本只做 inputText/keyPress。
"""
import sys, socket, base64, json

HOST, CTRL_PORT = "192.69.0.34", 18183

LUA = (
    "local r={} "
    "local function ck(n,f) local ok,err=pcall(f) r[#r+1]=n..(ok and '=OK' or '=FAIL:'..tostring(err)) end "
    "ck('runApp.settings',function() runApp('com.android.settings') end) "
    "sleep(2.5) "
    "local sx,sy=-1,-1 "
    "ck('ocr.findsearch',function() local ex=ocrTextEx(0,0,0,0) assert(type(ex)=='table') "
    "for i,it in ipairs(ex) do if it.text:find('搜索') then sx=it.x+it.w/2 sy=it.y+it.h/2 break end end "
    "assert(sx>0, 'no search bar on screen') end) "
    "if sx>0 then "
    "tap(sx,sy) sleep(1.5) "
    "ck('inputText',function() local ok=inputText('matisu123') assert(type(ok)=='boolean') end) "
    "sleep(0.8) "
    "ck('ocr.verify',function() local s=ocrText(0,0,0,0) assert(s:find('matisu123'), 'typed text not on screen') end) "
    "else r[#r+1]='inputText=SKIP(无搜索栏)' end "
    "ck('keyPress.back',function() keyPress('back') end) "
    "print('INSMOKE ' .. table.concat(r, ' '))"
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
        if "INSMOKE " in l:
            line = l.split("INSMOKE ", 1)[1]
    print(line or "(no smoke line)")
    if "FAIL" in line or "SKIP" in line or line.count("=OK") < 4:
        sys.exit(1)
    print("PASS")
except Exception as e:
    print("parse err", e)
    sys.exit(1)
