#!/usr/bin/env python3
# MatisuAuto 复刻进度表生成器
# 扫描：契约 core.lua（_stub）+ 文档分节（lua-api-surface.md）
#      PC runner.js（regGlobal）+ iOS LuaEngine.mm（registerFns/setglobal）
#      + Android LuaEngine.kt（g.set）
# 输出：docs/api-manifest.json + docs/api-coverage.md
import json
import re
import os
import sys
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def read(p):
    with open(os.path.join(ROOT, p), encoding='utf8', errors='replace') as f:
        return f.read()


def parse_sections():
    """从 core.lua 解析分节结构（-- 一、xxx 注释）与函数归属"""
    sections = []
    cur = {'name': '全局/其他', 'fns': []}
    core = read('common/lua-api/core.lua')
    for line in core.split('\n'):
        m = re.match(r'--\s*([一二三四五六七八九十]+)、(.+)', line)
        if m:
            if cur['fns']:
                sections.append(cur)
            cur = {'name': m.group(2).strip(), 'fns': []}
            continue
        for sm in re.finditer(r'_stub\("([^"]+)"\)', line):
            cur['fns'].append(sm.group(1))
    if cur['fns']:
        sections.append(cur)
    return sections


def parse_pc():
    src = read('pc/runner.js')
    fns = set(re.findall(r"regGlobal\('([^']+)'", src))
    # 数组循环注册：['tap','swipe',...].forEach(...) 形式
    for arr in re.findall(r"\[((?:\s*'[^']+',?)+)\]\.forEach", src):
        fns |= set(re.findall(r"'([^']+)'", arr))
    # setField('table', 'name', ...) 表绑定
    for tm in re.finditer(r"setField\('(\w+)',\s*'(\w+)'", src):
        fns.add(f'{tm.group(1)}.{tm.group(2)}')
    return fns


def parse_bridge():
    """bridge 导出也算 PC 能力（经 core.lua coreCall 走的函数）"""
    src = read('pc/device_bridge.js')
    m = re.search(r'module\.exports\s*=\s*\{(.*?)\};', src, re.S)
    if not m:
        return set()
    names = set()
    for line in m.group(1).split('\n'):
        for nm in re.findall(r'\b([a-zA-Z_]\w+)\b', line):
            names.add(nm)
    # 去掉明显非函数标识
    names -= {'function', 'const', 'let', 'var', 'require', 'path', 'fs', 'os'}
    return names


def parse_ios():
    src = read('ios/app/LuaEngine.mm')
    # 全局函数（FNS 表）
    fns = set(re.findall(r'\{\s*"([a-zA-Z_]\w*)"\s*,\s*l_\w+\s*\}', src))
    # lua_setglobal 直注册（print / jsonLib / network / cipher 等）
    fns |= set(re.findall(r'lua_setglobal\(L,\s*"(\w+)"\)', src))
    # 模块表函数：createtable -> 若干 setfield -> setglobal("表名")
    # 用状态机按 setglobal 归属表名，否则所有 setfield 都会被误算成 jsonLib.*
    # （也会把 OCR 结果表的 x/y/w/h/score/text 这类字段名误当成 API）
    tracking, pending = False, []
    for line in src.splitlines():
        s = line.strip()
        if 'lua_createtable' in s:
            tracking, pending = True, []
        elif tracking and 'lua_setfield' in s:
            m = re.search(r'lua_setfield\(L,\s*-2,\s*"(\w+)"\)', s)
            if m:
                pending.append(m.group(1))
        elif tracking and 'lua_setglobal' in s:
            m = re.search(r'lua_setglobal\(L,\s*"(\w+)"\)', s)
            if m:
                for f in pending:
                    fns.add('%s.%s' % (m.group(1), f))
            tracking, pending = False, []
    fns.discard('tostring')
    return fns


def parse_android():
    src = read('android/app/src/main/java/com/matisu/auto/LuaEngine.kt')
    fns = set(re.findall(r'g\.set\("([a-zA-Z_]\w*)"', src))
    fns.discard('print')  # print 三端通用不算 API
    return fns


# Lua 标准库前缀（三端引擎均为完整 Lua VM，标准库内置可用）
STDLIB_PREFIX = ('io.', 'os.', 'string.', 'table.', 'math.', 'utf8.', 'coroutine.')


