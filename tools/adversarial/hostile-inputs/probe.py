# /// script
# requires-python = ">=3.12"
# ///
"""
probe.py -- run `mulu apply|info|dump-outline` on every fixture of a gen dir with a timeout, and report
crashes (signal exits), hangs, wrong exit codes, max RSS and wall time.  No readers; see verify.py for those.

    uv run --python 3.12 tools/adversarial/hostile-inputs/probe.py <mulu> <gen-dir> <out-dir> [--timeout S]
"""
import json
import re
import signal
import subprocess
import sys
import time
from pathlib import Path


def run(cmd, timeout):
    t = time.monotonic()
    try:
        p = subprocess.run(["/usr/bin/time", "-l", *map(str, cmd)], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"rc": "TIMEOUT", "ms": int(timeout * 1000), "rss_mb": None, "err": ""}
    ms = int((time.monotonic() - t) * 1000)
    err = p.stderr.decode(errors="replace")
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    rss = int(m.group(1)) / 1e6 if m else None
    # /usr/bin/time reports a signal death as "Command terminated abnormally" + its own exit code
    rc = p.returncode
    if "terminated abnormally" in err or rc > 128:
        sig = rc - 128 if rc > 128 else None
        rc = f"SIG{signal.Signals(sig).name if sig else '?'}"
    own = "\n".join(ln for ln in err.splitlines() if not re.match(r"^\s+\d+\s+[a-z]", ln) and "real" not in ln
                    and "terminated abnormally" not in ln).strip()
    return {"rc": rc, "ms": ms, "rss_mb": rss, "err": own[:300], "out": p.stdout.decode(errors="replace")[:300]}


def main():
    mulu, gen, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    timeout = float(sys.argv[sys.argv.index("--timeout") + 1]) if "--timeout" in sys.argv else 60
    out.mkdir(parents=True, exist_ok=True)
    man = json.loads((gen / "manifest.json").read_text())["fixtures"]
    rows = []
    for name, f in man.items():
        pdf, toc = gen / f"{name}.pdf", gen / f"{name}.toc.txt"
        o = out / f"{name}.pdf"
        o.unlink(missing_ok=True)
        cmd = [mulu, "apply", pdf, toc, "-o", o]
        if f.get("offset"):
            cmd += ["--offset", str(f["offset"])]
        a = run(cmd, timeout)
        i = run([mulu, "info", pdf], timeout)
        d = run([mulu, "dump-outline", pdf], timeout)
        created = o.exists()
        want = f["expect"]
        verdict = "ok"
        bad = [x for x in (a, i, d) if str(x["rc"]).startswith(("SIG", "TIMEOUT"))]
        if bad:
            verdict = "CRASH/HANG"
        elif want == "refuse" and (a["rc"] != 2 or created):
            verdict = "SILENT-SUCCESS" if a["rc"] == 0 else f"bad-refusal(rc={a['rc']},created={created})"
        elif want == "apply" and a["rc"] != 0:
            verdict = "REFUSED"
        rows.append((name, want, a["rc"], i["rc"], d["rc"], a["ms"], a["rss_mb"], verdict, a["err"]))
    w = max(len(r[0]) for r in rows)
    print(f"{'fixture':<{w}}  expect  apply  info  dump    ms   rssMB  verdict / stderr")
    for r in rows:
        rss = f"{r[6]:.0f}" if r[6] else "-"
        print(f"{r[0]:<{w}}  {r[1]:<6}  {str(r[2]):>5}  {str(r[3]):>4}  {str(r[4]):>4}  {r[5]:>5}  {rss:>6}  {r[7]}  {r[8]}")


if __name__ == "__main__":
    main()
