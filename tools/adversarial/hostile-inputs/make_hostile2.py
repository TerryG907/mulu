# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9"]
# ///
"""
make_hostile2.py -- round-2 hostile inputs (crash vectors found by reading MuluCore, TOC-file encodings
that real users produce, trailer/catalog shapes the writer cannot express).

    uv run --python 3.12 tools/adversarial/hostile-inputs/make_hostile2.py

Writes tools/adversarial/hostile-inputs/gen2/ in the Fixtures/generated format (manifest.json + sidecars).
"""
from __future__ import annotations

import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pdfbuild import FONT, PDF, Registry, content, page, runs, toc_basic  # noqa: E402
from make_hostile import emit, objstm_doc, simple_classic, std_parts  # noqa: E402

GEN = HERE / "gen2"
T5 = toc_basic(5)


def raw_xrefstm(pdf: PDF, num: int, rows: dict, W, trailer: bytes, index=None, parms=b"", length=None,
                flate=True, size=None):
    """xref stream with arbitrary W / Index / DecodeParms, rows = {objnum: (t, f2, f3)}."""
    xoff = pdf.pos()
    rows = dict(rows)
    rows[num] = (1, xoff, 0)
    nums = sorted(rows)
    data = bytearray()
    for n in nums:
        t, f2, f3 = rows[n]
        for v, w in zip((t, f2, f3), W):
            if w > 0:
                data += v.to_bytes(w, "big")
    data = bytes(data)
    if flate:
        data = zlib.compress(data)
    idx = index if index is not None else [x for r in runs(nums) for x in r]
    inner = (b"/Type /XRef /W [%d %d %d] /Index [" % tuple(W) + b" ".join(b"%d" % x for x in idx) + b"]"
             + b" /Size %d" % (size if size is not None else max(nums) + 1)
             + (b" /Filter /FlateDecode" if flate else b"") + parms + b" " + trailer)
    pdf.stream(num, inner, data, length=length)
    pdf.buf += b"startxref\n%d\n%%%%EOF\n" % xoff
    return xoff


def std_rows(pdf: PDF):
    rows = {0: (0, 0, 0)}
    rows.update(pdf.rev)
    return rows


