#!/usr/bin/env python3
# <wtl> project: hackintosh-feature-test | file: ft.py | author: watchthelight </wtl>
"""Hackintosh feature test: runs the probes in probes.py and writes a feature matrix with evidence.

  ft.py [--out DIR] run --pass A [--area gpu,display] [--only id,...] [--dry]   automatic probes
  ft.py [--out DIR] guided --pass A [--area ...] [--only ...] [--auto]          human-eye checks (dialogs)
  ft.py [--out DIR] report A [B]                                  summary.md (and diff.md for two passes)
  ft.py [--out DIR] set --pass A <id> <status> <note>             record a judgement by hand

Results go to <out>/<date>/<pass>/: --out or FT_OUT sets <out> (default ./results), FT_DATE overrides the date so
passes run on different days land in one folder. Probes that need sudo read the password from FT_PW in the
environment (never stored). If FT_GUARD_FILE is set, nothing that moves the pointer, opens windows or plays sound
runs while that guard file is pending (see guard_clear); after FT_GUARD_WAIT seconds (default 900) those probes are
recorded as Skipped instead of blocking. The report compares numbers between passes with a relative tolerance (probe
key tol, default 0.10).
"""
import argparse, datetime, json, os, re, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path(os.environ.get("FT_OUT") or "results").resolve()  # results root; --out overrides it
sys.path.insert(0, str(HERE))
import probes as P  # noqa: E402

STATUSES = ["Pass", "Degraded", "Fail", "Not tested (no equipment)", "Not tested (risky)", "N/A", "Skipped", "Error"]


def outdir(pass_):
    d = REPO / os.environ.get("FT_DATE", datetime.date.today().isoformat()) / pass_
    d.mkdir(parents=True, exist_ok=True)
    return d


def boot_sec():
    r = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True)
    m = re.search(r"sec = (\d+)", r.stdout)
    return int(m.group(1)) if m else None


GUARD_WAIT = float(os.environ.get("FT_GUARD_WAIT", "900"))
guard_state = {"timed_out": False}


def guard_clear():
    """(clear, why). FT_GUARD_FILE names a JSON file that a driver rollback guard keeps while it waits for the user to
    confirm a boot. It is clear when it is missing, or has result "pass" and a started_boot equal to this boot (a
    pass left over from an earlier boot does not count)."""
    if not os.environ.get("FT_GUARD_FILE"):
        return True, "no guard file"
    p = Path(os.environ["FT_GUARD_FILE"]).expanduser()
    if not p.exists():
        return True, "no guard file"
    try:
        j = json.loads(p.read_text())
    except Exception as e:
        return False, f"unreadable guard file: {e!r}"
    if j.get("result") != "pass":
        return False, f"result={j.get('result') or 'pending'}"
    if j.get("started_boot") != boot_sec():
        return False, f"started_boot={j.get('started_boot')} is not this boot ({boot_sec()})"
    return True, "pass on this boot"


def wait_guard():
    """Blocks until the guard is clear; False after FT_GUARD_WAIT seconds (and on every later call, without waiting)."""
    if guard_state["timed_out"]:
        return False
    ok, why = guard_clear()
    if ok:
        return True
    print(f"waiting for {os.environ['FT_GUARD_FILE']} to clear before any GUI probe ({why}, up to {GUARD_WAIT:g} s) ...",
          flush=True)
    t0 = time.time()
    while time.time() - t0 < GUARD_WAIT:
        time.sleep(2)
        ok, why = guard_clear()
        if ok:
            return True
    guard_state["timed_out"] = True
    guard_state["why"] = why
    print(f"guard not clear after {GUARD_WAIT:g} s ({why}): GUI, pointer and sound probes are skipped", flush=True)
    return False


