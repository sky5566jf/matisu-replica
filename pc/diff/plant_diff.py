#!/usr/bin/env python3
"""差分实验：把差分脚本直接植入原版 run/ 目录并执行"""
import base64
import paramiko

LUA = '''print("==DIFF==")
print("getModel=" .. tostring(getModel()))
print("getDeviceName=" .. tostring(getDeviceName()))
print("getSysVer=" .. tostring(getSysVer()))
local w,h = getDisplaySize()
print("display=" .. tostring(w) .. "x" .. tostring(h))
print("pixel=" .. tostring(getPixelColor(100,300)))
print("MD5=" .. tostring(MD5("abc")))
print("b64=" .. tostring(encodeBase64("hello")))
print("frontapp=" .. tostring(frontAppName()))
print("==END==")
exitScript()
'''

ROOT = '/var/mobile/Media/com.matisu.one.nxs.rootcore'

def main():
    b64 = base64.b64encode(LUA.encode()).decode()
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect('192.69.0.38', 22, 'mobile', '12345678', timeout=10)
    sftp = c.open_sftp()
    # entry.json 直接写（UTF-8 内容，原版能解析中文 key 值）
    entry = '{"lc_entry":"脚本/diff_test.lua"}'
    with sftp.open('/var/mobile/entry_tmp.json', 'w') as f:
        f.write(entry)
    with sftp.open('/var/mobile/diff_tmp.b64', 'w') as f:
        f.write(b64)
    sftp.close()
    cmd = (
        f'echo 12345678 | sudo -S sh -c "mkdir -p {ROOT}/run/脚本 && '
        f'base64 -d /var/mobile/diff_tmp.b64 > {ROOT}/run/脚本/diff_test.lua && '
        f'cp /var/mobile/entry_tmp.json {ROOT}/run/entry.json && '
        f'echo 122 > {ROOT}/run/version" && '
        f'ls -R {ROOT}/run/'
    )
    i, o, e = c.exec_command(cmd, timeout=30)
    print(o.read().decode())
    print(e.read().decode()[:300])
    c.close()

if __name__ == '__main__':
    main()
