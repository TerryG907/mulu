# Mulu 真实扫描书测试（2026-09-30）

## 结论

- **写入安全：17/17 通过。** 17 本真实扫描书都用 `tools/gate/run_gate.sh` 写入了测试目录，五个独立阅读器（PDFKit、qpdf、PDFium、pypdf、pdf.js）读出的目录全部正确，原文件逐字节不变。这些书来自两种生产者：Internet Archive 自家的 PDF，以及 LuraDocument 重新编码的 PDF。图像压缩覆盖了 JPEG2000，还有一本 JBIG2。
- **自动生成目录：1/17 成功，0 本写错。** `mulu auto` 只在《The New McGuffey third reader》上写出了目录，共 69 个书签，页码全部指对，只有少数标题有错字。其余 16 本都被拒绝，没有一本写出错误目录。
- **被拒绝的书，大多该拒。** 这些书的草稿里，书签能落到正确页的比例在 0% 到 78% 之间，多数很低；硬写出来会有大量错误书签。
- **一句话**：真书上 Mulu 很安全，但自动识别老式英文目录的能力还很弱，需要专门改进。

## 测了什么

- 17 本 Internet Archive 上的公版扫描书，出版于 1874–1926 年（美国公版，1928 年及以前出版）。其中 14 本英文、3 本中文。
- 书本身不在仓库里。`tools/realscan/fetch.sh` 可以重新下载同一批文件，并校验 SHA-1。书的清单在 `tools/realscan/manifest.json`。
- 目录所在页由脚本从 PDF 自带的 ABBYY 隐藏文字层里查找，再人工看缩略图核对，结果在 `tools/realscan/toc_pages.tsv`。

## 怎么打分

Internet Archive 的 PDF 里自带一层 ABBYY FineReader 识别出的隐藏文字。它和 Mulu 用的苹果 Vision 是两个独立的识别引擎，所以用它来打分：

- **落点检查**（`tools/realscan/score_landing.py`）：对每个书签，看它指向的那一页上，ABBYY 文字里有没有这个标题的关键词。落在正确页记"准确"；差 1–3 页记"接近"；附近都找不到记"未找到"。
- 这个检查只看每页前 15 行，所以从页面中间开始的章节会被误判为"接近"或"未找到"。对唯一写出目录的那本书，我把所有没对上的书签逐个按整页文字复查过，见下文。

## 每本书的结果

| 书 | 年份 | 结果 | 页码偏移检测 | 草稿/书签落点准确 |
|---|---|---|---|---|
| The New McGuffey third reader | 1901 | **写出 69 个书签** | +4，24/24 一致 | 61/69 前 15 行命中；其余 8 个按整页文字复查全部在正确页 |
| Analytical geometry for beginners | 1905 | 拒绝：40 条里 10 条可疑 | +6，23/24 一致 | 29/37（78%） |
| Manual of English grammar and composition | 1908 | 拒绝：126 条里 62 条可疑 | +12，24/24 一致 | 73/121（60%） |
| British Columbia readers: a third reader | 1916 | 拒绝：71 条里 31 条可疑 | +4，21/24 一致 | 40/70（57%） |
| Chemical calculations | 1915 | 拒绝：行不像目录 | — | 3/22 |
| Space, time and gravitation | 1920 | 拒绝：行不像目录 | — | 2/18 |
| Mathematics of accounting and finance | 1921 | 拒绝：行不像目录 | — | 6/70 |
| The history of steam navigation | 1903 | 拒绝：行不像目录 | — | 1/18 |
| The theory of sound（JBIG2） | 1877 | 拒绝：行不像目录 | — | 1/16 |
| Practical mathematics for beginners | 1905 | 拒绝：行不像目录 | — | 1/30 |
| Elementary English composition | 1902 | 拒绝：行不像目录 | — | 2/63 |
| A history of Lehigh County | 1902 | 拒绝：行不像目录 | — | 0/9 |
| The First voyage round the world | 1874 | 拒绝：页码偏移前后不一致 | — | 0/18 |
| Up from Slavery | 1906 | 拒绝：页码偏移前后不一致 | — | 1/16 |
| 植物的分布 | 1926 | 拒绝：页码偏移在书末改变 | — | 0/6 |
| 南洋植物志 | 1919 | 拒绝：目录页没有识别出文字（竖排，扫描页上下颠倒） | — | — |
| 峨眉遊記 | 1923 | 拒绝：行不像目录（竖排，页码是中文数字） | — | — |

"—"表示在走到页码偏移那一步之前就已经拒绝。

**一处测试方的错误**：《The history of steam navigation》的目录实际在第 15–18 页，我交给 Mulu 的范围是 15–16 页，少了两页。它被拒的主要原因仍是每章后面跟着大段内容提要的排版，但这一行的结果对 Mulu 不完全公平。

## 被拒绝的原因

1. **老式英文目录的排版**（11 本）。1900 年代的书常见"分析式目录"：章标题后面跟一段内容提要，或者章下面列一串没有页码的小节；还有按课次范围列的条目（"CHAP. II.—FABLES, LESSONS VI–VIII"）、单独一列的 "PAGE" 表头、罗马数字页码的前言。Mulu 把这些行判为"可疑"或"不像目录"。
2. **页码偏移在书中间改变**（3 本，其中 2 本英文、1 本中文）。常见原因是书里夹着没有页码的插图页。页码偏移在书中间改变，Mulu 目前只支持整本书用一个偏移，所以拒绝。
3. **竖排中文目录**（2 本：《南洋植物志》《峨眉遊記》）。Mulu 目前只支持横排目录。第 3 本中文书《植物的分布》是因为页码偏移在书末改变而被拒的，计入第 2 类。

## 核实过的事

- **写入没有弄坏任何一本书。** 每本书写入后，原文件的字节都原样保留在输出文件开头。
- **页码偏移：走到这一步的 4 本书里，3 本和 ABBYY 参考一致**：《Analytical geometry》+6、《Third reader》+4、《McGuffey》+4。《Manual of English grammar》上 Mulu 测出 +12，参考脚本给出 +13，但参考只有 2 个标题作为依据；Mulu 的 +12 有 24/24 抽样页一致，且按 +12 有 73 个书签落在正确页，所以更可能是参考脚本错了。
- **唯一写出的那本书，页码全部指对。** 69 个书签里，61 个的标题出现在目标页前 15 行。另外 8 个的课文从页面中间开始，我按整页文字逐个复查，标题都在目标页上。标题有少数错字，例如 "The Little Loat"（应为 "The Little Boat"），以及 "Stories about Parrots" 后面多出了 "8 $6"。

## 还没做的

- 支持分析式目录、内容提要、课次范围等老式排版。
- 分段页码偏移，用来处理中间夹了插图页的书。
- 竖排中文目录。
- 现代横排简体中文教材还没在真书上测过。这类书有版权，网上没有能合法获取的扫描件，需要用户用自己的书来测。

## 复现

```bash
swift build -c release
tools/realscan/fetch.sh ~/realscan-books                 # 下载 17 本书（约 247 MB），校验 SHA-1
tools/realscan/run_auto.sh ~/realscan-books ~/realscan-out
uv run --python 3.12 tools/realscan/score_landing.py --books ~/realscan-books --out ~/realscan-out
tools/gate/run_gate.sh ~/realscan-books                  # 写入安全闸门
```
