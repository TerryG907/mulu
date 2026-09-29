"""
Realistic 3-level TOC templates (mixed Chinese / English) for mulu fixtures,
plus helpers that spread them over a page range and write the sidecars
defined by the EXPECTED SIDECAR contract.
"""
from __future__ import annotations

import json
from pathlib import Path

# (level, title). Levels only ever increase by 1 relative to the previous line.
THESIS = [
    (0, "摘要 Abstract"),
    (0, "第一章 绪论"),
    (1, "1.1 研究背景"),
    (2, "1.1.1 国内研究现状"),
    (2, "1.1.2 International Research Status"),
    (1, "1.2 研究意义与目标 Research Objectives"),
    (1, "1.3 论文结构"),
    (0, "第二章 文献综述 Literature Review"),
    (1, "2.1 理论基础"),
    (2, "2.1.1 Transformer 架构"),
    (2, "2.1.2 注意力机制 (Attention)"),
    (1, "2.2 Related Work: 95% CI [1.2, 3.4]"),
    (0, "Chapter 3 Methodology 研究方法"),
    (1, "3.1 数据采集 Data Collection"),
    (2, "3.1.1 问卷设计 & 抽样"),
    (2, '3.1.2 "Quoted" (paren) \\ backslash'),
    (1, "3.2 模型构建"),
    (0, "第四章 实验结果与分析"),
    (1, "4.1 Experimental Setup 实验设置"),
    (1, "4.2 结果 Results 2024"),          # title ends in a number: page is the LAST token
    (2, "4.2.1 Ünïcödé — café naïve"),
    (2, "4.2.2 数学符号 α≤β, ∑x²"),
    (1, "4.3 消融实验 Ablation"),
    (0, "第五章 结论与展望"),
    (1, "5.1 主要结论"),
    (1, "5.2 Limitations & Future Work"),
    (0, "参考文献 References"),
    (0, "Appendix A 数据表 (Data Tables)"),
    (1, "A.1 原始数据 Raw Data"),
    (0, "附录 B：问卷原文 🔖"),             # non-BMP code point -> UTF-16 surrogate pair
    (0, "致谢 Acknowledgements"),
]

BOOK = [
    (0, "前言 Preface"),
    (0, "Part I 基础 Foundations"),
    (1, "Chapter 1 引言 Introduction"),
    (2, "1.1 What Is a PDF?"),
    (2, "1.2 文件结构概览"),
    (1, "Chapter 2 对象与语法 Objects"),
    (2, "2.1 Names, Strings & Numbers"),
    (2, "2.2 字典与数组"),
    (2, "2.3 Streams / 流对象"),
    (1, "Chapter 3 交叉引用表"),
    (2, "3.1 Classic xref Tables"),
    (2, "3.2 Cross-Reference Streams"),
    (2, "3.3 增量更新 Incremental Updates"),
    (0, "Part II 文档结构 Document Structure"),
    (1, "Chapter 4 页面树 The Page Tree"),
    (2, "4.1 继承属性 Inheritable Attributes"),
    (2, "4.2 Page Labels 页码标签"),
    (1, "Chapter 5 书签与大纲 Outlines"),
    (2, "5.1 Outline Items"),
    (2, "5.2 目标 Destinations"),
    (2, "5.3 Actions 动作"),
    (1, "Chapter 6 字体 Fonts"),
    (2, "6.1 CID 字体与 CMap"),
    (2, "6.2 Type 1 & TrueType"),
    (0, "Part III 实践 Practice"),
    (1, "Chapter 7 扫描件处理 Scanned Books"),
    (2, "7.1 CCITT Group 4"),
    (2, "7.2 JPEG / DCT"),
    (1, "Chapter 8 性能 Performance"),
    (2, "8.1 大文件 500+ Pages"),
    (2, "8.2 内存映射 mmap"),
    (1, "Chapter 9 兼容性测试 Compatibility"),
    (2, "9.1 Preview.app & PDFKit"),
    (2, "9.2 Acrobat / pdf.js / PDFium"),
    (0, "Appendix A 术语表 Glossary"),
    (0, "Appendix B ISO 32000 对照 Reference"),
    (1, "B.1 §7.5.6 Incremental Updates"),
    (1, "B.2 §12.3.3 Document Outline"),
    (0, "索引 Index"),
    (0, "后记 Afterword"),
]

