#!/usr/bin/env bash
# Smoke test of the Mulu app through MULU_SMOKE mode (GUI_SPEC §9.3).
#
# Usage: scripts/smoke_app.sh [--app dist/Mulu.app | --bin <MuluApp executable>]
#                             [--stages ABCD] [--keep-registration] [--parity [--mulu <cli>]]
#
#   A  open + existing outline + write   Fixtures/generated/existing_outline.pdf
#   B  recognition                        Fixtures/books/zh_finance_small_jpeg.pdf, TOC pages 4-5
#   C  Finder-style open (odoc event)     --app only; exactly one visible window
#   D  language (zh-Hans, en)             --app only
#   E  closing a window frees its document (model, PDF, thumbnails): MULU_SMOKE_CLOSE=1
#   --parity  compare with `mulu auto --dry-run` on every book in Fixtures/books (GUI_SPEC §9.4)
#
# Default target: dist/Mulu.app, else the MuluApp binary from `swift build --show-bin-path`.
# Every app run has a 25-second kill guard (115 s in parity mode); the script fails if any Mulu
# process is left behind.
# Fixtures are git-ignored; a missing one skips its stage with a message.
# The whole run takes about a minute (parity: a few minutes): automated callers should run it in the background.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP=""
BIN=""
STAGES="ABCDE"
KEEP_REGISTRATION=0
PARITY=0
MULU_CLI=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?}"; shift 2 ;;
    --bin) BIN="${2:?}"; shift 2 ;;
    --stages) STAGES="${2:?}"; shift 2 ;;
    --keep-registration) KEEP_REGISTRATION=1; shift ;;
    --parity) PARITY=1; shift ;;
    --mulu) MULU_CLI="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "smoke_app: unknown option $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$APP" && -z "$BIN" ]]; then
  if [[ -d dist/Mulu.app ]]; then
    APP="dist/Mulu.app"
  else
    BIN="$(swift build --show-bin-path)/MuluApp"
  fi
fi
if [[ -n "$APP" ]]; then
  APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
  EXE="$APP/Contents/MacOS/Mulu"
else
  EXE="$BIN"
fi
[[ -x "$EXE" ]] || { echo "smoke_app: no executable at $EXE" >&2; exit 2; }
echo "smoke_app: target $EXE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mulu-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0
PASSES=0
GUARD_SECONDS=25   # kill guard per app run
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

pass() { echo "  PASS $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  FAIL $1"; FAILURES=$((FAILURES + 1)); }

# check <json> <python boolean expression over r> <label>
check() {
  local json="$1" expr="$2" label="$3"
  if python3 - "$json" "$expr" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    r = json.load(f)
try:
    ok = bool(eval(expr, {"r": r}))
except (KeyError, TypeError, IndexError):
    ok = False
if not ok:
    summary = {k: r.get(k) for k in ("status", "error", "app", "document", "draft", "write")}
    rec = r.get("recognition") or {}
    summary["recognition"] = {k: v for k, v in rec.items() if k != "muluText"}
    print("    report:", json.dumps(summary, ensure_ascii=False))
sys.exit(0 if ok else 1)
PY
  then pass "$label"; else fail "$label"; fi
}

run_smoke() {  # run_smoke <json-out> [env assignments…] -- [app args…]
  local out="$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  rm -f "$out"
  env "${envs[@]}" MULU_SMOKE_OUT="$out" "$EXE" -ApplePersistenceIgnoreState YES "$@" >/dev/null 2>&1 &
  local pid=$!
  local ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $ticks -ge $((GUARD_SECONDS * 10)) ]]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "    killed after $GUARD_SECONDS s"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

EXISTING="$ROOT/Fixtures/generated/existing_outline.pdf"
BOOK="$ROOT/Fixtures/books/zh_finance_small_jpeg.pdf"

