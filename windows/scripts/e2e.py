#!/usr/bin/env python3
"""End-to-end scenarios for Nexus for Windows, in a sandboxed fake home.

  python windows/scripts/e2e.py --exe "C:/Program Files/Nexus/Nexus.exe"       # installed app (headless)
  python windows/scripts/e2e.py --cmd "dotnet windows/src/nexusctl/bin/Debug/net10.0/nexusctl.dll serve"   # engine only (any OS)
"""
import argparse, json, os, shlex, shutil, subprocess, sys, time, urllib.request, urllib.error, zlib

ap = argparse.ArgumentParser()
ap.add_argument("--exe"); ap.add_argument("--cmd"); ap.add_argument("--nexusctl")
ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "e2e"))
args = ap.parse_args()

ROOT = os.path.abspath(args.root); H = os.path.join(ROOT, "home"); SUP = os.path.join(ROOT, "support"); TRASH = os.path.join(ROOT, "trash")
PASS, FAIL, FAILED = 0, 0, []

def ok(m):
    global PASS; PASS += 1; print(f"  ✅ {m}", flush=True)
def bad(m, extra=""):
    global FAIL; FAIL += 1; FAILED.append(m); print(f"  ❌ {m}  {str(extra)[:400]}", flush=True)
def step(m): print(f"\n━━ {m}", flush=True)
def check(cond, m, extra=""): ok(m) if cond else bad(m, extra)
def waitfor(fn, secs=40):
    end = time.time() + secs
    while time.time() < end:
        try:
            if fn(): return True
        except Exception: pass
        time.sleep(1)
    return False
def p(*parts): return os.path.join(H, *parts)
def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f: f.write(text)

def pdf(path, text):
    """Minimal single-page PDF with a text layer (readable by PdfPig)."""
    lines = text.split("\n")
    stream = "BT /F1 12 Tf 72 720 Td 14 TL " + " ".join("(" + l.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") + ") '" for l in lines) + " ET"
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out = "%PDF-1.4\n"; offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out.encode("latin-1"))); out += f"{i} 0 obj\n{o}\nendobj\n"
    xref = len(out.encode("latin-1"))
    out += f"xref\n0 {len(objs)+1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offsets)
    out += f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f: f.write(out.encode("latin-1"))

def png(path, seed):
    """Small valid PNG with a gradient (for screenshot scenarios)."""
    w, h = 64, 48
    raw = b"".join(b"\x00" + b"".join(bytes([(x * 4 + seed) % 256, (y * 5) % 256, 128]) for x in range(w)) for y in range(h))
    def chunk(t, d): return len(d).to_bytes(4, "big") + t + d + zlib.crc32(t + d).to_bytes(4, "big")
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", w.to_bytes(4, "big") + h.to_bytes(4, "big") + b"\x08\x02\x00\x00\x00") + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f: f.write(data)

# ── sandbox
proc = None
def split(s): return [s] if os.path.exists(s) else shlex.split(s)

def kill():
    global proc
    if proc and proc.poll() is None:
        proc.kill(); proc.wait(10)
    proc = None
shutil.rmtree(ROOT, ignore_errors=True)
for d in [SUP, p("Downloads"), p("Desktop"), p("Documents", "School", "Physics"), p("Documents", "Finance", "Invoices"), p("Documents", "English"), p("Pictures", "Screenshots")]:
    os.makedirs(d, exist_ok=True)
write(p("Documents", "School", "Physics", "kinematics-notes.txt"), "Kinematics notes: velocity acceleration momentum newton force friction projectile motion\n")
write(p("Documents", "English", "macbeth-essay.txt"), "Essay draft: Macbeth ambition theme analysis, Shakespeare tragedy, literary devices\n")
pdf(p("Documents", "Finance", "Invoices", "old-invoice.pdf"), "INVOICE #1001\nBill to: Aditya\nAmount due: $120.00\nDue date: Oct 1 2026\nPayment terms net 30")

env = dict(os.environ, NEXUS_HOME=SUP, NEXUS_HOME_ROOT=H, NEXUS_HEADLESS="1", NEXUS_TRASH_DIR=TRASH)
TOK = ""
def launch():
    global proc, TOK
    try: os.remove(os.path.join(SUP, "api.json"))
    except FileNotFoundError: pass
    cmd = [args.exe] if args.exe else split(args.cmd)
    proc = subprocess.Popen(cmd, env=env, stdout=open(os.path.join(ROOT, "app.log"), "a"), stderr=subprocess.STDOUT)
    def ready():
        global TOK
        TOK = json.load(open(os.path.join(SUP, "api.json")))["token"]
        return api("GET", "/v1/status").get("status") is not None
    return waitfor(ready, 90)

