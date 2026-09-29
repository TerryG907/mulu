# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9", "pypdfium2>=4.30", "pypdf>=5"]
# ///
"""dangling_probe.py <in.pdf> <out.pdf> -- what page 1's /Annots entries resolve to, before and after.

In the input, /Annots [10 0 R 11 0 R] points at objects that do not exist (/Size 10), i.e. null
(ISO 32000-1 §7.3.10). mulu numbers its new objects from /Size, so after the update the same
references resolve to the new /Outlines dictionary and the first outline item.
"""
import sys

import pikepdf
import pypdf
import pypdfium2 as pdfium
import pypdfium2.raw as c


def show(path):
    p = pikepdf.open(path)
    annots = p.pages[0].obj.get("/Annots")
    res = []
    for a in annots:
        res.append("null" if a is None or (hasattr(a, "is_null") and a.is_null) else
                   f"{a.objgen} {dict((str(k), str(v)[:30]) for k, v in a.items())}")
    doc = pdfium.PdfDocument(path)
    n_pdfium = c.FPDFPage_GetAnnotCount(doc[0].raw)
    r = pypdf.PdfReader(path)
    pyp = [repr(x.get_object())[:60] for x in r.pages[0].get("/Annots", [])]
    print(f"{path.split('/')[-1]}:\n  qpdf  /Annots -> {res}\n  PDFium FPDFPage_GetAnnotCount(page 1) = {n_pdfium}"
          f"\n  pypdf /Annots -> {pyp}")


for f in sys.argv[1:]:
    show(f)
