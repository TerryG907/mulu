"""pypdf2_legacy.py -- outline via old PyPDF2 releases (1.26 / 2.12 / 3.0), still pinned by many tools.
usage: uv run --no-project --python 3.12 --with PyPDF2==X python pypdf2_legacy.py <file.pdf>...
one JSON line per file."""
import io, json, logging, sys, warnings
import PyPDF2
V = PyPDF2.__version__ if hasattr(PyPDF2, "__version__") else "1.x"
buf = io.StringIO()
logging.getLogger().addHandler(logging.StreamHandler(buf))
for f in sys.argv[1:]:
    buf.truncate(0); buf.seek(0)
    with warnings.catch_warnings(record=True) as W:
        warnings.simplefilter("always")
        try:
            r = PyPDF2.PdfFileReader(open(f, "rb"), strict=False) if V.startswith("1.") else PyPDF2.PdfReader(f)
            n = r.getNumPages() if V.startswith("1.") else len(r.pages)
            ol = r.getOutlines() if V.startswith("1.") else (r.outline if hasattr(r, "outline") else r.outlines)
            pn = r.getDestinationPageNumber if V.startswith("1.") else r.get_destination_page_number
            items = []
            def walk(lst, lvl):
                for it in lst:
                    if isinstance(it, list):
                        walk(it, lvl + 1)
                    else:
                        items.append({"title": str(it.title), "level": lvl, "page_index": pn(it)})
            walk(ol, 0)
            res = {"file": f, "ok": True, "pages": n, "outline": items}
        except Exception as e:
            res = {"file": f, "ok": False, "error": f"{type(e).__name__}: {e}"}
    res["version"] = V
    res["warnings"] = sorted({str(w.message) for w in W} | {l for l in buf.getvalue().splitlines() if l.strip()})
    print(json.dumps(res, ensure_ascii=False))
