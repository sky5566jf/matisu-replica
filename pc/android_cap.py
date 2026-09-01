# -*- coding: utf-8 -*-
"""
MatisuAuto Android 图色/节点助手（对齐 懒人精灵 高级版 2.0.1 真实文档）

由 device_bridge.js 经 execFileSync 调用。参数统一从临时 JSON 文件读取，
避免 Windows shell 的引号/管道转义问题。

=== 颜色格式（重要） ===
懒人精灵图色系 API 的 16 进制颜色格式是 "BBGGRR"（蓝-绿-红），不是 RRGGBB。
  "aabbcc"  ->  B=0xaa  G=0xbb  R=0xcc
多色用 "|" 分隔；偏色用 "-" 分隔，如 "FFFFFF-000000|123456"。
（例外：imgui / 虚拟屏 系列用 0xAARRGGBB，不走本脚本。）

=== 子命令 ===
  keepcapture       {}                                        -> {ok}          截图落盘缓存
  releasecapture    {}                                        -> {ok}          删除缓存
  findcolor         {reg,color,dir,sim}                        -> {ret,x,y}
  findmulticolor    {reg,first,offset,dir,sim}                 -> {x,y}
  findmulticolorall {reg,first,offset,dir,sim}                 -> {list:[{x,y}]}
  cmpcolor          {x,y,color,sim}                            -> {ret}
  cmpcolorex        {multicolor,sim}                           -> {ret}
  getcolornum       {reg,color,sim}                            -> {num}
  colordiff         {c1,c2}                                    -> {diff}
  colortorgb        {c}                                        -> {r,g,b}
  getpixelcolor     {x,y,type}                                 -> {color}
  getscreenpixel    {reg}                                      -> {w,h,arr:[BBGGRR...]}
  isdisplaydead     {reg,time}                                 -> {ret}
  snapshot          {path,reg}                                 -> {path}
  getnodes          {preds,mode,index}                         -> {node} / {list}
  nodexml / dump    -                                          -> 原始 XML(stdout, 非 JSON)
  ocr               {lang,reg}                                 -> {text}

reg = [x1,y1,x2,y2]，四者全 0 或缺省表示全屏（与懒人精灵一致）。
坐标空间 = screencap 像素 = 设备物理像素。
"""
import sys, os, io, re, json, time, tempfile, subprocess

ADB = os.environ.get("MATISU_ADB", "")
DEVICE = os.environ.get("MATISU_DEVICE", "")

# 关键坑：Windows 上 os.path.join 会给 Linux 设备路径插入反斜杠，
# 设备侧会收到 "/data/local/tmp\ui.xml" 而报文件不存在。设备侧路径必须写字面量 POSIX 常量。
UI_XML = "/data/local/tmp/ui.xml"

# keepCapture 缓存：本脚本是「一次调用一进程」，进程内变量无法跨调用保活，必须落盘。
CACHE_PNG = os.path.join(tempfile.gettempdir(), "matisu_keepcap.png")

try:
    from PIL import Image
except Exception as e:
    print(json.dumps({"error": "PIL 不可用: %s" % e}, ensure_ascii=False))
    sys.exit(1)

try:
    import numpy as np
except Exception:
    np = None


# ---------------------------------------------------------------- adb / 截图

