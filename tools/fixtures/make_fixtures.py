# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pikepdf>=9",
#   "pillow>=10",
#   "img2pdf>=0.5",
#   "reportlab>=4",
# ]
# ///
"""
make_fixtures.py -- generate every mulu test PDF (no downloads, no personal files).

    uv run --python 3.12 tools/fixtures/make_fixtures.py [--only a,b] [--force] [--out DIR]

Writes into Fixtures/generated/:
    <name>.pdf, <name>.toc.txt, <name>.expected.json, [<name>.offset], [<name>.expect]
    [<name>.reapply.toc.txt, <name>.reapply.expected.json]   (second TOC for re-apply test)
    [<name>.preexisting.json]                                 (outline already in the input)
    manifest.json                                             (facts about every fixture)

Each builder asserts the property it is supposed to exercise (xref kind, CCITT
images, predictor, linearization, encryption, /Prev chain ...), so a fixture that
silently degenerated into something easier fails loudly here instead.
"""
from __future__ import annotations

import argparse
import io
import json
import random
import shutil
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "tools" / "verify"))

import pdfraw  # noqa: E402
from pdfraw import Name, Ref, PDFString  # noqa: E402
from toc_templates import BOOK, MANUAL, THESIS, spread, write_sidecars  # noqa: E402

import pikepdf  # noqa: E402

OUT = ROOT / "Fixtures" / "generated"
BIN = HERE / ".bin"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

CJK_FONT_CANDIDATES = [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
]


def pil_font(size: int):
    from PIL import ImageFont
    for p in CJK_FONT_CANDIDATES:
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size), p
            except OSError:
                continue
    try:
        return ImageFont.load_default(size=size), "PIL default (no CJK glyphs)"
    except TypeError:
        return ImageFont.load_default(), "PIL default bitmap (no CJK glyphs)"


def bmp_only(s: str) -> str:
    return "".join(ch for ch in s if ord(ch) <= 0xFFFF)


def facts(path: Path, pdf_password: str | None = None) -> dict:
    data = path.read_bytes()
    f = {"size": len(data)}
    try:
        f["xref"] = pdfraw.newest_xref_kind(data)
        f["revisions"] = len(pdfraw.revision_chain(data))
    except Exception as e:  # noqa: BLE001
        f["xref"] = f"unparsed: {e}"
        f["revisions"] = None
    try:
        with pikepdf.open(path, password=pdf_password or "") as pdf:
            f["pages"] = len(pdf.pages)
            f["encrypted"] = bool(pdf.is_encrypted)
            f["linearized"] = bool(pdf.is_linearized)
            f["has_outline"] = "/Outlines" in pdf.Root and len(pdf.open_outline().root) > 0
            f["qpdf_warnings"] = [str(w) for w in pdf.get_warnings()]
    except Exception as e:  # noqa: BLE001
        f["open_error"] = str(e)
    return f


def save_pikepdf(pdf, out: Path, **kw):
    pdf.save(out, deterministic_id="encryption" not in kw, **kw)


def page_images(pg):
    xo = pg.obj.get("/Resources", {}).get("/XObject", {})
    return [xo[k] for k in xo.keys() if xo[k].get("/Subtype") == "/Image"]


def filters_of(img):
    f = img.get("/Filter")
    if f is None:
        return []
    return [str(x) for x in f] if isinstance(f, pikepdf.Array) else [str(f)]


def text_lines_for_page(p: int, n: int = 30):
    base = [
        "本研究讨论增量更新在 PDF 书签写入中的应用，原始字节必须保持不变。",
        "Incremental updates (ISO 32000-1 §7.5.6) append new objects after %%EOF.",
        "扫描版电子书往往缺少目录，读者难以跳转到指定章节。",
        "The outline tree uses /First, /Last, /Next, /Prev and /Parent links.",
        "每一个书签条目都包含标题、层级与目标页面三个要素。",
        "Page trees may be nested; kids are walked in document order.",
    ]
    return [f"{base[(p + i) % len(base)]}  [{p}.{i + 1}]" for i in range(n)]


# ---------------------------------------------------------------------------
# builders -- each returns a dict of manifest extras (or raises)
# ---------------------------------------------------------------------------

def build_text_classic_cjk(out: Path, ctx):
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.cidfonts import UnicodeCIDFont
    from reportlab.pdfgen import canvas

    pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
    n = 30
    toc = spread(THESIS, n)
    heads = {}
    for lvl, t, p in toc:
        heads.setdefault(p, []).append((lvl, t))
    c = canvas.Canvas(str(out / "text_classic_cjk.pdf"), pagesize=A4, invariant=1)
    c.setTitle("文本 PDF 测试 text_classic_cjk")
    c.setAuthor("mulu fixtures")
    c.setSubject("reportlab + STSong-Light, classic xref")
    w, h = A4
    for p in range(1, n + 1):
        y = h - 70
        for lvl, t in heads.get(p, []):
            c.setFont("STSong-Light", 18 - 3 * lvl)
            c.drawString(60 + 18 * lvl, y, bmp_only(t))
            y -= 30
        c.setFont("STSong-Light", 10.5)
        for line in text_lines_for_page(p):
            if y < 70:
                break
            c.drawString(60, y, line)
            y -= 20
        c.setFont("STSong-Light", 10)
        c.drawCentredString(w / 2, 36, f"— {p} —")
        c.showPage()
    c.save()
    write_sidecars(out, "text_classic_cjk", toc, style=dict(indent="tab", sep=" "))
    write_sidecars(out, "text_classic_cjk", spread(MANUAL, n), suffix=".reapply",
                   style=dict(indent="space", sep="  "))
    ctx["text_classic_cjk_toc"] = toc
    return {"description": "reportlab, UnicodeCIDFont STSong-Light, 30 pages, classic xref", "reapply": True,
            "expect_xref": "classic"}


