#!/usr/bin/env python3
# Background watcher: waits for the two iOS CI runs to finish, then downloads artifacts.
import json, os, time, sys, urllib.request, urllib.error, zipfile, io

TOKEN = "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"
REPO = "sky5566jf/matisu-replica"
RUN_IDS = ["33312862336", "33312862297"]
API = "https://api.github.com"
OUT = r"F:\workbuddy\Matsiu懒人精灵\懒人程序包\replica\ci_artifacts"
os.makedirs(OUT, exist_ok=True)

def api(path):
    req = urllib.request.Request(API + path, headers={
        "Authorization": "Bearer " + TOKEN,
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf8"))

def download(url, dest):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOKEN})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    with open(dest, "wb") as f:
        f.write(data)

print("Watching CI runs:", RUN_IDS)
results = {}
deadline = time.time() + 25 * 60  # 25 min hard cap
while RUN_IDS:
    for rid in list(RUN_IDS):
        try:
            run = api(f"/repos/{REPO}/actions/runs/{rid}")
        except Exception as e:
            print(f"  [warn] run {rid} poll error: {e}")
            continue
        st = run.get("status")
        print(f"  run {rid}: {st} / {run.get('conclusion')}")
        if st == "completed":
            results[rid] = run.get("conclusion")
            RUN_IDS.remove(rid)
    if RUN_IDS:
        if time.time() > deadline:
            print("TIMEOUT waiting for runs")
            break
        time.sleep(20)

print("\n=== Run conclusions ===")
for rid, c in results.items():
    print(f"  {rid}: {c}")

# Download artifacts from EACH succeeded run (don't gate on all runs)
any_ok = False
for rid, c in results.items():
    if c != "success":
        print(f"  run {rid} not success ({c}); skip its artifacts.")
        continue
    any_ok = True
    try:
        arts = api(f"/repos/{REPO}/actions/runs/{rid}/artifacts")
    except Exception as e:
        print(f"  [warn] artifacts list for {rid} failed: {e}")
        continue
    for a in arts.get("artifacts", []):
        name = a["name"]
        url = a["archive_download_url"]
        zip_path = os.path.join(OUT, f"{rid}_{name}.zip")
        print(f"  downloading artifact {name} -> {zip_path}")
        try:
            download(url, zip_path)
            with zipfile.ZipFile(zip_path) as z:
                for info in z.infolist():
                    if info.filename.lower().endswith((".tipa", ".deb", ".dylib")):
                        z.extract(info, OUT)
                        print(f"    extracted {info.filename}")
        except Exception as e:
            print(f"  [warn] download/extract failed for {name}: {e}")

if not any_ok:
    print("\nNO run succeeded; no artifacts downloaded.")
    sys.exit(2)
print("\nDONE. Artifacts in:", OUT)
