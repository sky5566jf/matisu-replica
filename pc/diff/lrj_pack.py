#!/usr/bin/env python3
"""打 GBK zip（含目录条目）的 lrj 工程包"""
import zlib, struct, io

def zip_gbk(entries):
    out = io.BytesIO()
    centrals = []
    for name, data, is_dir in entries:
        crc = zlib.crc32(data) & 0xffffffff
        offset = out.tell()
        method = 0 if is_dir else 8
        comp = b'' if is_dir else zlib.compress(data, 9)[2:-4]
        ext_attr = 0x10 if is_dir else 0   # MS-DOS directory bit
        out.write(struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 0, method, 0, 0,
                              crc, len(comp), 0 if is_dir else len(data), len(name), 0))
        out.write(name)
        out.write(comp)
        centrals.append((name, crc, len(comp), 0 if is_dir else len(data), offset, method, ext_attr))
    cd_start = out.tell()
    for name, crc, clen, ulen, offset, method, ext_attr in centrals:
        out.write(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 20, 0, method, 0, 0,
                              crc, clen, ulen, len(name), 0, 0, 0, 0, ext_attr, offset))
        out.write(name)
    cd_end = out.tell()
    out.write(struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(centrals), len(centrals),
                          cd_end - cd_start, cd_start, 0))
    return out.getvalue()


def build_lrj(entry_json: bytes, files: list, version: bytes = b'122') -> bytes:
    """files: [(name_gbk_bytes, data)]  目录条目自动补齐"""
    entries = [(b'entry.json', entry_json, False), (b'version', version, False)]
    seen_dirs = set()
    for name, data in files:
        # 补齐中间目录条目
        parts = name.split(b'/')
        for i in range(1, len(parts)):
            d = b'/'.join(parts[:i]) + b'/'
            if d not in seen_dirs:
                seen_dirs.add(d)
                entries.append((d, b'', True))
        entries.append((name, data, False))
    return zip_gbk(entries)
