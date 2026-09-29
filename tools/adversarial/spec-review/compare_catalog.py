# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9", "pypdf>=5"]
# ///
"""compare_catalog.py <in.pdf> <out.pdf> -- semantic diff of the catalog and trailer (qpdf and pypdf views).

The harness's struct column crashes on catalogs holding a boolean (pikepdf returns a Python bool there),
so this re-does the comparison with a type-aware unparse.
"""
import sys

import pikepdf
import pypdf


def unparse(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, pikepdf.Object) and v.is_indirect:
        return f"{v.objgen[0]} {v.objgen[1]} R"
    if isinstance(v, pikepdf.Object):
        return v.unparse(resolved=False).decode("latin-1")
    return repr(v)


def qpdf_view(path):
    p = pikepdf.open(path)
    root = {str(k): unparse(p.Root[k]) for k in p.Root.keys()}
    tr = {str(k): unparse(p.trailer[k]) for k in p.trailer.keys()}
    return root, tr


def pypdf_view(path):
    r = pypdf.PdfReader(path, strict=False)
    root = r.trailer["/Root"].get_object()
    return {k: repr(root.get(k)) for k in root.keys()}, {k: repr(r.trailer.get(k)) for k in r.trailer.keys()}


def diff(label, a, b, skip=("/Outlines", "/PageMode")):
    bad = 0
    for k in sorted(set(a) | set(b)):
        if k in skip:
            continue
        if a.get(k) != b.get(k):
            bad += 1
            print(f"  {label} {k}: in={a.get(k)!s:.100} out={b.get(k)!s:.100}")
    return bad


def main():
    inp, outp = sys.argv[1], sys.argv[2]
    ra, ta = qpdf_view(inp)
    rb, tb = qpdf_view(outp)
    n = diff("qpdf catalog", ra, rb)
    n += diff("qpdf trailer", ta, tb, skip=("/Size", "/Prev", "/ID"))
    pa, pta = pypdf_view(inp)
    pb, ptb = pypdf_view(outp)
    n += diff("pypdf catalog", pa, pb)
    n += diff("pypdf trailer", pta, ptb, skip=("/Size", "/Prev", "/ID"))
    print(f"{inp.split('/')[-1]}: {n} difference(s)")
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main())
