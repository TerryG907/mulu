# /// script
# requires-python = ">=3.12"
# dependencies = ["pypdfium2>=4.30"]
# ///
"""Build an independent reference TOC for each book from Internet Archive's ABBYY text layer.
Outputs ref/<id>.json: toc_pages, entries [{title, printed_page, physical_page_ref, found_by}], offset_votes."""
import json, re, sys, unicodedata
from collections import Counter
from pathlib import Path
import pypdfium2 as pdfium

import argparse
ap = argparse.ArgumentParser(); ap.add_argument("--books", required=True); ap.add_argument("--out", required=True); ARGS = ap.parse_args()
HERE = Path(__file__).resolve().parent
ROMAN = re.compile(r"^(?=[ivxlc]+$)c{0,3}(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})$", re.I)
TOC_HEAD = re.compile(r"(table\s+of\s+)?contents|^\s*index\s*$|目\s*[录錄次]", re.I)

def norm(s):
    s = unicodedata.normalize("NFKC", s).lower()
    return re.sub(r"[^0-9a-z一-鿿]+", " ", s).strip()

def lines_with_boxes(page):
    tp = page.get_textpage()
    segs = []
    for i in range(tp.count_rects()):
        l, b, r, t = tp.get_rect(i)
        txt = tp.get_text_bounded(l, b, r, t).strip()
        if txt:
            segs.append([l, b, r, t, txt])
    segs.sort(key=lambda s: (-(s[1] + s[3]) / 2, s[0]))
    lines = []
    for s in segs:
        yc, h = (s[1] + s[3]) / 2, max(1.0, s[3] - s[1])
        for ln in lines:
            if abs(ln["yc"] - yc) < 0.45 * max(h, ln["h"]):
                ln["segs"].append(s); break
        else:
            lines.append({"yc": yc, "h": h, "segs": [s]})
    out = []
    for ln in sorted(lines, key=lambda x: -x["yc"]):
        segs = sorted(ln["segs"], key=lambda s: s[0])
        out.append({"x0": segs[0][0], "text": " ".join(s[4] for s in segs)})
    return out

PAGE_TAIL = re.compile(r"^(.*?)[\s.·…_\-—]*\b(\d{1,4}|[ivxlc]{1,7})\s*$", re.I)

def parse_toc_lines(lines):
    entries, pending = [], ""
    for ln in lines:
        t = re.sub(r"\s+", " ", ln["text"]).strip()
        if not t or TOC_HEAD.search(t) and len(t) < 30 or re.fullmatch(r"(page|pages|chapter|chap\.?)", t, re.I):
            continue
        t = re.sub(r"^(page)\s+", "", t, flags=re.I)
        m = PAGE_TAIL.match(t)
        if m and (m.group(2).isdigit() or ROMAN.match(m.group(2))) and len(m.group(1).strip(" .·…")) >= 2:
            title = (pending + " " + m.group(1)).strip(" .·…-—")
            entries.append({"title": re.sub(r"\s+", " ", title), "printed_page": m.group(2), "x0": round(ln["x0"], 1)})
            pending = ""
        else:
            pending = (pending + " " + t).strip() if len(pending) < 200 else t
    return entries

def find_toc_pages(pdf):
    n = len(pdf); hits = []
    for p in range(min(40, n)):
        txt = pdf[p].get_textpage().get_text_range()
        head = "\n".join(txt.splitlines()[:6])
        if TOC_HEAD.search(head) and not re.search(r"\bindex\b", head, re.I):
            hits.append(p)
    if not hits:
        return []
    pages = [hits[0]]
    for p in range(hits[0] + 1, min(hits[0] + 8, n)):
        lines = lines_with_boxes(pdf[p])
        numeric_tail = sum(1 for ln in lines if PAGE_TAIL.match(ln["text"].strip()))
        if numeric_tail >= max(3, 0.35 * len(lines)) or re.search(r"contents", " ".join(l["text"] for l in lines[:2]), re.I):
            pages.append(p)
        else:
            break
    return pages

def locate(pdf, entries, toc_last):
    n = len(pdf); texts = {}
    def pagetext(p):
        if p not in texts:
            txt = pdf[p].get_textpage().get_text_range()
            texts[p] = norm(" ".join(txt.splitlines()[:12]))
        return texts[p]
    votes = Counter()
    for e in entries:
        pp = e["printed_page"]
        if not pp.isdigit():
            continue
        words = [w for w in norm(e["title"]).split() if len(w) > 2 and w not in {"the", "and", "chapter", "part", "section"}][:4]
        if not words:
            continue
        cands = []
        for off in range(0, 45):
            p = int(pp) - 1 + off
            if toc_last < p < n and sum(w in pagetext(p) for w in words) >= max(1, len(words) - 1):
                cands.append(off)
        if len(cands) == 1:
            votes[cands[0]] += 1; e["_off"] = cands[0]
        elif cands:
            e["_cands"] = cands
    offset = votes.most_common(1)[0][0] if votes else None
    for e in entries:
        pp = e["printed_page"]
        if pp.isdigit() and offset is not None:
            e["physical_page_ref"] = int(pp) + offset
            e["found_by"] = "title-search" if e.get("_off") == offset else ("offset-majority" if "_off" not in e else f"title-search-disagrees({e['_off']})")
        e.pop("_off", None); e.pop("_cands", None)
    return offset, dict(votes)

def main():
    (Path(ARGS.out) / "ref").mkdir(parents=True, exist_ok=True)
    man = json.loads((HERE / "manifest.json").read_text())
    ids = [b["identifier"] for b in man]
    for bid in ids:
        pdf = pdfium.PdfDocument(str(Path(ARGS.books) / f"{bid}.pdf"))
        pages = find_toc_pages(pdf)
        entries = [e for p in pages for e in parse_toc_lines(lines_with_boxes(pdf[p]))]
        offset, votes = locate(pdf, entries, pages[-1] if pages else 0)
        ref = {"id": bid, "toc_pages_1based": [p + 1 for p in pages], "offset": offset, "offset_votes": votes,
               "n_entries": len(entries), "entries": entries, "source": "Internet Archive ABBYY text layer (independent of Apple Vision)"}
        (Path(ARGS.out) / "ref" / f"{bid}.json").write_text(json.dumps(ref, ensure_ascii=False, indent=1))
        conf = votes.get(offset, 0) if offset is not None else 0
        print(f"{bid:32s} toc={ref['toc_pages_1based']} entries={len(entries):3d} offset={offset} votes={conf}/{sum(votes.values())}")
main()
