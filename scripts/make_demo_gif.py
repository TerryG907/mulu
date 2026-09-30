# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pillow>=10",
#   "pyobjc-framework-Quartz>=10",
# ]
# ///
"""
make_demo_gif.py -- rebuilds docs/images/demo.gif, the animation at the top of the README.

    scripts/package_app.sh                      # dist/Mulu.app
    tools/run_all.sh --books                    # Fixtures/books (synthetic scanned books)
    uv run --python 3.12 scripts/make_demo_gif.py [--app dist/Mulu.app] [--out docs/images/demo.gif]

The app cannot be clicked from a script without the Accessibility permission, so each stage
of the story is reached through the smoke mode (GUI_SPEC §9.3): the app is started once per
stage with MULU_SMOKE_* set, holds its window (MULU_SMOKE_HOLD), the window is captured with
`screencapture -l`, and the app is stopped. The frames are real windows of the real app; only
the caption bar under them is drawn here.

  stage     environment                                   what the window shows
  open      MULU_SMOKE                                    the book, no outline yet
  marked    + MULU_SMOKE_TOC, MULU_SMOKE_STOP=marked      TOC pages marked
  result    + MULU_SMOKE_TOC, MULU_SMOKE_STOP=result      the recognition result panel
  draft     + MULU_SMOKE_TOC                              the draft, doubtful rows in orange
  review    + MULU_SMOKE_TOC, MULU_SMOKE_STOP=review      review of the first doubtful row
  written   + MULU_SMOKE_TOC, MULU_SMOKE_WRITE            the banner after writing

The book is a copy of a synthetic scanned book from Fixtures/books (generated text, invented
publisher), renamed to its printed title so the window title reads like a book. Everything is
written to a temporary folder that is removed at the end; the only output is the GIF.

Needs the Screen Recording permission for the terminal that runs it (macOS asks the first
time). The app is started in the background and does not take the keyboard focus, but keep an
ordinary desktop in front while it runs: with a full-screen app in front, the app's windows
land on another Space, and there the result panel (a sheet) cannot be captured. Takes about
a minute; run it with `nice -n 15` to keep the Mac responsive.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]

WIDTH = 900                      # GIF width in pixels
BAR = 60                         # caption bar height
BAR_COLOR = (31, 35, 40)
ACCENT = (9, 105, 218)
FADE_STEPS = 2                   # blended frames between two stages
FADE_MS = 60
HOLD_SECONDS = 20                # how long the app keeps a stage on screen (we stop it sooner)
SETTLE_SECONDS = 2.5             # thumbnails and the preview finish rendering
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"

# (name, extra environment, Chinese caption, English caption, seconds on screen)
STAGES = [
    ("open", {}, "打开一本扫描书", "Open a scanned book", 1.1),
    ("marked", {"toc": True, "stop": "marked"}, "标出印着目录的那几页", "Mark the pages of the printed contents", 1.2),
    ("result", {"toc": True, "stop": "result"}, "在本机把目录页识别成草稿", "Recognise them into a draft, on this Mac", 1.4),
    ("draft", {"toc": True}, "拿不准的条目标成橙色", "Rows it is not sure about are flagged in orange", 1.4),
    ("review", {"toc": True, "stop": "review"}, "逐条核对，预览跟着跳到那一页", "Check them one by one; the preview jumps to the page", 1.5),
    ("written", {"toc": True, "write": True}, "", "", 2.3),
]


def windows_of(pid: int) -> list[dict]:
    import Quartz

    out = []
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []:
        if w.get("kCGWindowOwnerPID") != pid or w.get("kCGWindowLayer") != 0:
            continue
        b = w.get("kCGWindowBounds") or {}
        area = float(b.get("Width", 0)) * float(b.get("Height", 0))
        # Title-less helper windows are tiny; the document window is at least 1100 x 680.
        if area < 400 * 300:
            continue
        out.append({"id": int(w["kCGWindowNumber"]), "area": area, "onscreen": bool(w.get("kCGWindowIsOnscreen"))})
    # The window counts as off screen while another Space is in front; it can still be captured.
    return sorted(out, key=lambda w: (not w["onscreen"], -w["area"]))


def capture_stage(exe: Path, book: Path, toc: str, work: Path, name: str, opts: dict) -> tuple[Path, dict]:
    """Starts the app for one stage, captures its document window, stops the app."""
    report = work / f"{name}.json"
    shot = work / f"{name}.png"
    env = dict(os.environ)
    env.update({"MULU_SMOKE": str(book), "MULU_SMOKE_OUT": str(report), "MULU_SMOKE_HOLD": str(HOLD_SECONDS),
                "MULU_SMOKE_TIMEOUT": "60"})
    if opts.get("toc"):
        env["MULU_SMOKE_TOC"] = toc
    if opts.get("stop"):
        env["MULU_SMOKE_STOP"] = opts["stop"]
    if opts.get("write"):
        env["MULU_SMOKE_WRITE"] = str(book.with_name(book.stem + "-目录.pdf"))
    proc = subprocess.Popen([str(exe), "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(zh-Hans)"],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 60
        while not report.exists():
            if proc.poll() is not None or time.time() > deadline:
                raise SystemExit(f"make_demo_gif: stage '{name}' wrote no report (exit {proc.poll()})")
            time.sleep(0.1)
        data = json.loads(report.read_text(encoding="utf-8"))
        if data.get("status") != "ok":
            raise SystemExit(f"make_demo_gif: stage '{name}' failed: {data.get('error')}")
        # An app built before MULU_SMOKE_STOP existed ignores it and runs to the end.
        rows = (data.get("draft") or {}).get("rows", 0)
        stopped_early = {"marked": data.get("recognition") is None and rows == 0, "result": rows == 0,
                         "review": data.get("write") is None}
        if not stopped_early.get(opts.get("stop"), True):
            raise SystemExit(f"make_demo_gif: stage '{name}' did not stop at '{opts['stop']}': "
                             "this app build is older than MULU_SMOKE_STOP (run scripts/package_app.sh)")
        time.sleep(SETTLE_SECONDS)
        wins = windows_of(proc.pid)
        if not wins:
            raise SystemExit(f"make_demo_gif: stage '{name}': the app has no document window")
        # A sheet is captured together with the window it is attached to.
        done = subprocess.run(["screencapture", "-x", "-o", "-l", str(wins[0]["id"]), str(shot)],
                              capture_output=True, text=True)
        if done.returncode != 0 or not shot.exists():
            raise SystemExit(f"make_demo_gif: stage '{name}': screencapture failed ({done.stderr.strip() or 'no image'}). "
                             "Check the Screen Recording permission, and keep an ordinary desktop in front: "
                             "a window with a sheet cannot be captured while a full-screen app covers it.")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    return shot, data


def caption_bar(index: int, total: int, zh: str, en: str) -> Image.Image:
    bar = Image.new("RGB", (WIDTH, BAR), BAR_COLOR)
    d = ImageDraw.Draw(bar)
    big = ImageFont.truetype(FONT, 20, index=2)
    small = ImageFont.truetype(FONT, 15, index=0)
    digit = ImageFont.truetype(FONT, 17, index=2)
    cx, cy, r = 32, BAR // 2, 15
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=ACCENT)
    d.text((cx, cy), str(index + 1), font=digit, fill="white", anchor="mm")
    d.text((62, 21), zh, font=big, fill=(255, 255, 255), anchor="lm")
    d.text((62, 44), en, font=small, fill=(208, 215, 222), anchor="lm")
    # progress dots on the right
    x0 = WIDTH - 22 - (total - 1) * 16
    for k in range(total):
        x = x0 + k * 16
        d.ellipse((x - 4, cy - 4, x + 4, cy + 4), fill=(255, 255, 255) if k == index else (87, 96, 106))
    return bar


def compose(shot: Path, index: int, total: int, zh: str, en: str) -> Image.Image:
    win = Image.open(shot).convert("RGBA")
    height = round(win.height * WIDTH / win.width)
    flat = Image.new("RGBA", win.size, BAR_COLOR + (255,))
    flat.alpha_composite(win)
    frame = Image.new("RGB", (WIDTH, height + BAR), BAR_COLOR)
    frame.paste(flat.convert("RGB").resize((WIDTH, height), Image.Resampling.LANCZOS), (0, 0))
    frame.paste(caption_bar(index, total, zh, en), (0, height))
    return frame


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", default=str(ROOT / "dist" / "Mulu.app"))
    ap.add_argument("--book", default=str(ROOT / "Fixtures" / "books" / "zh_pharm_fullwidth_jpeg.pdf"))
    ap.add_argument("--toc", default="8-9", help="physical pages of the printed TOC in --book")
    ap.add_argument("--title", default="临床药理学基础", help="file name the book gets in the window title")
    ap.add_argument("--out", default=str(ROOT / "docs" / "images" / "demo.gif"))
    ap.add_argument("--keep-frames", default="", help="also copy the captured PNGs into this folder")
    args = ap.parse_args()

    exe = Path(args.app) / "Contents" / "MacOS" / "Mulu"
    if not exe.exists():
        print(f"make_demo_gif: {exe} not found (run scripts/package_app.sh first)", file=sys.stderr)
        return 2
    source = Path(args.book)
    if not source.exists():
        print(f"make_demo_gif: {source} not found (run tools/run_all.sh --books first)", file=sys.stderr)
        return 2

    work = Path(tempfile.mkdtemp(prefix="mulu-demo-"))
    try:
        book = work / f"{args.title}.pdf"
        shutil.copyfile(source, book)
        frames: list[Image.Image] = []
        holds: list[int] = []
        for i, (name, opts, zh, en, seconds) in enumerate(STAGES):
            shot, report = capture_stage(exe, book, args.toc, work, name, opts)
            if name == "result":
                rec = report["recognition"]
                print(f"[demo] recognised {rec['rows']} rows, {rec['doubtful']} doubtful, offset {rec['offset']}")
            if name == "written":
                w = report["write"]
                if not w["originalBytesUnchanged"]:
                    raise SystemExit("make_demo_gif: the written file does not start with the original bytes")
                zh = f"写成新文件：原文件的字节一个没动，末尾追加 {w['appendedBytes']:,} 字节"
                en = f"Saved as a new file: original bytes untouched, {w['appendedBytes']:,} bytes appended"
                print(f"[demo] wrote {w['items']} bookmarks, {w['appendedBytes']} bytes appended to {source.stat().st_size} bytes")
            if args.keep_frames:
                keep = Path(args.keep_frames)
                keep.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(shot, keep / f"{i + 1}-{name}.png")
            frames.append(compose(shot, i, len(STAGES), zh, en))
            holds.append(int(seconds * 1000))
            print(f"[demo] stage {i + 1}/{len(STAGES)} {name}", flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # One palette for every frame, so pixels that do not change between stages stay identical
    # and the GIF only stores the differences.
    sheet = Image.new("RGB", (WIDTH, frames[0].height * len(frames)))
    for i, f in enumerate(frames):
        sheet.paste(f, (0, i * f.height))
    palette = sheet.quantize(colors=255, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)

    sequence: list[Image.Image] = []
    durations: list[int] = []
    for i, f in enumerate(frames):
        sequence.append(f)
        durations.append(holds[i])
        nxt = frames[(i + 1) % len(frames)]
        for k in range(1, FADE_STEPS + 1):
            sequence.append(Image.blend(f, nxt, k / (FADE_STEPS + 1)))
            durations.append(FADE_MS)
    quantized = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in sequence]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    quantized[0].save(out, save_all=True, append_images=quantized[1:], duration=durations, loop=0, optimize=False,
                      disposal=1)
    size = out.stat().st_size
    print(f"[demo] {out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}: {WIDTH}x{frames[0].height}, "
          f"{len(quantized)} frames, {sum(durations) / 1000:.1f} s, {size / 1e6:.2f} MB")
    if size > 3_000_000:
        print("make_demo_gif: the GIF is over 3 MB", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