def adb(args, timeout=30):
    return subprocess.run(
        [ADB, "-s", DEVICE] + [str(a) for a in args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


def grab():
    """强制新截一张图（不走缓存）。"""
    p = adb(["exec-out", "screencap", "-p"])
    if p.returncode != 0 or not p.stdout:
        raise RuntimeError("screencap 失败: " + p.stderr.decode("utf-8", "ignore"))
    return Image.open(io.BytesIO(p.stdout)).convert("RGB")


def capture():
    """有 keepCapture 缓存则复用，否则新截。"""
    if os.path.exists(CACHE_PNG):
        try:
            return Image.open(CACHE_PNG).convert("RGB")
        except Exception:
            pass
    return grab()


def region_of(img, reg):
    """reg=[x1,y1,x2,y2]；四者全 0 / 缺省 => 全屏。返回 (crop, ox, oy)。"""
    w, h = img.size
    if reg and len(reg) >= 4:
        x1, y1, x2, y2 = [int(v) for v in reg[:4]]
        if not (x1 == 0 and y1 == 0 and x2 == 0 and y2 == 0):
            x1 = max(0, min(x1, w - 1)); y1 = max(0, min(y1, h - 1))
            x2 = max(x1 + 1, min(x2, w)); y2 = max(y1 + 1, min(y2, h))
            return img.crop((x1, y1, x2, y2)), x1, y1
    return img, 0, 0


def as_arr(img):
    """PIL -> numpy int16 (h,w,3) RGB；无 numpy 时返回 None。"""
    if np is None:
        return None
    return np.asarray(img, dtype=np.int16)


# ---------------------------------------------------------------- 颜色解析

def to_int(c):
    """接受 int / "aabbcc" / "0xaabbcc" -> int"""
    if isinstance(c, (int, float)):
        return int(c) & 0xFFFFFF
    s = str(c).strip()
    if s.lower().startswith("0x"):
        s = s[2:]
    return int(s, 16) & 0xFFFFFF


def spec_rgb(c):
    """懒人精灵 BBGGRR -> (r,g,b)"""
    v = to_int(c)
    return (v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF)


def rgb_spec(r, g, b):
    """(r,g,b) -> BBGGRR int"""
    return ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF)


def parse_one(spec):
    """"778787" / "778787-101010" -> (r,g,b,dr,dg,db)，偏色即每通道容差。"""
    spec = str(spec).strip()
    if "-" in spec:
        base, dev = spec.split("-", 1)
    else:
        base, dev = spec, "000000"
    r, g, b = spec_rgb(base)
    dr, dg, db = spec_rgb(dev)
    return (r, g, b, dr, dg, db)


def parse_multi(spec):
    """多色 "|" 分隔 -> [(r,g,b,dr,dg,db), ...]"""
    return [parse_one(x) for x in str(spec).split("|") if str(x).strip() != ""]


def sim_tol(sim):
    """相似度 0-1 -> 每通道容差 0-255。"""
    try:
        s = float(sim)
    except Exception:
        s = 0.9
    if s > 1:
        s = 1.0
    if s < 0:
        s = 0.0
    return int(round((1.0 - s) * 255))


def parse_offset(offset):
    """
    偏移色串 -> [(dx, dy, [(r,g,b,dr,dg,db), ...]), ...]

    格式: "10|11|2F9772-000000|123456-101010,23|57|353535"
    注意：'|' 既分隔 dx/dy 也分隔多色。前两段是 dx,dy，**其余全部 join 回 '|'** 才是颜色串。
    """
    out = []
    for part in str(offset).split(","):
        part = part.strip()
        if not part:
            continue
        a = part.split("|")
        if len(a) < 3:
            continue
        try:
            dx, dy = int(a[0]), int(a[1])
        except Exception:
            continue
        out.append((dx, dy, parse_multi("|".join(a[2:]))))
    return out


# ---------------------------------------------------------------- 掩码 / 方向

def mask_of(arr, specs, tol):
    """任一 spec 命中即 True。返回 (h,w) bool 掩码。"""
    m = None
    for (r, g, b, dr, dg, db) in specs:
        cur = ((np.abs(arr[:, :, 0] - r) <= max(dr, tol)) &
               (np.abs(arr[:, :, 1] - g) <= max(dg, tol)) &
               (np.abs(arr[:, :, 2] - b) <= max(db, tol)))
        m = cur if m is None else (m | cur)
    if m is None:
        m = np.zeros(arr.shape[:2], dtype=bool)
    return m


def pick_dir(mask, dirn):
    """
    按懒人精灵查找方向取第一个命中点。
      0 左上->右下  1 中心->四周  2 右下->左上  3 左下->右上  4 右上->左下
    返回 (x, y) 或 None。
    """
    ys, xs = np.nonzero(mask)
    if len(ys) == 0:
        return None
    d = int(dirn or 0)
    if d == 1:
        h, w = mask.shape
        cx, cy = w / 2.0, h / 2.0
        i = int(np.argmin((xs - cx) ** 2 + (ys - cy) ** 2))
    elif d == 2:                                  # y 降序, x 降序
        i = int(np.lexsort((-xs, -ys))[0])
    elif d == 3:                                  # y 降序, x 升序
        i = int(np.lexsort((xs, -ys))[0])
    elif d == 4:                                  # y 升序, x 降序
        i = int(np.lexsort((-xs, ys))[0])
    else:                                         # 0: y 升序, x 升序（nonzero 本就行优先）
        i = 0
    return (int(xs[i]), int(ys[i]))


def need_numpy():
    if np is None:
        raise RuntimeError("numpy 不可用，图色功能需要 numpy（pip install numpy）")


# ---------------------------------------------------------------- 图色实现

def do_findcolor(req):
    """findColor(x1,y1,x2,y2,color,dir,sim) -> ret,x,y ；ret 为命中的多色索引(1起)。"""
    need_numpy()
    crop, ox, oy = region_of(capture(), req.get("reg"))
    arr = as_arr(crop)
    tol = sim_tol(req.get("sim", 0.9))
    specs = parse_multi(req["color"])
    masks = [mask_of(arr, [s], tol) for s in specs]
    comb = masks[0].copy()
    for m in masks[1:]:
        comb |= m
    pt = pick_dir(comb, req.get("dir", 0))
    if not pt:
        return {"ret": -1, "x": -1, "y": -1}
    x, y = pt
    ret = 1
    for i, m in enumerate(masks):
        if m[y, x]:
            ret = i + 1
            break
    return {"ret": ret, "x": x + ox, "y": y + oy}


def do_findmulticolor(req, want_all=False):
    """findMultiColor(x1,y1,x2,y2,first,offset,dir,sim) -> x,y"""
    need_numpy()
    crop, ox, oy = region_of(capture(), req.get("reg"))
    arr = as_arr(crop)
    h, w = arr.shape[:2]
    tol = sim_tol(req.get("sim", 0.9))

    res = mask_of(arr, parse_multi(req["first"]), tol)
    for (dx, dy, specs) in parse_offset(req.get("offset", "")):
        om = mask_of(arr, specs, tol)
        sh = np.zeros_like(om)
        # sh[y,x] = om[y+dy, x+dx]
        y0, y1 = max(0, -dy), min(h, h - dy)
        x0, x1 = max(0, -dx), min(w, w - dx)
        if y1 > y0 and x1 > x0:
            sh[y0:y1, x0:x1] = om[y0 + dy:y1 + dy, x0 + dx:x1 + dx]
        res &= sh
        if not res.any():
            break

    if want_all:
        ys, xs = np.nonzero(res)
        return {"list": [{"x": int(xs[i]) + ox, "y": int(ys[i]) + oy} for i in range(len(ys))]}
    pt = pick_dir(res, req.get("dir", 0))
    if not pt:
        return {"x": -1, "y": -1}
    return {"x": pt[0] + ox, "y": pt[1] + oy}


def do_cmpcolor(req):
    """cmpColor(x,y,color,sim) -> 1/0"""
    img = capture()
    x, y = int(req["x"]), int(req["y"])
    w, h = img.size
    if x < 0 or y < 0 or x >= w or y >= h:
        return {"ret": 0}
    pr, pg, pb = img.load()[x, y]
    tol = sim_tol(req.get("sim", 0.9))
    for (r, g, b, dr, dg, db) in parse_multi(req["color"]):
        if abs(pr - r) <= max(dr, tol) and abs(pg - g) <= max(dg, tol) and abs(pb - b) <= max(db, tol):
            return {"ret": 1}
    return {"ret": 0}


def do_cmpcolorex(req):
    """cmpColorEx("x|y|color[|color2],x|y|color", sim) -> 1/0（全部命中才 1）"""
    img = capture()
    px = img.load()
    w, h = img.size
    tol = sim_tol(req.get("sim", 0.9))
    pts = [p for p in str(req["multicolor"]).split(",") if p.strip()]
    if not pts:
        return {"ret": 0}
    for pt in pts:
        a = pt.split("|")
        if len(a) < 3:
            return {"ret": 0}
        try:
            x, y = int(a[0]), int(a[1])
        except Exception:
            return {"ret": 0}
        if x < 0 or y < 0 or x >= w or y >= h:
            return {"ret": 0}
        pr, pg, pb = px[x, y]
        ok = False
        # 前两段之后的全部 join 回 '|' 才是颜色串（多色仍用 '|' 分隔）
        for (r, g, b, dr, dg, db) in parse_multi("|".join(a[2:])):
            if abs(pr - r) <= max(dr, tol) and abs(pg - g) <= max(dg, tol) and abs(pb - b) <= max(db, tol):
                ok = True
                break
        if not ok:
            return {"ret": 0}
    return {"ret": 1}


def do_getcolornum(req):
    """getColorNum(x1,y1,x2,y2,color,sim) -> 匹配像素点个数"""
    need_numpy()
    crop, _, _ = region_of(capture(), req.get("reg"))
    arr = as_arr(crop)
    m = mask_of(arr, parse_multi(req["color"]), sim_tol(req.get("sim", 0.9)))
    return {"num": int(m.sum())}


def do_colordiff(req):
    r1, g1, b1 = spec_rgb(req["c1"])
    r2, g2, b2 = spec_rgb(req["c2"])
    return {"diff": abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)}


