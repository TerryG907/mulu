#!/usr/bin/env bash
# run.sh -- week-1 NO-REGRESSION + SAFETY audit of the OCR engines (ocr-toc / detect-offset / auto).
# Everything is written under this directory; the rest of the repo is only read (except that
# tools/run_all.sh itself rebuilds Fixtures/out, as it always does).
#   1. swift test, tools/run_all.sh (78 rows), gate self-test
#   2. producer matrix re-run into pm_out/ pm_out_big/ (+ catalog compare, chains)
#   3. test material: gen_vector.py (2000-page, 20000 pt, odd boxes), gen_scanned.py via
#      gen_all.sh (117-page scanned book + no-folio / sawtooth / plates variants), gen_zerobox.py
#   4. run_safety.py: every case checks input sha/inode/mtime, stray files, no output on
#      refusal, peak RSS and wall time (nice -n 15, one mulu at a time) -> results.json
#   5. tools/eval/eval_books.py into eval_out/ + eval_books.json
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
UV="${UV:-$HOME/.local/bin/uv}"
if [[ ! -x "$UV" ]]; then UV="$(command -v uv || true)"; fi
if [[ -z "$UV" ]]; then echo "uv not found (install: https://docs.astral.sh/uv/)" >&2; exit 1; fi
export UV
PY=(nice -n 15 "$UV" run --quiet --python 3.12)
cd "$ROOT"
nice -n 15 swift test > "$HERE/swift_test.log" 2>&1; echo "swift test rc=$?"
nice -n 15 tools/run_all.sh --jobs 2 > "$HERE/run_all.log" 2>&1; echo "run_all rc=$?"
nice -n 15 tools/gate/selftest.sh > "$HERE/gate_selftest.log" 2>&1; echo "gate selftest rc=$?"
PM="$ROOT/tools/adversarial/producer-matrix"
"${PY[@]}" tools/verify/verify.py run-all --mulu .build/release/mulu --gen "$PM/gen" --out "$HERE/pm_out" --json "$HERE/pm_out/report.json" --jobs 2 > "$HERE/producer_matrix.log" 2>&1
"${PY[@]}" tools/verify/verify.py run-all --mulu .build/release/mulu --gen "$PM/gen_big" --out "$HERE/pm_out_big" --json "$HERE/pm_out_big/report.json" --jobs 2 >> "$HERE/producer_matrix.log" 2>&1
"${PY[@]}" "$HERE/pm_catalog_compare.py" > "$HERE/pm_extra.log" 2>&1
"${PY[@]}" "$HERE/pm_chains.py" >> "$HERE/pm_extra.log" 2>/dev/null
grep -E "rows passed|pairs compared|chains ok" "$HERE/producer_matrix.log" "$HERE/pm_extra.log"
"${PY[@]}" python "$HERE/gen_vector.py"
"$HERE/gen_all.sh"
"${PY[@]}" "$HERE/gen_zerobox.py"
"${PY[@]}" "$HERE/run_safety.py"
"${PY[@]}" tools/eval/eval_books.py --mulu .build/release/mulu --parse-auto --out "$HERE/eval_out" --json "$HERE/eval_books.json" --jobs 2 > "$HERE/eval_books.log" 2>&1
echo "eval_books rc=$?"
