"""
pdfraw.py -- a tiny, strict, dependency-free PDF byte-level reader used by the
mulu verification harness (and by the fixture builders).

It is deliberately independent of every production reader (qpdf, PDFium,
pypdf, pdf.js, PDFKit) so that it can check the *bytes* mulu appends instead of
trusting readers that silently repair broken cross-reference data.

Only the subset of PDF syntax needed to inspect an incremental update is
implemented: objects, indirect objects, streams, classic xref tables, xref
streams (Flate + PNG/TIFF predictors) and the trailer.
"""
from __future__ import annotations

import re
import zlib
from dataclasses import dataclass, field

WS = b"\x00\t\n\x0c\r "
DELIM = b"()<>[]{}/%"


class PDFSyntaxError(Exception):
    pass


class Name(str):
    """A PDF name (stored without the leading slash)."""

    def __repr__(self) -> str:  # pragma: no cover - debug helper
        return "/" + str(self)


@dataclass(frozen=True)
class Ref:
    num: int
    gen: int

    def __repr__(self) -> str:  # pragma: no cover
        return f"{self.num} {self.gen} R"


class PDFString(bytes):
    """Raw (decoded-escape) string bytes; `.hex` says how it was written."""

    hex: bool = False

    def __new__(cls, value: bytes, hex: bool = False):
        o = super().__new__(cls, value)
        o.hex = hex
        return o

    def text(self) -> str:
        b = bytes(self)
        if b.startswith(b"\xfe\xff"):
            return b[2:].decode("utf-16-be", errors="replace")
        if b.startswith(b"\xff\xfe"):
            return b[2:].decode("utf-16-le", errors="replace")
        if b.startswith(b"\xef\xbb\xbf"):
            return b[3:].decode("utf-8", errors="replace")
        return b.decode("latin-1")


class Keyword(str):
    pass


@dataclass
class Stream:
    dict: dict
    raw: bytes          # the bytes between "stream<EOL>" and the EOL before "endstream"
    data_start: int     # absolute file offset of the first data byte


@dataclass
class IndirectObject:
    num: int
    gen: int
    value: object
    start: int          # offset of the "N G obj" header
    end: int            # offset just after "endobj"


# --------------------------------------------------------------------------
# Lexer / parser
# --------------------------------------------------------------------------

_NUM_RE = re.compile(rb"[+-]?(?:\d+\.?\d*|\.\d+)")


def skip_ws(data: bytes, pos: int) -> int:
    n = len(data)
    while pos < n:
        c = data[pos]
        if c in WS:
            pos += 1
        elif c == 0x25:  # '%'
            while pos < n and data[pos] not in b"\r\n":
                pos += 1
        else:
            break
    return pos


def _read_regular(data: bytes, pos: int) -> tuple[bytes, int]:
    start = pos
    n = len(data)
    while pos < n and data[pos] not in WS and data[pos] not in DELIM:
        pos += 1
    return data[start:pos], pos


def _parse_literal_string(data: bytes, pos: int) -> tuple[PDFString, int]:
    assert data[pos] == 0x28
    pos += 1
    depth = 1
    out = bytearray()
    n = len(data)
    while pos < n:
        c = data[pos]
        if c == 0x5C:  # backslash
            pos += 1
            if pos >= n:
                break
            e = data[pos]
            simple = {ord("n"): 10, ord("r"): 13, ord("t"): 9, ord("b"): 8, ord("f"): 12,
                      ord("("): 0x28, ord(")"): 0x29, ord("\\"): 0x5C}
            if e in simple:
                out.append(simple[e]); pos += 1
            elif 0x30 <= e <= 0x37:
                j = pos
                while j < n and j < pos + 3 and 0x30 <= data[j] <= 0x37:
                    j += 1
                out.append(int(data[pos:j], 8) & 0xFF); pos = j
            elif e == 0x0D:
                pos += 1
                if pos < n and data[pos] == 0x0A:
                    pos += 1
            elif e == 0x0A:
                pos += 1
            else:
                out.append(e); pos += 1
        elif c == 0x28:
            depth += 1; out.append(c); pos += 1
        elif c == 0x29:
            depth -= 1
            pos += 1
            if depth == 0:
                return PDFString(bytes(out), hex=False), pos
            out.append(c)
        else:
            out.append(c); pos += 1
    raise PDFSyntaxError("unterminated literal string")


