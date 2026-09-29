# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9"]
# ///
"""
make_hostile.py -- hand-crafted hostile / tricky PDFs for the mulu writer.

    uv run --python 3.12 tools/adversarial/hostile-inputs/make_hostile.py

Writes tools/adversarial/hostile-inputs/gen/<name>.pdf + sidecars + manifest.json in the
same format as Fixtures/generated, so tools/verify/verify.py run-all --gen <dir> can run it.
Each manifest entry carries a "probe" note saying what the fixture attacks and, where the
correct behaviour is debatable, what we expect.
"""
from __future__ import annotations

import io
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pdfbuild import (FONT, PDF, Registry, content, expected, page, runs, toc_basic,  # noqa: E402
                      toc_text)

GEN = HERE / "gen"


# ---------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------

def std_parts(n, root=1, pages=2, font=3, first=4, cat_extra=b"", pages_extra=b"", pgen=lambda i: 0,
              page_extra=b"", step=2):
    objs, streams, kids = {}, {}, []
    for i in range(n):
        p = first + step * i
        c = p + 1
        objs[p] = (pgen(i), page(pages, c, font, extra=page_extra))
        streams[c] = (0, b"", content(i))
        kids.append(b"%d %d R" % (p, pgen(i)))
    objs[pages] = (0, b"<< /Type /Pages /Kids [" + b" ".join(kids) + b"] /Count %d%s >>" % (n, pages_extra))
    objs[root] = (0, b"<< /Type /Catalog /Pages %d 0 R%s >>" % (pages, cat_extra))
    objs[font] = (0, FONT)
    return objs, streams


def emit(pdf: PDF, objs, streams, order=None, before_each=b""):
    allnums = sorted(set(objs) | set(streams))
    for n in (order or allnums):
        if before_each:
            pdf.raw(before_each)
        if n in objs:
            g, body = objs[n]
            pdf.obj(n, body, g)
        else:
            g, inner, data = streams[n]
            pdf.stream(n, inner, data, g)


def simple_classic(n=5, trailer=b"/Root 1 0 R", tail=None, **pdfkw) -> PDF:
    pdf = PDF(**pdfkw)
    objs, streams = std_parts(n)
    emit(pdf, objs, streams)
    pdf.classic(trailer, tail=tail)
    return pdf


def objstm_doc(n=5, W=(1, 4, 2), predictor=None, rowfilt=lambda r: 2, colors=1, flate=True, trailer=b"/Root 1 0 R",
               tail=None, version=b"1.7", extra_filters=None, xref_length=None, objstm_filter="flate",
               cat_extra=b"") -> PDF:
    """Catalog, page tree and page dicts compressed in one object stream; contents are plain streams."""
    pdf = PDF(version=version)
    objs, streams = std_parts(n, cat_extra=cat_extra)
    for num in sorted(streams):
        g, inner, data = streams[num]
        pdf.stream(num, inner, data, g)
    nxt = max(set(objs) | set(streams)) + 1
    pdf.objstm(nxt, [(k, objs[k][1]) for k in sorted(objs)], filt=objstm_filter)
    pdf.xrefstream(nxt + 1, trailer, W=W, predictor=predictor, rowfilt=rowfilt, colors=colors, flate=flate,
                   tail=tail, extra_filters=extra_filters, length=xref_length)
    return pdf


def tail_with(eol=b"\n", pre=b"", mid=None, post=b"%%EOF\n", value=None):
    def t(xoff):
        v = value(xoff) if value else xoff
        return pre + b"startxref" + (mid if mid is not None else eol) + b"%d" % v + eol + post
    return t


# ---------------------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------------------