def api(method, path, body=None, auth=True):
    req = urllib.request.Request("http://127.0.0.1:7788" + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("Content-Type", "application/json")
    if auth: req.add_header("Authorization", "Bearer " + TOK)
    try:
        with urllib.request.urlopen(req, timeout=300) as r: return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if not auth: return {"_status": e.code}
        try: return json.loads(e.read() or b"{}") | {"_status": e.code}
        except Exception: return {"_status": e.code}

def cmd(text): return api("POST", "/v1/command", {"text": text, "confirm": True})
def exists(*parts): return os.path.exists(p(*parts))
def find(name):
    for dp, _, fs in os.walk(H):
        if name in fs: return os.path.join(dp, name)
    return None

try:
    step("1 · Launch")
    print("  " + (args.exe or args.cmd))
    if not launch(): bad("app launches and API answers"); print(open(os.path.join(ROOT, "app.log")).read()[-3000:]); sys.exit(1)
    ok("app launches, local API answers")
    st = api("GET", "/v1/status"); print(f"  status: {st.get('status')} · llm: {st.get('llm')} · platform: {st.get('platform')}")
    check(api("GET", "/v1/status", auth=False).get("_status") == 401, "API rejects requests without a token")

    step("2 · First run: nothing moves before setup")
    time.sleep(3)
    pdf(p("Downloads", "acme-invoice-2211.pdf"), "INVOICE #2211\nAcme Supplies LLC\nBill to: Aditya\nAmount due: $84.00\nDue date: Nov 5 2026\nPayment terms net 30")
    shutil.copy(p("Documents", "Finance", "Invoices", "old-invoice.pdf"), p("Downloads", "old-invoice (1).pdf"))
    time.sleep(12)
    check(exists("Downloads", "acme-invoice-2211.pdf"), "new download left in place before onboarding")
    check(exists("Downloads", "old-invoice (1).pdf"), "duplicate not deleted before onboarding")

    step("3 · Setup complete → learning & autopilot")
    api("POST", "/v1/settings", {"onboardingComplete": True, "llmProvider": "auto"})
    api("POST", "/v1/tasks", {"operation": "learnTaxonomy"})
    for f in ["Documents", "Desktop"]: api("POST", "/v1/tasks", {"operation": "classifyFolder", "path": p(f)})
    time.sleep(10)
    for n in ["acme-invoice-2211.pdf", "old-invoice (1).pdf"]:
        try: os.remove(p("Downloads", n))
        except FileNotFoundError: pass
    time.sleep(3)
    pdf(p("Downloads", "brightsparks-invoice.pdf"), "INVOICE #3345\nBrightSparks Electronics\nBill to: Aditya\nAmount due: $64.50\nDue date: Dec 12 2026\nPayment terms net 30 invoice")
    waitfor(lambda: not exists("Downloads", "brightsparks-invoice.pdf") or any("brightsparks" in i["path"] for i in api("GET", "/v1/review")), 45)
    where = find("brightsparks-invoice.pdf")
    if where and "Finance" in where: ok("autopilot filed the invoice into the existing Finance folder")
    else:
        items = [i for i in api("GET", "/v1/review") if "brightsparks" in i["path"]]
        if items:
            ok(f"invoice queued for review → {items[0]['destination']}")
            api("POST", f"/v1/review/{items[0]['id']}/approve", {}); time.sleep(2)
            where = find("brightsparks-invoice.pdf")
            check(where and "Downloads" not in where, "approving the review item moved the file", where)
        else: bad("invoice neither filed nor queued", api("GET", "/v1/files?path=" + urllib.request.quote(p("Downloads", "brightsparks-invoice.pdf"))))

    step("4 · Duplicates")
    shutil.copy(p("Documents", "School", "Physics", "kinematics-notes.txt"), p("Downloads", "kinematics-notes copy.txt"))
    check(waitfor(lambda: not exists("Downloads", "kinematics-notes copy.txt"), 30), "re-downloaded duplicate removed automatically")
    check(os.path.isdir(TRASH) and any("kinematics" in f for f in os.listdir(TRASH)), "duplicate is recoverable from the bin")
    for n in ["macbeth-essay-2.txt", "macbeth-essay-3.txt"]: shutil.copy(p("Documents", "English", "macbeth-essay.txt"), p("Documents", "English", n))
    api("POST", "/v1/tasks", {"operation": "classifyFolder", "path": p("Documents", "English")}); time.sleep(6)
    r = cmd("clean up duplicates"); print("  → " + r.get("message", ""))
    check(len([f for f in os.listdir(p("Documents", "English")) if "macbeth" in f]) == 1, "“clean up duplicates” removed the extra copies", r)
    api("POST", "/v1/undo"); time.sleep(1)
    check(len([f for f in os.listdir(p("Documents", "English")) if "macbeth" in f]) == 3, "undo restored the duplicates")

    step("5 · Plain-English rule → watcher → undo")
    school = p("Documents", "School")
    r = api("POST", "/v1/rules", {"text": f"If a PDF in Downloads contains 'MYP3' → move to {school}, tag myp3"})
    check("myp3" in json.dumps(r), "rule compiled & saved", r)
    pdf(p("Downloads", "myp3-report.pdf"), "MYP3 unit report on energy transfer")
    check(waitfor(lambda: exists("Documents", "School", "myp3-report.pdf"), 40), "rule fired: file moved")
    api("POST", "/v1/undo")
    check(waitfor(lambda: exists("Downloads", "myp3-report.pdf"), 5), "undo moved it back")
    os.remove(p("Downloads", "myp3-report.pdf"))

    step("6 · Pause / resume")
    api("POST", "/v1/pause")
    pdf(p("Downloads", "myp3-paused.pdf"), "MYP3 paused test"); time.sleep(8)
    check(exists("Downloads", "myp3-paused.pdf"), "paused: nothing happens")
    api("POST", "/v1/resume"); api("POST", "/v1/ingest", {"path": p("Downloads", "myp3-paused.pdf")})
    check(waitfor(lambda: exists("Documents", "School", "myp3-paused.pdf"), 30), "resumed: file processed")

    step("7 · Commands")
    for i in (1, 2): png(p("Desktop", f"Screenshot 2026-09-1{i} 10{i}500.png"), i * 40)
    time.sleep(4)
    r = cmd("move all screenshots from Desktop to ~/Pictures/Screenshots and tag them shots"); print("  → " + r.get("message", "").replace("\n", " · "))
    check(waitfor(lambda: len([f for f in os.listdir(p("Pictures", "Screenshots")) if f.startswith("Screenshot")]) >= 2, 15), "multi-step move + tag command", r)
    q = {}
    check(waitfor(lambda: "kinematics-notes" in json.dumps(q := cmd("find everything about kinematics")), 30), "content search", q)
    a = cmd("when is the brightsparks invoice due?"); print("  → " + a.get("message", "")[:220])
    check("Dec" in a.get("message", "") or "12" in a.get("message", ""), "question answered from files (offline)", a)
    check(len(cmd("brief me").get("message", "")) > 30, "briefing")
    cmd("every Sunday at 9am generate weekly report")
    check("eport" in json.dumps(api("GET", "/v1/schedule")), "schedule created")
    check(len(api("GET", "/v1/report?type=weekly").get("markdown", "")) > 100, "weekly report generated")
    protected = r"C:\Windows\Nexus" if os.name == "nt" else "/System/Nexus"
    cmd(f"move kinematics-notes.txt to {protected}")
    check(exists("Documents", "School", "Physics", "kinematics-notes.txt"), "protected location refused")

    step("8 · Insights")
    api("POST", "/v1/tasks", {"operation": "scanInsights"}); time.sleep(6)
    ins = api("GET", "/v1/insights"); print("  " + " · ".join(i["title"] for i in ins)[:240])
    check(isinstance(ins, list), "insights scan completes")

    step("9 · iPhone remote protocol")
    api("POST", "/v1/settings", {"remoteEnabled": True}); time.sleep(3)
    code = api("POST", "/v1/remote/pairing").get("code", "")
    ctl = args.nexusctl
    if ctl:
        out = subprocess.run(split(ctl) + ["remote-test", "127.0.0.1", code], capture_output=True, text=True, env=env, timeout=120).stdout
        print("  " + out.strip().replace("\n", "\n  "))
        check("paired as" in out and "replayed request rejected" in out and "tampered ciphertext rejected" in out and "✗" not in out, "pair, encrypted commands, replay & tamper protection", out)
    else: print("  (skipped: pass --nexusctl)")

    step("10 · Crash recovery & persistence")
    rules_before = len(api("GET", "/v1/rules"))
    kill(); time.sleep(2)
    pdf(p("Downloads", "myp3-while-closed.pdf"), "MYP3 created while Nexus was not running")
    check(launch(), "relaunch after a hard kill")
    check(len(api("GET", "/v1/rules")) == rules_before, f"rules persisted ({rules_before})")
    check(waitfor(lambda: exists("Documents", "School", "myp3-while-closed.pdf"), 40), "file added while closed is processed on relaunch")
finally:
    kill()
    time.sleep(3)

print(f"\n━━ E2E result: {PASS} passed, {FAIL} failed")
if FAIL: print("Failed: " + ", ".join(FAILED)); sys.exit(1)