def build_text_objstm(out: Path, ctx):
    src = out / "text_classic_cjk.pdf"
    with pikepdf.open(src) as pdf:
        save_pikepdf(pdf, out / "text_objstm.pdf", object_stream_mode=pikepdf.ObjectStreamMode.generate,
                     compress_streams=True)
    data = (out / "text_objstm.pdf").read_bytes()
    sec = pdfraw.parse_xref_section(data, pdfraw.last_startxref(data))
    parms = sec.trailer.get("DecodeParms") or {}
    assert sec.kind == "stream", "text_objstm must end with an xref stream"
    assert isinstance(parms, dict) and parms.get("Predictor", 1) >= 10, f"expected PNG predictor, got {parms}"
    assert any(e.type == 2 for e in sec.entries.values()), "expected compressed (type 2) objects"
    write_sidecars(out, "text_objstm", ctx["text_classic_cjk_toc"], style=dict(indent="space", sep=" "))
    write_sidecars(out, "text_objstm", spread(MANUAL, 30), suffix=".reapply", style=dict(indent="tab", sep="\t"))
    return {"description": f"qpdf resave of text_classic_cjk with object streams; xref stream /W {sec.trailer.get('W')} "
                           f"/DecodeParms {dict(parms)}", "reapply": True, "expect_xref": "stream"}


def build_text_linearized(out: Path, ctx):
    with pikepdf.open(out / "text_classic_cjk.pdf") as pdf:
        save_pikepdf(pdf, out / "text_linearized.pdf", linearize=True)
    with pikepdf.open(out / "text_linearized.pdf") as pdf:
        assert pdf.is_linearized
    write_sidecars(out, "text_linearized", ctx["text_classic_cjk_toc"], style=dict(indent="tab", sep="   "))
    return {"description": "qpdf linearize=True of text_classic_cjk", "revisions_ambiguous": True}


