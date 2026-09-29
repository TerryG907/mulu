# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pikepdf>=9",
#   "pypdf>=5",
#   "pypdfium2>=4.30",
# ]
# ///
"""
verify.py -- the mulu verification harness.

    uv run --python 3.12 tools/verify/verify.py run-all  --mulu .build/release/mulu [--only a,b] [--json F]
    uv run --python 3.12 tools/verify/verify.py selftest [--only a,b]    # proves the harness (no mulu needed)
    uv run --python 3.12 tools/verify/verify.py readers  <file.pdf>...   # every reader's outline, for debugging
    uv run --python 3.12 tools/verify/verify.py resave-growth            # PDFKit rewrite growth table

VERIFICATION DEFINITION, per fixture:
  (a) prefix   output[0:len(in)] == in; input file unchanged; appended size reported
  (b) readers  PDFKit, qpdf (pikepdf), PDFium (pypdfium2), pypdf, pdf.js -- plus mulu's own dump-outline --
               must each report exactly <name>.expected.json (title, level, page_index)
  (c) check()  pikepdf check_pdf_syntax() + open warnings on the output add nothing new vs the input
  (d) pages    page count agrees across readers; PDFKit first/last page text + rendering hash unchanged
  (e) refusals exit 2, one-line stderr, no output file, input unchanged
  (f) re-apply second TOC applied on top of the first output; second outline wins; prefix holds at each step
  plus
  spec         a strict byte-level parse of the appended update (tools/verify/pdfraw.py) against the WRITER
               REQUIREMENTS: xref kind, 20-byte entries, offsets land on 'N G obj', /Prev, /Size, /Root, /Info,
               /ID, new-object numbering, catalog revision, hex UTF-16BE titles, /Count, /Dest arrays
  struct       the outline + catalog as qpdf resolves them: links, counts, catalog keys preserved, /PageMode
  info         `mulu info` JSON on input and output agrees with the fixture facts
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import pdfraw  # noqa: E402
from pdfraw import PDFString, Ref  # noqa: E402

GEN = ROOT / "Fixtures" / "generated"
OUTDIR = ROOT / "Fixtures" / "out"
BIN = HERE / ".bin"
PDFJS = HERE / "pdfjs"
READERS = ["pdfkit", "qpdf", "pdfium", "pypdf", "pdfjs"]
REF_APPLY = HERE / "ref_apply.py"

# ============================================================================
# worker side: each python reader / check runs in its own subprocess
# ============================================================================


def _named_dest_lookup(pdf, name):
    import pikepdf
    try:
        if isinstance(name, pikepdf.Name) and "/Dests" in pdf.Root:
            v = pdf.Root.Dests.get(name)
            if v is not None:
                return v
        if "/Names" in pdf.Root and "/Dests" in pdf.Root.Names:
            nt = pikepdf.NameTree(pdf.Root.Names.Dests)
            key = str(name) if not isinstance(name, pikepdf.Name) else str(name)[1:]
            if key in nt:
                return nt[key]
    except Exception:  # noqa: BLE001
        return None
    return None


def worker_qpdf(path):
    import pikepdf
    pdf = pikepdf.open(path)
    page_idx = {p.obj.objgen: i for i, p in enumerate(pdf.pages)}

    def resolve(d, depth=0):
        if d is None or depth > 4:
            return -1
        if isinstance(d, (pikepdf.Name, pikepdf.String)):
            return resolve(_named_dest_lookup(pdf, d), depth + 1)
        if isinstance(d, pikepdf.Dictionary) and "/D" in d:
            return resolve(d.D, depth + 1)
        if isinstance(d, pikepdf.Array) and len(d) > 0:
            first = d[0]
            if isinstance(first, pikepdf.Dictionary):
                return page_idx.get(first.objgen, -1)
            try:
                return int(first)
            except Exception:  # noqa: BLE001
                return -1
        return -1

    items = []
    with pdf.open_outline(max_depth=64) as ol:
        def walk(nodes, level):
            for it in nodes:
                d = it.destination
                if d is None and it.action is not None and it.action.get("/S") == "/GoTo":
                    d = it.action.get("/D")
                items.append({"title": str(it.title), "level": level, "page_index": resolve(d)})
                walk(it.children, level + 1)
        walk(ol.root, 0)
    return {"ok": True, "pages": len(pdf.pages), "outline": items,
            "warnings": [str(w) for w in pdf.get_warnings()]}


def worker_pdfium(path):
    import pypdfium2 as pdfium
    import pypdfium2.raw as c
    pdf = pdfium.PdfDocument(str(path))
    items = []
    for bm in pdf.get_toc(max_depth=64):
        idx = None
        dest = bm.get_dest()
        if dest is not None:
            idx = dest.get_index()
        if idx is None:
            act = c.FPDFBookmark_GetAction(bm.raw)
            if act:
                d = c.FPDFAction_GetDest(pdf.raw, act)
                if d:
                    v = c.FPDFDest_GetDestPageIndex(pdf.raw, d)
                    idx = v if v >= 0 else None
        items.append({"title": bm.get_title(), "level": bm.level, "page_index": -1 if idx is None else idx})
    n = len(pdf)
    texts = {}
    for key, i in (("first_text", 0), ("last_text", n - 1)):
        try:
            texts[key] = pdf[i].get_textpage().get_text_range() if n else ""
        except Exception as e:  # noqa: BLE001
            texts[key] = f"<error {e}>"
    pdf.close()
    return {"ok": True, "pages": n, "outline": items, "warnings": [], **texts}


def worker_pypdf(path):
    import logging

    import pypdf
    records = []

    class H(logging.Handler):
        def emit(self, r):
            records.append(r.getMessage())

    lg = logging.getLogger("pypdf")
    lg.addHandler(H())
    lg.setLevel(logging.WARNING)
    r = pypdf.PdfReader(str(path), strict=False)
    n = len(r.pages)
    items = []

    def walk(lst, level):
        for it in lst:
            if isinstance(it, list):
                walk(it, level + 1)
                continue
            try:
                idx = r.get_destination_page_number(it)
            except Exception:  # noqa: BLE001
                idx = None
            items.append({"title": str(it.title), "level": level, "page_index": -1 if idx is None else idx})

    walk(r.outline, 0)
    return {"ok": True, "pages": n, "outline": items, "warnings": records}


def _unparse(v) -> str:
    import decimal

    import pikepdf
    if isinstance(v, pikepdf.Object):
        if v.is_indirect:
            return f"{v.objgen[0]} {v.objgen[1]} R"
        text = v.unparse(resolved=False).decode("latin-1")
        return re.sub(r"(?<![\w#/.+-])[+-]?(?:\d+\.\d*|\.\d+)(?![\w.])",
                      lambda m: format(decimal.Decimal(m.group()).normalize(), "f"), text)
    # pikepdf returns numbers and booleans as Python values
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, decimal.Decimal):
        return format(v.normalize(), "f")
    if v is None:
        return "null"
    return str(v)


def worker_facts(path):
    import pikepdf
    pdf = pikepdf.open(path)
    tr = pdf.trailer
    info = list(tr.Info.objgen) if "/Info" in tr and tr.Info.is_indirect else None
    ids = [bytes(x).hex() for x in tr.ID] if "/ID" in tr else None
    return {"ok": True, "root": list(pdf.Root.objgen), "size": int(tr.Size),
            "pages": [list(p.obj.objgen) for p in pdf.pages], "info": info, "id": ids,
            "root_keys": {str(k): _unparse(pdf.Root[k]) for k in pdf.Root.keys()},
            "warnings": [str(w) for w in pdf.get_warnings()]}


def worker_check(path):
    import pikepdf
    pdf = pikepdf.open(path)
    fn = getattr(pdf, "check_pdf_syntax", None) or getattr(pdf, "check")
    problems = [str(p) for p in fn()]
    return {"ok": True, "problems": problems, "warnings": [str(w) for w in pdf.get_warnings()]}


def worker_struct(inp, outp, n_expected):
    """Outline + catalog as qpdf resolves them."""
    import pikepdf
    n_expected = int(n_expected)
    probs = []
    try:
        a = pikepdf.open(inp)
    except Exception as e:  # noqa: BLE001
        return {"ok": None, "na": f"qpdf cannot open the input: {e}"}
    b = pikepdf.open(outp)
    in_keys = {str(k): _unparse(a.Root[k]) for k in a.Root.keys() if not str(k).startswith("/QPDFFake")}
    out_keys = {str(k): _unparse(b.Root[k]) for k in b.Root.keys() if not str(k).startswith("/QPDFFake")}
    for k, v in in_keys.items():
        if k in ("/Outlines", "/PageMode"):
            continue
        if k not in out_keys:
            probs.append(f"catalog lost key {k}")
        elif out_keys[k] != v:
            probs.append(f"catalog {k} changed: {v[:60]} -> {out_keys[k][:60]}")
    if a.Root.objgen != b.Root.objgen:
        probs.append(f"catalog object number changed {a.Root.objgen} -> {b.Root.objgen}")
    for k in ("/Info",):
        ia = a.trailer.get(k)
        ib = b.trailer.get(k)
        if (ia is not None) != (ib is not None) or (ia is not None and ia.objgen != ib.objgen):
            probs.append(f"trailer {k} not preserved")
    if [p.obj.objgen for p in a.pages] != [p.obj.objgen for p in b.pages]:
        probs.append("page object list changed")
    if n_expected:
        if str(b.Root.get("/PageMode", "")) != "/UseOutlines":
            probs.append(f"/PageMode is {b.Root.get('/PageMode')} not /UseOutlines")
        ol = b.Root.get("/Outlines")
        if ol is None:
            probs.append("no /Outlines in catalog")
        else:
            seen = set()
            total = [0]

            def lint(node, is_root, depth):
                if depth > 64:
                    probs.append("outline depth > 64 (cycle?)")
                    return 0
                kids = []
                c = node.get("/First")
                prev = None
                while c is not None:
                    if c.objgen in seen:
                        probs.append(f"outline cycle at {c.objgen}")
                        break
                    seen.add(c.objgen)
                    kids.append(c)
                    if c.get("/Parent") is None or c.Parent.objgen != node.objgen:
                        probs.append(f"item {c.objgen} /Parent wrong")
                    if prev is None and c.get("/Prev") is not None:
                        probs.append(f"first child {c.objgen} has /Prev")
                    if prev is not None and (c.get("/Prev") is None or c.Prev.objgen != prev.objgen):
                        probs.append(f"item {c.objgen} /Prev wrong")
                    prev = c
                    c = c.get("/Next")
                if kids:
                    if node.get("/Last") is None or node.Last.objgen != kids[-1].objgen:
                        probs.append(f"node {node.objgen} /Last wrong")
                elif node.get("/First") is not None or node.get("/Last") is not None:
                    probs.append(f"node {node.objgen} has dangling /First or /Last")
                desc = 0
                for k in kids:
                    total[0] += 1
                    d = lint(k, False, depth + 1)
                    desc += 1 + d
                    cnt = int(k.get("/Count", 0))
                    if cnt != d:
                        probs.append(f"item {k.objgen} /Count {cnt} != descendants {d} (all items open)")
                    t = k.get("/Title")
                    if t is None:
                        probs.append(f"item {k.objgen} has no /Title")
                    dest = k.get("/Dest")
                    if dest is None or not isinstance(dest, pikepdf.Array) or len(dest) < 2:
                        probs.append(f"item {k.objgen} /Dest is not an explicit array")
                    elif str(dest[1]) != "/XYZ":
                        probs.append(f"item {k.objgen} /Dest uses {dest[1]} not /XYZ")
                return desc

            d = lint(ol, True, 0)
            if str(ol.get("/Type", "/Outlines")) != "/Outlines":
                probs.append(f"/Outlines /Type is {ol.get('/Type')}")
            if int(ol.get("/Count", 0)) != d:
                probs.append(f"/Outlines /Count {ol.get('/Count')} != total items {d}")
            if total[0] != n_expected:
                probs.append(f"{total[0]} outline items reachable, expected {n_expected}")
    else:
        if "/Outlines" in b.Root:
            probs.append("empty TOC but catalog still has /Outlines")
    return {"ok": not probs, "problems": probs}


def worker_spec(inp, outp, expected_path, opts_json="{}"):
    """Strict byte-level check of the appended update against the WRITER REQUIREMENTS.

    Offsets are checked in the input's own frame (pdfraw.offset_frame): absolute, or
    relative to '%PDF-' when the input has junk before the header and its offsets are
    header-relative. Fixture options (manifest):
      complete_xref  the input's xref chain is unusable (mulu reconstructs it), so the
                     update must be a COMPLETE table without /Prev; every row must land
                     exactly on its object (original objects included). Such a file's
                     frame is header-relative whenever there is junk before '%PDF-'.
      republish      the input has xref entries mulu repairs (wrong offsets, a renumbered
                     table); the update may republish original objects, but every such
                     row must land exactly on the right 'N G obj' header.
    """
    opts = json.loads(opts_json)
    complete = bool(opts.get("complete_xref"))
    republish = bool(opts.get("republish")) or complete
    expected = json.loads(Path(expected_path).read_text(encoding="utf-8"))
    try:
        f = worker_facts(inp)
    except Exception as e:  # noqa: BLE001
        return {"ok": None, "na": f"qpdf cannot open the input: {e}"}
    A = Path(inp).read_bytes()
    B = Path(outp).read_bytes()
    P = []
    frame = pdfraw.header_offset(A) if complete else pdfraw.offset_frame(A)
    if not complete and pdfraw.offset_frame(B) != frame:
        P.append(f"output offsets use frame {pdfraw.offset_frame(B)}, input uses {frame}")
    if not B.startswith(A):
        return {"ok": False, "problems": ["output does not start with the input bytes"]}
    base = len(A)
    if A[-1:] not in (b"\n", b"\r") and B[base:base + 1] != b"\n":
        P.append("input does not end with EOL and update does not start with a single \\n")
    if A[-1:] not in (b"\n", b"\r") and B[base + 1:base + 2] in (b"\n", b"\r"):
        P.append("more than one EOL inserted before the update")
    if not B.rstrip(b"\r\n").endswith(b"%%EOF"):
        P.append("output does not end with %%EOF")
    tail = B[B.rfind(b"startxref"):]
    if not re.fullmatch(rb"startxref(\r\n|\n|\r)\d+(\r\n|\n|\r)%%EOF(\r\n|\n|\r)?", tail):
        P.append(f"file tail is not 'startxref\\n<n>\\n%%EOF\\n': {tail[:60]!r}")
    in_kind, in_sx = None, None
    if not complete:
        try:
            in_sx = pdfraw.last_startxref(A)
            in_kind = pdfraw.xref_kind_at(A, in_sx + frame, tolerant=True)
        except Exception as e:  # noqa: BLE001
            in_kind, in_sx = None, None
            P.append(f"(harness) cannot parse input xref: {e}")
    sx = pdfraw.last_startxref(B)
    if sx + frame < base:
        return {"ok": False, "problems": P + [f"final startxref {sx} points into the original bytes (< {base})"]}
    if not pdfraw.lands_exactly(B, sx + frame):
        P.append(f"final startxref {sx} (+{frame}) does not land exactly on 'xref' or 'N G obj'")

    upd_objs: dict[int, pdfraw.IndirectObject] = {}

    def length_resolver(ref):
        o = upd_objs.get(ref.num)
        if o is None:
            raise pdfraw.PDFSyntaxError("indirect /Length not in update")
        return o.value

    try:
        sec = pdfraw.parse_xref_section(B, sx + frame, length_resolver)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "problems": P + [f"new xref section unparseable: {e}"]}
    P += sec.problems
    want_kind = "stream" if in_kind == "stream" else "classic"
    if in_kind and sec.kind != want_kind:
        P.append(f"input's newest xref is {in_kind}; update used {sec.kind} (expected {want_kind})")
    tr = sec.trailer
    if complete:
        if "Prev" in tr:
            P.append("the input needed reconstruction, but the update's xref has /Prev")
        missing = [n for n in range(int(tr.get("Size", 0))) if n not in sec.entries]
        if missing:
            P.append(f"the update's xref must be complete; objects {missing[:5]} are missing")
    elif in_sx is not None and tr.get("Prev") != in_sx:
        P.append(f"/Prev {tr.get('Prev')} != input startxref {in_sx}")
    # ISO 32000-1 §7.5.6: the added trailer keeps every entry of the previous one
    # (except /Prev; for an xref stream, minus the keys that describe the stream).
    if in_sx is not None:
        try:
            in_tr = pdfraw.parse_xref_section(A, in_sx + frame, tolerant=True).trailer
        except Exception:  # noqa: BLE001
            in_tr = {}
        section_keys = {"Type", "Size", "Index", "W", "Prev", "XRefStm", "Length", "Filter", "DecodeParms", "DP",
                        "F", "FFilter", "FDecodeParms", "DL", "Root", "Encrypt"}
        for k, v in in_tr.items():
            if k in section_keys or v is None:
                continue
            if tr.get(k) != v:
                P.append(f"trailer entry /{k} of the input not carried over (§7.5.6): {tr.get(k)!r} != {v!r}")
    root = Ref(*f["root"])
    if tr.get("Root") != root:
        P.append(f"/Root {tr.get('Root')} != input root {root}")
    if f["info"] and tr.get("Info") != Ref(*f["info"]):
        P.append(f"/Info {tr.get('Info')} not copied (input {f['info']})")
    if f["id"]:
        tid = tr.get("ID")
        if not (isinstance(tid, list) and [bytes(x).hex() for x in tid] == f["id"]):
            P.append("/ID not copied from the input trailer")
    if "Encrypt" in tr:
        P.append("update trailer has /Encrypt")
    if sec.kind == "stream":
        if tr.get("Filter") is not None:
            P.append(f"xref stream is compressed ({tr.get('Filter')}); spec asks for uncompressed")
        own = sec.entries.get(sec.stream_obj.num)
        if not own or own.type != 1 or own.f2 != sx:
            P.append("xref stream does not list itself with its own offset")
    # objects in the update
    republished = 0
    for num, e in sorted(sec.entries.items()):
        if e.type == 1:
            if e.f2 + frame < base:
                m = pdfraw._OBJ_HDR.match(B, e.f2 + frame)
                if not republish:
                    P.append(f"obj {num}: xref offset {e.f2} points into the original bytes")
                elif not (m and (int(m.group(1)), int(m.group(2))) == (num, e.f3)
                          and pdfraw.lands_exactly(B, e.f2 + frame)):
                    P.append(f"republished obj {num}: offset {e.f2} (+{frame}) does not land exactly on "
                             f"'{num} {e.f3} obj'")
                republished += 1
                continue
            try:
                o = pdfraw.parse_indirect(B, e.f2 + frame)
            except Exception as ex:  # noqa: BLE001
                P.append(f"obj {num}: offset {e.f2} does not land on '{num} {e.f3} obj' ({ex})")
                continue
            if (o.num, o.gen) != (num, e.f3):
                P.append(f"xref says {num} {e.f3} at {e.f2}, found {o.num} {o.gen} obj")
            upd_objs[num] = o
        elif e.type == 2 and not complete:
            P.append(f"obj {num}: update uses a compressed (type 2) entry")
    # re-parse stream objects with indirect /Length now that all objects are known
    max_new = max(sec.entries) if sec.entries else -1
    size_in = f["size"]
    if tr.get("Size") != max(size_in, max_new + 1):
        P.append(f"/Size {tr.get('Size')} != max(original {size_in}, highest new {max_new} + 1)")
    for num in upd_objs:
        if num >= size_in:
            continue
        if num == root.num or (sec.kind == "stream" and num == sec.stream_obj.num):
            continue
        P.append(f"obj {num} revised in the update but it is neither the catalog nor numbered >= /Size {size_in}")
    # §7.3.10: a reference to an undefined object is null. A new object must not take a
    # number that something in the input already refers to, or it changes that meaning.
    taken = sorted(set(upd_objs) - {root.num} & pdfraw.referenced_numbers(A))
    if taken:
        P.append(f"new object(s) {taken[:5]} reuse numbers the input already refers to (dangling references)")
    cat = upd_objs.get(root.num)
    items_raw = []
    if cat is None or cat.gen != root.gen:
        P.append(f"catalog {root} not rewritten in the update")
    elif not isinstance(cat.value, dict):
        P.append("catalog revision is not a dictionary")
    else:
        cd = cat.value
        # compare names as bytes: qpdf decodes name bytes as UTF-8, pdfraw as Latin-1
        have = {k.encode("latin-1", "replace") for k in cd}
        lost = sorted(k[1:] for k in f["root_keys"] if k not in ("/Outlines", "/PageMode")
                      and not k.startswith("/QPDFFake") and k[1:].encode("utf-8", "surrogateescape") not in have)
        if lost:
            P.append(f"catalog revision dropped key(s) {lost}")
        if expected:
            if cd.get("PageMode") != "UseOutlines":
                P.append(f"catalog /PageMode {cd.get('PageMode')!r} != /UseOutlines")
            oref = cd.get("Outlines")
            if not isinstance(oref, Ref) or oref.num not in upd_objs:
                P.append(f"catalog /Outlines {oref!r} is not a new object in the update")
            else:
                pages = {Ref(*p): i for i, p in enumerate(f["pages"])}
                od = upd_objs[oref.num].value
                if not isinstance(od, dict):
                    P.append("/Outlines is not a dictionary")
                else:
                    if od.get("Type") not in (None, "Outlines"):
                        P.append(f"/Outlines /Type {od.get('Type')!r}")
                    seen = set()

                    def walk(node_ref, node, level, depth):
                        if depth > 64:
                            P.append("outline too deep / cyclic")
                            return 0
                        c = node.get("First")
                        prev = None
                        desc = 0
                        last = None
                        while c is not None:
                            if not isinstance(c, Ref) or c.num not in upd_objs:
                                P.append(f"outline link {c!r} is not a new object in the update")
                                break
                            if c in seen:
                                P.append(f"outline cycle at {c}")
                                break
                            seen.add(c)
                            it = upd_objs[c.num].value
                            if not isinstance(it, dict):
                                P.append(f"outline item {c} is not a dictionary")
                                break
                            t = it.get("Title")
                            if not isinstance(t, PDFString):
                                P.append(f"item {c}: /Title missing or not a string")
                                title = ""
                            else:
                                if not t.hex:
                                    P.append(f"item {c}: /Title is a literal string, spec requires <FEFF...> hex")
                                if not bytes(t).startswith(b"\xfe\xff"):
                                    P.append(f"item {c}: /Title lacks the UTF-16BE BOM")
                                title = t.text()
                            if it.get("Parent") != node_ref:
                                P.append(f"item {c}: /Parent {it.get('Parent')} != {node_ref}")
                            if it.get("Prev") != prev:
                                P.append(f"item {c}: /Prev {it.get('Prev')} != {prev}")
                            dest = it.get("Dest")
                            pidx = -1
                            if not (isinstance(dest, list) and len(dest) == 5 and isinstance(dest[0], Ref)
                                    and dest[1] == "XYZ" and dest[2:] == [None, None, None]):
                                P.append(f"item {c}: /Dest {dest!r} is not [pageRef /XYZ null null null]")
                            if isinstance(dest, list) and dest and isinstance(dest[0], Ref):
                                pidx = pages.get(dest[0], -1)
                                if pidx < 0:
                                    P.append(f"item {c}: /Dest page {dest[0]} is not a page of the input")
                            items_raw.append({"title": title, "level": level, "page_index": pidx})
                            d = walk(c, it, level + 1, depth + 1)
                            cnt = it.get("Count", 0)
                            if cnt != d:
                                P.append(f"item {c}: /Count {cnt} != descendants {d}")
                            desc += 1 + d
                            prev = c
                            last = c
                            c = it.get("Next")
                        if node.get("Last") != last:
                            P.append(f"node {node_ref}: /Last {node.get('Last')} != {last}")
                        return desc

                    total = walk(oref, od, 0, 0)
                    if od.get("Count") != total:
                        P.append(f"/Outlines /Count {od.get('Count')} != total items {total}")
        elif "Outlines" in cd:
            P.append("empty TOC but catalog revision still has /Outlines")
    if expected and items_raw != expected:
        diff = first_diff(items_raw, expected)
        P.append(f"raw outline != expected: {diff}")
    return {"ok": not P, "problems": P, "appended": len(B) - len(A), "kind": sec.kind, "frame": frame,
            "republished": republished}


WORKERS = {"qpdf": worker_qpdf, "pdfium": worker_pdfium, "pypdf": worker_pypdf, "facts": worker_facts,
           "check": worker_check, "struct": worker_struct, "spec": worker_spec}


def worker_main(argv):
    task, args = argv[0], argv[1:]
    try:
        res = WORKERS[task](*args)
    except Exception as e:  # noqa: BLE001
        res = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    sys.stdout.write(json.dumps(res, ensure_ascii=False) + "\n")
    return 0


# ============================================================================
# orchestration side
# ============================================================================


def first_diff(got, exp):
    if not isinstance(got, list):
        return f"not a list: {str(got)[:80]}"
    for i, (g, e) in enumerate(zip(got, exp)):
        gg = (g.get("title"), g.get("level"), g.get("page_index"))
        ee = (e["title"], e["level"], e["page_index"])
        if gg != ee:
            return f"item {i}: got {gg!r} want {ee!r}"
    if len(got) != len(exp):
        return f"{len(got)} items, want {len(exp)}"
    return ""


def outline_eq(got, exp):
    if not isinstance(got, list) or len(got) != len(exp):
        return False
    return all((g.get("title"), g.get("level"), g.get("page_index")) == (e["title"], e["level"], e["page_index"])
               for g, e in zip(got, exp))


def run_json(cmd, timeout=240) -> dict:
    try:
        p = subprocess.run([str(c) for c in cmd], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"timeout after {timeout}s"}
    except OSError as e:
        return {"ok": False, "error": f"cannot run {cmd[0]}: {e}"}
    # "\n" only: str.splitlines() also splits on U+2028, U+0085 etc., which may occur in titles
    lines = [ln for ln in p.stdout.decode("utf-8", errors="replace").strip().split("\n") if ln.strip()]
    if not lines:
        return {"ok": False, "error": f"exit {p.returncode}, no output; stderr: "
                                      f"{p.stderr.decode(errors='replace').strip()[-300:]}"}
    try:
        res = json.loads(lines[-1])
    except json.JSONDecodeError:
        return {"ok": False, "error": f"exit {p.returncode}, non-JSON output: {lines[-1][:200]}"}
    if isinstance(res, dict):
        res.setdefault("exit", p.returncode)
    return res


def py_worker(task, *args):
    return [sys.executable, str(Path(__file__).resolve()), "_worker", task, *[str(a) for a in args]]


def ensure_tools(quiet=False):
    BIN.mkdir(exist_ok=True)
    for name in ("pdfkit_inspect", "pdfkit_resave"):
        src, exe = HERE / f"{name}.swift", BIN / name
        if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
            if not quiet:
                print(f"[verify] compiling {name}.swift (swiftc -O) ...", flush=True)
            subprocess.run(["swiftc", "-O", "-swift-version", "5", str(src), "-o", str(exe)], check=True)
    if not (PDFJS / "node_modules" / "pdfjs-dist").exists():
        if not quiet:
            print("[verify] npm install (pdfjs-dist) ...", flush=True)
        subprocess.run(["npm", "install", "--no-audit", "--no-fund", "--silent"], cwd=PDFJS, check=True)


def reader_cmd(reader, path, mulu=None):
    if reader == "pdfkit":
        return [BIN / "pdfkit_inspect", path]
    if reader == "pdfjs":
        return ["node", PDFJS / "outline.mjs", path]
    if reader == "mulu":
        return [mulu, "dump-outline", path]
    return py_worker(reader, path)


def run_reader(reader, path, mulu=None):
    if reader == "mulu":
        try:
            p = subprocess.run([str(mulu), "dump-outline", str(path)], capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            return {"ok": False, "error": str(e)}
        if p.returncode != 0:
            return {"ok": False, "error": f"exit {p.returncode}: {p.stderr.decode(errors='replace').strip()[:200]}"}
        try:
            arr = json.loads(p.stdout.decode("utf-8"))
        except json.JSONDecodeError as e:
            return {"ok": False, "error": f"dump-outline printed non-JSON: {e}"}
        return {"ok": isinstance(arr, list), "outline": arr, "warnings": []}
    return run_json(reader_cmd(reader, path, mulu))


def sha(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError:
        return None


def norm_warn(w: str, path) -> str:
    s = w.replace(str(path), "<file>")
    s = re.sub(r"/[^\s:()]+\.pdf", "<file>", s)
    # qpdf: "(object 1 0, offset 3075): ..." -> the object identifies the warning; its
    # byte offset moves when the object is re-read in a longer file. Offsets with no
    # object ("(offset 1470): xref not found") are kept.
    s = re.sub(r"\(((?:xref stream: )?object \d+ \d+), offset \d+\)", r"(\1)", s)
    return s


def norm_warn_junk_prefix(w: str) -> str | None:
    """pypdf with junk before '%PDF-': pypdf takes offsets as absolute, while the file's
    offsets are relative to the header (as qpdf, PDFium, pdf.js and PDFKit read them).
    Its startxref heuristics then differ only in which check number fails, and original
    objects whose preceding bytes are not whitespace are reported as wrong pointers
    (pypdf then finds them by searching). Both are properties of the input's frame."""
    if w.startswith("incorrect startxref pointer("):
        return "incorrect startxref pointer(*)"
    if w.startswith("Ignoring wrong pointing object"):
        return None
    return w