def do_colortorgb(req):
    r, g, b = spec_rgb(req["c"])
    return {"r": r, "g": g, "b": b}


def do_getpixelcolor(req):
    """getPixelColor(x,y,[type])：type=1 返回整数，否则返回 16 进制字符串（均为 BBGGRR）。"""
    img = capture()
    x, y = int(req["x"]), int(req["y"])
    w, h = img.size
    if x < 0 or y < 0 or x >= w or y >= h:
        return {"color": 0 if int(req.get("type", 0)) == 1 else "000000"}
    pr, pg, pb = img.load()[x, y]
    c = rgb_spec(pr, pg, pb)
    if int(req.get("type", 0)) == 1:
        return {"color": c}
    return {"color": "%06X" % c}


def do_getscreenpixel(req):
    """getScreenPixel(x1,y1,x2,y2) -> w,h,arr（BBGGRR 整数，行优先）"""
    need_numpy()
    crop, _, _ = region_of(capture(), req.get("reg"))
    arr = as_arr(crop).astype(np.int32)
    h, w = arr.shape[:2]
    flat = ((arr[:, :, 2] << 16) | (arr[:, :, 1] << 8) | arr[:, :, 0]).reshape(-1)
    return {"w": int(w), "h": int(h), "arr": flat.tolist()}


