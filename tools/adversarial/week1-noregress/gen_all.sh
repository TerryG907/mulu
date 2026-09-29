#!/usr/bin/env bash
# builds the scanned test books (at most 2 builders at once, nice 15); nofolio built first
# (its seed/name is shared by every variant, see gen_scanned.py build_as)
# Exit 0 only if every builder succeeded; the logs are gen_<variant>.log next to this script.
set -u
cd "$(dirname "$0")"
UV="${UV:-$HOME/.local/bin/uv}"
if [[ ! -x "$UV" ]]; then UV="$(command -v uv || true)"; fi
if [[ -z "$UV" ]]; then echo "gen_all: uv not found (install: https://docs.astral.sh/uv/)" >&2; exit 1; fi
UVR=(nice -n 15 "$UV" run --quiet --python 3.12)
rc=0
if [[ ! -f books/w1_nofolio.pdf ]]; then
  "${UVR[@]}" gen_scanned.py nofolio > gen_nofolio.log 2>&1 || { echo "gen_all: nofolio failed" >&2; rc=1; }
fi
"${UVR[@]}" gen_scanned.py book120 > gen_book120.log 2>&1 &
bg=$!
"${UVR[@]}" gen_scanned.py sawtooth > gen_sawtooth.log 2>&1 || { echo "gen_all: sawtooth failed" >&2; rc=1; }
wait "$bg" || { echo "gen_all: book120 failed" >&2; rc=1; }
"${UVR[@]}" gen_scanned.py plates > gen_plates.log 2>&1 || { echo "gen_all: plates failed" >&2; rc=1; }
tail -n 2 gen_*.log
exit $rc