if [[ "$STAGES" == *A* ]]; then
  echo "A: open + existing outline + write"
  if [[ -f "$EXISTING" ]]; then
    run_smoke "$WORK/a.json" MULU_SMOKE="$EXISTING" MULU_SMOKE_WRITE="$WORK/a-out.pdf"
    code=$?
    [[ $code -eq 0 ]] && pass "exit code 0" || fail "exit code $code"
    if [[ -f "$WORK/a.json" ]]; then
      check "$WORK/a.json" 'r["schema"] == 1 and r["status"] == "ok"' "status ok"
      check "$WORK/a.json" 'r["document"]["existingOutlineItems"] >= 1' "existing outline loaded"
      check "$WORK/a.json" 'r["draft"]["rows"] == r["document"]["existingOutlineItems"]' "draft rows = existing items"
      check "$WORK/a.json" 'r["write"]["originalBytesUnchanged"] is True and r["write"]["appendedBytes"] > 0' "original bytes unchanged"
      check "$WORK/a.json" 'r["app"]["windowsVisible"] >= 1' "window visible"
      if head -c "$(stat -f %z "$EXISTING")" "$WORK/a-out.pdf" | cmp -s - "$EXISTING"; then pass "output starts with the input bytes"; else fail "output prefix differs from input"; fi
    else
      fail "no JSON report"
    fi
  else
    echo "  SKIP: $EXISTING missing (run tools/run_all.sh once to generate fixtures)"
  fi
fi

if [[ "$STAGES" == *B* ]]; then
  echo "B: recognition"
  if [[ -f "$BOOK" ]]; then
    run_smoke "$WORK/b.json" MULU_SMOKE="$BOOK" MULU_SMOKE_TOC="4-5"
    code=$?
    [[ $code -eq 0 ]] && pass "exit code 0" || fail "exit code $code"
    if [[ -f "$WORK/b.json" ]]; then
      check "$WORK/b.json" 'r["status"] == "ok" and r["recognition"]["status"] == "finished"' "recognition finished"
      check "$WORK/b.json" 'r["recognition"]["offset"] == 6' "offset +6"
      check "$WORK/b.json" 'r["recognition"]["rows"] >= 30 and r["draft"]["rows"] >= 30' "at least 30 rows"
    else
      fail "no JSON report"
    fi
  else
    echo "  SKIP: $BOOK missing (tools/fixtures/make_books.py generates it)"
  fi
fi

if [[ "$STAGES" == *C* ]]; then
  echo "C: Finder-style open"
  if [[ -z "$APP" ]]; then
    echo "  SKIP: needs --app"
  elif [[ ! -f "$EXISTING" ]]; then
    echo "  SKIP: $EXISTING missing"
  else
    rm -f "$WORK/c.json"
    open -g -n -a "$APP" --env MULU_SMOKE=@odoc --env MULU_SMOKE_OUT="$WORK/c.json" "$EXISTING" \
      --args -ApplePersistenceIgnoreState YES
    ticks=0
    while [[ ! -s "$WORK/c.json" && $ticks -lt 250 ]]; do sleep 0.1; ticks=$((ticks + 1)); done
    sleep 1
    if [[ -s "$WORK/c.json" ]]; then
      check "$WORK/c.json" 'r["status"] == "ok"' "status ok"
      check "$WORK/c.json" 'r["app"]["bundled"] is True and r["app"]["activationPolicy"] == "regular"' "bundled, regular policy"
      check "$WORK/c.json" 'r["app"]["windowsVisible"] == 1' "exactly one visible window"
    else
      fail "no JSON report within 25 s"
    fi
    pkill -9 -f "$APP/Contents/MacOS/Mulu" 2>/dev/null || true
  fi
fi

if [[ "$STAGES" == *D* ]]; then
  echo "D: language"
  if [[ -z "$APP" ]]; then
    echo "  SKIP: needs --app"
  elif [[ ! -f "$EXISTING" ]]; then
    echo "  SKIP: $EXISTING missing"
  else
    for lang in zh-Hans en; do
      run_smoke "$WORK/d-$lang.json" MULU_SMOKE="$EXISTING" -- -AppleLanguages "($lang)"
      if [[ -f "$WORK/d-$lang.json" ]]; then
        check "$WORK/d-$lang.json" "r['status'] == 'ok' and r['app']['language'] == '$lang'" "language $lang"
      else
        fail "no JSON report for $lang"
      fi
    done
  fi
