# /// script
# requires-python = ">=3.12"
# dependencies = ["pypdfium2>=4.30"]
# ///
"""Landing check: does each bookmark (or draft entry) point at a page whose ABBYY text layer shows the title?
Reads out/<id>.pdf outline via `mulu dump-outline` if written, else the draft out/<id>.toc.txt (physical pages)."""
import json, re, subprocess, sys, unicodedata
from pathlib import Path
import pypdfium2 as pdfium
import argparse, os
ap = argparse.ArgumentParser(); ap.add_argument("--books", required=True); ap.add_argument("--out", required=True); ARGS = ap.parse_args()
HERE = Path(__file__).resolve().parent; BOOKS = Path(ARGS.books); OUT = Path(ARGS.out)
MULU = os.environ.get("MULU", str(HERE.parent.parent / ".build" / "release" / "mulu"))
STOP = {"the", "and", "of", "a", "an", "to", "in", "on", "for", "chapter", "chap", "part", "section", "lesson", "page", "with"}
def norm(s): return re.sub(r"[^0-9a-z一-鿿]+", " ", unicodedata.normalize("NFKC", s).lower()).strip()
def keywords(t):
    t = re.sub(r"^(chapter|chap\.?|part|section|lesson|book)\s+[ivxlc\d]+[.:—-]*\s*", "", t, flags=re.I)
    return [w for w in norm(t).split() if len(w) > 2 and w not in STOP and not re.fullmatch(r"[ivxlc]+|\d+", w)][:4]
def entries_for(bid):
    out = OUT / f"{bid}.pdf"
    if out.exists():
        js = json.loads(subprocess.run([MULU, "dump-outline", str(out)], capture_output=True, text=True).stdout)
        return "written", [(e["title"], e["page_index"] + 1) for e in js if e.get("page_index") is not None]
    toc = OUT / f"{bid}.toc.txt"
    rows = []
    if toc.exists():
        for ln in toc.read_text(encoding="utf-8").splitlines():
            if not ln.strip() or ln.lstrip().startswith("#"): continue
            m = re.match(r"^\s*(.*\S)\s+(\d+)\s*$", ln)
            if m: rows.append((m.group(1), int(m.group(2))))
    return "draft", rows
def main():
    ids = [l.split("\t")[0] for l in (HERE / "toc_pages.tsv").read_text().splitlines() if l.strip()]
    report = {}
    for bid in ids:
        kind, rows = entries_for(bid)
        pdf = pdfium.PdfDocument(str(BOOKS / f"{bid}.pdf")); n = len(pdf); cache = {}
        def head(p):
            if not (1 <= p <= n): return ""
            if p not in cache: cache[p] = norm(" ".join(pdf[p - 1].get_textpage().get_text_range().splitlines()[:15]))
            return cache[p]
        exact = near = miss = uncheckable = 0; misses = []
        for title, page in rows:
            kw = keywords(title)
            if len(kw) < 1: uncheckable += 1; continue
            need = max(1, len(kw) - 1)
            hit = lambda p: sum(w in head(p) for w in kw) >= need
            if hit(page): exact += 1
            elif any(hit(page + d) for d in (-3, -2, -1, 1, 2, 3)): near += 1; misses.append((title[:40], page, "near"))
            else: miss += 1; misses.append((title[:40], page, "notfound"))
        checked = exact + near + miss
        report[bid] = {"kind": kind, "entries": len(rows), "checked": checked, "exact": exact, "near": near, "notfound": miss, "uncheckable": uncheckable, "sample_misses": misses[:6]}
        rate = f"{exact / checked:.0%}" if checked else "-"
        print(f"{bid:32s} {kind:7s} entries={len(rows):3d} checked={checked:3d} land-exact={exact:3d} ({rate}) near={near:2d} notfound={miss:2d}")
    (OUT / "landing_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
main()
