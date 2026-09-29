# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow>=10", "img2pdf>=0.5", "numpy>=1.26", "fonttools>=4.40"]
# ///
"""
make_cases.py -- render the messy printed-TOC cases (cases.py) as small scanned books.

    nice -n 15 uv run --python 3.12 tools/adversarial/week1-messy/make_cases.py [--only c01,c05] [--jobs 2]

Writes tools/adversarial/week1-messy/cases/<name>.{pdf,raw.txt,truth.json} and a PNG preview
of the first TOC page. Fonts are macOS system fonts; all text comes from cases.py.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import io
import json
import random
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from cases import C, Case, L  # noqa: E402

OUT = HERE / "cases"
DPI = 300
W, H = 1748, 2480
ML, MR = 200, 200
RE = W - MR
PT = DPI / 72.0

SONGTI = "/System/Library/Fonts/Supplemental/Songti.ttc"
HEITI = "/System/Library/Fonts/STHeiti Medium.ttc"
TIMES = "/System/Library/Fonts/Times.ttc"
ARIALU = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
FONTS = {"song": (SONGTI, 6), "songb": (SONGTI, 1), "hei": (HEITI, 1), "times": (TIMES, 0), "timesb": (TIMES, 1), "arial": (ARIALU, 0)}
FALLBACK = ["song", "arial"]

_fc: dict = {}
_cm: dict = {}


def font(key, px):
    from PIL import ImageFont
    k = (key, int(px))
    if k not in _fc:
        p, i = FONTS[key]
        _fc[k] = ImageFont.truetype(p, int(px), index=i)
    return _fc[k]


def cmap(key):
    if key not in _cm:
        from PIL import ImageFont  # noqa
        from fontTools.ttLib import TTFont  # type: ignore
        p, i = FONTS[key]
        f = TTFont(p, fontNumber=i, lazy=True)
        _cm[key] = set(f.getBestCmap().keys())
    return _cm[key]


def pick(key, text):
    try:
        for k in [key] + [f for f in FALLBACK if f != key]:
            cm = cmap(k)
            if all(ord(c) in cm or c.isspace() for c in text):
                return k
    except Exception:
        pass
    return key


def draw_text(d, xy, text, key, px, fill=0):
    k = pick(key, text)
    f = font(k, px)
    d.text(xy, text, font=f, fill=fill)
    return f.getlength(text)


def tlen(text, key, px):
    return font(pick(key, text), px).getlength(text)


def roman(n):
    vals = [(10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
    s = ""
    for v, r in vals:
        while n >= v:
            s += r
            n -= v
    return s


ZH_FILL = ("本章讨论的问题在学界已有较多研究，但仍存在若干尚未解决的分歧。我们首先回顾相关文献，然后提出分析框架，"
           "并在此基础上展开讨论。需要指出的是，这里的分析以定性为主，辅以必要的说明。读者可以结合前后各章阅读，"
           "以便把握全书的结构与主要论点。作者在写作过程中得到许多同行的帮助，谨此致谢。")
EN_FILL = ("The questions raised in this chapter have a long history, and we shall not attempt a complete survey. "
           "Instead we sketch the main ideas and indicate where the reader may find further details. The argument "
           "proceeds in several steps, each of which is elementary, although the combination is not.")


def filler_lines(lang, n, rng):
    src = ZH_FILL if lang == "zh" else EN_FILL
    per = 30 if lang == "zh" else 62
    out = []
    for _ in range(n):
        s = rng.randrange(0, max(1, len(src) - per))
        out.append(src[s:s + per].strip())
    return out


# ---------------------------------------------------------------------------
# TOC pages


def leader_str(unit, avail, key, px):
    uw = tlen(unit, key, px)
    if uw <= 0:
        return ""
    n = int(avail // uw)
    return unit * max(0, n)


def raw_leader(unit):
    return (unit * 6).strip()


def render_toc(case: Case, rng: random.Random):
    """Returns (pages: list[PIL.Image], raw: list[str], maps) where maps records raw line numbers."""
    from PIL import Image, ImageDraw
    key = case.font
    px = case.size_pt * PT
    em = px
    pitch = px * case.spacing
    unitw = 2 * em if case.lang == "zh" else 1.6 * em
    cols = [(ML, RE)] if case.columns == 1 else [(ML - 60, W // 2 - 50), (W // 2 + 30, RE + 60)]
    pages = []
    raw: list[str] = []
    entry_lines: list[list[int]] = []   # per E line (in order), raw line numbers
    junk_lines: list[int] = []
    head_lines: list[int] = []
    folio_no = [case_front_toc_start(case)]

    state = {}

    def new_page():
        im = Image.new("L", (W, H), 255)
        pages.append(im)
        state["im"] = im
        state["d"] = ImageDraw.Draw(im)
        state["y"] = 300.0
        state["col"] = 0
        state["foot"] = []

    def finish_page():
        d = state["d"]
        foots = state["foot"]
        if foots:
            fy = H - 260 - len(foots) * px * 1.1
            d.line((ML, fy - 20, ML + 400, fy - 20), fill=0, width=3)
            for t in foots:
                draw_text(d, (ML, fy), t, key, px * 0.8)
                fy += px * 1.1
        # TOC page folio (roman), footer centre
        f = roman(folio_no[0]) if not (case.front_arabic or case.toc_at_back or case.continuous) else ""
        if case.continuous:
            f = str(2 + folio_no[0])
        if f:
            fw = tlen(f, key, px * 0.9)
            draw_text(d, ((W - fw) / 2, H - 170), f, key, px * 0.9)
            if case.raw_folios:
                raw.append(f)
                junk_lines.append(len(raw))
        folio_no[0] += 1

    def colx():
        return cols[state["col"]]

    def put_heading(text):
        d = state["d"]
        hp = px * 1.6
        l, r = colx() if case.columns == 1 else (ML, RE)
        w = tlen(text, key, hp)
        draw_text(d, ((l + r - w) / 2 if case.columns == 1 else (W - w) / 2, state["y"]), text, key, hp)
        state["y"] += hp * 2.2
        raw.append(text)
        head_lines.append(len(raw))

    def put_line(text, page, ind, style, unit, cont=False):
        """Draws one visual line; returns raw string."""
        if state["y"] + pitch > H - 330 - (len(state["foot"]) * px * 1.1):
            finish_page()
            new_page()
        d = state["d"]
        l, r = colx()
        y = state["y"]
        jit = rng.uniform(-3, 3)
        x0 = l + ind * unitw + (em if cont else 0) + jit
        rs = " " * max(0, int(round(ind * 2))) + (" " if cont else "")
        if page == "":
            draw_text(d, (x0, y), text, key, px)
            rs += text
        elif style == "glued":
            draw_text(d, (x0, y), text + page, key, px)
            rs += text + page
        elif style == "space":
            draw_text(d, (x0, y), text + " " + page, key, px)
            rs += text + " " + page
        elif style == "numleft":
            numcol = l + tlen("000", key, px)
            pw = tlen(page, key, px)
            draw_text(d, (numcol - pw, y), page, key, px)
            tx = l + 4 * em + ind * unitw + jit
            ld = leader_str(unit, tx - numcol - 2 * 0.4 * em, key, px)
            draw_text(d, (numcol + 0.4 * em, y), ld, key, px)
            draw_text(d, (tx, y), text, key, px)
            rs = " " * max(0, int(round(ind * 2))) + page + " " + raw_leader(unit) + " " + text
        else:
            right = r
            if style == "ragged":
                right = r - rng.choice([0, 40, 120, 260, 380, 60, 200])
            pw = tlen(page, key, px)
            tw = draw_text(d, (x0, y), text, key, px)
            if style == "noleader":
                rs += text + "  " + page
            else:
                ld = leader_str(unit, right - pw - 0.4 * em - (x0 + tw + 0.4 * em), key, px)
                draw_text(d, (x0 + tw + 0.4 * em, y), ld, key, px)
                rs += text + " " + raw_leader(unit) + " " + page
            draw_text(d, (right - pw, y), page, key, px)
        state["y"] += pitch
        return rs

    new_page()
    for ln in case.lines:
        if ln.kind == "PB":
            finish_page()
            new_page()
            continue
        if ln.kind == "CB":
            state["col"] = 1
            state["y"] = 300.0 + px * 1.6 * 2.2
            continue
        if ln.kind == "H":
            put_heading(ln.text)
            continue
        ind = ln.ind if ln.ind is not None else (ln.level if ln.kind == "E" else 0)
        style = ln.style or case.style
        unit = ln.lead or case.lead
        if ln.kind == "J" and style == "foot":
            state["foot"].append(ln.text)
            continue
        if ln.kind == "J":
            raw.append(put_line(ln.text, ln.page, ind, style, unit))
            junk_lines.append(len(raw))
            continue
        # entry
        nums = []
        parts = ln.wrap or [ln.text]
        vis = [p for p in parts if not p.startswith("@")]
        k = 0
        for p in parts:
            if p == "@PB":
                finish_page()
                new_page()
                continue
            if p.startswith("@H:"):
                put_heading(p[3:])
                continue
            last = (k == len(vis) - 1)
            raw.append(put_line(p, ln.page if last else "", ind, style, unit, cont=(k > 0)))
            nums.append(len(raw))
            k += 1
        entry_lines.append(nums)
    finish_page()
    if case.raw_override:
        assert len(case.raw_override) == len(raw), (case.name, len(case.raw_override), len(raw))
        raw = list(case.raw_override)
    return pages, raw, entry_lines, junk_lines, head_lines


def case_front_toc_start(case: Case):
    return front_layout(case)[1]


def front_values(case: Case):
    return sorted({roman_val(l.page) for l in case.lines if l.kind == "E" and l.front and not case.front_arabic})


def roman_val(s):
    m = {"i": 1, "v": 5, "x": 10, "l": 50}
    s = s.lower()
    tot = 0
    for i, c in enumerate(s):
        v = m[c]
        if i + 1 < len(s) and m[s[i + 1]] > v:
            tot -= v
        else:
            tot += v
    return tot


def n_toc_pages(case: Case):
    n = 1 + sum(1 for l in case.lines if l.kind == "PB")
    n += sum(1 for l in case.lines if l.kind == "E" and l.wrap and "@PB" in l.wrap)
    return n


def front_layout(case: Case, T=None):
    """(n_front_pages, toc_first_folio_value, preface_values)."""
    T = T or n_toc_pages(case)
    if case.toc_at_back:
        return case.preface_pages, 10 ** 6, list(range(1, case.preface_pages + 1))
    if case.front_arabic:
        return case.preface_pages + T, 0, list(range(1, case.preface_pages + 1))
    R = front_values(case)
    if R and max(R) > 2:
        n = max(max(R), 2 + T)
        return n, 3, R
    P = case.preface_pages
    return P + T, P + 1, list(range(1, P + 1))


# ---------------------------------------------------------------------------
# book


def degrade(im, rng, skew, profile, seed):
    import numpy as np
    from PIL import Image, ImageFilter
    im = im.rotate(skew, resample=Image.BICUBIC, fillcolor=255, translate=(rng.randint(-10, 10), rng.randint(-8, 8)))
    nrng = np.random.default_rng(seed)
    if profile == "faint":
        im = im.filter(ImageFilter.GaussianBlur(1.1))
        a = np.asarray(im, dtype=np.float32)
        ink, paper = 150.0, 214.0
        a = ink + (a / 255.0) * (paper - ink)
        xx = np.linspace(0, 1, W, dtype=np.float32)[None, :]
        a = a * (1.0 - 0.07 * (xx - 0.3) ** 2)
        a += nrng.normal(0, 6, a.shape).astype(np.float32)
        out = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), mode="L")
        buf = io.BytesIO()
        out.save(buf, format="JPEG", quality=55, dpi=(DPI, DPI))
        return buf.getvalue()
    if profile == "scan":
        im = im.filter(ImageFilter.GaussianBlur(0.7))
        a = np.asarray(im, dtype=np.float32)
        a += nrng.normal(0, 14, a.shape).astype(np.float32)
        bw = a >= 150
        out = Image.fromarray((bw * 255).astype(np.uint8), mode="L").convert("1", dither=Image.Dither.NONE)
    else:
        out = im.convert("1", dither=Image.Dither.NONE)
    buf = io.BytesIO()
    out.save(buf, format="TIFF", compression="group4", dpi=(DPI, DPI))
    return buf.getvalue()


def text_page(lang, key, rng, heads, folio, folio_pos, phys, running=None, plate=None):
    from PIL import Image, ImageDraw
    im = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(im)
    px = 10.5 * PT
    y = 300.0
    if running:
        rw = tlen(running, key, px * 0.8)
        draw_text(d, ((W - rw) / 2, 150), running, key, px * 0.8)
        d.line((ML, 150 + px * 1.1, RE, 150 + px * 1.1), fill=0, width=2)
    if plate is not None:
        d.rectangle((ML + 80, 500, RE - 80, 1700), fill=120)
        cap = f"图版{'一二三四五六七八九十'[plate % 10]}" if lang == "zh" else "Plate"
        draw_text(d, (W / 2 - 100, 1780), cap, key, px)
    else:
        for lvl, title in heads:
            if lvl == 0:
                hp = px * 1.7
                w = tlen(title, key, hp)
                y += 120
                draw_text(d, ((W - w) / 2, y), title, key, hp)
                y += hp * 2.4
            else:
                draw_text(d, (ML, y), title, "hei" if lang == "zh" else "timesb", px * 1.15)
                y += px * 2.2
            for t in filler_lines(lang, 3, rng):
                draw_text(d, (ML, y), t, key, px)
                y += px * 1.8
        while y < H - 420:
            for t in filler_lines(lang, 1, rng):
                draw_text(d, (ML, y), t, key, px)
            y += px * 1.8
    if folio:
        fpx = px * 0.95
        fw = tlen(folio, key, fpx)
        if folio_pos == "footer-center":
            xy = ((W - fw) / 2, H - 200)
        elif folio_pos == "footer-outer":
            xy = ((RE - fw) if phys % 2 == 1 else ML, H - 200)
        else:
            xy = ((RE - fw) if phys % 2 == 1 else ML, 150)
        draw_text(d, xy, folio, key, fpx)
    return im


def build(case: Case):
    import img2pdf
    rng = random.Random(zlib.crc32(case.name.encode()))
    OUT.mkdir(parents=True, exist_ok=True)
    key = case.font
    toc_imgs, raw, entry_lines, junk_lines, head_lines = render_toc(case, rng)
    (OUT / f"{case.name}.raw.txt").write_text("\n".join(raw) + "\n", encoding="utf-8")
    toc_imgs[0].convert("L").resize((W // 3, H // 3)).save(OUT / f"{case.name}.toc1.png")

    entries = [l for l in case.lines if l.kind == "E"]
    lang = case.lang
    blobs = []
    folios = {}

    def emit(im, folio, skew, profile="scan"):
        blobs.append(degrade(im, rng, skew, profile, len(blobs) + 7))
        folios[len(blobs)] = folio

    # cover + copyright
    from PIL import Image, ImageDraw
    cov = Image.new("L", (W, H), 255)
    dc = ImageDraw.Draw(cov)
    draw_text(dc, (ML, 800), "测试用书" if lang == "zh" else "A Test Book", key, 90)
    draw_text(dc, (ML, 1000), case.name, "times", 60)
    emit(cov, None, 0.2, "clean")
    cp = Image.new("L", (W, H), 255)
    dc = ImageDraw.Draw(cp)
    for i, t in enumerate(["ISBN 978-7-0000-0000-0", "2020年3月第3版 第12次印刷", "定价：68.00元", "开本 787×1092 1/16"]):
        draw_text(dc, (ML, 1500 + i * 70), t, "song", 40)
    emit(cp, None, 0.3)

    # front matter
    nfront, toc_start, pref_vals = front_layout(case, len(toc_imgs))
    front_heads = {}
    for l in entries:
        if l.front:
            v = int(l.page) if case.front_arabic else roman_val(l.page)
            front_heads.setdefault(v, []).append((0, l.title or l.text))
    toc_phys = []
    front_phys = {}
    cont_front = {}
    ti = 0
    for v in range(1, nfront + 1):
        is_toc = (toc_start <= v < toc_start + len(toc_imgs)) if not case.front_arabic else (v > case.preface_pages)
        if is_toc:
            skew = case.toc_skew if case.toc_skew is not None else rng.uniform(-0.4, 0.4)
            emit(toc_imgs[ti], str(len(blobs) + 1) if case.continuous else (roman(v) if not case.front_arabic else None), skew, case.profile)
            toc_phys.append(len(blobs))
            ti += 1
        else:
            f = str(v) if case.front_arabic else (str(len(blobs) + 1) if case.continuous else roman(v))
            heads = front_heads.get(v, [])
            if not heads and v == 1:
                heads = [(0, "前言" if lang == "zh" else "Preface")] if not front_heads else []
            emit(text_page(lang, key, rng, heads, f, "footer-center", len(blobs) + 1), f, rng.uniform(-0.4, 0.4))
            front_phys[v] = len(blobs)
            if case.continuous:
                cont_front[len(blobs)] = len(blobs)
    assert ti == len(toc_imgs) or case.toc_at_back, (case.name, ti, len(toc_imgs))

    # body
    arabic = [int(tp) for l in entries for tp in [truth_page(l)] if isinstance(tp, int) and not l.front]
    last = case.body_pages or ((max(arabic) + case.extra_body) if arabic else 90)
    body_heads: dict[int, list] = {}
    pending = []
    for l in entries:
        tp = truth_page(l)
        if l.front:
            continue
        if tp is None:
            pending.append(l)
            continue
        if tp <= last:
            for pl in pending:
                body_heads.setdefault(tp, []).append((pl.level, pl.title or pl.text))
            body_heads.setdefault(tp, []).append((l.level, l.title or l.text))
        pending = []
    body_phys = dict(cont_front)
    chapter = None
    section = None
    first = len(blobs) + 1 if case.continuous else 1
    for p in range(first, last + 1):
        heads = body_heads.get(p, [])
        opener = any(lv == 0 for lv, _ in heads)
        for lv, t in heads:
            if lv == 0:
                chapter = t
        folio = None if (case.opener_no_folio and opener) else str(p)
        for lv, t in heads:
            if lv >= 1:
                section = t
            elif lv == 0:
                section = None
        running = chapter if (case.running_header == "chapter" and not opener and chapter) else None
        if case.running_header == "section" and not opener:
            running = (section or chapter) if len(blobs) % 2 == 0 else chapter
        emit(text_page(lang, key, rng, heads, folio, case.folio, len(blobs) + 1, running), folio, rng.uniform(-0.4, 0.4))
        body_phys[p] = len(blobs)
        if case.plates and p == case.plates[0]:
            for k in range(case.plates[1]):
                emit(text_page(lang, key, rng, [], None, case.folio, len(blobs) + 1, plate=k), None, rng.uniform(-0.3, 0.3))
    if case.toc_at_back:
        for im in toc_imgs:
            emit(im, str(last + 1 + len(toc_phys)), case.toc_skew if case.toc_skew is not None else rng.uniform(-0.4, 0.4), case.profile)
            toc_phys.append(len(blobs))
    npages = len(blobs)
    (OUT / f"{case.name}.pdf").write_bytes(img2pdf.convert(blobs, nodate=True, engine=img2pdf.Engine.internal))

    # truth
    tentries = []
    for i, l in enumerate(entries):
        tp = truth_page(l)
        if l.front:
            v = int(l.page) if case.front_arabic else roman_val(l.page)
            phys = front_phys.get(v)
        elif tp is None:
            phys = None
        else:
            phys = body_phys.get(tp)
        tentries.append({"title": l.title or l.text, "level": l.level, "printed": tp, "printed_text": l.page,
                         "physical": phys, "front": l.front, "raw_lines": entry_lines[i], "note": l.note})
    # page-less entries inherit the next entry's physical page
    for i, t in enumerate(tentries):
        if t["printed"] is None and not t["front"]:
            for u in tentries[i + 1:]:
                if u["physical"] is not None:
                    t["physical"] = u["physical"]
                    t["inherited"] = True
                    break
    offset = body_phys[max(body_phys)] - max(body_phys)
    fo = None
    if front_phys and not case.front_arabic:
        v0 = min(front_phys)
        fo = front_phys[v0] - v0
    truth = {"name": case.name, "features": case.features, "notes": case.notes, "expect": case.expect,
             "pages": npages, "offset": offset, "front_offset": fo, "front_arabic": case.front_arabic,
             "plates": case.plates, "toc_pages": toc_phys,
             "toc_pages_arg": f"{toc_phys[0]}-{toc_phys[-1]}" if len(toc_phys) > 1 else str(toc_phys[0]),
             "entries": tentries, "junk_raw_lines": junk_lines, "heading_raw_lines": head_lines,
             "folios": folios}
    (OUT / f"{case.name}.truth.json").write_text(json.dumps(truth, ensure_ascii=False, indent=1), encoding="utf-8")
    return case.name, npages, len(tentries)


def truth_page(l: L):
    if l.tpage != "auto":
        return l.tpage
    s = l.page.strip()
    if not s:
        return None
    if l.front and not s.isdigit():
        return s
    import re
    m = re.match(r"\d+", s)
    return int(m.group()) if m else s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=2)
    a = ap.parse_args()
    sel = [c for c in C if not a.only or any(c.name.startswith(o) for o in a.only.split(","))]
    with cf.ProcessPoolExecutor(max_workers=min(2, a.jobs)) as ex:
        for name, n, e in ex.map(build, sel):
            print(f"{name}: {n} pages, {e} entries", flush=True)


if __name__ == "__main__":
    main()
