# Mulu 闸门周 spike：结果（加固后）

**结论**：增量写入器全部通过：生成样例 31/31 行，回归样例 47/47 行（43 个样例加 4 行重做检查；in==out 的 3 行在生成样例表里）。五个独立阅读器（PDFKit、qpdf、PDFium、pypdf、pdf.js）加 mulu 自己的读取结果，都与期望目录一致（个别回归样例中 PDFKit 连输入都打不开，记为 n/a，见下文）。对抗评审提出了 22 条问题（6 条 major，全部已修复）：20 条在 mulu 里修复，1 条是验证脚本自身的误报（已修验证脚本），1 条（HI-15）按契约保留原行为。每条都有回归样例。`swift test` 的 69 个测试里有 1 个只在设置 MULU_DUMP_FIXTURES 时才执行断言，实际做断言的是 68 个。`swift test` 69/69 通过（这是写入器阶段的数字；加上扫描书流水线后现在共 185 个测试，见 [WEEK1.md](WEEK1.md)）；`tools/run_all.sh --regen` 退出码为 0。

复现命令（一条）：`tools/run_all.sh --regen`。它会构建、重新生成样例、apply 并验证，再跑回归套件，只有全部通过才返回 0。

## 写入器支持什么

- **只追加，不改原文件**：输出等于原文件的全部字节，后面接一段增量更新（ISO 32000-1 §7.5.6）。原文件不以 EOL 结尾时，先补一个 `\n`。拒绝时退出码为 2，stderr 只有一行，并且不生成输出文件。
- **交叉引用**：支持经典表、xref 流（/W、/Index、PNG 预测器的 5 种过滤类型、TIFF Predictor 2）、/Prev 链、混合文件（/XRefStm）、对象流（含 /Extends），以及间接 /Length。支持的过滤器有 Flate（先校验 zlib 头再去掉）、**LZW**、RunLength、ASCIIHex 和 ASCII85（本轮新增 LZW 和 RunLength）。能容忍 CRLF、只有 CR 的换行和 %%EOF 前后的垃圾。startxref 错误时，只有扫描结果无歧义才重建 xref，否则拒绝。
- **%PDF- 之前有垃圾字节（本轮重做）**：只有当 startxref**精确**落在 `xref` 或 `N G obj` 上时，才认定对应的坐标系。偏移要么绝对，要么相对文件头；不再因为词法器会跳过空白，就把相差 1 到 2 字节的偏移误判为可用。追加段一律沿用原文件的坐标系，/Prev、xref 行和 startxref 不混用。在相对文件头的文件里，每个新对象和 xref 前面至少留 h 个空白字节，这样按绝对偏移读取的 pypdf 落在空白上也能读到。如果原对象前没有足够空白、目录也不在对象流里，就在 xref 流前加一行注释，引导 pypdf 走它自己的扫描重建（新定义胜出）。重建路径写出的完整表同样使用相对文件头的坐标系。
- **输出**：新 /Outlines、每个条目一个字典（全部展开；/Count 等于后代数）、同号同代的新目录修订（/Outlines 加 /PageMode /UseOutlines）。标题一律用 `<FEFF…>` UTF-16BE 十六进制串。原文件最新段是 xref 流时写未压缩 xref 流，否则写经典表：每条 20 字节，首个子节为 `0 1`。
- **追加的 trailer 保留上一版 trailer 的全部条目**（§7.5.6），例如私有键；只替换 /Size、/Prev、/Root，xref 流则去掉描述流本身的键。
- **新对象编号**：同时大于声明的 /Size、xref 中实际存在的对象号，以及文件里任何对象引用过的号码（§7.3.10：悬空引用仍然等于 null）。孤立的巨大空闲条目不再阻止写入。
- **页树**：以下情况各阅读器会给出不同的页码，mulu 一律拒绝并给出具体原因，不做修补：环、同一节点出现两次、同一页出现两次、缺失的 kid、直接对象 kid、/Count 与实际页数不符。
- **修补过的 xref 会重新发布**：mulu 靠扫描找到的对象（偏移指向 EOF 之外等），以及"1 N 表首是 0 号空闲条目"这种错号表，会把修正后的行写进新段，让所有阅读器解析到同一个对象。
- **防御**：解析深度限制为 64 层（针对对象流套 /DecodeParms 的链），嵌套超过 256 层的容器跳过、读作 null。页面字典只被引用，照常处理；目录或 trailer 需要重写，因此拒绝。单个流解码上限 64 MiB，整个文件合计 512 MiB。所有偏移运算都不会溢出。offset 为 0 的在用条目读作 null。
- **自检**：写完后用 MuluCore 重新解析输出，要求坐标系与输入相同、startxref 精确落点、目录逐项一致、页数不变，并且解析时不需要任何扫描修补，否则不产出文件。
- **`mulu info`**：目录或页树读不了时退出码为 2，与 apply 一致；加密文件照常报告。
- **TOC 解析**：全角空格（U+3000）算一级缩进，与两个 ASCII 空格相同。其他前导 Unicode 空白（如 NBSP）直接拒绝，错误信息给出行号和码位，不会静默压平层级。
- **性能**：big_500p（500 页）的 CLI 端到端时间：最短 7.4 ms，中位数 7.7 ms（30 次）。

