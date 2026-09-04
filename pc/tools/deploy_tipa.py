#!/usr/bin/env python3
"""部署 tipa 到真机 192.69.0.38（trollstorehelper 安装 + uiopen 拉起 + probe）。"""
import sys, time, socket
sys.path.insert(0, "F:/workbuddy/MatisuAuto/replica")
from install_ios import ssh, run, scp_push, HOST, CTRL_PORT

tipa = sys.argv[1]
remote = "/var/mobile/" + tipa.replace("\\", "/").split("/")[-1]
c = ssh()
print("推送 tipa (%d bytes) -> %s" % (__import__("os").path.getsize(tipa), remote))
scp_push(c, tipa, remote)
print("trollstorehelper install ...")
rc, out, err = run(c, 'TS=$(find /var/containers/Bundle/Application -maxdepth 2 -name TrollStore.app 2>/dev/null | head -1) && echo "12345678" | sudo -S "$TS/trollstorehelper" install %s' % remote, timeout=180)
print("rc=%d\n%s%s" % (rc, out[-2000:], err[-1000:]))
run(c, "rm -f %s" % remote)
print("uiopen 拉起 ...")
run(c, "uiopen 'matisuauto://'")
c.close()
print("等待服务 ...")
for i in range(10):
    time.sleep(3)
    try:
        s = socket.create_connection((HOST, CTRL_PORT), timeout=5)
        s.settimeout(5)
        s.sendall(b"ping\n")
        head = b""
        while len(head) < 4:
            head += s.recv(4 - len(head))
        n = int.from_bytes(head, "big")
        data = b""
        while len(data) < n:
            d = s.recv(min(65536, n - len(data)))
            if not d:
                break
            data += d
        s.close()
        print("probe ->", data.decode("utf-8", "replace")[:200])
        break
    except Exception as e:
        print("wait %d: %s" % (i, e))
else:
    print("probe FAIL: 服务未拉起")
