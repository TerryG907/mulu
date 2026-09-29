#!/usr/bin/env bash
# run_all.sh -- one command for the mulu gate-week spike:
#   1. swift build -c release (falls back to debug)
#   2. generate fixtures if missing (--regen forces a rebuild)
#   3. mulu apply on every fixture -> Fixtures/out/, re-apply test, in==out refusal test
#   4. five independent readers + mulu dump-outline + strict byte-level checks, then a table
#   5. the same verification on Fixtures/regression/ (one reproducer per adversarial finding;
#      kept in the repo, never regenerated here -- see tools/fixtures/make_regression.py)
#   6. (--books only) the scanned-book pipeline: synthetic books with ground truth
#      (tools/fixtures/make_books.py, built once into Fixtures/books) scored by tools/eval/eval_books.py
#      (OCR CER, printed-TOC parse, detect-offset, mulu auto end to end), then tools/eval/week1_regress.py
#      (one check per week-1 adversarial finding: messy printed TOCs, offset changes, resource guards).
#      Slow: minutes, OCR-heavy.
# Exit 0 only if every row of both tables passes (and, with --books, the book eval meets its thresholds).
#
# usage: tools/run_all.sh [--regen] [--only a,b] [--selftest] [--jobs N] [--books]
#   --regen     rebuild Fixtures/generated first (Fixtures/regression is never rebuilt);
#               with --books also rebuild Fixtures/books
#   --only      restrict to some fixtures (comma separated)
#   --selftest  also run the harness self-test (reference writer + negative controls) first
#   --jobs N    parallel reader processes (default: one per CPU core, at most 16; 2 keeps the Mac responsive)
#   --books     also run the scanned-book eval (off by default so the default run stays fast)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UV="${UV:-$HOME/.local/bin/uv}"
if [[ ! -x "$UV" ]]; then UV="$(command -v uv || true)"; fi
if [[ -z "$UV" ]]; then echo "run_all: uv not found (install: https://docs.astral.sh/uv/)" >&2; exit 1; fi
export UV  # the book and week-1 scripts start uv themselves
PY=("$UV" run --quiet --python 3.12)

REGEN=0
SELFTEST=0
BOOKS=0
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --regen) REGEN=1 ;;
    --selftest) SELFTEST=1 ;;
    --books) BOOKS=1 ;;
    --only) PASS_ARGS+=(--only "$2"); shift ;;
    --jobs) PASS_ARGS+=(--jobs "$2"); shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "run_all: unknown argument $1" >&2; exit 64 ;;
  esac
  shift
done

bold() { if [[ -t 1 ]]; then printf '\033[1m%s\033[0m\n' "$*"; else printf '%s\n' "$*"; fi; }

# ---------------------------------------------------------------- 1. build
bold "== 1/4 build (swift build -c release)"
MULU=""
BUILD_LOG="$(mktemp -t mulu-build)"
if swift build -c release --package-path "$ROOT" >"$BUILD_LOG" 2>&1; then
  MULU="$(swift build -c release --package-path "$ROOT" --show-bin-path)/mulu"
else
  echo "release build failed; trying debug" >&2
  tail -n 25 "$BUILD_LOG" >&2
  if swift build --package-path "$ROOT" >"$BUILD_LOG" 2>&1; then
    MULU="$(swift build --package-path "$ROOT" --show-bin-path)/mulu"
  else
    tail -n 40 "$BUILD_LOG" >&2
    echo "run_all: BUILD FAILED" >&2
    rm -f "$BUILD_LOG"
    exit 1
  fi
fi
rm -f "$BUILD_LOG"
if [[ ! -x "$MULU" ]]; then echo "run_all: built, but no executable at $MULU" >&2; exit 1; fi
echo "mulu: $MULU"

# ---------------------------------------------------------------- 2. fixtures
bold "== 2/4 fixtures"
GEN="$ROOT/Fixtures/generated"
if [[ $REGEN -eq 1 || ! -f "$GEN/manifest.json" || ! -f "$GEN/text_classic_cjk.pdf" ]]; then
  "${PY[@]}" "$ROOT/tools/fixtures/make_fixtures.py" || { echo "run_all: fixture generation failed" >&2; exit 1; }
else
  echo "using existing fixtures in Fixtures/generated (pass --regen to rebuild)"
fi

if [[ $SELFTEST -eq 1 ]]; then
  bold "== harness self-test"
  "${PY[@]}" "$ROOT/tools/verify/verify.py" selftest ${PASS_ARGS[@]+"${PASS_ARGS[@]}"} || {
    echo "run_all: HARNESS SELF-TEST FAILED - results below cannot be trusted" >&2; exit 1; }
fi

# ---------------------------------------------------------------- 3. apply + verify
bold "== 3/4 apply + verify (Fixtures/generated)"
rm -rf "$ROOT/Fixtures/out"
mkdir -p "$ROOT/Fixtures/out"
"${PY[@]}" "$ROOT/tools/verify/verify.py" run-all --mulu "$MULU" \
  --json "$ROOT/Fixtures/out/report.json" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
rc=$?

# ---------------------------------------------------------------- 4. regressions
bold "== 4/4 regressions (Fixtures/regression: one reproducer per adversarial finding)"
REG="$ROOT/Fixtures/regression"
rrc=0
if [[ -f "$REG/manifest.json" ]]; then
  mkdir -p "$ROOT/Fixtures/out/regression"
  "${PY[@]}" "$ROOT/tools/verify/verify.py" run-all --mulu "$MULU" --gen "$REG" \
    --out "$ROOT/Fixtures/out/regression" --json "$ROOT/Fixtures/out/regression/report.json" \
    ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
  rrc=$?
else
  echo "run_all: Fixtures/regression/manifest.json is missing" >&2
  rrc=1
fi

# ---------------------------------------------------------------- 5. scanned books (--books)
brc=0
if [[ $BOOKS -eq 1 ]]; then
  bold "== books (--books): OCR -> printed TOC -> offset -> outline, scored against ground truth"
  BOOKDIR="$ROOT/Fixtures/books"
  if [[ $REGEN -eq 1 || ! -f "$BOOKDIR/manifest.json" ]]; then
    nice -n 15 "${PY[@]}" "$ROOT/tools/fixtures/make_books.py" --jobs 2 || {
      echo "run_all: book generation failed" >&2; brc=1; }
  else
    echo "using existing books in Fixtures/books (pass --regen to rebuild)"
  fi
  if [[ $brc -eq 0 ]]; then
    "${PY[@]}" "$ROOT/tools/eval/eval_books.py" --selfcheck >/dev/null || {
      echo "run_all: eval scorer self-check FAILED" >&2; brc=1; }
  fi
  if [[ $brc -eq 0 ]]; then
    nice -n 15 "${PY[@]}" "$ROOT/tools/eval/eval_books.py" --mulu "$MULU" --parse-auto
    brc=$?
  fi
  bold "== week-1 regressions (--books): one check per adversarial finding (tools/eval/week1_regress.py)"
  nice -n 15 "${PY[@]}" "$ROOT/tools/eval/week1_regress.py" --mulu "$MULU" || brc=1
fi

if [[ $rc -eq 0 && $rrc -eq 0 && $brc -eq 0 ]]; then
  if [[ $BOOKS -eq 1 ]]; then bold "ALL PASS (fixtures + regressions + books)"; else bold "ALL PASS (fixtures + regressions)"; fi
  exit 0
fi
bold "FAILURES (fixtures exit $rc, regressions exit $rrc, books exit $brc) - see details above and Fixtures/out/**/report.json, Fixtures/books/eval.json"
exit 1
