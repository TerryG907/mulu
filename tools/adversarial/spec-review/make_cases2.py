# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pikepdf>=9",
# ]
# ///
"""
make_cases2.py -- second batch of spec-review fixtures (resumed run). Writes gen2/ + manifest.json.

    uv run --python 3.12 tools/adversarial/spec-review/make_cases2.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pikepdf

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from make_cases import (TOC3, Doc, content, objstm, rows_of, std_objects, stream_simple,  # noqa: E402
                        classic_simple, toc_files)

GEN = HERE / "gen2"
CASES = {}


def case(name, **meta):
    def deco(fn):
        CASES[name] = (fn, meta)
        return fn
    return deco


def break_startxref(pdf: bytes) -> bytes:
    """Point the last startxref at offset 20 (inside the header comment) so the chain is unusable."""
    i = pdf.rindex(b"startxref")
    j = pdf.index(b"%%EOF", i)
    return pdf[:i] + b"startxref\n20\n" + pdf[j:]


# --- xref reconstruction path (no /Prev, complete table) ---

@case("sr2_recon_classic", notes="single-revision classic file, startxref points into the header -> mulu reconstructs",
      xref="classic")
def _():
    return break_startxref(classic_simple()), *toc_files(TOC3)


@case("sr2_recon_junk8", notes="8 junk bytes before %PDF-, header-relative offsets, broken startxref -> reconstruct; "
                               "the complete table mulu writes must use the readers' (header-relative) frame",
      xref="classic")
def _():
    return b"GARBAGE\n" + break_startxref(classic_simple()), *toc_files(TOC3)


@case("sr2_recon_objstm", notes="xref stream + catalog/pages in an ObjStm, broken startxref -> reconstruct with "
                                "compressed objects (complete xref stream, type-2 rows)", xref="stream")
def _():
    d = Doc(header=b"%PDF-1.5\n%\xb5\xb5\xb5\xb5\n")
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(3):
        d.stream(5 + 2 * i, b"", content(i + 1))
    pairs = [(1, b"<< /Type /Catalog /Pages 2 0 R >>"),
             (2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>")]
    pairs += [(4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                          f"/Contents {5 + 2 * i} 0 R >>".encode()) for i in range(3)]
    inner, data = objstm(pairs)
    d.stream(10, inner, data)
    rows = {0: (0, 0, 65535)}
    for n, (o, g) in d.off.items():
        rows[n] = (1, o, g)
    for k, (n, _) in enumerate(pairs):
        rows[n] = (2, 10, k)
    x = d.xref_stream(11, rows, b"/Root 1 0 R")
    d.startxref(x)
    return break_startxref(d.bytes()), *toc_files(TOC3)


# --- hybrid, single revision: the table lists the compressed objects as FREE entries ---

@case("sr2_hybrid_table_free", notes="single-revision hybrid; pages compressed, table marks 4/6/8 free, /XRefStm has "
                                     "type-2 rows for them", xref="hybrid")
def _():
    d = Doc(header=b"%PDF-1.5\n%\xb5\xb5\xb5\xb5\n")
    d.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    d.obj(2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>")
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(3):
        d.stream(5 + 2 * i, b"", content(i + 1))
    pairs = [(4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                          f"/Contents {5 + 2 * i} 0 R >>".encode()) for i in range(3)]
    inner, data = objstm(pairs)
    d.stream(10, inner, data)
    srows = {n: (2, 10, k) for k, (n, _) in enumerate(pairs)}
    xs = d.xref_stream(11, srows, b"", size=12)
    rows = rows_of(d)
    del rows[11]
    for n, _ in pairs:
        rows[n] = ("f", 0, 0)
    x = d.classic_xref(rows, f"<< /Size 12 /Root 1 0 R /XRefStm {xs} >>".encode())
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


def main():
    GEN.mkdir(exist_ok=True)
    manifest = {"fixtures": {}}
    for name, (fn, meta) in CASES.items():
        pdf, toc, exp = fn()
        (GEN / f"{name}.pdf").write_bytes(pdf)
        (GEN / f"{name}.toc.txt").write_text(toc, encoding="utf-8")
        (GEN / f"{name}.expected.json").write_text(json.dumps(exp, ensure_ascii=False), encoding="utf-8")
        refuse = meta.get("expect") == "refuse"
        if refuse:
            (GEN / f"{name}.expect").write_text("refuse\n")
        else:
            (GEN / f"{name}.expect").unlink(missing_ok=True)
        facts = {"size": len(pdf), "xref": meta.get("xref"), "encrypted": False}
        try:
            with pikepdf.open(GEN / f"{name}.pdf") as p:
                facts["pages"] = len(p.pages)
                facts["qpdf_warnings"] = [str(w) for w in p.get_warnings()]
        except Exception as e:  # noqa: BLE001
            facts["open_error"] = str(e)
        manifest["fixtures"][name] = {"name": name, "status": "ok", "expect": "refuse" if refuse else "apply",
                                      "offset": 0, "reapply": False, "perf_limit_ms": None,
                                      "notes": meta.get("notes", ""), "facts": facts,
                                      "allow_input_warnings": True}
        print(f"{name:<28} {len(pdf):>6} B pages={facts.get('pages')} qpdf_warn={facts.get('qpdf_warnings')}"
              f" {facts.get('open_error', '')}")
    (GEN / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
