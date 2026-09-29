# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pikepdf>=9",
#   "pypdf>=5",
#   "pymupdf>=1.24",
#   "pdfminer.six>=20231228",
#   "pillow>=10",
#   "cryptography>=42",
# ]
# ///
"""
check_system.py -- extra reader matrix for the producer-matrix run (on top of tools/verify/verify.py).

    uv run --python 3.12 tools/adversarial/producer-matrix/check_system.py [--only a,b] [--mulu PATH]

For every mulu output in out/ (first apply and re-apply):
  ql      qlmanage -t -s 256 must produce a thumbnail, and its pixels must equal the input's thumbnail
  mdls    kMDItemNumberOfPages (Spotlight; after `mdimport` if not yet indexed) and the PDF importer's own
          value (`mdimport -t -d2`) must equal the page count
  mupdf   MuPDF (pymupdf) get_toc == expected, doc.is_repaired False, no new MuPDF warnings vs input
  miner   pdfminer.six get_outlines == expected
  rt-*    round trips through other writers keep the outline: PDFKit write, qpdf save, MuPDF garbage=4,
          pypdf clone; then `mulu apply` on the PDFKit-resaved file must still work
Preview.app is deliberately NOT opened (it would put windows in front of the user).
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
GEN, OUT = HERE / "gen", HERE / "out"
QL = OUT / "ql"
RT = OUT / "roundtrip"
RESAVE = ROOT / "tools" / "verify" / ".bin" / "pdfkit_resave"


def sh(cmd, timeout=120):
    return subprocess.run([str(c) for c in cmd], capture_output=True, timeout=timeout)


def img_hash(p: Path):
    from PIL import Image
    with Image.open(p) as im:
        return hashlib.sha256(im.convert("RGBA").tobytes()).hexdigest()[:16], im.size


def ql_thumb(pdf: Path, d: Path):
    d.mkdir(parents=True, exist_ok=True)
    png = d / (pdf.name + ".png")
    png.unlink(missing_ok=True)
    p = sh(["/usr/bin/qlmanage", "-t", "-s", "256", "-o", d, pdf], timeout=60)
    if not png.exists() or png.stat().st_size == 0:
        return None, p.stdout.decode(errors="replace")[-200:] + p.stderr.decode(errors="replace")[-200:]
    return img_hash(png), None


def md_pages(pdf: Path):
    def mdls():
        o = sh(["/usr/bin/mdls", "-name", "kMDItemNumberOfPages", "-raw", pdf]).stdout.decode().strip()
        return None if o in ("", "(null)") else int(o)
    v = mdls()
    if v is None:
        sh(["/usr/bin/mdimport", pdf])
        for _ in range(20):
            time.sleep(0.25)
            v = mdls()
            if v is not None:
                break
    t = sh(["/usr/bin/mdimport", "-t", "-d2", pdf]).stderr.decode(errors="replace") + \
        sh(["/usr/bin/mdimport", "-t", "-d2", pdf]).stdout.decode(errors="replace")
    m = re.search(r"kMDItemNumberOfPages\s*=\s*(\d+)", t)
    return v, (int(m.group(1)) if m else None)


MU_LOCK = __import__("threading").RLock()


def mupdf_toc(pdf: Path):
    with MU_LOCK:
        return _mupdf_toc(pdf)


def _mupdf_toc(pdf: Path):
    import pymupdf
    pymupdf.TOOLS.mupdf_warnings(reset=True)
    doc = pymupdf.open(pdf)
    toc = doc.get_toc(simple=True)
    res = {"pages": doc.page_count, "repaired": bool(doc.is_repaired),
           "outline": [{"title": t, "level": lvl - 1, "page_index": pg - 1} for lvl, t, pg in toc]}
    doc.close()
    res["warnings"] = [w for w in pymupdf.TOOLS.mupdf_warnings(reset=True).splitlines() if w.strip()]
    return res


def miner_outline(pdf: Path):
    from pdfminer.pdfdocument import PDFDocument
    from pdfminer.pdfpage import PDFPage
    from pdfminer.pdfparser import PDFParser
    from pdfminer.pdftypes import resolve1
    with open(pdf, "rb") as f:
        doc = PDFDocument(PDFParser(f))
        pages = {p.pageid: i for i, p in enumerate(PDFPage.create_pages(doc))}
        out = []
        for level, title, dest, action, _se in doc.get_outlines():
            d = resolve1(dest)
            if d is None and action:
                a = resolve1(action)
                d = resolve1(a.get("D")) if isinstance(a, dict) else None
            if isinstance(d, dict):
                d = resolve1(d.get("D"))
            idx = None
            if isinstance(d, list) and d:
                ref = d[0]
                idx = pages.get(getattr(ref, "objid", None))
            out.append({"title": title, "level": level - 1, "page_index": idx})
        return {"outline": out, "pages": len(pages)}


def eq(got, exp):
    return [(g["title"], g["level"], g["page_index"]) for g in got] == \
           [(e["title"], e["level"], e["page_index"]) for e in exp]


def diff(got, exp):
    for i, (g, e) in enumerate(zip(got, exp)):
        a = (g["title"], g["level"], g["page_index"])
        b = (e["title"], e["level"], e["page_index"])
        if a != b:
            return f"item {i}: got {a!r} want {b!r}"
    return f"{len(got)} items, want {len(exp)}"


def pike_outline(pdf: Path):
    import pikepdf
    with pikepdf.open(pdf) as p:
        idx = {pg.objgen: i for i, pg in enumerate(p.pages)}
        out = []

        def walk(items, lvl):
            for it in items:
                pi = None
                d = it.destination
                if d is None and it.action is not None and "/D" in it.action:
                    d = it.action.D
                if isinstance(d, pikepdf.Array) and len(d):
                    pi = idx.get(d[0].objgen)
                out.append({"title": str(it.title), "level": lvl, "page_index": pi})
                walk(it.children, lvl + 1)
        with p.open_outline() as ol:
            walk(ol.root, 0)
        return out


def roundtrips(name, outp: Path, exp, mulu, reapply_toc: Path | None, reapply_exp):
    """outline must survive re-serialization by other writers; mulu must accept their output again."""
    import pikepdf
    import pymupdf
    from pypdf import PdfReader, PdfWriter
    RT.mkdir(parents=True, exist_ok=True)
    res = {}
    # PDFKit
    pk = RT / f"{name}.pdfkit.pdf"
    r = sh([RESAVE, outp, pk])
    if not pk.exists():
        res["rt-pdfkit"] = f"PDFKit write failed: {r.stderr.decode(errors='replace')[-200:]}"
    else:
        try:
            got = pike_outline(pk)
            res["rt-pdfkit"] = "ok" if eq(got, exp) else f"outline changed after PDFKit write: {diff(got, exp)}"
        except Exception as e:  # noqa: BLE001
            res["rt-pdfkit"] = f"err {e}"
        if reapply_toc is not None and mulu:
            o2 = RT / f"{name}.pdfkit.mulu.pdf"
            o2.unlink(missing_ok=True)
            p = sh([mulu, "apply", pk, reapply_toc, "-o", o2])
            if p.returncode != 0:
                res["rt-pdfkit+mulu"] = f"mulu apply on PDFKit-resaved output: exit {p.returncode} " \
                                        f"{p.stderr.decode(errors='replace').strip()[:200]}"
            else:
                got = pike_outline(o2)
                ok = o2.read_bytes().startswith(pk.read_bytes()) and eq(got, reapply_exp)
                m = mupdf_toc(o2)
                res["rt-pdfkit+mulu"] = "ok" if ok and eq(m["outline"], reapply_exp) and not m["repaired"] \
                    else f"bad: prefix/outline/mupdf {diff(got, reapply_exp)} repaired={m['repaired']}"
    # qpdf
    q = RT / f"{name}.qpdf.pdf"
    try:
        with pikepdf.open(outp) as p:
            p.save(q, object_stream_mode=pikepdf.ObjectStreamMode.generate)
        got = pike_outline(q)
        res["rt-qpdf"] = "ok" if eq(got, exp) else f"outline changed after qpdf save: {diff(got, exp)}"
    except Exception as e:  # noqa: BLE001
        res["rt-qpdf"] = f"err {type(e).__name__}: {e}"
    # MuPDF
    mu = RT / f"{name}.mupdf.pdf"
    try:
        MU_LOCK.acquire()
        d = pymupdf.open(outp)
        d.save(mu, garbage=4, deflate=True)
        MU_LOCK.release()
        d.close()
        got = mupdf_toc(mu)["outline"]
        res["rt-mupdf"] = "ok" if eq(got, exp) else f"outline changed after MuPDF save: {diff(got, exp)}"
    except Exception as e:  # noqa: BLE001
        res["rt-mupdf"] = f"err {type(e).__name__}: {e}"
    # pypdf clone
    pp = RT / f"{name}.pypdf.pdf"
    try:
        w = PdfWriter(clone_from=PdfReader(outp))
        w.write(pp)
        got = pike_outline(pp)
        res["rt-pypdf"] = "ok" if eq(got, exp) else f"outline changed after pypdf clone: {diff(got, exp)}"
    except Exception as e:  # noqa: BLE001
        res["rt-pypdf"] = f"err {type(e).__name__}: {e}"
    return res


def check_case(name, inp: Path, outp: Path, exp, pages, mulu, reapply_toc, reapply_exp, label):
    R = {"label": label}
    # Quick Look
    th_in, _ = ql_thumb(inp, QL / "in" / label)
    th_out, err = ql_thumb(outp, QL / "out" / label)
    if th_out is None:
        R["ql"] = f"no thumbnail: {err}"
    elif th_in is not None and th_in != th_out:
        R["ql"] = f"thumbnail differs from input's ({th_in} vs {th_out})"
    else:
        R["ql"] = "ok"
    # Spotlight
    v, imp = md_pages(outp)
    R["mdls"] = "ok" if (v == pages and imp == pages) else f"mdls={v} importer={imp} want {pages}"
    # MuPDF
    try:
        mi, mo = mupdf_toc(inp), mupdf_toc(outp)
        probs = []
        if not eq(mo["outline"], exp):
            probs.append(diff(mo["outline"], exp))
        if mo["repaired"] and not mi["repaired"]:
            probs.append("MuPDF had to REPAIR the output (xref broken)")
        neww = sorted(set(mo["warnings"]) - set(mi["warnings"]))
        if neww:
            probs.append(f"new MuPDF warnings {neww[:3]}")
        if mo["pages"] != pages:
            probs.append(f"pages {mo['pages']}")
        R["mupdf"] = "ok" if not probs else "; ".join(probs)
    except Exception as e:  # noqa: BLE001
        R["mupdf"] = f"err {type(e).__name__}: {e}"
    # pdfminer
    try:
        m = miner_outline(outp)
        R["miner"] = "ok" if eq(m["outline"], exp) else diff(m["outline"], exp)
    except Exception as e:  # noqa: BLE001
        R["miner"] = f"err {type(e).__name__}: {e}"
    R.update(roundtrips(label.replace(" ↻", ".re"), outp, exp, mulu, reapply_toc, reapply_exp))
    return R


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--mulu", default=str(ROOT / ".build" / "release" / "mulu"))
    ap.add_argument("--jobs", type=int, default=6)
    a = ap.parse_args()
    only = {x for x in a.only.split(",") if x}
    man = json.loads((GEN / "manifest.json").read_text(encoding="utf-8"))["fixtures"]
    jobs = []
    for name, m in man.items():
        if m.get("status") != "ok" or m.get("expect") == "refuse" or (only and name not in only):
            continue
        pages = m["facts"]["pages"]
        exp = json.loads((GEN / f"{name}.expected.json").read_text(encoding="utf-8"))
        rt = GEN / f"{name}.reapply.toc.txt"
        rexp = json.loads((GEN / f"{name}.reapply.expected.json").read_text(encoding="utf-8")) if rt.exists() else exp
        o1 = OUT / f"{name}.pdf"
        if o1.exists():
            jobs.append((name, GEN / f"{name}.pdf", o1, exp, pages, a.mulu, rt if rt.exists() else
                         GEN / f"{name}.toc.txt", rexp if rt.exists() else exp, name))
        o2 = OUT / f"{name}.reapply.pdf"
        if o2.exists():
            jobs.append((name, o1, o2, rexp, pages, a.mulu, None, None, f"{name} ↻"))
    cols = ["ql", "mdls", "mupdf", "miner", "rt-pdfkit", "rt-pdfkit+mulu", "rt-qpdf", "rt-mupdf", "rt-pypdf"]
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        results = list(ex.map(lambda j: check_case(*j), jobs))
    print(f"{'fixture':<28}" + "".join(f"{c:>15}" for c in cols))
    fails = []
    for r in results:
        row = f"{r['label']:<28}"
        for c in cols:
            v = r.get(c, "-")
            row += f"{('ok' if v == 'ok' else ('-' if v == '-' else 'FAIL')):>15}"
            if v not in ("ok", "-"):
                fails.append(f"{r['label']} [{c}] {v}")
        print(row)
    print(f"\n{len(results) - len({f.split(' [')[0] for f in fails})}/{len(results)} rows clean")
    for f in fails:
        print("  - " + f)
    (OUT / "system_report.json").write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
