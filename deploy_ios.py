# MatisuAuto iOS one-shot deploy: CI artifact -> 巨魔下载站 -> 8588 install+launch -> probe
# usage: python deploy_ios.py <sha-prefix>
import json, os, shutil, socket, subprocess, sys, time, zipfile

TOKEN = "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"
REPO = "sky5566jf/matisu-replica"
SHA = sys.argv[1] if len(sys.argv) > 1 else "2bdb35a"
DEVICE = "192.69.0.38"
STATION_DIR = r"E:\lmp\ipa"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "ci_artifacts")


def api(path):
    out = subprocess.run(["curl", "-s", "-H", "Authorization: Bearer " + TOKEN,
                          "-H", "Accept: application/vnd.github+json",
                          "https://api.github.com" + path],
                         capture_output=True, text=True, timeout=60)
    return json.loads(out.stdout)


def wait_ci():
    while True:
        d = api("/repos/%s/actions/runs?per_page=10" % REPO)
        run = None
        for r in d.get("workflow_runs", []):
            if r["head_sha"].startswith(SHA) and "iOS" in (r.get("name") or ""):
                run = r
        if run and run["status"] == "completed":
            print("CI run %d: %s" % (run["id"], run["conclusion"]), flush=True)
            if run["conclusion"] != "success":
                sys.exit("CI failed")
            return run["id"]
        print("CI waiting...", flush=True)
        time.sleep(30)


def download(rid):
    os.makedirs(OUT, exist_ok=True)
    arts = api("/repos/%s/actions/runs/%d/artifacts" % (REPO, rid))
    for a in arts.get("artifacts", []):
        if a["name"] != "matisu-auto-ios":
            continue
        zpath = os.path.join(OUT, "%d_ios.zip" % rid)
        subprocess.run(["curl", "-sL", "--retry", "5", "--retry-delay", "3",
                        "--connect-timeout", "30",
                        "-H", "Authorization: Bearer " + TOKEN,
                        a["archive_download_url"], "-o", zpath],
                       timeout=900)
        with zipfile.ZipFile(zpath) as z:
            for info in z.infolist():
                if info.filename.endswith(".tipa"):
                    z.extract(info, OUT)
    tipa = os.path.join(OUT, "matisu-auto.tipa")
    print("tipa size:", os.path.getsize(tipa), flush=True)
    return tipa


def deploy(tipa):
    # 注意：8588 /install 在这台设备上经常走 LSApplicationWorkspace 兜底，
    # 会拉起 TrollStore 图形界面的下载弹窗（modal 霸占屏幕、最终超时），
    # 因此不再用它安装；仅把 tipa 拷到下载站，实际安装走 SSH trollstorehelper。
    dst = os.path.join(STATION_DIR, "matisu-auto.tipa")
    shutil.copy(tipa, dst)
    print("tipa copied to station (install via SSH separately)", flush=True)


def probe(cmd, timeout=15):
    s = socket.create_connection((DEVICE, 18182), timeout=timeout)
    s.settimeout(timeout)
    s.sendall((cmd + "\n").encode())
    head = b""
    while len(head) < 4:
        c = s.recv(4 - len(head))
        if not c:
            break
        head += c
    if len(head) < 4:
        s.close()
        return None
    n = int.from_bytes(head, "big")
    data = b""
    while len(data) < n:
        c = s.recv(min(65536, n - len(data)))
        if not c:
            break
        data += c
    s.close()
    return data


rid = wait_ci()
tipa = download(rid)
deploy(tipa)
time.sleep(2)

r = probe("diag")
print("diag ->", r.decode() if r else "EMPTY", flush=True)

r = probe("uinode")
if r:
    nodes = json.loads(r.decode())
    print("uinode -> %d nodes" % len(nodes), flush=True)
    for nd in nodes[:5]:
        print("  [%s] %s \"%s\" pkg=%s" % (nd.get("i"), nd.get("className"),
                                           (nd.get("text") or "")[:24], nd.get("packageName")), flush=True)
else:
    print("uinode -> EMPTY", flush=True)

r = probe("screencap")
if r and r[:4] == b"\x89PNG":
    p = os.path.join(OUT, "device_screen.png")
    open(p, "wb").write(r)
    print("screencap -> PNG %d bytes -> %s" % (len(r), p), flush=True)
else:
    print("screencap -> FAIL", flush=True)
print("DEPLOY+PROBE DONE", flush=True)
