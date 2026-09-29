# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pikepdf>=9",
#   "pypdf>=5",
#   "reportlab>=4",
#   "img2pdf>=0.5",
#   "pillow>=10",
#   "fpdf2>=2.7",
#   "pymupdf>=1.24",
#   "matplotlib>=3.8",
#   "cryptography>=42",
# ]
# ///
"""
make_big.py -- large documents from each producer, for the 500-page / <1 s requirement and big outlines.

    uv run --python 3.12 tools/adversarial/producer-matrix/make_big.py
    uv run --python 3.12 tools/verify/verify.py run-all --mulu .build/release/mulu \
        --gen tools/adversarial/producer-matrix/gen_big --out tools/adversarial/producer-matrix/out_big

Each fixture gets perf_limit_ms = 1000 (verify.py enforces best-of-3) and a ~3-entries-per-20-pages
3-level CJK+English TOC.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import make_matrix as M  # noqa: E402

GEN = HERE / "gen_big"


def big_toc(n):
    rows = []
    for c, start in enumerate(range(1, n + 1, 20)):
        rows.append((0, f"第{c + 1}章 Chapter {c + 1} 章节标题", start))
        if start + 5 <= n:
            rows.append((1, f"{c + 1}.1 小节 Section — “引号”", start + 5))
            if start + 7 <= n:
                rows.append((2, f"{c + 1}.1.1 条目 Item 🚀 ½", start + 7))
    rows.append((0, "索引 Index", n))
    return M.toc_for(rows, n)


def reportlab_big(out, n):
    M.reportlab_doc(Path(out), n)


def pikepdf_from(base_fn, n, **save):
    def f(out):
        import pikepdf
        b = M.SCRATCH / f"big_rl_{n}.pdf"
        if not b.exists():
            base_fn(b, n)
        with pikepdf.open(b) as p:
            p.save(out, **save)
    return f


def mupdf_objstm(out, n):
    import pymupdf
    b = M.SCRATCH / f"big_rl_{n}.pdf"
    if not b.exists():
        reportlab_big(b, n)
    d = pymupdf.open(b)
    d.save(out, garbage=3, deflate=True, use_objstms=1)


def build():
    import pikepdf
    return [
        ("big_quartz_2000", lambda o: M.base_quartz(o, 2000)),
        ("big_quartz_lin_1000", lambda o: M.base_quartz(o, 1000, "--linearized")),
        ("big_pdfkit_resave_1500", lambda o: (M.base_quartz(M.SCRATCH / "bq1500.pdf", 1500),
                                              M.run([M.PRODUCERS, "pdfkit-resave", M.SCRATCH / "bq1500.pdf", o]))),
        ("big_reportlab_2000", lambda o: reportlab_big(o, 2000)),
        ("big_qpdf_objstm_2000", pikepdf_from(reportlab_big, 2000,
                                              object_stream_mode=pikepdf.ObjectStreamMode.generate)),
        ("big_qpdf_objstm_lin_2000", pikepdf_from(reportlab_big, 2000, linearize=True,
                                                  object_stream_mode=pikepdf.ObjectStreamMode.generate)),
        ("big_mupdf_objstm_2000", lambda o: mupdf_objstm(o, 2000)),
        ("big_pdflib_objstm_3000", lambda o: M.run(["node", M.NODE / "produce.mjs", "pdflib-objstm", o, 3000],
                                                   cwd=M.NODE, timeout=300)),
        ("big_jspdf_2000", lambda o: M.run(["node", M.NODE / "produce.mjs", "jspdf", o, 2000], cwd=M.NODE,
                                           timeout=300)),
        ("big_pdfkitjs_1000", lambda o: M.run(["node", M.NODE / "produce.mjs", "pdfkitjs", o, 1000], cwd=M.NODE,
                                              timeout=300)),
        ("big_webkit_print_500", lambda o: (M.SRC.mkdir(exist_ok=True),
                                            (M.SRC / "big.html").write_text(M.html_doc(500), encoding="utf-8"),
                                            M.run([M.PRODUCERS, "webkit-print", M.SRC / "big.html", o],
                                                  timeout=300))),
        ("big_chrome_500", lambda o: _chrome_big(o, 500)),
    ]


def _chrome_big(o, n):
    M.SRC.mkdir(exist_ok=True)
    src = M.SRC / "chrome.html"
    keep = src.read_text(encoding="utf-8") if src.exists() else None
    orig = M.html_doc
    M.html_doc = lambda pages=6, headings=True: orig(n, headings)
    try:
        M._chrome(o, False)
    finally:
        M.html_doc = orig
        if keep is not None:
            src.write_text(keep, encoding="utf-8")


def main():
    GEN.mkdir(parents=True, exist_ok=True)
    M.SCRATCH.mkdir(parents=True, exist_ok=True)
    only = set(sys.argv[1].split(",")) if len(sys.argv) > 1 else set()
    mpath = GEN / "manifest.json"
    manifest = json.loads(mpath.read_text()) if mpath.exists() and only else {"fixtures": {}}
    for name, fn in build():
        if only and name not in only:
            continue
        out = GEN / f"{name}.pdf"
        out.unlink(missing_ok=True)
        m = {"name": name, "description": name, "expect": "apply", "offset": 0, "reapply": False,
             "perf_limit_ms": 1000, "notes": ""}
        try:
            fn(str(out))
            f = M.facts_of(out)
            toc, exp = big_toc(f["pages"])
            (GEN / f"{name}.toc.txt").write_text(toc, encoding="utf-8")
            (GEN / f"{name}.expected.json").write_text(json.dumps(exp, ensure_ascii=False), encoding="utf-8")
            m.update(status="ok", revisions_ambiguous=True,
                     facts={k: v for k, v in f.items() if k in ("size", "pages", "encrypted", "has_outline",
                                                                "linearized")})
            print(f"ok    {name:28} {f['pages']:>5}p {f['size']:>10}B  toc={len(exp)}")
        except Exception as e:  # noqa: BLE001
            m.update(status="unavailable", notes=f"{type(e).__name__}: {e}"[:300])
            print(f"SKIP  {name:28} {m['notes'][:160]}")
        manifest["fixtures"][name] = m
    mpath.write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
