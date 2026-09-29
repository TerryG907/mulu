#!/usr/bin/env bash
# selftest.sh -- proves the gate itself on generated files (no personal files involved):
#   real mulu                        -> PASS, encrypted.pdf REFUSED, everything else pass
#   mulu that corrupts 1 prefix byte -> FAIL, BROKEN (prefix)
#   mulu that shifts entry 3 by +1   -> FAIL, BROKEN (reader diff)
# usage: tools/gate/selftest.sh [--mulu PATH]   (default: .build/release/mulu, built if missing)
# Inputs: Fixtures/generated (built here with tools/fixtures/make_fixtures.py when missing) and,
# if present, the scanned book Fixtures/books/zh_finance_small_jpeg.pdf (built by
# tools/run_all.sh --books; skipped with a note when missing).
# Exit 0 = all three checks behave as expected, 1 = a check failed, 2 = setup error.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UV="${UV:-$HOME/.local/bin/uv}"
if [[ ! -x "$UV" ]]; then UV="$(command -v uv || true)"; fi
if [[ -z "$UV" ]]; then echo "selftest: uv not found (install: https://docs.astral.sh/uv/)" >&2; exit 2; fi
REAL=""
if [[ "${1:-}" == "--mulu" ]]; then REAL="$2"; fi
if [[ -z "$REAL" ]]; then
  swift build -c release --package-path "$ROOT" >/dev/null 2>&1 || { echo "selftest: build failed" >&2; exit 2; }
  REAL="$(swift build -c release --package-path "$ROOT" --show-bin-path)/mulu"
fi
REAL="$(cd "$(dirname "$REAL")" && pwd)/$(basename "$REAL")"

# The generated fixtures are not committed: build them first on a fresh clone (about 10 s).
REQUIRED=(Fixtures/generated/encrypted.pdf Fixtures/generated/existing_outline.pdf
          Fixtures/generated/text_objstm.pdf Fixtures/generated/scan_g4.pdf)
OPTIONAL=(Fixtures/books/zh_finance_small_jpeg.pdf)
missing=0
for f in "${REQUIRED[@]}"; do [[ -f "$ROOT/$f" ]] || missing=1; done
if [[ $missing -eq 1 || ! -f "$ROOT/Fixtures/generated/manifest.json" ]]; then
  echo "selftest: Fixtures/generated is missing; building it (tools/fixtures/make_fixtures.py) ..."
  nice -n 10 "$UV" run --quiet --python 3.12 "$ROOT/tools/fixtures/make_fixtures.py" >/dev/null || {
    echo "selftest: fixture generation failed" >&2; exit 2; }
fi
for f in "${REQUIRED[@]}"; do
  [[ -f "$ROOT/$f" ]] || { echo "selftest: required input $f is missing" >&2; exit 2; }
done

T="$(mktemp -d -t mulu-gate-selftest)"
trap 'rm -rf "$T"' EXIT
mkdir "$T/books"
for f in "${REQUIRED[@]}"; do ln -s "$ROOT/$f" "$T/books/"; done
for f in "${OPTIONAL[@]}"; do
  if [[ -f "$ROOT/$f" ]]; then
    ln -s "$ROOT/$f" "$T/books/"
  else
    echo "selftest: note: $f not found, so no scanned book is included (build it with tools/run_all.sh --books)"
  fi
done
echo "selftest: inputs: $(cd "$T/books" && ls | tr '\n' ' ')"

cat > "$T/mulu_prefix" <<EOF
#!/bin/bash
if [[ "\$1" == apply ]]; then
  "$REAL" "\$@"; rc=\$?
  out="\${@: -1}"
  [[ \$rc -eq 0 ]] && printf 'X' | dd of="\$out" bs=1 seek=200 conv=notrunc 2>/dev/null
  exit \$rc
fi
exec "$REAL" "\$@"
EOF
cat > "$T/mulu_page" <<EOF
#!/bin/bash
if [[ "\$1" == apply ]]; then
  toc="\$3"; t2="\${toc}.bad"
  awk -F'\t' 'BEGIN{OFS="\t"} /^#/ {print; next} {n++; if(n==3){\$NF=\$NF+1} print}' "\$toc" > "\$t2"
  set -- "\$1" "\$2" "\$t2" "\${@:4}"
fi
exec "$REAL" "\$@"
EOF
chmod +x "$T/mulu_prefix" "$T/mulu_page"

fail=0
check() {  # label, mulu, want_exit, grep-pattern that must appear
  local label="$1" m="$2" want="$3" pat="$4"
  out="$(nice -n 10 "$UV" run --quiet --python 3.12 "$ROOT/tools/gate/gate.py" "$T/books" --mulu "$m" \
         --report "$T/$label.md" 2>&1)"
  rc=$?
  if [[ $rc -eq $want ]] && grep -Eq "$pat" <<<"$out"; then
    echo "selftest: $label ok (exit $rc)"
  else
    echo "selftest: $label FAILED (exit $rc, want $want, pattern '$pat')"; echo "$out" | tail -12; fail=1
  fi
}
check real   "$REAL"          0 "refused +encrypted.pdf"
check prefix "$T/mulu_prefix" 1 "broken .*prefix: output differs"
check page   "$T/mulu_page"   1 "broken .*reads a different outline"
if [[ $fail -eq 0 ]]; then echo "selftest: ALL OK"; else echo "selftest: FAILED"; fi
exit $fail
