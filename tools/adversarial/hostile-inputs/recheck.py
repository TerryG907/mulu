# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9", "pypdf>=5", "pypdfium2>=4.30"]
# ///
"""
recheck.py -- run tools/verify/verify.py unchanged, except that reader-helper stdout is split
on '\\n' only.  verify.run_json uses str.splitlines(), which also splits on U+2028/U+0085/...,
so a TOC title containing U+2028 makes every reader look broken (harness false positive).

    uv run --python 3.12 tools/adversarial/hostile-inputs/recheck.py run-all --mulu M --gen G --out O --only X
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "verify"))
import verify  # noqa: E402


def run_json(cmd, timeout=240) -> dict:
    try:
        p = subprocess.run([str(c) for c in cmd], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"timeout after {timeout}s"}
    lines = [ln for ln in p.stdout.decode("utf-8", errors="replace").strip().split("\n") if ln.strip()]
    if not lines:
        return {"ok": False, "error": f"exit {p.returncode}, no output"}
    try:
        res = json.loads(lines[-1])
    except json.JSONDecodeError:
        return {"ok": False, "error": f"exit {p.returncode}, non-JSON output: {lines[-1][:200]}"}
    if isinstance(res, dict):
        res.setdefault("exit", p.returncode)
    return res


verify.run_json = run_json
if __name__ == "__main__":
    sys.exit(verify.main())