@dataclass
class Case:
    name: str
    label: str
    kind: str                  # apply | refuse | reapply | samepath | negative
    inp: Path
    toc: Path | None
    offset: int
    expected: list
    out: Path
    facts: dict = field(default_factory=dict)
    perf_limit_ms: int | None = None
    notes: str = ""
    # results
    exit: int | None = None
    stderr: str = ""
    ms: float | None = None
    ms_min: float | None = None
    appended: int | None = None
    cols: dict = field(default_factory=dict)      # col -> (status, short)
    details: list = field(default_factory=list)
    expect_fail: bool = False
    extra_cmd: list = field(default_factory=list)
    opts: dict = field(default_factory=dict)     # manifest options (regression fixtures)
    max_rss: int | None = None                   # bytes, measured
    remarks: list = field(default_factory=list)  # why an n/a or a tolerated change was accepted

    def set(self, col, ok, short="", detail=None):
        st = "ok" if ok is True else ("FAIL" if ok is False else ok)
        self.cols[col] = (st, short)
        if st == "FAIL" and detail:
            self.details.append(f"{col}: {detail}")

    @property
    def passed(self):
        return all(st != "FAIL" for st, _ in self.cols.values())


def read_int(p: Path, default=0):
    try:
        return int(p.read_text().strip())
    except (FileNotFoundError, ValueError):
        return default


