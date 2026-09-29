# /// script
# requires-python = ">=3.12"
# dependencies = ["pikepdf>=9"]
# ///
"""gen_zerobox.py -- big2000.pdf with ONE sampled body page (physical 101, the first page
detect-offset samples in a 2000-page book) given MediaBox [0 0 0 0]; written to vec/."""
from pathlib import Path
import pikepdf
HERE = Path(__file__).resolve().parent
pdf = pikepdf.open(HERE / "vec/big2000.pdf")
pdf.pages[100].obj.MediaBox = pikepdf.Array([0, 0, 0, 0])
pdf.save(HERE / "vec/big2000_zerobox.pdf")
print("ok")
