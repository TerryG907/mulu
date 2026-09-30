# 真实扫描书测试 / Real-scan test

17 本 Internet Archive 公版扫描书（1874–1926 年出版）上的测试工具。结果见 [docs/REALSCAN.md](../../docs/REALSCAN.md)。
Tools for testing Mulu on 17 public-domain scanned books from Internet Archive (published 1874–1926). Results: [docs/REALSCAN.md](../../docs/REALSCAN.md).

| 文件 / File | 作用 / Purpose |
|---|---|
| `fetch.sh DEST` | 下载 17 本书并校验 SHA-1（约 247 MB）/ download the books and verify SHA-1 (~247 MB) |
| `manifest.json` | 每本书的编号、书名、年份、来源、页数、压缩方式 / identifier, title, year, source, pages, compression |
| `toc_pages.tsv` | 每本书印刷目录所在的物理页 / physical pages of each printed TOC |
| `run_auto.sh BOOKS OUT` | 对每本书运行 `mulu auto` / run `mulu auto` on every book |
| `score_landing.py --books BOOKS --out OUT` | 用 PDF 自带的 ABBYY 文字层检查每个书签是否落在正确页 / check each bookmark's target page against the ABBYY text layer |
| `build_reference.py --books BOOKS --out DIR` | 从 ABBYY 文字层生成参考目录和页码偏移 / build a reference TOC and page offset from the ABBYY text layer |

书不进仓库。所有书都在美国属于公版（1928 年及以前出版）。
The books themselves are not in the repository. All are public domain in the US (published 1928 or earlier).
