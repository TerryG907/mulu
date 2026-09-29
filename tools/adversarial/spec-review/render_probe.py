# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9", "pypdfium2>=4.30", "pypdf>=5"]
# ///
"""render_probe.py <pdf>... -- per page: PDFium text + render hash, qpdf-resolved /Resources, pypdf text.

Used to show that a page's appearance changed between an input and mulu's output even though
the outline is correct (e.g. a dangling reference in the input captured by a new object number).
"""
import hashlib
import sys

import pikepdf
import pypdf
import pypdfium2 as pdfium


def show(path):
    print(f"== {path.split('/')[-1]}")
    doc = pdfium.PdfDocument(path)
    q = pikepdf.open(path)
    r = pypdf.PdfReader(path)
    for i in range(len(doc)):
        page = doc[i]
        text = page.get_textpage().get_text_range().strip()
        img = page.render(scale=0.5).to_pil()
        h = hashlib.sha1(img.tobytes()).hexdigest()[:12]
        res = q.pages[i].obj.get("/Resources")
        res_desc = "absent" if res is None else (str(res.objgen) + " keys=" + ",".join(str(k) for k in res.keys())
                                                 if isinstance(res, pikepdf.Dictionary) else repr(res))
        try:
            ptext = r.pages[i].extract_text().strip()
        except Exception as e:  # noqa: BLE001
            ptext = f"ERR {e}"
        print(f"  page {i + 1}: pdfium text={text!r:.40} render={h}  pypdf text={ptext!r:.40}  qpdf /Resources={res_desc}")


for f in sys.argv[1:]:
    show(f)
