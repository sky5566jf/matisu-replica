#!/usr/bin/env python3
"""差分测试：原版懒人精灵(Oracle) vs MatisuAuto 复刻(Replica) 统一封装"""
import base64
import json
import socket
import urllib.request


class Oracle:
    """原版引擎：nx-http-server :3333"""
    def __init__(self, host='192.69.0.38', port=3333):
        self.base = f'http://{host}:{port}'

    def _post(self, path, obj, timeout=15):
        req = urllib.request.Request(
            self.base + path,
            data=json.dumps(obj).encode(),
            headers={'Content-Type': 'application/json'},
            method='POST')
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())

    def _get(self, path, timeout=15):
        with urllib.request.urlopen(self.base + path, timeout=timeout) as r:
            return json.loads(r.read())

    def cmd(self, name, **kw):
        body = {'cmd': name}
        body.update(kw)
        return self._post('/api/command', body)

    def get_screen_info(self):
        return self.cmd('getscreeninfo').get('response', {})

    def get_device_id(self):
        return self.cmd('getdeviceid').get('response', {})

    def front_app(self):
        return self.cmd('frontappname').get('response', {})

    def screenshot(self):
        with urllib.request.urlopen(self.base + '/api/screenshot', timeout=20) as r:
            return r.read()

    def tap(self, x, y):
        return self.cmd('click', x=x, y=y)

    def key_home(self):
        return self.cmd('keypress', key='HOME')

    def stop_script(self):
        return self.cmd('stopscript')

    def run_script(self, path='script.lrj'):
        return self.cmd('runscript', path=path)


class Replica:
    """复刻引擎：MatisuAuto daemon :18182"""
    def __init__(self, host='192.69.0.38', port=18182):
        self.host, self.port = host, port

    def cmd(self, line, timeout=20):
        s = socket.create_connection((self.host, self.port), timeout=timeout)
        s.settimeout(timeout)
        s.sendall((line + '\n').encode())
        head = b''
        while len(head) < 4:
            x = s.recv(4 - len(head))
            if not x:
                s.close()
                return None
            head += x
        n = int.from_bytes(head, 'big')
        data = b''
        while len(data) < n:
            x = s.recv(min(65536, n - len(data)))
            if not x:
                break
            data += x
        s.close()
        return data

    def run_lua(self, source, timeout=30):
        b64 = base64.b64encode(source.encode()).decode()
        r = self.cmd('run ' + b64, timeout)
        return json.loads(r.decode()) if r else {'ok': False, 'error': 'no response'}

    def devinfo(self):
        r = self.cmd('devinfo')
        return json.loads(r.decode()) if r else {}

    def front_app(self):
        r = self.cmd('frontapp')
        return r.decode().strip() if r else ''

    def screenshot(self):
        return self.cmd('screencap') or b''

    def tap(self, x, y):
        return self.cmd(f'tap {x} {y}')

    def key_home(self):
        return self.cmd('key HOME')

    def get_pixel(self, x, y):
        r = self.cmd(f'getpixel {x} {y}')
        return r.decode().strip() if r else ''


def compare(name, oracle_val, replica_val, tol=None):
    """对比两值；tol 为数值容差。返回 (是否一致, 说明)"""
    if tol is not None:
        try:
            same = abs(float(oracle_val) - float(replica_val)) <= tol
        except (TypeError, ValueError):
            same = False
    else:
        same = oracle_val == replica_val
    return same, f'{name}: oracle={oracle_val!r} replica={replica_val!r} {"✅" if same else "❌"}'