def _parse_hex_string(data: bytes, pos: int) -> tuple[PDFString, int]:
    assert data[pos] == 0x3C
    end = data.find(b">", pos)
    if end < 0:
        raise PDFSyntaxError("unterminated hex string")
    hexchars = re.sub(rb"[\x00\t\n\x0c\r ]", b"", data[pos + 1:end])
    if not re.fullmatch(rb"[0-9A-Fa-f]*", hexchars):
        raise PDFSyntaxError(f"bad hex string at {pos}")
    if len(hexchars) % 2:
        hexchars += b"0"
    return PDFString(bytes.fromhex(hexchars.decode()), hex=True), end + 1


def _parse_name(data: bytes, pos: int) -> tuple[Name, int]:
    assert data[pos] == 0x2F
    raw, end = _read_regular(data, pos + 1)
    out = bytearray()
    i = 0
    while i < len(raw):
        if raw[i] == 0x23 and i + 2 < len(raw) + 0 and re.fullmatch(rb"[0-9A-Fa-f]{2}", raw[i + 1:i + 3] or b""):
            out.append(int(raw[i + 1:i + 3], 16)); i += 3
        else:
            out.append(raw[i]); i += 1
    return Name(out.decode("latin-1")), end


def parse_object(data: bytes, pos: int):
    """Parse one direct object (refs 'N G R' included). Returns (obj, newpos)."""
    pos = skip_ws(data, pos)
    if pos >= len(data):
        raise PDFSyntaxError("unexpected EOF")
    c = data[pos]
    if c == 0x3C:  # '<'
        if data[pos:pos + 2] == b"<<":
            pos += 2
            d: dict = {}
            while True:
                pos = skip_ws(data, pos)
                if data[pos:pos + 2] == b">>":
                    return d, pos + 2
                if data[pos] != 0x2F:
                    raise PDFSyntaxError(f"dict key is not a name at {pos}")
                key, pos = _parse_name(data, pos)
                val, pos = parse_object(data, pos)
                d[str(key)] = val
        return _parse_hex_string(data, pos)
    if c == 0x5B:  # '['
        pos += 1
        arr = []
        while True:
            pos = skip_ws(data, pos)
            if pos >= len(data):
                raise PDFSyntaxError("unterminated array")
            if data[pos] == 0x5D:
                return arr, pos + 1
            v, pos = parse_object(data, pos)
            arr.append(v)
    if c == 0x28:
        return _parse_literal_string(data, pos)
    if c == 0x2F:
        return _parse_name(data, pos)
    tok, end = _read_regular(data, pos)
    if not tok:
        raise PDFSyntaxError(f"unexpected byte {data[pos:pos+1]!r} at {pos}")
    if _NUM_RE.fullmatch(tok):
        if b"." in tok:
            return float(tok), end
        num = int(tok)
        # lookahead for "gen R"
        p2 = skip_ws(data, end)
        t2, e2 = _read_regular(data, p2)
        if t2.isdigit():
            p3 = skip_ws(data, e2)
            t3, e3 = _read_regular(data, p3)
            if t3 == b"R":
                return Ref(num, int(t2)), e3
        return num, end
    if tok == b"true":
        return True, end
    if tok == b"false":
        return False, end
    if tok == b"null":
        return None, end
    return Keyword(tok.decode("latin-1")), end


_OBJ_HDR = re.compile(rb"(\d+)[\x00\t\n\x0c\r ]+(\d+)[\x00\t\n\x0c\r ]+obj")