def _render_scan_page(size, font_big, font_body, font_small, heads, lines, footer, rng, mode="1", paper=255):
    from PIL import Image, ImageDraw
    w, h = size
    im = Image.new(mode, size, 1 if mode == "1" else paper)
    d = ImageDraw.Draw(im)
    ink = 0 if mode == "1" else 25
    sx = w / 2550
    y = int(260 * sx)
    for lvl, t in heads:
        d.text((int((250 + 60 * lvl) * sx), y), bmp_only(t), font=font_big, fill=ink)
        y += int(130 * sx)
    for line in lines:
        if y > h - int(330 * sx):
            break
        d.text((int(250 * sx), y), line, font=font_body, fill=ink)
        y += int(88 * sx)
    if footer:
        d.text((w // 2 - int(60 * sx), h - int(200 * sx)), footer, font=font_small, fill=ink)
    # scanner speckle, deterministic
    for _ in range(400):
        x, yy = rng.randrange(w), rng.randrange(h)
        r = rng.choice((1, 1, 2, 3))
        d.ellipse((x, yy, x + r, yy + r), fill=ink)
    return im


def _scan_pages(n_front, n_body, toc, size, dpi, mode):
    font_big, fontpath = pil_font(int(95 * size[0] / 2550))
    font_body, _ = pil_font(int(52 * size[0] / 2550))
    font_small, _ = pil_font(int(46 * size[0] / 2550))
    rng = random.Random(4242 + n_body)
    heads = {}
    for lvl, t, p in toc:
        heads.setdefault(p, []).append((lvl, t))
    roman = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii"]
    pages = []
    for k in range(n_front):
        if k == 0:
            hd, ls, ft = [(0, "基于增量更新的 PDF 书签写入研究"), (1, "A Study of Incremental PDF Outlines")], \
                         ["", "学位论文 (扫描版) Scanned Thesis", "", "作者 Author: mulu fixtures", "2026 年 9 月"], ""
        elif k == 1:
            hd, ls, ft = [], ["版权声明 Copyright notice", "本扫描件仅用于软件测试。"], ""
        elif k in (2, 3):
            hd = [(0, "摘要" if k == 2 else "Abstract")]
            ls, ft = text_lines_for_page(k, 22), roman[k - 2]
        else:
            hd = [(0, "目录 Contents")]
            half = (len(toc) + 1) // 2
            chunk = toc[:half] if k == n_front - 2 else toc[half:]
            ls = [("    " * lvl) + f"{bmp_only(t)} ........ {p}" for lvl, t, p in chunk]
            ft = roman[k - 2]
        pages.append(_render_scan_page(size, font_big, font_body, font_small, hd, ls, ft, rng, mode))
    for p in range(1, n_body + 1):
        pages.append(_render_scan_page(size, font_big, font_body, font_small, heads.get(p, []),
                                       text_lines_for_page(p, 26), str(p), rng, mode))
    return pages, fontpath


def build_scan_g4(out: Path, ctx):
    import img2pdf
    n_front, n_body = 6, 34
    toc = spread(THESIS, n_body)
    pages, fontpath = _scan_pages(n_front, n_body, toc, (2550, 3300), 300, "1")
    blobs = []
    for im in pages:
        buf = io.BytesIO()
        im.save(buf, format="TIFF", compression="group4", dpi=(300, 300))
        blobs.append(buf.getvalue())
    pdf_bytes = img2pdf.convert(blobs, nodate=True, title="扫描件 scan_g4", author="mulu fixtures",
                                engine=img2pdf.Engine.internal)
    (out / "scan_g4.pdf").write_bytes(pdf_bytes)
    with pikepdf.open(out / "scan_g4.pdf") as pdf:
        assert len(pdf.pages) == 40
        for pg in pdf.pages:
            for img in page_images(pg):
                assert filters_of(img) == ["/CCITTFaxDecode"], f"expected CCITT G4, got {img.get('/Filter')}"
    write_sidecars(out, "scan_g4", toc, offset=n_front, style=dict(indent="space", sep=" "))
    write_sidecars(out, "scan_g4", spread(MANUAL, n_body), offset=n_front, suffix=".reapply",
                   style=dict(indent="tab", sep=" "))
    ctx["scan_g4_toc"] = toc
    return {"description": f"40 bitonal 300 dpi pages, CCITT G4 via img2pdf (internal engine); 6 front-matter pages, "
                           f"offset 6; font {fontpath}", "reapply": True, "offset": n_front}


def build_scan_jpeg(out: Path, ctx):
    import img2pdf
    from PIL import Image
    n = 20
    toc = spread(MANUAL, n)
    pages, _ = _scan_pages(0, n, toc, (1275, 1650), 150, "L")
    blobs = []
    for i, im in enumerate(pages):
        noise = Image.effect_noise(im.size, 18)
        im = Image.blend(im, noise, 0.07)
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=72, dpi=(150, 150))
        blobs.append(buf.getvalue())
    (out / "scan_jpeg.pdf").write_bytes(img2pdf.convert(blobs, nodate=True, title="scan_jpeg 灰度扫描"))
    with pikepdf.open(out / "scan_jpeg.pdf") as pdf:
        assert len(pdf.pages) == n
        for pg in pdf.pages:
            for img in page_images(pg):
                assert filters_of(img) == ["/DCTDecode"], f"expected DCT, got {img.get('/Filter')}"
    write_sidecars(out, "scan_jpeg", toc, style=dict(indent="tab", sep=" "))
    return {"description": "20 grayscale 150 dpi JPEG pages via img2pdf (DCTDecode passthrough)"}


def build_scan_g4_objstm(out: Path, ctx):
    with pikepdf.open(out / "scan_g4.pdf") as pdf:
        save_pikepdf(pdf, out / "scan_g4_objstm.pdf", object_stream_mode=pikepdf.ObjectStreamMode.generate)
    data = (out / "scan_g4_objstm.pdf").read_bytes()
    assert pdfraw.newest_xref_kind(data) == "stream"
    write_sidecars(out, "scan_g4_objstm", ctx["scan_g4_toc"], offset=6, style=dict(indent="tab", sep="\t"))
    return {"description": "qpdf object-stream resave of scan_g4", "offset": 6}


PREEXISTING = [("旧书签 Old Bookmark 1", 0, 0), ("Old 1.1 旧子项", 1, 2), ("旧书签 Old Bookmark 2", 0, 9),
               ("Old 2.1", 1, 12), ("Old 2.1.1 深层", 2, 13), ("旧书签 Old Bookmark 3", 0, 20)]


def build_existing_outline(out: Path, ctx):
    with pikepdf.open(out / "text_classic_cjk.pdf") as pdf:
        with pdf.open_outline() as ol:
            stack = []
            for title, lvl, pidx in PREEXISTING:
                item = pikepdf.OutlineItem(title, pidx)
                del stack[lvl:]
                (stack[-1].children if stack else ol.root).append(item)
                stack.append(item)
        pdf.Root.PageMode = pikepdf.Name.UseNone
        save_pikepdf(pdf, out / "existing_outline.pdf")
    (out / "existing_outline.preexisting.json").write_text(
        json.dumps([{"title": t, "level": l, "page_index": p} for t, l, p in PREEXISTING], ensure_ascii=False, indent=1)
        + "\n", encoding="utf-8")
    write_sidecars(out, "existing_outline", ctx["text_classic_cjk_toc"], style=dict(indent="space", sep="\t"))
    return {"description": "text_classic_cjk + a 6-item outline added by pikepdf (/PageMode /UseNone); mulu must "
                           "REPLACE it"}


def build_quartz_made(out: Path, ctx):
    BIN.mkdir(exist_ok=True)
    exe = BIN / "quartz_make"
    src = HERE / "quartz_make.swift"
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-swift-version", "5", str(src), "-o", str(exe)], check=True)
    n = 24
    toc = spread(MANUAL, n)
    with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False, encoding="utf-8") as tf:
        for lvl, t, p in toc:
            tf.write(f"{p}\t{'  ' * lvl}{t}\n")
    subprocess.run([str(exe), str(out / "quartz_made.pdf"), str(n), tf.name], check=True)
    Path(tf.name).unlink()
    with pikepdf.open(out / "quartz_made.pdf") as pdf:
        assert len(pdf.pages) == n
        producer = str(pdf.docinfo.get("/Producer", ""))
    write_sidecars(out, "quartz_made", toc, style=dict(indent="tab", sep=" "))
    data = (out / "quartz_made.pdf").read_bytes()
    sec = pdfraw.parse_xref_section(data, pdfraw.last_startxref(data))
    zero = sorted(n for n, e in sec.entries.items() if e.type == 1 and e.f2 == 0)
    notes = ""
    if zero:
        notes += (f"Real Quartz quirk: in-use xref entries with offset 0 for object(s) {zero} (unreferenced); "
                  "qpdf warns on the ORIGINAL - mulu must tolerate this, not refuse.")
    return {"description": f"Apple Quartz CGPDFContext + CoreText, 24 pages (Producer: {producer})",
            "notes": notes, "allow_input_warnings": bool(zero)}


def build_encrypted(out: Path, ctx):
    with pikepdf.open(out / "text_classic_cjk.pdf") as pdf:
        save_pikepdf(pdf, out / "encrypted.pdf",
                     encryption=pikepdf.Encryption(owner="mulu-owner-pw", user="", R=6, aes=True))
    with pikepdf.open(out / "encrypted.pdf") as pdf:
        assert pdf.is_encrypted
    write_sidecars(out, "encrypted", ctx["text_classic_cjk_toc"], refuse=True)
    return {"description": "AES-256 (R6), empty user password -> must refuse"}


