# /// script
# requires-python = ">=3.12"
# ///
"""
run_cases.py -- run toc parse (on the perfect raw transcription), ocr-toc + toc parse, and
auto on every messy-TOC case and list every SILENT mis-parse: a wrong level, a wrong physical
page, a dropped line or an invented entry that carries no warning.

    nice -n 15 uv run --python 3.12 tools/adversarial/week1-messy/run_cases.py [--only c01,c05]
        [--jobs 2] [--stages raw,ocr,auto] [--bin .build/release/mulu]

Writes results/<case>/... and results/report.json; prints one block per case.

"Flagged" means: for toc parse, a stderr warning naming one of the entry's line numbers, or
confidence < 0.75; for auto, a '# ?' comment above the entry in --toc-out (auto then still
writes it) or a refusal (exit 2). Anything wrong that is not flagged is SILENT.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CASES = HERE / "cases"
RES = HERE / "results"
LOWCONF = 0.75


def run(cmd, timeout=600):
    t = time.time()
    p = subprocess.run(["nice", "-n", "15"] + [str(c) for c in cmd], capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr, time.time() - t


def norm(s):
    s = unicodedata.normalize("NFKC", s or "")
    return re.sub(r"\s+", "", s).lower()


def lev(a, b):
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def sim(a, b):
    a, b = norm(a), norm(b)
    if not a and not b:
        return 1.0
    return 1.0 - lev(a, b) / max(len(a), len(b))


def align(truth, out, thr=0.45):
    """Monotone alignment maximising total title similarity. Returns list of (ti, oi)."""
    n, m = len(truth), len(out)
    S = [[sim(t["title"], o["title"]) for o in out] for t in truth]
    dp = [[0.0] * (m + 1) for _ in range(n + 1)]
    bt = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            best, how = dp[i - 1][j], 1
            if dp[i][j - 1] > best:
                best, how = dp[i][j - 1], 2
            s = S[i - 1][j - 1]
            if s >= thr and dp[i - 1][j - 1] + s > best:
                best, how = dp[i - 1][j - 1] + s, 3
            dp[i][j], bt[i][j] = best, how
    pairs = []
    i, j = n, m
    while i > 0 and j > 0:
        h = bt[i][j]
        if h == 3:
            pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif h == 1:
            i -= 1
        else:
            j -= 1
    return pairs[::-1]


WARN_LINE = re.compile(r"\bline (\d+)")


def warned_lines(stderr):
    """Line numbers that a warning is ABOUT (its leading 'line N:' / 'lines N, M:'), not lines
    it merely refers to ('using the next entry's page (line 15)')."""
    s = set()
    for ln in stderr.splitlines():
        m = re.search(r"warning: (?:ocr: )?(?:page \d+ )?lines? ([\d, ]+):", ln)
        if m:
            for x in re.findall(r"\d+", m.group(1)):
                s.add(int(x))
    return s


def parse_entries(stdout, stderr):
    try:
        js = json.loads(stdout)
    except Exception:
        return None
    wl = warned_lines(stderr)
    out = []
    for e in js:
        flagged = e["confidence"] < LOWCONF or any(l in wl for l in e["lines"])
        out.append({"title": e["title"], "level": e["level"], "physical": e["page"], "printed": e["printed"],
                    "lines": e["lines"], "conf": e["confidence"], "notes": e["notes"], "flagged": flagged})
    return out


def compare(truth, out, stage, line_flag, junk_lines=()):
    """Returns list of issue dicts."""
    issues = []
    tent = truth["entries"]
    pairs = align(tent, out)
    mt = {ti: oi for ti, oi in pairs}
    mo = {oi: ti for ti, oi in pairs}
    for ti, t in enumerate(tent):
        exp_phys = t["physical"]
        if ti not in mt:
            fl = line_flag(t)
            issues.append({"kind": "dropped", "silent": not fl, "truth": t["title"], "level": t["level"],
                           "want_page": exp_phys, "stage": stage})
            continue
        o = out[mt[ti]]
        probs = []
        if o["level"] != t["level"]:
            probs.append(f"level {o['level']} != {t['level']}")
        if exp_phys is None:
            if o["physical"] is not None and not t.get("inherited"):
                probs.append(f"page {o['physical']} but truth has no such page (printed {t['printed_text']})")
        elif o["physical"] != exp_phys:
            probs.append(f"page {o['physical']} != {exp_phys} (printed {t['printed_text']!r}, read {o.get('printed')!r})")
        s = sim(t["title"], o["title"])
        if s < 0.8:
            probs.append(f"title {o['title']!r} (sim {s:.2f})")
        if probs:
            issues.append({"kind": "wrong", "silent": not o["flagged"], "truth": t["title"], "got": o["title"],
                           "problems": probs, "lines": o.get("lines"), "stage": stage,
                           "title_only": all(p.startswith("title") for p in probs)})
    for oi, o in enumerate(out):
        if oi in mo:
            continue
        src = "junk line" if o.get("lines") and set(o["lines"]) & set(junk_lines) else "unmatched"
        issues.append({"kind": "extra", "silent": not o["flagged"], "got": o["title"], "level": o["level"],
                       "page": o["physical"], "printed": o.get("printed"), "lines": o.get("lines"), "src": src, "stage": stage})
    return issues


def best_line(lines, title):
    best, bi = 0.0, None
    for i, l in enumerate(lines, 1):
        s = sim(re.sub(r"[\s.…·—\-_]+\S*$", "", l), title)
        if s > best:
            best, bi = s, i
    return bi if best >= 0.5 else None


def do_case(name, stages, mulu):
    t = json.loads((CASES / f"{name}.truth.json").read_text())
    d = RES / name
    d.mkdir(parents=True, exist_ok=True)
    pdf = CASES / f"{name}.pdf"
    res = {"name": name, "features": t["features"], "expect": t["expect"], "issues": [], "stages": {}}
    ro = ["--roman-offset", str(t["front_offset"])] if t["front_offset"] is not None else []

    if "raw" in stages:
        rc, so, se, dt = run([mulu, "toc", "parse", CASES / f"{name}.raw.txt", "--offset", t["offset"], *ro, "--pdf", pdf, "--json"])
        (d / "raw.json").write_text(so)
        (d / "raw.err").write_text(se)
        out = parse_entries(so, se)
        wl = warned_lines(se)
        if out is None:
            res["issues"].append({"kind": "crash", "stage": "raw", "silent": False, "got": se[-400:]})
        else:
            iss = compare(t, out, "raw", lambda te: any(l in wl for l in te["raw_lines"]), t["junk_raw_lines"])
            res["issues"] += iss
            res["stages"]["raw"] = {"rc": rc, "entries": len(out), "warnings": se.count("warning")}

    if "ocr" in stages:
        rc, so, se, dt = run([mulu, "ocr-toc", pdf, "--pages", t["toc_pages_arg"]])
        (d / "ocr.txt").write_text(so)
        (d / "ocr.err").write_text(se)
        ocr_lines = so.splitlines()
        res["stages"]["ocr"] = {"rc": rc, "lines": len(ocr_lines), "seconds": round(dt, 1)}
        rc2, so2, se2, _ = run([mulu, "toc", "parse", d / "ocr.txt", "--offset", t["offset"], *ro, "--pdf", pdf, "--json"])
        (d / "ocrparse.json").write_text(so2)
        (d / "ocrparse.err").write_text(se2)
        out = parse_entries(so2, se2)
        wl = warned_lines(se2)
        if out is None:
            res["issues"].append({"kind": "crash", "stage": "ocr", "silent": False, "got": (se + se2)[-400:]})
        else:
            def fl(te):
                bl = best_line(ocr_lines, te["title"])
                return bl is not None and bl in wl
            res["issues"] += compare(t, out, "ocr", fl)
            res["stages"]["ocr"].update({"entries": len(out), "warnings": se2.count("warning")})

    if "auto" in stages:
        outpdf = d / "auto.pdf"
        if outpdf.exists():
            outpdf.unlink()
        rc, so, se, dt = run([mulu, "auto", pdf, "--toc-pages", t["toc_pages_arg"], "-o", outpdf, "--toc-out", d / "auto.toc.txt", "--json"])
        (d / "auto.json").write_text(so)
        (d / "auto.err").write_text(se)
        try:
            aj = json.loads(so.strip().splitlines()[-1]) if so.strip() else {}
        except Exception:
            aj = {}
        st = {"rc": rc, "status": aj.get("status"), "offset": aj.get("offset"), "offset_source": aj.get("offset_source"),
              "offset_conf": aj.get("offset_confidence"), "roman_offset": aj.get("roman_offset"),
              "doubtful": aj.get("doubtful"), "seconds": round(dt, 1), "reason": aj.get("reason") or aj.get("error")}
        if rc != 0:
            st["refusal"] = se.strip().splitlines()[-1] if se.strip() else ""
        res["stages"]["auto"] = st
        if rc == 0 and outpdf.exists():
            rc3, so3, se3, _ = run([mulu, "dump-outline", outpdf])
            (d / "auto.outline.json").write_text(so3)
            ol = json.loads(so3)
            # flags from the draft: '# ?' comment right above an entry line
            flags = []
            draft = (d / "auto.toc.txt").read_text().splitlines() if (d / "auto.toc.txt").exists() else []
            prev_q = False
            left_out = []
            for ln in draft:
                if ln.startswith("# ?"):
                    if "left out" in ln:
                        left_out.append(ln)   # about an entry that was NOT written
                    else:
                        prev_q = True
                    continue
                if ln.startswith("#") or not ln.strip():
                    continue
                flags.append(prev_q)
                prev_q = False
            if len(flags) != len(ol):
                flags = [False] * len(ol)
                st["flag_map"] = "draft/outline count differ"
            out = [{"title": o["title"], "level": o["level"], "physical": o["page_index"] + 1, "flagged": f}
                   for o, f in zip(ol, flags)]
            if st["offset"] is not None and st["offset"] != t["offset"]:
                res["issues"].append({"kind": "offset", "stage": "auto", "silent": True,
                                      "got": f"offset {st['offset']} ({st['offset_source']}, conf {st['offset_conf']})",
                                      "truth": f"offset {t['offset']}"})
            def lf(te):
                return any(sim(te["title"], re.sub(r"^# \? line \d+[^:]*: ", "", l)) > 0.5 for l in left_out)
            iss = compare(t, out, "auto", lf)
            res["issues"] += iss
            st["bookmarks"] = len(out)
            if t["expect"] == "refuse":
                res["issues"].append({"kind": "accepted-non-toc", "stage": "auto", "silent": True,
                                      "got": f"wrote {len(out)} bookmarks from a page that is not a TOC"})
    if t.get("plates"):
        # one --offset for the whole book cannot be right after the plates: by design, only auto matters
        for i in res["issues"]:
            if i["stage"] in ("raw", "ocr"):
                i["by_design"] = True
    res["silent"] = sum(1 for i in res["issues"] if i["silent"] and not i.get("title_only") and not i.get("by_design"))
    (d / "result.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    return res


def show(res):
    print(f"== {res['name']}  ({'; '.join(res['features'])})")
    for k, v in res["stages"].items():
        print(f"   {k}: {json.dumps(v, ensure_ascii=False)}")
    for i in res["issues"]:
        if i.get("title_only") or i.get("by_design"):
            continue
        tag = "SILENT" if i["silent"] else "flagged"
        body = {k: v for k, v in i.items() if k not in ("silent", "stage", "kind", "title_only")}
        print(f"   [{i['stage']}] {tag} {i['kind']}: {json.dumps(body, ensure_ascii=False)}")
    sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--stages", default="raw,ocr,auto")
    ap.add_argument("--bin", default=str(ROOT / ".build" / "release" / "mulu"))
    a = ap.parse_args()
    names = sorted(p.name[:-len(".truth.json")] for p in CASES.glob("*.truth.json"))
    if a.only:
        names = [n for n in names if any(n.startswith(o) for o in a.only.split(","))]
    stages = set(a.stages.split(","))
    results = []
    with cf.ThreadPoolExecutor(max_workers=min(2, a.jobs)) as ex:
        for r in ex.map(lambda n: do_case(n, stages, a.bin), names):
            show(r)
            results.append(r)
    RES.mkdir(exist_ok=True)
    rp = RES / ("report.json" if not a.only else f"report_{a.only.replace(',', '_')}.json")
    rp.write_text(json.dumps(results, ensure_ascii=False, indent=1))
    tot = sum(r["silent"] for r in results)
    print(f"\n{len(results)} cases, {tot} silent issues -> {rp}")


if __name__ == "__main__":
    main()