def parse_indirect(data: bytes, pos: int, length_resolver=None, tolerant=False) -> IndirectObject:
    """Parse 'N G obj ... endobj' starting exactly at pos (no leading junk allowed).
    tolerant: a /Length that does not land on 'endstream' falls back to searching for it
    (used only to read a damaged INPUT, never the update)."""
    m = _OBJ_HDR.match(data, pos)
    if not m:
        raise PDFSyntaxError(f"no 'N G obj' header at offset {pos}: {data[pos:pos+24]!r}")
    num, gen = int(m.group(1)), int(m.group(2))
    val, p = parse_object(data, m.end())
    p = skip_ws(data, p)
    if data[p:p + 6] == b"stream":
        if not isinstance(val, dict):
            raise PDFSyntaxError("stream keyword after non-dict")
        p += 6
        if data[p:p + 2] == b"\r\n":
            p += 2
        elif data[p:p + 1] == b"\n":
            p += 1
        elif data[p:p + 1] == b"\r":
            p += 1  # not strictly legal, tolerated
        else:
            raise PDFSyntaxError("stream keyword not followed by EOL")
        length = val.get("Length")
        if isinstance(length, Ref):
            if length_resolver is None:
                raise PDFSyntaxError("indirect /Length with no resolver")
            length = length_resolver(length)
        if not isinstance(length, int) or length < 0:
            raise PDFSyntaxError(f"bad /Length {length!r}")
        raw = data[p:p + length]
        q = p + length
        q2 = skip_ws(data, q)
        if data[q2:q2 + 9] != b"endstream" and tolerant and data.find(b"endstream", p) >= 0:
            q2 = data.find(b"endstream", p)
            q = q2
            while q > p and data[q - 1] in b"\r\n":
                q -= 1
            raw = data[p:q]
        if data[q2:q2 + 9] != b"endstream":
            raise PDFSyntaxError(f"/Length {length} does not land on endstream (obj {num} {gen})")
        val = Stream(val, raw, p)
        p = q2 + 9
    p = skip_ws(data, p)
    if data[p:p + 6] != b"endobj":
        raise PDFSyntaxError(f"missing endobj for {num} {gen} at {p}: {data[p:p+20]!r}")
    return IndirectObject(num, gen, val, pos, p + 6)


# --------------------------------------------------------------------------
# Filters
# --------------------------------------------------------------------------