## 最终结果表（`tools/run_all.sh --regen`）

生成样例（Fixtures/generated），31/31：

```
fixture                  exit    prefix   +bytes  spec pdfkit  qpdf pdfium pypdf pdfjs  self check pages struct  info     ms  result
------------------------------------------------------------------------------------------------------------------------------------
text_classic_cjk            0        ok    6,908    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      8  PASS
text_classic_cjk ↻          0        ok    4,819    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      6  PASS
text_objstm                 0        ok    6,432    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      6  PASS
text_objstm ↻               0        ok    4,492    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      6  PASS
text_linearized             0        ok    6,912    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      5  PASS
scan_g4                     0        ok    6,973    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      6  PASS
scan_g4 ↻                   0        ok    4,761    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      6  PASS
scan_jpeg                   0        ok    4,738    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      7  PASS
scan_g4_objstm              0        ok    6,595    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      6  PASS
existing_outline            0        ok    6,922    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      5  PASS
quartz_made                 0        ok    4,785    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
encrypted                   2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      3  PASS
multirev                    0        ok    6,928    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
big_500p                    0        ok    9,529    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      8  PASS
cups_made                   0        ok    4,733    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sips_made                   0        ok    4,716    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
xref_png_filters            0        ok    6,432    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
hybrid_xref                 0        ok    6,913    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
toc_quirks                  0        ok    6,908    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
nested_pagetree             0        ok    7,228    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
eof_crlf                    0        ok    6,908    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
eof_cr                      0        ok    6,908    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
eof_no_eol                  0        ok    6,909    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      5  PASS
eof_garbage                 0        ok    6,909    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      5  PASS
refuse_page_range           2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
refuse_zero_pages           2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
refuse_no_root              2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
refuse_not_pdf              2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      6  PASS
in==out: same path          2 in-intact        -     -      -     -      -     -     -     -     -     -      -     -      3  PASS
in==out: alt spelling       2 in-intact        -     -      -     -      -     -     -     -     -     -      -     -      3  PASS
in==out: symlink out        2 in-intact        -     -      -     -      -     -     -     -     -     -      -     -      3  PASS
------------------------------------------------------------------------------------------------------------------------------------
```

PDFKit 整体重存和 mulu 增量更新的体积对比：

```
fixture                   input  PDFKit resave   growth  resave s  mulu +bytes mulu growth
------------------------------------------------------------------------------------------
scan_g4               1,987,616      4,267,663  +114.7%      0.25        6,973      +0.35%
scan_jpeg             5,138,325      5,144,231    +0.1%      0.07        4,738      +0.09%
text_classic_cjk         49,336        106,202  +115.3%      0.05        6,908     +14.00%
```

回归样例（Fixtures/regression，每条对抗发现对应一个复现样例），47/47：

