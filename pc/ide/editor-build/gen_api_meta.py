# -*- coding: utf-8 -*-
# gen_api_meta.py — 从 common/lua-api/core.lua 生成 EmmyLua 注解(meta)文件
# 供 lua-language-server 作为 workspace.library 注入，实现 700 API 补全/hover
import os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.normpath(os.path.join(ROOT, '..', '..', '..', 'common', 'lua-api', 'core.lua'))
OUT_DIR = os.path.normpath(os.path.join(ROOT, '..', 'lsp', 'meta'))
OUT = os.path.join(OUT_DIR, 'matisu.lua')

src = open(CORE, encoding='utf-8').read()
lines = src.split('\n')

def find_sig(comment, name):
    """从注释中提取 name(a,b,c) 形参表；找不到返回 None"""
    m = re.search(re.escape(name) + r'\(([^)]*)\)', comment)
    if not m:
        return None
    params = [p.strip() for p in m.group(1).split(',') if p.strip()]
    # 过滤非法标识符
    if all(re.match(r'^[A-Za-z_]\w*(\?)?$', p) for p in params):
        return [p.rstrip('?') for p in params]
    return None

def emit_fn(out, name, params, comment, prefix=''):
    """输出一个全局/模块函数注解"""
    doc = comment.strip()
    if doc.startswith('--'):
        doc = doc[2:].strip()
    if doc:
        for ln in doc.split('；'):
            ln = ln.strip()
            if ln:
                out.append('---' + ln)
    if params:
        for p in params:
            out.append('---@param %s any' % p)
        plist = ', '.join(params)
    else:
        plist = '...'
    out.append('function %s%s(%s) end' % (prefix, name, plist))
    out.append('')

out = []
out.append('---@meta')
out.append('-- MatisuAuto 统一 Lua API 注解（由 gen_api_meta.py 从 core.lua 自动生成，勿手改）')
out.append('-- 对齐「懒人精灵 高级版 2.0.1」契约；供 lua-language-server workspace.library 使用')
out.append('')

# ---------- 1) 全局 _stub 函数 & 模块表 ----------
i = 0
pending_comments = []
cur_table = None
n_global = 0
n_module = 0
while i < len(lines):
    ln = lines[i]
    stripped = ln.strip()
    # 注释行：缓存（可能是文档）
    if stripped.startswith('--') and '=====' not in stripped:
        pending_comments.append(stripped)
        i += 1
        continue
    # 分节标题行（-- ===...）：清空缓存并当作分类注释跳过
    if stripped.startswith('--') and '=====' in stripped:
        pending_comments = []
        i += 1
        continue
    # 表开始：xxx = {
    m = re.match(r'^(\w+)\s*=\s*\{\s*$', ln)
    if m and m.group(1) in ('ui', 'nodeLib', 'imeLib', 'cipher', 'network', 'json'):
        cur_table = m.group(1)
        out.append('%s = {}' % cur_table)
        out.append('')
        pending_comments = []
        i += 1
        continue
    # 表结束
    if cur_table and stripped == '}':
        cur_table = None
        pending_comments = []
        i += 1
        continue
    # 成员：key = _stub("mod.key")
    m = re.match(r'^\s*(\w+)\s*=\s*_stub\("([^"]+)"\)', ln)
    if m:
        key, full = m.group(1), m.group(2)
        comment = ' '.join(pending_comments)
        params = find_sig(comment, full.split('.')[-1]) or find_sig(comment, key)
        if cur_table:
            emit_fn(out, key, params, comment, prefix=cur_table + '.')
            n_module += 1
        else:
            emit_fn(out, key, params, comment)
            n_global += 1
        pending_comments = []
        i += 1
        continue
    # 真实实现的全局函数（如 colorToRGB）：仅注册名字+形参
    m = re.match(r'^function\s+(\w+)\s*\(([^)]*)\)', ln)
    if m and not cur_table:
        name = m.group(1)
        params = [p.strip() for p in m.group(2).split(',') if p.strip()]
        comment = ' '.join(pending_comments)
        emit_fn(out, name, params, comment)
        n_global += 1
        pending_comments = []
        i += 1
        continue
    # 非注释非空行 → 注释缓存失效
    if stripped and not stripped.startswith('--'):
        pending_comments = []
    i += 1

# ---------- 2) 节点选择器 / 节点对象 ----------
spec_fns = re.findall(r'\{\s*fn\s*=\s*"(\w+)"', src)
node_methods = re.findall(r'Node\.(\w+)\s*=\s*function\(self\s*([^)]*)\)\s*return\s*([^\n]+?)\s*end', src)

out.append('-- ============================================================')
out.append('-- 节点选择器（链式）与节点对象')
out.append('-- ============================================================')
out.append('')
out.append('---@class MaNode 界面节点对象（由选择器 findOne/findAll/findOnce 取得）')
out.append('local _MaNode = {}')

ret_map = {
    'nil': None,
    '0': 'integer',
    '0, 0, 0, 0': 'integer, integer, integer, integer',
    '{}': 'table',
    '"{}"': 'string',
    'false': 'boolean',
}
for meth, args, ret in node_methods:
    args = args.strip()
    if args.startswith(','):
        args = args[1:].strip()
    plist = [a.strip() for a in args.split(',') if a.strip()] if args else []
    for p in plist:
        out.append('---@param %s any' % p)
    r = ret_map.get(ret.strip())
    if r:
        out.append('---@return %s' % r)
    out.append('function _MaNode:%s(%s) end' % (meth, ', '.join(plist)))
    out.append('')

out.append('---@class MaSelector 节点选择器（全局工厂函数创建，谓词链式叠加）')
out.append('local _MaSelector = {}')
for fn in spec_fns:
    out.append('---@param v any')
    out.append('---@return MaSelector self 链式返回自身')
    out.append('function _MaSelector:%s(v) end' % fn)
    out.append('')
out.append('---@param timeout integer? 毫秒')
out.append('---@return MaNode? node 找到的节点，超时为 nil')
out.append('function _MaSelector:findOne(timeout) end')
out.append('')
out.append('---@param timeout integer? 毫秒')
out.append('---@return MaNode[] nodes 节点数组')
out.append('function _MaSelector:findAll(timeout) end')
out.append('')
out.append('---@param index integer? 第几个匹配（默认 0）')
out.append('---@return MaNode? node')
out.append('function _MaSelector:findOnce(index) end')
out.append('')
out.append('-- 41 个全局选择器工厂函数')
for fn in spec_fns:
    out.append('---@param v any 匹配值')
    out.append('---@return MaSelector sel 新选择器（已含首个谓词）')
    out.append('function %s(v) end' % fn)
    out.append('')

# ---------- 3) console / log ----------
out.append('console = {')
out.append('  ---@param ... any')
out.append('  log = function(...) end,')
out.append('  ---@param ... any')
out.append('  error = function(...) end,')
out.append('}')
out.append('')
out.append('---@param ... any')
out.append('function log(...) end')
out.append('')

os.makedirs(OUT_DIR, exist_ok=True)
open(OUT, 'w', encoding='utf-8').write('\n'.join(out))
print('OK -> %s' % OUT)
print('global=%d module=%d selector_fns=%d node_methods=%d total_lines=%d'
      % (n_global, n_module, len(spec_fns), len(node_methods), len(out)))
