# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9", "pypdf>=5", "pymupdf>=1.24", "cryptography>=42"]
# ///
"""chains.py -- interleave mulu updates with other producers' incremental updates:
   mulu x5 in a row; mulu -> pypdf incremental -> mulu; mulu -> MuPDF saveIncr -> mulu; mulu -> PDFKit write -> mulu.
Each final file is checked by the verify.py reader set (via `verify.py readers`) and MuPDF repair flag."""
import json, os, shutil, subprocess, sys
from pathlib import Path
PM = Path(__file__).resolve().parent.parent / "producer-matrix"
ROOT = PM.parents[2]
MULU = ROOT / ".build/release/mulu"
D = Path(__file__).resolve().parent / "pm_chains_out"
D.mkdir(parents=True, exist_ok=True)
GEN = PM / "gen"

def toc(k, n):
    rows = [(0, f"第{k}版 Rev {k} 目录", 1), (1, f"{k}.1 小节 section", min(2, n)), (2, f"{k}.1.1 深 deep", n)]
    return "\n".join("\t" * l + f"{t} {p}" for l, t, p in rows) + "\n", \
           [{"title": t, "level": l, "page_index": p - 1} for l, t, p in rows]

def mulu(inp, out, k, n):
    t, exp = toc(k, n)
    tp = out.with_suffix(".toc.txt"); tp.write_text(t, encoding="utf-8")
    out.unlink(missing_ok=True)
    p = subprocess.run([MULU, "apply", inp, tp, "-o", out], capture_output=True)
    assert p.returncode == 0, f"mulu apply {inp.name}: {p.stderr.decode()}"
    assert out.read_bytes().startswith(Path(inp).read_bytes()), "prefix broken"
    return exp

def pypdf_incr(inp, out):
    from pypdf import PdfWriter
    w = PdfWriter(str(inp), incremental=True)
    w.add_metadata({"/Subject": "pypdf incremental on top of mulu"})
    w.write(out)

def mupdf_incr(inp, out):
    import pymupdf
    shutil.copyfile(inp, out)
    d = pymupdf.open(out)
    d[0].insert_text((72, 40), "MuPDF incremental edit", fontsize=9)
    d.saveIncr(); d.close()

def pdfkit(inp, out):
    subprocess.run([ROOT / "tools/verify/.bin/pdfkit_resave", inp, out], capture_output=True, check=True)

def readers(path):
    p = subprocess.run([os.environ.get("UV") or shutil.which("uv") or str(Path.home() / ".local/bin/uv"), "run", "--quiet", "--python", "3.12",
                        ROOT / "tools/verify/verify.py", "readers", "-v", path, "--mulu", MULU],
                       capture_output=True, cwd=ROOT)
    return p.stdout.decode()

def mupdf_state(path):
    import pymupdf
    pymupdf.TOOLS.mupdf_warnings(reset=True)
    d = pymupdf.open(path)
    toc_ = [{"title": t, "level": l - 1, "page_index": p - 1} for l, t, p in d.get_toc()]
    r = d.is_repaired; d.close()
    return toc_, r, pymupdf.TOOLS.mupdf_warnings(reset=True)

import pikepdf
results = []
for base in ["qpdf_objstm", "quartz_linearized", "chrome_print", "pdfkit_outline", "mupdf_objstm",
             "pdflib_objstm", "chain_quartz_mupdf_incr", "qpdf_objstm_linearize"]:
    src = GEN / f"{base}.pdf"
    n = len(pikepdf.open(src).pages)
    for chain in ["mulu5", "pypdf", "mupdf", "pdfkit"]:
        cur, exp = src, None
        try:
            if chain == "mulu5":
                for k in range(1, 6):
                    nxt = D / f"{base}.{chain}.{k}.pdf"; exp = mulu(cur, nxt, k, n); cur = nxt
            else:
                a = D / f"{base}.{chain}.1.pdf"; mulu(cur, a, 1, n)
                b = D / f"{base}.{chain}.2.pdf"
                {"pypdf": pypdf_incr, "mupdf": mupdf_incr, "pdfkit": pdfkit}[chain](a, b)
                c = D / f"{base}.{chain}.3.pdf"; exp = mulu(b, c, 2, n); cur = c
            base_in = src if chain == "mulu5" else b
            def parse(txt, path):
                R = {}
                for line in txt.splitlines():
                    s = line.strip(); r = s.split(" ")[0]
                    if r in ("pdfkit", "qpdf", "pdfium", "pypdf", "pdfjs", "mulu"):
                        import re as _re
                        s2 = s.replace(str(path), "<f>")
                        s2 = _re.sub(r"(offset|at offset) \d+", "offset N", s2)
                        w = s2.split("warnings=", 1)[1] if "warnings=" in s2 else ""
                        R[r] = (s2, w)
                return R
            txt = readers(cur)
            mt, rep, mw = mupdf_state(cur)
            R1, R0, RS = parse(txt, cur), parse(readers(base_in), base_in), parse(readers(src), src)
            bad = []
            for r, (s2, w) in R1.items():
                if "ERROR" in s2 or f"items={len(exp)}" not in s2 or (r != "mulu" and f"pages={n}" not in s2):
                    bad.append(s2[:160])
                # verify.py `readers` prints only the first 2 warnings, so a warning set that equals the
                # untouched producer file (src) is also accepted (masked there by a third-party update)
                elif w != "[]" and w not in (R0.get(r, ("", ""))[1], RS.get(r, ("", ""))[1]):
                    bad.append(f"new warnings {r}: {w[:200]} (base {R0.get(r, ('', ''))[1][:120]})")
            titles = [l.strip().rsplit("  ->", 1)[0] for l in txt.splitlines() if "  -> " in l]
            want = [e["title"] for e in exp]
            if any(t not in want for t in titles):
                bad.append(f"stale titles seen: {sorted(set(titles) - set(want))[:3]}")
            if mt != exp:
                bad.append(f"MuPDF toc {mt[:2]}")
            if rep:
                bad.append("MuPDF repaired the file")
            results.append((base, chain, "ok" if not bad else "FAIL", bad))
        except Exception as e:  # noqa: BLE001
            results.append((base, chain, "ERR", [f"{type(e).__name__}: {e}"[:300]]))
for base, chain, st, bad in results:
    print(f"{base:<26} {chain:<7} {st}  {'; '.join(bad)[:600]}")
print(f"{sum(r[2] == 'ok' for r in results)}/{len(results)} chains ok")
sys.exit(0 if all(r[2] == "ok" for r in results) else 1)