def sh(cmd, timeout=120, pw=False, od=None):
    env = dict(os.environ, FT_REPO=str(REPO), FT_HERE=str(HERE), FT_OD=str(od or "/tmp"))
    if pw:
        cmd = cmd.replace("SUDO ", "printf '%s\\n' \"$FT_PW\" | sudo -S -p '' ")
    t0 = time.time()
    try:
        r = subprocess.run(["/bin/zsh", "-c", cmd], capture_output=True, text=True, timeout=timeout, env=env)
        out = r.stdout + (("\n[stderr]\n" + r.stderr) if r.stderr.strip() else "")
        return r.returncode, out, time.time() - t0
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return 124, out + f"\n[timeout after {timeout}s]", time.time() - t0


def osa(script, timeout=3600):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip()


def ask(feature, prompt):
    """Pass / Degraded / Fail / Skip from the user, then an optional note."""
    q = prompt.replace('"', "'")
    rc, sel = osa(f'choose from list {{"Pass","Degraded","Fail","Skip"}} with title "Feature test: {feature}" '
                  f'with prompt "{q}" default items {{"Pass"}}')
    status = sel if sel in ("Pass", "Degraded", "Fail") else "Skipped"
    note = ""
    if status != "Skipped":
        rc, ans = osa('display dialog "Note (optional)" default answer "" buttons {"OK"} default button "OK" '
                      'with title "Feature test"')
        m = re.search(r"text returned:(.*)$", ans)
        note = m.group(1).strip() if m else ""
    return status, note