def load_cases(gen: Path, out: Path, only: set[str]):
    manifest = json.loads((gen / "manifest.json").read_text(encoding="utf-8"))
    cases, skipped = [], []
    for name, m in manifest["fixtures"].items():
        if only and name not in only:
            continue
        if m.get("status") != "ok":
            skipped.append((name, m.get("status"), m.get("notes", "")))
            continue
        refuse = (gen / f"{name}.expect").exists() and (gen / f"{name}.expect").read_text().strip() == "refuse"
        c = Case(name=name, label=name, kind="refuse" if refuse else "apply", inp=gen / f"{name}.pdf",
                 toc=gen / f"{name}.toc.txt", offset=read_int(gen / f"{name}.offset"),
                 expected=json.loads((gen / f"{name}.expected.json").read_text(encoding="utf-8")),
                 out=out / f"{name}.pdf", facts=dict(m.get("facts", {}), **{
                     "revisions_ambiguous": m.get("revisions_ambiguous", False),
                     "allow_input_warnings": m.get("allow_input_warnings", False)}),
                 perf_limit_ms=m.get("perf_limit_ms"), notes=m.get("notes", ""), opts=dict(m.get("options", {})))
        cases.append(c)
        if m.get("reapply") and not refuse:
            # the second apply reads mulu's own output: a clean chain, nothing to repair
            ropts = {k: v for k, v in c.opts.items() if k not in ("complete_xref", "republish")}
            r = Case(name=name, label=f"{name} ↻", kind="reapply", inp=c.out, toc=gen / f"{name}.reapply.toc.txt",
                     offset=c.offset,
                     expected=json.loads((gen / f"{name}.reapply.expected.json").read_text(encoding="utf-8")),
                     out=out / f"{name}.reapply.pdf", facts=dict(c.facts, original_input=str(c.inp)), opts=ropts)
            cases.append(r)
    return cases, skipped