```
fixture                          exit    prefix   +bytes  spec pdfkit  qpdf pdfium pypdf pdfjs  self check pages struct  info     ms  result
--------------------------------------------------------------------------------------------------------------------------------------------
sr3_text_objstm_lfprefix            0        ok    6,432    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      6  PASS
sr3_quartz_made_lfprefix            0        ok    4,785    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      5  PASS
sr_junk1_rel_stream                 0        ok      781    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr_junk1_rel_classic                0        ok      812    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr_junk2_rel_crlf                   0        ok      817    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr_junk8_rel_classic                0        ok      854    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr3_text_objstm_crlfprefix          0        ok    6,466    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr2_recon_junk8                     0        ok    1,000    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr_trailer_private_keys             0        ok      933    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr_trailer_private_keys_stream      0        ok      813    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr_dangling_ref                     0        ok      812    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
sr_dangling_resources               0        ok      812    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_int64max_offset_junkprefix        0        ok    1,646    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_deep_decodeparms_chain            2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      8  PASS
h_pagetree_cycle                    2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
h_pagetree_selfkid                  2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
h_junk_prefix_rel1                  0        ok    1,579    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_junk_prefix_rel1 ↻                0        ok    1,663    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_junk_prefix_rel2_blanklines       0        ok    1,589    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h3_i64max_prev_junk                 0        ok    1,777    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h2_count_mismatch                   2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
h_pagetree_missingkid               2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
h_pagetree_dupleaf                  2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
h_offset0_shadow                    2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      3  PASS
h2_page_offset_beyond_eof           0        ok    1,603    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_xref_first_subsection_1           0        ok    1,815   n/a     ok    ok     ok    ok    ok    ok    ok    ok    n/a    ok      4  PASS
h2_page_nest300                     0        ok    1,579    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h2_page_nest300 ↻                   0        ok    1,663    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      5  PASS
h2_catalog_nest100k                 2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
h2_classic_objnum_9e9               0        ok    1,579    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h2_xrefstm_objnum_5e12              0        ok    1,484    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h2_direct_page_kid_ok               2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
h2_direct_page_kid_target           2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      3  PASS
h_hybrid_free                       2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      3  PASS
h_objstm_lzw                        0        ok    1,484    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h2_objstm_256mb_padding             2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok     19  PASS
h2_objstm_first_negative            2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      4  PASS
h2_root_direct_dict                 2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      3  PASS
h_mixed_stream_then_classic         0        ok    1,579    ok   n/a*    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_mixed_stream_then_classic ↻       0        ok    1,663    ok   n/a*    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_toc_weird_codepoints              0        ok    1,215    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_catalog_dupkeys_emptyname         0        ok    1,652    ok   n/a*    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h2_xrefstm_length_huge              0        ok    1,484    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_catalog_exotic                    0        ok    2,095    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
h_catalog_exotic ↻                  0        ok    2,179    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
toc_fullwidth_indent                0        ok    1,546    ok     ok    ok     ok    ok    ok    ok    ok    ok     ok    ok      4  PASS
toc_nbsp_indent                     2    no-out        -     -      -     -      -     -     -     -     -     -      -    ok      3  PASS
--------------------------------------------------------------------------------------------------------------------------------------------
```

以下几行被接受为 `n/a` 或"允许变化"，原因都在运行时做过核实：

- h2_page_offset_beyond_eof：PDFKit 读输入时末页就读错了（输入的 xref 偏移超出 EOF）。输出修好了，与 PDFium 对输入的读法一致。
- h_xref_first_subsection_1：qpdf 连输入都打不开，因此 spec 和 struct 两列没有基线（记为 n/a）。qpdf 能干净地打开输出，五个阅读器的目录都正确。
- h_mixed_stream_then_classic（含重做）和 h_catalog_dupkeys_emptyname：PDFKit 打不开输入（已核实）。其余四个阅读器都通过。

## 回归清单（Fixtures/regression，43 个样例，3.9 MB）

manifest.json 为每个样例记录 finding、来源和选项。样例由 `tools/fixtures/make_regression.py` 从 tools/adversarial 复制并补齐 sidecar，这个目录不会被重新生成。

