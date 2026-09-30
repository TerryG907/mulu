#!/usr/bin/env bash
# Run `mulu auto` on every real-scan book listed in toc_pages.tsv.
# Usage: tools/realscan/run_auto.sh BOOKS_DIR OUT_DIR
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
BOOKS="${1:?books dir}"; OUT="${2:?output dir}"; MULU="${MULU:-$REPO/.build/release/mulu}"
[[ -x "$MULU" ]] || { echo "build first: swift build -c release" >&2; exit 1; }
mkdir -p "$OUT"
while IFS=$'\t' read -r id pages; do
  [[ -z "$id" ]] && continue
  s=$(date +%s)
  nice -n 15 "$MULU" auto "$BOOKS/$id.pdf" --toc-pages "$pages" -o "$OUT/$id.pdf" --toc-out "$OUT/$id.toc.txt" > "$OUT/$id.log" 2>&1
  echo "$id exit=$? $(( $(date +%s)-s ))s"
done < "$HERE/toc_pages.tsv"