def apply_cmd(backend, c: Case, extra=()):
    cmd = list(backend) + ["apply", str(c.inp), str(c.toc), "-o", str(c.out)]
    if c.offset:
        cmd += ["--offset", str(c.offset)]
    return cmd + list(extra)


def run_measured(cmd, timeout=120):
    """(returncode or None on timeout, stdout, stderr, peak RSS in bytes)."""
    import tempfile
    import threading
    with tempfile.TemporaryFile() as fo, tempfile.TemporaryFile() as fe:
        proc = subprocess.Popen([str(x) for x in cmd], stdout=fo, stderr=fe)
        killed = []
        timer = threading.Timer(timeout, lambda: (killed.append(1), proc.kill()))
        timer.start()
        try:
            _, status, ru = os.wait4(proc.pid, 0)
        finally:
            timer.cancel()
        proc.returncode = os.waitstatus_to_exitcode(status)
        fo.seek(0)
        fe.seek(0)
        rss = ru.ru_maxrss if sys.platform == "darwin" else ru.ru_maxrss * 1024
        return (None if killed else proc.returncode), fo.read(), fe.read(), rss


def do_apply(backend, c: Case, perf_repeats=3):
    c.out.parent.mkdir(parents=True, exist_ok=True)
    if c.out.exists() or c.out.is_symlink():
        c.out.unlink()
    before = sha(c.inp)
    t0 = time.perf_counter()
    rc, _, err, rss = run_measured(apply_cmd(backend, c, c.extra_cmd), timeout=120)
    c.exit = rc
    c.stderr = err.decode("utf-8", errors="replace") if rc is not None else "timeout (120 s)"
    c.max_rss = rss
    c.ms = (time.perf_counter() - t0) * 1000
    c.ms_min = c.ms
    after = sha(c.inp)
    c.facts["input_unchanged"] = before == after
    if c.perf_limit_ms and c.exit == 0:
        tmp = c.out.with_suffix(".perf.pdf")
        for _ in range(perf_repeats - 1):
            cc = Case(**{**c.__dict__, "out": tmp, "cols": {}, "details": []})
            t0 = time.perf_counter()
            subprocess.run(apply_cmd(backend, cc), capture_output=True, timeout=120)
            c.ms_min = min(c.ms_min, (time.perf_counter() - t0) * 1000)
        tmp.unlink(missing_ok=True)


def check_info(js, facts, *, is_output, in_info=None, n_expected=0, out_size=None, complete=False):
    """Returns list of problems for a `mulu info` JSON object."""
    P = []
    keys = {"xref": str, "revisions": int, "objects": int, "pages": int, "encrypted": bool, "hasOutline": bool,
            "linearized": bool, "size": int}
    for k, t in keys.items():
        if k not in js:
            P.append(f"missing key {k}")
        elif not isinstance(js[k], t) or (t is int and isinstance(js[k], bool)):
            P.append(f"{k} has type {type(js[k]).__name__}")
    if P:
        return P
    if js["xref"] not in ("classic", "stream", "hybrid"):
        P.append(f"xref {js['xref']!r}")
    if js["objects"] <= 0:
        P.append(f"objects {js['objects']}")
    if "pages" in facts and js["pages"] != facts["pages"]:
        P.append(f"pages {js['pages']} != {facts['pages']}")
    if not is_output:
        if facts.get("xref") in ("classic", "stream", "hybrid") and js["xref"] != facts["xref"]:
            P.append(f"xref {js['xref']} != {facts['xref']}")
        if "encrypted" in facts and js["encrypted"] != facts["encrypted"]:
            P.append(f"encrypted {js['encrypted']} != {facts['encrypted']}")
        if "has_outline" in facts and js["hasOutline"] != facts["has_outline"]:
            P.append(f"hasOutline {js['hasOutline']} != {facts['has_outline']}")
        if "linearized" in facts and js["linearized"] != facts["linearized"]:
            P.append(f"linearized {js['linearized']} != {facts['linearized']}")
        if facts.get("revisions") and not facts.get("revisions_ambiguous") and js["revisions"] != facts["revisions"]:
            P.append(f"revisions {js['revisions']} != {facts['revisions']}")
        if "size" in facts and js["size"] != facts["size"]:
            P.append(f"size {js['size']} != {facts['size']}")
    else:
        if js["hasOutline"] != bool(n_expected):
            P.append(f"hasOutline {js['hasOutline']} after applying {n_expected} entries")
        if out_size is not None and js["size"] != out_size:
            P.append(f"size {js['size']} != {out_size}")
        if in_info:
            if complete:  # the input was reconstructed: the update is a complete xref without /Prev
                if js["revisions"] != 1:
                    P.append(f"revisions {js['revisions']} != 1 after a complete (reconstructed) xref")
            elif js["revisions"] != in_info.get("revisions", -99) + 1:
                P.append(f"revisions {js['revisions']} != input {in_info.get('revisions')} + 1")
            want = {"classic": "classic", "stream": "stream", "hybrid": None}.get(in_info.get("xref"))
            if want and js["xref"] != want:
                P.append(f"xref {js['xref']} after update of a {in_info.get('xref')} file")
            if js["encrypted"]:
                P.append("output reported encrypted")
    return P


