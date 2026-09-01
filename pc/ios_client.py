#!/usr/bin/env python3
"""MatisuAuto iOS 控制客户端：向设备 18182 端口发送触控指令。

用法:
  python ios_client.py tap 100 200
  python ios_client.py swipe 100 200 300 400 0.3
  python ios_client.py down 0 100 200
  python ios_client.py move 0 150 250
  python ios_client.py up 0 150 250
"""
import socket
import sys
import os

HOST = os.environ.get("MATISU_IOS_HOST", "192.69.0.38")
PORT = int(os.environ.get("MATISU_IOS_PORT", "18182"))


def send(cmd: str):
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.sendall((cmd + "\n").encode())
    s.close()
    print("sent:", cmd)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    send(" ".join(sys.argv[1:]))
