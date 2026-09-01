# Watch CI for the fix commit; download iOS artifacts via curl -L (avoids 401 from
# urllib forwarding the GitHub bearer token to Azure storage redirects).
import json, os, subprocess, sys, time, zipfile

TOKEN = "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"
REPO = "sky5566jf/matisu-replica"
SHA = "ddfef49"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ci_artifacts")
os.makedirs(OUT, exist_ok=True)


def api(path):
    out = subprocess.run(
        ["curl", "-s", "-H", "Authorization: Bearer " + TOKEN,
         "-H", "Accept: application/vnd.github+json",
         "https://api.github.com" + path],
        capture_output=True, text=True, timeout=60)
    return json.loads(out.stdout)


def find_ios_run():
    d = api("/repos/%s/actions/runs?per_page=10" % REPO)
    for r in d.get("workflow_runs", []):
        if r["head_sha"].startswith(SHA) and "iOS" in (r.get("name") or ""):
            return r
    return None


run = None
while True:
    run = find_ios_run()
    if run and run["status"] == "completed":
        break
    print("waiting... status=%s" % (run["status"] if run else "not-created"), flush=True)
    time.sleep(30)

rid = run["id"]
print("run %d finished: conclusion=%s" % (rid, run["conclusion"]), flush=True)
if run["conclusion"] != "success":
    # dump tail of logs for diagnosis
    subprocess.run("curl -sL -H \"Authorization: Bearer %s\" "
                   "\"https://api.github.com/repos/%s/actions/runs/%d/logs\" -o ci_fail3.log"
                   % (TOKEN, REPO, rid), shell=True, timeout=120)
    print("logs saved to ci_fail3.log", flush=True)
    sys.exit(2)

arts = api("/repos/%s/actions/runs/%d/artifacts" % (REPO, rid))
for a in arts.get("artifacts", []):
    name = a["name"]
    zpath = os.path.join(OUT, "%d_%s.zip" % (rid, name))
    print("downloading %s ..." % name, flush=True)
    subprocess.run("curl -sL -H \"Authorization: Bearer %s\" \"%s\" -o \"%s\""
                   % (TOKEN, a["archive_download_url"], zpath), shell=True, timeout=300)
    try:
        with zipfile.ZipFile(zpath) as z:
            for info in z.infolist():
                if info.filename.lower().endswith((".tipa", ".deb", ".dylib")):
                    z.extract(info, OUT)
                    print("  extracted " + info.filename, flush=True)
    except Exception as e:
        print("  [warn] extract failed: %s" % e, flush=True)

print("DONE. artifacts in: " + OUT, flush=True)