def run_info(mulu, path):
    try:
        p = subprocess.run([str(mulu), "info", str(path)], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    if p.returncode != 0:
        return None, f"exit {p.returncode}: {p.stderr.decode(errors='replace').strip()[:160]}"
    try:
        return json.loads(p.stdout.decode("utf-8")), None
    except json.JSONDecodeError as e:
        return None, f"non-JSON: {e}"


def evaluate(cases, mulu=None, jobs=None, log=print):
    """Run every reader/check for every case in parallel and fill the result columns."""
    jobs = jobs or min(16, (os.cpu_count() or 8))
    futures = {}
    pool = cf.ThreadPoolExecutor(max_workers=jobs)

    def sub(key, fn, *a):
        if key not in futures:
            futures[key] = pool.submit(fn, *a)
        return key

    for c in cases:
        if c.kind in ("refuse", "samepath"):
            if mulu and c.kind == "refuse":
                sub(("info", str(c.inp)), run_info, mulu, c.inp)
            continue
        if c.exit != 0 or not c.out.exists():
            continue
        for r in READERS:
            sub((r, str(c.out)), run_reader, r, c.out, mulu)
            sub((r, str(c.inp)), run_reader, r, c.inp, mulu)
        if mulu:
            sub(("mulu", str(c.out)), run_reader, "mulu", c.out, mulu)
            sub(("info", str(c.inp)), run_info, mulu, c.inp)
            sub(("info", str(c.out)), run_info, mulu, c.out)
        sub(("check", str(c.inp)), run_json, py_worker("check", c.inp))
        sub(("check", str(c.out)), run_json, py_worker("check", c.out))
        exp_file = c.out.with_suffix(".expected.json")
        exp_file.write_text(json.dumps(c.expected, ensure_ascii=False), encoding="utf-8")
        sub(("spec", str(c.out)), run_json, py_worker("spec", c.inp, c.out, exp_file, json.dumps(c.opts)))
        sub(("struct", str(c.out)), run_json, py_worker("struct", c.inp, c.out, len(c.expected)))
    total = len(futures)
    done = 0
    for _ in cf.as_completed(list(futures.values())):
        done += 1
        if log and (done % 20 == 0 or done == total):
            log(f"[verify] readers/checks {done}/{total}")
    pool.shutdown()
    R = {k: f.result() for k, f in futures.items()}

    for c in cases:
        if c.kind == "refuse":
            _eval_refusal(c, R, mulu)
            continue
        if c.kind == "samepath":
            continue  # evaluated at apply time
        _eval_apply(c, R, mulu)
    return R


def _check_rss(c: Case):
    lim = c.opts.get("max_rss_mb")
    if lim and c.max_rss is not None and c.max_rss > lim * 1024 * 1024:
        c.set("ms", False, f"{c.max_rss >> 20}MB", f"peak RSS {c.max_rss >> 20} MB > limit {lim} MB")


def _eval_refusal(c: Case, R, mulu):
    err = c.stderr.strip()
    ok_exit = c.exit == 2
    ok_err = bool(err) and len(err.split("\n")) == 1
    c.set("exit", ok_exit and ok_err, str(c.exit),
          f"expected exit 2 with a one-line stderr, got exit {c.exit}, stderr {err[:200]!r}")
    want_msg = c.opts.get("expect_stderr")
    if ok_exit and want_msg and not re.search(want_msg, err):
        c.set("exit", False, "msg", f"refusal message {err[:200]!r} does not match /{want_msg}/")
    no_out = not c.out.exists()
    c.set("prefix", no_out and c.facts.get("input_unchanged", False), "no-out" if no_out else "OUT!",
          ("output file was created on refusal" if not no_out else "input file was modified"))
    c.appended = None
    if c.perf_limit_ms is None:
        c.set("ms", "-", f"{c.ms:.0f}" if c.ms is not None else "-")
    _check_rss(c)
    if mulu:
        js, e = R.get(("info", str(c.inp)), (None, "not run"))
        f = c.facts
        can_open = "pages" in f and not f.get("encrypted")
        want_info = c.opts.get("expect_info")  # "error": `mulu info` must refuse too
        if want_info == "error":
            c.set("info", js is None, "refused" if js is None else "bad",
                  f"`mulu info` should fail like apply does, but printed {js}")
        elif js is None:
            c.set("info", False if can_open else True, "err" if can_open else "refused",
                  f"`mulu info` failed on an openable PDF: {e}")
        else:
            probs = check_info(js, f, is_output=False)
            if f.get("encrypted") and not js.get("encrypted"):
                probs.append("encrypted file reported encrypted=false")
            c.set("info", not probs, "ok" if not probs else "bad", "; ".join(probs))


WARNING_HINTS = {
    "parsing for Object Streams":
        "pypdf threw away the xref and rebuilt it by scanning. Its 'xref not zero-indexed' heuristic fires when the "
        "NEWEST classic xref's first subsection does not start at object 0; it then re-verifies every entry of every "
        "revision, and any odd original entry (Quartz writes an in-use entry with offset 0) forces a full rebuild. "
        "Fix: start the update's classic xref with the subsection '0 1' / '0000000000 65535 f ' (as Acrobat does).",
    "Indexing all PDF objects":
        "pdf.js could not use the xref and re-indexed the whole file: some offset/startxref in the update is wrong.",
    "incorrect startxref pointer": "pypdf: the final startxref does not point at 'xref' or 'N G obj'.",
}


def _eval_apply(c: Case, R, mulu):
    # exit
    ok = c.exit == 0 and c.out.exists()
    c.set("exit", ok, str(c.exit), f"apply failed: exit {c.exit}, stderr {c.stderr.strip()[:300]!r}"
          if c.exit != 0 else "exit 0 but no output file")
    c.set("ms", True if not c.perf_limit_ms else (c.ms_min is not None and c.ms_min < c.perf_limit_ms),
          f"{c.ms:.0f}" if c.ms is not None else "-",
          f"best of 3 = {c.ms_min:.0f} ms >= limit {c.perf_limit_ms} ms" if c.perf_limit_ms and c.ms_min else None)
    if not ok:
        for col in ["prefix", "spec", *READERS, "self", "check", "pages", "struct", "info"]:
            c.set(col, "-", "-")
        return
    _check_rss(c)
    A = c.inp.read_bytes()
    B = c.out.read_bytes()
    junk_prefix = pdfraw.header_offset(A) > 0
    # Readers a regression fixture declares unable to read the INPUT. The claim is
    # verified: the reader must fail on the input or see a different page count there.
    exempt = {}
    for r, why in c.opts.get("input_unreadable", {}).items():
        base = R.get((r, str(c.facts.get("original_input", c.inp))), {})
        if base.get("ok") and base.get("pages") == c.facts.get("pages"):
            c.set(r, False, "exempt?", f"{r} is declared unable to read the input ({why}), but it reads it "
                                       f"({base.get('pages')} pages)")
        else:
            exempt[r] = why
    pre = B.startswith(A) and len(B) > len(A)
    c.appended = len(B) - len(A)
    unchanged = c.facts.get("input_unchanged", True)
    c.set("prefix", pre and unchanged, "ok" if pre and unchanged else "FAIL",
          "input file was modified" if not unchanged else
          ("output does not start with the input bytes" if not B.startswith(A) else "nothing appended"))
    # spec
    s = R.get(("spec", str(c.out)), {})
    if s.get("ok") is None and "na" in s:
        allowed = "spec" in c.opts.get("allow_na", [])
        c.set("spec", "n/a" if allowed else False, "n/a", f"spec: {s['na']}")
        if allowed:
            c.remarks.append(f"spec n/a: {s['na'][:160]}")
    else:
        c.set("spec", bool(s.get("ok")), "ok" if s.get("ok") else f"{len(s.get('problems', [])) or 1}✗",
              "; ".join(s.get("problems", [])[:6]) or s.get("error"))
    # readers
    for r in READERS:
        if r in c.cols:
            continue  # an unjustified exemption, already failed
        res = R.get((r, str(c.out)), {})
        base = R.get((r, str(c.inp)), {})
        if r in exempt:
            c.set(r, "n/a", "n/a*")
            c.remarks.append(f"{r} n/a: {exempt[r]}")
            continue
        if not res.get("ok"):
            c.set(r, False, "err", f"{r} could not read output: {res.get('error')}")
            continue
        if not outline_eq(res.get("outline"), c.expected):
            c.set(r, False, "diff", f"{r}: {first_diff(res.get('outline'), c.expected)}")
            continue
        if not base.get("ok"):
            # The reader fails on the input, so its warnings have no baseline; the output
            # must still give exactly the expected outline (checked above).
            c.set(r, True, "ok*")
            continue

        def norm(ws, path):
            out = {norm_warn(w, path) for w in ws}
            if r == "pypdf" and junk_prefix:
                dropped = {m.group(1) for w in out for m in [re.match(r"Ignoring wrong pointing object (\d+ \d+)", w)]
                           if m}
                out = {x for x in (norm_warn_junk_prefix(w) for w in out) if x is not None
                       and not any(x == f"Object {d} found" for d in dropped)}
            return out

        new_w = sorted(norm(res.get("warnings", []), c.out) - norm(base.get("warnings", []), c.inp))
        if new_w:
            hints = [h for k, h in WARNING_HINTS.items() if any(k in w for w in new_w)]
            c.set(r, False, "warn", f"{r} emitted new warnings on the output: {new_w[:3]}"
                  + (f" -- hint: {hints[0]}" if hints else ""))
            continue
        c.set(r, True, "ok")
    if mulu:
        res = R.get(("mulu", str(c.out)), {})
        if not res.get("ok"):
            c.set("self", False, "err", f"dump-outline: {res.get('error')}")
        elif not outline_eq(res.get("outline"), c.expected):
            c.set("self", False, "diff", f"dump-outline: {first_diff(res.get('outline'), c.expected)}")
        else:
            c.set("self", True, "ok")
    else:
        c.set("self", "-", "n/a")
    # check()
    ci, co = R.get(("check", str(c.inp)), {}), R.get(("check", str(c.out)), {})
    ci_err = str(ci.get("error", ""))[:120]
    check_na = False
    if not ci.get("ok") and co.get("ok"):
        ci = {"ok": True, "problems": [], "warnings": []}
        if co.get("problems") or co.get("warnings"):
            # qpdf cannot open the input at all, so the output's findings have no baseline
            check_na = "check" in c.opts.get("allow_na", [])
    if check_na:
        c.set("check", "n/a", "n/a")
        c.remarks.append(f"check n/a: qpdf cannot open the input ({ci_err}); output: "
                         f"{(co.get('problems', []) + co.get('warnings', []))[:2]}")
    elif not co.get("ok"):
        c.set("check", False, "err", f"check() failed on output: {co.get('error')}")
    else:
        pin = {norm_warn(x, c.inp) for x in ci.get("problems", []) + ci.get("warnings", [])}
        pout = {norm_warn(x, c.out) for x in co.get("problems", []) + co.get("warnings", [])}
        new = sorted(pout - pin)
        c.set("check", not new, "ok" if not new else f"+{len(new)}", f"new qpdf problems: {new[:4]}")
    # (d) pages
    pk_in, pk_out = R.get(("pdfkit", str(c.inp)), {}), R.get(("pdfkit", str(c.out)), {})
    pdfium_in = R.get(("pdfium", str(c.inp)), {})
    P = []
    want_pages = c.facts.get("pages")
    for r in READERS:
        res = R.get((r, str(c.out)), {})
        if r not in exempt and res.get("ok") and want_pages is not None and res.get("pages") != want_pages:
            P.append(f"{r} sees {res.get('pages')} pages, want {want_pages}")

    def squash(t):
        return re.sub(r"\s+", "", t or "")

    if "pdfkit" in exempt:
        pass
    elif pk_in.get("ok") and pk_out.get("ok"):
        if pk_in.get("pages") != pk_out.get("pages"):
            P.append("PDFKit pages changed")
        for which in ("first", "last"):
            if (pk_in.get(f"{which}_text"), pk_in.get(f"{which}_render")) == \
                    (pk_out.get(f"{which}_text"), pk_out.get(f"{which}_render")):
                continue
            # A page PDFKit misread in the damaged input (its text differs from what
            # PDFium extracts there) may change, but only into what PDFium read.
            ref = pdfium_in.get(f"{which}_text") if pdfium_in.get("ok") else None
            if ref is not None and squash(pk_in.get(f"{which}_text")) != squash(ref) \
                    and squash(pk_out.get(f"{which}_text")) == squash(ref):
                c.remarks.append(f"PDFKit misread the input's {which} page; the output matches PDFium's reading")
                continue
            for k in ("text", "render"):
                if pk_in.get(f"{which}_{k}") != pk_out.get(f"{which}_{k}"):
                    P.append(f"PDFKit {which}_{k} changed")
    elif not pk_out.get("ok"):
        P.append("PDFKit cannot open output")
    c.set("pages", not P, "ok" if not P else "FAIL", "; ".join(P))
    # struct
    st = R.get(("struct", str(c.out)), {})
    if st.get("ok") is None and "na" in st:
        allowed = "struct" in c.opts.get("allow_na", [])
        c.set("struct", "n/a" if allowed else False, "n/a", f"struct: {st['na']}")
        if allowed:
            c.remarks.append(f"struct n/a: {st['na'][:160]}")
    else:
        c.set("struct", bool(st.get("ok")), "ok" if st.get("ok") else f"{len(st.get('problems', [])) or 1}✗",
              "; ".join(st.get("problems", [])[:6]) or st.get("error"))
    # info
    if mulu:
        ji, ei = R.get(("info", str(c.inp)), (None, "not run"))
        jo, eo = R.get(("info", str(c.out)), (None, "not run"))
        probs = []
        if ji is None:
            probs.append(f"info(input): {ei}")
        else:
            probs += [f"in: {p}" for p in check_info(ji, c.facts if c.kind != "reapply" else
                                                      {"pages": c.facts.get("pages")}, is_output=False)]
        if jo is None:
            probs.append(f"info(output): {eo}")
        else:
            probs += [f"out: {p}" for p in check_info(jo, {"pages": c.facts.get("pages")}, is_output=True,
                                                       in_info=ji, n_expected=len(c.expected), out_size=len(B),
                                                       complete=bool(c.opts.get("complete_xref")))]
        c.set("info", not probs, "ok" if not probs else "bad", "; ".join(probs[:5]))
    else:
        c.set("info", "-", "n/a")


def samepath_cases(backend, gen: Path, out: Path):
    """in == out must be refused (and the input must never be touched)."""
    src = gen / "text_classic_cjk.pdf"
    toc = gen / "text_classic_cjk.toc.txt"
    if not src.exists():
        return []
    d = out / "samepath"
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    tgt = d / "same.pdf"
    variants = [("same path", tgt, tgt, True),
                ("alt spelling", tgt, d / ".." / "samepath" / "." / "same.pdf", True),
                ("symlink out", tgt, d / "link.pdf", False)]
    res = []
    for label, inp, outp, must_refuse in variants:
        shutil.copyfile(src, tgt)
        if label == "symlink out":
            (d / "link.pdf").unlink(missing_ok=True)
            os.symlink("same.pdf", d / "link.pdf")
        before = sha(tgt)
        cmd = list(backend) + ["apply", str(inp), str(toc), "-o", str(outp)]
        t0 = time.perf_counter()
        p = subprocess.run(cmd, capture_output=True, timeout=120)
        ms = (time.perf_counter() - t0) * 1000
        after = sha(tgt)
        c = Case(name="samepath", label=f"in==out: {label}", kind="samepath", inp=inp, toc=toc, offset=0,
                 expected=[], out=outp)
        c.exit, c.stderr, c.ms = p.returncode, p.stderr.decode(errors="replace"), ms
        unchanged = before == after
        if must_refuse:
            ok = p.returncode == 2 and bool(c.stderr.strip())
            c.set("exit", ok, str(p.returncode), f"expected exit 2 + stderr, got {p.returncode} "
                                                  f"{c.stderr.strip()[:120]!r}")
        else:
            c.set("exit", p.returncode in (0, 2), str(p.returncode),
                  f"unexpected exit {p.returncode}: {c.stderr.strip()[:120]!r}")
            c.notes = "refused" if p.returncode == 2 else "wrote through a new file (symlink replaced), input intact"
        c.set("prefix", unchanged, "in-intact" if unchanged else "IN-MODIFIED",
              "the INPUT file was modified through the output path")
        c.set("ms", True, f"{ms:.0f}")
        res.append(c)
    return res


# ---------------------------------------------------------------------------
# table
# ---------------------------------------------------------------------------

COLS = [("exit", 5), ("prefix", 9), ("+bytes", 8), ("spec", 5), ("pdfkit", 6), ("qpdf", 5), ("pdfium", 6),
        ("pypdf", 5), ("pdfjs", 5), ("self", 5), ("check", 5), ("pages", 5), ("struct", 6), ("info", 5),
        ("ms", 6)]


def _color(s, st, tty):
    if not tty:
        return s
    if st == "FAIL":
        return f"\033[31;1m{s}\033[0m"
    if st == "ok":
        return f"\033[32m{s}\033[0m"
    return f"\033[2m{s}\033[0m"


def print_table(cases, skipped, title, out=sys.stdout):
    tty = out.isatty() and not os.environ.get("NO_COLOR")
    namew = max([len(c.label) for c in cases] + [len(s[0]) for s in skipped] + [22]) + 1
    hdr = f"{'fixture':<{namew}}" + "".join(f" {n:>{w}}" for n, w in COLS) + "  result"
    print("\n" + title, file=out)
    print(hdr, file=out)
    print("-" * len(hdr), file=out)
    for c in cases:
        row = f"{c.label:<{namew}}"
        for n, w in COLS:
            if n == "+bytes":
                txt = f"{c.appended:,}" if c.appended is not None else "-"
                row += " " + f"{txt:>{w}}"
                continue
            st, short = c.cols.get(n, ("-", "-"))
            txt = short if n in ("exit", "ms", "prefix") or st != "ok" else "ok"
            if n == "ms" and c.perf_limit_ms and st == "ok":
                txt = f"{c.ms:.0f}"
            txt = (txt or st)[:w]
            row += " " + _color(f"{txt:>{w}}", st, tty)
        res = "PASS" if c.passed else "FAIL"
        if c.expect_fail:
            res = "caught" if not c.passed else "MISSED"
        row += "  " + _color(res, "ok" if res in ("PASS", "caught") else "FAIL", tty)
        print(row, file=out)
    for name, st, note in skipped:
        print(f"{name:<{namew}} " + _color(f"{st}: {note}", "-", tty), file=out)
    print("-" * len(hdr), file=out)


def print_details(cases, out=sys.stdout):
    notes = [c for c in cases if c.remarks]
    if notes:
        print("\nAccepted with a verified reason:", file=out)
        for c in notes:
            for rm in c.remarks:
                print(f"  {c.label}: {rm}", file=out)
    fails = [c for c in cases if not c.passed and not c.expect_fail]
    if not fails:
        return
    print("\nFailure details:", file=out)
    for c in fails:
        for d in c.details:
            print(f"  {c.label}: {d}", file=out)


# ---------------------------------------------------------------------------
# PDFKit resave growth
# ---------------------------------------------------------------------------

def resave_growth(gen: Path, out: Path, appended: dict | None = None):
    rows = []
    d = out / "resave"
    d.mkdir(parents=True, exist_ok=True)
    for name in ("scan_g4", "scan_jpeg", "text_classic_cjk"):
        src = gen / f"{name}.pdf"
        if not src.exists():
            continue
        r = run_json([BIN / "pdfkit_resave", src, d / f"{name}.pdfkit.pdf"])
        rows.append((name, r, (appended or {}).get(name)))
    return rows


def print_growth(rows, out=sys.stdout):
    if not rows:
        return
    print("\nPDFKit rewrite (PDFDocument.write) vs mulu incremental update:", file=out)
    h = f"{'fixture':<18} {'input':>12} {'PDFKit resave':>14} {'growth':>8} {'resave s':>9} {'mulu +bytes':>12} " \
        f"{'mulu growth':>11}"
    print(h, file=out)
    print("-" * len(h), file=out)
    for name, r, app in rows:
        if not r.get("ok"):
            print(f"{name:<18} resave failed: {r.get('error')}", file=out)
            continue
        a, b = r["in_size"], r["out_size"]
        mg = f"{app / a * 100:+.2f}%" if app is not None else "-"
        print(f"{name:<18} {a:>12,} {b:>14,} {r['growth_pct']:>+7.1f}% {r['seconds']:>9.2f} "
              f"{(f'{app:,}' if app is not None else '-'):>12} {mg:>11}", file=out)


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_run_all(args, backend=None, mulu_extras=True, title=None, out_dir=None):
    gen = Path(args.gen)
    out = Path(out_dir or args.out)
    only = {x for x in (args.only or "").split(",") if x}
    if not (gen / "manifest.json").exists():
        print(f"[verify] no fixtures at {gen} - run tools/fixtures/make_fixtures.py first", file=sys.stderr)
        return 1
    ensure_tools()
    if backend is None:
        mulu = Path(args.mulu).resolve()
        if not mulu.exists():
            print(f"[verify] mulu binary not found: {mulu}", file=sys.stderr)
            return 1
        backend = [str(mulu)]
        mulu_path = mulu
    else:
        mulu_path = None
    if not mulu_extras:
        mulu_path = None
    out.mkdir(parents=True, exist_ok=True)
    cases, skipped = load_cases(gen, out, only)
    print(f"[verify] {len(cases)} cases ({sum(c.kind == 'apply' for c in cases)} apply, "
          f"{sum(c.kind == 'reapply' for c in cases)} re-apply, {sum(c.kind == 'refuse' for c in cases)} refuse); "
          f"backend: {' '.join(backend)[-80:]}", flush=True)
    # warm-up: the first exec of a freshly linked binary pays macOS code-signing/dyld costs (~0.5 s)
    for _ in range(2):
        subprocess.run(list(backend) + ["info", str(gen / "text_classic_cjk.pdf")], capture_output=True, timeout=60)
    for c in cases:  # sequential: timings are not polluted by parallel readers
        if c.kind == "reapply":
            base = next(x for x in cases if x.name == c.name and x.kind == "apply")
            if base.exit != 0 or not base.out.exists():
                c.exit, c.stderr = None, "first apply failed; re-apply skipped"
                continue
        if mulu_path is None and c.perf_limit_ms:
            c.perf_limit_ms = None
            c.notes += " (perf limit not enforced for the reference backend)"
        do_apply(backend, c)
    same = samepath_cases(backend, gen, out) if not only or "samepath" in only or "text_classic_cjk" in only else []
    evaluate(cases, mulu=mulu_path, jobs=args.jobs)
    # re-apply: first output must be a byte prefix of the second, which the prefix column shows (inp = out1)
    allc = cases + same
    print_table(allc, skipped, title or "mulu verification")
    print_details(allc)
    appended = {c.name: c.appended for c in cases if c.kind == "apply"}
    growth = resave_growth(gen, out, appended) if not only or only & {"scan_g4", "scan_jpeg",
                                                                          "text_classic_cjk"} else []
    print_growth(growth)
    npass = sum(c.passed for c in allc)
    print(f"\n{npass}/{len(allc)} rows passed" + (f", {len(skipped)} fixture(s) skipped" if skipped else ""))
    if args.json:
        rep = {"cases": [{"label": c.label, "kind": c.kind, "passed": c.passed, "exit": c.exit, "ms": c.ms,
                          "ms_min": c.ms_min, "appended": c.appended,
                          "cols": {k: v[0] for k, v in c.cols.items()}, "details": c.details} for c in allc],
               "skipped": skipped,
               "growth": [{"fixture": n, **r, "mulu_appended": a} for n, r, a in growth]}
        Path(args.json).write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"report: {args.json}")
    return 0 if npass == len(allc) else 1


