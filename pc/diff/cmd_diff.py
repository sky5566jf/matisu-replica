#!/usr/bin/env python3
"""命令级差分：同一语义命令在 Oracle/Replica 各跑一遍，对比返回值"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engines import Oracle, Replica, compare


def main():
    o = Oracle()
    r = Replica()
    results = []

    si = o.get_screen_info()
    di = r.devinfo()
    results.append(compare('getModel', si.get('device_model'), di.get('model')))
    results.append(compare('physical_resolution',
                           str(si.get('physical_resolution')),
                           f"{{{di.get('pixelWidth')}, {di.get('pixelHeight')}}}"))
    results.append(compare('scale', si.get('scale'), di.get('scale')))
    results.append(compare('render_resolution',
                           str(si.get('render_resolution')),
                           f"{{{di.get('pixelWidth')}, {di.get('pixelHeight')}}}"))

    lua_vals = {}
    for name, code in [
        ('getSysVer', 'return getSysVer()'),
        ('display', 'local w,h = getDisplaySize() return w .. "x" .. h'),
        ('MD5', 'return MD5("abc")'),
        ('base64', 'return encodeBase64("hello")'),
    ]:
        d = r.run_lua(code)
        out = (d.get('output') or '').strip()
        lua_vals[name] = out

    results.append(compare('getSysVer', '16.1.1', lua_vals['getSysVer']))
    results.append(compare('display', '320x568', lua_vals['display']))
    results.append(compare('MD5', '900150983cd24fb0d6963f7d28e17f72', lua_vals['MD5']))
    results.append(compare('base64', 'aGVsbG8=', lua_vals['base64']))

    of = o.front_app()
    rf = r.front_app()
    ov = of if isinstance(of, str) else str(of)
    results.append(compare('frontAppName', ov, rf))

    passed = sum(1 for ok, _ in results if ok)
    for ok, msg in results:
        print(msg)
    print(f'\n===== 差分: {passed}/{len(results)} 一致 =====')
    return 0 if passed == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
