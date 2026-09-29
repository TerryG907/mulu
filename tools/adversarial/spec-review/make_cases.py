# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pikepdf>=9",
# ]
# ///
"""
make_cases.py -- spec-review adversarial fixtures for mulu (hand-built raw PDFs).

    uv run --python 3.12 tools/adversarial/spec-review/make_cases.py

Writes tools/adversarial/spec-review/gen/<name>.{pdf,toc.txt,expected.json[,expect]} and a
manifest.json in the format tools/verify/verify.py run-all understands, so the regular harness
(5 readers + spec/struct/check/info columns) can be pointed at them with --gen/--out.
"""
from __future__ import annotations

import json
import zlib
from pathlib import Path

import pikepdf

HERE = Path(__file__).resolve().parent
GEN = HERE / "gen"


# ---------------------------------------------------------------------------
# a tiny raw PDF writer
# ---------------------------------------------------------------------------

class Doc:
    """Appends objects to a byte buffer and remembers their offsets (relative to buffer start)."""

    def __init__(self, header=b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n", eol=b"\n"):
        self.b = bytearray(header)
        self.eol = eol
        self.off: dict[int, tuple[int, int]] = {}

    def obj(self, num, body: bytes, gen=0):
        self.off[num] = (len(self.b), gen)
        e = self.eol
        self.b += f"{num} {gen} obj".encode() + e + body + e + b"endobj" + e
        return len(self.b)

    def stream(self, num, dict_inner: bytes, data: bytes, gen=0):
        self.off[num] = (len(self.b), gen)
        e = self.eol
        self.b += (f"{num} {gen} obj".encode() + e + b"<< " + dict_inner + f" /Length {len(data)} >>".encode()
                   + e + b"stream" + (b"\r\n" if e == b"\r\n" else b"\n") + data + e + b"endstream" + e
                   + b"endobj" + e)

    def raw(self, data: bytes):
        self.b += data

    def classic_xref(self, rows: dict, trailer: bytes, entry_eol=b" \n"):
        """rows: num -> ('n', off, gen) | ('f', next, gen). Returns offset of 'xref'."""
        e = self.eol
        at = len(self.b)
        self.b += b"xref" + e
        nums = sorted(rows)
        runs = []
        for n in nums:
            if runs and runs[-1][0] + runs[-1][1] == n:
                runs[-1][1] += 1
            else:
                runs.append([n, 1])
        for start, count in runs:
            self.b += f"{start} {count}".encode() + e
            for n in range(start, start + count):
                t, f2, f3 = rows[n]
                self.b += f"{f2:010d} {f3:05d} {t}".encode() + entry_eol
        self.b += b"trailer" + e + trailer + e
        return at

    def startxref(self, off):
        e = self.eol
        self.b += b"startxref" + e + str(off).encode() + e + b"%%EOF" + e

    def xref_stream(self, num, rows: dict, extra: bytes, W=(1, 2, 2), index=None, compress=True,
                    predictor_columns=None, size=None):
        """rows: num -> (type, f2, f3). The stream's own entry is added automatically."""
        at = len(self.b)
        rows = dict(rows)
        rows[num] = (1, at, 0)
        nums = sorted(rows)
        if index is None:
            runs = []
            for n in nums:
                if runs and runs[-1][0] + runs[-1][1] == n:
                    runs[-1][1] += 1
                else:
                    runs.append([n, 1])
            index = [x for r in runs for x in r]
        data = bytearray()
        covered = []
        for j in range(0, len(index), 2):
            covered += list(range(index[j], index[j] + index[j + 1]))
        for n in covered:
            t, f2, f3 = rows.get(n, (0, 0, 0))
            for width, v in zip(W, (t, f2, f3)):
                data += v.to_bytes(width, "big") if width else b""
        size = size if size is not None else max(nums) + 1
        d = f"/Type /XRef /Size {size} /W [{W[0]} {W[1]} {W[2]}] /Index [{' '.join(map(str, index))}] ".encode() + extra
        if predictor_columns:
            rec = sum(W)
            pd = bytearray()
            prev = bytes(rec)
            for k in range(0, len(data), rec):
                row = data[k:k + rec]
                pd += b"\x02" + bytes((row[i] - prev[i]) & 0xFF for i in range(rec))
                prev = row
            data = pd
            d += f" /DecodeParms << /Columns {rec} /Predictor 12 >>".encode()
        if compress:
            data = zlib.compress(bytes(data))
            d += b" /Filter /FlateDecode"
        self.stream(num, d, bytes(data))
        return at

    def bytes(self):
        return bytes(self.b)


def content(i):
    return f"BT /F1 24 Tf 72 700 Td (Spec review page {i}) Tj ET".encode()


def objstm(pairs: list[tuple[int, bytes]], extra=b""):
    """(num, body) list -> (dict_inner, data) of an object stream."""
    header = b""
    body = b""
    for num, b in pairs:
        header += f"{num} {len(body)} ".encode()
        body += b + b"\n"
    first = len(header)
    data = zlib.compress(header + body)
    return f"/Type /ObjStm /N {len(pairs)} /First {first} /Filter /FlateDecode ".encode() + extra, data


TOC3 = [("Chapter One", 0, 1), ("Section 1.1", 1, 2), ("Chapter Two", 0, 3)]


def toc_files(items, offset=0):
    toc = "".join("\t" * lvl + f"{t}\t{p}\n" for t, lvl, p in items)
    exp = [{"title": t, "level": lvl, "page_index": p - 1 + offset} for t, lvl, p in items]
    return toc, exp


def std_objects(d: Doc, npages=3, catalog_extra=b"", first=1, page_gen=0):
    """1 catalog, 2 pages, 3 font, 4.. page/content pairs. Returns rows for a classic table."""
    kids = " ".join(f"{4 + 2 * i} {page_gen} R" for i in range(npages))
    d.obj(first, b"<< /Type /Catalog /Pages 2 0 R " + catalog_extra + b">>")
    d.obj(2, f"<< /Type /Pages /Kids [{kids}] /Count {npages} >>".encode())
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(npages):
        d.obj(4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                         f"/Contents {5 + 2 * i} 0 R >>".encode(), gen=page_gen)
        d.stream(5 + 2 * i, b"", content(i + 1))
    return 4 + 2 * npages  # next free number


def rows_of(d: Doc, extra_free=()):
    rows = {0: ("f", 0, 65535)}
    for n, (o, g) in d.off.items():
        rows[n] = ("n", o, g)
    for n in extra_free:
        rows[n] = ("f", 0, 1)
    return rows


# ---------------------------------------------------------------------------
# cases
# ---------------------------------------------------------------------------

CASES = {}


def case(name, **meta):
    def deco(fn):
        CASES[name] = (fn, meta)
        return fn
    return deco


def classic_simple(eol=b"\n", catalog_extra=b"", trailer_extra=b"", npages=3):
    d = Doc(eol=eol)
    size = std_objects(d, npages, catalog_extra)
    x = d.classic_xref(rows_of(d), f"<< /Size {size} /Root 1 0 R ".encode() + trailer_extra + b">>",
                       entry_eol=b"\r\n" if eol == b"\r\n" else b" \n")
    d.startxref(x)
    return d.bytes()


def stream_simple(npages=3, trailer_extra=b""):
    d = Doc()
    size = std_objects(d, npages)
    rows = {n: (1, o, g) for n, (o, g) in d.off.items()}
    rows[0] = (0, 0, 65535)
    x = d.xref_stream(size, rows, b"/Root 1 0 R " + trailer_extra, predictor_columns=True)
    d.startxref(x)
    return d.bytes()


# --- junk before %PDF- with header-relative offsets (the convention qpdf/pdf.js/PDFium assume) ---

@case("sr_junk1_rel_classic", notes="1 byte (LF) before %PDF-, offsets relative to the header", xref="classic")
def _():
    return b"\n" + classic_simple(), *toc_files(TOC3)


@case("sr_junk1_rel_stream", notes="1 byte (space) before %PDF-, xref stream, offsets relative to the header",
      xref="stream")
def _():
    return b" " + stream_simple(), *toc_files(TOC3)


@case("sr_junk2_rel_crlf", notes="CRLF file with CRLF before %PDF-, offsets relative to the header", xref="classic")
def _():
    return b"\r\n" + classic_simple(eol=b"\r\n"), *toc_files(TOC3)


@case("sr_junk8_rel_classic", notes="control: 8 junk bytes before %PDF-, offsets relative (mulu retries base)",
      xref="classic")
def _():
    return b"GARBAGE\n" + classic_simple(), *toc_files(TOC3)


# --- Word-style hybrid: base table marks compressed objects free, empty 'xref 0 0' update with /XRefStm ---

@case("sr_word_hybrid", notes="Word-style hybrid: pages in ObjStm, base table lists them as free, "
                              "update is 'xref 0 0' + /XRefStm", xref="hybrid")
def _():
    d = Doc(header=b"%PDF-1.5\n%\xb5\xb5\xb5\xb5\n")
    npages = 3
    # 1 catalog (plain), 2 pages (compressed), 3 font (plain), 4/6/8 pages (compressed), 5/7/9 contents (plain)
    d.obj(1, b"<< /Type /Catalog /Pages 2 0 R /Lang (en-US) >>")
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(npages):
        d.stream(5 + 2 * i, b"", content(i + 1))
    pairs = [(2, f"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count {npages} >>".encode())]
    for i in range(npages):
        pairs.append((4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font "
                                 f"<< /F1 3 0 R >> >> /Contents {5 + 2 * i} 0 R >>".encode()))
    di, data = objstm(pairs)
    d.stream(10, di, data)
    size = 12
    # base classic table: every number listed; compressed ones (2,4,6,8) and 11 are free (Word style)
    rows = {0: ("f", 2, 65535)}
    for n in range(1, size):
        if n in d.off:
            rows[n] = ("n", d.off[n][0], 0)
    freel = [2, 4, 6, 8, 11]
    for k, n in enumerate(freel):
        rows[n] = ("f", freel[k + 1] if k + 1 < len(freel) else 0, 65535)
    x1 = d.classic_xref(rows, f"<< /Size {size} /Root 1 0 R >>".encode())
    d.startxref(x1)
    # hidden xref stream (object 11) with the compressed entries
    xs_rows = {2: (2, 10, 0), 4: (2, 10, 1), 6: (2, 10, 2), 8: (2, 10, 3)}
    xs = d.xref_stream(11, xs_rows, b"", W=(1, 4, 2), size=size)
    # empty update section
    x2 = len(d.b)
    d.raw(b"xref\n0 0\ntrailer\n" + f"<< /Size {size} /Root 1 0 R /Prev {x1} /XRefStm {xs} >>\n".encode())
    d.startxref(x2)
    return d.bytes(), *toc_files(TOC3)


# --- xref stream corner cases (Table 17/18) ---

@case("sr_xrefstm_w0_type_default", notes="xref stream /W [0 2 1]: no type field, every row defaults to type 1",
      xref="stream")
def _():
    d = Doc()
    size = std_objects(d)
    rows = {n: (1, o, g) for n, (o, g) in d.off.items()}
    x = d.xref_stream(size, rows, b"/Root 1 0 R", W=(0, 2, 1), index=[1, size], compress=False)
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


@case("sr_xrefstm_gen_width0", notes="xref stream /W [1 2 0]: generation field omitted (defaults to 0)",
      xref="stream")
def _():
    d = Doc()
    size = std_objects(d)
    rows = {n: (1, o, g) for n, (o, g) in d.off.items()}
    rows[0] = (0, 0, 0)
    x = d.xref_stream(size, rows, b"/Root 1 0 R", W=(1, 2, 0), index=None, predictor_columns=True)
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


@case("sr_xrefstm_sparse_index", notes="sparse object numbers, /Index with gaps, no /Index default",
      xref="stream")
def _():
    d = Doc()
    d.obj(7, b"<< /Type /Catalog /Pages 20 0 R >>")
    d.obj(20, b"<< /Type /Pages /Kids [40 0 R 42 0 R 44 0 R] /Count 3 >>")
    d.obj(30, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(3):
        d.obj(40 + 2 * i, f"<< /Type /Page /Parent 20 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 30 0 R >> >> "
                          f"/Contents {41 + 2 * i} 0 R >>".encode())
        d.stream(41 + 2 * i, b"", content(i + 1))
    rows = {n: (1, o, g) for n, (o, g) in d.off.items()}
    rows[0] = (0, 0, 65535)
    x = d.xref_stream(50, rows, b"/Root 7 0 R", W=(1, 3, 2), predictor_columns=True)
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


@case("sr_objstm_extends", notes="catalog + page tree in an ObjStm that /Extends another ObjStm holding pages",
      xref="stream")
def _():
    d = Doc()
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(3):
        d.stream(5 + 2 * i, b"", content(i + 1))
    pages = [(4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                         f"/Contents {5 + 2 * i} 0 R >>".encode()) for i in range(3)]
    di, data = objstm(pages)
    d.stream(20, di, data)
    di2, data2 = objstm([(1, b"<< /Type /Catalog /Pages 2 0 R >>"),
                         (2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>")], extra=b"/Extends 20 0 R ")
    d.stream(21, di2, data2)
    rows = {n: (1, o, g) for n, (o, g) in d.off.items()}
    rows[0] = (0, 0, 65535)
    rows[1] = (2, 21, 0)
    rows[2] = (2, 21, 1)
    for i in range(3):
        rows[4 + 2 * i] = (2, 20, i)
    x = d.xref_stream(22, rows, b"/Root 1 0 R", predictor_columns=True)
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


@case("sr_stream_then_classic", notes="rev1 xref stream with compressed catalog+pages; rev2 classic update "
                                        "(adds /Info) -> newest is classic, catalog still compressed", xref="classic")
def _():
    d = Doc()
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(3):
        d.stream(5 + 2 * i, b"", content(i + 1))
    pairs = [(1, b"<< /Type /Catalog /Pages 2 0 R >>"),
             (2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>")]
    pairs += [(4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                          f"/Contents {5 + 2 * i} 0 R >>".encode()) for i in range(3)]
    di, data = objstm(pairs)
    d.stream(10, di, data)
    rows = {n: (1, o, g) for n, (o, g) in d.off.items()}
    rows[0] = (0, 0, 65535)
    for k, (n, _) in enumerate(pairs):
        rows[n] = (2, 10, k)
    x1 = d.xref_stream(11, rows, b"/Root 1 0 R", predictor_columns=True)
    d.startxref(x1)
    d.obj(12, b"<< /Producer (rev2 classic) >>")
    x2 = d.classic_xref({12: ("n", d.off[12][0], 0)}, f"<< /Size 13 /Root 1 0 R /Info 12 0 R /Prev {x1} >>".encode())
    d.startxref(x2)
    return d.bytes(), *toc_files(TOC3)


# --- §7.3 syntax in the catalog that must survive re-serialization ---

CAT_SYNTAX = (b"/Lang(en\\-US)%comment inside the dictionary\n"
              b"/My#20Key#2FSlash (paren \\( \\) balanced (nested) octal \\101\\0102 \\\r\ncontinued\rCR)"
              b"/ViewerPreferences<</Direction/L2R/HideToolbar true/PrintScaling/None>>"
              b"/Nums[-.5 +3 4. 0.000001 -0 1 0 R]"
              b"/PieceInfo<</X#41pp<</Private<FEFF 00 41\n00 42>/LastModified(D:20260101000000Z)>>>>"
              b"/Empty/ /Uni#c3#a9 true ")


@case("sr_catalog_syntax", notes="catalog with comments, #xx names, escapes, CR in string, odd reals, "
                                   "no whitespace between tokens", xref="classic")
def _():
    return classic_simple(catalog_extra=CAT_SYNTAX), *toc_files(TOC3)


@case("sr_catalog_syntax_objstm", notes="same odd catalog, stored in an object stream", xref="stream")
def _():
    d = Doc()
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(3):
        d.obj(4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                         f"/Contents {5 + 2 * i} 0 R >>".encode())
        d.stream(5 + 2 * i, b"", content(i + 1))
    pairs = [(1, b"<< /Type /Catalog /Pages 2 0 R " + CAT_SYNTAX + b">>"),
             (2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>")]
    di, data = objstm(pairs)
    d.stream(10, di, data)
    rows = {n: (1, o, g) for n, (o, g) in d.off.items()}
    rows[0] = (0, 0, 65535)
    rows[1] = (2, 10, 0)
    rows[2] = (2, 10, 1)
    x = d.xref_stream(11, rows, b"/Root 1 0 R", predictor_columns=True)
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


# --- generation numbers / free list (§7.5.4) ---

@case("sr_gen_reuse", notes="rev2 frees catalog 1 and page 4; rev3 reuses them as 1 1 obj / 4 1 obj", xref="classic")
def _():
    d = Doc()
    size = std_objects(d)
    x1 = d.classic_xref(rows_of(d), f"<< /Size {size} /Root 1 0 R >>".encode())
    d.startxref(x1)
    # rev2: free 1 and 4 (gen bumped to 1), new catalog 10 0
    d.obj(10, b"<< /Type /Catalog /Pages 2 0 R >>")
    d.obj(2, b"<< /Type /Pages /Kids [6 0 R 8 0 R] /Count 2 >>")
    x2 = d.classic_xref({0: ("f", 1, 65535), 1: ("f", 4, 1), 2: ("n", d.off[2][0], 0), 4: ("f", 0, 1),
                         10: ("n", d.off[10][0], 0)},
                        f"<< /Size 11 /Root 10 0 R /Prev {x1} >>".encode())
    d.startxref(x2)
    # rev3: reuse 1 (gen 1) as catalog, 4 (gen 1) as page; free 10 (gen 1)
    d.obj(1, b"<< /Type /Catalog /Pages 2 0 R /Lang (reused) >>", gen=1)
    d.obj(4, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
             b"/Contents 5 0 R >>", gen=1)
    d.obj(2, b"<< /Type /Pages /Kids [4 1 R 6 0 R 8 0 R] /Count 3 >>")
    x3 = d.classic_xref({0: ("f", 10, 65535), 1: ("n", d.off[1][0], 1), 2: ("n", d.off[2][0], 0),
                         4: ("n", d.off[4][0], 1), 10: ("f", 0, 1)},
                        f"<< /Size 11 /Root 1 1 R /Prev {x2} >>".encode())
    d.startxref(x3)
    return d.bytes(), *toc_files(TOC3)


@case("sr_size_too_small", notes="trailer /Size 5 although the table defines objects up to 9", xref="classic")
def _():
    d = Doc()
    std_objects(d)
    x = d.classic_xref(rows_of(d), b"<< /Size 5 /Root 1 0 R >>")
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


# --- §7.5.6: 'The added trailer shall contain all the entries except the Prev entry ... from the previous trailer' ---

@case("sr_trailer_private_keys", notes="trailer carries /Info, /ID and a private second-class key", xref="classic")
def _():
    d = Doc()
    size = std_objects(d)
    d.obj(size, b"<< /Title (trailer keys) >>")
    x = d.classic_xref(rows_of(d), f"<< /Size {size + 1} /Root 1 0 R /Info {size} 0 R "
                                   f"/ID [<00112233445566778899AABBCCDDEEFF><00112233445566778899AABBCCDDEEFF>] "
                                   f"/ABCD:DocFlags (keep-me) >>".encode())
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


@case("sr_trailer_private_keys_stream", notes="xref-stream trailer with a private second-class key", xref="stream")
def _():
    return stream_simple(trailer_extra=b"/ABCD:DocFlags (keep-me)"), *toc_files(TOC3)


# --- new object numbers start at /Size: a reference that dangled in the original gets captured ---

@case("sr_dangling_ref", notes="page 1 /Annots [10 0 R] where 10 is undefined (/Size 10)", xref="classic")
def _():
    d = Doc()
    d.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    d.obj(2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>")
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(3):
        annots = b" /Annots [10 0 R 11 0 R]" if i == 0 else b""
        d.obj(4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                         f"/Contents {5 + 2 * i} 0 R".encode() + annots + b" >>")
        d.stream(5 + 2 * i, b"", content(i + 1))
    x = d.classic_xref(rows_of(d), b"<< /Size 10 /Root 1 0 R >>")
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


@case("sr_dangling_resources", notes="page 1 /Resources 10 0 R is undefined (null -> inherited from /Pages); "
                                      "mulu's new object 10 captures it", xref="classic")
def _():
    d = Doc()
    d.obj(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    d.obj(2, b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 /Resources << /Font << /F1 3 0 R >> >> >>")
    d.obj(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for i in range(3):
        res = b" /Resources 10 0 R" if i == 0 else b""
        d.obj(4 + 2 * i, f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {5 + 2 * i} 0 R".encode()
              + res + b" >>")
        d.stream(5 + 2 * i, b"", content(i + 1))
    x = d.classic_xref(rows_of(d), b"<< /Size 10 /Root 1 0 R >>")
    d.startxref(x)
    return d.bytes(), *toc_files(TOC3)


# --- encryption in an older / hidden trailer must refuse ---

@case("sr_encrypt_in_hidden_xrefstm", expect="refuse", notes="/Encrypt only in the /XRefStm dictionary", xref="hybrid")
def _():
    d = Doc(header=b"%PDF-1.5\n%\xb5\xb5\xb5\xb5\n")
    size = std_objects(d)
    d.obj(size, b"<< /Filter /Standard /V 1 /R 2 /O <00> /U <00> /P -4 >>")
    xs = d.xref_stream(size + 1, {}, f"/Encrypt {size} 0 R /Root 1 0 R".encode(), size=size + 2)
    rows = rows_of(d)
    del rows[size + 1]
    x = d.classic_xref(rows, f"<< /Size {size + 2} /Root 1 0 R /XRefStm {xs} >>".encode())
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
        facts = {"size": len(pdf), "xref": meta.get("xref"), "encrypted": refuse and "encrypt" in name}
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
        print(f"{name:<34} {len(pdf):>6} B  pages={facts.get('pages')}  qpdf_warn={len(facts.get('qpdf_warnings', []))}"
              f"  {facts.get('open_error', '')}")
    (GEN / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