def _append_update(data: bytes, objects: dict, trailer: dict, free: dict | None = None) -> bytes:
    """Append a classic-xref incremental update. objects: {(num,gen): body_bytes}; free: {num: next_gen}."""
    out = bytearray(data)
    if not out.endswith((b"\n", b"\r")):
        out += b"\n"
    entries = {}
    for (num, gen), body in objects.items():
        entries[num] = f"{len(out):010d} {gen:05d} n \n".encode()
        out += f"{num} {gen} obj\n".encode() + body + b"\nendobj\n"
    free = free or {}
    if free:
        chain = sorted(free)
        entries[0] = f"{chain[0]:010d} 65535 f \n".encode()
        for i, num in enumerate(chain):
            nxt = chain[i + 1] if i + 1 < len(chain) else 0
            entries[num] = f"{nxt:010d} {free[num]:05d} f \n".encode()
    xref_off = len(out)
    out += b"xref\n"
    nums = sorted(entries)
    i = 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        out += f"{nums[i]} {j - i + 1}\n".encode()
        for k in range(i, j + 1):
            assert len(entries[nums[k]]) == 20
            out += entries[nums[k]]
        i = j + 1
    out += b"trailer\n" + pdfraw.serialize(trailer) + b"\nstartxref\n" + str(xref_off).encode() + b"\n%%EOF\n"
    return bytes(out)


def build_multirev(out: Path, ctx):
    data = (out / "text_classic_cjk.pdf").read_bytes()
    sec = pdfraw.parse_xref_section(data, pdfraw.last_startxref(data))
    assert sec.kind == "classic"
    tr = sec.trailer
    root, info, size = tr["Root"], tr["Info"], tr["Size"]
    cat = pdfraw.parse_indirect(data, sec.entries[root.num].f2).value
    cat2 = dict(cat)
    cat2["Lang"] = PDFString(b"zh-CN")
    new_info = Ref(size, 0)
    ids = tr.get("ID")
    # revision 2: new Info object, old Info freed, catalog revised with /Lang
    t2 = {"Size": size + 1, "Root": root, "Info": new_info, "Prev": pdfraw.last_startxref(data)}
    if ids:
        t2["ID"] = [ids[0], PDFString(b"mulu-multirev-r2")]
    info2 = {"Title": PDFString(b"\xfe\xff" + "多版本 multirev r2".encode("utf-16-be")),
             "Producer": PDFString(b"mulu fixture multirev (hand-appended update)"),
             "ModDate": PDFString(b"D:20260923120000Z")}
    data2 = _append_update(data, {(new_info.num, 0): pdfraw.serialize(info2),
                                  (root.num, root.gen): pdfraw.serialize(cat2)},
                           t2, free={info.num: info.gen + 1})
    # revision 3: Info object revised again (same number) -> newest must win
    t3 = dict(t2)
    t3["Prev"] = pdfraw.last_startxref(data2)
    if ids:
        t3["ID"] = [ids[0], PDFString(b"mulu-multirev-r3")]
    info3 = dict(info2)
    info3["Title"] = PDFString(b"\xfe\xff" + "多版本 multirev r3".encode("utf-16-be"))
    info3["Keywords"] = PDFString(b"incremental, /Prev chain")
    data3 = _append_update(data2, {(new_info.num, 0): pdfraw.serialize(info3)}, t3)
    (out / "multirev.pdf").write_bytes(data3)
    with pikepdf.open(out / "multirev.pdf") as pdf:
        assert not pdf.get_warnings(), pdf.get_warnings()
        assert str(pdf.docinfo.Title) == "多版本 multirev r3", str(pdf.docinfo.Title)
        assert str(pdf.Root.Lang) == "zh-CN"
        assert len(pdf.pages) == 30
    assert len(pdfraw.revision_chain(data3)) == 3
    write_sidecars(out, "multirev", ctx["text_classic_cjk_toc"], style=dict(indent="tab", sep="\t"))
    return {"description": "text_classic_cjk + 2 hand-appended classic updates (new /Info, old /Info freed, catalog "
                           "revised with /Lang, Info revised again): 3 revisions"}


def build_big_500p(out: Path, ctx):
    from reportlab.lib.pagesizes import letter
    from reportlab.pdfgen import canvas
    n = 500
    c = canvas.Canvas(str(out / "big_500p.pdf"), pagesize=letter, invariant=1)
    c.setTitle("big_500p")
    w, h = letter
    for p in range(1, n + 1):
        c.setFont("Helvetica-Bold", 20)
        c.drawString(72, h - 90, f"Page {p} of {n}")
        c.setFont("Helvetica", 11)
        for i in range(12):
            c.drawString(72, h - 130 - 18 * i, f"Line {i + 1}: The quick brown fox jumps over the lazy dog. #{p * 100 + i}")
        c.drawCentredString(w / 2, 40, str(p))
        c.showPage()
    c.save()
    write_sidecars(out, "big_500p", spread(BOOK, n), style=dict(indent="tab", sep=" "))
    return {"description": "500 simple reportlab pages; apply must take < 1000 ms", "perf_limit_ms": 1000}


def quartz_zero_offset_quirk(path: Path):
    """Quartz-based producers (CGPDFContext, cupsfilter, sips) sometimes write in-use xref entries with
    offset 0 for unreferenced objects. qpdf warns about them on the ORIGINAL file; mulu must tolerate
    them. Returns (notes, allow_input_warnings)."""
    data = path.read_bytes()
    try:
        sec = pdfraw.parse_xref_section(data, pdfraw.last_startxref(data))
        zero = sorted(n for n, e in sec.entries.items() if e.type == 1 and e.f2 == 0)
    except Exception:
        zero = []
    if not zero:
        return "", False
    return (f"Real Quartz quirk: in-use xref entries with offset 0 for object(s) {zero} (unreferenced); "
            "qpdf warns on the ORIGINAL - mulu must tolerate this, not refuse."), True


