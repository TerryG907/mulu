# /// script
# requires-python = ">=3.12"
# ///
"""
week1_regress.py -- every reproducer of the two week-1 adversarial reviews as a pass/fail check.

    nice -n 15 uv run --python 3.12 tools/eval/week1_regress.py [--mulu .build/release/mulu] [--skip-messy] [--skip-noregress]

1. Messy printed TOCs (tools/adversarial/week1-messy): run_cases.py on the cases behind the
   findings (toc parse on the transcription, ocr-toc + toc parse, auto). Each case must have
   0 silent issues (a wrong level / page / title, a dropped or invented entry with no warning)
   and the expected `mulu auto` outcome; c33 and c15 (chapter 1 put on the TOC page) must have
   no wrong auto bookmark at all, flagged or not.
2. Offset changes and resource guards (tools/adversarial/week1-noregress):
   - plates in the middle (4 and 8 pages), plates near the end, sawtooth folios: auto exit 2,
     no output file, input unchanged;
   - the clean 120-page scan: auto exit 0, every bookmark on its true page;
   - a sampled page that cannot be rendered: detect-offset still finds offset +8;
   - an open page range (1992 pages) is refused before any OCR;
   - -o naming a directory or a file in a read-only directory is refused before any OCR.
3. Found while fixing: a short title before a long leader run ("之一 …… 50") must keep its title.
Exit 0 only if every check passes. Uses at most 2 mulu processes at a time (run_cases --jobs 2).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MESSY = ROOT / "tools" / "adversarial" / "week1-messy"
NOREG = ROOT / "tools" / "adversarial" / "week1-noregress"
UV = [os.environ.get("UV") or shutil.which("uv") or str(Path.home() / ".local" / "bin" / "uv"),
      "run", "--quiet", "--python", "3.12"]

# finding case -> expected auto status
MESSY_EXPECT = {
    "c02": "ok", "c04": "ok", "c06": "ok", "c08": "ok", "c09": "ok", "c12": "ok", "c14": "ok", "c15": "ok",
    "c16": "ok", "c18": "refused", "c19": "ok", "c21": "ok", "c22": "ok", "c23": "ok", "c24": "ok", "c26": "ok",
    "c28": "ok", "c33": "ok", "c35": "ok", "c36": "ok", "c38": "ok",
}
NO_WRONG_AUTO = {"c33", "c15"}

failures: list[str] = []


def check(ok: bool, what: str):
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def run(cmd, timeout=1800):
    t = time.monotonic()
    p = subprocess.run(["nice", "-n", "15"] + [str(c) for c in cmd], capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr, time.monotonic() - t


def norm(s: str) -> str:
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", s or "")).lower()


def messy(mulu: Path):
    names = sorted(p.name[: -len(".truth.json")] for p in (MESSY / "cases").glob("*.truth.json"))
    want = {k: next((n for n in names if n.startswith(k + "_")), None) for k in MESSY_EXPECT}
    missing = [k for k, n in want.items() if n is None or not (MESSY / "cases" / f"{n}.pdf").exists()]
    if missing:
        rc, _, se, _ = run(UV + [MESSY / "make_cases.py", "--only", ",".join(missing)])
        if rc != 0:
            check(False, f"messy: could not build cases {missing}: {se[-300:]}")
            return
    rc, so, se, dt = run(UV + [MESSY / "run_cases.py", "--only", ",".join(MESSY_EXPECT), "--jobs", "2", "--bin", mulu])
    print(f"messy cases: run_cases.py exit {rc} in {dt:.0f} s", flush=True)
    for k, status in MESSY_EXPECT.items():
        names = sorted(p.name for p in (MESSY / "results").iterdir() if p.name.startswith(k + "_"))
        rj = MESSY / "results" / names[0] / "result.json" if names else None
        if rj is None or not rj.exists():
            check(False, f"messy {k}: no result")
            continue
        r = json.loads(rj.read_text())
        silent = [i for i in r["issues"] if i["silent"] and not i.get("title_only") and not i.get("by_design")]
        got = (r["stages"].get("auto") or {}).get("status")
        detail = "; ".join(f"[{i['stage']}] {i['kind']} {i.get('truth') or i.get('got')}" for i in silent[:3])
        check(not silent, f"messy {r['name']}: 0 silent issues" + (f" (got {len(silent)}: {detail})" if silent else ""))
        check(got == status, f"messy {r['name']}: auto {status}" + ("" if got == status else f" (got {got})"))
        if k in NO_WRONG_AUTO:
            wrong = [i for i in r["issues"] if i["stage"] == "auto" and i["kind"] in ("wrong", "dropped", "extra")]
            check(not wrong, f"messy {r['name']}: every auto bookmark right" + (f" ({wrong[:2]})" if wrong else ""))


def score_outline(mulu: Path, out: Path, truth: dict) -> tuple[int, int, list[str]]:
    rc, so, se, _ = run([mulu, "dump-outline", out])
    items = json.loads(so) if rc == 0 else []
    body = [e for e in truth["entries"] if not e.get("front_matter")]
    found = right = 0
    wrong: list[str] = []
    j = 0
    for e in body:
        k = next((k for k in range(j, min(len(items), j + 6)) if norm(items[k]["title"]) == norm(e["title"])), None)
        if k is None:
            continue
        j = k + 1
        found += 1
        if items[k]["page_index"] + 1 == e["physical_page"]:
            right += 1
        else:
            wrong.append(f"{e['title']}: {items[k]['page_index'] + 1} != {e['physical_page']}")
    return found, len(body), wrong


def noregress(mulu: Path):
    books, vec = NOREG / "books", NOREG / "vec"
    if not (books / "w1_plates_mid.pdf").exists() or not (books / "w1_book120.pdf").exists():
        rc, so, se, _ = run(["bash", NOREG / "gen_all.sh"], timeout=7200)
        if rc != 0:  # reported only on failure, so the check count stays the same on a fresh clone
            check(False, f"noregress: gen_all.sh exit {rc}: {(se or so)[-300:]}")
    if not (vec / "big2000.pdf").exists():
        rc, so, se, _ = run(UV + ["python", NOREG / "gen_vector.py"], timeout=7200)
        if rc != 0:
            check(False, f"noregress: gen_vector.py exit {rc}: {se[-300:]}")
    if not (vec / "big2000_zerobox.pdf").exists():
        rc, so, se, _ = run(UV + [NOREG / "gen_zerobox.py"], timeout=3600)
        if rc != 0:
            check(False, f"noregress: gen_zerobox.py exit {rc}: {se[-300:]}")
    tmp = Path(tempfile.mkdtemp(prefix="mulu-w1-"))
    try:
        for b in ["w1_plates_mid", "w1_plates_mid8", "w1_plates_mid2", "w1_plates_late", "w1_sawtooth"]:
            pdf = books / f"{b}.pdf"
            if not pdf.exists():
                check(False, f"{b}: book missing (tools/adversarial/week1-noregress/gen_all.sh)")
                continue
            truth = json.loads((books / f"{b}.truth.json").read_text())
            before = sha(pdf)
            out = tmp / f"{b}.pdf"
            rc, so, se, dt = run([mulu, "auto", pdf, "--toc-pages", truth["toc_pages_arg"], "-o", out])
            reason = (se.strip().splitlines() or [""])[-1][:160]
            check(rc == 2 and not out.exists() and sha(pdf) == before,
                  f"{b}: auto refuses (exit {rc}, {dt:.1f} s): {reason}")
        pdf = books / "w1_book120.pdf"
        if pdf.exists():
            truth = json.loads((books / "w1_book120.truth.json").read_text())
            out = tmp / "book120.pdf"
            rc, so, se, dt = run([mulu, "auto", pdf, "--toc-pages", truth["toc_pages_arg"], "-o", out])
            found, total, wrong = score_outline(mulu, out, truth) if rc == 0 else (0, 0, ["no output"])
            check(rc == 0 and not wrong and found >= 0.95 * total,
                  f"w1_book120: auto writes the outline, {found}/{total} body entries found, {len(wrong)} on a wrong page ({dt:.1f} s)"
                  + (f": {wrong[:3]}" if wrong else ""))
        zb = vec / "big2000_zerobox.pdf"
        if zb.exists():
            rc, so, se, dt = run([mulu, "detect-offset", zb])
            try:
                j = json.loads(so)
            except Exception:
                j = {}
            check(rc == 0 and j.get("offset") == 8 and 101 in j.get("unrenderable", []),
                  f"big2000_zerobox: unrenderable sample skipped, offset {j.get('offset')} (exit {rc}, {dt:.1f} s)")
        big = vec / "big2000.pdf"
        if big.exists():
            rc, _, se, dt = run([mulu, "ocr-toc", big, "--pages", "9-"])
            check(rc != 0 and dt < 5, f"ocr-toc --pages 9- on 2000 pages refused before OCR (exit {rc}, {dt:.1f} s)")
            rc, _, se, dt = run([mulu, "auto", big, "--toc-pages", "9-", "-o", tmp / "o.pdf"])
            check(rc != 0 and dt < 5 and not (tmp / "o.pdf").exists(),
                  f"auto --toc-pages 9- on 2000 pages refused before OCR (exit {rc}, {dt:.1f} s)")
        src = books / "w1_book120.pdf"
        if src.exists():
            (tmp / "adir").mkdir()
            rc, _, se, dt = run([mulu, "auto", src, "--toc-pages", "7-9", "-o", tmp / "adir"])
            check(rc != 0 and dt < 5 and "directory" in se, f"-o <existing directory> refused before OCR (exit {rc}, {dt:.1f} s)")
            ro = tmp / "ro"
            ro.mkdir()
            ro.chmod(0o555)
            rc, _, se, dt = run([mulu, "auto", src, "--toc-pages", "7-9", "-o", ro / "o.pdf"])
            ro.chmod(0o755)
            check(rc != 0 and dt < 5 and "o.pdf" in se and not any(ro.iterdir()),
                  f"-o in a read-only directory refused before OCR, message names o.pdf (exit {rc}, {dt:.1f} s)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def short_titles(mulu: Path):
    """A short title before a long leader run ("之一 …… 50") that Vision reads as "17" or not at
    all: found in the fixing round (zh_essays_unnumbered e2e 98%); the tight 2x/3x re-read must
    recover it."""
    pdf = ROOT / "Fixtures" / "books" / "zh_essays_unnumbered.pdf"
    if not pdf.exists():
        check(False, "zh_essays_unnumbered: book missing (tools/fixtures/make_books.py)")
        return
    rc, so, se, dt = run([mulu, "ocr-toc", pdf, "--pages", "8"])
    lines = [l.strip() for l in so.splitlines()]
    check(rc == 0 and "之一\t50" in lines and not any(l.startswith("\t") or l == "50" for l in lines),
          f"zh_essays_unnumbered page 8: '之一 …… 50' read with its title (exit {rc}, {dt:.1f} s)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mulu", default=str(ROOT / ".build" / "release" / "mulu"))
    ap.add_argument("--skip-messy", action="store_true")
    ap.add_argument("--skip-noregress", action="store_true")
    a = ap.parse_args()
    mulu = Path(a.mulu)
    t0 = time.monotonic()
    if not a.skip_messy:
        messy(mulu)
    if not a.skip_noregress:
        noregress(mulu)
    short_titles(mulu)
    print(f"week-1 regressions: {'ALL PASS' if not failures else f'{len(failures)} FAILED'} ({time.monotonic() - t0:.0f} s)")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