def do_isdisplaydead(req):
    """isDisplayDead(x1,y1,x2,y2,time)：阻塞至区域像素变化；true=未变化(死屏)。"""
    need_numpy()
    reg = req.get("reg")
    secs = float(req.get("time", 5) or 5)
    base = as_arr(region_of(grab(), reg)[0])
    deadline = time.time() + secs
    while time.time() < deadline:
        time.sleep(0.4)
        try:
            cur = as_arr(region_of(grab(), reg)[0])
        except Exception:
            continue
        if cur.shape != base.shape or not np.array_equal(cur, base):
            return {"ret": False}
    return {"ret": True}


def do_snapshot(req):
    """
    snapShot(path,[l,t,r,b])。
    path 为 POSIX 绝对路径（如 /sdcard/a.png）时，落地到临时文件后 adb push 到设备，
    保持与真机语义一致；否则按 PC 本地路径保存。
    """
    crop, _, _ = region_of(capture(), req.get("reg"))
    path = str(req.get("path") or "matisu_shot.png")
    if path.startswith("/"):
        local = os.path.join(tempfile.gettempdir(), "matisu_snap.png")
        crop.save(local)
        p = adb(["push", local, path])
        if p.returncode != 0:
            return {"path": local, "pushed": False,
                    "error": p.stderr.decode("utf-8", "ignore").strip()}
        return {"path": path, "pushed": True}
    crop.save(path)
    return {"path": os.path.abspath(path), "pushed": False}


# ---------------------------------------------------------------- 节点

def dump_xml():
    raw = b""
    for _ in range(3):
        adb(["shell", "uiautomator", "dump", UI_XML])
        time.sleep(0.3)
        raw = adb(["exec-out", "cat", UI_XML]).stdout or b""
        if b"<node" in raw:
            break
    return raw


