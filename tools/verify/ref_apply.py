# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9"]
# ///
"""
ref_apply.py -- a small REFERENCE incremental-outline writer, used ONLY to validate
the verification harness itself (selftest) while the Swift core is being written.

It implements the same CLI contract as `mulu apply`:
    ref_apply.py apply <in.pdf> <toc.txt> -o <out.pdf> [--offset N]
It uses qpdf (pikepdf) to *read* the object graph, but writes the update bytes
itself exactly as the WRITER REQUIREMENTS describe (never re-serialising the
original). Hidden flag for negative controls: --literal-titles.
"""
from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pdfraw  # noqa: E402

import pikepdf  # noqa: E402


class Refuse(Exception):
    pass


def parse_toc(path: Path, offset: int, npages: int):
    try:
        text = path.read_bytes().decode("utf-8")
    except UnicodeDecodeError as e:
        raise Refuse(f"TOC is not UTF-8: {e}")
    if text.startswith("\ufeff"):
        text = text[1:]
    out = []
    prev = -1
    for lineno, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.startswith("#"):
            continue
        m = re.match(r"^(\t*)( *)", raw)
        level = len(m.group(1)) if m.group(1) else len(m.group(2)) // 2
        body = raw.strip(" \t")
        mm = re.match(r"^(.*?\S)[ \t]+(\S+)$", body)
        if not mm or not mm.group(2).isdigit() or int(mm.group(2)) < 1:
            raise Refuse(f"TOC line {lineno}: expected '<title> <page>'")
        if level > prev + 1:
            raise Refuse(f"TOC line {lineno}: level jumps from {prev} to {level}")
        phys = int(mm.group(2)) + offset
        if not 1 <= phys <= npages:
            raise Refuse(f"TOC line {lineno}: page {phys} out of range 1..{npages}")
        out.append((level, mm.group(1).strip(), phys - 1))
        prev = level
    return out


def lit(b: bytes) -> bytes:
    return b"(" + b.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)").replace(b"\r", b"\\r") + b")"