def cmd_readers(args):
    ensure_tools()
    for p in args.pdfs:
        print(f"== {p}")
        for r in READERS + (["mulu"] if args.mulu else []):
            res = run_reader(r, Path(p), args.mulu)
            if not res.get("ok"):
                print(f"  {r:<7} ERROR {res.get('error')}")
                continue
            print(f"  {r:<7} pages={res.get('pages', '-')} items={len(res.get('outline', []))} "
                  f"warnings={res.get('warnings', [])[:2]}")
            if args.verbose:
                for it in res["outline"]:
                    print(f"          {'  ' * it['level']}{it['title']}  -> {it['page_index']}")
    return 0


def cmd_growth(args):
    ensure_tools()
    print_growth(resave_growth(Path(args.gen), Path(args.out)))
    return 0


# ---------------------------------------------------------------------------
# selftest: prove the harness without mulu
# ---------------------------------------------------------------------------

def selftest(args):
    gen = Path(args.gen)
    base_out = ROOT / "Fixtures" / "selftest"
    if base_out.exists():
        shutil.rmtree(base_out)
    base_out.mkdir(parents=True)
    ensure_tools()
    manifest = json.loads((gen / "manifest.json").read_text(encoding="utf-8"))
    only = {x for x in (args.only or "").split(",") if x}
    ok_all = True

    # ---- 1. every reader on every ORIGINAL fixture ----------------------------------------------
    print("\n[selftest 1/3] every reader on the ORIGINAL fixtures (no mulu involved)")
    futs = {}
    with cf.ThreadPoolExecutor(max_workers=args.jobs or 12) as pool:
        for name, m in manifest["fixtures"].items():
            if m.get("status") != "ok" or (only and name not in only):
                continue
            pdf = gen / f"{name}.pdf"
            for r in READERS:
                futs[(name, r)] = pool.submit(run_reader, r, pdf)
            futs[(name, "check")] = pool.submit(run_json, py_worker("check", pdf))
    names = sorted({k[0] for k in futs}, key=list(manifest["fixtures"]).index)
    h = f"{'fixture':<20} {'pages':>5} " + " ".join(f"{r:>11}" for r in READERS) + f" {'check()':>8}  result"
    print(h)
    print("-" * len(h))
    for name in names:
        m = manifest["fixtures"][name]
        pages = m["facts"].get("pages")
        refuse = m.get("expect") == "refuse"
        pre = gen / f"{name}.preexisting.json"
        want = json.loads(pre.read_text(encoding="utf-8")) if pre.exists() else []
        cells, good = [], True
        for r in READERS:
            res = futs[(name, r)].result()
            if not res.get("ok"):
                cells.append("err")
                if not refuse:
                    good = False
                    print(f"   {name}/{r}: {res.get('error')}")
                continue
            okp = res.get("pages") == pages
            oko = outline_eq(res.get("outline"), want)
            if not refuse and not (okp and oko):
                good = False
                print(f"   {name}/{r}: pages {res.get('pages')} (want {pages}); outline "
                      f"{first_diff(res.get('outline'), want) or 'ok'}")
            cells.append(f"{res.get('pages')}p/{len(res.get('outline', []))}i"
                         + ("/w" if res.get("warnings") else ""))
        ch = futs[(name, "check")].result()
        cells.append("ok" if ch.get("ok") and not ch.get("problems") else
                     ("err" if not ch.get("ok") else f"{len(ch['problems'])}p"))
        verdict = "n/a (refusal fixture)" if refuse else ("PASS" if good else "FAIL")
        ok_all &= good or refuse
        print(f"{name:<20} {pages if pages is not None else '-':>5} " + " ".join(f"{x:>11}" for x in cells[:5])
              + f" {cells[5]:>8}  {verdict}")
    print("   cells: <pages>p/<outline items>i[/w = reader emitted warnings]; existing_outline must show 6 items")

    # ---- 2. full pipeline with the reference writer -------------------------------------------
    print("\n[selftest 2/3] full verification pipeline using the Python REFERENCE writer (tools/verify/ref_apply.py)")
    args.out = str(base_out / "ref")
    rc = cmd_run_all(args, backend=[sys.executable, str(REF_APPLY)], mulu_extras=False,
                     title="reference writer through the full harness (must be all PASS)", out_dir=args.out)
    ok_all &= rc == 0

    # ---- 3. negative controls -----------------------------------------------------------------
    print("\n[selftest 3/3] negative controls: deliberately broken outputs must be CAUGHT")
    nc = negative_controls(gen, base_out / "neg", args)
    ok_all &= all(not c.passed for c in nc)
    print("\nSELFTEST " + ("PASSED" if ok_all else "FAILED"))
    return 0 if ok_all else 1