def parse_nodes():
    """
    解析 uiautomator XML 为扁平节点列表。
    额外重建 parent / index / depth / childCount / childs —— uiautomator XML 只有嵌套结构，
    这些属性得靠标签的进出栈自己算。
    """
    raw = dump_xml()
    try:
        text = raw.decode("utf-8", "ignore")
    except Exception:
        return []
    if "<node" not in text:
        return []

    nodes = []
    stack = []   # 父节点索引栈
    # 逐个匹配开/自闭合 node 标签与闭合标签，才能正确维护层级
    for m in re.finditer(r'<node\b([^>]*?)(/?)>|</node>', text):
        if m.group(0) == "</node>":
            if stack:
                stack.pop()
            continue
        attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', m.group(1)))
        nums = re.findall(r'-?\d+', attrs.get("bounds", ""))
        if len(nums) >= 4:
            x1, y1, x2, y2 = [int(n) for n in nums[:4]]
        else:
            x1 = y1 = x2 = y2 = 0
        parent = stack[-1] if stack else -1
        idx = len(nodes)
        n = {
            "_i": idx,
            "_parent": parent,
            "_depth": len(stack),
            "_index": int(attrs.get("index", "0") or "0"),
            "_drawingOrder": int(attrs.get("drawing-order", "0") or "0"),
            "_text": attrs.get("text", ""),
            "_id": attrs.get("resource-id", ""),
            "_desc": attrs.get("content-desc", ""),
            "_className": attrs.get("class", ""),
            "_packageName": attrs.get("package", ""),
            "_x1": x1, "_y1": y1, "_x2": x2, "_y2": y2,
            "_clickable": attrs.get("clickable") == "true",
            "_longClickable": attrs.get("long-clickable") == "true",
            "_scrollable": attrs.get("scrollable") == "true",
            "_selected": attrs.get("selected") == "true",
            "_enabled": attrs.get("enabled") == "true",
            "_focusable": attrs.get("focusable") == "true",
            "_focused": attrs.get("focused") == "true",
            "_checkable": attrs.get("checkable") == "true",
            "_checked": attrs.get("checked") == "true",
            "_password": attrs.get("password") == "true",
            "_visibleToUser": attrs.get("visible-to-user", "true") == "true",
            "_childs": [],
        }
        nodes.append(n)
        if parent >= 0:
            nodes[parent]["_childs"].append(idx)
        if m.group(2) != "/":
            stack.append(idx)

    for n in nodes:
        n["_childCount"] = len(n["_childs"])
    return nodes


_STR_KEYS = {"id": "_id", "text": "_text", "desc": "_desc",
             "className": "_className", "packageName": "_packageName"}
_BOOL_KEYS = ("visibleToUser", "selected", "clickable", "longClickable", "enabled",
              "password", "scrollable", "checked", "checkable", "focusable", "focused")
_INT_KEYS = {"drawingOrder": "_drawingOrder", "depth": "_depth", "index": "_index"}


def node_match(n, preds):
    for p in preds:
        k, v, mode = p.get("k"), p.get("v"), p.get("m", "eq")
        if k in _STR_KEYS:
            s = n.get(_STR_KEYS[k]) or ""
            v = "" if v is None else str(v)
            if mode == "contains":
                if v not in s: return False
            elif mode == "startsWith":
                if not s.startswith(v): return False
            elif mode == "endsWith":
                if not s.endswith(v): return False
            elif mode == "matches":
                try:
                    if not re.search(v, s): return False
                except re.error:
                    return False
            else:
                if s != v: return False
        elif k == "bounds":
            l, t, r, b = [int(x) for x in v]
            if not (n["_x1"] == l and n["_y1"] == t and n["_x2"] == r and n["_y2"] == b):
                return False
        elif k == "boundsInside":
            l, t, r, b = [int(x) for x in v]
            if not (n["_x1"] >= l and n["_y1"] >= t and n["_x2"] <= r and n["_y2"] <= b):
                return False
        elif k in _INT_KEYS:
            if int(n.get(_INT_KEYS[k], 0)) != int(v):
                return False
        elif k in _BOOL_KEYS:
            if bool(n.get("_" + k, False)) != bool(v):
                return False
    return True


