#!/usr/bin/env python3
"""Check that every Chinese UI string has an English translation (GUI_SPEC §7.3).

Command-line SwiftPM does not extract strings into the String Catalog the way Xcode does, so
Sources/MuluApp/Resources/Localizable.xcstrings is maintained by hand. This script finds the
localization keys the code uses and fails when one is missing from the catalog or has no
translated English value.

What counts as a key:
  * Sources/MuluApp: every string literal that contains CJK characters (comments are skipped).
    A line containing `strings:ignore` is exempt.
  * Sources/MuluAppModel: literals passed to String(localized:) or LocalizedStringResource(...)
    (the model's only user-visible text is undo action names, GUI_SPEC §4.7).

Interpolations become format specifiers the way Swift builds localization keys: an Int is %lld,
a String or Text is %@, a Double is %lf. The script cannot see types, so it accepts any of them.

Usage: scripts/check_strings.py [--verbose]
Exit status: 0 when every key is translated, 1 otherwise.
"""
from __future__ import annotations

import itertools
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources" / "MuluApp" / "Resources" / "Localizable.xcstrings"
APP_DIR = ROOT / "Sources" / "MuluApp"
MODEL_DIR = ROOT / "Sources" / "MuluAppModel"

CJK = re.compile(r"[　-〿㐀-䶿一-鿿＀-￯]")
SPECIFIERS = ("%lld", "%@", "%lf", "%llu")
LOCALIZED_CALL = re.compile(r"(String\(\s*localized:|LocalizedStringResource\()\s*$")
FORMAT_SPEC = re.compile(r"%(?:\d+\$)?(?:lld|llu|ld|lu|lf|d|u|f|@)")


class Literal:
    """A Swift string literal: alternating text parts and interpolation expressions."""

    def __init__(self, parts: list[str], interpolations: int, line: int, prefix: str):
        self.parts = parts
        self.interpolations = interpolations
        self.line = line
        self.prefix = prefix

    @property
    def text(self) -> str:
        return "".join(self.parts)

    def candidate_keys(self) -> list[str]:
        if self.interpolations == 0:
            return [self.parts[0]]
        escaped = [p.replace("%", "%%") for p in self.parts]
        keys = []
        for combo in itertools.product(SPECIFIERS, repeat=self.interpolations):
            key = escaped[0]
            for spec, part in zip(combo, escaped[1:]):
                key += spec + part
            keys.append(key)
        return keys


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def parse_literals(source: str) -> list[Literal]:
    """Extract string literals from Swift source, skipping comments."""
    out: list[Literal] = []
    i, n, line = 0, len(source), 1

    def parse_string(start: int, multiline: bool) -> tuple[Literal, int]:
        nonlocal line
        j = start
        parts, current, interps = [], [], 0
        start_line = line
        terminator = '"""' if multiline else '"'
        while j < n:
            if source.startswith(terminator, j):
                j += len(terminator)
                break
            c = source[j]
            if c == "\n":
                line += 1
            if c == "\\" and j + 1 < n:
                nxt = source[j + 1]
                if nxt == "(":
                    parts.append("".join(current))
                    current = []
                    interps += 1
                    j = skip_interpolation(j + 2)
                    continue
                if nxt == "u" and j + 2 < n and source[j + 2] == "{":
                    end = source.index("}", j + 3)
                    current.append(chr(int(source[j + 3:end], 16)))
                    j = end + 1
                    continue
                if multiline and nxt == "\n":  # line continuation
                    line += 1
                    j += 2
                    continue
                current.append(ESCAPES.get(nxt, nxt))
                j += 2
                continue
            current.append(c)
            j += 1
        parts.append("".join(current))
        if multiline:
            parts = [dedent_multiline(p) for p in parts]
        prefix = source[max(0, start - 200):start - (3 if multiline else 1)]
        return Literal(parts, interps, start_line, prefix), j

    def skip_interpolation(j: int) -> int:
        """Skip to after the ')' closing an interpolation; nested strings are parsed too."""
        nonlocal line
        depth = 1
        while j < n and depth:
            c = source[j]
            if c == "\n":
                line += 1
            if c == '"':
                multiline = source.startswith('"""', j)
                lit, j = parse_string(j + (3 if multiline else 1), multiline)
                out.append(lit)
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            j += 1
        return j

    while i < n:
        c = source[i]
        if c == "\n":
            line += 1
            i += 1
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
        elif source.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif source.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    if source[i] == "\n":
                        line += 1
                    i += 1
        elif c == "#" and i + 1 < n and source[i + 1] in '#"':
            # Raw string: skip it (not used for UI text).
            hashes = 0
            while i < n and source[i] == "#":
                hashes, i = hashes + 1, i + 1
            if i < n and source[i] == '"':
                closing = '"' + "#" * hashes
                end = source.find(closing, i + 1)
                segment = source[i:end if end >= 0 else n]
                line += segment.count("\n")
                i = n if end < 0 else end + len(closing)
        elif c == '"':
            multiline = source.startswith('"""', i)
            lit, i = parse_string(i + (3 if multiline else 1), multiline)
            out.append(lit)
        else:
            i += 1
    return out


