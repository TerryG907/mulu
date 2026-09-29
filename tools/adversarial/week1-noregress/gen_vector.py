"""
gen_vector.py -- week-1 no-regression/safety audit: vector-text PDFs (no deps, stdlib only),
written to tools/adversarial/week1-noregress/vec/ only.

  uv run --python 3.12 gen_vector.py

  big2000.pdf           2000 pages, TOC on physical 3-6, 40 chapters x (1 + 2 sections),
                        body from physical 9, printed folio = physical - 8 (footer centre)
  big2000_nofolio.pdf   the same without any printed page number
  big2000_huge.pdf      the same book, every page 20000 x 20000 pt (content scaled)
  huge20000.pdf         8 pages of 20000 x 20000 pt: TOC on 3, body 4-8 with folios
  extreme.pdf           odd page boxes: 20000x20, 20x20000, 1x1, 200000x200000,
                        14400x14400 with /UserUnit 75, MediaBox 0 0 0 0, negative box
Each *.truth.json has the offset, the TOC pages and the entries (title, level, physical page).
"""
import json
import random
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "vec"
OUT.mkdir(exist_ok=True)

WORDS = ("memory cache register pipeline branch vector thread lock queue buffer kernel driver "
         "packet socket router switch frame signal clock timer latency bandwidth storage block "
         "sector journal index tree graph matrix tensor gradient model sample filter window").split()


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


class Doc:
    def __init__(self):
        self.objs: list[bytes] = []
        self.pages: list[int] = []

    def add(self, body: bytes) -> int:
        self.objs.append(body)
        return len(self.objs)

    def stream(self, data: bytes, extra: str = "") -> int:
        return self.add(b"<< /Length %d %s>>\nstream\n" % (len(data), extra.encode()) + data + b"\nendstream")

    def page(self, w, h, ops, extra=""):
        cs = []
        for (x, y, size, text) in ops:
            cs.append(f"BT /F1 {size:.2f} Tf {x:.2f} {y:.2f} Td ({esc(text)}) Tj ET")
        cid = self.stream("\n".join(cs).encode("latin-1"))
        self.pages.append((cid, w, h, extra))

    def save(self, path: Path):
        # 1 catalog, 2 pages, 3 font, then streams, then page objects
        font = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
        base = [b"", b"", font]
        n_pre = 3
        objs = base + self.objs
        page_ids = []
        for (cid, w, h, extra) in self.pages:
            objs.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Resources << /Font << /F1 3 0 R >> >> "
                         "/Contents %d 0 R %s>>" % (w, h, cid + n_pre, extra)).encode())
            page_ids.append(len(objs))
        objs[0] = b"<< /Type /Catalog /Pages 2 0 R >>"
        objs[1] = ("<< /Type /Pages /Count %d /Kids [%s] >>" % (len(page_ids), " ".join(f"{i} 0 R" for i in page_ids))).encode()
        # fix stream references: content ids were numbered from 1 in self.objs
        out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
        offs = []
        for i, body in enumerate(objs, start=1):
            offs.append(len(out))
            out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
        x = len(out)
        out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
        for o in offs:
            out += b"%010d 00000 n \n" % o
        out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
        path.write_bytes(bytes(out))


def book(n_pages=2000, folios=True, W=612.0, H=792.0, name="big2000"):
    rng = random.Random(7)
    S = min(W / 612.0, H / 792.0)  # content scale
    ox, oy = (W - 612 * S) / 2, (H - 792 * S) / 2

    def T(x, y, size, text):
        return (ox + x * S, oy + y * S, size * S, text)

    offset = 8
    body_first = offset + 1
    n_body = n_pages - offset
    # 40 chapters, each with 2 sections
    n_ch = max(2, min(40, n_body // 6))
    ch_len = n_body // n_ch
    entries = []
    for c in range(n_ch):
        p0 = 1 + c * ch_len
        t = " ".join(w.capitalize() for w in rng.sample(WORDS, 3))
        entries.append({"title": f"Chapter {c + 1} {t}", "level": 0, "printed": p0})
        for s in range(2):
            ps = p0 + 1 + s * (ch_len // 2)
            st = " ".join(w.capitalize() for w in rng.sample(WORDS, 2))
            entries.append({"title": f"{c + 1}.{s + 1} {st}", "level": 1, "printed": ps})
    d = Doc()
    d.page(W, H, [T(150, 500, 28, "A Big Test Book"), T(220, 450, 14, "Synthetic Press")])
    d.page(W, H, [])
    per = 30
    toc_pages = []
    for k in range(0, len(entries), per):
        ops = [T(250, 730, 18, "Contents")] if k == 0 else []
        y = 690
        for e in entries[k:k + per]:
            x = 72 if e["level"] == 0 else 96
            title = e["title"]
            ops.append(T(x, y, 11, title))
            lead_x = x + 6.2 * len(title) + 8
            n_dots = max(3, int((520 - lead_x) / 5.5))
            ops.append(T(lead_x, y, 11, " ".join(["."] * (n_dots // 2))))
            ops.append(T(540 - 6 * len(str(e["printed"])), y, 11, str(e["printed"])))
            y -= 21
        d.page(W, H, ops)
        toc_pages.append(len(d.pages))
    while len(d.pages) < offset:
        d.page(W, H, [T(250, 700, 16, "Preface"), T(72, 650, 10, "This book was generated for testing.")])
    starts = {}
    for e in entries:
        starts.setdefault(e["printed"], []).append(e)
    running = "A Big Test Book"
    for q in range(1, n_body + 1):
        ops = []
        y = 700
        for e in starts.get(q, []):
            if e["level"] == 0:
                running = e["title"]
                ops.append(T(72, 690, 20, e["title"]))
                y = 640
            else:
                ops.append(T(72, y, 14, e["title"]))
                y -= 30
        if not starts.get(q) or starts[q][0]["level"] != 0:
            ops.append(T(200, 750, 9, running if q % 2 else "A Big Test Book"))
        while y > 110:
            ops.append(T(72, y, 10, " ".join(rng.choice(WORDS) for _ in range(12))))
            y -= 16
        if folios:
            ops.append(T(300, 50, 10, str(q)))
        d.page(W, H, ops)
    assert len(d.pages) == n_pages, len(d.pages)
    d.save(OUT / f"{name}.pdf")
    truth = {"offset": offset, "toc_pages": toc_pages, "pages": n_pages,
             "entries": [{"title": e["title"], "level": e["level"], "printed_page": e["printed"],
                          "physical_page": e["printed"] + offset} for e in entries]}
    (OUT / f"{name}.truth.json").write_text(json.dumps(truth, indent=1) + "\n")
    print(name, n_pages, "pages; toc", toc_pages)


def extreme():
    d = Doc()
    boxes = [(20000, 20, ""), (20, 20000, ""), (1, 1, ""), (200000, 200000, ""), (14400, 14400, "/UserUnit 75 "),
             (0, 0, ""), (-500, -500, "")]
    for (w, h, extra) in boxes:
        s = max(1.0, min(abs(w), abs(h)) / 100.0)
        ops = [(abs(w) * 0.1, abs(h) * 0.5, s * 10, "Contents 12"), (abs(w) * 0.5, abs(h) * 0.05, s * 10, "7")] if w and h else []
        d.page(w, h, ops, extra)
    d.save(OUT / "extreme.pdf")
    print("extreme", len(boxes))


if __name__ == "__main__":
    book()
    book(folios=False, name="big2000_nofolio")
    book(W=20000.0, H=20000.0, name="big2000_huge")
    book(n_pages=24, W=20000.0, H=20000.0, name="huge20000")
    extreme()
