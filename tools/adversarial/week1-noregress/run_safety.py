"""
run_safety.py -- week-1 NO-REGRESSION + SAFETY audit of `mulu ocr-toc / detect-offset / auto`.

  uv run --python 3.12 run_safety.py [--only substr,substr] [--list]

Every case runs ONE mulu process at a time under `/usr/bin/time -l nice -n 15`, in a fresh
empty working directory (work/<case>/cwd) so stray files are visible. For every case it records
exit status, wall time, peak RSS / peak memory footprint, and checks:
  * every input file is byte-identical afterwards (sha256), same inode, same mtime;
  * no file appears or disappears in the input directory, the output directory or the cwd,
    except the expected output (and the --toc-out draft, which auto writes even on refusal);
  * on refusal (exit != 0): the -o path does not exist (or, if it pre-existed, is unchanged);
  * on success: the output starts with every input byte; the outline (mulu dump-outline) is
    scored against the generator's truth file (title found / page correct).
Writes results.json and prints a table.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MULU = ROOT / ".build/release/mulu"
WORK = HERE / "work"
VEC = HERE / "vec"
BOOKS = HERE / "books"


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fstate(p: Path):
    st = os.lstat(p)
    return {"sha": sha(p) if p.is_file() else None, "ino": st.st_ino, "mtime": st.st_mtime_ns, "size": st.st_size}


def listing(d: Path) -> set:
    try:
        return {x.name for x in d.iterdir()}
    except FileNotFoundError:
        return set()


def norm_title(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    return re.sub(r"\s+", "", s)


def score(out: Path, truth_path: Path | None):
    if truth_path is None or not truth_path.exists():
        return None
    truth = json.loads(truth_path.read_text())
    r = subprocess.run([str(MULU), "dump-outline", str(out)], capture_output=True, text=True)
    if r.returncode != 0:
        return {"error": r.stderr.strip()[:200]}
    items = json.loads(r.stdout)
    # in-order alignment by normalized title (duplicates such as 本章小结 pair up correctly)
    found = correct = 0
    wrong = []
    body = [e for e in truth["entries"] if not e.get("front_matter")]
    j = 0
    for e in body:
        t = norm_title(e["title"])
        k = next((k for k in range(j, min(len(items), j + 6)) if norm_title(items[k]["title"]) == t), None)
        if k is None:
            continue
        j = k + 1
        found += 1
        got = items[k]["page_index"] + 1
        if got == e["physical_page"]:
            correct += 1
        else:
            wrong.append(f"{e['title']}: truth {e['physical_page']} got {got}")
    by_pos = None
    return {"truth_body_entries": len(body), "outline_items": len(items), "title_found": found,
            "page_correct_of_found": correct, "page_correct_by_position": by_pos, "wrong_pages": wrong[:8],
            "n_wrong": len(wrong)}


def run_case(c: dict) -> dict:
    name = c["name"]
    wd = WORK / name
    if wd.exists():
        shutil.rmtree(wd)
    cwd = wd / "cwd"
    cwd.mkdir(parents=True)
    outdir = wd / "out"
    outdir.mkdir()
    for f in c.get("setup", []):
        f(wd)
    args = [a.replace("{OUT}", str(outdir)).replace("{WD}", str(wd)) for a in c["args"]]
    inputs = [Path(p.replace("{WD}", str(wd))) for p in c["inputs"]]
    out = Path(c["out"].replace("{OUT}", str(outdir)).replace("{WD}", str(wd))) if c.get("out") else None
    allowed_new = set(c.get("allowed_new", []))
    pre_out = fstate(out) if out and out.exists() else None
    before = {str(p): fstate(p) for p in inputs}
    dirs = {d for p in inputs for d in [p.parent]} | {outdir, cwd} | ({out.parent} if out else set())
    lst_before = {str(d): listing(d) for d in dirs}
    cmd = ["/usr/bin/time", "-l", "nice", "-n", "15", str(MULU)] + args
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if c.get("kill_after"):
        time.sleep(c["kill_after"])
        # signal mulu (the grandchild), not time/nice
        subprocess.run(["pkill", "-INT", "-f", f"{MULU} {args[0]} {args[1]}"])
    so, se = p.communicate(timeout=c.get("timeout", 3600))
    wall = time.monotonic() - t0
    rc = p.returncode
    m = re.search(r"(\d+)\s+maximum resident set size", se)
    rss = int(m.group(1)) if m else None
    m2 = re.search(r"(\d+)\s+peak memory footprint", se)
    peak = int(m2.group(1)) if m2 else None
    # strip time -l block from stderr
    se_mulu = "\n".join(l for l in se.splitlines() if not re.match(r"^\s+\d+(\.\d+)?\s+(real|user|sys)|^\s+\d+\s+[a-z]", l))
    problems = []
    for p_, st in before.items():
        now = fstate(Path(p_)) if Path(p_).exists() else None
        if now != st:
            problems.append(f"INPUT CHANGED: {p_} before={st} after={now}")
    for d, names in lst_before.items():
        now = listing(Path(d))
        new = now - names - ({out.name} if out and Path(d) == out.parent else set()) - allowed_new
        gone = names - now
        if new:
            problems.append(f"new files in {d}: {sorted(new)}")
        if gone:
            problems.append(f"files disappeared from {d}: {sorted(gone)}")
    ok_rc = c.get("expect_rc")
    if ok_rc is not None and rc not in (ok_rc if isinstance(ok_rc, (list, tuple)) else [ok_rc]):
        problems.append(f"exit {rc}, expected {ok_rc}")
    sc = None
    if out:
        if rc != 0:
            if pre_out is None and out.exists():
                problems.append(f"REFUSED/FAILED BUT OUTPUT EXISTS: {out}")
            if pre_out is not None and (not out.exists() or fstate(out) != pre_out):
                problems.append(f"REFUSED/FAILED BUT PRE-EXISTING OUTPUT CHANGED: {out}")
        elif c.get("expect_output", True) and "--dry-run" not in args:
            if not out.exists():
                problems.append("exit 0 but no output")
            else:
                ob = out.read_bytes()
                for p_ in inputs[:1]:
                    ib = Path(p_).read_bytes()
                    if not ob.startswith(ib) or len(ob) <= len(ib):
                        problems.append("output does not start with the input bytes")
                sc = score(out, Path(c["truth"]) if c.get("truth") else None)
    res = {"name": name, "why": c.get("why", ""), "rc": rc, "wall_s": round(wall, 2),
           "max_rss_mb": round(rss / 2**20, 1) if rss else None,
           "peak_footprint_mb": round(peak / 2**20, 1) if peak else None,
           "stdout_tail": so.strip().splitlines()[-6:], "stderr_tail": se_mulu.strip().splitlines()[-6:],
           "score": sc, "problems": problems}
    if c.get("check"):
        res["problems"] += c["check"](res, so, se_mulu, wd)
    return res


def cases():
    C = []
    vb = VEC
    # ---------- vector: 2000 pages, huge pages, extreme boxes
    C.append(dict(name="v_detect_big2000", why="2000-page sampling, folios offset 8", args=["detect-offset", str(vb / "big2000.pdf")],
                  inputs=[str(vb / "big2000.pdf")], expect_rc=0,
                  check=lambda r, so, se, wd: [] if '"offset":8' in so.replace(" ", "") else [f"offset not 8: {so[:200]}"]))
    C.append(dict(name="v_detect_big2000_nofolio", why="no folios -> refuse", args=["detect-offset", str(vb / "big2000_nofolio.pdf")],
                  inputs=[str(vb / "big2000_nofolio.pdf")], expect_rc=2))
    C.append(dict(name="v_detect_big2000_huge", why="2000 pages of 20000x20000 pt", args=["detect-offset", str(vb / "big2000_huge.pdf")],
                  inputs=[str(vb / "big2000_huge.pdf")], expect_rc=[0, 2]))
    C.append(dict(name="v_auto_big2000", why="auto on 2000 pages", args=["auto", str(vb / "big2000.pdf"), "--toc-pages", "3-6", "-o", "{OUT}/o.pdf"],
                  inputs=[str(vb / "big2000.pdf")], out="{OUT}/o.pdf", expect_rc=0, truth=str(vb / "big2000.truth.json")))
    C.append(dict(name="v_auto_big2000_nofolio", why="no folios -> refuse, no output",
                  args=["auto", str(vb / "big2000_nofolio.pdf"), "--toc-pages", "3-6", "-o", "{OUT}/o.pdf"],
                  inputs=[str(vb / "big2000_nofolio.pdf")], out="{OUT}/o.pdf", expect_rc=2))
    C.append(dict(name="v_auto_big2000_huge", why="auto, 2000 huge pages",
                  args=["auto", str(vb / "big2000_huge.pdf"), "--toc-pages", "3-6", "-o", "{OUT}/o.pdf"],
                  inputs=[str(vb / "big2000_huge.pdf")], out="{OUT}/o.pdf", expect_rc=[0, 2], truth=str(vb / "big2000_huge.truth.json")))
    C.append(dict(name="v_ocrtoc_huge20000", why="20000x20000 pt TOC page", args=["ocr-toc", str(vb / "huge20000.pdf"), "--pages", "3"],
                  inputs=[str(vb / "huge20000.pdf")], expect_rc=0))
    C.append(dict(name="v_ocrtoc_huge20000_dpi1200", why="20000 pt page at --dpi 1200 (cap must still hold)",
                  args=["ocr-toc", str(vb / "huge20000.pdf"), "--pages", "3", "--dpi", "1200"],
                  inputs=[str(vb / "huge20000.pdf")], expect_rc=0))
    C.append(dict(name="v_detect_huge20000", why="20000 pt pages", args=["detect-offset", str(vb / "huge20000.pdf")],
                  inputs=[str(vb / "huge20000.pdf")], expect_rc=[0, 2]))
    C.append(dict(name="v_auto_huge20000", why="auto on 20000 pt pages",
                  args=["auto", str(vb / "huge20000.pdf"), "--toc-pages", "3", "-o", "{OUT}/o.pdf"],
                  inputs=[str(vb / "huge20000.pdf")], out="{OUT}/o.pdf", expect_rc=[0, 2], truth=str(vb / "huge20000.truth.json")))
    for pg in range(1, 8):
        C.append(dict(name=f"v_ocrtoc_extreme_p{pg}", why="odd page boxes", args=["ocr-toc", str(vb / "extreme.pdf"), "--pages", str(pg)],
                      inputs=[str(vb / "extreme.pdf")], expect_rc=[0, 2]))
    C.append(dict(name="v_detect_extreme", why="odd page boxes", args=["detect-offset", str(vb / "extreme.pdf")],
                  inputs=[str(vb / "extreme.pdf")], expect_rc=2))
    C.append(dict(name="v_auto_extreme", why="odd page boxes -> refuse", args=["auto", str(vb / "extreme.pdf"), "--toc-pages", "1-7", "-o", "{OUT}/o.pdf"],
                  inputs=[str(vb / "extreme.pdf")], out="{OUT}/o.pdf", expect_rc=2))

    # ---------- output-path safety (fast refusals before OCR)
    def mk_copy(wd, name="in.pdf", src=vb / "huge20000.pdf"):
        shutil.copyfile(src, wd / name)

    def mk_symlink(wd):
        mk_copy(wd)
        os.symlink(wd / "in.pdf", wd / "out" / "link.pdf")

    def mk_hardlink(wd):
        mk_copy(wd)
        os.link(wd / "in.pdf", wd / "out" / "hard.pdf")

    def mk_sentinel(wd):
        (wd / "out" / "o.pdf").write_bytes(b"SENTINEL - must survive a refusal\n")

    C.append(dict(name="p_out_is_input", why="-o == input", setup=[mk_copy],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "-o", "{WD}/in.pdf"], inputs=["{WD}/in.pdf"], expect_rc=[1, 2]))
    C.append(dict(name="p_out_symlink_to_input", why="-o is a symlink to the input", setup=[mk_symlink],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "-o", "{OUT}/link.pdf"], inputs=["{WD}/in.pdf"], expect_rc=[1, 2]))
    C.append(dict(name="p_out_hardlink_to_input", why="-o is a hard link to the input", setup=[mk_hardlink],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "-o", "{OUT}/hard.pdf"], inputs=["{WD}/in.pdf"], expect_rc=[1, 2]))
    C.append(dict(name="p_out_case_variant", why="-o differs from the input only in case (APFS is case-insensitive)", setup=[mk_copy],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "-o", "{WD}/IN.PDF"], inputs=["{WD}/in.pdf"], expect_rc=[1, 2]))
    C.append(dict(name="p_tocout_is_input", why="--toc-out == input", setup=[mk_copy],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "--dry-run", "--toc-out", "{WD}/in.pdf"], inputs=["{WD}/in.pdf"], expect_rc=[1, 2]))
    C.append(dict(name="p_out_nodir", why="-o in a missing directory", setup=[mk_copy],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "-o", "{WD}/nodir/o.pdf"], inputs=["{WD}/in.pdf"], expect_rc=[1, 2]))
    C.append(dict(name="p_out_is_directory", why="-o names an existing directory", setup=[mk_copy],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "-o", "{OUT}"], inputs=["{WD}/in.pdf"], expect_rc=[1, 2]))
    C.append(dict(name="p_refusal_keeps_existing_output", why="refusal must not touch a pre-existing -o file",
                  setup=[lambda wd: mk_copy(wd, src=vb / "big2000_nofolio.pdf"), mk_sentinel],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3-6", "-o", "{OUT}/o.pdf"], inputs=["{WD}/in.pdf"], out="{OUT}/o.pdf", expect_rc=2))
    C.append(dict(name="p_refusal_tocout_draft", why="refusal with --toc-out: draft written (documented), no -o",
                  setup=[lambda wd: mk_copy(wd, src=vb / "big2000_nofolio.pdf")],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3-6", "-o", "{OUT}/o.pdf", "--toc-out", "{OUT}/draft.txt"],
                  inputs=["{WD}/in.pdf"], out="{OUT}/o.pdf", allowed_new=["draft.txt"], expect_rc=2))
    C.append(dict(name="p_dry_run_writes_nothing", why="--dry-run", setup=[mk_copy],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "--dry-run"], inputs=["{WD}/in.pdf"], expect_rc=[0, 2]))
    C.append(dict(name="p_sigint_midrun", why="SIGINT during OCR: no output, no temp file",
                  setup=[lambda wd: mk_copy(wd, src=vb / "big2000.pdf")],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3-6", "-o", "{OUT}/o.pdf"], inputs=["{WD}/in.pdf"], out="{OUT}/o.pdf",
                  kill_after=4, expect_rc=None))
    C.append(dict(name="p_ocrtoc_debugdir_is_input", why="--debug-dir names the input file", setup=[mk_copy],
                  args=["ocr-toc", "{WD}/in.pdf", "--pages", "3", "--debug-dir", "{WD}/in.pdf"], inputs=["{WD}/in.pdf"], expect_rc=[0, 2]))

    def ro_dir(wd):
        mk_copy(wd)
        os.chmod(wd / "out", 0o555)
    C.append(dict(name="p_out_readonly_dir", why="-o in a read-only directory: clean failure, no temp", setup=[ro_dir],
                  args=["auto", "{WD}/in.pdf", "--toc-pages", "3", "-o", "{OUT}/o.pdf"], inputs=["{WD}/in.pdf"], out="{OUT}/o.pdf", expect_rc=[1, 2]))

    # ---------- scanned books
    for b in ["w1_book120", "w1_nofolio", "w1_sawtooth", "w1_plates_mid", "w1_plates_late", "w1_plates_mid2", "w1_plates_mid8"]:
        pdf = BOOKS / f"{b}.pdf"
        tj = BOOKS / f"{b}.truth.json"
        if not pdf.exists():
            continue
        truth = json.loads(tj.read_text())
        tp = truth["toc_pages_arg"]
        C.append(dict(name=f"s_detect_{b}", why="detect-offset", args=["detect-offset", str(pdf)], inputs=[str(pdf)],
                      expect_rc=0 if b == "w1_book120" else None))
        C.append(dict(name=f"s_auto_{b}", why="auto", args=["auto", str(pdf), "--toc-pages", tp, "-o", "{OUT}/o.pdf"],
                      inputs=[str(pdf)], out="{OUT}/o.pdf", expect_rc=0 if b == "w1_book120" else None, truth=str(tj)))
    return C


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--json", default=str(HERE / "results.json"))
    a = ap.parse_args()
    cs = cases()
    if a.only:
        keys = a.only.split(",")
        cs = [c for c in cs if any(c["name"].startswith(k) for k in keys)]
    if a.list:
        for c in cs:
            print(c["name"], "-", c.get("why", ""))
        return 0
    WORK.mkdir(exist_ok=True)
    prev = {}
    if Path(a.json).exists():
        prev = {r["name"]: r for r in json.loads(Path(a.json).read_text())}
    for c in cs:
        r = run_case(c)
        prev[r["name"]] = r
        flag = "OK " if not r["problems"] else "BAD"
        sc = r["score"]
        s = ""
        if sc and "truth_body_entries" in sc:
            s = f" score: {sc['page_correct_of_found']}/{sc['title_found']} pages ok of found, {sc['truth_body_entries']} truth, {sc['outline_items']} items"
        print(f"{flag} {r['name']:34} rc={r['rc']:<3} {r['wall_s']:7.1f}s rss={r['max_rss_mb']}MB peak={r['peak_footprint_mb']}MB{s}", flush=True)
        for p in r["problems"]:
            print("     !", p, flush=True)
        if r["rc"] != 0:
            print("     stderr:", " | ".join(r["stderr_tail"][-3:])[:400], flush=True)
        Path(a.json).write_text(json.dumps(list(prev.values()), ensure_ascii=False, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