def dedent_multiline(text: str) -> str:
    lines = text.split("\n")
    if lines and lines[0] == "":
        lines = lines[1:]
    indent = min((len(l) - len(l.lstrip(" ")) for l in lines if l.strip()), default=0)
    return "\n".join(l[indent:] for l in lines).rstrip(" ")


def collect_keys() -> dict[str, list[tuple[Path, Literal]]]:
    """Map from the literal's text to the places it appears."""
    uses: dict[str, list[tuple[Path, Literal]]] = {}
    for directory, strict in ((APP_DIR, True), (MODEL_DIR, False)):
        if not directory.exists():
            continue
        for path in sorted(directory.rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            lines = source.split("\n")
            for lit in parse_literals(source):
                if not CJK.search(lit.text):
                    continue
                if 0 < lit.line <= len(lines) and "strings:ignore" in lines[lit.line - 1]:
                    continue
                if not strict and not LOCALIZED_CALL.search(lit.prefix):
                    continue
                uses.setdefault("\u0000".join(lit.parts) + f"\u0001{lit.interpolations}", []).append((path, lit))
    return uses


def english_value(entry: dict) -> str | None:
    unit = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
    if unit.get("state") not in ("translated", None) or not unit.get("value"):
        return None
    return unit["value"]


def spec_count(text: str) -> int:
    return len(FORMAT_SPEC.findall(text.replace("%%", "")))


def main() -> int:
    verbose = "--verbose" in sys.argv
    try:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"check_strings: cannot read {CATALOG.relative_to(ROOT)}: {error}")
        return 1
    if catalog.get("sourceLanguage") != "zh-Hans":
        print("check_strings: sourceLanguage must be zh-Hans")
        return 1
    strings: dict = catalog.get("strings", {})

    problems: list[str] = []
    used_keys: set[str] = set()
    uses = collect_keys()
    for occurrences in uses.values():
        path, lit = occurrences[0]
        where = f"{path.relative_to(ROOT)}:{lit.line}"
        found = next((k for k in lit.candidate_keys() if k in strings), None)
        if found is None:
            shown = lit.candidate_keys()[0] if lit.interpolations == 0 else lit.candidate_keys()[0] + "  (or another %lld/%@/%lf mix)"
            problems.append(f"missing key      {where}: {shown!r}")
            continue
        used_keys.add(found)
        value = english_value(strings[found])
        if value is None:
            problems.append(f"no English       {where}: {found!r}")
        elif spec_count(value) != spec_count(found):
            problems.append(f"format mismatch  {where}: {found!r} -> {value!r}")

    stale = sorted(set(strings) - used_keys)
    for key, entry in strings.items():
        if key in used_keys:
            continue
        if english_value(entry) is None:
            problems.append(f"no English       (catalog only): {key!r}")

    print(f"check_strings: {len(uses)} Chinese UI strings, {len(strings)} catalog entries, "
          f"{len(problems)} problem(s), {len(stale)} unused catalog entr{'y' if len(stale) == 1 else 'ies'}")
    for line in problems:
        print("  " + line)
    if verbose and stale:
        print("unused catalog entries (not an error):")
        for key in stale:
            print(f"  {key!r}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
