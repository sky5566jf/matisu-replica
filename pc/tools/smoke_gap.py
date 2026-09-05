#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""官方文档补齐批次冒烟（双端）：文件IO/时间/toast/OCR别名/zip/getter/cryptLib(AES5模式+RSA)/QDictionary。
用法：python smoke_gap.py --target ios   # 192.69.0.38:18182
      python smoke_gap.py --target android   # adb 192.69.0.34:5555 -> 18183
预期输出含 GAPSMOKE，所有项 =OK（iOS zip 场景断言可调用返回 boolean）。
"""
import sys, socket, base64, argparse

def build_lua(is_ios):
    return r"""
local r = {}
local function ck(n, f) local ok, err = pcall(f) r[#r+1] = n .. (ok and '=OK' or '=FAIL:' .. tostring(err)) end
local IS_IOS = IS_IOS_PLACEHOLDER

ck('systemTime', function() local t = systemTime() assert(t and t > 1600000000000, 'ts=' .. tostring(t)) end)
ck('tickCount', function() local a = tickCount() sleep(0.05) local b = tickCount() assert(b >= a and a >= 0) end)
ck('getWorkPath', function() local p = getWorkPath() assert(type(p) == 'string' and #p > 0, 'wp=' .. tostring(p)) end)
ck('fileIO', function()
  local p = getWorkPath() .. '/_gaptest.txt'
  assert(writeFile(p, 'hello', false) == true, 'write')
  assert(readFile(p) == 'hello', 'read')
  writeFile(p, ' world', true)
  assert(readFile(p) == 'hello world', 'append')
  assert(fileSize(p) == 11, 'size=' .. tostring(fileSize(p)))
  assert(fileExist(p) == true, 'exist')
  local l = listDir(getWorkPath())
  assert(type(l) == 'table' and #l >= 1, 'listdir')
  assert(delfile(p) == true, 'del')
  assert(fileExist(p) == false, 'gone')
end)
ck('mkdir', function()
  local d = getWorkPath() .. '/_gapdir/_sub'
  assert(mkdir(d) == true, 'mkdir')
  assert(fileExist(d) == true, 'exist')
  assert(delfile(getWorkPath() .. '/_gapdir') == true, 'rmdir')
end)
ck('getPackageName', function() local v = getPackageName() assert(type(v) == 'string' and #v > 0) end)
ck('getScriptVersion', function() assert(type(getScriptVersion()) == 'string') end)
ck('showToast', function() assert(showToast('gap-smoke') == true) end)
ck('ocrAlias', function()
  local s = ocr(0, 0, 0, 0) assert(type(s) == 'string', 'ocr')
  local t = ocrj(0, 0, 0, 0) assert(type(t) == 'table', 'ocrj')
  local s2 = ocrNew(0, 0, 0, 0, 0) assert(type(s2) == 'string', 'ocrNew')
  local t2 = ocrjNew(0, 0, 0, 0, 0) assert(type(t2) == 'table', 'ocrjNew')
end)
ck('findStrEx', function()
  assert(type(findStrEx(0, 0, 0, 0, 'x')) == 'table', 'ex')
  local x, y = findStrNew(0, 0, 0, 0, 0, 'x')
  assert(type(x) == 'number', 'new')
  assert(type(findStrExNew(0, 0, 0, 0, 0, 'x')) == 'table', 'exNew')
end)
if IS_IOS then
  ck('zip.iOSunsupported', function()
    assert(zip('a', 'b') == false, 'zip should return false on iOS')
    assert(unZip('a', 'b') == false, 'unzip should return false on iOS')
  end)
else
  ck('zip.roundtrip', function()
    local d = getWorkPath() .. '/_gapz'
    mkdir(d)
    writeFile(d .. '/a.txt', 'zip-test', false)
    local zp = getWorkPath() .. '/_gapz.zip'
    assert(zip(d, zp) == true, 'zip')
    local out = getWorkPath() .. '/_gapzout'
    assert(unZip(zp, out) == true, 'unzip')
    assert(readFile(out .. '/_gapz/a.txt') == 'zip-test', 'content')
    delfile(zp) delfile(out) delfile(d)
  end)
end
ck('aes.roundtrip', function()
  local key = '1234567890123456'
  local iv  = '0123456789abcdef'
  local plain = 'matisu-gap-smoke-测试'
  for _, m in ipairs({'ecb','cbc','cfb','ofb','ctr'}) do
    local enc = cryptLib.aes_crypt(plain, key, 'encrypt', m, m == 'ecb' and nil or iv, true)
    assert(type(enc) == 'string' and #enc > 0, m .. ' enc')
    local dec = cryptLib.aes_crypt(enc, key, 'decrypt', m, m == 'ecb' and nil or iv, true)
    assert(dec == plain, m .. ' dec=' .. tostring(dec))
  end
end)
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local VKEY, VPT = '2b7e151628aed2a6abf7158809cf4f3c', '6bc1bee22e409f96e93d7e117393172a'
print('CIPHERHEX-ecb', hex(cryptLib.aes_crypt(VPT, VKEY, 'encrypt', 'ecb', nil, false)))
print('CIPHERHEX-ctr', hex(cryptLib.aes_crypt(VPT, VKEY, 'encrypt', 'ctr', '0123456789abcdef', false)))
print('CIPHERHEX-cfb', hex(cryptLib.aes_crypt(VPT, VKEY, 'encrypt', 'cfb', '0123456789abcdef', false)))
print('CIPHERHEX-ofb', hex(cryptLib.aes_crypt(VPT, VKEY, 'encrypt', 'ofb', 'fedcba9876543210', false)))
ck('aes.keygen', function()
  local k32 = cryptLib.aes_keygen(32) assert(#k32 == 32, 'k32')
  local iv = cryptLib.aes_ivgen() assert(#iv == 16, 'iv')
  local p16 = '0123456789abcdef'
  local enc = cryptLib.aes_crypt(p16, k32, 'encrypt', 'cbc', iv, false)
  assert(#enc == 16, 'rawlen=' .. tostring(#enc))
  local dec = cryptLib.aes_crypt(enc, k32, 'decrypt', 'cbc', iv, false)
  assert(dec == p16, 'rawdec')
end)
ck('rsa.roundtrip', function()
  local pub, priv = cryptLib.rsa_generate_key(1024)
  assert(type(pub) == 'string' and pub:find('BEGIN', 1, true), 'pub')
  assert(type(priv) == 'string' and priv:find('BEGIN', 1, true), 'priv')
  local msg = 'rsa-matisu'
  local enc = cryptLib.rsa_encrypt(msg, pub, true)
  assert(#enc > 0, 'enc')
  local dec = cryptLib.rsa_decrypt(enc, priv, false)
  assert(dec == msg, 'dec=' .. tostring(dec))
  local sig = cryptLib.rsa_encrypt(msg, priv, false)
  local ver = cryptLib.rsa_decrypt(sig, pub, true)
  assert(ver == msg, 'verify=' .. tostring(ver))
end)
ck('qdict', function()
  local d = QDictionary.open('_gap_qdict')
  assert(d, 'open')
  d:put('s', '中文值') d:put('i', 42) d:put('f', 3.5) d:put('b', true)
  assert(d:get('s') == '中文值', 'get s')
  assert(d:get('i') == 42, 'get i=' .. tostring(d:get('i')))
  assert(d:get('f') == 3.5, 'get f')
  assert(d:get('b') == true, 'get b')
  assert(d:getType('i') == 'int', 'type i=' .. tostring(d:getType('i')))
  assert(d:getType('s') == 'string', 'type s')
  assert(d:getType('b') == 'bool', 'type b')
  assert(d:getInt('i') == 42, 'getInt')
  assert(d:getString('s') == '中文值', 'getString')
  assert(d:getDouble('f') == 3.5, 'getDouble')
  assert(d:getBool('b') == true, 'getBool')
  assert(d:contains('s') == true, 'contains')
  assert(d:size() == 4, 'size=' .. tostring(d:size()))
  d:remove('f')
  assert(d:size() == 3 and d:contains('f') == false, 'remove')
  assert(d:commit() == true, 'commit')
  local d2 = QDictionary.open('_gap_qdict')
  assert(d2:get('i') == 42 and d2:size() == 3, 'persist')
  d2:clear()
  assert(d2:size() == 0, 'clear')
end)
ck('getNetWorkTime', function() local t = getNetWorkTime() assert(type(t) == 'string' and #t == 19, 't=' .. tostring(t)) end)

print('GAPSMOKE ' .. table.concat(r, ' '))
""".replace("IS_IOS_PLACEHOLDER", "true" if is_ios else "false")

def run_ios(lua):
    s = socket.create_connection(("192.69.0.38", 18182), timeout=300)
    s.sendall(("run " + base64.b64encode(lua.encode()).decode() + "\n").encode())
    return s

def run_android(lua):
    adb = "D:/LDPlayer9.0.79.2/adb.exe"
    import subprocess
    subprocess.run([adb, "connect", "192.69.0.34:5555"], capture_output=True, timeout=20)
    subprocess.run([adb, "-s", "192.69.0.34:5555", "forward", "tcp:18183", "tcp:18183"], capture_output=True, timeout=20)
    s = socket.create_connection(("127.0.0.1", 18183), timeout=300)
    s.sendall(("run " + base64.b64encode(lua.encode()).decode() + "\n").encode())
    return s

def read_frame(s, timeout=280):
    s.settimeout(timeout)
    head = b""
    while len(head) < 4:
        c = s.recv(4 - len(head))
        if not c: raise ConnectionError("closed")
        head += c
    n = int.from_bytes(head, "big")
    p = b""
    while len(p) < n:
        c = s.recv(n - len(p))
        if not c: raise ConnectionError("closed")
        p += c
    s.close()
    txt = p.decode("utf-8", "replace")
    import json
    try: return json.loads(txt)
    except Exception: return txt

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=["ios", "android"], required=True)
    a = ap.parse_args()
    lua = build_lua(a.target == "ios")
    s = run_ios(lua) if a.target == "ios" else run_android(lua)
    resp = read_frame(s)
    obj = resp if isinstance(resp, dict) else {}
    out = obj.get("output", "") if isinstance(resp, dict) else str(resp)
    print(out if out else resp)
    line = [l for l in out.splitlines() if "GAPSMOKE" in l]
    if not line:
        print("RESULT: FAIL (no GAPSMOKE, error=%s)" % obj.get("error"))
        sys.exit(1)
    results = line[0].split(" ", 1)[1]
    bad = [t for t in results.split() if "=FAIL" in t]
    print("RESULT:", "PASS (%d/%d)" % (len(results.split()) - len(bad), len(results.split())) if not bad else "FAIL")
    if bad:
        print("FAILED:", bad)
        sys.exit(1)

if __name__ == "__main__":
    main()
