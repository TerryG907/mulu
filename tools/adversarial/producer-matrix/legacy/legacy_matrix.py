"""legacy_matrix.py -- run OLD readers (pdf.js 2.16/3.11/4.10, PyPDF2 1.26/2.12/3.0.1) over every mulu output
of the producer matrix and compare with the expected outline; flag new warnings vs the input.
usage: uv run --no-project --python 3.12 python legacy/legacy_matrix.py"""
import json, os, shutil, subprocess, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
PM = HERE.parent
UV = os.environ.get("UV") or shutil.which("uv") or str(Path.home() / ".local/bin/uv")
pairs = []  # (label, input, output, expected)
for gen, out in [(PM / "gen", PM / "out"), (PM / "gen_big", PM / "out_big")]:
    for exp in sorted(out.glob("*.expected.json")):
        o = exp.with_name(exp.name.replace(".expected.json", ".pdf"))
        if not o.exists():
            continue
        if o.name.endswith(".reapply.pdf"):
            inp = out / o.name.replace(".reapply.pdf", ".pdf")
        else:
            inp = gen / o.name
        pairs.append((o.stem, inp, o, json.loads(exp.read_text(encoding="utf-8"))))
files = sorted({str(p) for _, i, o, _ in pairs for p in (i, o)})
readers = {f"pdfjs-{v}": ["node", HERE / "pdfjs_legacy.mjs", v] for v in ("2", "3", "4")}
readers |= {f"PyPDF2-{v}": [UV, "run", "--quiet", "--no-project", "--python", "3.12", "--with", f"PyPDF2=={v}",
                            "python", HERE / "pypdf2_legacy.py"] for v in ("1.26.0", "2.12.1", "3.0.1")}
R = {}
for name, cmd in readers.items():
    p = subprocess.run([str(c) for c in cmd] + files, capture_output=True, cwd=HERE, timeout=1800)
    for line in p.stdout.decode().splitlines():
        try:
            j = json.loads(line)
        except json.JSONDecodeError:
            continue
        R[(name, str(Path(j["file"])))] = j
key = lambda xs: [(x["title"], x["level"], x["page_index"]) for x in xs]
fails, table = [], []
for label, inp, o, exp in pairs:
    row = [label]
    for name in readers:
        ro, ri = R.get((name, str(o)), {}), R.get((name, str(inp)), {})
        if not ro.get("ok"):
            st = "err"; fails.append(f"{label} [{name}] cannot read output: {ro.get('error')}")
        elif key(ro["outline"]) != key(exp):
            st = "diff"; fails.append(f"{label} [{name}] outline {key(ro['outline'])[:2]} ... want {key(exp)[:2]} "
                                      f"(n={len(ro['outline'])} vs {len(exp)})")
        else:
            new = sorted(set(ro.get("warnings", [])) - set(ri.get("warnings", [])))
            new = [w for w in new if "SyntaxWarning" not in w and "invalid escape" not in w]
            st = "warn" if new else "ok"
            if new:
                fails.append(f"{label} [{name}] new warnings {new[:3]}")
        row.append(st)
    table.append(row)
names = list(readers)
print(f"{'output':<34}" + "".join(f"{n:>14}" for n in names))
for r in table:
    print(f"{r[0]:<34}" + "".join(f"{s:>14}" for s in r[1:]))
print(f"\n{sum(all(s == 'ok' for s in r[1:]) for r in table)}/{len(table)} outputs clean in all legacy readers")
for f in fails:
    print("  - " + f[:400])
(PM / "out" / "legacy_report.json").write_text(json.dumps({"fails": fails, "table": table}, ensure_ascii=False,
                                                          indent=1), encoding="utf-8")
sys.exit(1 if fails else 0)
