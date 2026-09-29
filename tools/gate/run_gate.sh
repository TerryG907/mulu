#!/usr/bin/env bash
# run_gate.sh -- the real-scan gate: run mulu on every PDF in a folder of YOUR books and check the
# result with five independent readers. Your books are only read: never copied, modified or
# uploaded; outputs go to a private temp dir that is deleted afterwards. Only a report is written
# (tools/gate/reports/gate-<time>.md and .json). See tools/gate/README.md.
#
# usage: tools/gate/run_gate.sh <folder> [--toc-csv FILE] [--recursive] [--report FILE] [--keep-temp]
#        tools/gate/run_gate.sh <folder> --make-csv [FILE]     # write a CSV template to fill in
#
#   --toc-csv FILE   CSV "file,toc_pages" (e.g. "某书.pdf,5-7"): for the books listed, also run
#                    mulu detect-offset + mulu auto and put the proposed outline in the report.
#                    Default: tools/gate/toc_pages.csv when it exists.
#   --recursive      also look in sub-folders
#   --keep-temp      keep the temp outputs (for debugging; they contain full copies of the books)
# Exit 0 = PASS (at most 2 writer failures), 1 = FAIL, 2 = usage / build error.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/tools/gate"
UV="${UV:-$HOME/.local/bin/uv}"
if [[ ! -x "$UV" ]]; then UV="$(command -v uv || true)"; fi
if [[ -z "$UV" ]]; then echo "run_gate: uv not found (install: https://docs.astral.sh/uv/)" >&2; exit 2; fi

FOLDER=""
ARGS=()
CSV=""
MAKE_CSV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toc-csv) CSV="$2"; shift ;;
    --make-csv)
      if [[ $# -gt 1 && "$2" != --* ]]; then MAKE_CSV="$2"; shift; else MAKE_CSV="$GATE/toc_pages.csv"; fi ;;
    --recursive|--keep-temp) ARGS+=("$1") ;;
    --report) ARGS+=(--report "$2"); shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "run_gate: unknown option $1" >&2; exit 2 ;;
    *) if [[ -z "$FOLDER" ]]; then FOLDER="$1"; else echo "run_gate: one folder only" >&2; exit 2; fi ;;
  esac
  shift
done
if [[ -z "$FOLDER" ]]; then sed -n '2,15p' "$0"; exit 2; fi
if [[ ! -d "$FOLDER" ]]; then echo "run_gate: $FOLDER is not a folder" >&2; exit 2; fi

PY=(nice -n 10 "$UV" run --quiet --python 3.12 "$GATE/gate.py")

if [[ -n "$MAKE_CSV" ]]; then
  exec "${PY[@]}" "$FOLDER" --make-csv "$MAKE_CSV" ${ARGS[@]+"${ARGS[@]}"}
fi

if [[ -z "$CSV" && -f "$GATE/toc_pages.csv" ]]; then CSV="$GATE/toc_pages.csv"; fi
if [[ -n "$CSV" ]]; then
  if [[ ! -f "$CSV" ]]; then echo "run_gate: CSV $CSV not found" >&2; exit 2; fi
  ARGS+=(--toc-csv "$CSV")
  echo "run_gate: TOC pages from $CSV"
fi

echo "run_gate: building mulu (swift build -c release) ..."
LOG="$(mktemp -t mulu-gate-build)"
if nice -n 10 swift build -c release --package-path "$ROOT" >"$LOG" 2>&1; then
  MULU="$(swift build -c release --package-path "$ROOT" --show-bin-path)/mulu"
else
  tail -n 30 "$LOG" >&2
  rm -f "$LOG"
  echo "run_gate: BUILD FAILED" >&2
  exit 2
fi
rm -f "$LOG"
echo "run_gate: mulu = $MULU"

"${PY[@]}" "$FOLDER" --mulu "$MULU" ${ARGS[@]+"${ARGS[@]}"}
