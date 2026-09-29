# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "rapidfuzz>=3.6",
# ]
# ///
"""
eval_books.py -- score the scanned-book pipeline (OCR -> printed TOC -> offset -> outline)
against the synthetic books in Fixtures/books (tools/fixtures/make_books.py).

    uv run --python 3.12 tools/eval/eval_books.py [--mulu PATH] [--only a,b] [--json FILE]
                                                  [--out DIR] [--parse-auto] [--keep-pdfs]
                                                  [--no-thresholds] [--jobs N]

Everything goes through the CLI (the contract, not the Swift API). Per book:

  stage       command                                                    scored against
  ocr         mulu ocr-toc <pdf> --pages <toc_pages>                     <book>.toc_lines.txt (whole-text CER)
  parse       mulu toc parse raw.txt --offset 0                          truth entries: title CER, printed page, level
  parse*      mulu toc parse <book>.toc_lines.txt --offset 0             same, on a PERFECT transcription (parser only)
  offset      mulu detect-offset <pdf>                                   truth offset (+ confidence, samples)
  parse-auto  mulu toc parse raw.txt --offset auto --pdf <pdf>           physical pages      (only with --parse-auto)
  auto        mulu auto <pdf> --toc-pages <toc_pages> -o out.pdf         mulu dump-outline out.pdf vs truth, + prefix check

SCORING
  Titles are normalized before comparing: NFKC (full-width -> ASCII, U+3000 -> space), then every
  whitespace character removed. CER = Levenshtein(pred, truth) / len(truth).
  Predicted entries are aligned to truth entries with a global alignment (cost = title CER, gap = 1;
  a pair with CER > 0.5 is never matched). An unmatched truth entry counts as CER 1, wrong page,
  wrong level. Extra predicted entries are counted separately ("extra").
  title_cer_body  the parse stages' title CER over the arabic (body) entries only; title_cer also
           counts the roman front-matter entries, which `toc parse` leaves out without --roman-offset.
  page     parse stages: predicted page == printed page, over arabic truth entries (roman front-matter
           entries have no printed arabic page; they are reported as "front found").
  level    predicted level == truth level (0-based printed hierarchy).
  e2e      auto stage: an entry is correct iff title CER <= 5% and page_index == physical_page - 1.
           e2e_body = over arabic entries; e2e_all = over all entries incl. roman front matter.
           exact = every truth entry correct and no extra entries.
  ocr CER  the raw OCR text vs the perfect transcription, both normalized as above and with dot
           leaders (… · . — - _ ･ ‥) removed: a character-level measure of the OCR alone.

THRESHOLDS (exit 1 when missed; --no-thresholds reports only). Chosen as the bar for "one command
works on a typical scanned book"; see Fixtures/books/eval.json for the numbers of the last run.
  detect-offset never confidently wrong (a null offset = abstaining is allowed) and correct on
  >= all-but-1 books, mean e2e_body >= 0.90, no book with e2e_body < 0.60
  unless `mulu auto` refused it (exit 2, the documented low-confidence path), and at most 2 refusals.

Exit: 0 thresholds met, 1 missed, 3 the CLI lacks one of the subcommands (the parts that exist are
still run and reported), 2 usage / environment error.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

from rapidfuzz.distance import Levenshtein

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BOOKS = ROOT / "Fixtures" / "books"
OUT = ROOT / "Fixtures" / "out" / "books"

STAGE_TIMEOUT = 600
E2E_CER = 0.05
MATCH_MAX_CER = 0.5
LEADERS = re.compile(r"[\.…·・･‥—―─\-_·•∙⋯]")

# ============================================================================
# text helpers
# ============================================================================


def norm_title(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    return "".join(ch for ch in s if not ch.isspace())


def norm_ocr_text(s: str) -> str:
    return LEADERS.sub("", norm_title(s))


def cer(pred: str, truth: str) -> float:
    p, t = norm_title(pred), norm_title(truth)
    if not t:
        return 0.0 if not p else 1.0
    return min(1.0, Levenshtein.distance(p, t) / len(t))


MULU_LINE = re.compile(r"^(?P<indent>[\t 　]*)(?P<title>.*?)[\t 　]+(?P<page>\S+)[\t ]*$")


def parse_mulu_toc(text: str) -> list[dict]:
    """A Mulu TOC (the output of `toc parse`) -> [{title, level, page(int|None), raw_page}].
    Lenient on purpose: a page token that is not an integer (a flagged roman page, say) is kept
    as page None so the entry still counts for title and level."""
    out = []
    for ln in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if not ln.strip() or ln.lstrip(" \t").startswith("#"):
            continue
        m = MULU_LINE.match(ln)
        if not m:
            out.append({"title": ln.strip(), "level": 0, "page": None, "raw_page": None})
            continue
        ind = m.group("indent")
        level = ind.count("\t") + ind.count(" ") // 2 + ind.count("　")
        tok = m.group("page")
        page = int(tok) if re.fullmatch(r"-?\d+", tok) else None
        out.append({"title": m.group("title").strip(), "level": level, "page": page, "raw_page": tok})
    return out


def align(pred: list[dict], truth: list[dict]) -> list[tuple[int | None, int | None, float]]:
    """Global alignment of predicted to truth entries by title. Returns (pi, ti, cer) triples in
    order; pi or ti is None for a gap."""
    n, m = len(pred), len(truth)
    pt = [norm_title(p["title"]) for p in pred]
    tt = [norm_title(t["title"]) for t in truth]
    INF = float("inf")
    cost = [[INF] * (m + 1) for _ in range(n + 1)]
    back = [[None] * (m + 1) for _ in range(n + 1)]
    cost[0][0] = 0.0
    for i in range(n + 1):
        for j in range(m + 1):
            c = cost[i][j]
            if c == INF:
                continue
            if i < n and c + 1 < cost[i + 1][j]:
                cost[i + 1][j], back[i + 1][j] = c + 1, (i, j, "p")
            if j < m and c + 1 < cost[i][j + 1]:
                cost[i][j + 1], back[i][j + 1] = c + 1, (i, j, "t")
            if i < n and j < m:
                t = tt[j]
                d = (Levenshtein.distance(pt[i], t) / len(t)) if t else (0.0 if not pt[i] else 1.0)
                if d <= MATCH_MAX_CER and c + d < cost[i + 1][j + 1]:
                    cost[i + 1][j + 1], back[i + 1][j + 1] = c + d, (i, j, "m")
    out = []
    i, j = n, m
    while (i, j) != (0, 0):
        pi, pj, kind = back[i][j]
        if kind == "m":
            out.append((pi, pj, min(1.0, Levenshtein.distance(pt[pi], tt[pj]) / max(1, len(tt[pj])))))
        elif kind == "p":
            out.append((pi, None, 1.0))
        else:
            out.append((None, pj, 1.0))
        i, j = pi, pj
    out.reverse()
    return out


def score_parse(pred: list[dict], truth: list[dict], page_key: str) -> dict:
    """page_key: 'printed' (compare to printed arabic page) or 'physical'."""
    al = align(pred, truth)
    by_t = {ti: (pi, c) for pi, ti, c in al if ti is not None}
    extra = sum(1 for pi, ti, _ in al if ti is None)
    cers, lvl_ok, page_ok, page_n = [], 0, 0, 0
    front_found, front_n, front_page_ok = 0, 0, 0
    errors = []
    for ti, t in enumerate(truth):
        pi, c = by_t.get(ti, (None, 1.0))
        p = pred[pi] if pi is not None else None
        cers.append(c)
        if p is not None and p["level"] == t["level"]:
            lvl_ok += 1
        if t["front_matter"]:
            front_n += 1
            if p is not None:
                front_found += 1
                if page_key == "physical" and p["page"] == t["physical_page"]:
                    front_page_ok += 1
            continue
        page_n += 1
        want = t["printed_page"] if page_key == "printed" else t["physical_page"]
        if p is not None and p["page"] == want:
            page_ok += 1
        elif len(errors) < 8:
            errors.append({"truth": t["title"], "want_page": want,
                           "got": None if p is None else {"title": p["title"], "page": p["raw_page"],
                                                           "level": p["level"]}})
    n = len(truth)
    return {
        "truth_entries": n, "pred_entries": len(pred), "matched": len(by_t), "extra": extra,
        "title_cer": round(sum(cers) / n, 4) if n else None,
        # the same over the arabic (body) entries only: `toc parse` without --roman-offset
        # leaves roman front-matter entries out (as comments), which title_cer counts as misses
        "title_cer_body": (round(sum(c for c, t in zip(cers, truth) if not t["front_matter"]) / page_n, 4)
                           if page_n else None),
        "page_acc": round(page_ok / page_n, 4) if page_n else None,
        "level_acc": round(lvl_ok / n, 4) if n else None,
        "front_found": f"{front_found}/{front_n}",
        **({"front_page_ok": f"{front_page_ok}/{front_n}"} if page_key == "physical" else {}),
        "first_errors": errors,
    }


def score_outline(outline: list[dict], truth: list[dict]) -> dict:
    pred = [{"title": o.get("title", ""), "level": o.get("level", 0),
             "page": (o["page_index"] + 1) if isinstance(o.get("page_index"), int) else None,
             "raw_page": o.get("page_index")} for o in outline]
    al = align(pred, truth)
    by_t = {ti: (pi, c) for pi, ti, c in al if ti is not None}
    extra = sum(1 for _, ti, _ in al if ti is None)
    ok_body = ok_all = n_body = lvl_ok = 0
    cers = []
    errors = []
    for ti, t in enumerate(truth):
        pi, c = by_t.get(ti, (None, 1.0))
        p = pred[pi] if pi is not None else None
        cers.append(c)
        good = p is not None and c <= E2E_CER and p["page"] == t["physical_page"]
        if p is not None and p["level"] == t["level"]:
            lvl_ok += 1
        ok_all += good
        if not t["front_matter"]:
            n_body += 1
            ok_body += good
        if not good and len(errors) < 8:
            errors.append({"truth": t["title"], "want_physical": t["physical_page"],
                           "got": None if p is None else {"title": p["title"], "physical": p["page"],
                                                           "cer": round(c, 3)}})
    n = len(truth)
    return {"truth_entries": n, "outline_entries": len(pred), "extra": extra,
            "e2e_body": round(ok_body / n_body, 4) if n_body else None,
            "e2e_all": round(ok_all / n, 4) if n else None,
            "level_acc": round(lvl_ok / n, 4) if n else None,
            "title_cer": round(sum(cers) / n, 4) if n else None,
            "exact": ok_all == n and extra == 0, "first_errors": errors}


# ============================================================================
# running the CLI
# ============================================================================

MISSING = re.compile(r"unknown (command|subcommand)|unknown toc (command|subcommand)", re.I)


def run(cmd: list, out_path: Path | None = None, timeout=STAGE_TIMEOUT) -> dict:
    t0 = time.monotonic()
    try:
        p = subprocess.run([str(c) for c in cmd], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"exit": None, "error": f"timeout after {timeout}s", "seconds": timeout, "stdout": "", "stderr": ""}
    except OSError as e:
        return {"exit": None, "error": str(e), "seconds": 0, "stdout": "", "stderr": ""}
    dt = time.monotonic() - t0
    so = p.stdout.decode("utf-8", errors="replace")
    se = p.stderr.decode("utf-8", errors="replace")
    if out_path is not None:
        put(out_path, so)
    res = {"exit": p.returncode, "seconds": round(dt, 2), "stdout": so, "stderr": se}
    first = se.strip().split("\n")[0] if se.strip() else ""
    if p.returncode != 0 and MISSING.search(first):
        res["missing"] = True
    return res


def put(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def last_json(text: str):
    text = text.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    for ln in reversed(text.split("\n")):
        ln = ln.strip()
        if ln.startswith("{"):
            try:
                return json.loads(ln)
            except json.JSONDecodeError:
                continue
    m = re.search(r"\{.*\}\s*$", text, re.S)
    if m:
        try:
            return json.loads(m.group(0))
        except json.JSONDecodeError:
            return None
    return None


def stage_summary(r: dict) -> dict:
    d = {"exit": r.get("exit"), "seconds": r.get("seconds")}
    if r.get("error"):
        d["error"] = r["error"]
    if r.get("missing"):
        d["missing"] = True
    se = r.get("stderr", "").strip()
    if se:
        lines = se.split("\n")
        d["stderr_lines"] = len(lines)
        d["stderr_head"] = lines[:6]
        d["warnings"] = sum(1 for ln in lines if re.search(r"warn|低置信|low.confidence|flag", ln, re.I))
    return d


def eval_book(mulu: Path, name: str, books: Path, out: Path, args, missing: set[str], log) -> dict:
    truth = json.loads((books / f"{name}.truth.json").read_text(encoding="utf-8"))
    pdf = books / f"{name}.pdf"
    entries = truth["entries"]
    toc_arg = truth["toc_pages_arg"]
    wd = out / name
    wd.mkdir(parents=True, exist_ok=True)
    row: dict = {"book": name, "pages": truth["pages"], "entries": len(entries), "levels": truth["levels"],
                 "offset_truth": truth["offset"], "toc_pages": toc_arg, "language": truth["language"],
                 "features": truth["features"], "stages": {}, "scores": {}}
    S, R = row["stages"], row["scores"]
    t_book = time.monotonic()

    def log_stage(key, r, group=None):
        put(wd / f"{key}.stderr.txt", r.get("stderr", ""))
        S[key] = stage_summary(r)
        if r.get("missing"):
            missing.add(group or key)

    # ---- ocr-toc
    raw_path = wd / "raw.txt"
    if "ocr" not in missing:
        r = run([mulu, "ocr-toc", pdf, "--pages", toc_arg], raw_path)
        log_stage("ocr", r)
        if r["exit"] == 0:
            truth_text = (books / f"{name}.toc_lines.txt").read_text(encoding="utf-8")
            # the TOC heading ("目 录", "Contents") and the TOC pages' own folios ("iii") are not
            # entries; they are dropped on both sides so the CER measures the entry text only
            skip = {"目录", "contents"} | {norm_title(truth["folios"].get(str(p)) or "").lower()
                                          for p in truth["toc_pages"]}
            skip.discard("")

            def entry_text(t):
                return "\n".join(ln for ln in t.split("\n") if norm_title(ln).lower() not in skip)
            a, b = norm_ocr_text(entry_text(r["stdout"])), norm_ocr_text(entry_text(truth_text))
            R["ocr_cer"] = round(min(1.0, Levenshtein.distance(a, b) / max(1, len(b))), 4)
            R["ocr_lines"] = sum(1 for ln in r["stdout"].split("\n") if ln.strip())
    have_raw = S.get("ocr", {}).get("exit") == 0

    # ---- toc parse (on OCR output, and on the perfect transcription)
    for key, src in (("parse", raw_path if have_raw else None), ("parse_perfect", books / f"{name}.toc_lines.txt")):
        if src is None or "parse" in missing:
            continue
        r = run([mulu, "toc", "parse", src, "--offset", "0"], wd / f"{key}.toc.txt")
        log_stage(key, r, "parse")
        if r["exit"] is not None and r["stdout"].strip():   # scored even on a non-zero exit, which is recorded
            R[key] = score_parse(parse_mulu_toc(r["stdout"]), entries, "printed")

    # ---- detect-offset
    if "offset" not in missing:
        r = run([mulu, "detect-offset", pdf])
        log_stage("offset", r)
        put(wd / "offset.json", r.get("stdout", ""))
        js = last_json(r.get("stdout", "")) if r["exit"] is not None else None
        if isinstance(js, dict):
            R["offset"] = {"got": js.get("offset"), "want": truth["offset"],
                           "correct": js.get("offset") == truth["offset"],
                           "abstained": js.get("offset") is None,
                           "confidence": js.get("confidence"), "samples": js.get("samples"),
                           "status": js.get("status"), "best_guess": js.get("best_guess"),
                           "votes": js.get("votes"), "exit": r["exit"]}
        elif r["exit"] is not None and not r.get("missing"):
            R["offset"] = {"got": None, "want": truth["offset"], "correct": False, "abstained": True,
                           "exit": r["exit"], "error": "no JSON on stdout"}

    # ---- toc parse --offset auto (optional)
    if args.parse_auto and have_raw and "parse" not in missing:
        r = run([mulu, "toc", "parse", raw_path, "--offset", "auto", "--pdf", pdf], wd / "parse_auto.toc.txt")
        log_stage("parse_auto", r, "parse")
        if r["exit"] is not None and r["stdout"].strip():
            R["parse_auto"] = score_parse(parse_mulu_toc(r["stdout"]), entries, "physical")

    # ---- auto + dump-outline
    if "auto" not in missing:
        out_pdf = wd / "auto.pdf"
        wd.mkdir(parents=True, exist_ok=True)
        out_pdf.unlink(missing_ok=True)
        r = run([mulu, "auto", pdf, "--toc-pages", toc_arg, "-o", out_pdf])
        log_stage("auto", r)
        put(wd / "auto.stdout.txt", r.get("stdout", ""))
    if "auto" not in missing:
        a = {"exit": r["exit"], "refused": r["exit"] == 2 and not out_pdf.exists()}
        if r["exit"] == 0 and out_pdf.exists():
            A, B = pdf.read_bytes(), out_pdf.read_bytes()
            a["prefix_ok"] = B.startswith(A) and len(B) > len(A)
            d = run([mulu, "dump-outline", out_pdf], timeout=120)
            try:
                outline = json.loads(d["stdout"]) if d["exit"] == 0 else None
            except json.JSONDecodeError:
                outline = None
            if isinstance(outline, list):
                put(wd / "auto.outline.json", json.dumps(outline, ensure_ascii=False, indent=1) + "\n")
                a.update(score_outline(outline, entries))
            else:
                a["error"] = f"dump-outline failed: exit {d['exit']} {d.get('stderr', '')[:200]}"
            if not args.keep_pdfs:
                out_pdf.unlink(missing_ok=True)
        elif r["exit"] == 0:
            a["error"] = "exit 0 but no output file"
        R["auto"] = a

    row["seconds"] = round(time.monotonic() - t_book, 1)
    row["stage_seconds"] = {k: v.get("seconds") for k, v in S.items()}
    return row


# ============================================================================
# report
# ============================================================================


def pct(x):
    return "   -" if x is None else f"{100 * x:4.0f}"


def fmt_cer(x):
    return "    -" if x is None else f"{100 * x:5.1f}"


def print_table(rows: list[dict], missing: set[str] = frozenset(), out=sys.stdout):
    hdr = (f"{'book':26s} {'pg':>3s} {'ent':>3s} | {'ocrCER':>6s} | {'parse: tCER':>11s} {'page':>4s} {'lvl':>4s} "
           f"{'+/-':>5s} | {'perfect: pg':>11s} {'lvl':>4s} | {'offset':>11s} {'conf':>4s} | "
           f"{'auto':>4s} {'e2eB':>4s} {'e2eA':>4s} {'lvl':>4s} {'exact':>5s} | {'sec':>5s}")
    print(hdr, file=out)
    print("-" * len(hdr), file=out)
    for r in rows:
        R, S = r["scores"], r["stages"]
        p = R.get("parse", {})
        pp = R.get("parse_perfect", {})
        off = R.get("offset")
        a = R.get("auto", {})
        if off:
            got = "?" if off.get("got") is None else off.get("got")
            ot = f"{got}/{off.get('want')}{'' if off.get('correct') or off.get('abstained') else ' ✗'}"
            oc = off.get("confidence")
            oc = f"{float(oc):4.2f}" if isinstance(oc, (int, float)) else "   -"
        else:
            ot = "n/a" if "offset" in missing or "offset" not in S else f"exit {S['offset'].get('exit')}"
            oc = "   -"
        plus = f"+{p.get('extra', 0)}-{p.get('truth_entries', 0) - p.get('matched', 0)}" if p else "-"
        if a:
            at = "ok" if a.get("exit") == 0 else ("REF" if a.get("refused") else f"x{a.get('exit')}")
        else:
            at = "n/a" if "auto" in missing or "auto" not in S else "-"
        print(f"{r['book'][:26]:26s} {r['pages']:3d} {r['entries']:3d} | {fmt_cer(R.get('ocr_cer')):>6s} | "
              f"{fmt_cer(p.get('title_cer')):>11s} {pct(p.get('page_acc'))} {pct(p.get('level_acc'))} {plus:>5s} | "
              f"{pct(pp.get('page_acc')):>11s} {pct(pp.get('level_acc'))} | {ot:>11s} {oc} | "
              f"{at:>4s} {pct(a.get('e2e_body'))} {pct(a.get('e2e_all'))} {pct(a.get('level_acc'))} "
              f"{('yes' if a.get('exact') else 'no') if 'exact' in a else '-':>5s} | {r['seconds']:5.1f}", file=out)
    print("columns: ocrCER = OCR text CER % vs perfect transcription; parse = `toc parse` on the OCR text "
          "(title CER %, printed-page %, level %, extra/missing entries); perfect = `toc parse` on the perfect "
          "transcription; offset = detected/true; auto = exit (REF = refused with exit 2), e2eB/e2eA = % "
          "entries correct (body / all incl. roman), exact = whole outline right", file=out)


def summarize(rows: list[dict], missing: set[str], thresholds: bool) -> dict:
    def vals(f):
        return [v for v in (f(r) for r in rows) if v is not None]

    def mean(xs):
        return round(sum(xs) / len(xs), 4) if xs else None

    off = [r["scores"]["offset"] for r in rows if "offset" in r["scores"]]
    autos = [r["scores"]["auto"] for r in rows if "auto" in r["scores"]]
    refused = [r["book"] for r in rows if r["scores"].get("auto", {}).get("refused")]
    e2e_body = [(r["book"], r["scores"]["auto"].get("e2e_body")) for r in rows
                if r["scores"].get("auto", {}).get("e2e_body") is not None]
    s = {
        "books": len(rows),
        "missing_subcommands": sorted(missing),
        "ocr_cer_mean": mean(vals(lambda r: r["scores"].get("ocr_cer"))),
        "parse_title_cer_mean": mean(vals(lambda r: r["scores"].get("parse", {}).get("title_cer"))),
        "parse_title_cer_body_mean": mean(vals(lambda r: r["scores"].get("parse", {}).get("title_cer_body"))),
        "parse_page_acc_mean": mean(vals(lambda r: r["scores"].get("parse", {}).get("page_acc"))),
        "parse_level_acc_mean": mean(vals(lambda r: r["scores"].get("parse", {}).get("level_acc"))),
        "perfect_page_acc_mean": mean(vals(lambda r: r["scores"].get("parse_perfect", {}).get("page_acc"))),
        "perfect_level_acc_mean": mean(vals(lambda r: r["scores"].get("parse_perfect", {}).get("level_acc"))),
        "parse_auto_page_acc_mean": mean(vals(lambda r: r["scores"].get("parse_auto", {}).get("page_acc"))),
        "offset_correct": f"{sum(1 for o in off if o.get('correct'))}/{len(off)}" if off else None,
        "offset_abstained": [r["book"] for r in rows if r["scores"].get("offset", {}).get("abstained")],
        "offset_wrong": [r["book"] for r in rows if "offset" in r["scores"]
                         and not r["scores"]["offset"].get("correct") and not r["scores"]["offset"].get("abstained")],
        "auto_refused": refused,
        "auto_prefix_ok": all(a.get("prefix_ok", True) for a in autos) if autos else None,
        "e2e_body_mean": mean([v for _, v in e2e_body]),
        "e2e_all_mean": mean(vals(lambda r: r["scores"].get("auto", {}).get("e2e_all"))),
        # the auto outline's titles and levels (all entries, incl. roman front matter; books
        # auto refused have no outline and are not in these means)
        "auto_title_cer_mean": mean(vals(lambda r: r["scores"].get("auto", {}).get("title_cer"))),
        "auto_level_acc_mean": mean(vals(lambda r: r["scores"].get("auto", {}).get("level_acc"))),
        "exact_books": sum(1 for a in autos if a.get("exact")),
        "seconds_total": round(sum(r["seconds"] for r in rows), 1),
    }
    fails = []
    if missing:
        fails.append(f"CLI lacks: {', '.join(sorted(missing))}")
    if off:
        if s["offset_wrong"]:
            fails.append(f"detect-offset CONFIDENTLY WRONG on: {', '.join(s['offset_wrong'])} (must abstain instead)")
        not_ok = s["offset_wrong"] + s["offset_abstained"]
        if len(not_ok) > 1:
            fails.append(f"offset not found on {len(not_ok)} books (max 1): {', '.join(not_ok)}")
    elif "offset" not in missing:
        fails.append("no detect-offset results")
    if autos:
        if s["auto_prefix_ok"] is False:
            fails.append("auto output does not start with the input bytes")
        if len(refused) > 2:
            fails.append(f"auto refused {len(refused)} books (max 2): {', '.join(refused)}")
        if s["e2e_body_mean"] is not None and s["e2e_body_mean"] < 0.90:
            fails.append(f"mean e2e_body {s['e2e_body_mean']:.3f} < 0.90")
        low = [b for b, v in e2e_body if v < 0.60]
        if low:
            fails.append(f"e2e_body < 0.60 on: {', '.join(low)}")
        crashed = [r["book"] for r in rows if r["scores"].get("auto", {}).get("exit") not in (0, 2)
                   or r["scores"].get("auto", {}).get("error")]
        if crashed:
            fails.append(f"auto failed (not a clean refusal) on: {', '.join(crashed)}")
    elif "auto" not in missing:
        fails.append("no auto results")
    s["threshold_failures"] = fails
    s["verdict"] = ("PASS" if not fails else "FAIL") if thresholds else "REPORT-ONLY"
    return s


def selfcheck(books: Path, names: list[str]) -> int:
    """Proves the scorer on the ground truth itself (no mulu needed): the correct outline scores
    100%, and known perturbations score exactly what they should."""
    bad = 0
    for n in names:
        truth = json.loads((books / f"{n}.truth.json").read_text(encoding="utf-8"))
        E = truth["entries"]
        pred = parse_mulu_toc((books / f"{n}.toc.txt").read_text(encoding="utf-8"))
        s = score_parse(pred, E, "physical")
        ok = s["title_cer"] == 0 and s["page_acc"] == 1 and s["level_acc"] == 1 and s["extra"] == 0
        outline = json.loads((books / f"{n}.expected.json").read_text(encoding="utf-8"))
        o = score_outline(outline, E)
        ok &= o["exact"] and o["e2e_all"] == 1
        # perturb: drop entry 3, shift entry 5's page, add a junk entry, one typo in entry 7's title
        P = [dict(x) for x in outline]
        P[5]["page_index"] += 1
        t7 = P[7]["title"]
        P[7]["title"] = t7[:-1] + ("X" if t7[-1] != "X" else "Y")
        del P[3]
        P.insert(0, {"title": "封面扫描噪声 junk", "level": 0, "page_index": 0})
        o2 = score_outline(P, E)
        n_all = len(E)
        typo_ok = cer(P[7]["title"], E[7]["title"]) <= E2E_CER
        want_ok = n_all - 2 - (0 if typo_ok else 1)
        got_ok = round(o2["e2e_all"] * n_all)
        ok &= got_ok == want_ok and o2["extra"] == 1 and not o2["exact"]
        print(f"[selfcheck] {n:28s} {'ok' if ok else 'FAIL'}  perturbed e2e_all {got_ok}/{n_all} "
              f"(want {want_ok}), extra {o2['extra']}")
        bad += not ok
    return 1 if bad else 0


def find_mulu(arg: str | None) -> Path | None:
    if arg:
        return Path(arg)
    for cfg in ("release", "debug"):
        p = ROOT / ".build" / cfg / "mulu"
        if p.exists():
            return p
    w = shutil.which("mulu")
    return Path(w) if w else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mulu", default=None, help="mulu binary (default .build/release/mulu, then debug)")
    ap.add_argument("--books", default=str(BOOKS))
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default=str(OUT), help="per-book working files (raw OCR, parsed TOCs, logs)")
    ap.add_argument("--json", default=None, help="report path (default <books>/eval.json)")
    ap.add_argument("--parse-auto", action="store_true", help="also run `toc parse --offset auto --pdf`")
    ap.add_argument("--keep-pdfs", action="store_true", help="keep the auto.pdf outputs")
    ap.add_argument("--no-thresholds", action="store_true")
    ap.add_argument("--jobs", type=int, default=1, help="books in parallel (max 2; OCR is CPU/ANE heavy)")
    ap.add_argument("--selfcheck", action="store_true", help="prove the scorer on the ground truth and exit")
    args = ap.parse_args()
    if args.selfcheck:
        b = Path(args.books)
        names = [x["book"] for x in json.loads((b / "manifest.json").read_text(encoding="utf-8"))["books"]]
        return selfcheck(b, names)

    mulu = find_mulu(args.mulu)
    if mulu is None or not mulu.exists():
        print("eval_books: no mulu binary (swift build -c release first, or --mulu)", file=sys.stderr)
        return 2
    books = Path(args.books)
    man = books / "manifest.json"
    if not man.exists():
        print(f"eval_books: {man} missing -- run tools/fixtures/make_books.py", file=sys.stderr)
        return 2
    names = [b["book"] for b in json.loads(man.read_text(encoding="utf-8"))["books"]]
    only = {x for x in args.only.split(",") if x}
    if only - set(names):
        print(f"eval_books: unknown book(s) {sorted(only - set(names))}", file=sys.stderr)
        return 2
    names = [n for n in names if not only or n in only]
    names = [n for n in names if (books / f"{n}.pdf").exists() and (books / f"{n}.truth.json").exists()]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    missing: set[str] = set()
    rows: list[dict] = []
    t0 = time.monotonic()
    print(f"[eval] {len(names)} book(s), mulu = {mulu}", flush=True)
    jobs = max(1, min(args.jobs, 2))
    if jobs == 1:
        for n in names:
            row = eval_book(mulu, n, books, out, args, missing, print)
            rows.append(row)
            a = row["scores"].get("auto", {})
            print(f"[eval] {n:28s} {row['seconds']:6.1f}s  auto exit {a.get('exit', '-')}  "
                  f"e2e_body {a.get('e2e_body', '-')}", flush=True)
    else:
        import concurrent.futures as cf
        with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
            futs = {ex.submit(eval_book, mulu, n, books, out, args, missing, print): n for n in names}
            for f in cf.as_completed(futs):
                rows.append(f.result())
                print(f"[eval] {futs[f]:28s} done", flush=True)
        rows.sort(key=lambda r: names.index(r["book"]))

    print()
    print_table(rows, missing)
    summary = summarize(rows, missing, not args.no_thresholds)
    print()
    for k in ("ocr_cer_mean", "parse_title_cer_mean", "parse_title_cer_body_mean", "parse_page_acc_mean", "parse_level_acc_mean",
              "perfect_page_acc_mean", "perfect_level_acc_mean", "parse_auto_page_acc_mean", "offset_correct",
              "offset_abstained",
              "offset_wrong", "auto_refused",
              "e2e_body_mean", "e2e_all_mean", "auto_title_cer_mean", "auto_level_acc_mean", "exact_books", "seconds_total"):
        print(f"  {k:26s} {summary.get(k)}")
    if summary["missing_subcommands"]:
        print(f"  missing subcommands      {', '.join(summary['missing_subcommands'])} (those stages were skipped)")
    for f in summary["threshold_failures"]:
        print(f"  THRESHOLD: {f}")
    print(f"[eval] verdict {summary['verdict']} in {time.monotonic() - t0:.0f}s")

    report = {"generator": "tools/eval/eval_books.py", "mulu": str(mulu),
              "date": time.strftime("%Y-%m-%d %H:%M:%S"), "summary": summary, "books": rows}
    jpath = Path(args.json) if args.json else books / "eval.json"
    if only and jpath.exists() and not args.json:
        # a partial run updates its rows in the full report instead of dropping the others
        try:
            old = json.loads(jpath.read_text(encoding="utf-8"))
            keep = {r["book"]: r for r in old.get("books", [])}
            for r in rows:
                keep[r["book"]] = r
            all_names = [b["book"] for b in json.loads(man.read_text(encoding="utf-8"))["books"]]
            merged = [keep[n] for n in all_names if n in keep]
            report["books"] = merged
            report["summary"] = summarize(merged, missing, not args.no_thresholds)
            report["summary"]["note"] = f"partial run ({', '.join(sorted(only))}) merged into the previous report"
        except (ValueError, KeyError):
            pass
    jpath.write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"[eval] wrote {jpath}")
    if missing:
        return 3
    return 0 if summary["verdict"] in ("PASS", "REPORT-ONLY") else 1


if __name__ == "__main__":
    sys.exit(main())