def build_cups_made(out: Path, ctx):
    exe = Path("/usr/sbin/cupsfilter")
    if not exe.exists():
        raise SkipFixture("/usr/sbin/cupsfilter not present")
    lines = []
    for sec_i, (lvl, t) in enumerate(MANUAL):
        lines.append("")
        lines.append(("  " * lvl) + t)
        lines.append("")
        for k in range(14):
            lines.append(f"    {sec_i + 1}.{k + 1}  Plain text rendered by cupsfilter text/plain -> application/pdf.")
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as tf:
        tf.write("\n".join(lines) + "\n")
    try:
        r = subprocess.run([str(exe), "-i", "text/plain", "-m", "application/pdf", tf.name],
                           capture_output=True, timeout=120)
    finally:
        Path(tf.name).unlink()
    if r.returncode != 0 or not r.stdout.startswith(b"%PDF"):
        raise SkipFixture(f"cupsfilter failed (exit {r.returncode}): {r.stderr.decode(errors='replace')[-200:]}")
    (out / "cups_made.pdf").write_bytes(r.stdout)
    with pikepdf.open(out / "cups_made.pdf") as pdf:
        n = len(pdf.pages)
        producer = str(pdf.docinfo.get("/Producer", "")) if "/Info" in pdf.trailer else ""
    write_sidecars(out, "cups_made", spread(MANUAL, n), style=dict(indent="space", sep=" "))
    notes, allow = quartz_zero_offset_quirk(out / "cups_made.pdf")
    return {"description": f"/usr/sbin/cupsfilter text/plain -> PDF, {n} pages (Producer: {producer})",
            "notes": notes, "allow_input_warnings": allow}


def build_sips_made(out: Path, ctx):
    exe = Path("/usr/bin/sips")
    if not exe.exists():
        raise SkipFixture("/usr/bin/sips not present")
    pages, _ = _scan_pages(0, 1, [(0, "sips 单页测试 Single Page", 1)], (1240, 1754), 150, "L")
    im = pages[0].convert("RGB")
    with tempfile.TemporaryDirectory() as td:
        png = Path(td) / "page.png"
        im.save(png)
        r = subprocess.run([str(exe), "-s", "format", "pdf", str(png), "--out", str(out / "sips_made.pdf")],
                           capture_output=True, timeout=120)
    if r.returncode != 0 or not (out / "sips_made.pdf").exists():
        raise SkipFixture(f"sips failed (exit {r.returncode}): {r.stderr.decode(errors='replace')[-200:]}")
    with pikepdf.open(out / "sips_made.pdf") as pdf:
        n = len(pdf.pages)
    write_sidecars(out, "sips_made", spread(MANUAL, n), style=dict(indent="tab", sep=" "))
    notes, allow = quartz_zero_offset_quirk(out / "sips_made.pdf")
    return {"description": f"sips -s format pdf from a PNG ({n} page); every TOC entry targets page 1",
            "notes": notes, "allow_input_warnings": allow}


# ---- extra positive fixtures (beyond the 12 in the brief) -------------------

def build_xref_png_filters(out: Path, ctx):
    """text_objstm with its xref stream re-encoded so rows cycle through ALL 5 PNG filter types."""
    data = (out / "text_objstm.pdf").read_bytes()
    sx = pdfraw.last_startxref(data)
    obj = pdfraw.parse_indirect(data, sx)
    d = dict(obj.value.dict)
    raw = pdfraw.decode_stream(obj.value)
    w = d["W"]
    rowlen = sum(w)
    enc = pdfraw.png_predict(raw, rowlen, lambda r: r % 5)
    assert pdfraw.png_unpredict(enc, rowlen) == raw
    comp = zlib.compress(enc, 9)
    d["Filter"] = Name("FlateDecode")
    d["DecodeParms"] = {"Predictor": 15, "Columns": rowlen}
    d["Length"] = len(comp)
    body = f"{obj.num} {obj.gen} obj\n".encode() + pdfraw.serialize(d) + b"\nstream\n" + comp + b"\nendstream\nendobj\n"
    new = data[:sx] + body + b"startxref\n" + str(sx).encode() + b"\n%%EOF\n"
    (out / "xref_png_filters.pdf").write_bytes(new)
    with pikepdf.open(out / "xref_png_filters.pdf") as pdf:
        assert not pdf.get_warnings(), pdf.get_warnings()
        assert len(pdf.pages) == 30
    chk = pdfraw.parse_xref_section(new, sx)
    assert {k: (e.type, e.f2, e.f3) for k, e in chk.entries.items()} == \
           {k: (e.type, e.f2, e.f3) for k, e in pdfraw.parse_xref_section(data, sx).entries.items()}
    write_sidecars(out, "xref_png_filters", ctx["text_classic_cjk_toc"], style=dict(indent="tab", sep=" "))
    return {"description": "text_objstm with the xref stream rows encoded with PNG filter types 0,1,2,3,4 cycling "
                           "(/Predictor 15)", "expect_xref": "stream"}


