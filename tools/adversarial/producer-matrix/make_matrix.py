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
make_matrix.py -- producer-matrix fixture generator for the mulu adversarial run.

    uv run --python 3.12 tools/adversarial/producer-matrix/make_matrix.py [--only a,b]

Writes tools/adversarial/producer-matrix/gen/<name>.pdf + .toc.txt + .expected.json (+ .expect/.reapply.*)
and gen/manifest.json in the format tools/verify/verify.py `run-all --gen` consumes.
Every PDF is produced locally (no user files, no downloads).
"""
from __future__ import annotations

import argparse
import io
import json
import os
import shutil
import subprocess
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
GEN = HERE / "gen"
SRC = HERE / "src"
PRODUCERS = HERE / ".bin" / "producers"
NODE = HERE / "node"
FONT_TTF = Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
SCRATCH = Path(os.environ.get("PM_SCRATCH", HERE / ".scratch"))

# ---------------------------------------------------------------- TOC (3 levels, CJK + English)
TOC_ROWS = [  # (level, title, page 1-based)
    (0, "第一章 Introduction 引言", 1),
    (1, "1.1 背景 Background", 1),
    (2, "1.1.1 细节 Details — “quotes” & (parens)", 2),
    (2, "1.1.2 符号 Symbols ½ ∑ → 🚀", 2),
    (1, "1.2 方法 Method", 3),
    (0, "第二章 Results 结果", 4),
    (1, "2.1 数据 Data", 5),
    (2, "2.1.1 表格 Tables 表", 6),
    (0, "附录 Appendix 付録", 9999),  # -> last page
]
REAPPLY_ROWS = [
    (0, "新目录 Second Outline", 1),
    (1, "第二版 v2 — 章节", 9999),
    (2, "深层 deep 三级", 2),
]


def toc_for(rows, n):
    out, exp = [], []
    for lvl, title, p in rows:
        page = min(p, n)
        out.append("\t" * lvl + f"{title} {page}")
        exp.append({"title": title, "level": lvl, "page_index": page - 1})
    return "# producer-matrix TOC (tab indented)\n" + "\n".join(out) + "\n", exp


# ---------------------------------------------------------------- helpers
def run(cmd, **kw):
    p = subprocess.run([str(c) for c in cmd], capture_output=True, timeout=kw.pop("timeout", 180), **kw)
    if p.returncode != 0:
        raise RuntimeError(f"{Path(str(cmd[0])).name} exit {p.returncode}: "
                           f"{p.stderr.decode(errors='replace').strip()[-400:]}")
    return p


def html_doc(pages=6, headings=True):
    parts = ["<!doctype html><html><head><meta charset='utf-8'><title>HTML 矩阵 producer matrix</title>",
             "<style>body{font-family:'PingFang SC',Helvetica;font-size:14px} .pb{page-break-after:always}"
             " h1{color:#246} table{border-collapse:collapse} td{border:1px solid #888;padding:3px}</style>"
             "</head><body>"]
    for p in range(1, pages + 1):
        parts.append(f"<div class='pb'><h1>第 {p} 章 Chapter {p}</h1>" if headings else f"<div class='pb'>")
        parts.append(f"<h2>{p}.1 小节 Section</h2><p>增量更新不改原始字节 — incremental updates keep "
                     f"the original bytes. <a href='https://example.com/{p}'>link {p}</a></p>")
        parts.append("<table>" + "".join(f"<tr><td>{p}.{r}</td><td>数据 data {r*p}</td></tr>" for r in range(8))
                     + "</table>")
        parts.append("<p>" + ("中文段落 English paragraph. " * 40) + "</p></div>")
    parts.append("</body></html>")
    return "".join(parts)


def text_doc(pages=5):
    lines = []
    for p in range(1, pages + 1):
        for k in range(60):
            lines.append(f"Page-ish {p} line {k + 1}: 纯文本 plain text 目录测试 cupsfilter")
    return "\n".join(lines) + "\n"


def make_png(path: Path, w=1200, h=1600, seed=0, mode="RGB"):
    from PIL import Image, ImageDraw
    img = Image.new(mode, (w, h), "white" if mode != "1" else 1)
    d = ImageDraw.Draw(img)
    for i in range(0, w, 40):
        d.line([(i, 0), (w - i, h)], fill=(i * 7 + seed) % 255 if mode in ("L", "1") else
               ((i + seed) % 255, (i * 3) % 255, (i * 5 + seed) % 255), width=3)
    d.rectangle([100, 100, 600, 300], outline=0 if mode in ("L", "1") else (0, 0, 0), width=6)
    img.save(path)
    return path


def reportlab_doc(path: Path, pages: int, cjk_ttf=False, outline=False, invariant=True, compress=1):
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.cidfonts import UnicodeCIDFont
    c = canvas.Canvas(str(path), pagesize=A4, invariant=invariant, pageCompression=compress)
    c.setTitle("reportlab 矩阵")
    if cjk_ttf:
        from reportlab.pdfbase.ttfonts import TTFont
        pdfmetrics.registerFont(TTFont("AU", str(FONT_TTF)))
        font = "AU"
    else:
        pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
        font = "STSong-Light"
    for p in range(1, pages + 1):
        c.setFont(font, 20)
        c.drawString(72, 770, f"第 {p} 页 reportlab page {p}")
        c.setFont(font, 10)
        for k in range(30):
            c.drawString(72, 740 - k * 20, f"{p}.{k} 增量更新 incremental update line")
        if outline and p <= 3:
            key = f"k{p}"
            c.bookmarkPage(key)
            c.addOutlineEntry(f"旧 reportlab 书签 {p}", key, level=0)
        c.showPage()
    c.save()


# ---------------------------------------------------------------- producers
# each returns nothing; writes `out`. Many derive from a base made by another producer.
def base_quartz(out, n=12, *flags):
    run([PRODUCERS, "quartz", out, n, *flags])


def P(name, desc, reapply=False, refuse=False):
    def deco(fn):
        REG.append((name, desc, reapply, refuse, fn))
        return fn
    return deco


REG: list = []

# ---- Apple Quartz (CGPDFContext)
for _flags, _nm, _rp in [((), "quartz_plain", True), (("--outline",), "quartz_outline", True),
                         (("--dests", "--links"), "quartz_dests_links", False),
                         (("--linearized",), "quartz_linearized", True), (("--pdfa",), "quartz_pdfa", False),
                         (("--tagged",), "quartz_tagged", False)]:
    P(_nm, f"CGPDFContext {' '.join(_flags) or '(plain)'}", reapply=_rp)(
        lambda out, _f=_flags: base_quartz(out, 12, *_f))
P("quartz_ownerpw", "CGPDFContext owner password only (RC4/AES, empty user pw)", refuse=True)(
    lambda out: base_quartz(out, 4, "--owner-pw"))
P("quartz_userpw", "CGPDFContext user+owner password", refuse=True)(
    lambda out: base_quartz(out, 4, "--user-pw"))


# ---- PDFKit write
def _pk(sub):
    def f(out):
        base = SCRATCH / "quartz_links_base.pdf"
        base_quartz(base, 9, "--dests", "--links")
        run([PRODUCERS, sub, base, out])
    return f


P("pdfkit_resave", "PDFDocument.write of a Quartz file")(_pk("pdfkit-resave"))
P("pdfkit_outline", "PDFKit outlineRoot set, then write (existing outline to replace)", reapply=True)(
    _pk("pdfkit-outline"))
P("pdfkit_annots", "PDFKit highlight/note/link/freeText annotations, then write")(_pk("pdfkit-annots"))


@P("pdfkit_merge", "PDFKit page copy from Quartz + reportlab + pdf-lib documents")
def _(out):
    a, b, c = SCRATCH / "m_a.pdf", SCRATCH / "m_b.pdf", SCRATCH / "m_c.pdf"
    base_quartz(a, 3)
    reportlab_doc(b, 3)
    run(["node", NODE / "produce.mjs", "pdflib-objstm", c, 3], cwd=NODE)
    run([PRODUCERS, "pdfkit-merge", out, a, b, c])


@P("pdfkit_encrypt", "PDFKit write with owner password", refuse=True)
def _(out):
    base = SCRATCH / "enc_base.pdf"
    base_quartz(base, 3)
    run([PRODUCERS, "pdfkit-encrypt", base, out, "", "owner"])


@P("pdfkit_of_objstm", "PDFKit resave of a pdf-lib object-stream file")
def _(out):
    base = SCRATCH / "objstm_base.pdf"
    run(["node", NODE / "produce.mjs", "pdflib-objstm", base, 7], cwd=NODE)
    run([PRODUCERS, "pdfkit-resave", base, out])


# ---- WebKit / AppKit printing
def _html_src(name, pages=6, headings=True):
    SRC.mkdir(exist_ok=True)
    p = SRC / name
    p.write_text(html_doc(pages, headings), encoding="utf-8")
    return p


P("webkit_createpdf", "WKWebView.createPDF (one tall page)")(
    lambda out: run([PRODUCERS, "webkit-createpdf", _html_src("wk.html"), out], timeout=90))
P("webkit_print", "WKWebView.printOperation -> PDF (paginated)", reapply=True)(
    lambda out: run([PRODUCERS, "webkit-print", _html_src("wk.html"), out], timeout=90))


@P("textview_print_rtf", "NSTextView + NSPrintOperation from RTF (textutil html->rtf)")
def _(out):
    h = _html_src("tv.html", 5)
    rtf = SRC / "tv.rtf"
    run(["/usr/bin/textutil", "-convert", "rtf", "-output", rtf, h])
    run([PRODUCERS, "textview-print", rtf, out], timeout=90)


# ---- CUPS
@P("cups_text", "cupsfilter text/plain -> PDF", reapply=True)
def _(out):
    SRC.mkdir(exist_ok=True)
    t = SRC / "plain.txt"
    t.write_text(text_doc(5), encoding="utf-8")
    p = run(["/usr/sbin/cupsfilter", "-i", "text/plain", "-m", "application/pdf", t])
    Path(out).write_bytes(p.stdout)


@P("cups_html", "cupsfilter text/html -> PDF")
def _(out):
    h = _html_src("cups.html", 4)
    p = run(["/usr/sbin/cupsfilter", "-i", "text/html", "-m", "application/pdf", h])
    Path(out).write_bytes(p.stdout)


@P("textutil_cups", "textutil rtf->html, then cupsfilter html -> PDF")
def _(out):
    SRC.mkdir(exist_ok=True)
    rtf = SRC / "tu.rtf"
    rtf.write_text("{\\rtf1\\ansi\\ansicpg1252{\\fonttbl\\f0 Helvetica;}\\f0\\fs28 "
                   + "\\par ".join(f"Line {i} textutil \\u30446?\\u24405? mulu" for i in range(400)) + "}",
                   encoding="ascii")
    html = SRC / "tu.html"
    run(["/usr/bin/textutil", "-convert", "html", "-output", html, rtf])
    p = run(["/usr/sbin/cupsfilter", "-i", "text/html", "-m", "application/pdf", html])
    Path(out).write_bytes(p.stdout)


# ---- sips
@P("sips_png", "sips PNG -> PDF (single image page)")
def _(out):
    png = make_png(SCRATCH / "sips.png")
    run(["/usr/bin/sips", "-s", "format", "pdf", png, "--out", out])


@P("sips_jpeg", "sips JPEG -> PDF")
def _(out):
    from PIL import Image
    png = make_png(SCRATCH / "sips2.png", seed=40)
    jpg = SCRATCH / "sips2.jpg"
    Image.open(png).convert("RGB").save(jpg, quality=85)
    run(["/usr/bin/sips", "-s", "format", "pdf", jpg, "--out", out])


# ---- Chrome headless
def _chrome(out, outline):
    if not CHROME.exists():
        raise FileNotFoundError("Google Chrome not installed")
    h = _html_src("chrome.html", 6)
    prof = SCRATCH / "chrome-profile"
    cmd = [CHROME, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
           "--disable-extensions", "--disable-sync", f"--user-data-dir={prof}", "--no-pdf-header-footer",
           f"--print-to-pdf={out}"]
    if outline:
        cmd.append("--generate-pdf-document-outline")
    cmd.append(h.as_uri())
    # Chrome headless writes the PDF but often never exits: poll until the file is stable, then kill it.
    import time
    Path(out).unlink(missing_ok=True)
    proc = subprocess.Popen([str(c) for c in cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    last, stable, t0 = -1, 0, time.time()
    try:
        while time.time() - t0 < 90:
            time.sleep(0.5)
            sz = Path(out).stat().st_size if Path(out).exists() else -1
            if sz > 0 and sz == last and Path(out).read_bytes().rstrip().endswith(b"%%EOF"):
                stable += 1
                if stable >= 2:
                    break
            else:
                stable = 0
            last = sz
            if proc.poll() is not None and sz > 0:
                break
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
    if not Path(out).exists() or Path(out).stat().st_size == 0:
        raise RuntimeError("chrome wrote no PDF")


P("chrome_print", "Chrome headless --print-to-pdf (Skia)", reapply=True)(lambda out: _chrome(out, False))
P("chrome_outline", "Chrome headless --generate-pdf-document-outline (existing outline)")(
    lambda out: _chrome(out, True))

# ---- reportlab
P("reportlab_cid", "reportlab STSong-Light CID font, classic xref")(lambda out: reportlab_doc(Path(out), 10))
P("reportlab_ttf_outline", "reportlab embedded Arial Unicode subset + existing outline", reapply=True)(
    lambda out: reportlab_doc(Path(out), 10, cjk_ttf=True, outline=True))
P("reportlab_nocompress", "reportlab pageCompression=0, invariant=0")(
    lambda out: reportlab_doc(Path(out), 6, compress=0, invariant=False))


# ---- qpdf via pikepdf
def _rl_base(n=10):
    b = SCRATCH / f"rl_base_{n}.pdf"
    if not b.exists():
        reportlab_doc(b, n, cjk_ttf=True, outline=True)
    return b


@P("qpdf_objstm", "qpdf --object-streams=generate (xref stream, predictor 12)", reapply=True)
def _(out):
    import pikepdf
    with pikepdf.open(_rl_base()) as pdf:
        pdf.save(out, object_stream_mode=pikepdf.ObjectStreamMode.generate)


@P("qpdf_linearize", "qpdf --linearize (classic hybrid first-page xref)")
def _(out):
    import pikepdf
    with pikepdf.open(_rl_base()) as pdf:
        pdf.save(out, linearize=True)


@P("qpdf_objstm_linearize", "qpdf --object-streams=generate --linearize", reapply=True)
def _(out):
    import pikepdf
    with pikepdf.open(_rl_base()) as pdf:
        pdf.save(out, linearize=True, object_stream_mode=pikepdf.ObjectStreamMode.generate)


@P("qpdf_qdf", "qpdf --qdf (uncompressed, normalized content)")
def _(out):
    import pikepdf
    with pikepdf.open(_rl_base()) as pdf:
        pdf.save(out, qdf=True, object_stream_mode=pikepdf.ObjectStreamMode.disable)


@P("qpdf_objstm_nopred", "qpdf object streams, deterministic_id, generalized re-compression")
def _(out):
    import pikepdf
    with pikepdf.open(_rl_base()) as pdf:
        pdf.save(out, object_stream_mode=pikepdf.ObjectStreamMode.generate, deterministic_id=True,
                 stream_decode_level=pikepdf.StreamDecodeLevel.generalized)


@P("qpdf_aes256", "qpdf AES-256 encryption (R6)", refuse=True)
def _(out):
    import pikepdf
    with pikepdf.open(_rl_base()) as pdf:
        pdf.save(out, encryption=pikepdf.Encryption(owner="o", user="", R=6))


# ---- img2pdf
@P("img2pdf_jpeg", "img2pdf JPEG pages (DCT passthrough), 3 pages")
def _(out):
    import img2pdf
    from PIL import Image
    jpgs = []
    for i in range(3):
        png = make_png(SCRATCH / f"i2p{i}.png", seed=i * 30)
        j = SCRATCH / f"i2p{i}.jpg"
        Image.open(png).convert("RGB").save(j, quality=80)
        jpgs.append(str(j))
    Path(out).write_bytes(img2pdf.convert(jpgs))


@P("img2pdf_png_gray", "img2pdf grayscale + bilevel PNG pages (Flate+predictor image streams)", reapply=True)
def _(out):
    import img2pdf
    a = make_png(SCRATCH / "i2p_l.png", mode="L")
    b = make_png(SCRATCH / "i2p_1.png", mode="1", w=800, h=1000)
    Path(out).write_bytes(img2pdf.convert([str(a), str(b)]))


# ---- pypdf writer
@P("pypdf_writer", "pypdf PdfWriter clone of reportlab (with outline) + compress")
def _(out):
    from pypdf import PdfReader, PdfWriter
    w = PdfWriter(clone_from=PdfReader(_rl_base()))
    w.compress_identical_objects()
    for pg in w.pages:
        pg.compress_content_streams()
    w.write(out)


@P("pypdf_add_outline", "pypdf builds pages + its own outline + page labels", reapply=True)
def _(out):
    from pypdf import PdfReader, PdfWriter
    from pypdf.generic import NameObject
    w = PdfWriter()
    for pg in PdfReader(_rl_base()).pages:
        w.add_page(pg)
    p0 = w.add_outline_item("pypdf 旧书签", 0)
    w.add_outline_item("pypdf 子项", 1, parent=p0)
    w.set_page_label(0, 1, "/r")
    w.set_page_label(2, 9, "/D", prefix="P-")
    w.page_mode = NameObject("/UseThumbs")
    w.write(out)


@P("pypdf_incremental", "pypdf incremental=True update (file already has 2 revisions)", reapply=True)
def _(out):
    from pypdf import PdfWriter
    w = PdfWriter(_rl_base(), incremental=True)
    w.add_metadata({"/Subject": "pypdf incremental 增量"})
    w.write(out)


# ---- MuPDF via pymupdf
@P("mupdf_garbage", "MuPDF save(garbage=4, deflate=True, clean=True)")
def _(out):
    import pymupdf
    d = pymupdf.open(_rl_base())
    d.save(out, garbage=4, deflate=True, clean=True)


@P("mupdf_objstm", "MuPDF save(use_objstms=1, garbage=3) -> xref stream + object streams", reapply=True)
def _(out):
    import pymupdf
    d = pymupdf.open(_rl_base())
    d.save(out, garbage=3, deflate=True, use_objstms=1)


@P("mupdf_incremental", "MuPDF saveIncr() on a MuPDF-created file (existing TOC via set_toc)")
def _(out):
    import pymupdf
    d = pymupdf.open()
    for i in range(8):
        pg = d.new_page()
        pg.insert_text((72, 72), f"MuPDF page {i + 1}", fontsize=20)
    d.set_toc([[1, "MuPDF old 旧", 1], [2, "child", 2]])
    tmp = SCRATCH / "mupdf_inc.pdf"
    d.save(tmp)
    d.close()
    shutil.copyfile(tmp, out)
    d = pymupdf.open(out)
    d[0].insert_text((72, 120), "incremental edit", fontsize=12)
    d.saveIncr()
    d.close()


@P("mupdf_newdoc", "MuPDF new document with CJK text (insert_htmlbox)")
def _(out):
    import pymupdf
    d = pymupdf.open()
    for i in range(7):
        pg = d.new_page()
        pg.insert_htmlbox(pymupdf.Rect(50, 50, 550, 750),
                          f"<h1>第 {i + 1} 页 MuPDF</h1><p>" + "中文 English 混排。" * 60 + "</p>")
    d.save(out, garbage=1, deflate=True)


# ---- fpdf2 / matplotlib
@P("fpdf2_ttf", "fpdf2 with embedded Arial Unicode subset")
def _(out):
    from fpdf import FPDF
    pdf = FPDF()
    pdf.add_font("AU", "", str(FONT_TTF))
    pdf.set_font("AU", size=14)
    for i in range(6):
        pdf.add_page()
        pdf.multi_cell(0, 8, f"第 {i + 1} 页 fpdf2 page\n" + "增量更新 incremental. " * 30)
    pdf.output(out)


@P("matplotlib_pdf", "matplotlib PdfPages (Type3/Type42 fonts), 4 pages")
def _(out):
    import matplotlib
    matplotlib.use("pdf")
    import matplotlib.pyplot as plt
    from matplotlib.backends.backend_pdf import PdfPages
    with PdfPages(out) as pp:
        for i in range(4):
            fig, ax = plt.subplots()
            ax.plot([x * (i + 1) for x in range(20)])
            ax.set_title(f"figure {i + 1}")
            pp.savefig(fig)
            plt.close(fig)


# ---- JavaScript producers
for _k, _rp in [("pdflib-objstm", True), ("pdflib-classic", False), ("pdflib-cjk", False), ("jspdf", True),
                ("pdfkitjs", False), ("pdfkitjs-outline", True)]:
    P(_k.replace("-", "_"), f"node {_k}", reapply=_rp)(
        lambda out, _k=_k: run(["node", NODE / "produce.mjs", _k, out, 8, FONT_TTF], cwd=NODE))


# ---- chains: producer A -> mulu-style consumer B (other tools touching each other's output)
@P("chain_chrome_qpdf_objstm", "Chrome PDF -> qpdf object streams")
def _(out):
    import pikepdf
    base = SCRATCH / "chrome_base.pdf"
    _chrome(base, True)
    with pikepdf.open(base) as pdf:
        pdf.save(out, object_stream_mode=pikepdf.ObjectStreamMode.generate)


@P("chain_quartz_mupdf_incr", "Quartz PDF -> MuPDF incremental save (hybrid-ish multi-revision)")
def _(out):
    import pymupdf
    base_quartz(out, 6)
    d = pymupdf.open(out)
    d.set_metadata({"title": "MuPDF on Quartz", "author": "x"})
    d.saveIncr()
    d.close()


@P("chain_pdflib_pypdf_incr", "pdf-lib xref-stream file -> pypdf incremental update")
def _(out):
    from pypdf import PdfWriter
    base = SCRATCH / "pl_inc_base.pdf"
    run(["node", NODE / "produce.mjs", "pdflib-objstm", base, 6], cwd=NODE)
    w = PdfWriter(str(base), incremental=True)
    w.add_metadata({"/Subject": "pypdf on pdf-lib"})
    w.write(out)


# ---------------------------------------------------------------- facts + manifest
def facts_of(path: Path):
    import pikepdf
    f = {"size": path.stat().st_size}
    try:
        with pikepdf.open(path) as pdf:
            f["pages"] = len(pdf.pages)
            f["encrypted"] = bool(pdf.is_encrypted)
            f["has_outline"] = "/Outlines" in pdf.Root and len(pdf.open_outline().root) > 0
            f["linearized"] = bool(pdf.is_linearized)
            tr = pdf.trailer
            f["producer"] = str(pdf.docinfo.get("/Producer", "")) if pdf.docinfo is not None else ""
    except pikepdf.PasswordError:
        f["encrypted"] = True
    head = path.read_bytes()
    tail = head[-2048:]
    f["xref_hint"] = "stream" if b"/XRef" in head and b"\nxref" not in tail and b"\rxref" not in tail else "classic"
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    only = {x for x in a.only.split(",") if x}
    if a.list:
        for n, d, *_ in REG:
            print(f"{n:28} {d}")
        return 0
    GEN.mkdir(parents=True, exist_ok=True)
    SCRATCH.mkdir(parents=True, exist_ok=True)
    mpath = GEN / "manifest.json"
    manifest = json.loads(mpath.read_text()) if mpath.exists() and only else {"fixtures": {}}
    for name, desc, reapply, refuse, fn in REG:
        if only and name not in only:
            continue
        out = GEN / f"{name}.pdf"
        for sfx in (".pdf", ".toc.txt", ".expected.json", ".expect", ".reapply.toc.txt", ".reapply.expected.json"):
            (GEN / f"{name}{sfx}").unlink(missing_ok=True)
        m = {"name": name, "description": desc, "expect": "refuse" if refuse else "apply", "offset": 0,
             "reapply": reapply, "perf_limit_ms": None, "notes": ""}
        try:
            fn(str(out))
            if not out.exists() or out.stat().st_size == 0:
                raise RuntimeError("producer wrote nothing")
            f = facts_of(out)
            n = f.get("pages") or 3
            toc, exp = toc_for(TOC_ROWS, n)
            (GEN / f"{name}.toc.txt").write_text(toc, encoding="utf-8")
            (GEN / f"{name}.expected.json").write_text(json.dumps(exp, ensure_ascii=False), encoding="utf-8")
            if refuse:
                (GEN / f"{name}.expect").write_text("refuse\n")
            if reapply:
                t2, e2 = toc_for(REAPPLY_ROWS, n)
                (GEN / f"{name}.reapply.toc.txt").write_text(t2, encoding="utf-8")
                (GEN / f"{name}.reapply.expected.json").write_text(json.dumps(e2, ensure_ascii=False),
                                                                   encoding="utf-8")
            facts = {k: v for k, v in f.items() if k in ("size", "pages", "encrypted", "has_outline", "linearized")}
            m.update(status="ok", facts=facts, producer_string=f.get("producer", ""), revisions_ambiguous=True)
            print(f"ok    {name:28} {f.get('pages', '?'):>3}p {f['size']:>8}B  {f.get('producer', '')[:50]}")
        except Exception as e:  # noqa: BLE001
            m.update(status="unavailable", notes=f"{type(e).__name__}: {e}"[:400])
            print(f"SKIP  {name:28} {m['notes'][:150]}")
            if os.environ.get("PM_DEBUG"):
                traceback.print_exc()
        manifest["fixtures"][name] = m
    mpath.write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