fi

if [[ "$STAGES" == *E* ]]; then
  echo "E: closing the window frees the document"
  if [[ -f "$EXISTING" ]]; then
    run_smoke "$WORK/e.json" MULU_SMOKE="$EXISTING" MULU_SMOKE_CLOSE=1
    code=$?
    if [[ -f "$WORK/e.json" ]]; then
      check "$WORK/e.json" 'r["status"] == "ok" and r["draft"]["rows"] >= 1' "document opened"
    else
      fail "no JSON report"
    fi
    # 0 = session, model and thumbnail renderer were freed; 4 = still alive 4 s after closing.
    [[ $code -eq 0 ]] && pass "document freed after the window closed" || fail "document still alive after the window closed (exit code $code)"
  else
    echo "  SKIP: $EXISTING missing"
  fi
fi

if [[ $PARITY -eq 1 ]]; then
  echo "Parity with mulu auto --dry-run"
  if [[ -z "$MULU_CLI" ]]; then
    MULU_CLI="$(swift build --show-bin-path)/mulu"
  fi
  if [[ ! -x "$MULU_CLI" ]]; then
    echo "  SKIP: no mulu CLI at $MULU_CLI (swift build --product mulu, or pass --mulu)"
  elif [[ ! -f Fixtures/books/manifest.json ]]; then
    echo "  SKIP: Fixtures/books/manifest.json missing"
  else
    python3 - <<'PY' > "$WORK/books.tsv"
import json
for b in json.load(open("Fixtures/books/manifest.json"))["books"]:
    pages = b["toc_pages"]
    print(f'{b["book"]}\t{min(pages)}-{max(pages)}' if pages == list(range(min(pages), max(pages) + 1))
          else f'{b["book"]}\t{",".join(map(str, pages))}')
PY
    GUARD_SECONDS=115  # big books: up to 40 TOC pages of OCR plus offset detection
    while IFS=$'\t' read -r book pages; do
      pdf="Fixtures/books/$book.pdf"
      [[ -f "$pdf" ]] || { echo "  SKIP $book (missing)"; continue; }
      "$MULU_CLI" auto "$pdf" --toc-pages "$pages" --dry-run >"$WORK/$book.cli.txt" 2>/dev/null
      cli_code=$?
      run_smoke "$WORK/$book.json" MULU_SMOKE="$ROOT/$pdf" MULU_SMOKE_TOC="$pages" MULU_SMOKE_TIMEOUT=110 >/dev/null
      if [[ ! -f "$WORK/$book.json" ]]; then fail "$book: no JSON report"; continue; fi
      if python3 - "$WORK/$book.json" "$WORK/$book.cli.txt" "$cli_code" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
cli = open(sys.argv[2], encoding="utf-8").read()
accepted = sys.argv[3] == "0"
rec = r.get("recognition") or {}
ok = rec.get("autoWouldAccept") == accepted and (not accepted or rec.get("muluText") == cli)
if not ok:
    print(f"    app autoWouldAccept={rec.get('autoWouldAccept')} cli exit={sys.argv[3]} "
          f"text equal={rec.get('muluText') == cli}")
sys.exit(0 if ok else 1)
PY
      then pass "$book"; else fail "$book"; fi
    done < "$WORK/books.tsv"
  fi
fi

LEFT="$(pgrep -fl '(Mulu\.app/Contents/MacOS/Mulu|/MuluApp)( |$)' || true)"
if [[ -n "$LEFT" ]]; then
  fail "Mulu processes left running:"
  echo "$LEFT" | sed 's/^/    /'
  pkill -9 -f '(Mulu\.app/Contents/MacOS/Mulu|/MuluApp)( |$)' 2>/dev/null || true
fi

# Launching the bundle registers it with LaunchServices (as an "Open With" PDF editor, rank
# Alternate). Undo that unless asked to keep it, so a test run leaves no trace.
if [[ -n "$APP" && $KEEP_REGISTRATION -eq 0 && -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
fi

echo "smoke_app: $PASSES passed, $FAILURES failed"
[[ $FAILURES -eq 0 ]]