def build_hybrid_xref(out: Path, ctx):
    """Hybrid-reference file: classic table for plain objects + /XRefStm stream for compressed objects."""
    data = (out / "text_objstm.pdf").read_bytes()
    sx = pdfraw.last_startxref(data)
    sec = pdfraw.parse_xref_section(data, sx)
    xnum = sec.stream_obj.num
    body = bytearray(data[:sx])
    type1 = {n: e for n, e in sec.entries.items() if e.type == 1 and n != xnum}
    type2 = {n: e for n, e in sec.entries.items() if e.type == 2}
    size = sec.trailer["Size"]
    # 1) XRefStm stream (only compressed objects), Flate without predictor
    rows = bytearray()
    idx = []
    nums = sorted(type2)
    i = 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        idx += [nums[i], j - i + 1]
        for k in range(i, j + 1):
            e = type2[nums[k]]
            rows += bytes([2]) + e.f2.to_bytes(4, "big") + e.f3.to_bytes(2, "big")
        i = j + 1
    comp = zlib.compress(bytes(rows), 9)
    xs_off = len(body)
    xs_dict = {"Type": Name("XRef"), "Size": size, "W": [1, 4, 2], "Index": idx,
               "Filter": Name("FlateDecode"), "Length": len(comp)}
    body += f"{xnum} 0 obj\n".encode() + pdfraw.serialize(xs_dict) + b"\nstream\n" + comp + b"\nendstream\nendobj\n"
    # 2) classic table for uncompressed objects (+ the XRefStm object itself)
    entries = {0: f"{0:010d} 65535 f \n".encode()}
    for n, e in type1.items():
        entries[n] = f"{e.f2:010d} {e.f3:05d} n \n".encode()
    entries[xnum] = f"{xs_off:010d} 00000 n \n".encode()
    xref_off = len(body)
    body += b"xref\n"
    nums = sorted(entries)
    i = 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        body += f"{nums[i]} {j - i + 1}\n".encode() + b"".join(entries[nums[k]] for k in range(i, j + 1))
        i = j + 1
    tr = {"Size": size, "Root": sec.trailer["Root"]}
    for k in ("Info", "ID"):
        if k in sec.trailer:
            tr[k] = sec.trailer[k]
    tr["XRefStm"] = xs_off
    body += b"trailer\n" + pdfraw.serialize(tr) + b"\nstartxref\n" + str(xref_off).encode() + b"\n%%EOF\n"
    (out / "hybrid_xref.pdf").write_bytes(bytes(body))
    assert pdfraw.newest_xref_kind(bytes(body)) == "hybrid"
    with pikepdf.open(out / "hybrid_xref.pdf") as pdf:
        assert not pdf.get_warnings(), pdf.get_warnings()
        assert len(pdf.pages) == 30
    write_sidecars(out, "hybrid_xref", ctx["text_classic_cjk_toc"], style=dict(indent="space", sep=" "))
    return {"description": f"hybrid-reference file built from text_objstm: classic table ({len(type1) + 1} objs) + "
                           f"/XRefStm ({len(type2)} compressed objs incl. Root/Pages)", "expect_xref": "hybrid"}


def build_toc_quirks(out: Path, ctx):
    """Same PDF as text_classic_cjk; the TOC FILE is Windows-flavoured: UTF-8 BOM, CRLF, tab+space separators,
    trailing whitespace. Beyond the letter of the TOC contract, but what real users paste."""
    shutil.copyfile(out / "text_classic_cjk.pdf", out / "toc_quirks.pdf")
    write_sidecars(out, "toc_quirks", ctx["text_classic_cjk_toc"],
                   style=dict(indent="space", sep=" \t ", eol="\r\n", bom=True, trail="  "))
    return {"description": "text_classic_cjk PDF; TOC file has UTF-8 BOM + CRLF + ' \\t ' separators + trailing "
                           "spaces", "notes": "TOC-parser robustness beyond the letter of the TOC contract"}


def _retail(data: bytes, eol: bytes, entry_eol: bytes) -> bytes:
    """Rewrite the final classic xref/trailer/startxref/%%EOF of `data` with other line endings.
    Object offsets are unchanged because the xref section is the last thing in the file."""
    sx = pdfraw.last_startxref(data)
    sec = pdfraw.parse_xref_section(data, sx)
    assert sec.kind == "classic" and data[sx:sx + 4] == b"xref"
    ti = data.find(b"trailer", sx)
    si = data.rfind(b"startxref")
    trailer_body = data[ti + 7:si].strip(b"\r\n ")
    trailer_body = trailer_body.replace(b"\r\n", b"\n").replace(b"\n", eol)
    nums = sorted(sec.entries)
    assert nums == list(range(len(nums)))
    out = bytearray(data[:sx]) + b"xref" + eol + f"0 {len(nums)}".encode() + eol
    for n in nums:
        e = sec.entries[n]
        line = f"{e.f2:010d} {e.f3:05d} {'n' if e.type == 1 else 'f'}".encode() + entry_eol
        assert len(line) == 20
        out += line
    out += b"trailer" + eol + trailer_body + eol + b"startxref" + eol + str(sx).encode() + eol + b"%%EOF" + eol
    return bytes(out)


def _eof_variant(name, make, desc):
    def build(out: Path, ctx):
        data = (out / "text_classic_cjk.pdf").read_bytes()
        new = make(data)
        (out / f"{name}.pdf").write_bytes(new)
        with pikepdf.open(out / f"{name}.pdf") as pdf:
            assert len(pdf.pages) == 30
        write_sidecars(out, name, ctx["text_classic_cjk_toc"], style=dict(indent="tab", sep=" "))
        return {"description": desc, "allow_input_warnings": True}
    return build


build_eof_crlf = _eof_variant("eof_crlf", lambda d: _retail(d, b"\r\n", b"\r\n"),
                              "text_classic_cjk with xref/trailer/startxref/%%EOF rewritten with CRLF (entries end \\r\\n)")
build_eof_cr = _eof_variant("eof_cr", lambda d: _retail(d, b"\r", b" \r"),
                            "text_classic_cjk with CR-only xref/trailer/%%EOF (entries end ' \\r'; file ends with CR)")
build_eof_no_eol = _eof_variant("eof_no_eol", lambda d: d.rstrip(b"\r\n"),
                                "text_classic_cjk without the final EOL (ends in '%%EOF'): update must start with one \\n")
