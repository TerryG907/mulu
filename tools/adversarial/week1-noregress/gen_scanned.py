# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow>=10", "img2pdf>=0.5", "numpy>=1.26", "pikepdf>=9", "fonttools>=4.40"]
# ///
"""
gen_scanned.py -- week-1 no-regression/safety audit: synthetic SCANNED books built with the
project's own generator (tools/fixtures/make_books.py, imported, not modified), written to
tools/adversarial/week1-noregress/books/ only.

  uv run --python 3.12 gen_scanned.py <variant>
    book120     a normal ~120-page scanned book (baseline for time / peak RSS of `mulu auto`)
    nofolio     the same book with NO printed page numbers anywhere
    sawtooth    printed page numbers restart every 13 pages (inconsistent numbering)
    plates      post-process book120: insert 2, 4 or 8 unnumbered plate pages at 50% (4 also at 88%) of
                the body (the physical-printed offset changes partway through the book)
"""
import copy
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / "books"
OUT.mkdir(exist_ok=True)

spec = importlib.util.spec_from_file_location("make_books", ROOT / "tools/fixtures/make_books.py")
mb = importlib.util.module_from_spec(spec)
sys.modules["make_books"] = mb
spec.loader.exec_module(mb)


def base(name: str):
    b = copy.deepcopy(next(x for x in mb.BOOKS if x.name == "zh_econ_textbook"))
    b.name = name
    b.pages_range = (112, 120)
    return b


def build_as(target: str):
    """Same seed (name w1_nofolio) for every variant, so the books differ only in their folios."""
    import shutil, tempfile
    tmp = Path(tempfile.mkdtemp(dir=OUT))
    info = mb.build_book(base("w1_nofolio"), tmp)
    for f in tmp.iterdir():
        f.rename(OUT / f.name.replace("w1_nofolio", target))
    shutil.rmtree(tmp)
    return info


def plates():
    import pikepdf
    src = OUT / "w1_book120.pdf"
    truth = json.loads((OUT / "w1_book120.truth.json").read_text())
    n = truth["pages"]
    off = truth["offset"]
    body_first = off + 1
    for tag, frac, nplates in (("mid", 0.50, 4), ("late", 0.88, 4), ("mid2", 0.50, 2), ("mid8", 0.50, 8)):
        cut = body_first + int((n - body_first) * frac)  # insert after physical page `cut`
        pdf = pikepdf.open(src)
        mbox = pdf.pages[cut - 1].mediabox
        for k in range(nplates):
            # an unnumbered plate: a grey box and a caption-less figure, no folio
            content = pdf.make_stream(b"q 0.6 g 72 144 m 400 144 l 400 500 l 72 500 l f Q")
            page = pikepdf.Dictionary(Type=pikepdf.Name.Page, MediaBox=mbox, Resources=pikepdf.Dictionary(),
                                      Contents=content)
            pdf.pages.insert(cut + k, pikepdf.Page(page))
        out = OUT / f"w1_plates_{tag}.pdf"
        pdf.save(out)
        # truth: entries after the cut move 4 pages later
        t = copy.deepcopy(truth)
        t["plates_after_physical"] = cut
        for e in t["entries"]:
            if not e.get("front_matter") and e["physical_page"] > cut:
                e["physical_page"] += nplates
        t["pages"] = n + nplates
        (OUT / f"w1_plates_{tag}.truth.json").write_text(json.dumps(t, ensure_ascii=False, indent=1) + "\n")
        print(out, "cut after", cut, "plates", nplates, "pages", n + nplates)


def main():
    v = sys.argv[1]
    if v == "book120":
        print(build_as("w1_book120"))
    elif v == "nofolio":
        mb.draw_folio = lambda *a, **k: None
        print(mb.build_book(base("w1_nofolio"), OUT))
    elif v == "sawtooth":
        orig = mb.folio_text
        mb.folio_text = lambda n, style: orig(((n - 1) % 13) + 1, style) if isinstance(n, int) else orig(n, style)
        print(build_as("w1_sawtooth"))
    elif v == "plates":
        plates()
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