| 发现 | 严重度 | 样例 | 修法 |
|---|---|---|---|
| SR-1 %PDF- 前有 1–2 字节时坐标系选错且混用 | major | sr3_text_objstm_lfprefix, sr3_quartz_made_lfprefix, sr_junk1_rel_stream, sr_junk1_rel_classic, sr_junk2_rel_crlf, sr_junk8_rel_classic（对照） | 按精确落点判定坐标系，追加段沿用原坐标系并留空白 |
| SR-2 前缀让 pypdf 丢失整个目录 | major | sr3_text_objstm_crlfprefix | 同上，加上对 pypdf 路径的引导 |
| SR-3 重建路径忽略 headerOffset | minor | sr2_recon_junk8 | 重建时使用相对文件头的坐标系 |
| SR-4 追加的 trailer 丢了原有条目 | minor | sr_trailer_private_keys, sr_trailer_private_keys_stream | 按 §7.5.6 复制所有条目 |
| SR-5 新编号"劫持"悬空引用 | minor | sr_dangling_ref, sr_dangling_resources | 新编号高于所有被引用的号码 |
| HI-1 Int64.max 偏移导致溢出崩溃 | major | h_int64max_offset_junkprefix | 越界偏移不参与运算 |
| HI-2 /DecodeParms 链导致栈溢出 | major | h_deep_decodeparms_chain（3 MB） | 解析深度 64 层后拒绝 |
| HI-3 页树有环时静默跳过 | major | h_pagetree_cycle, h_pagetree_selfkid | 拒绝 |
| HI-4 1–2 字节垃圾前缀 | major | h_junk_prefix_rel1（含重做）, h_junk_prefix_rel2_blanklines, h3_i64max_prev_junk | 同 SR-1、SR-3 |
| HI-5 /Count 与 kids 数量不符 | minor | h2_count_mismatch | 拒绝 |
| HI-6 悬空 /Kids 项 | minor | h_pagetree_missingkid（另加 h_pagetree_dupleaf：同一页出现两次） | 拒绝 |
| HI-7 offset 为 0 的条目遮住旧定义 | minor | h_offset0_shadow | 读作 null，页树因此拒绝 |
| HI-8 内部修补的 xref 没有重新发布 | minor | h2_page_offset_beyond_eof, h_xref_first_subsection_1 | 重新发布修正后的行 |
| HI-9 嵌套超过 256 层被误拒，报错指向 xref | minor | h2_page_nest300（含重做）, h2_catalog_nest100k | 页面照常处理；目录拒绝并说明嵌套层数 |
| HI-10 巨大号码的空闲条目阻塞写入 | minor | h2_classic_objnum_9e9, h2_xrefstm_objnum_5e12 | 编号时忽略空闲条目 |
| HI-11 直接对象页 kid | minor | h2_direct_page_kid_ok, h2_direct_page_kid_target | 一律拒绝 |
| HI-12 拒绝信息误导（混合表、LZW） | minor | h_hybrid_free, h_objstm_lzw | 报错点明混合表冲突；实现 LZW |
| HI-13 解压无上限（884 MB） | minor | h2_objstm_256mb_padding（限 200 MB） | 64 MiB 上限加分块解压，峰值 **92 MB** |
| HI-14 info 在 apply 拒绝的文件上返回 0 | minor | h2_objstm_first_negative, h2_root_direct_dict | info 同样退出 2 |
| HI-15 经典段叠在 xref 流上，PDFKit 首项为 -1 | minor（信息性） | h_mixed_stream_then_classic（含重做） | 保持契约写经典表。实测改写 xref 流后 PDFKit 更差（6/7 项变成 -1）；PDFKit 连输入都打不开 |
| HI-16 验证脚本误报 | minor | h_toc_weird_codepoints, h_catalog_dupkeys_emptyname, h2_xrefstm_length_huge, h_catalog_exotic | 只按 `\n` 分行；qpdf 警告去掉"对象号+偏移"里的偏移；标量与实数规范化；忽略 qpdf 伪造的 /QPDFFake 键 |
| PM-1 全角空格缩进被静默压平 | minor | toc_fullwidth_indent, toc_nbsp_indent | U+3000 算一级缩进，其他前导空白拒绝 |

验证脚本本轮加严的地方：spec 列按原文件坐标系校验偏移，要求最终 startxref 精确落点。同时检查 §7.5.6 规定的 trailer 条目，以及新对象号不得占用输入里已被引用的号码。回归样例支持断言拒绝信息（`expect_stderr`）、`mulu info` 必须失败（`expect_info`）和 RSS 上限。只对"该阅读器连输入都读不了"的情况豁免，而且会在运行时核实，核实不成立就算失败。harness 自检（参考写入器加 11 个故意损坏的负对照）全部被捕获。

## 扫描书流水线（`mulu auto`：OCR 目录页 → 解析 → 页码偏移 → 增量写入）

命令：`mulu ocr-toc`、`mulu toc parse`、`mulu detect-offset`、`mulu auto`、`mulu toc convert`、`mulu export-outline`。`mulu auto book.pdf --toc-pages 5-7 -o out.pdf` 一条命令完成全程；偏移或 OCR 置信度不够时退出码 2 并说明原因，不猜（`--toc-out` 可留下草稿手改）。

13 本合成扫描书（`Fixtures/books`，`tools/run_all.sh --books`，结果在 `Fixtures/books/eval.json`）：

| 指标 | 目标 | 结果 |
|---|---|---|
| 印刷页码完全正确（ocr-toc + toc parse） | ≥ 97% | 98.7% |
| 标题 CER：正文条目（toc parse） | ≤ 3% | 2.3% |
| 标题 CER：含罗马页码的前言类条目 | ≤ 3% | 4.2%（前言类条目在没给 `--roman-offset` 时按设计只写成注释，被计为整条缺失） |
| 标题 CER：auto 写出的目录 | ≤ 3% | 0.01% |
| OCR 文本 CER | — | 2.0% |
| 层级正确（toc parse / auto） | ≥ 95% | 97.3% / 100% |
| detect-offset | 每本都对 | 13/13 正确，0 本错 |
| auto 整本完全正确 | ≥ 10/12 | 12/13；唯一例外 zh_chem_noisy 按设计拒绝（59 条中 24 条可疑） |

