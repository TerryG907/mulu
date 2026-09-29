# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pikepdf>=9",
#   "pypdf>=5",
#   "pypdfium2>=4.30",
# ]
# ///
"""
gate.py -- the REAL-SCAN GATE: run mulu's writer on your own books and check every output with
the same five independent readers as tools/verify (PDFKit, qpdf, PDFium, pypdf, pdf.js) plus
`mulu dump-outline`. Use tools/gate/run_gate.sh; it builds mulu and calls this.

    uv run --python 3.12 tools/gate/gate.py --mulu PATH <folder> [--toc-csv FILE] [--recursive]
                                            [--report FILE] [--keep-temp]
    uv run --python 3.12 tools/gate/gate.py --make-csv FILE <folder> [--recursive]

YOUR BOOKS ARE NEVER COPIED, MOVED, MODIFIED OR UPLOADED. They are only read. Each output is
written to a private temporary directory (mkdtemp, mode 0700), checked, and deleted right away;
the whole temporary directory is removed at the end (--keep-temp keeps it for debugging). All
readers run locally. The only file written outside the temp dir is the report (Markdown + JSON).

Per PDF:
  1. mulu info                       pages, xref kind, encrypted, existing outline
  2. mulu apply <book> toc5 -o tmp   a trivial 5-entry, 3-level TOC spread over the book
                                     (first page, 1/4, 1/2, 3/4, last page)
  3. checks on the output            prefix: output starts with every byte of the book, something was
                                       appended, the book itself is unchanged (SHA-256 before/after)
                                     readers: each of the 5 readers + dump-outline reports exactly the
                                       5 entries (title, level, page) and the book's page count, and
                                       emits no warning it did not already emit on the book itself
                                     check: qpdf's syntax check finds nothing new
  4. optional (book listed in --toc-csv with its printed-TOC pages):
                                     mulu detect-offset + mulu auto --toc-pages P -o tmp; the proposed
                                     outline is printed in the report for you to eyeball. Not part of
                                     the verdict.
Verdict: PASS if at most 2 writer failures across the folder. A writer failure is a book where
apply refused (exit 2) or any check in step 3 failed; each is listed with its reason. Failures
of kind "broken" (an output was produced but is wrong) are flagged separately: even one of those
needs to be looked at.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "tools" / "verify"))
import verify  # tools/verify/verify.py: readers, outline comparison, warning normalization)

READERS = verify.READERS            # pdfkit, qpdf, pdfium, pypdf, pdfjs
MAX_WRITER_FAILURES = 2
APPLY_TIMEOUT = 600
AUTO_TIMEOUT = 1800

# ============================================================================
# helpers
# ============================================================================


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def starts_with(big: Path, small: Path) -> tuple[bool, str]:
    """Streams both files: big[0:len(small)] == small and len(big) > len(small)."""
    ns, nb = small.stat().st_size, big.stat().st_size
    if nb <= ns:
        return False, f"output is {nb} bytes, not longer than the book ({ns} bytes)"
    with open(small, "rb") as a, open(big, "rb") as b:
        off = 0
        while True:
            x = a.read(1 << 20)
            if not x:
                return True, ""
            y = b.read(len(x))
            if x != y:
                i = next((k for k in range(min(len(x), len(y))) if x[k] != y[k]), min(len(x), len(y)))
                return False, f"output differs from the book at byte {off + i}"
            off += len(x)


def run(cmd, timeout) -> dict:
    t0 = time.monotonic()
    try:
        p = subprocess.run([str(c) for c in cmd], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"exit": None, "stdout": "", "stderr": f"timeout after {timeout}s", "seconds": timeout}
    except OSError as e:
        return {"exit": None, "stdout": "", "stderr": str(e), "seconds": 0}
    return {"exit": p.returncode, "stdout": p.stdout.decode("utf-8", errors="replace"),
            "stderr": p.stderr.decode("utf-8", errors="replace").strip(), "seconds": round(time.monotonic() - t0, 2)}


def toc5(n_pages: int) -> tuple[str, list[dict]]:
    """A trivial TOC: 5 entries, levels 0/1/2/1/0, CJK + ASCII + full-width, spread over the book."""
    pages = [1, max(1, n_pages // 4), max(1, n_pages // 2), max(1, (3 * n_pages) // 4), max(1, n_pages)]
    items = [("第一章 Mulu 闸门测试（开头）", 0), ("1.1 二级条目 Level 2", 1), ("1.1.1 三级条目：中间页", 2),
             ("1.2 二级条目 ３／４", 1), ("附录 最后一页 Last page", 0)]
    lines = ["# mulu gate: trivial 5-entry TOC (physical pages)"]
    expected = []
    for (title, level), pg in zip(items, pages):
        lines.append("\t" * level + title + "\t" + str(pg))
        expected.append({"title": title, "level": level, "page_index": pg - 1})
    return "\n".join(lines) + "\n", expected


def list_pdfs(folder: Path, recursive: bool) -> list[Path]:
    it = folder.rglob("*") if recursive else folder.iterdir()
    return sorted(p for p in it if p.is_file() and p.suffix.lower() == ".pdf" and not p.name.startswith("."))


def read_csv(path: Path) -> dict[str, str]:
    """file,toc_pages[,note] -- '#' lines are comments; blank toc_pages = skip."""
    out = {}
    with open(path, encoding="utf-8-sig", newline="") as f:
        for row in csv.reader(f):
            if not row or not row[0].strip() or row[0].lstrip().startswith("#"):
                continue
            if row[0].strip().lower() in ("file", "文件", "filename"):
                continue
            pages = row[1].strip().replace(" ", "").replace("，", ",").replace("－", "-").replace("—", "-") \
                if len(row) > 1 else ""
            if pages:
                out[row[0].strip()] = pages
    return out


# ============================================================================
# one book
# ============================================================================


def gate_book(mulu: Path, pdf: Path, rel: str, tmp: Path, idx: int, toc_pages: str | None, keep: bool) -> dict:
    res: dict = {"file": rel, "size": pdf.stat().st_size, "checks": {}, "status": None, "reasons": []}
    wd = tmp / f"b{idx:03d}"
    wd.mkdir(mode=0o700)
    t0 = time.monotonic()
    sha_before = sha256_file(pdf)

    def fail(kind: str, reason: str):
        res["reasons"].append(reason)
        # "broken" beats "refused" beats "error"
        rank = {"error": 0, "refused": 1, "broken": 2}
        if res["status"] is None or rank[kind] > rank.get(res["status"], -1):
            res["status"] = kind

    # 1. info
    r = run([mulu, "info", pdf], 120)
    info = None
    if r["exit"] == 0:
        try:
            info = json.loads(r["stdout"].strip().split("\n")[-1])
        except (json.JSONDecodeError, IndexError):
            info = None
    res["info"] = info
    if info is None:
        fail("refused" if r["exit"] == 2 else "error",
             f"mulu info: exit {r['exit']}: {r['stderr'][:300] or 'no JSON'}")
    n_pages = (info or {}).get("pages") or 0

    # 2. apply a trivial TOC
    out = wd / "out.pdf"
    if info is not None and n_pages > 0:
        toc_text, expected = toc5(n_pages)
        toc_path = wd / "toc5.txt"
        toc_path.write_text(toc_text, encoding="utf-8")
        r = run([mulu, "apply", pdf, toc_path, "-o", out], APPLY_TIMEOUT)
        res["apply"] = {"exit": r["exit"], "seconds": r["seconds"], "stderr": r["stderr"][:400]}
        if r["exit"] == 0:
            try:
                res["apply"].update(json.loads(r["stdout"].strip().split("\n")[-1]))
            except (json.JSONDecodeError, IndexError):
                pass
        if r["exit"] == 2:
            fail("refused", f"apply refused: {r['stderr'][:300]}")
            if out.exists():
                fail("broken", "apply refused but still wrote an output file")
        elif r["exit"] != 0:
            fail("error", f"apply exit {r['exit']}: {r['stderr'][:300]}")
        elif not out.exists():
            fail("broken", "apply exit 0 but no output file")
        else:
            # 3a. prefix + book unchanged
            ok, why = starts_with(out, pdf)
            res["checks"]["prefix"] = "ok" if ok else why
            if not ok:
                fail("broken", f"prefix: {why}")
            # 3b. readers (+ baseline on the book itself for warnings and page count)
            for rd in READERS + ["mulu"]:
                o = verify.run_reader(rd, out, mulu)
                b = verify.run_reader(rd, pdf, mulu) if rd != "mulu" else {"ok": True, "warnings": []}
                if not o.get("ok"):
                    if not b.get("ok"):
                        res["checks"][rd] = f"n/a ({rd} cannot read the book itself either)"
                        continue
                    res["checks"][rd] = f"err: {str(o.get('error'))[:200]}"
                    fail("broken", f"{rd} cannot read the output: {str(o.get('error'))[:200]}")
                    continue
                if not verify.outline_eq(o.get("outline"), expected):
                    d = verify.first_diff(o.get("outline"), expected)
                    res["checks"][rd] = f"diff: {d}"
                    fail("broken", f"{rd} reads a different outline: {d}")
                    continue
                if rd != "mulu" and o.get("pages") is not None and o.get("pages") != n_pages:
                    res["checks"][rd] = f"pages {o.get('pages')} != {n_pages}"
                    fail("broken", f"{rd} sees {o.get('pages')} pages, mulu info says {n_pages}")
                    continue
                if rd != "mulu" and b.get("ok"):
                    new_w = sorted({verify.norm_warn(w, out) for w in o.get("warnings", [])}
                                   - {verify.norm_warn(w, pdf) for w in b.get("warnings", [])})
                    if new_w:
                        res["checks"][rd] = f"new warnings: {new_w[:2]}"
                        fail("broken", f"{rd} warns on the output but not on the book: {new_w[:2]}")
                        continue
                res["checks"][rd] = "ok" if b.get("ok") else "ok (book itself unreadable)"
            # 3c. qpdf syntax check: nothing new
            ci = verify.run_json(verify.py_worker("check", pdf), timeout=600)
            co = verify.run_json(verify.py_worker("check", out), timeout=600)
            if not co.get("ok"):
                if ci.get("ok"):
                    res["checks"]["check"] = f"err: {str(co.get('error'))[:200]}"
                    fail("broken", f"qpdf check fails on the output: {str(co.get('error'))[:200]}")
                else:
                    res["checks"]["check"] = "n/a (qpdf cannot check the book itself)"
            else:
                pin = {verify.norm_warn(x, pdf) for x in ci.get("problems", []) + ci.get("warnings", [])} \
                    if ci.get("ok") else set()
                pout = {verify.norm_warn(x, out) for x in co.get("problems", []) + co.get("warnings", [])}
                new = sorted(pout - pin)
                res["checks"]["check"] = "ok" if not new else f"new: {new[:3]}"
                if new:
                    fail("broken", f"qpdf check reports new problems on the output: {new[:3]}")
        if out.exists() and not keep:
            out.unlink()

    sha_after = sha256_file(pdf)
    if sha_after != sha_before:
        fail("broken", "THE BOOK ITSELF CHANGED while mulu ran (SHA-256 differs)")
    res["sha256_unchanged"] = sha_after == sha_before

    # 4. optional: detect-offset + auto for eyeballing
    if toc_pages and info is not None and n_pages > 0:
        a: dict = {"toc_pages": toc_pages}
        r = run([mulu, "detect-offset", pdf], AUTO_TIMEOUT)
        a["detect_offset"] = {"exit": r["exit"], "stderr": r["stderr"][-600:]}
        try:
            js = json.loads(r["stdout"].strip() or "null")
        except json.JSONDecodeError:
            js = None
        if isinstance(js, dict):
            a["detect_offset"]["result"] = {k: js[k] for k in ("offset", "confidence", "samples", "agreeing", "votes",
                                                             "status", "best_guess", "reason") if k in js}
        else:
            a["detect_offset"]["stdout"] = r["stdout"].strip()[:600]
        auto_out = wd / "auto.pdf"
        r = run([mulu, "auto", pdf, "--toc-pages", toc_pages, "-o", auto_out], AUTO_TIMEOUT)
        a["auto"] = {"exit": r["exit"], "seconds": r["seconds"], "stdout": r["stdout"].strip()[-4000:],
                     "stderr": r["stderr"][-4000:]}
        if r["exit"] == 0 and auto_out.exists():
            ok, why = starts_with(auto_out, pdf)
            a["prefix"] = "ok" if ok else why
            d = run([mulu, "dump-outline", auto_out], 300)
            try:
                a["outline"] = json.loads(d["stdout"]) if d["exit"] == 0 else None
            except json.JSONDecodeError:
                a["outline"] = None
            if not keep:
                auto_out.unlink()
        res["auto"] = a
        if sha256_file(pdf) != sha_before:
            fail("broken", "THE BOOK ITSELF CHANGED during mulu auto (SHA-256 differs)")

    if res["status"] is None:
        res["status"] = "pass"
    res["seconds"] = round(time.monotonic() - t0, 1)
    if not keep:
        shutil.rmtree(wd, ignore_errors=True)
    return res


# ============================================================================
# report
# ============================================================================

STATUS_ZH = {"pass": "通过", "refused": "拒绝（退出码 2）", "broken": "输出有误", "error": "异常"}


def write_report(rows: list[dict], folder: Path, mulu: Path, verdict: dict, md_path: Path):
    L = []
    L.append("# Mulu 真实扫描书闸门报告")
    L.append("")
    L.append(f"- 时间：{time.strftime('%Y-%m-%d %H:%M:%S')}")
    L.append(f"- 文件夹：`{folder}`（共 {len(rows)} 个 PDF；只读取，未复制、未上传）")
    L.append(f"- mulu：`{mulu}`")
    L.append(f"- **结论：{verdict['verdict']}**（写入失败 {verdict['failures']} 本，上限 {MAX_WRITER_FAILURES}；"
             f"其中输出有误 {verdict['broken']} 本）")
    if verdict["broken"]:
        L.append("- 注意：有“输出有误”的书。即使总数没超上限，也请把下面的原因发给开发者逐条排查。")
    L.append("")
    L.append("## 每本书")
    L.append("")
    L.append("| # | 文件 | 页数 | 大小 | xref | 加密 | 原有目录 | 结果 | prefix | " + " | ".join(READERS)
             + " | mulu | check | 用时 |")
    L.append("|---|---|---|---|---|---|---|---|---|" + "---|" * (len(READERS) + 3))
    for i, r in enumerate(rows, 1):
        info = r.get("info") or {}
        ck = r.get("checks", {})

        def cell(k, ck=ck):
            v = ck.get(k)
            return "-" if v is None else ("ok" if v == "ok" else ("n/a" if str(v).startswith("n/a") else "✗"))
        size = f"{r['size'] / 1e6:.1f} MB" if r["size"] >= 1e6 else f"{r['size'] / 1e3:.0f} KB"
        L.append(f"| {i} | {r['file']} | {info.get('pages', '-')} | {size} | {info.get('xref', '-')} | "
                 f"{'是' if info.get('encrypted') else '否' if info else '-'} | "
                 f"{'有' if info.get('hasOutline') else '无' if info else '-'} | {STATUS_ZH[r['status']]} | "
                 f"{cell('prefix')} | " + " | ".join(cell(k) for k in READERS)
                 + f" | {cell('mulu')} | {cell('check')} | {r['seconds']}s |")
    fails = [r for r in rows if r["status"] != "pass"]
    if fails:
        L.append("")
        L.append("## 失败原因")
        L.append("")
        for r in fails:
            L.append(f"- **{r['file']}**（{STATUS_ZH[r['status']]}）")
            for why in r["reasons"]:
                L.append(f"  - {why}")
    autos = [r for r in rows if r.get("auto")]
    if autos:
        L.append("")
        L.append("## 自动生成的目录（请人工核对）")
        L.append("")
        L.append("逐条对照书上印刷的目录：标题是否认对、层级是否对、点开后是否跳到正文对应那一页。"
                 "这一部分不计入结论。")
        for r in autos:
            a = r["auto"]
            L.append("")
            L.append(f"### {r['file']}（目录页 {a['toc_pages']}）")
            L.append("")
            do = a.get("detect_offset", {})
            if do.get("result"):
                L.append(f"- detect-offset：退出码 {do.get('exit')}，`{json.dumps(do['result'], ensure_ascii=False)}`")
            else:
                L.append(f"- detect-offset：退出码 {do.get('exit')}，输出 `{(do.get('stdout') or do.get('stderr') or '')[:300]}`")
            au = a.get("auto", {})
            L.append(f"- auto：退出码 {au.get('exit')}，用时 {au.get('seconds')}s"
                     + ("（mulu 拒绝了，原因见下方说明；置信度不足时按设计拒绝，不猜）" if au.get("exit") == 2 else "")
                     + (f"，输出前缀 {a.get('prefix')}" if a.get("prefix") else ""))
            said = "\n".join(x for x in (au.get("stdout", ""), au.get("stderr", "")) if x).strip()
            if said:
                L.append("")
                L.append("mulu auto 的说明：")
                L.append("")
                L.append("```")
                L.extend(said.split("\n")[-60:])
                L.append("```")
            ol = a.get("outline")
            if ol:
                L.append("")
                L.append(f"提议的目录（{len(ol)} 条；物理页码，从 1 开始）：")
                L.append("")
                L.append("```")
                for it in ol:
                    L.append(f"{'    ' * it.get('level', 0)}{it.get('title', '')}  → 第 {it.get('page_index', -2) + 1} 页")
                L.append("```")
    L.append("")
    L.append("## 每一项检查的含义")
    L.append("")
    L.append("- prefix：输出文件的开头与原书逐字节相同，后面追加了一段；原书的 SHA-256 在运行前后不变。")
    L.append("- pdfkit / qpdf / pdfium / pypdf / pdfjs：五个独立阅读器读出的目录与写入的 5 条完全一致"
             "（标题、层级、页码），页数与 mulu info 一致，并且没有出现原书上没有的警告。mulu：mulu 自己的 dump-outline。")
    L.append("- check：qpdf 语法检查在输出上没有发现原书上没有的问题。")
    L.append("- 拒绝（退出码 2）：mulu 明确拒绝处理（例如加密文件），没有生成输出，原书不受影响。")
    md_path.write_text("\n".join(L) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder")
    ap.add_argument("--mulu", default=None)
    ap.add_argument("--toc-csv", default=None, help="CSV: file,toc_pages (e.g. 'book.pdf,5-7')")
    ap.add_argument("--make-csv", default=None, help="write a CSV template listing the folder's PDFs and exit")
    ap.add_argument("--recursive", action="store_true")
    ap.add_argument("--report", default=None, help="report path (.md; a .json is written next to it)")
    ap.add_argument("--keep-temp", action="store_true")
    args = ap.parse_args()

    folder = Path(args.folder).expanduser().resolve()
    if not folder.is_dir():
        print(f"gate: {folder} is not a folder", file=sys.stderr)
        return 2
    pdfs = list_pdfs(folder, args.recursive)

    if args.make_csv:
        dst = Path(args.make_csv)
        if dst.exists():
            print(f"gate: {dst} already exists; not overwriting", file=sys.stderr)
            return 2
        with open(dst, "w", encoding="utf-8", newline="") as f:
            f.write("# 每行一本书：文件名,目录所在的物理页（PDF 阅读器里显示的页码，如 5-7 或 5,6,8）。不想试 auto 的书留空。\n")
            w = csv.writer(f)
            w.writerow(["file", "toc_pages"])
            for p in pdfs:
                w.writerow([str(p.relative_to(folder)), ""])
        print(f"gate: wrote {dst} with {len(pdfs)} book(s); fill in the toc_pages column")
        return 0

    if not args.mulu or not Path(args.mulu).exists():
        print("gate: --mulu PATH is required (run_gate.sh builds it)", file=sys.stderr)
        return 2
    mulu = Path(args.mulu).resolve()
    if not pdfs:
        print(f"gate: no .pdf files in {folder}", file=sys.stderr)
        return 2
    toc_map = read_csv(Path(args.toc_csv)) if args.toc_csv else {}
    unknown = sorted(set(toc_map) - {str(p.relative_to(folder)) for p in pdfs})
    for u in unknown:
        print(f"gate: warning: CSV lists '{u}', which is not in the folder", file=sys.stderr)

    verify.ensure_tools(quiet=False)
    tmp = Path(tempfile.mkdtemp(prefix="mulu-gate-"))
    os.chmod(tmp, 0o700)
    rows = []
    t0 = time.monotonic()
    try:
        for i, p in enumerate(pdfs, 1):
            rel = str(p.relative_to(folder))
            print(f"[gate] {i}/{len(pdfs)} {rel} ...", end="", flush=True)
            try:
                r = gate_book(mulu, p, rel, tmp, i, toc_map.get(rel), args.keep_temp)
            except Exception as e:  # noqa: BLE001  -- one bad book must not stop the run
                r = {"file": rel, "size": p.stat().st_size, "checks": {}, "status": "error",
                     "reasons": [f"gate crashed on this book: {type(e).__name__}: {e}"], "seconds": 0}
            rows.append(r)
            extra = "" if r["status"] == "pass" else f"  -- {r['reasons'][0][:160]}"
            print(f" {r['status'].upper()} ({r['seconds']}s){extra}", flush=True)
    finally:
        if not args.keep_temp:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"[gate] temp files kept in {tmp}")

    failures = [r for r in rows if r["status"] != "pass"]
    broken = [r for r in rows if r["status"] == "broken"]
    verdict = {"verdict": "PASS" if len(failures) <= MAX_WRITER_FAILURES else "FAIL",
               "failures": len(failures), "broken": len(broken), "books": len(rows),
               "max_failures": MAX_WRITER_FAILURES, "seconds": round(time.monotonic() - t0, 1)}
    stamp = time.strftime("%Y%m%d-%H%M%S")
    md = Path(args.report) if args.report else HERE / "reports" / f"gate-{stamp}.md"
    md.parent.mkdir(parents=True, exist_ok=True)
    write_report(rows, folder, mulu, verdict, md)
    md.with_suffix(".json").write_text(json.dumps({"folder": str(folder), "mulu": str(mulu), "verdict": verdict,
                                                   "books": rows}, ensure_ascii=False, indent=1) + "\n",
                                       encoding="utf-8")
    print()
    print(f"[gate] {len(rows)} book(s): {len(rows) - len(failures)} pass, {len(failures)} writer failure(s)"
          f" ({len(broken)} broken output)")
    for r in failures:
        print(f"  {r['status']:8s} {r['file']}: {'; '.join(r['reasons'])[:300]}")
    print(f"[gate] VERDICT {verdict['verdict']} (PASS = at most {MAX_WRITER_FAILURES} writer failures)")
    if broken:
        print(f"[gate] note: {len(broken)} book(s) got a WRONG output (not a clean refusal) -- look at each one")
    print(f"[gate] report: {md}")
    return 0 if verdict["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
