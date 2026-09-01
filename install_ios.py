#!/usr/bin/env python3
"""MatisuAuto iOS 真机部署/回滚（rootless palera1n, 设备 192.69.0.38）。

依赖隔离 venv 的 paramiko:
  C:/Users/Administrator/.workbuddy/binaries/python/envs/default/Scripts/python install_ios.py <cmd>

cmd:
  backup            拉取当前能跑的 daemon 二进制 + LaunchDaemon plist 到本地安全网
  install_deb PATH sudo dpkg -i 安装指定 deb（升级会触发 prerm/postinst 重载守护）
  rollback          用安全网二进制覆盖 /var/jb/Applications 并 kickstart 守护
  probe             连 18182 取 diag / screencap
  check             探测环境（dpkg/arch/当前进程）
"""
import os
import sys
import time
import socket

HOST = "192.69.0.38"
PORT_SSH = 22
USER = "mobile"
PASS = "12345678"
BUNDLE = "com.matisu.auto"
CTRL_PORT = 18182
LD_PLIST = "/var/jb/Library/LaunchDaemons/com.matisu.auto.daemon.plist"
DAEMON_BIN = "/var/jb/Applications/MatisuAuto.app/MatisuAuto"
BACKUP_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ci_artifacts", "backup")
SUDO = "echo %s | sudo -S " % PASS


def ssh():
    import paramiko
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, PORT_SSH, USER, PASS, timeout=15, look_for_keys=False, allow_agent=False)
    return c


def run(c, cmd, timeout=120, sudo=False):
    full = (SUDO + cmd) if sudo else cmd
    stdin, stdout, stderr = c.exec_command(full, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    rc = stdout.channel.recv_exit_status()
    return rc, out, err


def scp_push(c, local, remote):
    sftp = c.open_sftp()
    sftp.put(local, remote)
    sftp.close()


def scp_pull(c, remote, local):
    sftp = c.open_sftp()
    os.makedirs(os.path.dirname(local), exist_ok=True)
    sftp.get(remote, local)
    sftp.close()


def do_backup():
    c = ssh()
    os.makedirs(BACKUP_DIR, exist_ok=True)
    scp_pull(c, DAEMON_BIN, os.path.join(BACKUP_DIR, "MatisuAuto.bin"))
    scp_pull(c, LD_PLIST, os.path.join(BACKUP_DIR, "com.matisu.auto.daemon.plist"))
    rc, out, err = run(c, "cat %s/Info.plist | grep -A1 CFBundleShortVersionString" % os.path.dirname(DAEMON_BIN))
    print("当前设备 daemon 版本信息:\n", out, err)
    c.close()
    print("备份完成 ->", BACKUP_DIR)


def do_install_deb():
    if len(sys.argv) < 3:
        sys.exit("用法: install_ios.py install_deb <本地.deb路径>")
    local = sys.argv[2]
    if not os.path.exists(local):
        sys.exit("本地 deb 不存在: " + local)
    c = ssh()
    remote = "/var/mobile/" + os.path.basename(local)
    print("推送 deb (%d bytes) -> %s" % (os.path.getsize(local), remote))
    scp_push(c, local, remote)
    print("sudo dpkg -i ...")
    rc, out, err = run(c, "dpkg -i %s" % remote, timeout=180, sudo=True)
    print("dpkg rc=%d\n%s%s" % (rc, out, err))
    # 清掉推送的 deb
    run(c, "rm -f %s" % remote)
    c.close()
    print("等待守护拉起 ...")
    time.sleep(6)
    do_probe()


def do_rollback():
    bin_local = os.path.join(BACKUP_DIR, "MatisuAuto.bin")
    if not os.path.exists(bin_local):
        sys.exit("无安全网二进制，无法回滚")
    c = ssh()
    # 停守护
    run(c, "launchctl unload %s" % LD_PLIST, sudo=True)
    run(c, "killall MatisuAuto", sudo=True)
    time.sleep(2)
    # 覆盖二进制
    remote = "/var/mobile/MatisuAuto.rollback"
    scp_push(c, bin_local, remote)
    run(c, "cp %s %s && chown root:wheel %s && chmod 0755 %s" % (remote, DAEMON_BIN, DAEMON_BIN, DAEMON_BIN), sudo=True)
    run(c, "rm -f %s" % remote)
    # 重载
    run(c, "launchctl load %s" % LD_PLIST, sudo=True)
    c.close()
    time.sleep(5)
    do_probe()


def do_probe():
    try:
        s = socket.create_connection((HOST, CTRL_PORT), timeout=10)
        s.settimeout(10)
        s.sendall(b"diag\n")
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
        txt = data.decode("utf-8", "replace")
        print("diag ->", txt[:1000])
        # 版本
        import re
        m = re.search(r'"version"\s*:\s*"([^"]+)"', txt)
        if m:
            print(">> 设备运行版本:", m.group(1))
    except Exception as e:
        print("probe FAIL:", e)


def do_check():
    c = ssh()
    for cmd in [
        "uname -m",
        "which dpkg",
        "ls -l /var/jb/Applications/MatisuAuto.app/MatisuAuto",
        "ps -o pid,user,command -p $(pgrep -f 'MatisuAuto --daemon') 2>/dev/null",
        "launchctl list 2>/dev/null | grep matisu.auto",
    ]:
        rc, out, err = run(c, cmd)
        print("$ %s\n%s%s" % (cmd, out, err))
    c.close()


if __name__ == "__main__":
    act = sys.argv[1] if len(sys.argv) > 1 else "check"
    {"backup": do_backup, "install_deb": do_install_deb, "rollback": do_rollback,
     "probe": do_probe, "check": do_check}.get(act, lambda: print(__doc__))()
