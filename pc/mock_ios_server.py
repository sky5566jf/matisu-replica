#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MatisuAuto iOS 协议 Mock 服务（仅本地验证 PC 侧 iOS 闭环用，不进真机）

监听 127.0.0.1:18183，模拟设备侧 ControlServer.mm 的协议：
  - screencap : 返回一张程序生成的 PNG（含已知红/绿块，便于 findColor 命中）
  - uinode    : 返回一棵与 android_cap.py pub() 同字段的节点 JSON 数组
  - tap/swipe/down/move/up : 仅打印，回 OK（长度前缀包裹）
  - 统一响应：4 字节大端长度 + 负载

运行: python mock_ios_server.py
关闭: Ctrl+C
"""
import io
import json
import os
import socket
import threading

HOST = "127.0.0.1"
PORT = 18183
W, H = 375, 667  # 逻辑点分辨率（与 demo 的 CFG.ios.w/h 对应）


def build_png():
    # 优先用 PIL，缺失时回退到手写最小 PNG
    try:
        from PIL import Image, ImageDraw
        img = Image.new("RGBA", (W, H), (240, 240, 240, 255))
        d = ImageDraw.Draw(img)
        d.rectangle([100, 200, 140, 240], fill=(255, 0, 0, 255))   # 红块 BBGGRR=0000FF
        d.rectangle([200, 300, 260, 360], fill=(0, 255, 0, 255))   # 绿块 BBGGRR=00FF00
        d.rectangle([300, 100, 340, 140], fill=(0, 0, 255, 255))   # 蓝块 BBGGRR=FF0000
        buf = io.BytesIO()
        img.save(buf, "PNG")
        return buf.getvalue()
    except Exception:
        return _minimal_png()


def _minimal_png():
    import zlib, struct
    raw = bytearray()
    bg = (240, 240, 240)
    for y in range(H):
        raw.append(0)  # filter none
        for x in range(W):
            if 100 <= x <= 140 and 200 <= y <= 240:
                raw += bytes((255, 0, 0, 255))
            elif 200 <= x <= 260 and 300 <= y <= 360:
                raw += bytes((0, 255, 0, 255))
            else:
                raw += bytes(bg + (255,))
    comp = zlib.compress(bytes(raw), 9)

    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        import binascii
        c += struct.pack(">I", binascii.crc32(typ + data) & 0xffffffff)
        return c

    ihdr = struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", comp) + chunk(b"IEND", b"")
    return png


def build_devinfo():
    """模拟 DeviceInfo.m 的 devinfo 响应"""
    return {
        "name": "老马的 iPhone", "model": "iPhone9,3", "modelName": "iPhone",
        "systemName": "iOS", "systemVersion": "15.8.7", "sdk": 15,
        "width": W, "height": H, "scale": 2.0,
        "pixelWidth": W * 2, "pixelHeight": H * 2, "dpi": 326, "rotate": 0,
        "battery": 87, "cpuAbi": "arm64", "idfv": "5B9A1C2E-0000-4AAA-BBBB-1234567890AB",
        "bundleId": "com.matisu.auto",
    }


def build_nodes():
    return [
        {"i": 0, "parent": -1, "depth": 0, "index": 0, "drawingOrder": 0, "text": "",
         "id": "", "desc": "", "className": "Window", "packageName": "MobileSafari", "left": 0, "top": 0,
         "right": W, "bottom": H, "cx": W // 2, "cy": H // 2, "childCount": 2, "childs": [1, 2],
         "clickable": False, "longClickable": False, "scrollable": False, "selected": False,
         "enabled": True, "focusable": False, "focused": False, "checkable": False, "checked": False,
         "password": False, "visibleToUser": True},
        {"i": 1, "parent": 0, "depth": 1, "index": 0, "drawingOrder": 0, "text": "查看证书",
         "id": "android:id/button3", "desc": "", "className": "Button", "packageName": "MobileSafari",
         "left": 312, "top": 448, "right": 639, "bottom": 520, "cx": 475, "cy": 484, "childCount": 0,
         "childs": [], "clickable": True, "longClickable": False, "scrollable": False, "selected": False,
         "enabled": True, "focusable": True, "focused": False, "checkable": False, "checked": False,
         "password": False, "visibleToUser": True},
        {"i": 2, "parent": 0, "depth": 1, "index": 1, "drawingOrder": 0, "text": "首页",
         "id": "", "desc": "", "className": "Button", "packageName": "MobileSafari", "left": 10, "top": 10,
         "right": 100, "bottom": 50, "cx": 55, "cy": 30, "childCount": 0, "childs": [],
         "clickable": True, "longClickable": False, "scrollable": False, "selected": False,
         "enabled": True, "focusable": True, "focused": False, "checkable": False, "checked": False,
         "password": False, "visibleToUser": True},
    ]


def send_frame(cli, payload):
    head = len(payload).to_bytes(4, "big")
    try:
        cli.sendall(head + payload)
    except Exception:
        pass


def handle(cli):
    buf = b""
    while True:
        try:
            data = cli.recv(4096)
        except Exception:
            break
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            cmd = line.decode("utf-8", "ignore").strip()
            verb = cmd.split(" ", 1)[0] if cmd else ""
            if cmd == "screencap":
                png = build_png()
                send_frame(cli, png)
                print("[mock] screencap ->", len(png), "bytes", flush=True)
            elif cmd == "uinode":
                nodes = build_nodes()
                send_frame(cli, json.dumps(nodes, ensure_ascii=False).encode("utf-8"))
                print("[mock] uinode ->", len(nodes), "nodes", flush=True)
            elif cmd == "devinfo":
                send_frame(cli, json.dumps(build_devinfo(), ensure_ascii=False).encode("utf-8"))
                print("[mock] devinfo", flush=True)
            elif verb in ("tap", "swipe", "down", "move", "up"):
                print("[mock] touch:", cmd, flush=True)
                send_frame(cli, b"OK\n")
            else:
                print("[mock] unknown:", cmd, flush=True)
                send_frame(cli, b"OK\n")
    try:
        cli.close()
    except Exception:
        pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(4)
    print(f"[mock] MatisuAuto iOS mock listening on {HOST}:{PORT}")
    while True:
        cli, _ = srv.accept()
        threading.Thread(target=handle, args=(cli,), daemon=True).start()


if __name__ == "__main__":
    main()