def pub(n, nodes):
    """裁剪为对外 JSON（去掉内部 childs 索引，保留可用信息）。"""
    if n is None:
        return None
    return {
        "i": n["_i"], "parent": n["_parent"], "depth": n["_depth"],
        "index": n["_index"], "drawingOrder": n["_drawingOrder"],
        "text": n["_text"], "id": n["_id"], "desc": n["_desc"],
        "className": n["_className"], "packageName": n["_packageName"],
        "left": n["_x1"], "top": n["_y1"], "right": n["_x2"], "bottom": n["_y2"],
        "cx": (n["_x1"] + n["_x2"]) // 2, "cy": (n["_y1"] + n["_y2"]) // 2,
        "childCount": n["_childCount"], "childs": n["_childs"],
        "clickable": n["_clickable"], "longClickable": n["_longClickable"],
        "scrollable": n["_scrollable"], "selected": n["_selected"],
        "enabled": n["_enabled"], "focusable": n["_focusable"], "focused": n["_focused"],
        "checkable": n["_checkable"], "checked": n["_checked"],
        "password": n["_password"], "visibleToUser": n["_visibleToUser"],
    }


def do_getnodes(req):
    """
    mode = one | once | all | index
      one   取第一个
      once  取第 index 个（0 起）
      all   全部
      index 直接按扁平索引取（供 node:parent()/node:childs() 复用同一棵树）
    """
    nodes = parse_nodes()
    mode = req.get("mode", "all")
    if mode == "index":
        want = req.get("indexes") or []
        return {"list": [pub(nodes[i], nodes) for i in want if 0 <= i < len(nodes)]}
    matched = [n for n in nodes if node_match(n, req.get("preds", []))]
    if mode == "one":
        return {"node": pub(matched[0], nodes) if matched else None}
    if mode == "once":
        i = int(req.get("index", 0) or 0)
        return {"node": pub(matched[i], nodes) if 0 <= i < len(matched) else None}
    return {"list": [pub(n, nodes) for n in matched]}


def do_ocr(req):
    try:
        import pytesseract
    except Exception:
        return {"text": "", "error": "pytesseract 未安装（pip install pytesseract + tesseract-ocr）"}
    crop, _, _ = region_of(capture(), req.get("reg"))
    try:
        return {"text": pytesseract.image_to_string(crop, lang=req.get("lang", "chi_sim+eng"))}
    except Exception as e:
        return {"text": "", "error": str(e)}


# ---------------------------------------------------------------- 入口

_HANDLERS = {
    "findcolor":         do_findcolor,
    "findmulticolor":    lambda r: do_findmulticolor(r, False),
    "findmulticolorall": lambda r: do_findmulticolor(r, True),
    "cmpcolor":          do_cmpcolor,
    "cmpcolorex":        do_cmpcolorex,
    "getcolornum":       do_getcolornum,
    "colordiff":         do_colordiff,
    "colortorgb":        do_colortorgb,
    "getpixelcolor":     do_getpixelcolor,
    "getscreenpixel":    do_getscreenpixel,
    "isdisplaydead":     do_isdisplaydead,
    "snapshot":          do_snapshot,
    "getnodes":          do_getnodes,
    "ocr":               do_ocr,
}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "no subcommand"}))
        sys.exit(1)
    sub = sys.argv[1]

    if sub == "keepcapture":
        grab().save(CACHE_PNG)
        print(json.dumps({"ok": True, "path": CACHE_PNG}))
        return
    if sub == "releasecapture":
        try:
            if os.path.exists(CACHE_PNG):
                os.remove(CACHE_PNG)
        except Exception:
            pass
        print(json.dumps({"ok": True}))
        return
    if sub in ("nodexml", "dump"):
        raw = dump_xml()
        try:
            sys.stdout.buffer.write(raw)
        except Exception:
            sys.stdout.write(raw.decode("utf-8", "ignore"))
        return

    if len(sys.argv) < 3:
        print(json.dumps({"error": "missing json arg file"}))
        sys.exit(1)
    with open(sys.argv[2], "r", encoding="utf-8") as f:
        req = json.load(f)

    fn = _HANDLERS.get(sub)
    if fn is None:
        print(json.dumps({"error": "unknown subcommand: %s" % sub}))
        sys.exit(1)
    try:
        print(json.dumps(fn(req), ensure_ascii=False))
    except Exception as e:
        print(json.dumps({"error": "%s: %s" % (type(e).__name__, e)}, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
