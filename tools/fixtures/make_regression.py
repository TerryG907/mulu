# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""
make_regression.py -- (re)build Fixtures/regression/ from the adversarial reviews' reproducers.

    uv run --python 3.12 tools/fixtures/make_regression.py

Every fixture here reproduces one adversarial finding (see "finding" in manifest.json).
The directory is meant to be kept (committed): tools/run_all.sh verifies it on every run
and never regenerates it. This script only needs tools/adversarial/ when rebuilding.

Sidecars per fixture (same contract as Fixtures/generated): <name>.pdf, <name>.toc.txt,
<name>.expected.json, optional <name>.expect ("refuse"), <name>.reapply.toc.txt and
<name>.reapply.expected.json. manifest.json adds per-fixture "options" read by
tools/verify/verify.py:
  expect_stderr     regex the one-line refusal message must match
  expect_info       "error": `mulu info` must refuse as well
  complete_xref     the input is reconstructed: update = complete xref without /Prev
  republish         the update may republish (exactly-landing) rows of repaired objects
  input_unreadable  {reader: why}: that reader cannot read the INPUT (verified at run time)
  allow_na          columns that may be n/a because qpdf cannot open the input (verified)
  max_rss_mb        peak RSS limit for `mulu apply`
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADV = ROOT / "tools" / "adversarial"
OUT = ROOT / "Fixtures" / "regression"

SR, SR2, SR3 = ADV / "spec-review" / "gen", ADV / "spec-review" / "gen2", ADV / "spec-review" / "gen3"
H, H2, H3 = ADV / "hostile-inputs" / "gen", ADV / "hostile-inputs" / "gen2", ADV / "hostile-inputs" / "gen3"

REFUSE_INFO = {"expect_info": "error"}

