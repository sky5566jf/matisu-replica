#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iOS 真机冒烟：重启 MatisuAuto 进程后跑一段覆盖 strutils/cipher/json/设备信息的 Lua。"""
import sys, time, socket, json
sys.path.insert(0, "F:/workbuddy/MatisuAuto/replica")
from install_ios import ssh, run, HOST, CTRL_PORT

# 1) 杀老进程（覆盖安装不重启）+ 拉起
c = ssh()
run(c, "sudo killall -9 MatisuAuto 2>/dev/null; true")
c.close()
time.sleep(2)
c = ssh()
run(c, "uiopen 'matisuauto://'")
c.close()

# 2) 等控制端口
ok = False
for i in range(12):
    time.sleep(3)
    try:
        s = socket.create_connection((HOST, CTRL_PORT), timeout=5)
        s.close()
        ok = True
        break
    except Exception:
        pass
print("service up:", ok)
if not ok:
    sys.exit(1)

LUA = (
    "local r={} "
    "local function ck(n,f) local ok,err=pcall(f) r[#r+1]=n..(ok and '=OK' or '=FAIL:'..tostring(err)) end "
    "ck('strutils.bin2Hex',function() assert(strutils.bin2Hex('hello',true)=='68656c6c6f') end) "
    "ck('strutils.split',function() local w=strutils.split('a,b,c',',') assert(w[1]=='a' and w[3]=='c' and #w==3) end) "
    "ck('strutils.trim/replace',function() assert(strutils.trim('  x ')=='x') assert(strutils.replace('a-b','-','+')=='a+b') end) "
    "ck('strutils.startswith/endswith',function() assert(strutils.startswith('hi','h')) assert(strutils.endswith('hi','i')) end) "
    "ck('strutils.upper/lower',function() assert(strutils.upper('a')=='A' and strutils.lower('B')=='b') end) "
    "ck('MD5',function() assert(MD5('abc')=='900150983cd24fb0d6963f7d28e17f72') end) "
    "ck('sha1',function() assert(#sha1('abc')==40) end) "
    "ck('base64',function() assert(encodeBase64('hi')=='aGk=') assert(decodeBase64('aGk=')=='hi') end) "
    "ck('json.roundtrip',function() local t=json.decode('{\"a\":[1,2,{\"b\":\"x\"}],\"s\":\"y\"}') assert(t.a[3].b=='x') local s=jsonLib.encode({a=1,b={'z'}}) assert(type(s)=='string' and s:find('z')) end) "
    "ck('colorToRGB',function() local r,g,b=colorToRGB(0x0000FF) assert(r==255 and g==0 and b==0) end) "
    "ck('colorDiff',function() assert(colorDiff('000000','010101')==3) end) "
    "ck('network.httpGet',function() assert(network ~= nil and network.httpGet ~= nil) end) "
    "ck('findPic.args',function() local x,y=findPic(0,0,0,0,'/nope.png',0.9) assert(x==-1) end) "
    "ck('getScreenPixel',function() local a=getScreenPixel(0,0,2,2) assert(type(a)=='table' and #a>=1) end) "
    "ck('isDisplayDead',function() local v=isDisplayDead(0,0,10,10,1) assert(v==0 or v==1) end) "
    "ck('device.getModel',function() assert(#getModel()>0) end) "
    "ck('getEngineVersion',function() assert(#getEngineVersion()>0) end) "
    "ck('cipher.table',function() assert(cipher.md5('abc')==MD5('abc')) end) "
    "print('SMOKE ' .. table.concat(r, ' '))"
)

s = socket.create_connection((HOST, CTRL_PORT), timeout=30)
import base64
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
print("RAW:", txt[:2000])
try:
    j = json.loads(txt)
    out = j.get("output", "")
    print("KEYS:", list(j.keys()), "ok:", j.get("ok"), "error:", j.get("error"), "stopped:", j.get("stopped"))
    print("OUT:", out[:2000])
    smoke = [l for l in out.splitlines() if l.startswith("SMOKE")]
    line = smoke[0] if smoke else ""
    print(line)
    if "=FAIL" in line or not line:
        sys.exit(1)
    print("PASS")
except Exception as e:
    print("parse err", e)
    sys.exit(1)