def _mutate(path: Path, fn):
    b = bytearray(path.read_bytes())
    fn(b)
    path.write_bytes(bytes(b))


def negative_controls(gen: Path, out: Path, args):
    out.mkdir(parents=True, exist_ok=True)
    ref = [sys.executable, str(REF_APPLY)]
    manifest = json.loads((gen / "manifest.json").read_text(encoding="utf-8"))

    def mk(label, fixture, mutate=None, extra=(), toc_edit=None):
        m = manifest["fixtures"][fixture]
        c = Case(name=fixture, label=label, kind="negative", inp=gen / f"{fixture}.pdf",
                 toc=gen / f"{fixture}.toc.txt", offset=read_int(gen / f"{fixture}.offset"),
                 expected=json.loads((gen / f"{fixture}.expected.json").read_text(encoding="utf-8")),
                 out=out / f"{label.replace(' ', '_').replace('/', '_')}.pdf", facts=dict(m["facts"]))
        c.expect_fail = True
        if toc_edit:
            t = out / f"{c.out.stem}.toc.txt"
            t.write_bytes(toc_edit(c.toc.read_bytes()))
            c.toc = t
        c.extra_cmd = list(extra)
        do_apply(ref, c)
        if mutate and c.out.exists():
            _mutate(c.out, lambda b: mutate(b, len(c.inp.read_bytes())))
        return c

    def xref_off_plus1(b, base):
        sx = pdfraw.last_startxref(bytes(b))
        if b[sx:sx + 4] == b"xref":
            m = re.compile(rb"(\d{10}) (\d{5}) n").search(b, sx)
            v = int(m.group(1)) + 1
            b[m.start(1):m.end(1)] = f"{v:010d}".encode()
        else:  # binary W [1 8 2] rows in our reference xref stream
            o = pdfraw.parse_indirect(bytes(b), sx)
            p = o.value.data_start + 1
            v = int.from_bytes(b[p:p + 8], "big") + 1
            b[p:p + 8] = v.to_bytes(8, "big")

    def flip_prefix(b, base):
        i = base // 2
        while b[i] in b"\r\n":
            i += 1
        b[i] ^= 0x01

    def bad_count(b, base):
        i = b.find(b"/Type /Outlines", base)
        j = b.find(b"/Count ", i) + 7
        k = j
        while chr(b[k]).isdigit():
            k += 1
        v = int(b[j:k]) - 1
        s = str(v).rjust(k - j)
        b[j:k] = s.encode()

    def stale_startxref(b, base):
        i = bytes(b).rfind(b"startxref")
        orig = pdfraw.last_startxref(bytes(b[:base]))
        del b[i:]
        b += b"startxref\n" + str(orig).encode() + b"\n%%EOF\n"

    def drop_catalog_key(b, base):
        i = bytes(b).rfind(b"/Lang", base)
        b[i:i + 5] = b"/Lanx"

    def no_eol_sep(b, base):
        assert b[base:base + 1] == b"\n"
        b[base] = 0x20  # update glued to '%%EOF' with a space instead of an EOL

    def tamper_page1(b, base):
        import io

        import pikepdf
        with pikepdf.open(io.BytesIO(bytes(b))) as pdf:
            cref = pdf.pages[0].obj.Contents
            num, gen = (cref[0] if isinstance(cref, pikepdf.Array) else cref).objgen
            root = pdf.Root.objgen
            size = int(pdf.trailer.Size)
        prev = pdfraw.last_startxref(bytes(b))
        content = b"BT /F1 24 Tf 72 700 Td (tampered page) Tj ET"
        off = len(b)
        b += f"{num} {gen} obj\n<< /Length {len(content)} >>\nstream\n".encode() + content + b"\nendstream\nendobj\n"
        x = len(b)
        b += f"xref\n0 1\n0000000000 65535 f \n{num} 1\n{off:010d} {gen:05d} n \n".encode()
        b += f"trailer\n<< /Size {size} /Root {root[0]} {root[1]} R /Prev {prev} >>\nstartxref\n{x}\n%%EOF\n".encode()

    def page_shift(t):
        lines = t.decode("utf-8").split("\n")
        for idx in range(len(lines) - 1, -1, -1):
            s = lines[idx].rstrip()
            if s and not s.startswith("#"):
                head, _, num = s.rpartition(" ")
                lines[idx] = f"{head} {int(num) - 1}"
                break
        return "\n".join(lines).encode("utf-8")

    cases = [
        mk("NC xref offset +1 (classic)", "text_classic_cjk", xref_off_plus1),
        mk("NC xref offset +1 (stream)", "text_objstm", xref_off_plus1),
        mk("NC prefix byte flipped", "scan_jpeg", flip_prefix),
        mk("NC wrong page (last item -1)", "text_classic_cjk", toc_edit=page_shift),
        mk("NC /Count off by one", "text_objstm", bad_count),
        mk("NC literal (non-hex) titles", "text_classic_cjk", extra=["--literal-titles"]),
        mk("NC stale startxref", "text_classic_cjk", stale_startxref),
        mk("NC catalog key lost (/Lang)", "multirev", drop_catalog_key),
        mk("NC no EOL before update", "eof_no_eol", no_eol_sep),
        mk("NC page 1 content tampered", "text_classic_cjk", tamper_page1),
    ]
    # refusal negative control: a "writer" that happily writes for an encrypted file
    enc = Case(name="encrypted", label="NC refusal ignored", kind="refuse", inp=gen / "encrypted.pdf",
               toc=gen / "encrypted.toc.txt", offset=0, expected=[], out=out / "NC_refusal_ignored.pdf",
               facts=dict(manifest["fixtures"]["encrypted"]["facts"]))
    enc.expect_fail = True
    shutil.copyfile(enc.inp, enc.out)
    enc.exit, enc.stderr, enc.ms, enc.facts["input_unchanged"] = 0, "", 1.0, True
    cases.append(enc)
    evaluate(cases, mulu=None, jobs=args.jobs, log=None)
    print_table(cases, [], "negative controls (every row must say 'caught')")
    for c in cases:
        if c.passed:
            print(f"   MISSED: {c.label}")
        else:
            flagged = [k for k, (st, _) in c.cols.items() if st == "FAIL"]
            print(f"   {c.label:<32} caught by: {', '.join(flagged)}")
    return cases


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "_worker":
        return worker_main(sys.argv[2:])
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--gen", default=str(GEN), help="fixture directory (default Fixtures/generated)")
        p.add_argument("--out", default=str(OUTDIR), help="output directory (default Fixtures/out)")
        p.add_argument("--only", default="", help="comma-separated fixture names")
        p.add_argument("--jobs", type=int, default=0, help="parallel reader processes")
        p.add_argument("--json", default="", help="also write a JSON report here")

    p = sp.add_parser("run-all", help="apply mulu to every fixture and verify")
    common(p)
    p.add_argument("--mulu", required=True, help="path to the mulu binary")
    p = sp.add_parser("selftest", help="prove the harness works (readers, reference writer, negative controls)")
    common(p)
    p = sp.add_parser("readers", help="print every reader's view of PDFs")
    p.add_argument("pdfs", nargs="+")
    p.add_argument("--mulu", default=None)
    p.add_argument("-v", "--verbose", action="store_true")
    p = sp.add_parser("resave-growth", help="PDFKit rewrite growth table")
    common(p)
    args = ap.parse_args()
    if args.cmd == "run-all":
        return cmd_run_all(args)
    if args.cmd == "selftest":
        return selftest(args)
    if args.cmd == "readers":
        return cmd_readers(args)
    if args.cmd == "resave-growth":
        return cmd_growth(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
