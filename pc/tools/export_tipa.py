#!/usr/bin/env python3
# MatisuAuto 工程导出打包：基础 tipa + 用户脚本 → 独立自启动 tipa
#
# 用法:
#   python export_tipa.py <基础tipa> <脚本目录> <输出tipa> [--name 显示名]
#
# 原理:
#   1. 解包基础 tipa（Payload/MatisuAuto.app）
#   2. 注入脚本到 MatisuAuto.app/scripts/（daemon 首启自动同步到
#      /var/mobile/Media/com.matisu.auto/run/脚本/ 并跑 autorun.lua）
#   3. 改 CFBundleDisplayName（保持 bundle id 不变，避免 LaunchDaemon/路径连锁）
#   4. 重新 zip 成 tipa（TrollStore 安装即部署）
import sys
import os
import zipfile
import shutil
import tempfile
import plistlib


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    base_tipa, script_dir, out_tipa = sys.argv[1:4]
    display_name = None
    if '--name' in sys.argv:
        display_name = sys.argv[sys.argv.index('--name') + 1]

    if not os.path.isfile(base_tipa):
        print(f'基础 tipa 不存在: {base_tipa}')
        return 1
    if not os.path.isdir(script_dir):
        print(f'脚本目录不存在: {script_dir}')
        return 1

    tmp = tempfile.mkdtemp(prefix='matisu_export_')
    try:
        # 1. 解包
        with zipfile.ZipFile(base_tipa) as z:
            z.extractall(tmp)
        app_dir = None
        for root, dirs, _ in os.walk(os.path.join(tmp, 'Payload')):
            for d in dirs:
                if d.endswith('.app'):
                    app_dir = os.path.join(root, d)
        if not app_dir:
            print('tipa 内未找到 .app')
            return 1

        # 2. 注入脚本
        dst_scripts = os.path.join(app_dir, 'scripts')
        os.makedirs(dst_scripts, exist_ok=True)
        n = 0
        for f in os.listdir(script_dir):
            src = os.path.join(script_dir, f)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(dst_scripts, f))
                n += 1
        if n == 0:
            print('脚本目录为空，未注入任何文件')
            return 1

        # 3. 改显示名
        if display_name:
            plist_path = os.path.join(app_dir, 'Info.plist')
            with open(plist_path, 'rb') as fp:
                pl = plistlib.load(fp)
            pl['CFBundleDisplayName'] = display_name
            pl['CFBundleName'] = display_name
            with open(plist_path, 'wb') as fp:
                plistlib.dump(pl, fp)

        # 4. 重打包（tipa = zip，Payload 在根）
        if os.path.exists(out_tipa):
            os.remove(out_tipa)
        with zipfile.ZipFile(out_tipa, 'w', zipfile.ZIP_DEFLATED) as z:
            for root, _, files in os.walk(tmp):
                for f in files:
                    full = os.path.join(root, f)
                    # Windows 下 os.path 是反斜杠，zip 条目名必须正斜杠（否则 TrollStore 安装报 179）
                    rel = os.path.relpath(full, tmp).replace(os.sep, '/')
                    z.write(full, rel)
        size = os.path.getsize(out_tipa)
        print(f'OK: {out_tipa} ({size} bytes, {n} 个脚本, 显示名={display_name or "不变"})')
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