zh_chem_noisy 是故意做坏的扫描：细横笔整段断掉，一 字在图上已经没有了，Vision 读不出来。它的页码偏移现在能测对（13/24 页一致），但标题错太多，auto 拒绝写入。`tools/gate/run_gate.sh Fixtures/books` 试跑：13/13 PASS，auto 12 本写出、1 本拒绝。

## 实测数字（Apple M5 Pro，macOS 26.6.2，Xcode 27 / Swift 6）

- **追加字节**：text_classic_cjk 6,908（重做 4,819）；text_objstm 6,432（重做 4,492）；text_linearized 6,912；scan_g4 6,973（重做 4,761）；scan_jpeg 4,738；scan_g4_objstm 6,595；existing_outline 6,922；quartz_made 4,785；multirev 6,928；big_500p 9,529（40 条目）；cups_made 4,733；sips_made 4,716；xref_png_filters 6,432；hybrid_xref 6,913；toc_quirks 6,908；nested_pagetree 7,228；eof_crlf 6,908；eof_cr 6,908；eof_no_eol 6,909；eof_garbage 6,909。
- **PDFKit 整体重存的体积增长**：scan_g4 **+114.7%**（1,987,616 → 4,267,663），scan_jpeg **+0.1%**（5,138,325 → 5,144,231），text_classic_cjk **+115.3%**（49,336 → 106,202）。mulu 对同样三个文件分别只增加 +0.35%、+0.09%、+14.00%（后者是 49 KB 的小文件加 31 个条目）。
- **big_500p apply 时间**：CLI 端到端最短 **7.4 ms**，中位数 7.7 ms（30 次，含进程启动），harness 计时 7–8 ms，门槛是 1,000 ms。producer 矩阵的大文件中，最慢的是 big_chrome_500（27,722 个对象，67 ms，RSS 51 MB）。新增的"全对象引用扫描"每个对象约 2 µs。
- **解压炸弹**（h2_objstm_256mb_padding，262 KB 输入）：峰值 RSS 从 884 MB 降到 **92 MB**，以明确信息拒绝。
- **复跑对抗套件**：producer 矩阵 68/68（另有 2 个样例跳过：本机 cupsfilter 没有 HTML 转 PDF 的过滤器，cups_html 和 textutil_cups 无法生成）；大文件 12/12（500–3000 页，最慢 67 ms）；混合更新链 32/32。hostile 与 spec-review 全量重跑后，此前通过的行没有变差；唯一变化是 h2_direct_page_kid_target 的 info 列，现在按设计退出 2。注意：这是和当时存下的基线对比；hostile 与 spec-review 的原始脚本直接重跑时并非全绿（hostile 70/95、19/40、4/6；spec-review 18/19、0/4、3/3），差异主要来自 mulu 现在按设计拒绝的坏文件和攻击者脚本自带的旧预期，不代表输出损坏。

## 剩余限制

- **JBIG2 未测**：本机没有 JBIG2 编码器。好在 mulu 从不解码页面内容流，只引用页对象，风险低，但还没有实测。
- **真实扫描书还待验证**：所有样例都是本机生成的，要等用户拿自己的书来验证（尤其是扫描仪固件和国产 PDF 工具的输出）。
- **%PDF- 前有垃圾时的 pypdf**：pypdf 把偏移当绝对值读，与其他四个阅读器相反。目录和页码都正确，但可能出现"incorrect startxref pointer"或"Ignoring wrong pointing object"之类警告。验证脚本只对有前缀的文件、只对 pypdf 这两类警告做了规范化。
- **页树异常一律拒绝**：环、重复、缺页、直接 kid、/Count 不符都会拒绝。这类文件本来就在不同阅读器里页码不一致，但确实会拒掉少数"看起来能打开"的坏文件（有明确报错）。
- 经典段叠在 xref 流上的文件（非混合）：PDFKit 连输入都打不开，mulu 按契约写经典表，其余四个阅读器正确。
- 以下情况会拒绝：对象流或 xref 流解码超过 64 MiB、解析嵌套超过 64 层、目录或 trailer 嵌套超过 256 层、加密文件、/Size 超过 8,388,607（Annex C 上限）。
- 标题的显示差异来自阅读器本身，不影响页码：PDFium 把标题里的 TAB 显示成空格，并丢弃 U+0000。
- Ghostscript 和 LibreOffice 未安装，未测。为了不在用户面前弹窗，也没有打开 Preview.app 实测。
