#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iOS 断点调试冒烟：bpset → runfiledbg → 断言暂停帧（行号/局部变量）→ dbggo/dbgstep/dbgstop。
脚本（上传为 dbg_smoke.lua）：
  1 local x = 1
  2 while x <= 3 do
  3   x = x + 1        ← 断点设在这行（循环 3 次）
  4 end
  5 print("done " .. x)
预期：断点暂停 3 次（line=3），首次暂停 locals 含 x，dbggo 恢复后再暂停，最终帧 ok=true 输出 done 4。
"""
import sys, socket, base64, json, time

HOST, CTRL_PORT = "192.69.0.38", 18182
SRC = "local x = 1\nwhile x <= 3 do\n  x = x + 1\nend\nprint(\"done \" .. x)\n"

class Conn:
    def __init__(self, timeout=60):
        self.s = socket.create_connection((HOST, CTRL_PORT), timeout=timeout)
        self.s.settimeout(timeout)
    def send(self, line):
        self.s.sendall((line + "\n").encode())
    def read_frame(self, timeout=90):
        self.s.settimeout(timeout)
        head = b""
        while len(head) < 4:
            c = self.s.recv(4 - len(head))
            if not c:
                raise ConnectionError("closed")
            head += c
        n = int.from_bytes(head, "big")
        p = b""
        while len(p) < n:
            c = self.s.recv(n - len(p))
            if not c:
                raise ConnectionError("closed")
            p += c
        txt = p.decode("utf-8", "replace")
        try:
            return json.loads(txt)
        except Exception:
            return txt   # upload 等命令应答裸文本（"OK\n"）
    def close(self):
        try: self.s.close()
        except Exception: pass

def b64(s): return base64.b64encode(s.encode()).decode()

def main():
    ok = True
    # 0) 上传脚本：upload <b64路径> <b64内容>，应答为长度帧裸文本 "OK\n"
    up = Conn(30)
    up.send("upload %s %s" % (b64("dbg_smoke.lua"), b64(SRC)))
    ack = up.read_frame(30)
    up.close()
    print("upload:", ack)
    if "OK" not in str(ack):
        print("RESULT: FAIL (upload)")
        sys.exit(1)

    # 1) 会话连接：bpset + runfiledbg
    c = Conn(120)
    c.send("bpset " + b64(json.dumps({"lines": [3]})))
    print("bpset ack:", c.read_frame(30))

    c.send("runfiledbg dbg_smoke.lua")

    pauses = []
    final = None
    cmd = Conn(30)   # 独立连接发恢复命令

    # 第一次暂停
    f1 = c.read_frame(90)
    pauses.append(f1)
    print("pause1:", {k: f1.get(k) for k in ("paused", "line", "stack")})
    if not (f1.get("paused") and f1.get("line") == 3): ok = False
    lv = {row[1]: row[2] for row in f1.get("locals", []) if len(row) >= 3 and row[1] != "(*temporary)"}
    lv.pop("(temporary)", None)
    print("locals:", lv)
    if "x" not in lv: ok = False
    if not f1.get("globals"): ok = False   # 全局快照应有内容

    # 恢复 → 第二次暂停（行 3）
    cmd.send("dbggo")
    print("dbggo ack:", cmd.read_frame(30))
    f2 = c.read_frame(90)
    pauses.append(f2)
    print("pause2 line:", f2.get("line"))
    if not (f2.get("paused") and f2.get("line") == 3): ok = False

    # 单步：应到行 4（end 行）——lua 行事件在 while 4 行上再停
    cmd.send("dbgstep")
    print("dbgstep ack:", cmd.read_frame(30))
    f3 = c.read_frame(90)
    print("step line:", f3.get("line"), "(单步命中即算过)")
    if not f3.get("paused"): ok = False

    # 继续跑完剩余循环（x 已=3，还会停 1 次在行 3）→ 用 dbggo 恢复，等最终帧
    cmd.send("dbggo")
    cmd.read_frame(30)
    # 循环里可能还有若干暂停（x=3 时行 3 再停一次），逐个恢复直到最终帧
    for _ in range(6):
        f = c.read_frame(90)
        if f.get("paused"):
            print("extra pause line:", f.get("line"))
            cmd.send("dbggo")
            cmd.read_frame(30)
            continue
        final = f
        break
    cmd.close()

    print("final:", final)
    if not final or not final.get("ok"): ok = False
    if final and "done 4" not in str(final.get("output", "")): ok = False

    c.close()
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
