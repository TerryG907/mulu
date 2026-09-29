"""
pdfbuild.py -- a tiny byte-exact PDF assembler for hostile fixtures.

Everything is written by hand so that line endings, xref layout, offsets, object
streams, predictors etc. are exactly what a fixture wants to exercise.
"""
from __future__ import annotations

import json
import zlib
from pathlib import Path


def runs(nums):
    out = []
    for n in nums:
        if out and out[-1][0] + out[-1][1] == n:
            out[-1][1] += 1
        else:
            out.append([n, 1])
    return out


def png_encode(data: bytes, rowlen: int, filt, bpp: int = 1) -> bytes:
    out = bytearray()
    prev = bytes(rowlen)
    for r in range(0, len(data), rowlen):
        row = data[r:r + rowlen]
        ft = filt(r // rowlen) if callable(filt) else filt
        out.append(ft)
        for x in range(rowlen):
            a = row[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if ft == 0:
                pred = 0
            elif ft == 1:
                pred = a
            elif ft == 2:
                pred = b
            elif ft == 3:
                pred = (a + b) >> 1
            else:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            out.append((row[x] - pred) & 0xFF)
        prev = row
    return bytes(out)


def tiff_encode(data: bytes, rowlen: int, colors: int = 1) -> bytes:
    out = bytearray(data)
    for r in range(0, len(data), rowlen):
        for x in range(min(r + rowlen, len(data)) - 1, r + colors - 1, -1):
            out[x] = (data[x] - data[x - colors]) & 0xFF
    return bytes(out)


def lzw_encode(data: bytes, early_change: int = 1) -> bytes:
    """LZWDecode encoder (PDF flavour: 9..12-bit codes, MSB first, EarlyChange=1)."""
    CLEAR, EOD = 256, 257
    out_bits = []

    def emit(code, width):
        out_bits.append((code, width))

    table = {bytes([i]): i for i in range(256)}
    next_code = 258
    width = 9
    emit(CLEAR, width)
    w = b""
    for ch in data:
        wc = w + bytes([ch])
        if wc in table:
            w = wc
            continue
        emit(table[w], width)
        table[wc] = next_code
        next_code += 1
        if next_code + early_change > (1 << width):
            if width < 12:
                width += 1
            else:
                emit(CLEAR, width)
                table = {bytes([i]): i for i in range(256)}
                next_code = 258
                width = 9
        w = bytes([ch])
    if w:
        emit(table[w], width)
        # the decoder adds one more table entry when it reads this last code
        next_code += 1
        if next_code + early_change > (1 << width) and width < 12:
            width += 1
    emit(EOD, width)
    acc = 0
    nbits = 0
    out = bytearray()
    for code, wd in out_bits:
        acc = (acc << wd) | code
        nbits += wd
        while nbits >= 8:
            nbits -= 8
            out.append((acc >> nbits) & 0xFF)
    if nbits:
        out.append((acc << (8 - nbits)) & 0xFF)
    return bytes(out)


def content(i: int, label: str = "Page") -> bytes:
    return (f"q 0.8 g {50 + 17 * (i % 20)} {100 + 23 * (i % 17)} 150 80 re f Q "
            f"BT /F1 36 Tf 72 700 Td ({label} {i + 1}) Tj ET").encode()


class PDF:
    """Append-only PDF assembler. Offsets are recorded relative to `hdr` (0 = absolute)."""

    def __init__(self, version=b"1.7", eol=b"\n", prefix=b"", rel_to_header=True, binary=True,
                 stream_eol=None, entry_eol=None):
        self.eol = eol
        self.stream_eol = stream_eol if stream_eol is not None else (b"\r\n" if eol == b"\r" else eol)
        if entry_eol is None:
            entry_eol = {b"\r\n": b"\r\n", b"\r": b" \r"}.get(eol, b" \n")
        self.entry_eol = entry_eol
        self.buf = bytearray(prefix)
        self.hdr = len(prefix) if rel_to_header else 0
        self.buf += b"%PDF-" + version + eol
        if binary:
            self.buf += b"%\xe2\xe3\xcf\xd3" + eol
        self.rev: dict[int, tuple[int, int, int]] = {}
        self.all: dict[int, tuple[int, int, int]] = {}
        self.prev: int | None = None
        self.revisions = 0

    # -- objects ------------------------------------------------------------------
    def pos(self) -> int:
        return len(self.buf) - self.hdr

    def raw(self, b: bytes):
        self.buf += b

    def obj(self, num: int, body: bytes, gen: int = 0):
        e = self.eol
        self.rev[num] = (1, self.pos(), gen)
        self.buf += b"%d %d obj" % (num, gen) + e + body + e + b"endobj" + e

    def stream(self, num: int, inner: bytes, data: bytes, gen: int = 0, length: bytes | None = None):
        e = self.eol
        L = length if length is not None else b"%d" % len(data)
        self.rev[num] = (1, self.pos(), gen)
        self.buf += (b"%d %d obj" % (num, gen) + e + b"<< " + inner + b" /Length " + L + b" >>" + e
                     + b"stream" + self.stream_eol + data + e + b"endstream" + e + b"endobj" + e)

    def free(self, num: int, next_free: int, gen: int):
        self.rev[num] = (0, next_free, gen)

    def objstm(self, num: int, members: list[tuple[int, bytes]], extends: int | None = None,
               filt: str = "flate", length: bytes | None = None, index_base: int = 0):
        offs, parts, o = [], [], 0
        for _, body in members:
            offs.append(o)
            parts.append(body)
            o += len(body) + 1
        header = (" ".join(f"{n} {off}" for (n, _), off in zip(members, offs)) + "\n").encode()
        data = header + b"\n".join(parts) + b"\n"
        inner = b"/Type /ObjStm /N %d /First %d" % (len(members), len(header))
        if extends is not None:
            inner += b" /Extends %d 0 R" % extends
        if filt == "flate":
            data = zlib.compress(data)
            inner += b" /Filter /FlateDecode"
        elif filt == "lzw":
            data = lzw_encode(data)
            inner += b" /Filter /LZWDecode"
        elif filt == "none":
            pass
        self.stream(num, inner, data, length=length)
        for i, (n, _) in enumerate(members):
            self.rev[n] = (2, num, index_base + i)

    # -- cross-reference sections ----------------------------------------------------
    def _commit(self, xoff: int):
        self.all.update(self.rev)
        self.rev = {}
        self.prev = xoff
        self.revisions += 1

    def default_tail(self, xoff: int) -> bytes:
        e = self.eol
        return b"startxref" + e + b"%d" % xoff + e + b"%%EOF" + e

    def classic(self, trailer_inner: bytes = b"", include0=True, size=None, tail=None, first_one_bug=False,
                prev=True, rows_override=None) -> int:
        e = self.eol
        rows = dict(self.rev) if rows_override is None else rows_override
        if include0 and 0 not in rows:
            rows[0] = (0, 0, 65535)
        xoff = self.pos()
        self.buf += b"xref" + e
        for start, count in runs(sorted(rows)):
            hdr_start = start
            if first_one_bug and start == 0:
                hdr_start = 1
            self.buf += b"%d %d" % (hdr_start, count) + e
            for n in range(start, start + count):
                t, f2, f3 = rows[n]
                assert t in (0, 1), "classic xref cannot hold compressed entries"
                self.buf += b"%010d %05d %s" % (f2, f3, b"n" if t == 1 else b"f") + self.entry_eol
        if size is None:
            size = max(set(self.all) | set(rows)) + 1
        pv = b" /Prev %d" % self.prev if (prev and self.prev is not None) else b""
        self.buf += b"trailer" + e + b"<< /Size %d%s %s >>" % (size, pv, trailer_inner) + e
        self.buf += tail(xoff) if tail else self.default_tail(xoff)
        self._commit(xoff)
        return xoff

    def xrefstream(self, num: int, trailer_inner: bytes = b"", W=(1, 4, 2), predictor=None, colors=1,
                   rowfilt=lambda r: 2, flate=True, size=None, include0=True, length=None, tail=None,
                   index=None, extra_filters=None, prev=True) -> int:
        rows = dict(self.rev)
        xoff = self.pos()
        rows[num] = (1, xoff, 0)
        if include0 and 0 not in rows:
            rows[0] = (0, 0, 65535)
        nums = sorted(rows)
        data = bytearray()
        for n in nums:
            t, f2, f3 = rows[n]
            if t == 0 and W[2]:
                f3 = min(f3, 256 ** W[2] - 1)  # free-entry gen 65535 does not fit a 1-byte field
            if W[0]:
                data += t.to_bytes(W[0], "big")
            else:
                assert t == 1
            data += f2.to_bytes(W[1], "big")
            if W[2]:
                data += f3.to_bytes(W[2], "big")
            else:
                assert f3 == 0, (n, rows[n])
        data = bytes(data)
        rowlen = sum(W)
        inner = b"/Type /XRef /W [%d %d %d]" % W
        idx = index if index is not None else [x for r in runs(nums) for x in r]
        inner += b" /Index [" + b" ".join(b"%d" % x for x in idx) + b"]"
        if size is None:
            size = max(set(self.all) | set(rows)) + 1
        inner += b" /Size %d" % size
        if prev and self.prev is not None:
            inner += b" /Prev %d" % self.prev
        parms = None
        if predictor in (10, 11, 12, 13, 14, 15):
            bpp = colors
            cols = rowlen // colors
            assert cols * colors == rowlen
            data = png_encode(data, rowlen, rowfilt, bpp)
            parms = b"<< /Predictor %d /Columns %d%s >>" % (predictor, cols, b" /Colors %d" % colors if colors != 1 else b"")
        elif predictor == 2:
            cols = rowlen // colors
            data = tiff_encode(data, rowlen, colors)
            parms = b"<< /Predictor 2 /Columns %d%s >>" % (cols, b" /Colors %d" % colors if colors != 1 else b"")
        if flate:
            data = zlib.compress(data)
            if extra_filters == "ahx":
                data = data.hex().upper().encode() + b">"
                inner += b" /Filter [/ASCIIHexDecode /FlateDecode]"
                if parms:
                    inner += b" /DecodeParms [null " + parms + b"]"
            else:
                inner += b" /Filter /FlateDecode"
                if parms:
                    inner += b" /DecodeParms " + parms
        else:
            assert parms is None
        inner += b" " + trailer_inner
        self.stream(num, inner, data, length=length)
        self.buf += tail(xoff) if tail else self.default_tail(xoff)
        self._commit(xoff)
        return xoff

    def bytes(self) -> bytes:
        return bytes(self.buf)


# ---------------------------------------------------------------------------------
# standard document parts
# ---------------------------------------------------------------------------------

FONT = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"


def page(parent: int, contents: int, font: int, pgen: int = 0, extra: bytes = b"", mediabox=True) -> bytes:
    mb = b" /MediaBox [0 0 612 792]" if mediabox else b""
    return (b"<< /Type /Page /Parent %d %d R%s /Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R%s >>"
            % (parent, pgen, mb, font, contents, extra))


# ---------------------------------------------------------------------------------
# TOC helpers
# ---------------------------------------------------------------------------------

def toc_basic(n_pages: int, tag: str = "") -> list[tuple[int, str, int]]:
    """(level, title, printed page) spread over n pages."""
    last = n_pages
    mid = max(1, (n_pages + 1) // 2)
    t = [
        (0, f"{tag}Chapter 1 Introduction", 1),
        (1, f"{tag}1.1 Scope", 1),
        (1, f"{tag}1.2 Terms", min(2, last)),
        (0, f"{tag}Chapter 2 Methods", mid),
        (1, f"{tag}2.1 Setup", mid),
        (2, f"{tag}2.1.1 Hardware", min(mid + 1, last)),
        (0, f"{tag}Appendix", last),
    ]
    return t


def toc_text(entries, indent="\t", eol="\n") -> bytes:
    lines = ["# generated by tools/adversarial/hostile-inputs/make_hostile.py"]
    for lvl, title, pg in entries:
        lines.append(indent * lvl + f"{title} {pg}")
    return (eol.join(lines) + eol).encode("utf-8")


def expected(entries, offset=0):
    return [{"title": t, "level": l, "page_index": p - 1 + offset} for l, t, p in entries]


class Registry:
    def __init__(self, out: Path):
        self.out = out
        self.manifest = {"fixtures": {}}

    def add(self, name: str, data: bytes, toc: bytes | list, *, exp=None, refuse=False, offset=0, pages=None,
            xref=None, revisions=None, has_outline=False, reapply=None, desc="", probe="", notes="",
            revisions_ambiguous=False, encrypted=False):
        """Write <name>.pdf + sidecars and register in the manifest."""
        o = self.out
        (o / f"{name}.pdf").write_bytes(data)
        if isinstance(toc, list):
            if exp is None:
                exp = expected(toc, offset)
            toc = toc_text(toc)
        (o / f"{name}.toc.txt").write_bytes(toc)
        (o / f"{name}.expected.json").write_text(json.dumps(exp or [], ensure_ascii=False, indent=1), encoding="utf-8")
        if offset:
            (o / f"{name}.offset").write_text(str(offset))
        if refuse:
            (o / f"{name}.expect").write_text("refuse\n")
        if reapply:
            (o / f"{name}.reapply.toc.txt").write_bytes(toc_text(reapply))
            (o / f"{name}.reapply.expected.json").write_text(
                json.dumps(expected(reapply, offset), ensure_ascii=False, indent=1), encoding="utf-8")
        facts = {"size": len(data), "encrypted": encrypted, "linearized": False, "has_outline": has_outline}
        if pages is not None:
            facts["pages"] = pages
        if xref:
            facts["xref"] = xref
        if revisions:
            facts["revisions"] = revisions
        self.manifest["fixtures"][name] = {
            "name": name, "status": "ok", "expect": "refuse" if refuse else "apply", "offset": offset,
            "reapply": bool(reapply), "perf_limit_ms": None, "notes": notes, "description": desc,
            "probe": probe, "revisions_ambiguous": revisions_ambiguous or not revisions,
            "allow_input_warnings": True, "facts": facts,
        }

    def save(self):
        (self.out / "manifest.json").write_text(json.dumps(self.manifest, ensure_ascii=False, indent=1),
                                               encoding="utf-8")