def is_stdlib(name):
    return name.startswith(STDLIB_PREFIX)


# Android 平台专属（原版 iOS 端同样没有；iOS 端标 N/A 不计缺口）
ANDROID_ONLY = {
    'getBrand', 'getBootLoader', 'getBoard', 'getManufacturer', 'getProduct', 'getDevice',
    'getHardware', 'getId', 'getFingerprint', 'getCpuAbi', 'getCpuAbi2', 'getSdkVersion',
    'getPackageName', 'getSubscriberId', 'getSimSerialNumber', 'getInstalledApk',
    'getInstalledApps', 'installApk', 'getCurrentActivity', 'appIsRunning', 'sendSms',
    'phoneCall', 'runIntent', 'scanImage', 'setBTEnable', 'setWifiEnable', 'setAirplaneMode',
    'getSdPath', 'setControlBarPosNew', 'showControlBar', 'exec',
}


def platform_na(name, platform):
    """该函数在此平台不适用（原版同样没有）"""
    if platform == 'ios' and name in ANDROID_ONLY:
        return True
    return False


def main():
    sections = parse_sections()
    pc, ios, android = parse_pc() | parse_bridge(), parse_ios(), parse_android()

    manifest = {
        'generated': datetime.datetime.now().isoformat(timespec='seconds'),
        'summary': {'pc': len(pc), 'ios': len(ios), 'android': len(android)},
        'sections': [],
    }
    md = ['# MatisuAuto 复刻进度表（API manifest）',
          f'> 生成: {manifest["generated"]}  ｜  PC {len(pc)} / iOS {len(ios)} / Android {len(android)} 已注册', '']

    total = done_pc = done_ios = done_android = 0
    for sec in sections:
        items = []
        for fn in sec['fns']:
            if is_stdlib(fn):
                st = {'pc': True, 'ios': True, 'android': True, 'builtin': True}
            else:
                st = {
                    'pc': fn in pc,
                    'ios': 'N/A' if platform_na(fn, 'ios') else fn in ios,
                    'android': 'N/A' if platform_na(fn, 'android') else fn in android,
                }
            items.append({'name': fn, **st})
            total += 1
            done_pc += bool(st['pc'])
            done_ios += bool(st['ios'] and st['ios'] != 'N/A')
            done_android += bool(st['android'] and st['android'] != 'N/A')
        missing = [i['name'] for i in items if not (i['pc'] and i['ios'])]
        md.append(f'## {sec["name"]}（{len(items)} 个）')
        md.append('')
        md.append('| 函数 | PC | iOS | Android |')
        md.append('|---|---|---|---|')
        for i in items:
            def mark(v):
                if v == 'N/A':
                    return 'N/A'
                return '✅' if v else '—'
            if i.get('builtin'):
                md.append(f'| {i["name"]} | 内置 | 内置 | 内置 |')
            else:
                md.append(f'| {i["name"]} | {mark(i["pc"])} | {mark(i["ios"])} | {mark(i["android"])} |')
        md.append('')
        if missing:
            md.append(f'缺口: {", ".join(missing)}')
            md.append('')
        manifest['sections'].append({'name': sec['name'], 'count': len(items), 'functions': items})

    md.insert(4, f'**契约函数 {total} 个；覆盖率 PC {done_pc}/{total} ({done_pc*100//total}%) / '
                 f'iOS {done_ios}/{total} ({done_ios*100//total}%) / Android {done_android}/{total} ({done_android*100//total}%)**')
    md.insert(5, '')
    md.insert(6, '> 注：仅统计 core.lua 契约函数（133 个）；文档长尾 ~570 个见 lua-api-surface.md §5。')
    md.insert(7, '')

    os.makedirs(os.path.join(ROOT, 'docs'), exist_ok=True)
    with open(os.path.join(ROOT, 'docs', 'api-manifest.json'), 'w', encoding='utf8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    with open(os.path.join(ROOT, 'docs', 'api-coverage.md'), 'w', encoding='utf8') as f:
        f.write('\n'.join(md) + '\n')
    print(f'total={total} pc={done_pc} ios={done_ios} android={done_android}')
    print('docs/api-manifest.json + docs/api-coverage.md')


if __name__ == '__main__':
    sys.exit(main())
