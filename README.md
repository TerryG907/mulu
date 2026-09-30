# Mulu（目录）

给 PDF 加上可以点击的多级目录（书签），**原文件的字节一个都不改**。

Mulu 是一个免费、开源（MIT）的 macOS 命令行工具。它还能识别扫描书里印刷的目录页，自动算出页码偏移，一条命令把目录写进 PDF。

[English below](#english)

> **当前状态：预发布。** 只有命令行，还没有图形界面。下面的准确率数字来自程序生成的「合成」PDF 和扫描书。**在 17 本真实公版扫描书上**：写入安全 17/17 通过；`mulu auto` 只在 1 本上自动写出了目录（页码全对），其余 16 本都拒绝了，没有写错一本。老式英文目录、页码偏移在书中间改变、竖排中文目录目前都做不了。详见 [docs/REALSCAN.md](docs/REALSCAN.md)。

## 为什么做 Mulu

- 常用的加书签工具 PDF补丁丁（PDFPatcher）只能在 Windows 上用。
- 在 Mac 上，PDFKit（「预览」也基于它）保存时会把整个文件重写一遍，文件可能一下子变大很多。
- Mulu 用的是 PDF 标准里的「增量更新」（ISO 32000-1 §7.5.6）：新文件 = 原文件的全部字节 + 末尾追加的一小段目录。原来的内容一个字节都不动；测试时每个输出都会逐字节核对这一点。

我们的测试（PDFKit 整体重存 vs. Mulu 追加目录）：

| 样例 | 原大小（字节） | PDFKit 重存后 | 增长 | Mulu 追加 | 增长 |
|---|---:|---:|---:|---:|---:|
| scan_g4（G4 压缩的扫描件） | 1,987,616 | 4,267,663 | +114.7% | 6,973 | +0.35% |
| scan_jpeg（JPEG 扫描件） | 5,138,325 | 5,144,231 | +0.1% | 4,738 | +0.09% |
| text_classic_cjk（49 KB 的中文文本 PDF） | 49,336 | 106,202 | +115.3% | 6,908 | +14.00% |

说明：「PDFKit 重存」是用 PDFKit 的 API 保存（`tools/verify/pdfkit_resave.swift`）。「预览」用的是同一个框架，但我们没有直接在「预览」里点保存来测。JPEG 那一行说明，PDFKit 重存并不总是让文件变大。

## 命令一览

| 命令 | 作用 |
|---|---|
| `mulu apply` | 把一份目录文本写进 PDF |
| `mulu auto` | 扫描书一条命令：识别目录页 → 推断层级 → 算页码偏移 → 写入 |
| `mulu ocr-toc` | 用 macOS 自带的 Vision 识别印刷目录页 |
| `mulu toc parse` | 把印刷目录文字变成 Mulu 目录：推断层级，把印刷页码换成物理页码 |
| `mulu detect-offset` | 抽样正文页的页码，算出「物理页 − 印刷页」 |
| `mulu toc convert` | 在 Mulu、PDF补丁丁 XML、pdfdir、OPML、JSON 之间转换目录 |
| `mulu export-outline` | 导出 PDF 里已有的目录 |
| `mulu info` | 查看 PDF 的基本信息（JSON） |
| `mulu dump-outline` | 打印 PDF 里已有的目录（JSON） |

- 全部在本机完成。mulu 本身不联网，OCR 用的是 macOS 自带的 Vision 框架。
- 写 PDF 的命令（`apply`、`auto`）总是写到 `-o` 指定的新文件，输出路径等于输入文件时直接拒绝。输出文字的命令（`ocr-toc`、`detect-offset`、`toc parse`、`toc convert`、`export-outline`）打印到 stdout；其中后三个也可以用 `-o` 写到文件。
- 没把握时 mulu 会拒绝：退出码为 2，原因写在 stderr，不产生输出 PDF。

## 系统要求

- macOS 14 或更新
- Swift 6 工具链（Xcode 16 或更新版本自带）
- 开发和测试只在一台 Apple M5 Pro、macOS 26.6.2、Xcode 27 上做过。

## 从源码构建

```bash
git clone https://github.com/TerryG907/mu-lu.git mulu
cd mulu
swift build -c release
.build/release/mulu --help
```

可执行文件在 `.build/release/mulu`。可以把它复制到 `PATH` 里的某个目录（例如 `/usr/local/bin`）；下面的例子都假设直接输入 `mulu` 就能运行。

## 用法

### 已有目录文本，写进 PDF：`apply`

```bash
mulu apply 书.pdf 目录.txt -o 书-带目录.pdf
```

目录里写的是印刷页码时，加 `--offset N`（物理页 = 页码 + N）。`目录.txt` 写成 `-` 表示从标准输入读取。成功时 stdout 打印一行 JSON，写明追加了多少字节、写了多少条。

### 扫描书一条命令：`auto`

```bash
mulu auto 书.pdf --toc-pages 5-7 -o 书-带目录.pdf --toc-out 目录草稿.txt
```

- `--toc-pages` 是印刷目录所在的**物理页**，也就是「预览」侧边栏缩略图下面的页码，最多 40 页。
- 每一步做了什么都会打印出来。任何一步没把握就拒绝（退出码 2），不写 PDF。
- 被拒绝时，`--toc-out` 的草稿仍然会写出来，可疑的行前面标着 `# ?`。手工改好后用 `mulu apply` 写入。
- 已经知道偏移时可以加 `--offset N`；`--dry-run` 只打印目录，不写 PDF。

### 分步做：`ocr-toc`、`detect-offset`、`toc parse`

```bash
mulu ocr-toc 书.pdf --pages 5-7 > 印刷目录.txt
mulu detect-offset 书.pdf
mulu toc parse 印刷目录.txt --offset auto --pdf 书.pdf -o 目录.txt
```

- `ocr-toc` 每个条目输出一行，例如 `第一章 绪论<TAB>1`（印刷页码）。
- `detect-offset` 输出 JSON，其中 `offset` = 物理页 − 印刷页；没把握时 `offset` 为 null，退出码 2。
- `toc parse` 也能处理手打的或从网上书店复制的目录文字。`--offset auto --pdf 书.pdf` 会自动找偏移，也可以直接写 `--offset 8`。前言用罗马页码时可以加 `--roman-offset N`。

### 转换和导出：`toc convert`、`export-outline`

```bash
mulu toc convert 书签.xml --to mulu -o 目录.txt
mulu export-outline 书.pdf --format opml -o 目录.opml
```

支持的格式：`mulu`、`pdfpatcher-xml`（PDF补丁丁的信息文件）、`pdfdir`、`opml`、`json`。`toc convert` 默认自动识别输入格式。

### 查看：`info`、`dump-outline`

```bash
mulu info 书.pdf
mulu dump-outline 书.pdf
```

`info` 给出页数、交叉引用类型、是否加密、有没有目录；`dump-outline` 列出已有目录的标题、层级和页（`page_index` 从 0 开始数）。

## Mulu 目录格式

```text
# 以 # 开头的行是注释，空行会被忽略
前言 1
第一章 绪论 3
	1.1 研究背景 4
		1.1.1 国内研究现状 5
	1.2 本文结构 8
第二章 方法 11
```

- 每行：缩进 + 标题 + 空白 + 页码。页码是这一行**最后一个**用空白隔开的部分，必须是正整数；标题里可以有空格。
- 页码默认是物理页（1 = PDF 的第一页）。用了 `--offset N` 时，实际页 = 页码 + N。
- 层级看行首缩进：每个 TAB 算一级，或每 2 个空格算一级，或每个全角空格（U+3000）算一级。其他行首空白（比如不间断空格）会报错，不会悄悄压平层级。
- 第一条必须在最外层；每一行最多比上一行深一级。
- 文件用 UTF-8 编码，可以带 BOM。

## 实测结果（全部是合成样例）

> 下面的数字全部来自程序生成的 PDF 和合成扫描书：印刷整齐，没有真实纸张的阴影、弯曲和污渍。它们只说明「最好的情况下能做到什么」。真实扫描书的结果见 [docs/REALSCAN.md](docs/REALSCAN.md)。

**写入器**（`tools/run_all.sh`）

- 生成样例 31/31 行通过，回归样例 47/47 行通过（对抗评审的每个发现都有一个复现样例）。
- 每个输出都要满足：开头与原文件逐字节相同；五个独立阅读器（PDFKit、qpdf、PDFium、pypdf、pdf.js）和 mulu 自己读出的目录都与期望完全一致。例外：有 2 个回归样例，PDFKit 连原始输入都打不开，这几行的 PDFKit 一列记为 n/a，其余阅读器照常核对（见 [docs/RESULTS.md](docs/RESULTS.md)）。
- 该拒绝的文件（加密、页树有环、页码超出范围等）一律退出码 2，不产生输出。
- 给 500 页的 PDF 写目录：命令行端到端中位数 7.7 毫秒（30 次）。

**扫描书流水线**（`tools/run_all.sh --books`，13 本合成扫描书）

| 书 | 页数 | 条目 | 目录识别错字率 | 解析页码 | 解析层级 | 偏移 | auto 结果 |
|---|---:|---:|---:|---:|---:|---|---|
| zh_econ_textbook | 86 | 82 | 0.0% | 100% | 99% | 对 | 全对 |
| zh_network_decimal | 76 | 49 | 0.0% | 100% | 100% | 对 | 全对 |
| zh_history_parts_longtoc | 117 | 120 | 0.1% | 100% | 98% | 对 | 全对 |
| zh_mgmt_twocol（双栏目录） | 55 | 43 | 0.0% | 100% | 100% | 对 | 全对 |
| zh_mech_header_folio | 91 | 74 | 0.4% | 99% | 100% | 对 | 全对 |
| zh_policy_long_titles | 71 | 25 | 0.0% | 100% | 96% | 对 | 全对 |
| en_systems_technical | 102 | 61 | 0.7% | 100% | 97% | 对 | 全对 |
| en_router_manual_jpeg | 48 | 21 | 0.0% | 100% | 100% | 对 | 全对 |
| zh_essays_unnumbered（无编号） | 64 | 53 | 0.0% | 100% | 98% | 对 | 全对 |
| zh_pharm_fullwidth_jpeg | 73 | 38 | 0.6% | 100% | 97% | 对 | 全对 |
| zh_chem_noisy（很脏的扫描） | 69 | 58 | 23.4% | 84% | 90% | 对 | **拒绝** |
| zh_proceedings_ranges | 96 | 20 | 0.0% | 100% | 90% | 对 | 全对 |
| zh_finance_small_jpeg | 42 | 33 | 0.4% | 100% | 100% | 对 | 全对 |

- 「解析」两列是 `toc parse` 单独解析识别结果的准确率。`auto` 还会用正文页上的标题交叉核对，所以最后写进 PDF 的结果比这两列更准。
- 13 本里 12 本自动写出了目录，书签全部正确（页码、层级都对，标题错字率约 0.01%）；最脏的 1 本被拒绝，没有乱猜。
- 另有 38 个专门刁难的「乱目录」样例：29 个自动写出目录，共 492 个书签，其中 1 个多出来的书签（已标为可疑）和 3 个标题错字，其余书签页码全对；另外 9 个被拒绝。

**速度**（Apple M5 Pro，`nice -n 15` 低优先级）：识别目录页每页约 1 秒；找偏移每本 2–4.5 秒；整本 `mulu auto` 每本 4–16 秒（13 本平均 7.5 秒），内存峰值 350–400 MB。写入本身是毫秒级。

详细记录：[docs/RESULTS.md](docs/RESULTS.md)（写入器）、[docs/WEEK1.md](docs/WEEK1.md)（扫描书流水线）。

## 已知限制

- 真实扫描书上，自动目录只在 1/17 本上成功（其余拒绝，未写错），详见 [docs/REALSCAN.md](docs/REALSCAN.md)。现代横排简体中文教材还没在真书上测过。
- 下面几种目录目前会被拒绝（安全，但得不到目录）：页码印在标题左边；每个中文条目后面跟一行英文的双语目录；标题下面还有作者行（会议论文集）；页码紧贴在以数字结尾的标题后面（例如「iPhone 1512」）；英文标题里含罗马数字，又碰上识别不清（例如「Henry VIII」）；前言单独从 1 开始编页码。
- 书中间夹了没有页码的插页时只会拒绝，还不支持分段偏移。这种书只能先手工加 `--offset`，再改草稿。
- 标题偶尔会有错字（492 个书签里有 3 个），页码和层级不受影响。用之前最好扫一眼。
- 很脏的扫描（识别错字率 20% 以上）会被拒绝，只能手工校对草稿。
- 加密的 PDF 会被拒绝。JBIG2 压缩的扫描件没测过。

## 运行测试

```bash
swift test                    # 单元测试和回归测试
tools/run_all.sh              # 构建、生成样例、写入，再用五个阅读器交叉验证，并跑回归样例
tools/run_all.sh --selftest   # 另外先证明验证脚本能抓住故意写坏的输出
tools/run_all.sh --books      # 另外跑扫描书流水线（慢；第一次还要先生成几百 MB 的合成书）
```

`tools/run_all.sh` 需要 [uv](https://docs.astral.sh/uv/)（用 Python 3.12）和 Node.js/npm。第一次运行会下载 Python 依赖（pikepdf、pypdf、pypdfium2 等）和 pdf.js，并编译几个 Swift 小工具。生成的样例和输出都放在 `Fixtures/` 下，不进 git；只有 `Fixtures/regression/`（对抗评审的复现样例）是提交的。

`tools/run_all.sh` 默认按 CPU 核数并行启动阅读器进程（最多 16 个）。想让电脑在跑测试时保持流畅，可以加 `--jobs 2`，例如 `tools/run_all.sh --books --jobs 2`。

## 真实扫描闸门

用你自己的扫描书检验 mulu：

```bash
tools/gate/run_gate.sh ~/你的书文件夹 --make-csv
tools/gate/run_gate.sh ~/你的书文件夹
```

- 第一条生成 `tools/gate/toc_pages.csv`。在 `toc_pages` 一列填上印刷目录所在的物理页（例如 `5-7`），就会顺便试 `mulu auto`；不想试的书留空。
- mulu 只读你的书，不修改、不复制、不上传。每本书的输出写到临时目录，检查完就删掉。报告写在 `tools/gate/reports/`，CSV 和报告都不进 git。
- 最后一行 PASS 表示失败（拒绝、输出有误或出错）的书不超过 2 本。只要出现一本 BROKEN（有输出但读出来不对），就必须排查。

完整说明见 [tools/gate/README.md](tools/gate/README.md)。

## 路线图

- 现在：已在 17 本公版扫描书上测过，下一步是支持老式英文目录（内容提要、课次范围）和分段页码偏移，并用现代中文教材验证。
- 下一步：Mac 图形界面（GUI）。

## 许可证

MIT，见 [LICENSE](LICENSE)。

Mulu 与 PDF补丁丁（PDFPatcher）、pdfdir 和 Apple 均无关联；「预览」、PDFKit 和 Vision 是 Apple 的技术。

---

<a id="english"></a>

# Mulu (English)

Mulu adds a clickable, multi-level outline (bookmarks) to a PDF **without changing a single original byte**.

It is a free, open-source (MIT) command-line tool for macOS. It can also read the printed table of contents of a scanned book, work out the page offset, and write the outline in one command.

> **Status: pre-release.** Command line only; there is no GUI yet. The accuracy numbers below come from synthetic PDFs and synthetic scanned books. **On 17 real public-domain scans**, the writer passed 17/17; `mulu auto` wrote an outline for only 1 book (every page correct) and refused the other 16, writing no wrong outline. Old-style English TOCs, page offsets that change mid-book and vertical Chinese TOCs are not handled yet. See [docs/REALSCAN.md](docs/REALSCAN.md) (in Chinese).

## Why

- PDFPatcher (PDF补丁丁), a popular tool for adding bookmarks to scanned books, runs only on Windows.
- On a Mac, PDFKit (which Preview is built on) rewrites the whole file when it saves, which can make it much larger.
- Mulu writes a PDF *incremental update* (ISO 32000-1 §7.5.6): the new file is every byte of the original followed by a small appended section with the outline. The original bytes are never touched; the test harness checks this byte by byte for every output.

Our measurements (PDFKit whole-file resave vs. Mulu append):

| Sample | Input bytes | After PDFKit resave | Growth | Mulu appended | Growth |
|---|---:|---:|---:|---:|---:|
| scan_g4 (G4-compressed scan) | 1,987,616 | 4,267,663 | +114.7% | 6,973 | +0.35% |
| scan_jpeg (JPEG scan) | 5,138,325 | 5,144,231 | +0.1% | 4,738 | +0.09% |
| text_classic_cjk (49 KB Chinese text PDF) | 49,336 | 106,202 | +115.3% | 6,908 | +14.00% |

"PDFKit resave" means saving through the PDFKit API (`tools/verify/pdfkit_resave.swift`). Preview uses the same framework, but we did not measure by clicking Save in Preview. The JPEG row shows that a PDFKit resave does not always make the file bigger.

## Commands

| Command | What it does |
|---|---|
| `mulu apply` | Write an outline from a TOC text file |
| `mulu auto` | Scanned book in one command: OCR the TOC pages, infer levels, detect the page offset, write |
| `mulu ocr-toc` | OCR printed TOC pages with macOS Vision |
| `mulu toc parse` | Turn printed TOC text into a Mulu TOC: infer levels, convert printed pages to physical pages |
| `mulu detect-offset` | Sample page numbers printed on body pages and compute physical − printed |
| `mulu toc convert` | Convert between Mulu, PDFPatcher XML, pdfdir, OPML and JSON |
| `mulu export-outline` | Export the outline a PDF already has |
| `mulu info` | Basic facts about a PDF (JSON) |
| `mulu dump-outline` | Print the existing outline (JSON) |

- Everything runs locally. mulu itself makes no network connections; OCR uses the Vision framework built into macOS.
- Commands that write a PDF (`apply`, `auto`) always write a new file given with `-o`; an output path that is the input file is refused. Text commands (`ocr-toc`, `detect-offset`, `toc parse`, `toc convert`, `export-outline`) print to stdout; the last three can also write to a file with `-o`.
- When mulu is not confident it refuses: exit status 2, the reason on stderr, no output PDF.

## Requirements

- macOS 14 or later
- A Swift 6 toolchain (included with Xcode 16 or later)
- Developed and tested only on one Apple M5 Pro with macOS 26.6.2 and Xcode 27.

## Build from source

```bash
git clone https://github.com/TerryG907/mu-lu.git mulu
cd mulu
swift build -c release
.build/release/mulu --help
```

The binary is `.build/release/mulu`. Copy it to a directory on your `PATH` (for example `/usr/local/bin`); the examples below assume `mulu` runs it.

## Usage

### Write an outline from a TOC file: `apply`

```bash
mulu apply book.pdf toc.txt -o book-with-toc.pdf
```

If the TOC uses printed page numbers, add `--offset N` (physical page = page + N). Use `-` as the TOC path to read it from stdin. On success mulu prints one JSON line with the number of bytes appended and entries written.

### Scanned book in one command: `auto`

```bash
mulu auto book.pdf --toc-pages 5-7 -o book-with-toc.pdf --toc-out toc-draft.txt
```

- `--toc-pages` are the **physical** pages of the printed TOC (the numbers under the thumbnails in Preview's sidebar), at most 40 pages.
- Every step is reported. If any step is not confident, mulu refuses (exit 2) and writes no PDF.
- On a refusal the `--toc-out` draft is still written, with doubtful lines marked `# ?`. Fix it by hand and write it with `mulu apply`.
- Pass `--offset N` if you already know the offset; `--dry-run` prints the TOC without writing a PDF.

### Step by step: `ocr-toc`, `detect-offset`, `toc parse`

```bash
mulu ocr-toc book.pdf --pages 5-7 > printed-toc.txt
mulu detect-offset book.pdf
mulu toc parse printed-toc.txt --offset auto --pdf book.pdf -o toc.txt
```

- `ocr-toc` prints one line per entry, such as `Chapter 1 Introduction<TAB>1` (printed page).
- `detect-offset` prints JSON where `offset` = physical − printed; when it is not confident, `offset` is null and the exit status is 2.
- `toc parse` also accepts TOC text typed by hand or copied from an online bookstore. `--offset auto --pdf book.pdf` detects the offset; `--offset 8` sets it. Use `--roman-offset N` for front matter numbered in roman numerals.

### Convert and export: `toc convert`, `export-outline`

```bash
mulu toc convert bookmarks.xml --to mulu -o toc.txt
mulu export-outline book.pdf --format opml -o toc.opml
```

Formats: `mulu`, `pdfpatcher-xml` (PDFPatcher's info file), `pdfdir`, `opml`, `json`. `toc convert` detects the input format by default.

### Inspect: `info`, `dump-outline`

```bash
mulu info book.pdf
mulu dump-outline book.pdf
```

`info` reports the page count, cross-reference type, encryption and whether an outline exists; `dump-outline` lists the existing outline's titles, levels and pages (`page_index` counts from 0).

## The Mulu TOC format

```text
# Lines starting with # are comments; blank lines are ignored
Preface 1
Chapter 1 Introduction 3
	1.1 Background 4
		1.1.1 Prior work 5
	1.2 Outline of this book 8
Chapter 2 Method 11
```

- Each line is indentation + title + whitespace + page. The page is the **last** whitespace-separated token and must be a positive integer; titles may contain spaces.
- Pages are physical by default (1 = the first page of the PDF). With `--offset N` the target page is page + N.
- The level comes from the leading indentation: one TAB, two spaces, or one full-width space (U+3000) per level. Any other leading whitespace (such as a no-break space) is an error rather than a silently flattened level.
- The first entry must be at the top level, and a line can be at most one level deeper than the line before it.
- The file is UTF-8, with or without a BOM.

## Measured results (synthetic samples only)

> Every number below comes from generated PDFs and synthetic scanned books: clean print, no shadows, curvature or stains from real paper. They show the best case. Real-scan results: [docs/REALSCAN.md](docs/REALSCAN.md).

**Writer** (`tools/run_all.sh`)

- 31/31 generated-fixture rows and 47/47 regression rows pass (one reproducer per adversarial-review finding).
- For every output: its first bytes equal the original file byte for byte, and five independent readers (PDFKit, qpdf, PDFium, pypdf, pdf.js) plus mulu's own reader report exactly the expected outline. The exception is 2 regression files that PDFKit cannot open even before mulu touches them: those rows record PDFKit as n/a and check the other readers as usual (see [docs/RESULTS.md](docs/RESULTS.md)).
- Files that must be refused (encrypted, page-tree cycles, pages out of range and so on) exit 2 with no output.
- Writing an outline into a 500-page PDF: median 7.7 ms end to end from the command line (30 runs).

**Scanned-book pipeline** (`tools/run_all.sh --books`, 13 synthetic scanned books)

| Book | Pages | Entries | TOC OCR character error | Parse: pages | Parse: levels | Offset | auto result |
|---|---:|---:|---:|---:|---:|---|---|
| zh_econ_textbook | 86 | 82 | 0.0% | 100% | 99% | right | all right |
| zh_network_decimal | 76 | 49 | 0.0% | 100% | 100% | right | all right |
| zh_history_parts_longtoc | 117 | 120 | 0.1% | 100% | 98% | right | all right |
| zh_mgmt_twocol (two-column TOC) | 55 | 43 | 0.0% | 100% | 100% | right | all right |
| zh_mech_header_folio | 91 | 74 | 0.4% | 99% | 100% | right | all right |
| zh_policy_long_titles | 71 | 25 | 0.0% | 100% | 96% | right | all right |
| en_systems_technical | 102 | 61 | 0.7% | 100% | 97% | right | all right |
| en_router_manual_jpeg | 48 | 21 | 0.0% | 100% | 100% | right | all right |
| zh_essays_unnumbered (no numbering) | 64 | 53 | 0.0% | 100% | 98% | right | all right |
| zh_pharm_fullwidth_jpeg | 73 | 38 | 0.6% | 100% | 97% | right | all right |
| zh_chem_noisy (very dirty scan) | 69 | 58 | 23.4% | 84% | 90% | right | **refused** |
| zh_proceedings_ranges | 96 | 20 | 0.0% | 100% | 90% | right | all right |
| zh_finance_small_jpeg | 42 | 33 | 0.4% | 100% | 100% | right | all right |

- The two "Parse" columns score `toc parse` on the OCR output alone. `auto` also cross-checks chapter headings on the body pages, so what it finally writes is more accurate than these columns.
- 12 of the 13 books got an outline with every bookmark right (page and level; title character error about 0.01%). The dirtiest book was refused rather than guessed.
- 38 extra "messy TOC" cases built to break the parser: 29 got an outline with 492 bookmarks in total, including 1 extra bookmark (flagged as doubtful) and 3 titles with a wrong character; every other bookmark is on the right page. The other 9 were refused.

**Speed** (Apple M5 Pro, low priority with `nice -n 15`): OCR of a TOC page about 1 s; offset detection 2–4.5 s per book; a whole `mulu auto` run 4–16 s per book (mean 7.5 s over 13 books), peak memory 350–400 MB. Writing itself takes milliseconds.

Full records (in Chinese): [docs/RESULTS.md](docs/RESULTS.md) (writer) and [docs/WEEK1.md](docs/WEEK1.md) (scanned-book pipeline).

## Known limitations

- On real scans, `mulu auto` succeeded on 1 of 17 books (the rest were refused, none written wrong); see [docs/REALSCAN.md](docs/REALSCAN.md). Modern horizontal simplified-Chinese textbooks are still untested on real scans.
- These TOC layouts are currently refused (safe, but no outline): page numbers printed to the left of titles; bilingual TOCs with an English line under each Chinese entry; author lines under titles (conference proceedings); page numbers glued to a title that ends in digits (such as "iPhone 1512"); English titles with roman numerals that OCR misreads (such as "Henry VIII"); front matter numbered separately from 1.
- A book with unnumbered plates in the middle is refused; per-section offsets are not supported yet. For such a book, pass `--offset` by hand and edit the draft.
- Titles occasionally have a wrong character (3 of 492 bookmarks); pages and levels are unaffected. Skim the result before relying on it.
- Very dirty scans (OCR character error above 20%) are refused; correct the draft by hand.
- Encrypted PDFs are refused. JBIG2-compressed scans have not been tested.

## Running the tests

```bash
swift test                    # unit and regression tests
tools/run_all.sh              # build, generate fixtures, apply, cross-check with five readers, run the regression set
tools/run_all.sh --selftest   # also prove first that the harness catches deliberately broken outputs
tools/run_all.sh --books      # also run the scanned-book pipeline (slow; the first run also generates a few hundred MB of synthetic books)
```

`tools/run_all.sh` needs [uv](https://docs.astral.sh/uv/) (it uses Python 3.12) and Node.js/npm. The first run downloads Python packages (pikepdf, pypdf, pypdfium2 and others) and pdf.js, and compiles a few small Swift helpers. Generated fixtures and outputs go under `Fixtures/` and are not tracked by git; only `Fixtures/regression/` (the adversarial reproducers) is committed.

By default `tools/run_all.sh` starts reader processes in parallel, one per CPU core (at most 16). To keep the Mac responsive while the tests run, add `--jobs 2`, for example `tools/run_all.sh --books --jobs 2`.

## The real-scan gate

Check mulu against your own scanned books:

```bash
tools/gate/run_gate.sh ~/your-books --make-csv
tools/gate/run_gate.sh ~/your-books
```

- The first command writes `tools/gate/toc_pages.csv`. Fill in the physical pages of the printed TOC in the `toc_pages` column (for example `5-7`) to also try `mulu auto` on that book; leave it empty to skip.
- Your books are only read: never modified, copied or uploaded. Each book's output goes to a temporary directory and is deleted after checking. Reports go to `tools/gate/reports/`; the CSV and reports are not tracked by git.
- PASS on the last line means at most 2 books failed (refused, broken or errored). A single BROKEN book (output written but read back wrong) must be investigated.

Details (in Chinese): [tools/gate/README.md](tools/gate/README.md).

## Roadmap

- Now: tested on 17 public-domain scans; next is support for old-style English TOCs (run-in synopses, lesson ranges), per-section page offsets, and validation on modern Chinese textbooks.
- Next: a Mac GUI.

## License

MIT, see [LICENSE](LICENSE).

Mulu is not affiliated with PDFPatcher, pdfdir or Apple. Preview, PDFKit and Vision are Apple technologies.
