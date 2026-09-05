#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""两端函数面对齐静态审计：core.lua 清单 vs iOS FNS/module 注册 vs Android g.set 注册。"""
import re, io, sys

ROOT = "F:/workbuddy/MatisuAuto/replica"

def core_catalog():
    txt = io.open(f"{ROOT}/common/lua-api/core.lua", encoding="utf-8").read()
    fns = [m.group(1) for m in re.finditer(r'_stub\("([^"]+)"\)', txt)]
    fns.append("colorToRGB")   # 真实实现（非 stub）
    return sorted(set(fns))

def ios_registered():
    txt = io.open(f"{ROOT}/ios/app/LuaEngine.mm", encoding="utf-8").read()
    fns = set()
    # 全局函数：FNS 表条目
    for m in re.finditer(r'\{\s*"([^"]+)"\s*,\s*l_\w+\s*\}', txt):
        fns.add(m.group(1))
    # 模块表：lua_createtable ... lua_setglobal(L, "<mod>") 区间内的 setfield 归属该模块
    for m in re.finditer(r'lua_createtable\(L[^)]*\);(.*?)lua_setglobal\(L,\s*"(\w+)"\)', txt, re.S):
        body, mod = m.group(1), m.group(2)
        for f in re.finditer(r'lua_setfield\(L,\s*-2,\s*"(\w+)"\)', body):
            fns.add(mod + "." + f.group(1))
    # strutils（Lua 实现）
    fns.update("strutils." + w for w in re.findall(r'strutils\.(\w+)', txt))
    # QDictionary 实例方法：l_qdOpen 内 lua_createtable + setfield("方法") 块
    mq = re.search(r'static int l_qdOpen\(lua_State \*L\).*?lua_createtable\(L[^)]*\);(.*?)return 1;', txt, re.S)
    if mq:
        for f in re.finditer(r'lua_setfield\(L,\s*-2,\s*"(\w+)"\)', mq.group(1)):
            if f.group(1) != "_name":
                fns.add("QDictionary." + f.group(1))
    if re.search(r'lua_setglobal\(L,\s*"QDictionary"\)', txt):
        fns.add("QDictionary.open")     # open 为全局入口（lua_setglobal），实例方法见上
    return fns

def android_registered():
    txt = io.open(f"{ROOT}/android/app/src/main/java/com/matisu/auto/LuaEngine.kt", encoding="utf-8").read()
    fns = set()
    for m in re.finditer(r'g\.set\("([^"]+)"', txt):
        fns.add(m.group(1))
    # 模块表：找 "g.set(\"NAME\", var)" 对，var 的 tableOf() 初始化区间内的 var.set("f", ...) 归属 NAME
    for mm in re.finditer(r'g\.set\("(\w+)",\s*(\w+)\)', txt):
        mod, v = mm.group(1), mm.group(2)
        seg = re.search(r'val\s+' + re.escape(v) + r'\s*=\s*LuaValue\.tableOf\(\)(.*?)(?=g\.set\("' + re.escape(mod) + r'")', txt, re.S)
        if seg:
            for f in re.finditer(re.escape(v) + r'\.set\("(\w+)",', seg.group(1)):
                fns.add(mod + "." + f.group(1))
    # strutils（Lua 实现）
    fns.update("strutils." + w for w in re.findall(r'strutils\.(\w+)', txt))
    # QDictionary 实例方法：qdTable.set("open") 闭包内 t = tableOf + t.set("方法")
    mq = re.search(r'qdTable\.set\("open".*$', txt, re.S)
    if mq:
        mt = re.search(r'val t = LuaValue\.tableOf\(\)(.*?)return t', mq.group(0), re.S)
        if mt:
            for f in re.finditer(r'\bt\.set\("(\w+)",', mt.group(1)):
                if f.group(1) != "_name":
                    fns.add("QDictionary." + f.group(1))
    if "QDictionary" in fns:
        fns.add("QDictionary.open")     # open 为表静态入口，实例方法见上
    return fns

core = core_catalog()
ios = ios_registered()
andrd = android_registered()

# 平台差异白名单：标注「本轮先落地某端、另一端待补」的函数
ANDROID_ONLY = set()   # showUI/closeWindow 双端均已落地（2026-09-05 iOS WKWebView 版补齐）

miss_ios = [f for f in core if f not in ios and f not in ANDROID_ONLY]
miss_and = [f for f in core if f not in andrd]
extra_ios = sorted(ios - set(core))
extra_and = sorted(andrd - set(core))

print(f"core.lua 清单: {len(core)} 个函数")
print(f"iOS 注册: {len(ios)} 个 | Android 注册: {len(andrd)} 个")
if ANDROID_ONLY:
    print(f"平台差异（Android 先行，iOS 待补）: {sorted(ANDROID_ONLY)}")
print(f"\n清单有但 iOS 缺 ({len(miss_ios)}): {miss_ios}")
print(f"清单有但 Android 缺 ({len(miss_and)}): {miss_and}")
print(f"iOS 多出清单外 ({len(extra_ios)}): {extra_ios}")
print(f"Android 多出清单外 ({len(extra_and)}): {extra_and}")
ok = not miss_ios and not miss_and
print("\n" + ("PASS: 清单与两端注册对齐" if ok else "FAIL: 存在缺口"))
sys.exit(0 if ok else 1)