def png_unpredict(data: bytes, columns: int, colors: int = 1, bpc: int = 8) -> bytes:
    bpp = max(1, (colors * bpc + 7) // 8)
    rowlen = (colors * bpc * columns + 7) // 8
    out = bytearray()
    prev = bytearray(rowlen)
    i = 0
    while i < len(data):
        ft = data[i]
        row = bytearray(data[i + 1:i + 1 + rowlen])
        if len(row) < rowlen:
            row.extend(b"\x00" * (rowlen - len(row)))
        i += 1 + rowlen
        if ft == 0:
            pass
        elif ft == 1:
            for x in range(bpp, rowlen):
                row[x] = (row[x] + row[x - bpp]) & 0xFF
        elif ft == 2:
            for x in range(rowlen):
                row[x] = (row[x] + prev[x]) & 0xFF
        elif ft == 3:
            for x in range(rowlen):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + ((left + prev[x]) >> 1)) & 0xFF
        elif ft == 4:
            for x in range(rowlen):
                a = row[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[x] = (row[x] + pred) & 0xFF
        else:
            raise PDFSyntaxError(f"bad PNG filter type {ft}")
        out += row
        prev = row
    return bytes(out)


def png_predict(data: bytes, columns: int, filters, bpp: int = 1) -> bytes:
    """Encode rows with the PNG filter types given by `filters` (callable row->type or int)."""
    rowlen = columns
    out = bytearray()
    prev = bytes(rowlen)
    for r in range(0, len(data), rowlen):
        row = data[r:r + rowlen]
        ft = filters(r // rowlen) if callable(filters) else filters
        enc = bytearray()
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
            enc.append((row[x] - pred) & 0xFF)
        out.append(ft)
        out += enc
        prev = row
    return bytes(out)


def decode_stream(s: Stream) -> bytes:
    d = s.dict
    filt = d.get("Filter")
    parms = d.get("DecodeParms")
    filters = filt if isinstance(filt, list) else ([filt] if filt else [])
    parmsl = parms if isinstance(parms, list) else [parms] * max(1, len(filters))
    data = s.raw
    for i, f in enumerate(filters):
        if f not in ("FlateDecode", "Fl"):
            raise PDFSyntaxError(f"unsupported filter {f}")
        data = zlib.decompress(data)
        p = parmsl[i] if i < len(parmsl) else None
        if isinstance(p, dict):
            pred = p.get("Predictor", 1)
            cols = p.get("Columns", 1)
            colors = p.get("Colors", 1)
            bpc = p.get("BitsPerComponent", 8)
            if pred >= 10:
                data = png_unpredict(data, cols, colors, bpc)
            elif pred == 2:
                rowlen = cols * colors
                out = bytearray(data)
                for r in range(0, len(out), rowlen):
                    for x in range(r + colors, min(r + rowlen, len(out))):
                        out[x] = (out[x] + out[x - colors]) & 0xFF
                data = bytes(out)
    return data


# --------------------------------------------------------------------------
# Cross-reference sections
# --------------------------------------------------------------------------

@dataclass
class XrefEntry:
    type: int      # 0 free, 1 in use (offset), 2 compressed
    f2: int        # offset / objstm number / next free
    f3: int        # generation / index in objstm


@dataclass
class XrefSection:
    kind: str                      # "classic" | "stream"
    offset: int
    entries: dict = field(default_factory=dict)   # num -> XrefEntry
    trailer: dict = field(default_factory=dict)
    problems: list = field(default_factory=list)  # strict-format issues found while parsing
    stream_obj: IndirectObject | None = None


_ENTRY_RE = re.compile(rb"(\d{10}) (\d{5}) ([nf])( \r| \n|\r\n)")


def last_startxref(data: bytes) -> int:
    i = data.rfind(b"startxref")
    if i < 0:
        raise PDFSyntaxError("no startxref")
    p = skip_ws(data, i + 9)
    tok, _ = _read_regular(data, p)
    if not tok.isdigit():
        raise PDFSyntaxError("startxref not followed by an integer")
    return int(tok)


def parse_xref_section(data: bytes, offset: int, length_resolver=None, tolerant=False) -> XrefSection:
    if offset < 0 or offset >= len(data):
        raise PDFSyntaxError(f"xref offset {offset} outside file")
    if data[offset:offset + 4] == b"xref":
        sec = XrefSection("classic", offset)
        p = offset + 4
        # EOL after 'xref'
        p = skip_ws(data, p)
        while True:
            if data[p:p + 7] == b"trailer":
                break
            m = re.compile(rb"(\d+)[ ]+(\d+)[ \t]*(\r\n|\n|\r)").match(data, p)
            if not m:
                raise PDFSyntaxError(f"bad xref subsection header at {p}: {data[p:p+30]!r}")
            start, count = int(m.group(1)), int(m.group(2))
            p = m.end()
            for k in range(count):
                em = _ENTRY_RE.match(data, p)
                if not em or em.end() - p != 20:
                    sec.problems.append(f"xref entry {start + k} at {p} is not exactly 20 bytes: {data[p:p+20]!r}")
                    em2 = re.compile(rb"(\d+) (\d+) ([nf])[ \r\n]*").match(data, p)
                    if not em2:
                        raise PDFSyntaxError(f"unparseable xref entry at {p}")
                    f2, f3, t = int(em2.group(1)), int(em2.group(2)), em2.group(3)
                    p = em2.end()
                else:
                    f2, f3, t = int(em.group(1)), int(em.group(2)), em.group(3)
                    p = em.end()
                sec.entries[start + k] = XrefEntry(1 if t == b"n" else 0, f2, f3)
            p = skip_ws(data, p)
        tr, _ = parse_object(data, p + 7)
        if not isinstance(tr, dict):
            raise PDFSyntaxError("trailer is not a dictionary")
        sec.trailer = tr
        return sec
    obj = parse_indirect(data, offset, length_resolver, tolerant=tolerant)
    if not isinstance(obj.value, Stream):
        raise PDFSyntaxError(f"object at xref offset {offset} is not a stream")
    d = obj.value.dict
    if d.get("Type") != "XRef":
        raise PDFSyntaxError(f"stream at {offset} is not /Type /XRef")
    raw = decode_stream(obj.value)
    w = d.get("W")
    if not (isinstance(w, list) and len(w) == 3 and all(isinstance(x, int) and x >= 0 for x in w)):
        raise PDFSyntaxError(f"bad /W {w!r}")
    size = d.get("Size")
    index = d.get("Index", [0, size])
    rec = sum(w)
    sec = XrefSection("stream", offset, trailer=d, stream_obj=obj)
    pos = 0
    for j in range(0, len(index), 2):
        start, count = index[j], index[j + 1]
        for k in range(count):
            if pos + rec > len(raw):
                raise PDFSyntaxError("xref stream data too short for /Index")
            fields = []
            q = pos
            for wi in w:
                v = 0
                for _ in range(wi):
                    v = (v << 8) | raw[q]; q += 1
                fields.append(v)
            pos += rec
            t = fields[0] if w[0] else 1
            sec.entries[start + k] = XrefEntry(t, fields[1], fields[2])
    if pos != len(raw):
        sec.problems.append(f"xref stream has {len(raw) - pos} trailing bytes beyond /Index entries")
    return sec


def xref_kind_at(data: bytes, offset: int, tolerant=False) -> str:
    """'classic', 'hybrid' or 'stream' for the section at offset."""
    sec = parse_xref_section(data, offset, tolerant=tolerant)
    if sec.kind == "classic":
        return "hybrid" if "XRefStm" in sec.trailer else "classic"
    return "stream"


def newest_xref_kind(data: bytes) -> str:
    return xref_kind_at(data, last_startxref(data))


def revision_chain(data: bytes) -> list[XrefSection]:
    """Follow startxref -> /Prev. Returns sections newest first (XRefStm not counted)."""
    seen = set()
    out = []
    off = last_startxref(data)
    while off is not None and off not in seen:
        seen.add(off)
        sec = parse_xref_section(data, off)
        out.append(sec)
        prev = sec.trailer.get("Prev")
        off = prev if isinstance(prev, int) else None
    return out


# --------------------------------------------------------------------------
# Serialisation helpers (used by fixture builders)
# --------------------------------------------------------------------------

def pdf_hex_utf16(s: str) -> bytes:
    return b"<FEFF" + s.encode("utf-16-be").hex().upper().encode() + b">"


def serialize(obj) -> bytes:
    if obj is None:
        return b"null"
    if obj is True:
        return b"true"
    if obj is False:
        return b"false"
    if isinstance(obj, Ref):
        return f"{obj.num} {obj.gen} R".encode()
    if isinstance(obj, Name):
        out = bytearray(b"/")
        for ch in str(obj).encode("latin-1"):
            if ch < 0x21 or ch > 0x7E or ch in b"#()<>[]{}/%":
                out += b"#%02X" % ch
            else:
                out.append(ch)
        return bytes(out)
    if isinstance(obj, PDFString):
        return b"<" + bytes(obj).hex().upper().encode() + b">"
    if isinstance(obj, bytes):
        return b"<" + obj.hex().upper().encode() + b">"
    if isinstance(obj, bool):
        return b"true" if obj else b"false"
    if isinstance(obj, int):
        return str(obj).encode()
    if isinstance(obj, float):
        s = f"{obj:.6f}".rstrip("0").rstrip(".")
        return (s or "0").encode()
    if isinstance(obj, list):
        return b"[" + b" ".join(serialize(x) for x in obj) + b"]"
    if isinstance(obj, dict):
        return b"<<" + b"".join(serialize(Name(k)) + b" " + serialize(v) + b" " for k, v in obj.items()) + b">>"
    if isinstance(obj, Keyword):
        return str(obj).encode("latin-1")
    raise TypeError(f"cannot serialize {type(obj)}")


# --------------------------------------------------------------------------
# Offset frames and references (used by the spec check)
# --------------------------------------------------------------------------

def header_offset(data: bytes) -> int:
    """Position of '%PDF-' within the first 1024 bytes (0 if absent)."""
    i = data.find(b"%PDF-", 0, 1024)
    return max(i, 0)


def lands_exactly(data: bytes, p: int) -> bool:
    """True if p is the first byte of an 'xref' keyword or of an 'N G obj' header."""
    if p < 0 or p >= len(data) or data[p] in WS:
        return False
    if p > 0 and data[p - 1] not in WS and data[p - 1] not in DELIM:
        return False  # the middle of a token
    if data.startswith(b"xref", p):
        return p + 4 == len(data) or data[p + 4] in WS or data[p + 4] in DELIM
    return _OBJ_HDR.match(data, p) is not None


def offset_frame(data: bytes) -> int:
    """The frame the file's offsets use: the header position when there is junk before
    '%PDF-' and startxref only lands exactly when read relative to the header (what
    qpdf, PDFium, pdf.js and PDFKit do), else 0 (absolute)."""
    h = header_offset(data)
    if not h:
        return 0
    try:
        sx = last_startxref(data)
    except PDFSyntaxError:
        return 0
    return h if lands_exactly(data, sx + h) and not lands_exactly(data, sx) else 0


def _collect_refs(v, out: set) -> None:
    stack = [v]
    while stack:
        x = stack.pop()
        if isinstance(x, Ref):
            out.add(x.num)
        elif isinstance(x, dict):
            stack.extend(x.values())
        elif isinstance(x, list):
            stack.extend(x)
        elif isinstance(x, Stream):
            stack.extend(x.dict.values())


def referenced_numbers(data: bytes) -> set:
    """Object numbers referred to ('N G R') by any object defined anywhere in the file
    (every revision, found by scanning 'N G obj' headers, objects inside object streams
    included) or by any trailer. A superset of the live references. Objects that do
    not parse are skipped."""
    refs: set = set()

    def resolver(ref):
        m = re.search(rb"(?<![0-9])%d[\x00\t\n\x0c\r ]+%d[\x00\t\n\x0c\r ]+obj" % (ref.num, ref.gen), data)
        if not m:
            raise PDFSyntaxError("indirect /Length not found")
        v, _ = parse_object(data, m.end())
        return v

    skip_until = 0
    for m in _OBJ_HDR.finditer(data):
        p = m.start()
        if p < skip_until or (p > 0 and data[p - 1] not in WS and data[p - 1] not in DELIM):
            continue
        try:
            o = parse_indirect(data, p, resolver)
        except (PDFSyntaxError, RecursionError, ValueError, IndexError):
            continue
        skip_until = o.end
        _collect_refs(o.value, refs)
        if isinstance(o.value, Stream) and o.value.dict.get("Type") == "ObjStm":
            try:
                raw = decode_stream(o.value)
                n, first = int(o.value.dict["N"]), int(o.value.dict["First"])
                head = raw[:first].split()
                for k in range(0, min(len(head), 2 * n), 2):
                    v, _ = parse_object(raw, first + int(head[k + 1]))
                    _collect_refs(v, refs)
            except Exception:  # noqa: BLE001 - hostile object streams
                pass
    for m in re.finditer(rb"trailer[\x00\t\n\x0c\r ]*<<", data):
        try:
            v, _ = parse_object(data, m.end() - 2)
            _collect_refs(v, refs)
        except (PDFSyntaxError, RecursionError, ValueError, IndexError):
            pass
    return refs
