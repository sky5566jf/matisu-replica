#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MatisuAuto iOS 设备通信助手（同步）

作为 device_bridge.js 的子进程被调用，与 Android 的 android_cap.py 同构：
通过阻塞 socket 连接设备侧 MatisuAuto 的 18182 端口，发送一条文本指令，
读取「4 字节大端长度 + 负载」帧，按命令类型输出：
  - 二进制命令（screencap）：负载写入 outfile（PNG），stdout 为空
  - 文本命令（uinode）：负载（UTF-8 JSON）直接打印到 stdout

用法:
  python ios_sock.py <cmd> [outfile]
环境变量 MATISU_IOS_HOST / MATISU_IOS_PORT 覆盖目标（默认 192.69.0.38:18182）。
"""
import os
import sys
import socket
import json


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: ios_sock.py <cmd> [outfile]\n")
        sys.exit(2)
    cmd = sys.argv[1]
    outfile = sys.argv[2] if len(sys.argv) > 2 else None

    host = os.environ.get("MATISU_IOS_HOST", "192.69.0.38")
    port = int(os.environ.get("MATISU_IOS_PORT", "18182"))

    s = socket.create_connection((host, port), timeout=20)
    s.sendall((cmd + "\n").encode("utf-8"))

    # 读 4 字节大端长度
    head = b""
    while len(head) < 4:
        chunk = s.recv(4 - len(head))
        if not chunk:
            break
        head += chunk
    if len(head) < 4:
        sys.stderr.write("ios: 连接中断，未收到长度头\n")
        s.close()
        sys.exit(1)

    length = int.from_bytes(head, "big")
    if length == 0:
        sys.stderr.write("ios: 设备返回空帧（指令执行失败）\n")
        s.close()
        sys.exit(1)

    # 读负载
    payload = b""
    while len(payload) < length:
        chunk = s.recv(length - len(payload))
        if not chunk:
            break
        payload += chunk
    s.close()

    if len(payload) < length:
        sys.stderr.write("ios: 负载不完整 %d/%d\n" % (len(payload), length))
        sys.exit(1)

    if outfile:
        with open(outfile, "wb") as f:
            f.write(payload)
        # 不向 stdout 输出，避免与二进制混淆
    else:
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