def record(od, rec):
    with open(od / "results.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(f"{rec['status']:<10} {rec['id']:<28} {rec.get('value', '')}"[:160], flush=True)


def selected(args, kinds):
    areas = set(args.area.split(",")) if args.area else None
    only = set(args.only.split(",")) if args.only else None
    for p in P.PROBES:
        if p["kind"] not in kinds:
            continue
        if areas and p["area"] not in areas:
            continue
        if only and p["id"] not in only:
            continue
        if args.pass_ not in p.get("passes", "AB"):
            continue
        yield p


def run_auto(args):
    od = outdir(args.pass_)
    for p in selected(args, ("auto", "nt", "info")):
        if args.dry:
            print(f"{p['kind']:<6} {p['area']:<9} {p['id']:<28} needs={','.join(p.get('needs', [])) or '-'}  {p['feature']}")
            continue
        rec = {"id": p["id"], "area": p["area"], "feature": p["feature"], "pass": args.pass_, "kind": p["kind"],
               "time": datetime.datetime.now().isoformat(timespec="seconds")}
        if p["kind"] == "nt":
            rec.update(status=p["status"], value="", note=p.get("note", ""))
            record(od, rec); continue
        if "risky" in p.get("needs", []) and not args.risky:
            rec.update(status="Not tested (risky)", value="", note="run with --risky"); record(od, rec); continue
        if set(p.get("needs", [])) & {"gui", "sound", "pointer"} and not wait_guard():
            rec.update(status="Skipped", value="", note=f"guard timeout: {guard_state.get('why', '')}"); record(od, rec); continue
        if set(p.get("needs", [])) & {"gui", "sound", "pointer"} and not args.no_ask:
            what = {"pointer": "moves the pointer", "sound": "plays sound", "gui": "opens or changes something on screen"}
            how = ", ".join(what[n] for n in p["needs"] if n in what)
            rc, ans = osa(f'display dialog "Next probe: {p["feature"]}. It {how}. Continue or skip it?" '
                          'buttons {"Skip", "Continue"} default button "Continue" with title "Feature test" giving up after 20')
            if "Skip" in ans:
                rec.update(status="Skipped", value="", note="skipped by the user"); record(od, rec); continue
        if "sudo" in p.get("needs", []) and not os.environ.get("FT_PW"):
            rec.update(status="Skipped", value="", note="needs FT_PW for sudo"); record(od, rec); continue
        if p.get("req") and sh(f'test -e "{p["req"]}"', 10, od=od)[0] != 0:
            rec.update(status="N/A", value="", note=f"needs {p['req']}"); record(od, rec); continue
        rc, out, dt = sh(p["cmd"], p.get("timeout", 120), pw="sudo" in p.get("needs", []), od=od)
        ev = od / f"{p['id']}.txt"
        ev.write_text(f"$ {p['cmd']}\n[rc {rc}, {dt:.1f} s]\n{out}")
        try:
            status, value, note = p["check"](rc, out) if "check" in p else (("Pass" if rc == 0 else "Fail"), "", "")
        except Exception as e:  # a parser bug is a harness error, not a feature failure
            status, value, note = "Error", "", f"check raised {e!r}"
        if p["kind"] == "info" and status == "Pass":
            status = "N/A" if p.get("info_na") else "Pass"
        rec.update(status=status, value=value, note=note or p.get("note", ""), evidence=str(ev.relative_to(REPO)),
                   seconds=round(dt, 1))
        record(od, rec)


def run_guided(args):
    od = outdir(args.pass_)
    clear = wait_guard()
    for p in selected(args, ("guided",)):
        rec = {"id": p["id"], "area": p["area"], "feature": p["feature"], "pass": args.pass_, "kind": "guided",
               "time": datetime.datetime.now().isoformat(timespec="seconds")}
        if not clear:
            rec.update(status="Skipped", value="", note=f"guard timeout: {guard_state.get('why', '')}"); record(od, rec); continue
        if args.auto and p["id"] not in P.SHOT:
            rec.update(status="Not tested (needs a person)", value="",
                       note="needs hands, a phone or watching motion; not judgeable from a screenshot")
            record(od, rec); continue
        if p.get("prep"):
            sh(p["prep"], p.get("timeout", 60), od=od)
            time.sleep(p.get("settle", 3))
        shot = od / f"{p['id']}.png"
        subprocess.run(["screencapture", "-x", str(shot)])
        if args.auto:  # someone judges the screenshot afterwards and records it with `ft.py set`
            status, note = "Review", "screenshot waiting for review"
        else:
            status, note = ask(p["feature"], p["prompt"])
        if p.get("cleanup"):
            sh(p["cleanup"], 60, od=od)
        rec.update(status=status, value="", note=note, evidence=str(shot.relative_to(REPO)))
        record(od, rec)


def run_set(args):
    od = outdir(args.pass_)
    old = load(args.pass_).get(args.id) or next(({"id": p["id"], "area": p["area"], "feature": p["feature"]}
                                                 for p in P.PROBES if p["id"] == args.id), None)
    if not old:
        sys.exit(f"unknown probe {args.id}")
    rec = dict(old, status=args.status, note=args.note, pass_=None, time=datetime.datetime.now().isoformat(timespec="seconds"),
               judged_by=args.by)
    rec.pop("pass_", None); rec["pass"] = args.pass_
    record(od, rec)


def load(pass_):
    f = outdir(pass_) / "results.jsonl"
    res = {}
    if f.exists():
        for line in f.read_text().splitlines():
            r = json.loads(line)
            res[r["id"]] = r  # the latest run of a probe wins
    return res


NUM_RX = r"-?\d+(?:\.\d+)?"


def values_differ(va, vb, tol):
    """Compare two recorded values. Numbers (every number in the string, same count) are the same within the relative
    tolerance; anything else must match exactly. Returns (differ, delta) with delta the largest relative change."""
    sa, sb = str(va or ""), str(vb or "")
    na, nb = re.findall(NUM_RX, sa), re.findall(NUM_RX, sb)
    if na and len(na) == len(nb) and re.sub(NUM_RX, "#", sa) == re.sub(NUM_RX, "#", sb):
        worst = 0.0
        for x, y in zip(na, nb):
            x, y = float(x), float(y)
            d = 0.0 if x == y else (abs(y - x) / abs(x) if x else float("inf"))
            if d > abs(worst):
                worst = d if y >= x else -d
        return abs(worst) > tol, worst
    return sa != sb, None


def fmt_delta(d):
    if d is None:
        return ""
    if d in (float("inf"), -float("inf")):
        return "from 0"
    return f"{d * 100:+.1f}%"


def run_report(args):
    a = load(args.passes[0])
    order = [p["id"] for p in P.PROBES]
    for p in P.PROBES:  # a probe of this pass that never ran (stopped early) still gets a row
        if p["id"] not in a and args.passes[0] in p.get("passes", "AB"):
            a[p["id"]] = {"id": p["id"], "area": p["area"], "feature": p["feature"], "status": "Not run", "value": "",
                          "note": "guided item not reached" if p["kind"] == "guided" else "not run"}
    od = outdir(args.passes[0])
    lines = [f"# Feature test pass {args.passes[0]}", ""]
    counts = {}
    for area in P.AREAS:
        rows = [a[i] for i in order if i in a and a[i]["area"] == area]
        if not rows:
            continue
        lines += [f"## {P.AREAS[area]}", "", "| Feature | Status | Measured | Note |", "|---|---|---|---|"]
        for r in rows:
            counts[r["status"]] = counts.get(r["status"], 0) + 1
            lines.append(f"| {r['feature']} | {r['status']} | {str(r.get('value', ''))[:80]} | {r.get('note', '')[:160]} |")
        lines.append("")
    lines.insert(2, "Totals: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + "\n")
    (od / "summary.md").write_text("\n".join(lines))
    print(f"wrote {od / 'summary.md'}")
    if len(args.passes) > 1:
        b = load(args.passes[1])
        tols = {p["id"]: p.get("tol", 0.10) for p in P.PROBES}
        d = [f"# Feature test: pass {args.passes[0]} vs pass {args.passes[1]}", "",
             "Numbers count as the same within the probe's relative tolerance (default 10 %); the delta is the largest "
             "relative change in the row.", "",
             f"| Feature | {args.passes[0]} | {args.passes[1]} | {args.passes[0]} value | {args.passes[1]} value | Delta |",
             "|---|---|---|---|---|---|"]
        for i in order:
            if i not in a or i not in b:
                continue
            differ, delta = values_differ(a[i].get("value"), b[i].get("value"), tols.get(i, 0.10))
            if a[i]["status"] != b[i]["status"] or differ:
                d.append(f"| {a[i]['feature']} | {a[i]['status']} | {b[i]['status']} | {str(a[i].get('value', ''))[:60]} | "
                         f"{str(b[i].get('value', ''))[:60]} | {fmt_delta(delta)} |")
        (od.parent / "diff.md").write_text("\n".join(d) + "\n")
        print(f"wrote {od.parent / 'diff.md'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="results root (default $FT_OUT or ./results)")
    sp = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "guided"):
        s = sp.add_parser(name)
        s.add_argument("--pass", dest="pass_", required=True)
        s.add_argument("--area"); s.add_argument("--only"); s.add_argument("--dry", action="store_true")
        s.add_argument("--risky", action="store_true")
        s.add_argument("--no-ask", dest="no_ask", action="store_true", help="no Continue/Skip dialogs before GUI probes")
        s.add_argument("--auto", action="store_true", help="guided: screenshot only, judged later with `set`")
    r = sp.add_parser("report"); r.add_argument("passes", nargs="+")
    st = sp.add_parser("set"); st.add_argument("--pass", dest="pass_", required=True); st.add_argument("id")
    st.add_argument("status", choices=STATUSES + ["Not tested (needs a person)"]); st.add_argument("note")
    st.add_argument("--by", default="screenshot review")
    args = ap.parse_args()
    if args.out:
        global REPO
        REPO = Path(args.out).resolve()
    {"run": run_auto, "guided": run_guided, "report": run_report, "set": run_set}[args.cmd](args)


if __name__ == "__main__":
    main()
