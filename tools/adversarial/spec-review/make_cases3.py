# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9"]
# ///
"""make_cases3.py -- 'server prepended a newline' variants of real-producer fixtures from Fixtures/generated.

Prepends b"\\n" to text_objstm.pdf (xref stream + object streams) and quartz_made.pdf (Quartz, classic),
so every offset in the file becomes header-relative -- the frame qpdf, PDFium and pdf.js read such files in.
Writes gen3/ + manifest.json for tools/verify/verify.py run-all --gen.
"""
import json
import shutil
from pathlib import Path

import pikepdf

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SRC = ROOT / "Fixtures" / "generated"
GEN = HERE / "gen3"


def main():
    GEN.mkdir(exist_ok=True)
    manifest = {"fixtures": {}}
    for base, prefix, tag in [("text_objstm", b"\n", "lf"), ("quartz_made", b"\n", "lf"), ("text_objstm", b"\r\n", "crlf")]:
        name = f"sr3_{base}_{tag}prefix"
        pdf = prefix + (SRC / f"{base}.pdf").read_bytes()
        (GEN / f"{name}.pdf").write_bytes(pdf)
        for ext in ("toc.txt", "expected.json", "offset"):
            if (SRC / f"{base}.{ext}").exists():
                shutil.copy(SRC / f"{base}.{ext}", GEN / f"{name}.{ext}")
        with pikepdf.open(GEN / f"{name}.pdf") as p:
            facts = {"size": len(pdf), "pages": len(p.pages), "encrypted": False,
                     "xref": "stream" if base == "text_objstm" else "classic",
                     "qpdf_warnings": [str(w) for w in p.get_warnings()]}
        off = GEN / f"{name}.offset"
        manifest["fixtures"][name] = {"name": name, "status": "ok", "expect": "apply",
                                      "offset": int(off.read_text().strip()) if off.exists() else 0,
                                      "reapply": False, "perf_limit_ms": None,
                                      "notes": f"{base}.pdf with {prefix!r} prepended", "facts": facts,
                                      "allow_input_warnings": True}
        print(name, len(pdf), facts)
    (GEN / "manifest.json").write_text(json.dumps(manifest, indent=1))


if __name__ == "__main__":
    main()