build_eof_garbage = _eof_variant(
    "eof_garbage", lambda d: d + b"\x00" * 48 + b"\r\n<!-- junk appended by a download tool -->\r\n  \t",
    "text_classic_cjk + NULs and junk text after %%EOF (no trailing EOL)")


def build_nested_pagetree(out: Path, ctx):
    """Hand-built page tree: 4 levels, Page and Pages kids mixed, page object numbers DEcreasing in reading
    order, inherited /MediaBox /Resources /Rotate. A walker that sorts by object number gets it wrong."""
    tree = [[0, 0, [0] * 5, 0], 0, [[[0] * 3, 0, 0], [0] * 12, 0, [[0, 0]]], 0]

    def count(t):
        return sum(count(k) if isinstance(k, list) else 1 for k in t)

    n_pages = count(tree)
    objs: dict[int, bytes] = {}
    next_num = [3]

    def alloc():
        v = next_num[0]
        next_num[0] += 1
        return v

    font = alloc()
    objs[font] = pdfraw.serialize({"Type": Name("Font"), "Subtype": Name("Type1"), "BaseFont": Name("Helvetica")})
    page_nums = list(range(1000 + 2 * n_pages, 1000, -2))  # descending object numbers in reading order
    reading = [0]

    def build(t, parent_ref, depth):
        me = alloc() if parent_ref is not None else 2
        kids = []
        for k in t:
            if isinstance(k, list):
                kids.append(build(k, Ref(me, 0), depth + 1))
            else:
                i = reading[0]
                reading[0] += 1
                pnum = page_nums[i]
                cnum = pnum + 1
                content = (f"q 0.85 g {40 + 12 * (i % 30)} {80 + 20 * (i % 25)} 120 60 re f Q "
                           f"BT /F1 40 Tf 72 700 Td (Page {i + 1}) Tj ET "
                           f"BT /F1 12 Tf 72 660 Td (depth {depth + 1}, object {pnum}) Tj ET").encode()
                objs[cnum] = pdfraw.serialize({"Length": len(content)}) + b"\nstream\n" + content + b"\nendstream"
                pd = {"Type": Name("Page"), "Parent": Ref(me, 0), "Contents": Ref(cnum, 0)}
                objs[pnum] = pdfraw.serialize(pd)
                kids.append(Ref(pnum, 0))
        d = {"Type": Name("Pages"), "Kids": kids, "Count": count(t)}
        if parent_ref is not None:
            d["Parent"] = parent_ref
        else:
            d["MediaBox"] = [0, 0, 595, 842]
            d["Resources"] = {"Font": {"F1": Ref(font, 0)}}
        if depth == 2:
            d["Rotate"] = 90  # inherited by the pages below
        objs[me] = pdfraw.serialize(d)
        return Ref(me, 0)

    build(tree, None, 0)
    objs[1] = pdfraw.serialize({"Type": Name("Catalog"), "Pages": Ref(2, 0)})
    info = alloc()
    objs[info] = pdfraw.serialize({"Title": PDFString(b"nested page tree"), "Producer": PDFString(b"mulu fixtures")})
    size = max(objs) + 1
    body = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offs = {}
    for num in sorted(objs, key=lambda n: (n % 7, n)):  # physical order unrelated to numbering
        offs[num] = len(body)
        body += f"{num} 0 obj\n".encode() + objs[num] + b"\nendobj\n"
    x = len(body)
    body += f"xref\n0 {size}\n".encode()
    for num in range(size):
        body += (f"{offs[num]:010d} 00000 n \n" if num in offs else f"{0:010d} 65535 f \n").encode()
    body += b"trailer\n" + pdfraw.serialize({"Size": size, "Root": Ref(1, 0), "Info": Ref(info, 0),
                                               "ID": [PDFString(b"nested-pagetree-1"), PDFString(b"nested-pagetree-1")]})
    body += b"\nstartxref\n" + str(x).encode() + b"\n%%EOF\n"
    (out / "nested_pagetree.pdf").write_bytes(bytes(body))
    with pikepdf.open(out / "nested_pagetree.pdf") as pdf:
        assert len(pdf.pages) == n_pages
        for i, pg in enumerate(pdf.pages):
            assert f"(Page {i + 1})".encode() in pg.Contents.read_bytes(), f"page order broken at {i}"
    write_sidecars(out, "nested_pagetree", spread(THESIS, n_pages), style=dict(indent="tab", sep=" "))
    return {"description": f"hand-built {n_pages}-page tree, 4 levels deep, Page/Pages kids mixed, page object numbers "
                           f"decreasing in reading order, inherited MediaBox/Resources/Rotate, free-entry gaps"}


# ---- refusal fixtures ---------------------------------------------------------

def build_refuse_page_range(out: Path, ctx):
    shutil.copyfile(out / "text_classic_cjk.pdf", out / "refuse_page_range.pdf")
    toc = list(ctx["text_classic_cjk_toc"])
    lvl, t, _ = toc[-1]
    toc[-1] = (lvl, t, 31)  # document has 30 pages
    write_sidecars(out, "refuse_page_range", toc, refuse=True, style=dict(indent="tab", sep=" "))
    return {"description": "valid 30-page PDF, TOC's last entry targets page 31 -> must refuse"}


def build_refuse_zero_pages(out: Path, ctx):
    pdf = pikepdf.new()
    pdf.docinfo["/Title"] = "zero pages"
    save_pikepdf(pdf, out / "refuse_zero_pages.pdf")
    write_sidecars(out, "refuse_zero_pages", [(0, "Nothing here 空", 1)], refuse=True)
    return {"description": "structurally valid PDF with an empty page tree -> must refuse"}