def apply(inp: Path, toc: Path, outp: Path, offset: int, literal_titles=False):
    if outp.exists() and os.path.samefile(inp, outp) or os.path.realpath(inp) == os.path.realpath(outp):
        raise Refuse("input and output are the same file")
    data = inp.read_bytes()
    try:
        pdf = pikepdf.open(inp)
    except pikepdf.PasswordError:
        raise Refuse("encrypted")
    except Exception as e:  # noqa: BLE001
        raise Refuse(f"cannot parse PDF: {e}")
    if pdf.is_encrypted or "/Encrypt" in pdf.trailer:
        raise Refuse("encrypted")
    if "/Root" not in pdf.trailer:
        raise Refuse("no /Root")
    pages = [p.obj.objgen for p in pdf.pages]
    if not pages:
        raise Refuse("zero pages")
    entries = parse_toc(toc, offset, len(pages))
    try:
        kind = pdfraw.newest_xref_kind(data)
        prev = pdfraw.last_startxref(data)
    except Exception as e:  # noqa: BLE001
        raise Refuse(f"cannot parse xref: {e}")
    root_num, root_gen = pdf.Root.objgen
    size = int(pdf.trailer.Size)

    # tree
    n = len(entries)
    base = size
    onum = base            # /Outlines
    nums = [base + 1 + i for i in range(n)]
    parent = [None] * n
    children = {i: [] for i in range(-1, n)}
    stack = []
    for i, (lvl, _, _) in enumerate(entries):
        del stack[lvl:]
        parent[i] = stack[-1] if stack else -1
        children[parent[i]].append(i)
        stack.append(i)

    def desc(i):
        return sum(1 + desc(c) for c in children[i])

    objs = []  # (num, gen, body)
    if n:
        top = children[-1]
        objs.append((onum, 0, f"<< /Type /Outlines /First {nums[top[0]]} 0 R /Last {nums[top[-1]]} 0 R "
                               f"/Count {n} >>".encode()))
        for i, (lvl, title, pidx) in enumerate(entries):
            sib = children[parent[i]]
            k = sib.index(i)
            t = b"\xfe\xff" + title.encode("utf-16-be")
            d = [b"<< /Title ", lit(t) if literal_titles else b"<" + t.hex().upper().encode() + b">",
                 f" /Parent {onum if parent[i] == -1 else nums[parent[i]]} 0 R".encode()]
            if k > 0:
                d.append(f" /Prev {nums[sib[k - 1]]} 0 R".encode())
            if k + 1 < len(sib):
                d.append(f" /Next {nums[sib[k + 1]]} 0 R".encode())
            if children[i]:
                d.append(f" /First {nums[children[i][0]]} 0 R /Last {nums[children[i][-1]]} 0 R "
                         f"/Count {desc(i)}".encode())
            pg = pages[pidx]
            d.append(f" /Dest [{pg[0]} {pg[1]} R /XYZ null null null] >>".encode())
            objs.append((nums[i], 0, b"".join(d)))
    cat = [b"<<"]
    for k in pdf.Root.keys():
        if k in ("/Outlines", "/PageMode"):
            continue
        v = pdf.Root[k]
        cat.append(b" " + pikepdf.Name(k).unparse() + b" ")
        cat.append(f"{v.objgen[0]} {v.objgen[1]} R".encode() if v.is_indirect else v.unparse(resolved=False))
    if n:
        cat.append(f" /Outlines {onum} 0 R /PageMode /UseOutlines".encode())
    cat.append(b" >>")
    objs.append((root_num, root_gen, b"".join(cat)))

    upd = bytearray()
    if not data.endswith((b"\n", b"\r")):
        upd += b"\n"
    offs = {}
    for num, gen, body in objs:
        offs[num] = (len(data) + len(upd), gen)
        upd += f"{num} {gen} obj\n".encode() + body + b"\nendobj\n"
    trailer_extra = b""
    if "/Info" in pdf.trailer and pdf.trailer.Info.is_indirect:
        i = pdf.trailer.Info.objgen
        trailer_extra += f" /Info {i[0]} {i[1]} R".encode()
    if "/ID" in pdf.trailer:
        trailer_extra += b" /ID " + pdf.trailer.ID.unparse(resolved=True)
    highest = max([num for num, _, _ in objs])
    if kind == "stream":
        xnum = max(size, highest + 1)
        new_size = xnum + 1
        offs[xnum] = (len(data) + len(upd), 0)
        sorted_nums = sorted(offs)
        index, rows = [], bytearray()
        i = 0
        while i < len(sorted_nums):
            j = i
            while j + 1 < len(sorted_nums) and sorted_nums[j + 1] == sorted_nums[j] + 1:
                j += 1
            index += [sorted_nums[i], j - i + 1]
            for k in range(i, j + 1):
                off, gen = offs[sorted_nums[k]]
                rows += b"\x01" + off.to_bytes(8, "big") + gen.to_bytes(2, "big")
            i = j + 1
        d = (f"<< /Type /XRef /Size {new_size} /Index [{' '.join(map(str, index))}] /W [1 8 2] "
             f"/Root {root_num} {root_gen} R /Prev {prev} /Length {len(rows)}").encode() + trailer_extra + b" >>"
        start = len(data) + len(upd)
        upd += f"{xnum} 0 obj\n".encode() + d + b"\nstream\n" + bytes(rows) + b"\nendstream\nendobj\n"
        upd += b"startxref\n" + str(start).encode() + b"\n%%EOF\n"
    else:
        new_size = max(size, highest + 1)
        start = len(data) + len(upd)
        upd += b"xref\n0 1\n0000000000 65535 f \n"  # free-list head first: keeps pypdf's zero-index heuristic quiet
        sorted_nums = sorted(offs)
        i = 0
        while i < len(sorted_nums):
            j = i
            while j + 1 < len(sorted_nums) and sorted_nums[j + 1] == sorted_nums[j] + 1:
                j += 1
            upd += f"{sorted_nums[i]} {j - i + 1}\n".encode()
            for k in range(i, j + 1):
                off, gen = offs[sorted_nums[k]]
                upd += f"{off:010d} {gen:05d} n \n".encode()
            i = j + 1
        upd += (f"trailer\n<< /Size {new_size} /Root {root_num} {root_gen} R /Prev {prev}".encode() + trailer_extra
                + b" >>\nstartxref\n" + str(start).encode() + b"\n%%EOF\n")
    pdf.close()
    fd, tmp = tempfile.mkstemp(dir=str(outp.parent), prefix=".ref_apply.")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
        f.write(upd)
    os.replace(tmp, outp)


def main(argv):
    if len(argv) < 2 or argv[1] != "apply":
        print("usage: ref_apply.py apply <in.pdf> <toc.txt> -o <out.pdf> [--offset N]", file=sys.stderr)
        return 64
    pos, out, offset, literal = [], None, 0, False
    it = iter(argv[2:])
    for a in it:
        if a == "-o":
            out = next(it)
        elif a == "--offset":
            offset = int(next(it))
        elif a == "--literal-titles":
            literal = True
        else:
            pos.append(a)
    if len(pos) != 2 or not out:
        print("usage: ref_apply.py apply <in.pdf> <toc.txt> -o <out.pdf> [--offset N]", file=sys.stderr)
        return 64
    try:
        apply(Path(pos[0]), Path(pos[1]), Path(out), offset, literal)
    except Refuse as e:
        print(f"ref_apply: refused: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