# (name, source dir, finding id + summary, manifest options, tweak)
CASES = [
    # --- spec-review major: 1-2 bytes before %PDF- -> offsets must stay header-relative
    ("sr3_text_objstm_lfprefix", SR3, "SR-1 junk prefix frame (xref stream, LF before %PDF-)", {}, ""),
    ("sr3_quartz_made_lfprefix", SR3, "SR-1 junk prefix frame (Quartz classic, LF before %PDF-)", {}, ""),
    ("sr_junk1_rel_stream", SR, "SR-1 junk prefix frame (PDFKit could not open the old output)", {}, ""),
    ("sr_junk1_rel_classic", SR, "SR-1 junk prefix frame (classic)", {}, ""),
    ("sr_junk2_rel_crlf", SR, "SR-1 junk prefix frame (CRLF file, CRLF prefix)", {}, ""),
    ("sr_junk8_rel_classic", SR, "SR-1 control: 8 junk bytes, header-relative (kept passing)", {}, ""),
    # --- spec-review major: pypdf lost the outline with a 2-byte prefix
    ("sr3_text_objstm_crlfprefix", SR3, "SR-2 pypdf lost the outline (CRLF prefix, xref stream)", {}, ""),
    # --- spec-review minor: reconstruction path must write header-relative offsets
    ("sr2_recon_junk8", SR2, "SR-3 reconstruct + junk prefix: complete table in the header frame",
     {"complete_xref": True}, ""),
    # --- spec-review minor: trailer keys (§7.5.6)
    ("sr_trailer_private_keys", SR, "SR-4 added trailer keeps every previous entry (classic)", {}, ""),
    ("sr_trailer_private_keys_stream", SR, "SR-4 added trailer keeps every previous entry (xref stream)", {}, ""),
    # --- spec-review minor: new numbers must not capture dangling references
    ("sr_dangling_ref", SR, "SR-5 /Annots [10 0 R 11 0 R] undefined: new objects numbered above them", {}, ""),
    ("sr_dangling_resources", SR, "SR-5 /Resources 10 0 R undefined: new objects numbered above it", {}, ""),
    # --- hostile major
    ("h_int64max_offset_junkprefix", H, "HI-1 Int overflow trap (junk prefix + Int64.max offset)", {}, ""),
    ("h_deep_decodeparms_chain", H, "HI-2 stack overflow via 20,000 nested /DecodeParms",
     {"expect_stderr": r"nest more than \d+ levels", **REFUSE_INFO}, ""),
    ("h_pagetree_cycle", H, "HI-3 page-tree cycle must be refused",
     {"expect_stderr": "cycle", **REFUSE_INFO}, ""),
    ("h_pagetree_selfkid", H, "HI-3 root /Pages lists itself",
     {"expect_stderr": "cycle", **REFUSE_INFO}, ""),
    ("h_junk_prefix_rel1", H, "HI-4 1 junk byte, header-relative (with re-apply)", {}, ""),
    ("h_junk_prefix_rel2_blanklines", H, "HI-4 CRLF prefix, header-relative", {}, ""),
    ("h3_i64max_prev_junk", H3, "HI-4 junk prefix on the reconstruction path",
     {"complete_xref": True}, ""),
    # --- hostile minor
    ("h2_count_mismatch", H2, "HI-5 /Count 3 with 5 kids: readers disagree -> refuse",
     {"expect_stderr": "/Count", **REFUSE_INFO}, ""),
    ("h_pagetree_missingkid", H, "HI-6 dangling /Kids entry -> refuse",
     {"expect_stderr": "missing", **REFUSE_INFO}, ""),
    ("h_pagetree_dupleaf", H, "HI-6 (same class) a page listed twice -> refuse",
     {"expect_stderr": "appears twice", **REFUSE_INFO}, ""),
    ("h_offset0_shadow", H, "HI-7 page resolves through an offset-0 entry -> refuse",
     {"expect_stderr": "missing", **REFUSE_INFO}, ""),
    ("h2_page_offset_beyond_eof", H2, "HI-8 repaired page offset is republished", {"republish": True}, ""),
    ("h_xref_first_subsection_1", H, "HI-8 renumbered '1 N' table is republished",
     {"republish": True, "allow_na": ["spec", "struct"]}, ""),
    ("h2_page_nest300", H2, "HI-9 page dicts nested 300 deep are only referenced: apply", {}, ""),
    ("h2_catalog_nest100k", H2, "HI-9 catalog nested 100k deep: refuse, naming the nesting limit",
     {"expect_stderr": "nests arrays or dictionaries more than"}, ""),
    ("h2_classic_objnum_9e9", H2, "HI-10 stray free entry 9e9 does not block apply", {}, ""),
    ("h2_xrefstm_objnum_5e12", H2, "HI-10 stray entry 5e12 in an xref stream", {}, ""),
    ("h2_direct_page_kid_ok", H2, "HI-11 direct page kid anywhere -> refuse",
     {"expect_stderr": "not an indirect reference", **REFUSE_INFO}, ""),
    ("h2_direct_page_kid_target", H2, "HI-11 direct page kid targeted -> refuse",
     {"expect_stderr": "not an indirect reference", **REFUSE_INFO}, ""),
    ("h_hybrid_free", H, "HI-12 hybrid table-free vs /XRefStm conflict: message names it",
     {"expect_stderr": "hybrid xref", **REFUSE_INFO}, ""),
    ("h_objstm_lzw", H, "HI-12 LZWDecode object stream is decoded", {}, ""),
    ("h2_objstm_256mb_padding", H2, "HI-13 decompression bomb: capped, bounded memory",
     {"expect_stderr": "MiB", "max_rss_mb": 200, **REFUSE_INFO}, ""),
    ("h2_objstm_first_negative", H2, "HI-14 info must fail where apply refuses", REFUSE_INFO, ""),
    ("h2_root_direct_dict", H2, "HI-14 info must fail where apply refuses", REFUSE_INFO, ""),
    ("h_mixed_stream_then_classic", H, "HI-15 classic update over an xref-stream revision",
     {"input_unreadable": {"pdfkit": "PDFKit cannot open the input (classic section over an xref stream)"}}, ""),
    ("h_toc_weird_codepoints", H, "HI-16 harness: U+2028 in a title (split on \\n only)", {}, "nul"),
    ("h_catalog_dupkeys_emptyname", H, "HI-16 harness: shifted qpdf offsets, int catalog values",
     {"input_unreadable": {"pdfkit": "CoreGraphics rejects the input's /Z#00 name"}}, ""),
    ("h2_xrefstm_length_huge", H2, "HI-16 harness: shifted qpdf offsets", {}, ""),
    ("h_catalog_exotic", H, "HI-16 harness: Decimal/int catalog values", {}, ""),
]


