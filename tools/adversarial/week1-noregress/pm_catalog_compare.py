# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9", "pypdfium2>=4.30", "cryptography>=42"]
# ///
"""catalog_compare.py -- every producer's catalog/trailer must survive mulu's catalog re-serialization.
For each (input, output) pair: every catalog key except /Outlines and /PageMode deep-equal (direct objects
compared by value, indirect refs by object number), trailer /Info and /ID identical, and PDFium renders of the
first and last page are pixel-identical (catches e.g. dropped /OCProperties)."""
import hashlib, json, sys
from pathlib import Path
import pikepdf, pypdfium2 as pdfium
PM = Path(__file__).resolve().parent.parent / "producer-matrix"; W1 = Path(__file__).resolve().parent

def norm(o, depth=0):
    if isinstance(o, pikepdf.Object) and o.is_indirect and depth > 0:
        return ("ref", o.objgen)
    if isinstance(o, pikepdf.Dictionary):
        return {str(k): norm(o.get(k), depth + 1) for k in o.keys()}
    if isinstance(o, pikepdf.Array):
        return [norm(x, depth + 1) for x in o]
    if isinstance(o, pikepdf.Stream):
        return ("stream", o.objgen)
    return o.unparse() if isinstance(o, pikepdf.Object) else repr(o)

def render(path):
    d = pdfium.PdfDocument(str(path))
    h = []
    for i in {0, len(d) - 1}:
        img = d[i].render(scale=0.5).to_pil()
        h.append(hashlib.sha256(img.tobytes()).hexdigest()[:12])
    return h

fails, n = [], 0
for gen, out in [(PM / "gen", W1 / "pm_out"), (PM / "gen_big", W1 / "pm_out_big")]:
    for o in sorted(out.glob("*.pdf")):
        if o.name.endswith((".perf.pdf",)):
            continue
        inp = out / o.name.replace(".reapply.pdf", ".pdf") if o.name.endswith(".reapply.pdf") else gen / o.name
        if not inp.exists() or inp == o:
            continue
        n += 1
        with pikepdf.open(inp) as a, pikepdf.open(o) as b:
            ca = {k: v for k, v in norm(a.Root).items() if k not in ("/Outlines", "/PageMode")}
            cb = {k: v for k, v in norm(b.Root).items() if k not in ("/Outlines", "/PageMode")}
            if ca != cb:
                ks = sorted(set(ca) | set(cb))
                bad = [k for k in ks if ca.get(k) != cb.get(k)]
                fails.append(f"{o.name}: catalog keys differ {bad}: in={[ca.get(k) for k in bad][:2]} out={[cb.get(k) for k in bad][:2]}")
            if str(b.Root.get("/PageMode")) != "/UseOutlines" and "/Outlines" in b.Root:
                fails.append(f"{o.name}: /PageMode {b.Root.get('/PageMode')}")
            for k in ("/Info", "/ID"):
                va, vb = a.trailer.get(k), b.trailer.get(k)
                if (va is None) != (vb is None) or (va is not None and
                        (va.objgen if va.is_indirect else va.unparse()) != (vb.objgen if vb.is_indirect else vb.unparse())):
                    fails.append(f"{o.name}: trailer {k} changed {va!r} -> {vb!r}")
            if b.Root.objgen != a.Root.objgen:
                fails.append(f"{o.name}: catalog object number changed {a.Root.objgen} -> {b.Root.objgen}")
        if render(inp) != render(o):
            fails.append(f"{o.name}: PDFium first/last page render changed")
print(f"{n} pairs compared, {len(fails)} problems")
for f in fails:
    print("  - " + f[:500])
sys.exit(1 if fails else 0)