def build_refuse_no_root(out: Path, ctx):
    objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"]
    body = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(body))
        body += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
    x = len(body)
    body += b"xref\n0 4\n0000000000 65535 f \n" + b"".join(f"{o:010d} 00000 n \n".encode() for o in offs)
    body += b"trailer\n<< /Size 4 >>\nstartxref\n" + str(x).encode() + b"\n%%EOF\n"
    (out / "refuse_no_root.pdf").write_bytes(bytes(body))
    write_sidecars(out, "refuse_no_root", [(0, "Chapter 1", 1)], refuse=True)
    return {"description": "trailer has no /Root -> must refuse"}


def build_refuse_not_pdf(out: Path, ctx):
    (out / "refuse_not_pdf.pdf").write_bytes(b"This is not a PDF file.\n" * 40 + b"startxref\n12\n%%EOF\n")
    write_sidecars(out, "refuse_not_pdf", [(0, "Chapter 1", 1)], refuse=True)
    return {"description": "plain text with a .pdf extension -> must refuse"}


class SkipFixture(Exception):
    pass


BUILDERS = [
    ("text_classic_cjk", build_text_classic_cjk, []),
    ("text_objstm", build_text_objstm, ["text_classic_cjk"]),
    ("text_linearized", build_text_linearized, ["text_classic_cjk"]),
    ("scan_g4", build_scan_g4, []),
    ("scan_jpeg", build_scan_jpeg, []),
    ("scan_g4_objstm", build_scan_g4_objstm, ["scan_g4"]),
    ("existing_outline", build_existing_outline, ["text_classic_cjk"]),
    ("quartz_made", build_quartz_made, []),
    ("encrypted", build_encrypted, ["text_classic_cjk"]),
    ("multirev", build_multirev, ["text_classic_cjk"]),
    ("big_500p", build_big_500p, []),
    ("cups_made", build_cups_made, []),
    ("sips_made", build_sips_made, []),
    ("xref_png_filters", build_xref_png_filters, ["text_objstm", "text_classic_cjk"]),
    ("hybrid_xref", build_hybrid_xref, ["text_objstm", "text_classic_cjk"]),
    ("toc_quirks", build_toc_quirks, ["text_classic_cjk"]),
    ("nested_pagetree", build_nested_pagetree, []),
    ("eof_crlf", build_eof_crlf, ["text_classic_cjk"]),
    ("eof_cr", build_eof_cr, ["text_classic_cjk"]),
    ("eof_no_eol", build_eof_no_eol, ["text_classic_cjk"]),
    ("eof_garbage", build_eof_garbage, ["text_classic_cjk"]),
    ("refuse_page_range", build_refuse_page_range, ["text_classic_cjk"]),
    ("refuse_zero_pages", build_refuse_zero_pages, []),
    ("refuse_no_root", build_refuse_no_root, []),
    ("refuse_not_pdf", build_refuse_not_pdf, []),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--only", default="", help="comma-separated fixture names (dependencies are built too)")
    ap.add_argument("--force", action="store_true", help="(kept for symmetry; fixtures are always rebuilt)")
    args = ap.parse_args()
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    wanted = {n for n in args.only.split(",") if n} or {b[0] for b in BUILDERS}
    need = set(wanted)
    changed = True
    while changed:
        changed = False
        for name, _, deps in BUILDERS:
            if name in need and not set(deps) <= need:
                need |= set(deps)
                changed = True

    manifest_path = out / "manifest.json"
    manifest = {"fixtures": {}}
    if manifest_path.exists() and args.only:
        try:
            manifest = json.loads(manifest_path.read_text())
        except Exception:  # noqa: BLE001
            pass

    ctx: dict = {}
    # the TOC of text_classic_cjk is shared by several fixtures
    ctx["text_classic_cjk_toc"] = spread(THESIS, 30)
    ctx["scan_g4_toc"] = spread(THESIS, 34)
    failures = 0
    for name, fn, _deps in BUILDERS:
        if name not in need:
            continue
        t0 = time.time()
        entry = {"name": name, "status": "ok", "expect": "apply", "offset": 0, "reapply": False,
                 "perf_limit_ms": None, "notes": ""}
        try:
            extra = fn(out, ctx) or {}
            entry.update(extra)
            if (out / f"{name}.expect").exists():
                entry["expect"] = "refuse"
            pw = None
            entry["facts"] = facts(out / f"{name}.pdf", pw)
            exp_x = entry.get("expect_xref")
            if exp_x:
                assert entry["facts"].get("xref") == exp_x, f"{name}: xref {entry['facts'].get('xref')} != {exp_x}"
            if entry["expect"] == "apply":
                assert entry["facts"].get("pages", 0) > 0
                if not entry.get("allow_input_warnings"):
                    assert not entry["facts"].get("qpdf_warnings"), entry["facts"]["qpdf_warnings"]
            msg = f"ok     {name:<20} {entry['facts'].get('size', 0):>10,d} B  " \
                  f"pages={entry['facts'].get('pages', '-')!s:<4} xref={entry['facts'].get('xref')!s:<8} " \
                  f"({time.time() - t0:.1f}s)"
        except SkipFixture as e:
            entry.update(status="skipped", notes=str(e))
            for suffix in (".pdf", ".toc.txt", ".expected.json", ".offset", ".expect"):
                (out / f"{name}{suffix}").unlink(missing_ok=True)
            msg = f"SKIP   {name:<20} {e}"
        except Exception as e:  # noqa: BLE001
            entry.update(status="error", notes=f"{type(e).__name__}: {e}")
            failures += 1
            msg = f"ERROR  {name:<20} {type(e).__name__}: {e}"
        manifest["fixtures"][name] = entry
        print(msg, flush=True)

    order = [b[0] for b in BUILDERS]
    manifest["fixtures"] = {k: manifest["fixtures"][k] for k in order if k in manifest["fixtures"]}
    manifest["generated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    manifest["generator"] = {"pikepdf": pikepdf.__version__, "qpdf": pikepdf.__libqpdf_version__}
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"manifest: {manifest_path}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
