"""
cases.py -- the messy printed-TOC cases for tools/adversarial/week1-messy.

Each case is a list of printed TOC lines plus book options. Line kinds:
  E  a real TOC entry (truth: title, level, printed page)
  H  the TOC page's own heading ("目录", "Contents", "目录（续）") -- may be skipped silently
  J  junk that is NOT an entry (footnote, index line, column header, list-of-figures line):
     it must not turn into an unflagged outline entry
  PB TOC page break, CB column break (two-column pages)

All text is written here; nothing is downloaded or read from the user's files.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class L:
    kind: str                      # E H J PB CB
    text: str = ""                 # title as printed (E), text (H/J)
    page: str = ""                 # printed page text as printed ("12", "12-15", "iii", "")
    level: int = 0                 # truth level (E)
    ind: float | None = None       # visual indent in level units (1 unit = 2 em); default = level
    style: str | None = None       # leader | noleader | glued | space | numleft | ragged (default from case)
    lead: str | None = None        # leader glyph unit (default from case)
    wrap: list[str] | None = None  # visual lines of a wrapped title (joined = text)
    tpage: int | str | None = "auto"  # truth printed page value; "auto" = parsed from page; None = no page
    front: bool = False            # page is in the front-matter scheme (roman, or arabic-restart)
    title: str | None = None       # truth title if it differs from text (e.g. markers)
    note: str = ""


def E(level, text, page="", **kw):
    return L("E", text=text, page=str(page), level=level, **kw)


def H(text, **kw):
    return L("H", text=text, **kw)


def J(text, page="", **kw):
    return L("J", text=text, page=str(page), **kw)


PB = L("PB")
CB = L("CB")


@dataclass
class Case:
    name: str
    features: list[str]
    lines: list[L]
    lang: str = "zh"               # zh | en
    font: str = "song"             # song | hei | times | arial
    size_pt: float = 10.5
    spacing: float = 1.9           # line pitch / font size
    style: str = "leader"
    lead: str = "…"
    columns: int = 1
    profile: str = "scan"          # scan | faint | clean
    toc_skew: float | None = None  # fixed skew for TOC pages (deg); None = small random
    folio: str = "footer-center"   # footer-center | footer-outer | header-outer
    running_header: str | None = None  # None | "chapter" | "numbers"
    preface_pages: int = 2
    front_arabic: bool = False     # front matter folios are arabic 1.. (restart in body)
    plates: tuple[int, int] | None = None  # (after printed page p, n unnumbered plate pages)
    opener_no_folio: bool = False
    extra_body: int = 4            # body pages after the last TOC page number
    body_pages: int | None = None  # force last printed body page (partial scans)
    expect: str = "ok"             # ok | refuse (the whole TOC is not a TOC)
    toc_at_back: bool = False      # TOC printed at the end of the book (French/Japanese style)
    continuous: bool = False       # one arabic sequence from the first page: physical == printed
    raw_folios: bool = False       # raw transcription keeps each TOC page's own folio line
    raw_only: bool = False         # no scanned PDF (text-level case)
    raw_override: list[str] | None = None  # raw lines differ from the print (OCR-confusion case)
    notes: str = ""


C: list[Case] = []

# ---------------------------------------------------------------------------
C.append(Case("c01_simp_trad_mixed", ["繁体关键字 目錄/參考文獻/附錄/後記", "简繁混排"], [
    H("目　錄"),
    E(0, "序言", "i", front=True),
    E(0, "第一章 緒論", 1),
    E(1, "第一節 研究背景與問題", 2),
    E(1, "第二節 文獻回顧", 5),
    E(0, "第二章 經濟與社會變遷", 9),
    E(1, "第一節 臺灣的工業化", 10),
    E(1, "第二節 两岸贸易往来", 14),
    E(2, "一、進出口結構", 15),
    E(2, "二、投资与金融", 17),
    E(0, "第三章 歷史與記憶", 21),
    E(1, "第一節 國家敘事", 22),
    E(1, "第二節 個人記憶與口述歷史", 26),
    E(0, "第四章 結論", 31),
    E(0, "參考文獻", 35),
    E(0, "附錄A 訪談大綱", 39),
    E(0, "附錄B 统计资料", 41),
    E(0, "後記", 44),
]))

C.append(Case("c02_zh_en_mixed", ["中英混排", "Chapter 3 inside a 第N章 book", "titles with 2.0 / GPT-4 / HTTP/2"], [
    H("目录"),
    E(0, "第1章 Python 入门", 1),
    E(1, "1.1 What is Python?", 2),
    E(1, "1.2 安装 Anaconda 与 Jupyter", 4),
    E(1, "1.3 Hello, World! 第一个程序", 7),
    E(0, "第2章 数据结构 Data Structures", 10),
    E(1, "2.1 List 与 Tuple", 11),
    E(1, "2.2 dict、set 与 hash", 14),
    E(1, "2.3 NumPy 数组 ndarray", 18),
    E(0, "Chapter 3 Web 开发", 22),
    E(1, "3.1 HTTP/2 协议", 23),
    E(1, "3.2 REST API 设计", 27),
    E(1, "3.3 使用 Flask 2.0 构建服务", 31),
    E(0, "第4章 机器学习 ML", 35),
    E(1, "4.1 scikit-learn 快速上手", 36),
    E(1, "4.2 GPT-4 与大语言模型", 40),
    E(0, "Appendix A 常用命令", 45),
    E(0, "附录B Git 速查表", 48),
    E(0, "Index 索引", 52),
]))

C.append(Case("c03_skip_levels", ["numbering skips levels (1.1.1 right under 第一章)", "（一） under a chapter", "1. under 第一节 then 一、"], [
    H("目录"),
    E(0, "第一章 总论", 1),
    E(1, "1.1.1 基本概念", 2, ind=2),
    E(1, "1.1.2 基本原理", 4, ind=2),
    E(1, "1.2 研究方法", 6, ind=1),
    E(0, "第二章 市场", 9),
    E(1, "（一）供给", 10, ind=2),
    E(1, "（二）需求", 12, ind=2),
    E(2, "1. 价格弹性", 13, ind=3),
    E(2, "2. 收入弹性", 15, ind=3),
    E(0, "第三章 政府", 18),
    E(1, "第一节 财政", 19),
    E(2, "1. 税收", 20, ind=3),
    E(2, "2. 支出", 22, ind=3),
    E(2, "一、预算", 24, ind=2),
    E(1, "第二节 货币", 27),
    E(0, "第四章 结论", 30),
]))

C.append(Case("c04_numbers_in_titles", ["titles that start/end with numbers: 2020年 1.5倍速 3D 5G 100个 1949年"], [
    H("目录"),
    E(0, "第一章 2020年经济形势", 1),
    E(1, "一、2019年回顾", 2),
    E(1, "二、2020年展望", 5),
    E(1, "三、1.5倍速增长的可能", 8),
    E(0, "第二章 第3版说明", 11),
    E(1, "1.5倍速播放与学习效率", 12),
    E(1, "3D打印技术", 15),
    E(1, "5G网络与物联网", 18),
    E(0, "第三章 二十世纪的中国", 21),
    E(1, "一带一路倡议", 23),
    E(1, "100个问题", 26),
    E(1, "12生肖与民俗", 29),
    E(0, "第四章 展望2030", 33),
    E(1, "1949年以后的城市", 35),
    E(1, "G20峰会", 38),
    E(0, "第3版后记", 41),
]))

C.append(Case("c05_glued_pages", ["page glued to title, no leader, no space", "titles ending in digits (G20, iPhone 15, Windows 10)"], [
    H("目录"),
    E(0, "第一章 绪论", 1, style="glued"),
    E(1, "1.1 研究背景", 3, style="glued"),
    E(1, "1.2 G20峰会", 7, style="glued"),
    E(1, "1.3 iPhone 15", 12, style="glued", note="prints 'iPhone 1512'"),
    E(0, "第二章 方法论", 18, style="glued"),
    E(1, "2.1 问卷设计", 20, style="glued"),
    E(1, "2.2 第3版量表", 23, style="glued"),
    E(1, "2.3 Windows 10", 27, style="glued", note="prints 'Windows 1027'"),
    E(0, "第三章 结果", 31, style="glued"),
    E(1, "3.1 描述统计", 33, style="space"),
    E(1, "3.2 回归分析", 36, style="space"),
    E(0, "第四章 讨论", 40, style="glued"),
    E(0, "参考文献", 45, style="glued"),
], style="glued"))

C.append(Case("c06_leader_glyphs", ["15 different leader glyphs incl. ～ － — ___ ・ ‥ ⋯ • spaced dots"], [
    H("目录"),
    E(0, "第一章 总则", 1, lead="…"),
    E(1, "第一节 目的", 2, lead="·"),
    E(1, "第二节 适用范围", 4, lead="."),
    E(1, "第三节 定义", 6, lead="—"),
    E(0, "第二章 组织", 9, lead="－"),
    E(1, "第一节 机构", 10, lead="＿"),
    E(1, "第二节 职责", 12, lead="‥"),
    E(1, "第三节 人员", 14, lead="⋯"),
    E(0, "第三章 程序", 17, lead="～"),
    E(1, "第一节 申请", 18, lead="• "),
    E(1, "第二节 审核", 20, lead=". "),
    E(1, "第三节 决定", 23, lead="-"),
    E(0, "第四章 监督", 26, lead="_"),
    E(1, "第一节 检查", 27, lead="・"),
    E(1, "第二节 责任", 29, lead="~"),
    E(0, "附则", 32, lead="=" ),
]))

C.append(Case("c07_misaligned_columns", ["page column not aligned (ragged right)", "indent jitter", "unnumbered level-1 lines"], [
    H("目录"),
    E(0, "第一章 城市与乡村", 1, style="ragged"),
    E(1, "第一节 城市的起源", 2, style="ragged", ind=0.8),
    E(1, "第二节 乡村的变迁", 6, style="ragged", ind=1.2),
    E(1, "田野笔记", 9, style="ragged", ind=0.9),
    E(0, "第二章 人口流动", 12, style="ragged", ind=0.15),
    E(1, "第一节 迁移的动力", 13, style="ragged", ind=1.1),
    E(2, "一、推力与拉力", 14, style="ragged", ind=1.9),
    E(2, "二、制度因素", 17, style="ragged", ind=2.2),
    E(1, "第二节 城市融入", 20, style="ragged", ind=0.85),
    E(1, "访谈记录", 24, style="ragged", ind=1.15),
    E(0, "第三章 结论与讨论", 27, style="ragged", ind=-0.1),
    E(0, "参考文献", 31, style="ragged"),
], style="ragged"))

C.append(Case("c08_toc_continues", ["TOC continues on next page", "wrapped title split across the page break", "目录（续） running header", "TOC page folio iii/iv printed"], [
    H("目　录"),
    E(0, "第一章 导论", 1),
    E(1, "第一节 问题的提出", 2),
    E(1, "第二节 研究框架", 5),
    E(0, "第二章 制度变迁的理论", 9),
    E(1, "第一节 新制度经济学的基本观点", 10),
    E(1, "第二节 路径依赖", 14),
    E(1, "第三节 诱致性变迁与强制性变迁", 17),
    E(0, "第三章 地方政府行为", 21),
    E(1, "第一节 财政分权", 22),
    E(1, "第二节 晋升锦标赛", 25),
    E(1, "第三节 土地财政与地方债务的形成机制及其对区域经济的影响", 29,
      wrap=["第三节 土地财政与地方债务的形成机制及其", "@PB", "@H:目录（续）", "对区域经济的影响"]),
    E(0, "第四章 实证分析", 33),
    E(1, "第一节 数据与变量", 34),
    E(1, "第二节 回归结果", 38),
    E(0, "第五章 结论", 43),
    E(0, "参考文献", 47),
    E(0, "后记", 52),
], raw_folios=True))

C.append(Case("c09_footnote_markers", ["title footnote markers * ① ¹ † [1]", "footnote lines at TOC page bottom ending in years/(2019)"], [
    H("目录"),
    E(0, "第一章 绪论*", 1, title="第一章 绪论"),
    E(1, "1.1 研究背景①", 2, title="1.1 研究背景"),
    E(1, "1.2 研究方法¹", 5, title="1.2 研究方法"),
    E(0, "第二章 理论框架†", 9, title="第二章 理论框架"),
    E(1, "2.1 数据说明[1]", 10, title="2.1 数据说明"),
    E(1, "2.2 稳健性检验**", 14, title="2.2 稳健性检验"),
    E(0, "第三章 实证结果", 18),
    E(1, "3.1 基准回归", 19),
    E(1, "3.2 异质性分析", 23),
    E(0, "第四章 结论", 27),
    E(0, "参考文献", 30),
    J("* 带星号的章节为选读内容，初次阅读可跳过。", style="foot"),
    J("① 本节数据来源：国家统计局，2023", style="foot"),
    J("† 本章部分内容曾发表于《经济研究》(2019)", style="foot"),
]))

C.append(Case("c10_ocr_confusions", ["raw text with O/0 l/1 I/1 〇/0 S/5 B/8 Z/2 g/9 confusions in pages and numbering"], [
    H("目录"),
    E(0, "第1章 总论", 1),
    E(1, "1.1 背景", 3),
    E(1, "1.2 二〇二〇年规划", 5),
    E(1, "1.3 目标", 7),
    E(0, "第2章 实施", 10),
    E(1, "2.1 组织", 12),
    E(1, "2.2 保障", 15),
    E(1, "2.3 考核", 21),
    E(0, "第3章 评估", 30),
    E(1, "3.1 指标", 31),
    E(1, "3.2 方法", 35),
    E(1, "3.3 结果", 38),
    E(1, "3.4 讨论", 40),
    E(0, "第4章 结论", 42),
    E(0, "附录", 49),
    E(0, "参考文献", 50),
], raw_override=[
    "目录",
    "第l章 总论 …… l",
    "  l.1 背景 …… 3",
    "  1.2 二〇二〇年规划 …… 5",
    "  1.3 目标 …… O7",
    "第2章 实施 …… 1O",
    "  2.1 组织 …… l2",
    "  2.2 保障 …… I5",
    "  2.3 考核 …… 2l",
    "第3章 评估 …… 3〇",
    "  3.1 指标 …… 3l",
    "  3.2 方法 …… 3S",
    "  3.3 结果 …… 3B",
    "  3.4 讨论 …… 4O",
    "第4章 结论 …… 4Z",
    "附录 …… 4g",
    "参考文献 …… 5O",
]))

C.append(Case("c11_roman_in_titles", ["Part I/II lines without page", "titles ending in roman numerals (Henry VIII, John XXIII, Elizabeth II)", "wrapped title whose first line ends in XXIII"], [
    H("Contents"),
    E(0, "Preface", "ix", front=True),
    E(0, "Part I The Ancient World", "", tpage=None),
    E(1, "Chapter 1 Egypt and the Nile", 3),
    E(1, "Chapter 2 Louis XIV and Versailles", 17),
    E(1, "Chapter 3 World War I", 29),
    E(0, "Part II", "", tpage=None, note="bare 'Part II' line, no page"),
    E(1, "Chapter 4 Henry VIII", 45),
    E(1, "Chapter 5 Pope John XXIII and the Council", 61,
      wrap=["Chapter 5 Pope John XXIII", "and the Council"]),
    E(1, "Chapter 6 Elizabeth II", 77),
    E(0, "Appendix I Timeline", 95),
    E(0, "Index", 99),
], lang="en", font="times", size_pt=11))

C.append(Case("c12_page_ranges", ["page ranges 1-8 1–3 4—8 9～20 9~14 '15 - 20' 'pp. 21-27' '28 至 35'"], [
    H("目录"),
    E(0, "第一章 导论", "1-8"),
    E(1, "第一节 概念", "1–3"),
    E(1, "第二节 方法", "4—8"),
    E(0, "第二章 理论", "9～20"),
    E(1, "第一节 古典理论", "9~14"),
    E(1, "第二节 现代理论", "15 - 20", tpage=15),
    E(0, "第三章 实证", "21-35"),
    E(1, "第一节 数据", "pp. 21-27", tpage=21),
    E(1, "第二节 结果", "28 至 35", tpage=28),
    E(0, "第四章 结论", "36—40"),
    E(0, "参考文献", "41-44"),
]))

C.append(Case("c13_duplicate_titles", ["引言/本章小结/习题 repeated in every chapter", "same page for chapter and first section"], [
    H("目录"),
    E(0, "第一章 力学", 1),
    E(1, "第一节 引言", 1),
    E(1, "第二节 运动学", 3),
    E(1, "本章小结", 8),
    E(1, "习题", 9),
    E(0, "第二章 热学", 11),
    E(1, "第一节 引言", 11),
    E(1, "第二节 热力学第一定律", 13),
    E(1, "本章小结", 18),
    E(1, "习题", 19),
    E(0, "第三章 电磁学", 21),
    E(1, "第一节 引言", 21),
    E(1, "本章小结", 28),
    E(1, "习题", 29),
    E(0, "第四章 光学", 31),
    E(1, "第一节 引言", 31),
    E(1, "第二节 引言", 33),
    E(1, "本章小结", 38),
    E(1, "习题", 39),
]))


def _dense():
    out = [H("目录")]
    names = ["绪论", "基本概念", "数学基础", "线性模型", "非线性模型", "数值方法", "稳定性分析", "应用实例", "扩展讨论"]
    subn = ["定义", "性质", "定理", "证明", "例题", "推广"]
    p = 1
    for c in range(1, 10):
        out.append(E(0, f"第{c}章 {names[c-1]}", p))
        for s in range(1, 4):
            p += 1
            out.append(E(1, f"{c}.{s} {subn[(c+s) % 6]}与{subn[(c+2*s) % 6]}", p))
            for t in range(1, 3):
                p += (t % 2)
                out.append(E(2, f"{c}.{s}.{t} {subn[(c*s+t) % 6]}", p))
        p += 2
        if c == 5:
            out.append(PB)
    out.append(E(0, "参考文献", p))
    out.append(E(0, "索引", p + 3))
    return out


C.append(Case("c14_dense_8pt", ["8 pt at 300 dpi, tight line pitch, 3 levels, 60+ entries"], _dense(),
              size_pt=8, spacing=1.45))

C.append(Case("c15_faint_low_contrast", ["faint grey ink on grey paper, JPEG q55, blur"], [
    H("目录"),
    E(0, "第一章 导论", 1),
    E(1, "第一节 研究对象", 2),
    E(2, "一、基本问题", 3),
    E(2, "二、研究意义", 5),
    E(1, "第二节 研究方法", 7),
    E(0, "第二章 历史回顾", 10),
    E(1, "第一节 早期思想", 11),
    E(1, "第二节 近代发展", 15),
    E(2, "一、工业革命", 16),
    E(2, "二、三次浪潮", 19),
    E(0, "第三章 现状分析", 23),
    E(1, "第一节 一般特征", 24),
    E(1, "第二节 区域差异", 28),
    E(0, "第四章 对策建议", 33),
    E(0, "参考文献", 38),
], profile="faint"))

C.append(Case("c16_skew_2deg", ["TOC pages skewed 2.0 deg", "'Chapter  Page' column header line", "English"], [
    H("Contents"),
    J("Chapter", page="Page", style="noleader"),
    E(0, "Preface", "vii", front=True),
    E(0, "1 Introduction", 1),
    E(1, "1.1 Motivation", 2),
    E(1, "1.2 Outline of the Book", 6),
    E(0, "2 Background", 9),
    E(1, "2.1 Linear Algebra", 10),
    E(1, "2.2 Probability", 15),
    E(1, "2.3 Optimization", 21),
    E(0, "3 Methods", 27),
    E(1, "3.1 Gradient Descent", 28),
    E(1, "3.2 Newton's Method", 33),
    E(0, "4 Experiments", 39),
    E(0, "Bibliography", 47),
    E(0, "Index", 51),
], lang="en", font="times", size_pt=11, toc_skew=2.0))

C.append(Case("c17_numbers_left", ["page numbers on the LEFT, dotted leader, then title"], [
    H("目录"),
    E(0, "第一章 绪论", 1, style="numleft"),
    E(1, "第一节 研究缘起", 2, style="numleft"),
    E(1, "第二节 研究综述", 6, style="numleft"),
    E(0, "第二章 理论基础", 11, style="numleft"),
    E(1, "第一节 核心概念", 12, style="numleft"),
    E(1, "第二节 分析框架", 16, style="numleft"),
    E(0, "第三章 案例研究", 21, style="numleft"),
    E(1, "第一节 案例选择", 22, style="numleft"),
    E(1, "第二节 案例分析", 27, style="numleft"),
    E(0, "第四章 结论", 33, style="numleft"),
    E(0, "参考文献", 37, style="numleft"),
], style="numleft"))

C.append(Case("c18_index_not_toc", ["the given 'TOC' page is an index (索引) with multi-page refs"], [
    H("索　引"),
    J("A", ind=0),
    J("阿基米德原理 23, 45", style="space"),
    J("安培定律 67", style="space"),
    J("B", ind=0),
    J("伯努利方程 12–14, 88", style="space"),
    J("比热容 31", style="space"),
    J("边际效用 56", style="space"),
    J("C", ind=0),
    J("长度收缩 72, 73", style="space"),
    J("磁通量 80", style="space"),
    J("超导体 81, 84–86", style="space"),
    J("D", ind=0),
    J("电磁感应 60", style="space"),
    J("动量守恒 18, 22", style="space"),
    J("多普勒效应 41", style="space"),
    J("F", ind=0),
    J("法拉第定律 62", style="space"),
    J("浮力 25", style="space"),
    J("G", ind=0),
    J("光电效应 77, 79", style="space"),
    J("惯性系 70", style="space"),
], expect="refuse"))

C.append(Case("c19_list_of_figures_follows", ["TOC range also covers 图表目录 (list of figures) page"], [
    H("目录"),
    E(0, "第一章 市场与价格", 1),
    E(1, "第一节 需求", 2),
    E(1, "第二节 供给", 7),
    E(0, "第二章 消费者理论", 12),
    E(1, "第一节 效用", 13),
    E(1, "第二节 预算约束", 18),
    E(0, "第三章 生产者理论", 23),
    E(1, "第一节 生产函数", 24),
    E(1, "第二节 成本", 29),
    E(0, "参考文献", 35),
    PB,
    H("图表目录"),
    J("图1-1 需求曲线", page="3"),
    J("图1-2 供给曲线", page="8"),
    J("表1-1 价格弹性", page="10"),
    J("图2-1 无差异曲线", page="14"),
    J("图2-2 预算线", page="19"),
    J("表2-1 效用函数", page="21"),
    J("图3-1 等产量线", page="25"),
    J("图3-2 成本曲线", page="30"),
]))


def _twocol():
    out = [H("目录")]
    p = 1
    for c in range(1, 9):
        out.append(E(0, f"第{'一二三四五六七八'[c-1]}章 {['总论','需求','供给','均衡','市场','政府','贸易','增长'][c-1]}", p))
        for s in range(1, 4):
            p += 2
            out.append(E(1, f"{c}.{s} {['概念','模型','应用'][s-1]}", p))
        p += 3
        if c == 4:
            out.append(CB)
    return out


C.append(Case("c20_two_column", ["two-column TOC page"], _twocol(), columns=2, size_pt=10))

C.append(Case("c21_deep_hierarchy", ["6 levels: 第一篇 / 第1章 / 1.1 / 1.1.1 / (1) / ①"], [
    H("目录"),
    E(0, "第一篇 基础篇", 1),
    E(1, "第1章 概述", 1),
    E(2, "1.1 发展历程", 2),
    E(3, "1.1.1 萌芽阶段", 2),
    E(4, "(1) 早期探索", 3),
    E(5, "① 理论准备", 3),
    E(5, "② 技术准备", 4),
    E(4, "(2) 初步形成", 5),
    E(3, "1.1.2 成熟阶段", 6),
    E(2, "1.2 基本框架", 8),
    E(1, "第2章 原理", 11),
    E(2, "2.1 核心原理", 12),
    E(0, "第二篇 应用篇", 17),
    E(1, "第3章 实践", 17),
    E(2, "3.1 案例", 18),
    E(3, "3.1.1 国内案例", 18),
    E(3, "3.1.2 国外案例", 21),
]))

C.append(Case("c22_cn_enum_under_dotted", ["一、 under 1.1 and （一） under 一、 (unusual order)"], [
    H("目录"),
    E(0, "第一章 总论", 1),
    E(1, "1.1 基本概念", 2),
    E(2, "一、定义", 2),
    E(3, "（一）狭义", 3),
    E(3, "（二）广义", 4),
    E(2, "二、特征", 5),
    E(1, "1.2 研究对象", 7),
    E(2, "一、对象", 7),
    E(2, "二、范围", 8),
    E(0, "第二章 方法", 10),
    E(1, "2.1 定性方法", 11),
    E(2, "一、访谈", 11),
    E(3, "（一）半结构访谈", 12),
    E(1, "2.2 定量方法", 15),
]))

C.append(Case("c23_unnumbered_indent", ["no numbering at all; 3 levels only by indent", "long wrapped titles with hanging indent", "subtitle continuation lines starting with ——"], [
    H("目录"),
    E(0, "城市笔记", 1),
    E(1, "旧街", 2),
    E(1, "在北方的冬天里想起一座南方小城的雨季和它的石板路", 7,
      wrap=["在北方的冬天里想起一座南方小城的雨季和", "它的石板路"]),
    E(2, "附记一", 11),
    E(2, "附记二", 13),
    E(1, "河流", 15),
    E(0, "故人", 21),
    E(1, "父亲的书房——兼忆八十年代的阅读生活", 22,
      wrap=["父亲的书房", "——兼忆八十年代的阅读生活"]),
    E(1, "老师", 29),
    E(2, "补记", 33),
    E(0, "远方", 36),
    E(1, "火车", 37),
    E(1, "海", 42),
]))

C.append(Case("c24_wrapped_number_end", ["wrapped title whose first visual line ends in a number (70年代 / 100年 / Apollo 11)"], [
    H("目录"),
    E(0, "第五章 战后经济", 60),
    E(1, "5.1 马歇尔计划", 62),
    E(1, "5.2 世界大战后的70年代经济", 72, wrap=["5.2 世界大战后的70", "年代经济"]),
    E(1, "5.3 石油危机", 78),
    E(0, "第六章 未来100年的城市", 101, wrap=["第六章 未来100", "年的城市"]),
    E(1, "6.1 人口", 102),
    E(1, "6.2 交通与住房的第2", 106, wrap=["6.2 交通与住房的第2", "次革命"], title="6.2 交通与住房的第2次革命"),
    E(1, "6.3 能源", 110),
    E(0, "第七章 Lessons from Apollo 11 and Beyond", 115, wrap=["第七章 Lessons from Apollo 11", "and Beyond"]),
    E(0, "参考文献", 120),
], extra_body=3))

C.append(Case("c25_out_of_range_pages", ["TOC refers to pages beyond the scanned PDF (partial scan)", "第0章"], [
    H("目录"),
    E(0, "第0章 预备知识", 1),
    E(0, "第1章 集合", 5),
    E(1, "1.1 基本运算", 6),
    E(0, "第2章 映射", 12),
    E(1, "2.1 单射与满射", 13),
    E(0, "第3章 群", 20),
    E(0, "第4章 环与域", 150),
    E(0, "索引", 310),
], body_pages=40))

C.append(Case("c26_en_titles_start_with_numbers", ["English: '1 The Problem', '2 1984 Revisited', 'Catch-22', '2001: A Space Odyssey', 'Fahrenheit 451' (no leaders)"], [
    H("CONTENTS"),
    E(0, "Acknowledgments", "vii", front=True),
    E(0, "Introduction", 1),
    E(0, "1 The Problem", 5),
    E(0, "2 1984 Revisited", 19),
    E(0, "3 Catch-22 and Bureaucracy", 33),
    E(0, "4 2001: A Space Odyssey", 47),
    E(0, "5 The 1990s", 61),
    E(0, "6 Fahrenheit 451", 75),
    E(0, "7 101 Dalmatians and 1001 Nights", 83),
    E(0, "Conclusion", 89),
    E(0, "Notes", 95),
    E(0, "Index", 103),
], lang="en", font="times", size_pt=11, style="noleader"))

C.append(Case("c27_offset_plates", ["8 unnumbered plate pages after printed page 30 (offset changes mid-book)"], [
    H("目录"),
    E(0, "第一章 早期绘画", 1),
    E(1, "第一节 岩画", 2),
    E(1, "第二节 帛画", 9),
    E(0, "第二章 唐宋绘画", 16),
    E(1, "第一节 人物画", 17),
    E(1, "第二节 山水画", 24),
    E(0, "第三章 元明清绘画", 31),
    E(1, "第一节 文人画", 32),
    E(1, "第二节 宫廷画", 40),
    E(0, "第四章 近现代绘画", 48),
    E(1, "第一节 海派", 49),
    E(1, "第二节 新中国美术", 56),
    E(0, "图版目录", 63),
], plates=(30, 8), extra_body=6))

C.append(Case("c28_running_header_numbers", ["running headers with chapter numbers and years ('第3章 2020年经济形势')", "folio outer corner in footer", "chapter openers without folio"], [
    H("目录"),
    E(0, "第1章 2020年经济形势", 1),
    E(1, "1.1 总体判断", 3),
    E(1, "1.2 1.5万亿投资", 8),
    E(0, "第2章 2021年政策取向", 13),
    E(1, "2.1 财政政策", 15),
    E(1, "2.2 货币政策", 20),
    E(0, "第3章 2022年风险展望", 25),
    E(1, "3.1 外部风险", 27),
    E(1, "3.2 内部风险", 32),
    E(0, "第4章 2023年十大趋势", 37),
    E(1, "4.1 趋势一至五", 39),
    E(1, "4.2 趋势六至十", 44),
    E(0, "后记", 50),
], folio="footer-outer", running_header="chapter", opener_no_folio=True, extra_body=5))

C.append(Case("c29_front_arabic_restart", ["front matter numbered 1.. in arabic, body restarts at 1", "TOC lists 前言 1 / 序 4 then 第一章 1"], [
    H("目录"),
    E(0, "序", 1, front=True),
    E(0, "前言", 4, front=True),
    E(0, "第一章 总论", 1),
    E(1, "第一节 概述", 2),
    E(1, "第二节 沿革", 6),
    E(0, "第二章 分论", 11),
    E(1, "第一节 类型", 12),
    E(1, "第二节 比较", 17),
    E(0, "第三章 结语", 23),
    E(0, "后记", 28),
], front_arabic=True, preface_pages=6))

C.append(Case("c30_zh_en_parallel_toc", ["bilingual TOC: each Chinese line followed by an English line (with or without page)"], [
    H("目录 Contents"),
    E(0, "第一章 导论", 1),
    J("Chapter 1 Introduction", ind=0),
    E(1, "1.1 问题", 2),
    J("1.1 The Question", ind=1),
    E(1, "1.2 方法", 5),
    J("1.2 Method", ind=1),
    E(0, "第二章 模型", 9),
    J("Chapter 2 The Model", ind=0),
    E(1, "2.1 设定", 10),
    J("2.1 Setup", ind=1),
    E(1, "2.2 求解", 14),
    J("2.2 Solution", ind=1),
    E(0, "参考文献", 20),
    J("References", ind=0),
], notes="English echo lines have no page; they must not become children or eat the next page"))

C.append(Case("c31_sections_title_first_number", ["Section/§ numbering, 'Part One' words, Lecture N"], [
    H("Contents"),
    E(0, "Part One Foundations", 1),
    E(1, "Lecture 1 Sets and Logic", 3),
    E(2, "§1 Sets", 3),
    E(2, "§2 Logic", 8),
    E(1, "Lecture 2 Numbers", 14),
    E(2, "Section 2.1 Integers", 14),
    E(2, "Section 2.2 Rationals", 19),
    E(0, "Part Two Structures", 25),
    E(1, "Lecture 3 Groups", 27),
    E(2, "§3 Axioms", 27),
    E(2, "§4 Examples", 31),
    E(0, "Index", 38),
], lang="en", font="times", size_pt=11))

C.append(Case("c32_tabular_toc_with_author", ["proceedings style: title line, author line (no page), page on title line", "author names containing digits-looking tokens"], [
    H("目　录"),
    E(0, "城市更新中的社区参与机制研究", 1),
    J("张　伟　李　明", ind=1),
    E(0, "基于 GIS 的历史街区保护评价", 12),
    J("王小红　陈　刚", ind=1),
    E(0, "1990—2020年上海住房政策演变", 23),
    J("赵　一　钱　二", ind=1),
    E(0, "“十四五”时期县域城镇化路径", 35),
    J("孙　立", ind=1),
    E(0, "3个案例：乡村振兴中的集体经济", 46),
    J("周　杰　吴　凡", ind=1),
]))


C.append(Case("c33_chapter_lines_without_pages", ["chapter lines carry no page number (only sections do)", "chapter opener page precedes its first section"], [
    H("目录"),
    E(0, "第一章 导论", "", tpage=1),
    E(1, "第一节 问题的提出", 2),
    E(1, "第二节 文献综述", 5),
    E(0, "第二章 理论框架", "", tpage=9),
    E(1, "第一节 基本假设", 10),
    E(1, "第二节 模型设定", 14),
    E(0, "第三章 实证检验", "", tpage=19),
    E(1, "第一节 数据说明", 20),
    E(1, "第二节 回归结果", 25),
    E(0, "第四章 结论", "", tpage=31),
    E(1, "第一节 主要发现", 32),
    E(1, "第二节 政策建议", 35),
]))

C.append(Case("c34_header_folio_with_numbered_running_head", ["folio in the header outer corner on the same line as a running head full of numbers ('3.2 2019年的12个月')"], [
    H("目录"),
    E(0, "第1章 1978年以来的增长", 1),
    E(1, "1.1 12个五年计划", 3),
    E(1, "1.2 3次产业结构调整", 9),
    E(0, "第2章 2008年金融危机", 15),
    E(1, "2.1 4万亿计划", 17),
    E(1, "2.2 2009年的V型反弹", 23),
    E(0, "第3章 2015年以后", 29),
    E(1, "3.1 供给侧改革的5项任务", 31),
    E(1, "3.2 2019年的12个月", 37),
    E(0, "第4章 展望2035", 43),
], folio="header-outer", running_header="section", extra_body=6))

C.append(Case("c35_continuous_numbering_offset0", ["one arabic sequence from the cover: printed == physical (offset 0)", "TOC pages themselves carry arabic folios 5, 6"], [
    H("目录"),
    E(0, "前言", 3),
    E(0, "第一章 总论", 7),
    E(1, "第一节 概念", 8),
    E(1, "第二节 沿革", 12),
    E(0, "第二章 分论", 17),
    E(1, "第一节 类型", 18),
    E(1, "第二节 比较", 23),
    E(0, "第三章 结语", 29),
    E(0, "后记", 34),
], continuous=True, preface_pages=3))

C.append(Case("c36_toc_at_back", ["TOC printed at the END of the book (French/Japanese style), arabic folios"], [
    H("Table des matières"),
    E(0, "Avant-propos", 1),
    E(0, "Chapitre 1 Les origines", 5),
    E(1, "1.1 La cité antique", 6),
    E(1, "1.2 Le Moyen Âge", 12),
    E(0, "Chapitre 2 La modernité", 19),
    E(1, "2.1 Les Lumières", 20),
    E(1, "2.2 La révolution industrielle", 27),
    E(0, "Chapitre 3 Le présent", 35),
    E(0, "Bibliographie", 43),
    E(0, "Index", 47),
], lang="en", font="times", size_pt=11, toc_at_back=True, preface_pages=2))

C.append(Case("c37_leading_fullwidth_punct", ["unnumbered one-level TOC; some titles start with “ 《 （ 【 whose glyphs have a wide left bearing (ink starts ~half an em right)"], [
    H("目录"),
    E(0, "小引", 1),
    E(0, "《红楼梦》的版本问题", 3),
    E(0, "说“雅”", 11),
    E(0, "“五四”以来的新诗", 17),
    E(0, "读史札记", 25),
    E(0, "（附）作者年表", 33),
    E(0, "【补遗】两封信", 39),
    E(0, "「京派」与「海派」", 44),
    E(0, "后记", 50),
]))

C.append(Case("c38_one_wrapped_number_line", ["an ordinary 18-entry TOC with ONE wrapped title whose first line ends in a number that is in page order ('3.2 回顾20' / '世纪的经济史', previous entry on page 20)"], [
    H("目录"),
    E(0, "第一章 导论", 1),
    E(1, "1.1 问题", 2),
    E(1, "1.2 方法", 5),
    E(0, "第二章 战前经济", 9),
    E(1, "2.1 大萧条", 10),
    E(1, "2.2 新政", 14),
    E(0, "第三章 战后经济", 19),
    E(1, "3.1 马歇尔计划", 20),
    E(1, "3.2 回顾20世纪的经济史", 26, wrap=["3.2 回顾20", "世纪的经济史"]),
    E(1, "3.3 石油危机", 31),
    E(0, "第四章 全球化", 36),
    E(1, "4.1 贸易", 37),
    E(1, "4.2 金融", 42),
    E(0, "第五章 新世纪", 47),
    E(1, "5.1 危机", 48),
    E(1, "5.2 复苏", 53),
    E(0, "第六章 结论", 58),
    E(0, "参考文献", 62),
]))
