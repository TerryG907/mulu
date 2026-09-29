// MuluOCR: Vision-based reading of printed table-of-contents pages and detection of the
// physical-minus-printed page offset. macOS only (Vision, CoreGraphics). The pure rules
// (PageTokens, LineLayout, OffsetVoter) are unit-tested without Vision.
//
// ocr-toc (TOCPageReader), per page:
//   1. Render with CoreGraphics at 300 dpi (long edge capped at 4000 px), grayscale.
//   2. VNRecognizeTextRequest .accurate, zh-Hans + en-US, language correction on. When most
//      text comes back rotated (the newest revision sometimes decides an upright page full
//      of dot leaders is upside down), retry with revision 2, then at 70% scale.
//      Observations read upside down, nested duplicates and punctuation-only specks are
//      dropped.
//   3. Skew from the right edges of the page-number column (Theil-Sen), else Vision's
//      baselines; every box is rotated back before layout.
//   4. The "目录"/"Contents" heading is removed; a vertical gutter at 30-70% of the width
//      with titles on both sides makes it two columns (left read before right).
//   5. Tall gaps between lines are OCRed again (Vision drops some short lines, "序 …… i").
//   6. Lines: observations grouped by vertical overlap (>= half the smaller height, no
//      horizontal overlap). The page number is the trailing token of the line
//      (PageToken.splitTrailing) or a last observation that is only a number.
//   7. Page-number column: the largest cluster of right (or left) edges of separated arabic
//      numbers. Numbers left of it belong to the title.
//   8. Second reading of the column (crop per line, contrast-stretched) for lines without
//      a number, repaired (O/l/I) or roman numbers, a digit left in the title, a number
//      short of the column's right edge, and numbers out of printed order. Crops are read
//      in five layouts (row 2x, stacked 1x, row 1x, stacked 2x English; stacked 2x Chinese)
//      until two readings agree; a changed number must fit the printed order better.
//      A lone "1"/"i" that Vision cannot see at all is recognized by its stroke shape.
//      When the number came from this second reading, trailing title words that sit in
//      the column and look like a number ("×11", "1 0") are dropped from the title.
//   9. Folios and headings are dropped (the TOC pages' own folios are kept in
//      TOCReadResult.folios); indentation levels are clusters of the first glyph's x
//      (tolerance 0.6 line height); "1" vs "i" is settled by the printed order.
//  10. Title vote: the page is read again at 200 and 400 dpi (Vision drops a thin
//      character such as 一 or 为 at one resolution and not at another); a title only
//      gains lost CJK characters, loses stray marks both re-readings agree on, or is
//      filled in when the first reading had none (TOCPageReader.voteTitle).
//
// detect-offset (OffsetDetector): ~24 pages spread through the book (first/last 5%
// skipped); the top and bottom 12% bands are OCRed together; folio candidates are standalone
// numbers ("12", "- 12 -", "第 12 页") or a number at either end of a running head (both
// edges, so alternating left/right folios count), never "第3章"/"Chapter 3"/"3.2". Pages
// without a standalone folio get a second English, no-correction reading. Each page votes
// once per distinct physical - printed; OffsetVoter documents the acceptance rule.
//
// Front matter (roman pages) and heading checks, used by `mulu auto`:
//   RomanOffsetVoter / OffsetDetector.detectRoman: roman folios in the header/footer bands,
//   at least 2 agreeing pages. HeadingLocator: reads the top (or all) of a page and finds a
//   TOC title as a line of its own (exact for titles of up to 3 characters, else within
//   20% edit distance); anchors roman entries ("前言" on its first page) and pages the
//   printed TOC did not give.
