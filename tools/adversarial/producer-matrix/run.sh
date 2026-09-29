#!/usr/bin/env bash
# run.sh -- producer-matrix + reader-matrix adversarial run for mulu (reproduces every table).
#   1. build the Swift producers (Quartz / PDFKit / WebKit / NSPrintOperation) and npm deps if missing
#   2. make_matrix.py  -> gen/      (~50 producers/variants, 3-level CJK+English TOC each)
#      make_big.py     -> gen_big/  (500..3000-page files from 12 producers, perf limit 1000 ms)
#   3. tools/verify/verify.py run-all on gen/ and gen_big/ (5 readers + self + spec/check/pages/struct/info)
#   4. check_system.py   Quick Look thumbnail, Spotlight page count, MuPDF, pdfminer, writer round trips
#   5. legacy/legacy_matrix.py  pdf.js 2.16/3.11/4.10 + PyPDF2 1.26/2.12/3.0.1
#   6. catalog_compare.py  catalog/trailer deep-equality + PDFium render identity
#   7. chains/chains.py  mulu x5; mulu -> pypdf/MuPDF/PDFKit update -> mulu
# Preview.app is not opened (it would put windows in front of the user).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
UV="${UV:-$HOME/.local/bin/uv}"
if [[ ! -x "$UV" ]]; then UV="$(command -v uv || true)"; fi
if [[ -z "$UV" ]]; then echo "uv not found (install: https://docs.astral.sh/uv/)" >&2; exit 1; fi
export UV
MULU="${MULU:-$ROOT/.build/release/mulu}"
export PM_SCRATCH="${PM_SCRATCH:-$HERE/.scratch}"
PY=("$UV" run --quiet --python 3.12)
rc=0
[[ -x "$HERE/.bin/producers" ]] || { mkdir -p "$HERE/.bin"; swiftc -O -swift-version 5 "$HERE/swift/producers.swift" -o "$HERE/.bin/producers" || exit 1; }
[[ -d "$HERE/node/node_modules" ]] || (cd "$HERE/node" && npm install --no-audit --no-fund --silent) || exit 1
[[ -d "$HERE/legacy/node_modules" ]] || (cd "$HERE/legacy" && npm install --no-audit --no-fund --silent) || exit 1
[[ -f "$HERE/gen/manifest.json" && "${REGEN:-0}" == 0 ]] || "${PY[@]}" "$HERE/make_matrix.py" || exit 1
[[ -f "$HERE/gen_big/manifest.json" && "${REGEN:-0}" == 0 ]] || "${PY[@]}" "$HERE/make_big.py" || exit 1
"${PY[@]}" "$ROOT/tools/verify/verify.py" run-all --mulu "$MULU" --gen "$HERE/gen" --out "$HERE/out" --json "$HERE/out/report.json" | grep -v "readers/checks" || rc=1
"${PY[@]}" "$ROOT/tools/verify/verify.py" run-all --mulu "$MULU" --gen "$HERE/gen_big" --out "$HERE/out_big" --json "$HERE/out_big/report.json" | grep -v "readers/checks" || rc=1
"${PY[@]}" "$HERE/check_system.py" --mulu "$MULU" 2>/dev/null || rc=1
"$UV" run --quiet --no-project --python 3.12 python "$HERE/legacy/legacy_matrix.py" || rc=1
"${PY[@]}" "$HERE/catalog_compare.py" || rc=1
"${PY[@]}" "$HERE/chains/chains.py" 2>/dev/null | grep -v "^Ignoring\|^parsing" || rc=1
exit $rc