MANUAL = [
    (0, "快速入门 Getting Started"),
    (1, "安装 Installation"),
    (1, "First Launch 首次启动"),
    (0, "基本操作 Basics"),
    (1, "打开文件 Opening Files"),
    (1, "编辑目录 Editing the TOC"),
    (2, "缩进与层级 Indentation"),
    (2, "页码偏移 Page Offset"),
    (1, "保存 Saving (增量写入)"),
    (0, "高级功能 Advanced"),
    (1, "批量处理 Batch Mode"),
    (1, "命令行 CLI: mulu apply"),
    (2, "--offset N"),
    (2, "退出码 Exit Codes"),
    (0, "常见问题 FAQ"),
    (1, "为什么文件没有变大？"),
    (1, "Why Is My Scan Unchanged?"),
    (1, "加密文件 Encrypted PDFs"),
    (0, "附录 Appendix"),
    (1, "快捷键 Keyboard Shortcuts"),
    (1, "版本历史 Changelog v0.1"),
    (0, "联系我们 Contact"),
]

TEMPLATES = {"thesis": THESIS, "book": BOOK, "manual": MANUAL}


def check_levels(entries):
    prev = -1
    for lvl, _ in entries:
        assert lvl <= prev + 1, f"level jump in template at {_}"
        prev = lvl


for _t in TEMPLATES.values():
    check_levels(_t)


def spread(template, printed_pages: int):
    """Assign monotonic non-decreasing printed page numbers in [1, printed_pages]."""
    n = len(template)
    out = []
    for i, (lvl, title) in enumerate(template):
        page = 1 if printed_pages <= 1 or n <= 1 else 1 + (i * (printed_pages - 1)) // (n - 1)
        out.append((lvl, title, page))
    return out


def toc_text(entries, *, indent="tab", sep=" ", eol="\n", bom=False, comments=True, header=None, trail="") -> bytes:
    lines = []
    if comments:
        lines.append(f"# {header or 'mulu fixture TOC'}")
        lines.append("# <indent><title><whitespace><page>; level = leading TABs or spaces/2")
    prev_lvl = None
    for lvl, title, page in entries:
        if comments and lvl == 0 and prev_lvl is not None:
            lines.append("")  # blank line between top-level entries is legal
        ind = "\t" * lvl if indent == "tab" else "  " * lvl
        lines.append(f"{ind}{title}{sep}{page}{trail}")
        prev_lvl = lvl
    text = eol.join(lines) + eol
    data = text.encode("utf-8")
    if bom:
        data = b"\xef\xbb\xbf" + data
    return data


def expected_json(entries, offset: int):
    return [{"title": t, "level": l, "page_index": p + offset - 1} for l, t, p in entries]


def write_sidecars(outdir: Path, name: str, entries, *, offset=0, style=None, refuse=False,
                   suffix="", header=None):
    """suffix='' writes <name>.toc.txt / <name>.expected.json; suffix='.reapply' the re-apply pair."""
    style = style or {}
    (outdir / f"{name}{suffix}.toc.txt").write_bytes(toc_text(entries, header=header or name, **style))
    exp = [] if refuse else expected_json(entries, offset)
    (outdir / f"{name}{suffix}.expected.json").write_text(json.dumps(exp, ensure_ascii=False, indent=1) + "\n",
                                                           encoding="utf-8")
    if not suffix:
        off = outdir / f"{name}.offset"
        if offset:
            off.write_text(f"{offset}\n")
        elif off.exists():
            off.unlink()
        ex = outdir / f"{name}.expect"
        if refuse:
            ex.write_text("refuse\n")
        elif ex.exists():
            ex.unlink()
