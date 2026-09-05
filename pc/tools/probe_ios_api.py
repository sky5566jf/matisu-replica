#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""快速探针：设备端 _VERSION / strutils / sha1 / 部分 API 状态。"""
import sys, time, socket, json, base64
sys.path.insert(0, "F:/workbuddy/MatisuAuto/replica")
from install_ios import HOST, CTRL_PORT

def devrun(lua, timeout=30):
    s = socket.create_connection((HOST, CTRL_PORT), timeout=timeout)
    s.sendall(("run " + base64.b64encode(lua.encode("utf-8")).decode() + "\n").encode("utf-8"))
    head = b""
    while len(head) < 4:
        chunk = s.recv(4 - len(head))
        if not chunk: break
        head += chunk
    length = int.from_bytes(head, "big")
    payload = b""
    while len(payload) < length:
        chunk = s.recv(length - len(payload))
        if not chunk: break
        payload += chunk
    s.close()
    try:
        j = json.loads(payload.decode("utf-8", "replace"))
        return j.get("output", "") + (" ERR:" + j["error"] if j.get("error") else "")
    except Exception:
        return "RAWFAIL: " + payload[:200].decode("utf-8", "replace")

print(devrun("print(_VERSION) print(type(strutils)) print(type(sha1)) print(type(utf8)) print(type(warn))"))
print(devrun("local ok,e = pcall(function() local s = assert(loadstring or load) end) print(ok, e)"))