def build_all(R: Registry):
    T5 = toc_basic(5)
    T5b = toc_basic(5, tag="R2 ")

    # ---- line endings / tail ------------------------------------------------------------
    pdf = simple_classic(5, eol=b"\r\n")
    R.add("h_crlf_all", pdf.bytes(), T5, pages=5, xref="classic", revisions=1, reapply=T5b,
          desc="every EOL is CRLF (objects, stream keywords, xref entries, trailer, %%EOF)")

    pdf = simple_classic(5, eol=b"\r")
    R.add("h_cr_only", pdf.bytes(), T5, pages=5, xref="classic", revisions=1, reapply=T5b,
          desc="CR-only EOLs everywhere except 'stream\\r\\n' (spec requires CRLF or LF there); entries ' \\r'")

    pdf = simple_classic(5, eol=b"\r", stream_eol=b"\r")
    R.add("h_cr_only_stream_cr", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="CR-only EOLs INCLUDING 'stream\\r' (technically invalid, common in old Mac files)")

    pdf = simple_classic(5, eol=b"\r\n", tail=lambda x: b"startxref\r\n%d\r\n%%%%EOF" % x)
    R.add("h_no_final_eol_crlf", pdf.bytes(), T5, pages=5, xref="classic", revisions=1, reapply=T5b,
          desc="CRLF file whose last bytes are '%%EOF' with no EOL")

    pdf = simple_classic(5)
    data = pdf.bytes() + b"\x00\x00\xff\xfe junk\r\nstartxref\n999999\n%%EOF\n\x00garbage"
    R.add("h_garbage_fake_startxref", data, T5, pages=5, revisions_ambiguous=True,
          desc="garbage after %%EOF that itself contains 'startxref 999999 %%EOF' (points outside the file)",
          probe="last startxref is bogus -> reconstruction path; reconstruction is unambiguous so apply should work")

    pdf = simple_classic(5, tail=lambda x: b"startxref\n%d\n%%%%EOF\n%%%%EOF\r\n\r\n%%%%EOF" % x)
    R.add("h_two_eof", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="three %%EOF markers after the single startxref, mixed EOLs, no final EOL")

    pdf = simple_classic(5, tail=lambda x: b"startxref \t\r\n%% a comment line\r\n  \t%d  %% trailing comment\n%%%%EOF\n" % x)
    R.add("h_startxref_comment", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="whitespace, a comment line and a trailing comment between 'startxref' and its number")

    for name, delta, note in [("h_startxref_plus1", 1, "points at 'ref' inside 'xref' -> reconstruction"),
                              ("h_startxref_minus1", -1, "points at the LF before 'xref' (tolerated without reconstruction)"),
                              ("h_startxref_minus7", -7, "points into 'endobj' before the xref -> reconstruction"),
                              ("h_startxref_zero", 0, "startxref 0 -> reconstruction")]:
        v = (lambda d: (lambda x: x + d))(delta) if name != "h_startxref_zero" else (lambda x: 0)
        pdf = simple_classic(5, tail=tail_with(value=v))
        R.add(name, pdf.bytes(), T5, pages=5, revisions_ambiguous=True, reapply=T5b if delta == 1 else None,
              desc=f"startxref off: {note}", probe="apply must succeed (reconstruct or tolerate) and output must be clean")

    # two revisions redefining object 5 (page 1 content), startxref broken -> ambiguous reconstruction
    pdf = PDF()
    objs, streams = std_parts(4)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    pdf.stream(5, b"", content(0, "Revised page"))
    pdf.classic(b"/Root 1 0 R", tail=tail_with(value=lambda x: x + 2))
    R.add("h_offxref_multirev_ambiguous", pdf.bytes(), toc_basic(4), refuse=True,
          desc="2 revisions both defining '5 0 obj', final startxref off by 2",
          probe="contract: reconstruct only if unambiguous, otherwise refuse")

    # ---- generations -------------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(4, pgen=lambda i: 5 if i == 2 else 0)
    objs[1] = (3, objs[1][1])
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 3 R /Info 20 0 R /ID [<A1B2> <C3D4>]", size=21)
    # (Info object added after: append then a second classic section would change revisions; keep it simple)
    data = pdf.bytes()
    R.add("h_catalog_gen3", data, toc_basic(4), pages=4, xref="classic", revisions=1, reapply=toc_basic(4, "R2 "),
          desc="catalog is '1 3 obj' (/Root 1 3 R), page 3 is '8 5 obj'; /Info points to a missing object",
          probe="new catalog revision must be '1 3 obj'; the dest of page 3 must be '8 5 R'")

    # ---- xref streams --------------------------------------------------------------------
    # object numbers with gaps -> /Index with several subsections, W [1 3 1]
    pdf = PDF()
    objs, streams = std_parts(5, root=10, pages=11, font=12, first=20, step=7)
    for num in sorted(streams):
        pdf.stream(num, b"", streams[num][2])
    pdf.objstm(60, [(k, objs[k][1]) for k in sorted(objs)])
    pdf.xrefstream(70, b"/Root 10 0 R /ID [<00112233> <00112233>]", W=(1, 3, 1))
    R.add("h_xrefstm_w131_multiindex", pdf.bytes(), T5, pages=5, xref="stream", revisions=1, reapply=T5b,
          desc="xref stream W [1 3 1], /Index with 12 subsections (gaps), catalog+page tree+pages in an ObjStm")

    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    pdf.xrefstream(20, b"/Root 1 0 R", W=(0, 2, 0), include0=False)
    R.add("h_xrefstm_w020", pdf.bytes(), T5, pages=5, xref="stream", revisions=1, reapply=T5b,
          desc="xref stream W [0 2 0] (type and generation fields absent -> defaults 1 and 0), /Index starts at 1")

    pdf = objstm_doc(5, W=(1, 2, 1), predictor=12, rowfilt=2)
    R.add("h_xrefstm_pred12", pdf.bytes(), T5, pages=5, xref="stream", revisions=1, reapply=T5b,
          desc="xref stream Flate + /Predictor 12 (PNG Up), W [1 2 1]")

    pdf = objstm_doc(9, W=(1, 4, 2), predictor=15, rowfilt=lambda r: r % 5)
    R.add("h_xrefstm_pred15", pdf.bytes(), toc_basic(9), pages=9, xref="stream", revisions=1,
          desc="xref stream /Predictor 15, rows cycling PNG filters None/Sub/Up/Average/Paeth")

    pdf = objstm_doc(9, W=(1, 2, 1), predictor=15, rowfilt=lambda r: (r * 3) % 5, colors=2)
    R.add("h_xrefstm_pred_colors2", pdf.bytes(), toc_basic(9), pages=9, xref="stream", revisions=1,
          desc="xref stream PNG predictor with /Colors 2 /Columns 2 (bpp=2), all 5 filter types")

    pdf = objstm_doc(6, W=(1, 3, 1), predictor=2)
    R.add("h_xrefstm_tiff2", pdf.bytes(), toc_basic(6), pages=6, xref="stream", revisions=1,
          desc="xref stream /Predictor 2 (TIFF horizontal differencing)")

    pdf = objstm_doc(5, W=(1, 2, 2), predictor=12, extra_filters="ahx")
    R.add("h_xrefstm_ahx_flate", pdf.bytes(), T5, pages=5, xref="stream", revisions=1,
          desc="xref stream /Filter [/ASCIIHexDecode /FlateDecode] /DecodeParms [null <<PNG>>]")

    # indirect /Length for the xref stream itself and for the object stream (defined after it)
    pdf = PDF()
    objs, streams = std_parts(5)
    for num in sorted(streams):
        g, inner, data = streams[num]
        pdf.stream(num, inner, data, g, length=b"%d 0 R" % (100 + num))
        pdf.obj(100 + num, b"%d" % len(data))
    body = [(k, objs[k][1]) for k in sorted(objs)]
    # object stream with an indirect /Length that is defined AFTER it
    offs, parts, o = [], [], 0
    for _, b in body:
        offs.append(o)
        parts.append(b)
        o += len(b) + 1
    header = (" ".join(f"{n} {off}" for (n, _), off in zip(body, offs)) + "\n").encode()
    raw = zlib.compress(header + b"\n".join(parts) + b"\n")
    pdf.stream(30, b"/Type /ObjStm /N %d /First %d /Filter /FlateDecode" % (len(body), len(header)), raw,
               length=b"31 0 R")
    for i, (n, _) in enumerate(body):
        pdf.rev[n] = (2, 30, i)
    pdf.obj(31, b"%d" % len(raw))
    # the xref stream's own /Length is indirect (object 32 written just before it)
    rows_len_holder = 32
    # compute xref stream bytes first to know their length: build with a placeholder then patch
    tmp = PDF()
    tmp.buf = bytearray(pdf.buf)
    tmp.rev = dict(pdf.rev)
    tmp.rev[rows_len_holder] = (1, tmp.pos(), 0)
    tmp.obj(rows_len_holder, b"0000000000")
    tmp.xrefstream(33, b"/Root 1 0 R", W=(1, 4, 2), length=b"32 0 R")
    xs = tmp.bytes()
    so = xs.rfind(b"stream\n", 0, xs.rfind(b"endstream")) + 7
    eo = xs.rfind(b"\nendstream")
    xs = xs.replace(b"32 0 obj\n0000000000", b"32 0 obj\n%010d" % (eo - so))
    R.add("h_indirect_lengths", xs, T5, pages=5, xref="stream", revisions=1, reapply=T5b,
          desc="every stream has an indirect /Length: contents (after), ObjStm (after), and the xref stream itself")

    # ---- hybrid ----------------------------------------------------------------------------
    for variant in ("omit", "free"):
        pdf = PDF(version=b"1.5")
        objs, streams = std_parts(6)
        for num in sorted(streams):
            pdf.stream(num, b"", streams[num][2])
        pdf.obj(1, objs[1][1])
        pdf.obj(3, objs[3][1])
        comp_nums = sorted(k for k in objs if k not in (1, 3))
        pdf.objstm(30, [(k, objs[k][1]) for k in comp_nums])
        hidden = {k: pdf.rev.pop(k) for k in comp_nums}
        # hidden xref stream: compressed entries only
        xs_off = pdf.pos()
        rows = bytearray()
        for k in comp_nums:
            t, f2, f3 = hidden[k]
            rows += bytes([t]) + f2.to_bytes(4, "big") + f3.to_bytes(2, "big")
        idx = [x for r in runs(comp_nums) for x in r]
        cz = zlib.compress(bytes(rows))
        pdf.buf += (b"31 0 obj\n<< /Type /XRef /Size 32 /W [1 4 2] /Index [" + b" ".join(b"%d" % x for x in idx)
                    + b"] /Filter /FlateDecode /Length %d >>\nstream\n" % len(cz) + cz + b"\nendstream\nendobj\n")
        pdf.rev[31] = (1, xs_off, 0)
        if variant == "free":
            for k in comp_nums:
                pdf.rev[k] = (0, 0, 0)
        pdf.classic(b"/Root 1 0 R /XRefStm %d" % xs_off, size=32)
        R.add(f"h_hybrid_{variant}", pdf.bytes(), toc_basic(6), pages=6, xref="hybrid", revisions=1,
              reapply=toc_basic(6, "R2 ") if variant == "omit" else None,
              desc=f"hybrid-reference file: page tree + page dicts only in the /XRefStm stream; table "
                   f"{'omits' if variant == 'omit' else 'lists as FREE'} the compressed objects",
              probe="free-in-table variant: readers differ (table entries take precedence)" if variant == "free" else "")

    # ---- free entries / reuse across revisions -----------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(3)  # pages 4,6,8
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R /ID [<AA> <AA>]")
    # rev2: delete page 2 (obj 6 -> free gen 1; content 7 free gen 1), free list 0 -> 6 -> 7 -> 0
    pdf.obj(2, b"<< /Type /Pages /Kids [4 0 R 8 0 R] /Count 2 >>")
    pdf.free(0, 6, 65535)
    pdf.free(6, 7, 1)
    pdf.free(7, 0, 1)
    pdf.classic(b"/Root 1 0 R /ID [<AA> <BB>]")
    # rev3: reuse 6 (gen 1) as a new page appended at the end; 7 stays free (gen 1)
    pdf.stream(10, b"", content(2, "Reborn page"))
    pdf.obj(6, page(2, 10, 3), 1)
    pdf.obj(2, b"<< /Type /Pages /Kids [4 0 R 8 0 R 6 1 R] /Count 3 >>")
    pdf.free(0, 7, 65535)
    pdf.free(7, 0, 1)
    pdf.classic(b"/Root 1 0 R /ID [<AA> <CC>]")
    T3 = [(0, "First", 1), (0, "Second (was third)", 2), (1, "Reborn obj 6 gen 1", 3)]
    R.add("h_free_reuse_3rev", pdf.bytes(), T3, pages=3, xref="classic", revisions=3,
          reapply=[(0, "R2 First", 1), (0, "R2 Last", 3)],
          desc="3 revisions: page obj 6 freed (gen 1) in rev2 and re-used as '6 1 obj' in rev3; free list chains",
          probe="dest of the last page must be '6 1 R'; appended classic xref repeats object 0's free-list head (7)")

    # ---- page trees ----------------------------------------------------------------------------
    # depth-10 tree; each level has one page then the next level; inherited attrs on the upper nodes
    pdf = PDF()
    pdf.obj(3, FONT)
    levels = 10
    node_nums = [2] + [100 + i for i in range(1, levels)]
    page_objs = {}
    order_pages = []
    for d in range(levels):
        pnum, cnum = 200 + 2 * d, 201 + 2 * d
        order_pages.append(pnum)
    # contents
    for d in range(levels):
        pdf.stream(201 + 2 * d, b"", content(d, f"Depth {d + 1} page"))
    # pages at each depth: no MediaBox/Resources (inherited), Rotate only via inheritance
    for d in range(levels):
        pdf.obj(200 + 2 * d, b"<< /Type /Page /Parent %d 0 R /Contents %d 0 R >>" % (node_nums[d], 201 + 2 * d))
    # an extra last-leaf page at the deepest level
    pdf.stream(301, b"", content(levels, "Deepest leaf"))
    pdf.obj(300, b"<< /Type /Page /Parent %d 0 R /Contents 301 0 R /Rotate 0 >>" % node_nums[-1])
    for d in range(levels):
        kids = [b"%d 0 R" % (200 + 2 * d)]
        if d + 1 < levels:
            kids.append(b"%d 0 R" % node_nums[d + 1])
        else:
            kids.append(b"300 0 R")
        extra = b""
        if d == 0:
            extra = b" /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >>"
        if d == 3:
            extra = b" /Rotate 90 /CropBox [0 0 600 780]"
        if d == 6:
            extra = b" /Rotate 180 /MediaBox [0 0 595 842]"
        parent = b" /Parent %d 0 R" % node_nums[d - 1] if d else b""
        pdf.obj(node_nums[d], b"<< /Type /Pages%s /Kids [%s] /Count %d%s >>" % (parent, b" ".join(kids),
                                                                               levels - d + 1, extra))
    pdf.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    pdf.classic(b"/Root 1 0 R")
    T11 = [(0, "Level-1 page", 1), (1, "Depth 4 (inherits Rotate 90)", 4), (2, "Depth 7 (Rotate 180, A4)", 7),
           (0, "Depth 10", 10), (1, "Deepest leaf", 11)]
    R.add("h_deep_pagetree10", pdf.bytes(), T11, pages=11, xref="classic", revisions=1,
          reapply=[(0, "R2 a", 2), (0, "R2 b", 11)],
          desc="page tree 10 /Pages levels deep, pages at every level, inherited /MediaBox /Resources /Rotate /CropBox")

    # cycles
    def cycle_doc(kind):
        pdf = PDF()
        pdf.obj(3, FONT)
        for i in range(3):
            pdf.stream(21 + 2 * i, b"", content(i))
        if kind == "ancestor":
            pdf.obj(2, b"<< /Type /Pages /Kids [20 0 R 10 0 R] /Count 3 /MediaBox [0 0 612 792] "
                       b"/Resources << /Font << /F1 3 0 R >> >> >>")
            pdf.obj(10, b"<< /Type /Pages /Parent 2 0 R /Kids [22 0 R 2 0 R 24 0 R] /Count 2 >>")
            parents = {20: 2, 22: 10, 24: 10}
        elif kind == "self":
            pdf.obj(2, b"<< /Type /Pages /Kids [20 0 R 2 0 R 22 0 R 24 0 R] /Count 3 /MediaBox [0 0 612 792] "
                       b"/Resources << /Font << /F1 3 0 R >> >> >>")
            parents = {20: 2, 22: 2, 24: 2}
        elif kind == "dupleaf":
            pdf.obj(2, b"<< /Type /Pages /Kids [20 0 R 22 0 R 20 0 R 24 0 R] /Count 4 /MediaBox [0 0 612 792] "
                       b"/Resources << /Font << /F1 3 0 R >> >> >>")
            parents = {20: 2, 22: 2, 24: 2}
        elif kind == "missingkid":
            pdf.obj(2, b"<< /Type /Pages /Kids [20 0 R 99 0 R 22 0 R 24 0 R] /Count 4 /MediaBox [0 0 612 792] "
                       b"/Resources << /Font << /F1 3 0 R >> >> >>")
            parents = {20: 2, 22: 2, 24: 2}
        for i, p in enumerate((20, 22, 24)):
            pdf.obj(p, b"<< /Type /Page /Parent %d 0 R /Contents %d 0 R >>" % (parents[p], 21 + 2 * i))
        pdf.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
        pdf.classic(b"/Root 1 0 R")
        return pdf.bytes()

    T3c = [(0, "One", 1), (0, "Two", 2), (0, "Three", 3)]
    R.add("h_pagetree_cycle", cycle_doc("ancestor"), T3c, refuse=True, pages=3, xref="classic", revisions=1,
          desc="/Pages 10 lists its own parent (2 0 R) among its /Kids -> page-tree cycle",
          probe="lens: must refuse (not hang, not silently skip)")
    R.add("h_pagetree_selfkid", cycle_doc("self"), T3c, refuse=True, pages=3, xref="classic", revisions=1,
          desc="root /Pages lists itself in /Kids", probe="lens: must refuse")
    R.add("h_pagetree_dupleaf", cycle_doc("dupleaf"), [(0, "One", 1), (0, "Two", 2), (0, "Four", 4)],
          pages=4, xref="classic", revisions=1,
          desc="the same page object appears twice in /Kids (page 1 == page 3)",
          probe="ambiguous page numbering; readers may disagree")
    R.add("h_pagetree_missingkid", cycle_doc("missingkid"), [(0, "One", 1), (0, "Two", 2), (0, "Three", 3)],
          pages=3, xref="classic", revisions=1,
          desc="/Kids [20 0 R 99 0 R 22 0 R 24 0 R] /Count 4 where object 99 does not exist",
          probe="mulu silently skips the dangling kid (3 pages); pdf.js-style /Count readers see 4 -> page numbers shift")

    # ---- existing outline inside an object stream ---------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(5, cat_extra=b" /Outlines 40 0 R /PageMode /UseOutlines")
    for num in sorted(streams):
        pdf.stream(num, b"", streams[num][2])
    ol = {
        40: b"<< /Type /Outlines /First 41 0 R /Last 43 0 R /Count 3 >>",
        41: b"<< /Title (Old one) /Parent 40 0 R /Next 42 0 R /Dest [4 0 R /Fit] >>",
        42: b"<< /Title (Old two) /Parent 40 0 R /Prev 41 0 R /Next 43 0 R /Dest [6 0 R /Fit] >>",
        43: b"<< /Title (Old three) /Parent 40 0 R /Prev 42 0 R /Dest [8 0 R /Fit] >>",
    }
    members = [(k, objs[k][1]) for k in sorted(objs)] + sorted(ol.items())
    pdf.objstm(50, members)
    pdf.xrefstream(51, b"/Root 1 0 R /ID [<0102> <0102>]", predictor=12)
    R.add("h_existing_outline_objstm", pdf.bytes(), T5, pages=5, xref="stream", revisions=1, has_outline=True,
          reapply=T5b, desc="existing /Outlines + items + catalog all compressed in one ObjStm")
    R.add("h_existing_outline_emptytoc", pdf.bytes(), b"# only comments\n\n# nothing else\n", exp=[], pages=5,
          xref="stream", revisions=1, has_outline=True,
          desc="same file, TOC with only comments -> the outline must be removed")

    # ---- PDF 2.0 ----------------------------------------------------------------------------
    pdf = objstm_doc(5, version=b"2.0", predictor=12, cat_extra=b" /Version /2.0 /Lang (en-US)",
                     trailer=b"/Root 1 0 R /ID [<DEADBEEF> <DEADBEEF>]")
    R.add("h_pdf20", pdf.bytes(), T5, pages=5, xref="stream", revisions=1, reapply=T5b,
          desc="%PDF-2.0 header, catalog /Version /2.0, xref stream, /ID, no /Info")

    # ---- /Size lower than the highest object -------------------------------------------------
    pdf = simple_classic(5)
    data = pdf.bytes().replace(b"<< /Size 14 ", b"<< /Size 4  ")
    assert b"/Size 4  " in data
    R.add("h_size_too_low", data, T5, pages=5, xref="classic", revisions=1, reapply=T5b,
          desc="classic trailer /Size 4 while the xref lists objects 0..14 (padded so offsets stay valid)",
          probe="tolerate: new objects must not collide with 5..14")

    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    pdf.xrefstream(20, b"/Root 1 0 R", size=6)
    R.add("h_xrefstm_size_too_low", pdf.bytes(), T5, pages=5, xref="stream", revisions=1,
          desc="xref stream /Size 6 while /Index covers objects up to 20",
          probe="tolerate: new objects must not collide with 6..20")

    # ---- truncated -----------------------------------------------------------------------------
    full = simple_classic(8).bytes()
    R.add("h_truncated_classic", full[:len(full) * 55 // 100], toc_basic(8), refuse=True,
          desc="classic 8-page file cut at 55% (no xref, no trailer)", probe="must refuse, not crash")
    fullx = objstm_doc(8, predictor=12).bytes()
    # (the first version used rfind(b"stream\n"), which matches "endstream\n": that cut is kept below
    # as h_truncated_after_xrefstm, where every object is intact and reconstruction is legitimate)
    R.add("h_truncated_after_xrefstm", fullx[:fullx.rfind(b"stream\n") + 7 + 10], toc_basic(8), pages=8,
          revisions_ambiguous=True,
          desc="xref-stream file cut 10 bytes after 'endstream' of the xref stream (inside 'startxref')",
          probe="every object intact; only startxref missing -> reconstruction legitimate")
    cut = fullx.find(b"stream\n", fullx.find(b"/Type /XRef")) + 7 + 10
    R.add("h_truncated_in_xrefstm", fullx[:cut], toc_basic(8), refuse=True,
          desc="xref-stream file cut 10 bytes into the xref stream data", probe="must refuse")
    cut2 = fullx.find(b"endstream", fullx.find(b"/Type /ObjStm")) - 20
    R.add("h_truncated_in_objstm", fullx[:cut2], toc_basic(8), refuse=True,
          desc="xref-stream file cut inside the object stream that holds catalog + pages", probe="must refuse")
    R.add("h_truncated_tail_digits", full[:full.rfind(b"startxref") + 12], toc_basic(8), pages=8,
          revisions_ambiguous=True,
          desc="complete body + xref + trailer, but the file ends in the middle of the startxref number",
          probe="nothing is missing except the offset -> reconstruction is legitimate; apply may succeed")
    # linearized + truncated (first-page trailer survives at the top)
    lin = linearized(8)
    R.add("h_truncated_linearized", lin[:len(lin) * 60 // 100], toc_basic(8), refuse=True,
          desc="qpdf-linearized 8-page file cut at 60%: the first-page xref+trailer at the top survive",
          probe="must refuse: pages beyond the cut are missing")

    # ---- zero pages / ranges ---------------------------------------------------------------------
    pdf = PDF()
    pdf.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    pdf.obj(2, b"<< /Type /Pages /Kids [] /Count 0 >>")
    pdf.classic(b"/Root 1 0 R")
    R.add("h_zero_pages_empty_kids", pdf.bytes(), [(0, "x", 1)], refuse=True, pages=0,
          desc="/Kids [] /Count 0")
    pdf = PDF()
    pdf.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    pdf.obj(2, b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 0 >>")
    pdf.obj(3, b"<< /Type /Pages /Parent 2 0 R /Kids [] /Count 0 >>")
    pdf.obj(4, b"<< /Type /Pages /Parent 2 0 R /Kids [5 0 R] /Count 0 >>")
    pdf.obj(5, b"<< /Type /Pages /Parent 4 0 R /Kids [] /Count 0 >>")
    pdf.classic(b"/Root 1 0 R")
    R.add("h_zero_pages_nested_empty", pdf.bytes(), [(0, "x", 1)], refuse=True, pages=0,
          desc="three levels of /Pages nodes, none has a leaf")
    pdf = PDF()
    pdf.obj(1, b"<< /Type /Catalog >>")
    pdf.classic(b"/Root 1 0 R")
    R.add("h_zero_pages_no_pages_key", pdf.bytes(), [(0, "x", 1)], refuse=True, pages=0,
          desc="catalog without /Pages")

    R.add("h_page_out_of_range", simple_classic(5).bytes(), [(0, "ok", 1), (0, "too far", 6)], refuse=True,
          pages=5, xref="classic", revisions=1, desc="TOC targets page 6 of 5")
    R.add("h_offset_below_one", simple_classic(5).bytes(), [(0, "Cover", 1), (0, "Body", 4)], refuse=True,
          offset=-1, pages=5, xref="classic", revisions=1, exp=[],
          desc="--offset -1 maps printed page 1 to physical page 0")
    R.add("h_offset_negative_ok", simple_classic(5).bytes(), [(0, "Body p3", 3), (1, "Body p5", 5)], offset=-2,
          pages=5, xref="classic", revisions=1, desc="--offset -2 with printed pages 3..5 -> physical 1..3")
    R.add("h_offset_pushes_out", simple_classic(5).bytes(), [(0, "A", 1), (0, "B", 3)], refuse=True, offset=3,
          pages=5, xref="classic", revisions=1, exp=[], desc="--offset 3 maps printed page 3 to physical 6 of 5")

    # ---- TOC contents ------------------------------------------------------------------------------
    TU = [
        (0, "👨‍👩‍👧‍👦 Family (ZWJ sequence)", 1),
        (1, "🇨🇳🇯🇵🇺🇸 flags", 1),
        (1, "👍🏽 skin tone + ❤️ VS16", 2),
        (0, "العربية: الفصل الأول", 2),
        (1, "עברית: פרק ראשון", 3),
        (2, "‏RLM-led mixed עב English 123‎", 3),
        (0, "Ext-B 𠀀𪚥 and combining é ñ", 4),
        (0, "Tab\tinside the title", 4),
        (0, "Math 𝔘𝔫𝔦𝔠𝔬𝔡𝔢 ∑∫ ≠", 5),
        (0, "Title ending in a number 2024", 5),
        (0, "中文标题：第一章　总论", 5),
    ]
    R.add("h_toc_emoji_rtl", simple_classic(5).bytes(), TU, pages=5, xref="classic", revisions=1,
          desc="TOC titles: ZWJ emoji, flags, skin tones, VS16, Arabic, Hebrew, RLM/LRM, CJK Ext-B, combining "
               "marks, a TAB inside a title, math alphanumerics, trailing number, ideographic space")

    TW = [(0, "odd﻿inner BOM", 1), (0, "﻿BOM-led second line", 2), (0, "NUL\x00inside", 3),
          (0, "LS inside", 4), (0, "Replacement � char", 5)]
    R.add("h_toc_weird_codepoints", simple_classic(5).bytes(), TW, pages=5, xref="classic", revisions=1,
          desc="titles with an inner U+FEFF, a U+FEFF-led title (not line 1), U+0000, U+2028, U+FFFD",
          probe="readers may normalise these; informational")

    bad = "Part One 1\n\t\tJumped two levels 2\n".encode()
    R.add("h_toc_level_jump2", simple_classic(5).bytes(), bad, exp=[], refuse=True, pages=5, xref="classic",
          revisions=1, desc="TOC level jumps 0 -> 2", probe="contract: refuse (exit 2)")

    ws = ("﻿# BOM + CRLF + unicode separators\r\n"
          "Chapter 1 NBSP 3\r\n"          # NBSP-separated page
          "\tSection　ideographic　4\r\n"        # U+3000 separated page
          "  2024 5\r\n"                                  # two spaces = level 1, title '2024'
          "Final\t \t5   \r\n").encode("utf-8")
    R.add("h_toc_unicode_ws", simple_classic(5).bytes(), ws,
          exp=[{"title": "Chapter 1 NBSP", "level": 0, "page_index": 2},
               {"title": "Section　ideographic", "level": 1, "page_index": 3},
               {"title": "2024", "level": 1, "page_index": 4},
               {"title": "Final", "level": 0, "page_index": 4}],
          pages=5, xref="classic", revisions=1,
          desc="TOC with UTF-8 BOM, CRLF, NBSP / U+3000 as the title-page separator, numeric-only title",
          probe="beyond the letter of the contract (whitespace = Unicode White_Space); informational")

    # ---- exotic catalogs -----------------------------------------------------------------------------
    cat = (b"<< /Type /Catalog /Pages 2 0 R\n"
           b"  % a comment inside the catalog dictionary\n"
           b"  /Lang (en\\(US\\) \\\\ \\376\\377 tab\\t) /A#20B#23C /Name#C3#A9 /Caf#C3#A9 /Str (caf\\351)\n"
           b"  /ViewerPreferences << /DisplayDocTitle true /Direction /R2L /PrintPageRange [0 1] >>\n"
           b"  /OpenAction [4 0 R /FitH -.5] /Threshold +3.0 /Weird 4. /Neg -0 /Big 123456789012345678\n"
           b"  /PageLabels << /Nums [0 << /S /r >> 2 << /S /D /St 1 /P <FEFF00410042> >>] >>\n"
           b"  /PageMode /UseThumbs /PageMode /FullScreen\n"
           b"  /MarkInfo << /Marked true >> /AcroForm << /Fields [] /DA (/Helv 0 Tf 0 g) /NeedAppearances false >>\n"
           b"  /Binary <00FF10EE7F80> /Nested [[[<< /K [1 [2 [3]]] >>]]] /Outlines null\n"
           b">>")
    pdf = PDF()
    objs, streams = std_parts(5)
    objs[1] = (0, cat)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R /Info 30 0 R")
    R.add("h_catalog_exotic", pdf.bytes(), T5, pages=5, xref="classic", revisions=1, reapply=T5b,
          desc="catalog with escaped names (#20 #23 #C3#A9), octal/escaped literal strings, comments, reals "
               "(-.5 +3.0 4. -0), 18-digit int, duplicate /PageMode, /PageLabels, /AcroForm, deep nesting, "
               "/Outlines null, /Info pointing at a missing object",
          probe="catalog revision must be semantically identical except /Outlines and /PageMode")

    cat2 = b"<< /Type /Catalog / (empty-name key) /Pages 99 0 R /Pages 2 0 R /Z#00 1 >>"
    pdf = PDF()
    objs, streams = std_parts(5)
    objs[1] = (0, cat2)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    R.add("h_catalog_dupkeys_emptyname", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="catalog with an empty name key '/', duplicate /Pages (first bogus, last real), name with #00",
          probe="readers take the LAST duplicate; the re-serialised catalog must keep pointing at 2 0 R")

    # ---- junk before the header ------------------------------------------------------------------------
    junk50 = b"Content-Type: application/pdf\r\nX-Junk: 0123456789\r\n"
    R.add("h_junk_prefix_rel50", simple_classic(5, prefix=junk50).bytes(), T5, pages=5, xref="classic",
          revisions=1, reapply=T5b, desc=f"{len(junk50)} bytes of HTTP-header junk before %PDF-; offsets relative to %PDF-")
    R.add("h_junk_prefix_abs30", simple_classic(5, prefix=b"#" * 29 + b"\n", rel_to_header=False).bytes(), T5,
          pages=5, xref="classic", revisions=1,
          desc="30 bytes junk before %PDF-; offsets ABSOLUTE (file-relative)")
    R.add("h_junk_prefix_rel1", simple_classic(5, prefix=b"\n").bytes(), T5, pages=5, xref="classic",
          revisions=1, reapply=T5b,
          desc="a single LF before %PDF-; offsets relative to %PDF- (what qpdf/pdf.js/PDFium assume)",
          probe="base-0 parse succeeds by coincidence (every offset lands on the preceding EOL)")
    pdf = PDF(prefix=b"\r\n")
    objs, streams = std_parts(5)
    emit(pdf, objs, streams, before_each=b"\r\n")
    pdf.raw(b"\r\n")
    pdf.classic(b"/Root 1 0 R")
    R.add("h_junk_prefix_rel2_blanklines", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="CRLF before %PDF- (stray newline from a web script), writer puts a blank line before every object; "
               "offsets relative to %PDF-", probe="base-0 parse succeeds by coincidence")
    pdf = PDF(prefix=b"\xef\xbb\xbf")
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    R.add("h_junk_prefix_utf8bom", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="UTF-8 BOM before %PDF-; offsets relative to %PDF-")

    # ---- xref table oddities ---------------------------------------------------------------------------
    R.add("h_xref_19byte_entries", simple_classic(5, entry_eol=b"\n").bytes(), T5, pages=5, xref="classic",
          revisions=1, reapply=T5b, desc="classic xref entries end in a single LF (19 bytes)")
    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R", first_one_bug=True)
    R.add("h_xref_first_subsection_1", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="xref subsection header says '1 15' but starts with object 0's free entry (classic writer bug)")
    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams)
    pdf.prev = pdf.pos()
    pdf.classic(b"/Root 1 0 R")
    R.add("h_prev_self_loop", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="trailer /Prev points at its own xref section", probe="must not hang")

    # ---- encryption in an OLD revision -----------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(3)
    emit(pdf, objs, streams)
    pdf.obj(30, b"<< /Filter /Standard /V 1 /R 2 /O <%s> /U <%s> /P -4 >>" % (b"00" * 32, b"00" * 32))
    pdf.classic(b"/Root 1 0 R /Encrypt 30 0 R /ID [<01> <01>]")
    pdf.obj(2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>")
    pdf.classic(b"/Root 1 0 R /ID [<01> <02>]")
    R.add("h_encrypt_old_revision", pdf.bytes(), toc_basic(3), refuse=True, encrypted=True,
          desc="/Encrypt only in the OLDER revision's trailer", probe="contract rule 4: refuse")

    # ---- mixed chains --------------------------------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(4)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    pdf.stream(20, b"", content(4))
    pdf.obj(19, page(2, 20, 3))
    pdf.obj(2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R 10 0 R 19 0 R] /Count 5 >>")
    pdf.xrefstream(21, b"/Root 1 0 R", predictor=12, include0=False)
    R.add("h_mixed_classic_then_stream", pdf.bytes(), T5, pages=5, xref="stream", revisions=2, reapply=T5b,
          desc="rev1 classic table, rev2 xref stream adding page 5")

    pdf = PDF()
    objs, streams = std_parts(4)
    for num in sorted(streams):
        pdf.stream(num, b"", streams[num][2])
    pdf.objstm(20, [(k, objs[k][1]) for k in sorted(objs)])
    pdf.xrefstream(21, b"/Root 1 0 R", predictor=12)
    pdf.stream(23, b"", content(4))
    pdf.obj(22, page(2, 23, 3))
    pdf.obj(2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R 10 0 R 22 0 R] /Count 5 >>")
    pdf.classic(b"/Root 1 0 R")
    R.add("h_mixed_stream_then_classic", pdf.bytes(), T5, pages=5, xref="classic", revisions=2, reapply=T5b,
          desc="rev1 xref stream + ObjStm (catalog compressed), rev2 plain classic table (not hybrid) adding page 5",
          probe="update must be classic and keep the compressed catalog superseded")

    # ---- object streams ---------------------------------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(6)
    for num in sorted(streams):
        pdf.stream(num, b"", streams[num][2])
    keys = sorted(objs)
    pdf.objstm(30, [(k, objs[k][1]) for k in keys[:4]])
    pdf.objstm(31, [(k, objs[k][1]) for k in keys[4:]], extends=30)
    pdf.xrefstream(32, b"/Root 1 0 R", predictor=12)
    R.add("h_objstm_extends", pdf.bytes(), toc_basic(6), pages=6, xref="stream", revisions=1,
          desc="two object streams, the second /Extends the first")

    pdf = objstm_doc(5, objstm_filter="lzw", predictor=12)
    R.add("h_objstm_lzw", pdf.bytes(), T5, pages=5, xref="stream", revisions=1,
          desc="catalog + page tree in an ObjStm compressed with LZWDecode (valid PDF 1.5)",
          probe="valid file; a refusal is a wrong refusal (LZW unsupported)")

    pdf = objstm_doc(5, predictor=12)
    data = pdf.bytes()
    i = data.rfind(b"/Length ")
    j = data.index(b" >>", i)
    L = int(data[i + 8:j])
    data = data[:i] + (b"/Length %d" % (L + 7)).ljust(j - i) + data[j:]
    R.add("h_xrefstm_bad_length", data, T5, pages=5, xref="stream", revisions=1,
          desc="xref stream /Length 7 bytes too long (reaches into 'endstream')", probe="tolerate like readers do")

    # ---- crash candidates -----------------------------------------------------------------------------------
    # xref stream with an 8-byte offset field = Int64.max for an unused object, in a junk-prefixed file
    for pre, nm in ((b"JUNKJUNKJUNKJUNK\n", "h_int64max_offset_junkprefix"), (b"", "h_int64max_offset")):
        pdf = PDF(prefix=pre)
        objs, streams = std_parts(5)
        emit(pdf, objs, streams)
        pdf.rev[50] = (1, 0x7FFFFFFFFFFFFFFF, 0)
        pdf.xrefstream(51, b"/Root 1 0 R", W=(1, 8, 1))
        R.add(nm, pdf.bytes(), T5, pages=5, xref="stream", revisions=1,
              desc=f"xref stream W [1 8 1]; unused object 50 has offset 0x7FFFFFFFFFFFFFFF"
                   f"{'; 17 junk bytes before %PDF- (header-relative offsets)' if pre else ''}",
              probe="must not crash (Int overflow in offset + base)")

    # deep recursion: ObjStm k's /DecodeParms lives in ObjStm k+1
    depth = 20000
    pdf = PDF()
    objs, streams = std_parts(3)
    for num in sorted(streams):
        pdf.stream(num, b"", streams[num][2])
    base_s, base_p = 1000, 100000
    # stream k (k=0..depth-1) = object base_s+k, holds object base_p+k-1 (the parms of stream k-1)
    # catalog etc. go into stream 0; stream k has /DecodeParms base_p+k 0 R which lives in stream k+1
    for k in range(depth):
        if k == 0:
            members = [(n, objs[n][1]) for n in sorted(objs)]
        else:
            members = [(base_p + k - 1, b"<< >>")]
        offs, parts, o = [], [], 0
        for _, b in members:
            offs.append(o)
            parts.append(b)
            o += len(b) + 1
        header = (" ".join(f"{n} {of}" for (n, _), of in zip(members, offs)) + "\n").encode()
        raw = header + b"\n".join(parts) + b"\n"
        parms = b" /Filter /FlateDecode /DecodeParms %d 0 R" % (base_p + k) if k + 1 < depth else b""
        dataz = zlib.compress(raw) if k + 1 < depth else raw
        pdf.stream(base_s + k, b"/Type /ObjStm /N %d /First %d%s" % (len(members), len(header), parms), dataz)
        for i, (n, _) in enumerate(members):
            pdf.rev[n] = (2, base_s + k, i)
    pdf.xrefstream(base_s + depth + 5, b"/Root 1 0 R", W=(1, 4, 2))
    R.add("h_deep_decodeparms_chain", pdf.bytes(), toc_basic(3), pages=3, xref="stream", revisions=1,
          desc=f"{depth} object streams: ObjStm k's /DecodeParms is an object compressed in ObjStm k+1 "
               f"(catalog lives in ObjStm 0)",
          probe="must not crash (unbounded recursion resolve -> objectStream -> filterChain -> resolve)")

    # ---- misc syntax ---------------------------------------------------------------------------------------------
    pdf = PDF()
    objs, streams = std_parts(5)
    emit(pdf, objs, streams, before_each=b"\x00\x00\x00 \x0c\t")
    pdf.raw(b"\x00" * 8)
    pdf.classic(b"/Root 1 0 R")
    R.add("h_nul_padding", pdf.bytes(), T5, pages=5, xref="classic", revisions=1,
          desc="NULs, form feeds and tabs between objects and before 'xref'")

    tight = bytearray(b"%PDF-1.4\n")
    offs = {}

    def put(n, b):
        offs[n] = len(tight)
        tight.extend(b)
    put(1, b"1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj ")
    put(2, b"2 0 obj<</Type/Pages/Kids[4 0 R 6 0 R 8 0 R]/Count 3/MediaBox[0 0 612 792]/Resources<</Font<</F1 3 0 R>>>>>>endobj\n")
    put(3, b"3 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\r")
    for i, p in enumerate((4, 6, 8)):
        c = content(i)
        put(p, b"%d 0 obj<</Type/Page/Parent 2 0 R/Contents %d 0 R>>endobj" % (p, p + 1))
        put(p + 1, b"%d 0 obj<</Length %d>>stream\r\n" % (p + 1, len(c)) + c + b"endstream endobj\n")
    x = len(tight)
    tight += b"xref\n0 10\n0000000000 65535 f\r\n" + b"".join(b"%010d 00000 n\r\n" % offs[n] for n in range(1, 10))
    tight += b"trailer<</Size 10/Root 1 0 R>>startxref\n%d\n%%%%EOF" % x
    R.add("h_tight_syntax", bytes(tight), toc_basic(3), pages=3, xref="classic", revisions=1,
          desc="no whitespace around delimiters ('obj<<', '>>endobj', 'endstream' glued to data, 'trailer<<')")

    # in-use entries with offset 0 in the NEWER revision shadowing a real older definition
    pdf = PDF()
    objs, streams = std_parts(4)
    emit(pdf, objs, streams)
    pdf.classic(b"/Root 1 0 R")
    pdf.obj(2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R 10 0 R] /Count 4 >>")
    pdf.rev[6] = (1, 0, 0)  # 'Quartz-style' in-use offset 0 for page 2 in the newest section
    pdf.classic(b"/Root 1 0 R")
    R.add("h_offset0_shadow", pdf.bytes(), toc_basic(4), pages=4, xref="classic", revisions=2,
          desc="newest xref marks page object 6 in-use at offset 0; the older section has the real offset",
          probe="mulu ignores offset-0 entries so the old definition shines through; readers may treat 6 as null")

    pdf = simple_classic(5)
    data = pdf.bytes().replace(b"<< /Size 14 ", b"<< /Size 9000000 ")
    assert b"/Size 9000000" in data
    # the trailer grew by 5 bytes: recompute startxref (it is after the trailer, offsets unchanged)
    R.add("h_huge_size", data, T5, pages=5, xref="classic", revisions=1,
          desc="trailer /Size 9000000 (only 15 objects exist)",
          probe="new object numbers >= /Size exceed the 8,388,607 Annex-C limit; refusal is defensible")


def linearized(n: int) -> bytes:
    import pikepdf
    src = simple_classic(n).bytes()
    pdf = pikepdf.open(io.BytesIO(src))
    buf = io.BytesIO()
    pdf.save(buf, linearize=True)
    return buf.getvalue()


def main():
    GEN.mkdir(parents=True, exist_ok=True)
    for p in GEN.iterdir():
        p.unlink()
    R = Registry(GEN)
    build_all(R)
    R.save()
    print(f"wrote {len(R.manifest['fixtures'])} fixtures to {GEN}")


if __name__ == "__main__":
    main()
