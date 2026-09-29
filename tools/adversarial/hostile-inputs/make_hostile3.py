# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9"]
# ///
"""make_hostile3.py -- round-3: 8-byte xref-stream field values at the Int/UInt64 edges (gen3/)."""
import sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pdfbuild import PDF, Registry, toc_basic  # noqa: E402
from make_hostile import emit, std_parts  # noqa: E402
from make_hostile2 import raw_xrefstm, std_rows  # noqa: E402

GEN = HERE / "gen3"
T5 = toc_basic(5)


def build(R):
    cases = [
        ("h3_u64max_offset", (1, 0xFFFFFFFFFFFFFFFF, 0), b""),
        ("h3_i64max_objstm_num", (2, 0x7FFFFFFFFFFFFFFF, 0), b""),
        ("h3_u64max_objstm_idx", (2, 30, 0xFFFFFFFFFFFFFFFF), b""),
        ("h3_i64max_gen", (1, 15, 0x7FFFFFFFFFFFFFFF), b""),
        ("h3_u64max_offset_junk", (1, 0xFFFFFFFFFFFFFFFF, 0), b"JUNK\n"),
        ("h3_i64max_prev_junk", None, b"JUNK\n"),
    ]
    for name, row, pre in cases:
        pdf = PDF(prefix=pre)
        objs, streams = std_parts(5)
        emit(pdf, objs, streams)
        rows = std_rows(pdf)
        trailer = b"/Root 1 0 R"
        if row is not None:
            rows[50] = row
        else:
            trailer += b" /Prev 999999999999999999"
        raw_xrefstm(pdf, 51, rows, (1, 8, 8), trailer)
        R.add(name, pdf.bytes(), T5, pages=5, xref="stream",
              desc=f"xref stream W [1 8 8]; unused object 50 entry {row}; prefix {pre!r}",
              probe="must not crash (UInt64->Int conversion / offset+base overflow)")


if __name__ == "__main__":
    GEN.mkdir(parents=True, exist_ok=True)
    for p in GEN.iterdir():
        p.unlink()
    R = Registry(GEN)
    build(R)
    R.save()
    print(f"wrote {len(R.manifest['fixtures'])} fixtures to {GEN}")