def build(R: Registry):
    # ---- 1. crash vectors --------------------------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(5, cat_extra=b" /Deep " + b"[" * 100000 + b"]" * 100000)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    R.add("h2_catalog_nest100k", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="catalog has /Deep with 100,000 nested arrays", probe="no crash; refusal acceptable (cannot re-serialise)")

    pdf = PDF()
    objs, streams = std_parts(5, page_extra=b" /PieceInfo " + b"[" * 300 + b"]" * 300)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    R.add("h2_page_nest300", pdf.bytes(), T5, pages=5, xref="classic", revisions=1, reapply=toc_basic(5, "R2 "),
          desc="every page dict carries a 300-deep nested array (/PieceInfo)",
          probe="parser maxDepth 256: a refusal here is a wrong refusal (readers open it)")

    # 30,000-level /Pages chain
    depth = 30000
    pdf = PDF()
    pdf.obj(1, b"<< /Type /Catalog /Pages 10 0 R >>")
    pdf.obj(3, FONT)
    for d in range(depth):
        n = 10 + d
        parent = b" /Parent %d 0 R" % (n - 1) if d else b""
        kid = b"%d 0 R" % (n + 1) if d + 1 < depth else b"5 0 R"
        extra = b" /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >>" if d == 0 else b""
        pdf.obj(n, b"<< /Type /Pages%s /Kids [%s] /Count 1%s >>" % (parent, kid, extra))
    pdf.obj(5, b"<< /Type /Page /Parent %d 0 R /Contents 6 0 R >>" % (10 + depth - 1))
    pdf.stream(6, b"", content(0))
    pdf.classic(b"/Root 1 0 R")
    R.add("h2_pages_chain30k", pdf.bytes(), [(0, "Only page", 1)], pages=1, xref="classic", revisions=1,
          desc="page tree is a 30,000-level chain of single-kid /Pages nodes", probe="no crash / no hang")

    # xref stream W variants
    for W, nm, probe in (((1, 9, 1), "h2_w_1_9_1", "valid: 9-byte offset field with leading zeros"),
                         ((1, 3, 0), "h2_w_1_3_0", "valid: gen field absent"),
                         ((1, -2, 1), "h2_w_negative", "must refuse or reconstruct, not crash"),
                         ((1, 999999999, 1), "h2_w_huge", "must refuse/reconstruct quickly, no huge allocation"),
                         ((0, 0, 0), "h2_w_zero", "degenerate W [0 0 0]; must not loop/crash")):
        pdf = PDF()
        objs, streams = std_parts(5)
        emit(pdf, objs, streams)
        rows = std_rows(pdf)
        if W[2] == 0:
            rows[0] = (0, 0, 0)
        Wreal = tuple(max(0, min(w, 9)) for w in W)
        # write the data with the *real* widths, but declare the hostile W
        xoff = pdf.pos()
        rows[20] = (1, xoff, 0)
        data = bytearray()
        for n in sorted(rows):
            for v, w in zip(rows[n], Wreal):
                if w:
                    data += v.to_bytes(w, "big")
        z = zlib.compress(bytes(data))
        idx = b" ".join(b"%d" % x for r in runs(sorted(rows)) for x in r)
        pdf.stream(20, b"/Type /XRef /W [%d %d %d] /Index [%s] /Size 21 /Filter /FlateDecode /Root 1 0 R"
                   % (W[0], W[1], W[2], idx), z)
        pdf.buf += b"startxref\n%d\n%%%%EOF\n" % xoff
        valid = W in ((1, 9, 1), (1, 3, 0))
        R.add(nm, pdf.bytes(), T5, pages=5, xref="stream", revisions=1 if valid else None,
              desc=f"xref stream declares /W [{W[0]} {W[1]} {W[2]}]", probe=probe)

    # predictor with absurd /Columns
    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    raw_xrefstm(pdf, 20, std_rows(pdf), (1, 4, 2), b"/Root 1 0 R",
                parms=b" /DecodeParms << /Predictor 12 /Columns 999999999999 >>")
    R.add("h2_columns_huge", pdf.bytes(), T5, pages=5, xref="stream",
          desc="xref stream /DecodeParms /Predictor 12 /Columns 999999999999", probe="no crash/huge alloc")

    for L, nm in ((b"-5", "h2_xrefstm_length_negative"), (b"999999999999999999", "h2_xrefstm_length_huge")):
        pdf = PDF()
        objs, streams = std_parts(5)
        emit(pdf, objs, streams)
        raw_xrefstm(pdf, 20, std_rows(pdf), (1, 4, 2), b"/Root 1 0 R", length=L)
        R.add(nm, pdf.bytes(), T5, pages=5, xref="stream",
              desc=f"xref stream /Length {L.decode()}", probe="no crash; reconstruct or refuse")

    # object stream with hostile /N and /First
    for inner_n, inner_first, nm in ((b"999999999999", None, "h2_objstm_n_huge"),
                                     (None, b"-40", "h2_objstm_first_negative"),
                                     (None, b"999999999999999", "h2_objstm_first_huge")):
        pdf = PDF()
        objs, streams = std_parts(5)
        for num in sorted(streams):
            pdf.stream(num, b"", streams[num][2])
        members = [(k, objs[k][1]) for k in sorted(objs)]
        offs, parts, o = [], [], 0
        for _, body in members:
            offs.append(o)
            parts.append(body)
            o += len(body) + 1
        header = (" ".join(f"{n} {off}" for (n, _), off in zip(members, offs)) + "\n").encode()
        z = zlib.compress(header + b"\n".join(parts) + b"\n")
        N = inner_n or b"%d" % len(members)
        F = inner_first or b"%d" % len(header)
        pdf.stream(30, b"/Type /ObjStm /N " + N + b" /First " + F + b" /Filter /FlateDecode", z)
        rows = std_rows(pdf)
        for i, (k, _) in enumerate(members):
            rows[k] = (2, 30, i)
        raw_xrefstm(pdf, 31, rows, (1, 4, 2), b"/Root 1 0 R")
        R.add(nm, pdf.bytes(), T5, pages=5, xref="stream", refuse=True,
              desc=f"catalog/pages in an ObjStm with /N {N.decode()} /First {F.decode()}",
              probe="catalog unreadable -> refuse (exit 2), no crash")

    # recursion: ObjStm whose /Length is an object compressed in itself
    pdf = PDF()
    objs, streams = std_parts(5)
    for num in sorted(streams):
        pdf.stream(num, b"", streams[num][2])
    members = [(k, objs[k][1]) for k in sorted(objs)] + [(40, b"100")]
    offs, parts, o = [], [], 0
    for _, body in members:
        offs.append(o)
        parts.append(body)
        o += len(body) + 1
    header = (" ".join(f"{n} {off}" for (n, _), off in zip(members, offs)) + "\n").encode()
    z = zlib.compress(header + b"\n".join(parts) + b"\n")
    pdf.stream(30, b"/Type /ObjStm /N %d /First %d /Filter /FlateDecode" % (len(members), len(header)), z,
               length=b"40 0 R")
    rows = std_rows(pdf)
    for i, (k, _) in enumerate(members):
        rows[k] = (2, 30, i)
    raw_xrefstm(pdf, 31, rows, (1, 4, 2), b"/Root 1 0 R")
    R.add("h2_objstm_length_self", pdf.bytes(), T5, pages=5, xref="stream",
          desc="ObjStm 30's /Length is 40 0 R, and object 40 lives inside ObjStm 30",
          probe="self-referential resolve: must not recurse forever; endstream scan fallback is fine")

    # huge object numbers via xref (not via /Size)
    pdf = simple_classic(5)
    data = pdf.bytes()
    i = data.rfind(b"trailer")
    extra = b"9000000000 1\n0000000000 00001 f \n"
    data2 = data[:i] + extra + data[i:]
    data2 = data2.replace(b"startxref\n", b"startxref\n", 1)
    R.add("h2_classic_objnum_9e9", data2, T5, pages=5, xref="classic", revisions=1,
          desc="classic xref has an extra subsection '9000000000 1' (a free entry); /Size 14",
          probe="new objects must not be numbered 9000000000+ (Annex C limit 8,388,607)")

    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    rows = std_rows(pdf)
    rows[5_000_000_000_000] = (0, 0, 1)
    raw_xrefstm(pdf, 20, rows, (1, 4, 2), b"/Root 1 0 R", size=21)
    R.add("h2_xrefstm_objnum_5e12", pdf.bytes(), T5, pages=5, xref="stream", revisions=1,
          desc="xref stream /Index includes object 5,000,000,000,000 (free); /Size 21",
          probe="new objects must not be numbered 5e12+")

    # ---- 2. trailer / catalog shapes -------------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(5)
    cat = objs.pop(1)[1]
    emit(pdf, objs, streams)
    pdf.classic(b"/Root " + cat)
    R.add("h2_root_direct_dict", pdf.bytes(), T5, refuse=True, pages=5, xref="classic", revisions=1,
          desc="trailer /Root is a DIRECT catalog dictionary", probe="cannot write a new catalog revision -> refuse")

    pdf = PDF()
    objs, streams = std_parts(5)
    cat = objs.pop(1)[1]
    emit(pdf, objs, streams)
    pdf.stream(1, cat[3:-3], b"junk")
    pdf.classic(b"/Root 1 0 R")
    R.add("h2_root_is_stream", pdf.bytes(), T5, refuse=True, pages=5, xref="classic", revisions=1,
          desc="/Root 1 0 R is a stream whose dictionary is the catalog", probe="refuse (writer cannot keep the data)")

    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R /Encrypt null")
    R.add("h2_encrypt_null", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="trailer /Encrypt null (== absent)", probe="not encrypted; refusal is a wrong refusal")

    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    pdf.obj(50, b"<< /Filter /Standard /V 2 /R 3 /Length 128 /P -4 /O <%s> /U <%s> >>" % (b"00" * 32, b"00" * 32))
    raw_xrefstm(pdf, 20, std_rows(pdf), (1, 4, 2), b"/Root 1 0 R /Encrypt 50 0 R /ID [<01><01>]")
    R.add("h2_encrypt_in_xrefstm", pdf.bytes(), toc_basic(5), refuse=True, encrypted=True, pages=5, xref="stream",
          desc="xref-stream file whose xref stream dictionary carries /Encrypt", probe="must refuse")

    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R /XRefStm 12")
    R.add("h2_hybrid_bogus_xrefstm", pdf.bytes(), T5, pages=5, xref="classic",
          desc="classic table lists every object, but trailer /XRefStm 12 points into the header comment",
          probe="readers ignore a broken XRefStm when the table is complete")

    # ---- 3. page-tree shapes -----------------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(3)
    direct = page(2, 7, 3).replace(b" /Parent 2 0 R", b"")
    objs[2] = (0, b"<< /Type /Pages /Kids [4 0 R %s 8 0 R] /Count 3 >>" % direct)
    objs.pop(6)  # page 2 exists only as the direct dictionary above
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    R.add("h2_direct_page_kid_ok", pdf.bytes(), [(0, "First", 1), (0, "Third", 3)], pages=3, xref="classic",
          desc="/Kids [4 0 R <<direct page dict>> 8 0 R]; TOC avoids page 2", probe="page 3 must map to 8 0 R")
    R.add("h2_direct_page_kid_target", pdf.bytes(), [(0, "First", 1), (0, "Direct", 2)], refuse=True, pages=3,
          xref="classic", desc="same file; TOC targets the direct (unreferenceable) page 2",
          probe="must refuse: no object to point /Dest at")

    pdf = PDF()
    objs, streams = std_parts(5)
    objs[2] = (0, objs[2][1].replace(b"/Count 5", b"/Count 3"))
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    R.add("h2_count_mismatch", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="/Pages /Count 3 but 5 kids", probe="readers disagree on page count? report")

    pdf = simple_classic(5)
    data = bytearray(pdf.bytes())
    # corrupt the xref entry of object 8 (page 3) to point beyond EOF
    xs = data.rfind(b"\nxref") + 1
    lines = data[xs:].split(b"\n")
    # entry line index: 'xref', '0 14', then obj 0..13
    old = lines[2 + 8]
    new = b"%010d" % 999999 + old[10:]
    k = xs + len(b"\n".join(lines[:2 + 8])) + 1
    data[k:k + len(old)] = new
    R.add("h2_page_offset_beyond_eof", bytes(data), T5, pages=5, xref="classic",
          desc="xref entry of page 3 (object 8) points beyond EOF; the object itself is intact",
          probe="readers reconstruct and see 5 pages; mulu must not silently drop page 3 and shift indices")

    pdf = PDF()
    objs, streams = std_parts(5)
    for k in list(objs):
        b = objs[k][1]
        if b"/Type /Page " in b:
            objs[k] = (0, b.replace(b"/Type /Page ", b""))
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    R.add("h2_leaf_no_type", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="page leaves lack /Type", probe="tolerate like readers")

    # cyclic existing outline (/Next loop) -- dump-outline and apply must terminate
    pdf = PDF()
    objs, streams = std_parts(5, cat_extra=b" /Outlines 40 0 R")
    objs[40] = (0, b"<< /Type /Outlines /First 41 0 R /Last 42 0 R /Count 2 >>")
    objs[41] = (0, b"<< /Title (A) /Parent 40 0 R /Next 42 0 R /Dest [4 0 R /Fit] >>")
    objs[42] = (0, b"<< /Title (B) /Parent 40 0 R /Prev 41 0 R /Next 41 0 R /First 41 0 R /Dest [6 0 R /Fit] >>")
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    R.add("h2_existing_outline_cycle", pdf.bytes(), T5, pages=5, xref="classic", revisions=1, has_outline=True,
          reapply=toc_basic(5, "R2 "), desc="existing outline with a /Next cycle and a /First back-edge",
          probe="dump-outline must terminate; apply replaces it")

    # ---- 4. size / performance ----------------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(5)
    for num in sorted(streams):
        pdf.stream(num, b"", streams[num][2])
    members = [(k, objs[k][1]) for k in sorted(objs)]
    offs, parts, o = [], [], 0
    for _, body in members:
        offs.append(o)
        parts.append(body)
        o += len(body) + 1
    header = (" ".join(f"{n} {off}" for (n, _), off in zip(members, offs)) + "\n").encode()
    comp = zlib.compressobj(9)
    z = comp.compress(header + b"\n".join(parts) + b"\n")
    chunk = b" " * (1 << 20)
    for _ in range(256):
        z += comp.compress(chunk)
    z += comp.flush()
    pdf.stream(30, b"/Type /ObjStm /N %d /First %d /Filter /FlateDecode" % (len(members), len(header)), z)
    rows = std_rows(pdf)
    for i, (k, _) in enumerate(members):
        rows[k] = (2, 30, i)
    raw_xrefstm(pdf, 31, rows, (1, 4, 2), b"/Root 1 0 R")
    R.add("h2_objstm_256mb_padding", pdf.bytes(), T5, pages=5, xref="stream", revisions=1,
          desc=f"ObjStm (catalog+pages) inflates to 256 MB (trailing spaces); file {len(pdf.bytes())} bytes",
          probe="valid; measure time + memory")

    pdf = simple_classic(5)
    for r in range(2000):
        pdf.obj(3, FONT.replace(b"Helvetica", b"Helvetica" if r % 2 else b"Times-Roman"))
        pdf.classic(b"/Root 1 0 R")
    R.add("h2_2000_revisions", pdf.bytes(), T5, pages=5, xref="classic", revisions=2001,
          desc="2001 incremental revisions (object 3 rewritten each time)", probe="time; /Prev chain of 2000")

    # ---- 5. TOC files real users produce ----------------------------------------------------------------
    base = simple_classic(5).bytes()
    toc = "﻿第一章 引言 1\r\n\t1.1 背景 1\r\n\t1.2 目标 2\r\n第二章 方法 3  \t\r\n附录 5\r\n".encode("utf-8")
    exp = [{"title": "第一章 引言", "level": 0, "page_index": 0}, {"title": "1.1 背景", "level": 1, "page_index": 0},
           {"title": "1.2 目标", "level": 1, "page_index": 1}, {"title": "第二章 方法", "level": 0, "page_index": 2},
           {"title": "附录", "level": 0, "page_index": 4}]
    R.add("h2_toc_bom_crlf", base, toc, exp=exp, pages=5, xref="classic", revisions=1,
          desc="TOC saved by Windows Notepad: UTF-8 BOM, CRLF, trailing spaces/tab after the page number",
          probe="BOM must not end up in the first title; CR must not end up in titles")

    toc = "第一章 引言 1\n\t1.1 背景 2\n附录 5\n".encode("gbk")
    R.add("h2_toc_gbk", base, toc, exp=[], refuse=True, pages=5, xref="classic", revisions=1,
          desc="TOC file encoded in GBK (not UTF-8), as saved by a Chinese-locale Windows editor",
          probe="must refuse (exit 2) rather than write U+FFFD garbage titles")

    toc = "Café 1\n\tRésumé 2\n".encode("latin-1")
    R.add("h2_toc_latin1", base, toc, exp=[], refuse=True, pages=5, xref="classic", revisions=1,
          desc="TOC file encoded in Latin-1", probe="must refuse rather than write mojibake")

    toc = "﻿".encode("utf-16-le") + "Intro 1\nBody 3\n".encode("utf-16-le")
    R.add("h2_toc_utf16le", base, toc, exp=[], refuse=True, pages=5, xref="classic", revisions=1,
          desc="TOC saved as UTF-16LE with BOM (Windows 'Unicode')", probe="must refuse (or decode correctly)")

    toc = "Intro 1\n第二章 ５\n".encode("utf-8")
    R.add("h2_toc_fullwidth_digit", base, toc, exp=[], refuse=True, pages=5, xref="classic", revisions=1,
          desc="page number written with a fullwidth digit (U+FF15)", probe="refuse (exit 2) with a clear message")

    toc = "Intro 0\n".encode()
    R.add("h2_toc_page_zero", base, toc, exp=[], refuse=True, pages=5, xref="classic", revisions=1,
          desc="page number 0", probe="refuse")

    toc = "A 1\nB\n".encode()
    R.add("h2_toc_missing_page", base, toc, exp=[], refuse=True, pages=5, xref="classic", revisions=1,
          desc="a line without a page number", probe="refuse")

    toc = ("Very long " * 20000 + "1\n").encode()
    R.add("h2_toc_title_200k", base, toc, exp=[{"title": ("Very long " * 20000).strip(), "level": 0,
                                                 "page_index": 0}], pages=5, xref="classic", revisions=1,
          desc="one 200,000-character title", probe="no crash; hex string of 800 KB")


def main():
    GEN.mkdir(parents=True, exist_ok=True)
    for p in GEN.iterdir():
        p.unlink()
    R = Registry(GEN)
    build(R)
    R.save()
    print(f"wrote {len(R.manifest['fixtures'])} fixtures to {GEN}")


if __name__ == "__main__":
    main()