def copy_case(name: str, src: Path, finding: str, options: dict, tweak: str, manifest: dict) -> None:
    sm = json.loads((src / "manifest.json").read_text(encoding="utf-8"))["fixtures"][name]
    for suffix in (".pdf", ".toc.txt", ".expected.json", ".offset", ".reapply.toc.txt",
                   ".reapply.expected.json", ".preexisting.json"):
        f = src / f"{name}{suffix}"
        if f.exists():
            shutil.copyfile(f, OUT / f"{name}{suffix}")
    refuse = "expect_stderr" in options or options.get("expect_info") == "error"
    (OUT / f"{name}.expect").unlink(missing_ok=True)
    if refuse:
        (OUT / f"{name}.expect").write_text("refuse\n")
    facts = {k: v for k, v in sm.get("facts", {}).items() if k != "qpdf_warnings"}
    if tweak == "nul":
        # PDFium drops U+0000 from titles (a PDFium limitation, not mulu's); the point of
        # this fixture is U+2028 and friends, so the NUL line is made printable.
        toc = (OUT / f"{name}.toc.txt").read_text(encoding="utf-8").replace("NUL\x00inside", "NUL-inside")
        (OUT / f"{name}.toc.txt").write_text(toc, encoding="utf-8")
        exp = json.loads((OUT / f"{name}.expected.json").read_text(encoding="utf-8"))
        for it in exp:
            it["title"] = it["title"].replace("NUL\x00inside", "NUL-inside")
        (OUT / f"{name}.expected.json").write_text(json.dumps(exp, ensure_ascii=False, indent=1), encoding="utf-8")
    if options.get("complete_xref"):
        facts.pop("revisions", None)  # a reconstructed file's revision count is a guess
    manifest[name] = {"name": name, "status": "ok", "expect": "refuse" if refuse else "apply",
                      "reapply": bool(sm.get("reapply")) and not refuse and (OUT / f"{name}.reapply.toc.txt").exists(),
                      "perf_limit_ms": None, "finding": finding, "source": str(src.relative_to(ROOT)),
                      "notes": sm.get("notes", "") or sm.get("desc", ""), "facts": facts, "options": options}


def synthetic(manifest: dict) -> None:
    """TOC-parser findings, on a small clean PDF (a copy of Fixtures/generated/cups_made.pdf)."""
    base = ROOT / "Fixtures" / "generated" / "cups_made.pdf"
    bm = json.loads((ROOT / "Fixtures" / "generated" / "manifest.json").read_text(encoding="utf-8"))
    facts = bm["fixtures"]["cups_made"]["facts"]
    name = "toc_fullwidth_indent"
    shutil.copyfile(base, OUT / f"{name}.pdf")
    (OUT / f"{name}.toc.txt").write_text(
        "第一章 总论 1\n　第一节 范围 2\n　　一、定义 3\n　第二节 术语 4\n"
        "第二章 方法\t5\n\t2.1 混合缩进（Tab） 6\n　　 2.1.1 全角加空格 7\n", encoding="utf-8")
    exp = [{"title": "第一章 总论", "level": 0, "page_index": 0},
           {"title": "第一节 范围", "level": 1, "page_index": 1},
           {"title": "一、定义", "level": 2, "page_index": 2},
           {"title": "第二节 术语", "level": 1, "page_index": 3},
           {"title": "第二章 方法", "level": 0, "page_index": 4},
           {"title": "2.1 混合缩进（Tab）", "level": 1, "page_index": 5},
           {"title": "2.1.1 全角加空格", "level": 2, "page_index": 6}]
    (OUT / f"{name}.expected.json").write_text(json.dumps(exp, ensure_ascii=False, indent=1), encoding="utf-8")
    manifest[name] = {"name": name, "status": "ok", "expect": "apply", "reapply": False, "perf_limit_ms": None,
                      "finding": "PM-1 full-width space (U+3000) indentation counts as one level",
                      "source": "synthetic", "notes": "Word/WPS-style Chinese TOC indented with U+3000",
                      "facts": {k: v for k, v in facts.items()}, "options": {}}
    name = "toc_nbsp_indent"
    shutil.copyfile(base, OUT / f"{name}.pdf")
    (OUT / f"{name}.toc.txt").write_text("Chapter 1 1\n 1.1 NBSP-indented 2\n", encoding="utf-8")
    (OUT / f"{name}.expected.json").write_text("[]", encoding="utf-8")
    (OUT / f"{name}.expect").write_text("refuse\n")
    manifest[name] = {"name": name, "status": "ok", "expect": "refuse", "reapply": False, "perf_limit_ms": None,
                      "finding": "PM-1 other leading Unicode whitespace is refused, not silently flattened",
                      "source": "synthetic", "notes": "", "facts": {k: v for k, v in facts.items()},
                      "options": {"expect_stderr": r"line 2: indentation uses U\+00A0"}}


def main() -> int:
    # The generated reproducers under tools/adversarial/*/gen* are not in git (only their
    # generator scripts are); without them, keep the committed Fixtures/regression as is.
    missing = sorted({str(src.relative_to(ROOT)) for _, src, *_ in CASES if not (src / "manifest.json").exists()})
    if missing:
        print("make_regression: generated reproducers are missing (" + ", ".join(missing)
              + "); run the tools/adversarial generators first. Fixtures/regression is kept as is", file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    manifest: dict = {}
    for name, src, finding, options, tweak in CASES:
        copy_case(name, src, finding, options, tweak, manifest)
    synthetic(manifest)
    (OUT / "manifest.json").write_text(json.dumps({"fixtures": manifest}, ensure_ascii=False, indent=1),
                                       encoding="utf-8")
    total = sum(f.stat().st_size for f in OUT.iterdir())
    print(f"make_regression: {len(manifest)} fixtures, {total / 1e6:.1f} MB in {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
