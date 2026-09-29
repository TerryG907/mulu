# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pillow>=10",
#   "img2pdf>=0.5",
#   "numpy>=1.26",
#   "pikepdf>=9",
#   "fonttools>=4.40",
# ]
# ///
"""
make_books.py -- synthetic SCANNED BOOKS with ground truth, for the OCR -> printed-TOC ->
offset -> outline pipeline (mulu ocr-toc / toc parse / detect-offset / auto).

    uv run --python 3.12 tools/fixtures/make_books.py [--only a,b] [--out DIR] [--list]
                                                      [--preview DIR] [--jobs N]

Everything is generated here: text is written by this script, fonts are the macOS system
fonts (Songti / STHeiti / Hiragino Sans GB / PingFang, Times). No downloads, no personal files.

Each book is: a cover, front matter with roman-numeral folios (preface, 1-5 printed TOC
pages), body pages with printed arabic folios (footer centre, footer outer corner, or header
outer corner), back matter, sometimes a back cover. The physical-minus-printed offset is 4..14.
Pages are rendered at 300 dpi with Pillow and degraded like a real scan (per-page skew 0.3-1.2 deg,
shift, blur, noise, speckle, gutter shadow), then stored as CCITT G4 bitonal or grayscale JPEG
through img2pdf (the image data is passed through untouched).

Writes into Fixtures/books/ (and nowhere else):
  <book>.pdf            the scanned book
  <book>.truth.json     ground truth, see TRUTH FORMAT below
  <book>.toc_lines.txt  a perfect transcription of the printed TOC pages, in reading order
                        (heading, entry lines incl. wrapped continuation lines, folio), one
                        visual line per text line; 2 spaces of indentation per TOC level
  <book>.toc.txt        the correct Mulu TOC with PHYSICAL pages (apply it with --offset 0)
  <book>.expected.json  what `mulu dump-outline` prints after applying <book>.toc.txt
  manifest.json         one row per book (features, fonts, page count, size)

TRUTH FORMAT (<book>.truth.json)
  toc_pages            [physical page numbers, 1-based] of the printed TOC
  toc_pages_arg        the same as a range string ("7-8") for --pages / --toc-pages
  offset               physical = printed + offset, for every arabic printed page
  front_matter_offset  physical = roman value + front_matter_offset, for roman printed pages
  pages                physical page count
  entries[]            {title, level, printed_page, printed_page_text, physical_page, front_matter}
                       title  = the outline title: numbering + one ASCII space + text ("第一章 绪论",
                                "1.1 研究背景", "一、基本概念", "（一）定义", "Chapter 3 Memory"), exactly
                                as printed except that the printed separator (U+3000 / 2 spaces) is
                                one space and a wrapped title is joined (CJK: no space, Latin: one space)
                       level  = 0-based depth in the printed hierarchy
                       printed_page      = int (arabic, first page of a range) or roman string ("iii")
                       printed_page_text = exactly what is printed ("１２", "12-15", "iii")
                       physical_page     = 1-based page of the PDF the entry points at
                       front_matter      = true for roman-numbered entries
  folios               {physical page: printed folio text or null}, for every page; null = no
                       folio printed (cover, blank, part title, chapter opener in some books)
  folio_position       footer-center | footer-outer | header-outer
  features, render     what the book exercises and how it was rendered / degraded
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import io
import json
import math
import random
import sys
import time
import zlib
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "Fixtures" / "books"

# ============================================================================
# fonts
# ============================================================================

SONGTI = "/System/Library/Fonts/Supplemental/Songti.ttc"
HEITI_L = "/System/Library/Fonts/STHeiti Light.ttc"
HEITI_M = "/System/Library/Fonts/STHeiti Medium.ttc"
HIRAGINO = "/System/Library/Fonts/Hiragino Sans GB.ttc"
PINGFANG = "/System/Library/PrivateFrameworks/FontServices.framework/Versions/A/Resources/Reserved/PingFangUI.ttc"
PINGFANG_PUBLIC = "/System/Library/Fonts/PingFang.ttc"
ARIAL_UNI = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
TIMES = "/System/Library/Fonts/Times.ttc"
TNR = "/System/Library/Fonts/Supplemental/Times New Roman.ttf"
TNR_B = "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf"
GEORGIA = "/System/Library/Fonts/Supplemental/Georgia.ttf"

# (path, face index); the first one that exists wins. CJK keys never fall back to a font
# without CJK glyphs: every drawn string is checked against the font's cmap.
FONT_CANDIDATES: dict[str, list[tuple[str, int]]] = {
    "song": [(SONGTI, 6), (SONGTI, 4), (HIRAGINO, 0), (ARIAL_UNI, 0)],
    "song_light": [(SONGTI, 3), (SONGTI, 6), (HIRAGINO, 0)],
    "song_bold": [(SONGTI, 1), (HEITI_M, 1), (HIRAGINO, 2)],
    "hei": [(HEITI_L, 1), (HIRAGINO, 0), (PINGFANG_PUBLIC, 0), (PINGFANG, 20), (ARIAL_UNI, 0)],
    "hei_bold": [(HEITI_M, 1), (HIRAGINO, 2), (PINGFANG, 20)],
    "pingfang": [(PINGFANG_PUBLIC, 0), (PINGFANG, 20), (HIRAGINO, 0), (HEITI_L, 1)],
    "hiragino": [(HIRAGINO, 0), (HEITI_L, 1)],
    "times": [(TIMES, 0), (TNR, 0), (GEORGIA, 0)],
    "times_bold": [(TIMES, 1), (TNR_B, 0)],
    "georgia": [(GEORGIA, 0), (TIMES, 0)],
}

_font_cache: dict = {}
_cmap_cache: dict = {}
FONTS_USED: dict[str, str] = {}


def font_source(key: str) -> tuple[str, int]:
    for path, idx in FONT_CANDIDATES[key]:
        if Path(path).exists():
            return path, idx
    raise SystemExit(f"make_books: no font for '{key}' (tried {FONT_CANDIDATES[key]})")


def get_font(key: str, px: float):
    from PIL import ImageFont
    px = max(6, int(round(px)))
    ck = (key, px)
    if ck not in _font_cache:
        path, idx = font_source(key)
        _font_cache[ck] = ImageFont.truetype(path, px, index=idx)
        FONTS_USED[key] = f"{Path(path).name}#{idx}"
    return _font_cache[ck]


def cmap_of(key: str) -> set[int]:
    if key not in _cmap_cache:
        from fontTools.ttLib import TTFont
        path, idx = font_source(key)
        f = TTFont(path, fontNumber=idx, lazy=True)
        _cmap_cache[key] = set(f.getBestCmap().keys())
        f.close()
    return _cmap_cache[key]


def check_glyphs(key: str, text: str):
    cm = cmap_of(key)
    missing = sorted({c for c in text if not c.isspace() and ord(c) not in cm})
    if missing:
        raise SystemExit(f"make_books: font '{key}' ({font_source(key)}) has no glyph for {missing!r} in {text!r}")


# ============================================================================
# numbering
# ============================================================================

CN_DIGITS = "零一二三四五六七八九"


def cn(n: int) -> str:
    if n < 10:
        return CN_DIGITS[n]
    if n < 20:
        return "十" + (CN_DIGITS[n - 10] if n > 10 else "")
    if n < 100:
        return CN_DIGITS[n // 10] + "十" + (CN_DIGITS[n % 10] if n % 10 else "")
    raise ValueError(n)


def roman(n: int, upper=False) -> str:
    vals = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
    out = ""
    for v, s in vals:
        while n >= v:
            out += s
            n -= v
    return out.upper() if upper else out


FULLWIDTH = str.maketrans("0123456789-", "０１２３４５６７８９－")


def fmt_number(kind: str, path: tuple[int, ...], chapter: int, chapter_depth: int) -> str:
    i = path[-1]
    if kind == "zh_zhang":
        return f"第{cn(i)}章"
    if kind == "zh_zhang_ar":
        return f"第{i}章"
    if kind == "zh_jie":
        return f"第{cn(i)}节"
    if kind == "zh_pian":
        return f"第{cn(i)}篇"
    if kind == "zh_bufen":
        return f"第{cn(i)}部分"
    if kind == "zh_dun":
        return f"{cn(i)}、"
    if kind == "zh_paren_fw":
        return f"（{cn(i)}）"
    if kind == "zh_paren_hw":
        return f"({cn(i)})"
    if kind == "ar_dot":
        return f"{i}."
    if kind == "dec":
        return ".".join([str(chapter)] + [str(x) for x in path[chapter_depth + 1:]])
    if kind == "en_part":
        return f"Part {roman(i, upper=True)}"
    if kind == "en_chapter":
        return f"Chapter {chapter}"
    if kind == "en_section":
        return "Section " + ".".join([str(chapter)] + [str(x) for x in path[chapter_depth + 1:]])
    if kind == "none":
        return ""
    raise ValueError(kind)


# ============================================================================
# vocabulary (all written for this script)
# ============================================================================

def _v(s: str) -> list[str]:
    return [x for x in s.split() if x]


VOCAB: dict[str, list[str]] = {
    # --- economics textbook
    "econ_ch": _v("绪论 需求、供给与市场均衡 消费者行为理论 生产理论 成本理论 完全竞争市场 垄断市场 寡头市场与博弈论初步 "
                  "生产要素市场 一般均衡与福利经济学 市场失灵与微观经济政策"),
    "econ_sec": _v("研究对象与研究方法 基本概念与基本假设 理论的历史演变 需求曲线及其移动 供给曲线及其移动 均衡价格的决定 "
                   "弹性的概念与计算 价格管制的效应 边际效用分析 无差异曲线分析 预算约束线 消费者均衡 收入效应与替代效应 "
                   "生产函数 短期生产分析 长期生产与规模报酬 等产量线 机会成本与会计成本 短期成本曲线 长期成本曲线 "
                   "厂商的收益 利润最大化原则 短期均衡 长期均衡 垄断的成因 价格歧视 自然垄断的管制 古诺模型 囚徒困境 "
                   "纳什均衡 要素需求 工资的决定 地租与利息 洛伦兹曲线与基尼系数 帕累托最优 外部性 公共物品 信息不对称"),
    "generic3": _v("概念界定 基本特征 主要类型 影响因素 计算方法 政策含义 案例分析 评价与展望 数学推导 图形分析 "
                   "适用条件 典型事实 实证检验 比较分析 主要结论 方法步骤 注意事项 常见误区"),
    # --- computer networks (decimal numbering)
    "net_ch": _v("计算机网络概述 物理层 数据链路层 网络层 传输层 应用层 网络安全 无线网络与移动网络 网络管理"),
    "net_sec": _v("网络的发展历程 分层体系结构 性能指标 传输介质 信道复用技术 差错检测 点对点协议 以太网 交换机的工作原理 "
                  "虚拟局域网 IP协议 地址解析协议 路由选择算法 路由器的结构 用户数据报协议UDP 传输控制协议TCP 可靠传输原理 "
                  "拥塞控制 域名系统 万维网与HTTP 电子邮件 文件传送协议 对称密钥密码体制 公钥密码体制 数字签名 防火墙 "
                  "无线局域网 蜂窝网络 移动IP 简单网络管理协议 网络故障诊断"),
    "net_sub": _v("基本原理 帧格式 工作过程 算法描述 典型实现 性能分析 配置示例 协议字段 状态转换 安全隐患"),
    # --- Chinese history, parts
    "hist_part": _v("先秦时期 秦汉至隋唐 宋元明清 近代中国"),
    "hist_ch": _v("文明的起源 夏商西周的国家形态 春秋战国的社会变革 秦的统一与制度建设 两汉的政治与经济 魏晋南北朝的分裂与融合 "
                  "隋唐的繁荣 宋代的经济与文化 元代的疆域与行省制度 明代的政治与社会 清代前期的统一与发展 鸦片战争与近代开端 "
                  "洋务运动与维新变法 辛亥革命"),
    "hist_sec": _v("考古发现 社会结构 政治制度 经济发展 思想文化 对外交往 民族关系 科学技术 城市与交通 土地制度 赋役制度 "
                   "选官制度 地方行政 文学艺术 宗教信仰 边疆治理 历史评价 主要人物"),
    "hist_sub": _v("背景 经过 影响 史料 争论 遗存"),
    # --- management (two-column TOC)
    "mgmt_part": _v("管理导论 计划与决策 组织与人员 领导与激励 控制与创新"),
    "mgmt_sec": _v("管理的内涵 管理者的角色 管理理论的演进 环境分析 目标管理 决策的过程 战略规划 组织结构设计 "
                   "人力资源管理 团队建设 领导理论 激励理论 沟通 控制的类型 绩效评估 创新管理 企业文化 社会责任"),
    "mgmt_sub": _v("基本含义 主要内容 实施步骤 常用工具 典型案例 发展趋势"),
    # --- mechanical design (4 levels)
    "mech_ch": _v("机械设计总论 连接 带传动 链传动 齿轮传动 蜗杆传动 轴 滚动轴承 联轴器与离合器 弹簧"),
    "mech_sec": _v("设计的基本要求 材料的选用 螺纹连接 键连接 带传动的受力分析 带的选型计算 链传动的运动特性 "
                   "齿轮的失效形式 齿面接触强度计算 齿根弯曲强度计算 蜗杆传动的效率 轴的结构设计 轴的强度校核 "
                   "轴承的类型与代号 寿命计算 联轴器的选择 弹簧的设计计算"),
    "mech_sub": _v("受力分析 强度条件 设计步骤 参数选择 计算实例 结构要点 润滑与密封 精度等级"),
    "mech_sub2": _v("已知条件 计算过程 结果校核 讨论"),
    # --- literature essays (unnumbered)
    "essay_group": _v("故园 行旅 书边 人物 四时"),
    "essay": _v("老屋的门槛 母亲的菜园 井边的石榴树 雨夜读书记 外婆的针线笸箩 小城的钟声 夜航船上 北方的冬天 江南梅雨 "
                "山中一日 旧书摊 书房的灯 读史札记 重读唐诗 父亲的手表 远去的邻居 一位老教师 春分 小暑 白露 大雪 "
                "异乡的月亮 火车站的黄昏 渡口 桥 集市 灯下 茶事 纸上的河流"),
    "essay_sub": _v("之一 之二 之三 补记 附记"),
    # --- pharmacology (fullwidth digits, JPEG)
    "pharm_ch": _v("绪言 药物效应动力学 药物代谢动力学 影响药物作用的因素 传出神经系统药理概论 抗高血压药 抗心律失常药 "
                   "抗菌药物概论 解热镇痛抗炎药 糖皮质激素"),
    "pharm_sec": _v("药物的基本作用 量效关系 药物的体内过程 房室模型 给药方案 药物相互作用 受体学说 作用机制 临床应用 "
                    "不良反应 禁忌证 用法与用量 耐药性 联合用药 特殊人群用药 药物的分类"),
    # --- organic chemistry (noisy)
    "chem_ch": _v("绪论 烷烃 烯烃 炔烃和二烯烃 芳香烃 卤代烃 醇和酚 醛和酮 羧酸及其衍生物"),
    "chem_sec": _v("有机化合物的特点 结构与命名 物理性质 化学性质 制备方法 重要化合物 反应机理 立体化学 亲电加成 "
                   "亲核取代 消除反应 氧化与还原 波谱分析 共振论"),
    # --- policy research (long titles)
    "policy_ch": [
        "新时代基层社会治理体系和治理能力现代化的理论基础与历史演进",
        "城乡基层治理中党建引领机制的形成逻辑与运行方式",
        "数字技术赋能社区公共服务供给的实践探索与制度保障研究",
        "基层财政保障能力与公共服务均等化之间的关系及其政策含义",
        "乡村振兴背景下村民自治组织与新型农村集体经济组织的协同发展路径",
        "超大城市社区网格化管理的成效评估与优化方向",
        "结论与政策建议",
    ],
    "policy_sec": [
        "基层社会治理的概念内涵与主要特征",
        "改革开放以来我国基层治理体制机制演变的主要阶段与基本经验",
        "国外社区治理模式的比较及其对我国的借鉴意义",
        "党组织在社区议事协商中的领导作用及其实现形式",
        "区域化党建联席会议制度在跨部门协调中的实际运行状况调查",
        "政务服务“一网通办”在街道和社区层面的落地情况与存在的主要问题",
        "社区数据共享平台建设中的个人信息保护与安全管理问题研究",
        "转移支付制度对县级政府基本公共服务支出结构的影响",
        "基层公共服务供给效率的测度方法",
        "集体经济收益分配机制与村民参与积极性的关系分析",
        "村务监督委员会在农村小微权力运行中的监督作用",
        "网格员队伍建设中的职责边界、激励机制与职业发展通道问题",
        "基于十二个城市社区问卷调查数据的治理成效实证分析",
        "主要研究结论",
        "进一步完善基层治理体系的若干政策建议",
        "研究不足与展望",
    ],
    # --- proceedings
    "proc_part": _v("数字人文理论与方法 古籍整理与知识组织 文本挖掘与计量分析 数字档案与公共记忆"),
    "proc_paper": [
        "数字人文研究范式的形成与反思", "面向人文学者的数据素养教育", "知识图谱在历史人物研究中的应用",
        "基于深度学习的古籍版面分析方法", "宋代文人交游网络的可视化研究", "地方志中灾害记录的抽取与整理",
        "古籍异体字规范化处理的若干问题", "明清小说人物关系的计量分析", "唐诗意象的共现网络研究",
        "近代报刊语料库的建设与利用", "口述历史档案的数字化保存", "城市记忆项目的公众参与机制",
        "档案开放与隐私保护的平衡", "图书馆特藏资源的元数据设计", "人文数据的长期保存策略",
    ],
    # --- personal finance small book
    "fin_ch": _v("认识家庭资产 记账与预算 储蓄的方法 保险的配置 基金入门 退休规划 常见误区"),
    "fin_sec": _v("收入与支出 资产负债表 现金流量表 每月预算表 应急资金 定期存款 意外险 医疗险 重疾险 货币基金 指数基金 "
                  "定投的原理 养老金 税收优惠 过度负债 盲目跟风"),
    "fin_sub": _v("基本做法 注意事项 一个例子 小结"),
    # --- English technical
    "sys_part": ["Foundations", "Building Systems", "Running in Production"],
    "sys_ch": ["Why Systems Programming", "The Toolchain", "Memory and Ownership", "Errors and Recovery",
               "Concurrency Primitives", "Asynchronous I/O", "Networking Basics", "Storage Engines", "Observability",
               "Performance Engineering", "Packaging and Deployment", "Security Hardening"],
    "sys_sec": ["Overview", "Design Goals", "A First Example", "Stack and Heap", "Borrowing Rules",
                "Lifetimes in Practice", "Error Types", "Retry Strategies", "Threads and Locks", "Channels", "Atomics",
                "Event Loops", "Futures and Tasks", "Sockets", "Framing Protocols", "Write-Ahead Logs", "B-Trees",
                "Compaction", "Metrics", "Tracing", "Profiling with Samples", "Benchmark Hygiene", "Static Linking",
                "Reproducible Builds", "Threat Models", "Sandboxing", "Summary", "Exercises"],
    "sys_sub": ["Motivation", "Worked Example", "Common Pitfalls", "Further Reading", "Trade-offs",
                "Implementation Notes", "Checklist"],
    # --- English manual
    "man_ch": ["Getting Started", "Planning Your Network", "Routers and Access Points", "Wired Connections",
               "Wireless Coverage", "Security Settings", "Troubleshooting", "Maintenance"],
    "man_sec": ["Unboxing the Kit", "Safety Notes", "Choosing a Location", "Measuring Signal Strength",
                "Connecting the Modem", "Updating Firmware", "Running Cable", "Mesh Nodes", "Guest Networks",
                "Passwords and Keys", "Parental Controls", "Slow Connections", "Dropped Calls", "Resetting the Router",
                "Cleaning and Storage", "Replacing Parts"],
}

ZH_SENT = [
    "本节在前文讨论的基础上，进一步分析相关因素之间的相互关系。", "从历史数据来看，这一趋势在1998年以后表现得尤为明显。",
    "需要指出的是，上述结论依赖于若干较强的假设条件。", "如图3-2所示，曲线的斜率随着数量的增加而逐渐减小。",
    "表2-1列出了主要变量的定义、单位及数据来源。", "在实际应用中，研究者往往需要根据具体情况对模型加以修正。",
    "这一观点最早在二十世纪五十年代提出，此后得到了广泛的讨论。", "根据抽样调查的结果，约有35.6%的受访者表示支持。",
    "由公式（4.12）可以推出，当参数趋近于零时，系统趋于稳定。", "为了便于理解，我们先从一个简单的例子开始。",
    "以下三个方面值得读者特别注意。", "其一，数据的可得性直接影响分析的深度；其二，方法应当与问题相匹配。",
    "本书第7章将对这一问题作更为详细的讨论。", "在2015年至2020年间，相关指标的年均增长率保持在6%左右。",
    "这种做法虽然简便，但也存在明显的局限性。", "读者可以结合习题5和习题6加深对这部分内容的理解。",
    "总体而言，理论预测与实证结果基本一致。", "当然，也有学者对这一解释提出了不同意见。",
    "进一步的研究表明，制度环境在其中发挥了关键作用。", "我们将在下一节讨论更一般的情形。",
    "图中的阴影部分表示在给定约束条件下可以实现的全部组合。", "上述分析同样适用于多个主体相互作用的情形。",
    "值得注意的是，短期效应与长期效应的方向并不总是相同的。", "第1至第3个样本的结果见附表A-4。",
    "这些材料为后人留下了宝贵的第一手记录。", "在此基础上，可以归纳出若干具有普遍意义的规律。",
    "实验共进行了12组，每组重复3次，取其平均值。", "这一过程通常需要经过4个阶段才能完成。",
]
EN_SENT = [
    "This section builds on the previous one and looks at the same problem from a different angle.",
    "As Figure 4.2 shows, latency grows slowly at first and then sharply once the queue fills up.",
    "The listing below is complete; you can type it in and run it as is.",
    "In our measurements the difference was about 12 percent, which is well within the noise.",
    "We will come back to this point in Chapter 9, once the necessary tools are in place.",
    "Most production incidents we studied in 2019 had more than one contributing cause.",
    "A good rule of thumb is to measure first and optimize second.",
    "Note that the second call never blocks, even when the buffer is empty.",
    "Table 3.1 summarizes the options and their default values.",
    "None of this is new, but it is easy to forget under deadline pressure.",
    "The same idea applies to files, sockets, and any other resource with a lifetime.",
    "If the test fails, the error message names the exact line and the value it expected.",
    "There are 3 common ways to structure such a program, and each has its place.",
    "Readers who skipped Part I may want to review the terminology before continuing.",
    "The protocol is described in RFC 9293, which replaced several older documents.",
    "In practice the limit is rarely reached, but the code must still handle it.",
]
SURNAMES = list("王李张刘陈杨赵黄周吴徐孙胡朱高林何郭马罗")
GIVEN = list("建国明华伟芳娜敏静丽强磊军洋勇艳杰涛超秀霞平刚桂英")
# Fictional imprints only (these books are synthetic test data). Same length as the names used
# when the recorded results were made, so every page lays out exactly as before.
PUBLISHERS = ["北京：示例教育出版社", "上海：示例人文出版社", "北京：示例出版社", "北京：示例书局", "北京：示例大学出版社",
              "北京：虚构出版社", "北京：示例工业出版社", "上海：虚构大学出版社"]


# ============================================================================
# book specs
# ============================================================================

@dataclass
class Level:
    fmt: str                 # numbering kind (fmt_number) or "none"
    count: tuple[int, int]   # children per parent
    vocab: str
    sep: str = "　"          # printed separator between number and text
    kind: str = "section"    # part | chapter | section


@dataclass
class Book:
    name: str
    lang: str
    title: str
    author: str
    publisher: str
    trim: str                 # 16k | 32k | 6x9
    mode: str                 # g4 | jpeg
    dpi: int
    offset: int
    front: list               # physical order: ("cover",) ("blank",) ("title",) ("copyright",) ("intro",)
    #                           ("preface", name, pages, in_toc) ("toc",) ("pad",) ("ack", name, pages, in_toc)
    roman_from: str           # "title" | "preface" | "halftitle": the item whose first page is roman i
    levels: list
    back: list                # [(title, pages)] arabic back matter, level 0
    folio: str = "footer-center"
    folio_style: str = "plain"
    opener_folio: str = "same"      # same | none | footer-center
    running_head: bool = True
    recto_chapters: bool = False
    part_folio: bool = False
    leader: str = "ellipsis"        # ellipsis | middot | dots | spaced_dots | dash | none
    leader_level0: str | None = None
    toc_heading: str = "目　录"
    toc_twocol: bool = False
    toc_size_pt: float = 10.5
    toc_indent_em: float = 2.0
    toc_line_factor: float = 1.8
    toc_num_font: str = "times"
    toc_folio: bool = True
    fullwidth_digits: bool = False
    page_ranges: bool = False
    chapter_tail: str | None = None  # an unnumbered last section in every chapter ("本章小结")
    heading_style: str = "one-line"  # one-line | two-line
    profile: str = "normal_g4"
    rotation: float = 0.6
    cover: str = "bitonal"          # bitonal | color
    back_cover: bool = False
    pages_range: tuple = (60, 90)
    resave_objstm: bool = False
    body_font: str = "song"
    features: list = field(default_factory=list)


BOOKS: list[Book] = [
    Book("zh_econ_textbook", "zh", "微观经济学原理", "王建国　李明华　编著", "北京：示例教育出版社", "16k", "g4", 300, 9,
         [("cover",), ("blank",), ("title",), ("copyright",), ("preface", "前言", 2, True), ("toc",), ("pad",)],
         "preface",
         [Level("zh_zhang", (8, 8), "econ_ch", "　", "chapter"), Level("zh_jie", (2, 4), "econ_sec", "　"),
          Level("zh_dun", (0, 3), "generic3", "")],
         [("参考文献", 2), ("索引", 2)],
         folio="footer-outer", leader="ellipsis", leader_level0="none", chapter_tail="本章小结",
         heading_style="two-line", profile="normal_g4", rotation=0.4, cover="color", back_cover=True,
         pages_range=(85, 100), features=["第X章/第X节/一、", "unnumbered 本章小结 at section level", "roman 前言 entry",
                                          "footer outer (alternating)", "level-0 lines without leaders", "color cover"]),
    Book("zh_network_decimal", "zh", "计算机网络（第2版）", "张伟　编著", "北京：示例大学出版社", "32k", "g4", 300, 8,
         [("cover",), ("title",), ("copyright",), ("preface", "前言", 1, False), ("toc",), ("pad",)],
         "preface",
         [Level("zh_zhang_ar", (7, 7), "net_ch", "　", "chapter"), Level("dec", (2, 4), "net_sec", " "),
          Level("dec", (0, 2), "net_sub", " ")],
         [("附录A 常用协议端口号", 1), ("附录B 缩略语", 1), ("参考文献", 1)],
         folio="footer-center", folio_style="dash", leader="middot", profile="normal_g4", rotation=-0.6,
         pages_range=(65, 85), toc_size_pt=9.5,
         features=["第1章/1.1/1.1.1", "附录A/附录B", "folio '— 12 —'", "middle-dot leaders", "titles with digits"]),
    Book("zh_history_parts_longtoc", "zh", "中国古代史纲要", "刘静　赵强　主编", "北京：示例书局", "16k", "g4", 300, 13,
         [("cover",), ("blank",), ("title",), ("copyright",), ("preface", "序", 2, True), ("preface", "前言", 2, True),
          ("toc",), ("pad",)],
         "preface",
         [Level("zh_pian", (4, 4), "hist_part", "　", "part"), Level("zh_zhang", (3, 4), "hist_ch", "　", "chapter"),
          Level("zh_jie", (2, 3), "hist_sec", "　"), Level("zh_dun", (0, 3), "hist_sub", "")],
         [("后记", 1)],
         folio="footer-center", leader="dots", recto_chapters=False, part_folio=False, profile="normal_g4",
         rotation=0.8, pages_range=(108, 120), toc_line_factor=1.75, toc_size_pt=11,
         features=["第X篇/第X章/第X节/一、 (4 levels)", "TOC spans 5 pages", "roman 序 and 前言 entries",
                   "part title pages without folio", "ASCII dot leaders", "后记"]),
    Book("zh_mgmt_twocol", "zh", "管理学基础", "陈芳　编著", "上海：虚构大学出版社", "16k", "g4", 300, 5,
         [("cover",), ("title",), ("copyright",), ("toc",), ("pad",)],
         "title",
         [Level("zh_bufen", (5, 5), "mgmt_part", "　", "chapter"), Level("zh_dun", (2, 4), "mgmt_sec", ""),
          Level("zh_paren_fw", (0, 3), "mgmt_sub", "")],
         [("参考文献", 1)],
         folio="footer-outer", leader="ellipsis", toc_twocol=True, toc_size_pt=9, toc_indent_em=1.5,
         profile="clean_g4", rotation=0.3, pages_range=(55, 70),
         features=["two-column TOC page", "第一部分/一、/（一）", "footer outer (alternating)"]),
    Book("zh_mech_header_folio", "zh", "机械设计基础", "孙磊　编", "北京：示例工业出版社", "32k", "g4", 300, 12,
         [("cover",), ("blank",), ("title",), ("copyright",), ("intro",), ("preface", "前言", 2, False), ("toc",),
          ("pad",)],
         "preface",
         [Level("zh_zhang", (6, 6), "mech_ch", "　", "chapter"), Level("dec", (2, 3), "mech_sec", " "),
          Level("dec", (1, 2), "mech_sub", " "), Level("dec", (0, 2), "mech_sub2", " ")],
         [("参考文献", 1)],
         folio="header-outer", opener_folio="footer-center", leader="ellipsis", profile="normal_g4", rotation=-0.9,
         pages_range=(85, 100), toc_size_pt=9.5, toc_indent_em=1.5,
         features=["第一章/1.1/1.1.1/1.1.1.1 (4 levels)", "page numbers in the HEADER (outer corner)",
                   "chapter openers numbered in the footer"]),
    Book("zh_policy_long_titles", "zh", "基层治理现代化研究", "周敏　等著", "北京：虚构出版社", "16k", "g4", 300, 7,
         [("cover",), ("title",), ("copyright",), ("preface", "前言", 2, True), ("toc",), ("pad",)],
         "preface",
         [Level("zh_zhang", (7, 7), "policy_ch", "　", "chapter"), Level("zh_jie", (2, 3), "policy_sec", "　")],
         [("参考文献", 2), ("后记", 1)],
         folio="footer-center", leader="ellipsis", profile="normal_g4", rotation=0.5, pages_range=(60, 80),
         features=["very long titles wrapped over 2-3 lines", "第X章/第X节", "roman 前言 entry"]),
    Book("en_systems_technical", "en", "Systems Programming in Practice", "A. N. Author", "Example Press", "6x9", "g4",
         300, 14,
         [("cover",), ("blank",), ("halftitle",), ("blank",), ("title",), ("copyright",), ("dedication",),
          ("blank",), ("preface", "Preface", 2, True), ("toc",), ("ack", "Acknowledgments", 1, True), ("pad",)],
         "halftitle",
         [Level("en_part", (3, 3), "sys_part", "  ", "part"), Level("en_chapter", (3, 4), "sys_ch", "  ", "chapter"),
          Level("dec", (2, 3), "sys_sec", " "), Level("dec", (0, 2), "sys_sub", " ")],
         [("Appendix A Tool Reference", 2), ("Bibliography", 1), ("Index", 2)],
         folio="footer-outer", leader="spaced_dots", toc_heading="Contents", toc_size_pt=10.5, toc_indent_em=1.5,
         toc_num_font="times", profile="normal_g4", rotation=0.7, pages_range=(100, 120), body_font="times",
         features=["English", "Part I/Chapter 1/1.1/1.1.1", "roman Preface/Acknowledgments entries",
                   "Appendix A/Bibliography/Index", "running heads with chapter numbers"]),
    Book("en_router_manual_jpeg", "en", "The Home Network Field Guide", "J. Q. Writer", "Example Press", "6x9", "jpeg",
         200, 5,
         [("cover",), ("title",), ("copyright",), ("toc",), ("pad",)],
         "title",
         [Level("en_chapter", (8, 8), "man_ch", "  ", "chapter"), Level("en_section", (1, 3), "man_sec", "  ")],
         [("Index", 1)],
         folio="footer-outer", leader="none", toc_heading="Contents", toc_size_pt=11, toc_indent_em=2.0,
         profile="jpeg_gray", rotation=-0.4, cover="color", pages_range=(40, 55), body_font="times",
         features=["English", "grayscale JPEG 200 dpi", "Chapter N / Section N.M", "no dot leaders",
                   "footer outer (alternating)"]),
    Book("zh_essays_unnumbered", "zh", "纸上的河流", "林秀　著", "上海：示例人文出版社", "32k", "g4", 300, 8,
         [("cover",), ("blank",), ("title",), ("copyright",), ("preface", "序", 1, True), ("toc",), ("pad",)],
         "preface",
         [Level("none", (5, 5), "essay_group", "", "chapter"), Level("none", (3, 5), "essay", ""),
          Level("none", (0, 2), "essay_sub", "")],
         [("后记", 1)],
         folio="footer-center", leader="ellipsis", running_head=False, profile="normal_g4", rotation=0.6,
         pages_range=(60, 80), toc_indent_em=2.0,
         features=["no numbering at all: levels only by indentation", "roman 序 entry", "no running heads"]),
    Book("zh_pharm_fullwidth_jpeg", "zh", "临床药理学基础", "何军　主编", "北京：示例出版社", "32k", "jpeg", 300, 11,
         [("cover",), ("blank",), ("title",), ("copyright",), ("preface", "前言", 3, True), ("toc",),
          ("intro",), ("pad",)],
         "preface",
         [Level("zh_zhang_ar", (9, 9), "pharm_ch", "　", "chapter"), Level("dec", (2, 4), "pharm_sec", " ")],
         [("参考文献", 1)],
         folio="footer-center", leader="dash", fullwidth_digits=True, toc_num_font="song",
         profile="jpeg_gray", rotation=1.0, cover="color", pages_range=(70, 90), resave_objstm=True,
         features=["full-width page digits in the TOC (１２３)", "dash leaders ——", "grayscale JPEG 300 dpi",
                   "第1章/1.1", "object streams (qpdf re-save)", "roman 前言 entry"]),
    Book("zh_chem_noisy", "zh", "有机化学", "马超　编", "北京：示例教育出版社", "16k", "g4", 300, 7,
         [("cover",), ("title",), ("copyright",), ("preface", "前言", 1, False), ("toc",), ("pad",)],
         "preface",
         [Level("zh_zhang", (8, 8), "chem_ch", "　", "chapter"), Level("zh_jie", (2, 3), "chem_sec", "　"),
          Level("zh_dun", (0, 2), "generic3", "")],
         [("参考文献", 1)],
         folio="footer-outer", leader="dots", profile="noisy_g4", rotation=1.2, pages_range=(55, 70),
         features=["heavy noise: 1.2 deg skew, blur, speckle, broken strokes, gutter shadow", "第X章/第X节/一、"]),
    Book("zh_proceedings_ranges", "zh", "数字人文研究论文集（2025）", "本书编委会　编", "北京：示例出版社", "16k", "g4", 300,
         13,
         [("cover",), ("blank",), ("title",), ("copyright",), ("intro",), ("blank",), ("preface", "序", 2, True),
          ("preface", "前言", 2, True), ("toc",), ("pad",)],
         "preface",
         [Level("zh_bufen", (4, 4), "proc_part", "　", "chapter"), Level("none", (3, 4), "proc_paper", "")],
         [],
         folio="footer-center", folio_style="dot", leader="ellipsis", page_ranges=True, profile="normal_g4",
         rotation=-0.5, pages_range=(90, 110), resave_objstm=True,
         features=["page ranges '12-15'", "unnumbered papers under 第X部分", "folio '· 12 ·'", "roman 序/前言 entries",
                   "object streams (qpdf re-save)"]),
    Book("zh_finance_small_jpeg", "zh", "家庭理财入门", "高洋　著", "北京：示例工业出版社", "32k", "jpeg", 200, 6,
         [("cover",), ("title",), ("copyright",), ("toc",), ("pad",)],
         "title",
         [Level("zh_dun", (7, 7), "fin_ch", "", "chapter"), Level("zh_paren_hw", (1, 3), "fin_sec", ""),
          Level("ar_dot", (0, 2), "fin_sub", " ")],
         [],
         folio="footer-center", leader="middot", toc_folio=False, toc_heading="目录", profile="jpeg_gray",
         rotation=0.3, cover="color", pages_range=(40, 50),
         features=["一、/(一)/1.", "grayscale JPEG 200 dpi", "TOC page without folio", "smallest book"]),
]

PROFILES = {
    # blur radius px @300dpi, gaussian noise sigma, speckle count per Mpx, threshold, extras
    "clean_g4": dict(blur=0.55, noise=6, speckle=25, thr=138, shadow=False, broken=0.0),
    "normal_g4": dict(blur=0.75, noise=11, speckle=60, thr=134, shadow=False, broken=0.0),
    "noisy_g4": dict(blur=1.15, noise=24, speckle=260, thr=116, shadow=True, broken=0.04),
    "jpeg_gray": dict(blur=0.85, noise=7, speckle=20, thr=None, shadow=False, broken=0.0, quality=62, paper=236,
                      ink=48),
}

TRIMS_MM = {"16k": (185, 260), "32k": (140, 203), "6x9": (152.4, 228.6)}


# ============================================================================
# structure: entries and pagination
# ============================================================================

@dataclass
class Entry:
    level: int
    num: str
    sep: str
    text: str
    kind: str                 # front | part | chapter | section | back
    printed: int | str | None = None
    range_end: int | None = None
    physical: int | None = None
    lines: int = 1            # visual lines in the printed TOC

    @property
    def printed_title(self) -> str:
        return self.num + self.sep + self.text if self.num else self.text

    @property
    def title(self) -> str:
        if not self.num:
            return self.text
        return self.num + (" " if self.sep else "") + self.text


class Pool:
    def __init__(self, rng: random.Random):
        self.rng = rng
        self.left: dict[str, list[str]] = {}

    def draw(self, key: str) -> str:
        if not self.left.get(key):
            items = list(VOCAB[key])
            self.rng.shuffle(items)
            self.left[key] = items
        return self.left[key].pop()


def build_entries(book: Book, rng: random.Random) -> list[Entry]:
    pool = Pool(rng)
    chapter_depth = next(i for i, lv in enumerate(book.levels) if lv.kind == "chapter")
    chapter_no = 0
    out: list[Entry] = []

    # ordered vocab for chapter / part level so a book reads in order
    ordered = {}
    for lv in book.levels[: chapter_depth + 1]:
        ordered[lv.vocab] = list(VOCAB[lv.vocab])

    def rec(depth: int, path: tuple[int, ...]):
        nonlocal chapter_no
        lv = book.levels[depth]
        n = rng.randint(*lv.count)
        for i in range(1, n + 1):
            p = path + (i,)
            if lv.kind == "chapter":
                chapter_no += 1
            if lv.vocab in ordered:
                src = ordered[lv.vocab]
                text = src.pop(0) if src else pool.draw(lv.vocab)
            else:
                text = pool.draw(lv.vocab)
            num = fmt_number(lv.fmt, p, chapter_no, chapter_depth)
            out.append(Entry(depth, num, lv.sep if num else "", text, lv.kind))
            if depth + 1 < len(book.levels):
                rec(depth + 1, p)
            if lv.kind == "chapter" and book.chapter_tail:
                out.append(Entry(depth + 1, "", "", book.chapter_tail, "section"))

    rec(0, ())
    # the deepest level must actually occur
    assert any(e.level == len(book.levels) - 1 for e in out), f"{book.name}: deepest level never generated"
    return out


def paginate(book: Book, body: list[Entry], factor: float, rng: random.Random):
    """Assigns printed pages. Returns (n_body_pages, page_kinds{printed: kind})."""
    kinds: dict[int, str] = {}
    cur = 0
    prev_kind = None
    for idx, e in enumerate(body):
        if e.kind in ("part", "chapter", "back"):
            if e.kind == "chapter" and prev_kind == "part":
                start = cur + 1
            else:
                start = cur + 1 + (rng.choice([0, 1]) if prev_kind == "section" and factor > 1.2 else 0)
            if book.recto_chapters and e.kind in ("chapter", "part") and start % 2 == 0:
                kinds[start] = "blank"
                start += 1
            e.printed = start
            cur = start
            kinds[cur] = {"part": "part", "chapter": "opener", "back": "back"}[e.kind]
            if e.kind == "back":
                cur += e.range_end - 1  # range_end temporarily holds the page count
                for q in range(start + 1, cur + 1):
                    kinds[q] = "back_cont"
                e.range_end = None
        else:
            weights = [0.28, 0.42, 0.2, 0.1]
            adv = rng.choices([0, 1, 2, 3], weights)[0]
            adv = int(round(adv * factor)) if adv else (1 if factor > 2.2 else 0)
            if book.page_ranges:
                adv = max(3, int(round((2 + rng.random() * 3) * factor)))
                if prev_kind != "section":
                    adv = 1
            cur += adv
            e.printed = cur
        prev_kind = e.kind if e.kind != "back" else "back"
    n_body = cur + (0 if body[-1].kind == "back" else max(1, int(round(2 * factor))))
    for q in range(1, n_body + 1):
        kinds.setdefault(q, "text")
    if book.page_ranges:
        secs = [e for e in body if e.kind == "section"]
        for i, e in enumerate(body):
            if e.kind != "section":
                continue
            nxt = next((b.printed for b in body[i + 1:] if b.kind in ("section", "part", "chapter", "back")), None)
            end = (nxt - 1) if nxt is not None else n_body
            if nxt is not None and body[i + 1].kind in ("part", "chapter"):
                end = nxt - 1
            e.range_end = max(e.printed, end)
        assert secs
    return n_body, kinds


# ============================================================================
# geometry and drawing helpers
# ============================================================================

@dataclass
class Geom:
    w: int
    h: int
    dpi: int

    def pt(self, v: float) -> float:
        return v * self.dpi / 72.0


def geometry(book: Book) -> Geom:
    wmm, hmm = TRIMS_MM[book.trim]
    return Geom(int(round(wmm / 25.4 * book.dpi)), int(round(hmm / 25.4 * book.dpi)), book.dpi)


class Page:
    def __init__(self, g: Geom, recto: bool):
        from PIL import Image, ImageDraw
        self.g = g
        self.recto = recto
        self.im = Image.new("L", (g.w, g.h), 255)
        self.d = ImageDraw.Draw(self.im)
        inner, outer = 0.13 * g.w, 0.10 * g.w
        self.left = inner if recto else outer
        self.right = g.w - (outer if recto else inner)
        self.top = 0.105 * g.h
        self.bottom = g.h - 0.10 * g.h
        self.photo = None   # optional RGB cover

    def text(self, x, y, s, fkey, pt, anchor="ls", fill=0):
        if not s:
            return
        check_glyphs(fkey, s)
        self.d.text((x, y), s, font=get_font(fkey, self.g.pt(pt)), anchor=anchor, fill=fill)

    def width(self, s, fkey, pt):
        return get_font(fkey, self.g.pt(pt)).getlength(s)

    def rule(self, x0, x1, y, pt=0.5):
        self.d.line((x0, y, x1, y), fill=0, width=max(1, int(self.g.pt(pt))))


def folio_text(n: int | str, style: str) -> str:
    s = str(n)
    if style == "dash":
        return f"— {s} —"
    if style == "dot":
        return f"· {s} ·"
    return s


def num_font(book: Book) -> str:
    return "times"


def draw_folio(book: Book, pg: Page, text: str, where: str):
    g = pg.g
    fk = "times"
    pt = 9 if book.lang == "zh" else 9.5
    if any(ord(c) > 0x2000 for c in text):
        fk = "song" if book.lang == "zh" else "times"
    if where == "footer-center":
        pg.text(g.w / 2, g.h - 0.055 * g.h, text, fk, pt, anchor="ms")
    elif where == "footer-outer":
        if pg.recto:
            pg.text(pg.right, g.h - 0.055 * g.h, text, fk, pt, anchor="rs")
        else:
            pg.text(pg.left, g.h - 0.055 * g.h, text, fk, pt, anchor="ls")
    elif where == "header-outer":
        y = 0.07 * g.h
        if pg.recto:
            pg.text(pg.right, y, text, fk, pt, anchor="rs")
        else:
            pg.text(pg.left, y, text, fk, pt, anchor="ls")
    else:
        raise ValueError(where)


def draw_running_head(book: Book, pg: Page, text: str, with_folio_in_header: bool):
    g = pg.g
    y = 0.07 * g.h
    fk = "song" if book.lang == "zh" else "times"
    pt = 8.5 if book.lang == "zh" else 9
    # keep the running head short enough for the line
    while text and pg.width(text, fk, pt) > (pg.right - pg.left) * 0.62:
        text = text[:-1]
    if with_folio_in_header:
        # folio at the outer corner is drawn by draw_folio; the head sits at the inner side
        if pg.recto:
            pg.text(pg.left, y, text, fk, pt, anchor="ls")
        else:
            pg.text(pg.right, y, text, fk, pt, anchor="rs")
    else:
        pg.text(g.w / 2, y, text, fk, pt, anchor="ms")
    pg.rule(pg.left, pg.right, y + g.pt(4.5), 0.6)


def wrap_body(book: Book, pg: Page, text: str, fk: str, pt: float, width: float, indent_first: float) -> list:
    lines = []
    if book.lang == "zh":
        f = get_font(fk, pg.g.pt(pt))
        cur, cur_w, first = "", indent_first, True
        for ch in text:
            cw = f.getlength(ch)
            if cur_w + cw > width and cur:
                lines.append((cur, first))
                cur, cur_w, first = "", 0.0, False
            cur += ch
            cur_w += cw
        if cur:
            lines.append((cur, first))
    else:
        f = get_font(fk, pg.g.pt(pt))
        cur, first = "", True
        for word in text.split():
            cand = (cur + " " + word) if cur else word
            limit = width - (indent_first if first else 0)
            if f.getlength(cand) > limit and cur:
                lines.append((cur, first))
                cur, first = word, False
            else:
                cur = cand
        if cur:
            lines.append((cur, first))
    return lines


def filler_paragraphs(book: Book, rng: random.Random, n_sent: int) -> str:
    src = ZH_SENT if book.lang == "zh" else EN_SENT
    sents = [rng.choice(src) for _ in range(n_sent)]
    return ("" if book.lang == "zh" else " ").join(sents)


# ============================================================================
# printed TOC
# ============================================================================

LEADER_TEXT = {"ellipsis": "……", "middot": "·····", "dots": "......", "spaced_dots": ". . . . .", "dash": "——",
               "none": ""}


def page_text(book: Book, e: Entry) -> str:
    if isinstance(e.printed, str):
        return e.printed
    s = str(e.printed)
    if e.range_end and e.range_end > e.printed:
        s = f"{e.printed}-{e.range_end}"
    if book.fullwidth_digits:
        s = s.translate(FULLWIDTH)
    return s


def toc_fonts(book: Book, level: int, depth_levels: int):
    base = book.toc_size_pt
    if book.lang == "en":
        if level == 0:
            return "times_bold", base + 0.5
        if level == 1 and depth_levels >= 3:
            return "times_bold", base
        return "times", base
    if level == 0:
        return "hei_bold", base + 1.0
    return "song", base


def split_title(book: Book, pg: Page, title: str, fk: str, pt: float, first_w: float, rest_w: float) -> list[str]:
    f = get_font(fk, pg.g.pt(pt))
    if f.getlength(title) <= first_w:
        return [title]
    pieces = []
    if book.lang == "en":
        words = title.split(" ")
        cur = ""
        limit = first_w
        for w_ in words:
            cand = (cur + " " + w_) if cur else w_
            if f.getlength(cand) > limit and cur:
                pieces.append(cur)
                cur, limit = w_, rest_w
            else:
                cur = cand
        pieces.append(cur)
        return pieces
    cur, limit = "", first_w
    no_start = set("，。、）：；”》")
    for ch in title:
        if f.getlength(cur + ch) > limit and cur and ch not in no_start:
            pieces.append(cur)
            cur, limit = "", rest_w
        cur += ch
    pieces.append(cur)
    return pieces


def draw_leader(pg: Page, style: str, x0: float, x1: float, y: float, fk: str, pt: float):
    if style == "none" or x1 - x0 <= 0:
        return
    g = pg.g
    if style == "ellipsis":
        unit = "…"
        wu = pg.width(unit, "song", pt)
        n = int((x1 - x0) // wu)
        if n > 0:
            pg.text(x1, y, unit * n, "song", pt, anchor="rs")
    elif style == "dash":
        unit = "—"
        wu = pg.width(unit, "song", pt)
        n = int((x1 - x0) // wu)
        if n > 0:
            pg.text(x1, y, unit * n, "song", pt, anchor="rs")
    else:
        dot = {"middot": "·", "dots": ".", "spaced_dots": "."}[style]
        fkd = "song" if style == "middot" else "times"
        pitch = g.pt(pt) * {"middot": 0.5, "dots": 0.33, "spaced_dots": 0.55}[style]
        # dots sit on a global grid so columns of leaders line up, as typeset leaders do
        start = math.ceil(x0 / pitch) * pitch
        xs = []
        x = start
        while x + pitch <= x1:
            xs.append(x)
            x += pitch
        for x in xs:
            pg.text(x, y, dot, fkd, pt, anchor="ls")


@dataclass
class TocLine:
    entry_idx: int
    level: int
    piece: str
    last: bool
    x_indent: float
    height: float
    extra_before: float


def typeset_toc(book: Book, entries: list[Entry], g: Geom, recto_first: bool):
    """Lays out the printed TOC. Returns a list of page draw-callables and transcript lines per page."""
    depth_levels = max(e.level for e in entries) + 1
    probe = Page(g, True)
    margin = 0.12 * g.w
    left, right = margin, g.w - margin
    cols = [(left, right)]
    if book.toc_twocol:
        gap = 0.05 * g.w
        mid = (left + right) / 2
        cols = [(left, mid - gap / 2), (mid + gap / 2, right)]
    colw = cols[0][1] - cols[0][0]
    base_px = g.pt(book.toc_size_pt)
    # build visual lines
    vlines: list[TocLine] = []
    for idx, e in enumerate(entries):
        fk, pt = toc_fonts(book, e.level, depth_levels)
        indent = e.level * book.toc_indent_em * base_px
        ptxt = page_text(book, e)
        nfk = "song" if book.fullwidth_digits else book.toc_num_font
        wnum = max(probe.width(ptxt, nfk, pt), probe.width("000", nfk, pt))
        reserve = wnum + 2.2 * g.pt(pt)
        first_w = colw - indent - reserve
        hang = probe.width(e.num + e.sep, fk, pt) if e.num else 1.0 * g.pt(pt)
        rest_w = colw - indent - hang - reserve
        pieces = split_title(book, probe, e.printed_title, fk, pt, first_w, rest_w)
        e.lines = len(pieces)
        for k, piece in enumerate(pieces):
            vlines.append(TocLine(idx, e.level, piece, k == len(pieces) - 1, indent + (hang if k else 0),
                                  g.pt(pt) * book.toc_line_factor,
                                  (g.pt(pt) * 0.55 if (k == 0 and e.level == 0 and idx > 0) else 0.0)))
    # paginate into columns/pages; keep an entry's lines together
    pages = []   # list of list of (col, y_baseline, TocLine)
    heading_space = 0.20 * g.h
    top_other = 0.11 * g.h
    bottom = g.h - 0.11 * g.h
    page, col, y = [], 0, heading_space
    i = 0
    while i < len(vlines):
        j = i
        while not vlines[j].last:
            j += 1
        block = vlines[i:j + 1]
        need = sum(v.height + v.extra_before for v in block)
        if y + need > bottom:
            if col + 1 < len(cols):
                col += 1
                y = heading_space if not pages else top_other
            else:
                pages.append(page)
                page, col, y = [], 0, top_other
        for v in block:
            y += v.extra_before + v.height
            page.append((col, y, v))
        i = j + 1
    if page:
        pages.append(page)

    def make_drawer(page_items, first: bool):
        def draw(pg: Page):
            if first:
                fk = "hei_bold" if book.lang == "zh" else "times_bold"
                pg.text(g.w / 2, 0.14 * g.h, book.toc_heading, fk, 18 if book.lang == "zh" else 20, anchor="ms")
            for col_i, yb, v in page_items:
                cx0, cx1 = cols[col_i]
                e = entries[v.entry_idx]
                fk, pt = toc_fonts(book, e.level, depth_levels)
                x = cx0 + v.x_indent
                pg.text(x, yb, v.piece, fk, pt, anchor="ls")
                if v.last:
                    ptxt = page_text(book, e)
                    nfk = "song" if book.fullwidth_digits else book.toc_num_font
                    pg.text(cx1, yb, ptxt, nfk, pt, anchor="rs")
                    style = book.leader_level0 if (e.level == 0 and book.leader_level0) else book.leader
                    tw = pg.width(v.piece, fk, pt)
                    x0 = x + tw + 0.45 * g.pt(pt)
                    x1 = cx1 - pg.width(ptxt, nfk, pt) - 0.45 * g.pt(pt)
                    draw_leader(pg, style, x0, x1, yb, fk, pt)
        return draw

    def transcript(page_items, first: bool) -> list[str]:
        out = [book.toc_heading.replace("　", " ")] if first else []
        by_col: dict[int, list] = {}
        for col_i, yb, v in page_items:
            by_col.setdefault(col_i, []).append(v)
        for col_i in sorted(by_col):
            for v in by_col[col_i]:
                e = entries[v.entry_idx]
                s = "  " * e.level + v.piece.replace("　", " ").replace("  ", " ")
                if v.last:
                    style = book.leader_level0 if (e.level == 0 and book.leader_level0) else book.leader
                    lead = LEADER_TEXT[style]
                    s += (" " + lead + " " if lead else " ") + page_text(book, e)
                out.append(s)
        return out

    drawers = [make_drawer(p, k == 0) for k, p in enumerate(pages)]
    scripts = [transcript(p, k == 0) for k, p in enumerate(pages)]
    return drawers, scripts


# ============================================================================
# page renderers
# ============================================================================

def render_cover(book: Book, g: Geom, rng: random.Random):
    from PIL import Image, ImageDraw
    pg = Page(g, True)
    tfk = "hei_bold" if book.lang == "zh" else "times_bold"
    fk = "song" if book.lang == "zh" else "times"
    if book.cover == "color":
        palette = [(122, 32, 38), (22, 64, 110), (28, 92, 70), (140, 96, 30)]
        bg = palette[zlib.crc32(book.name.encode()) % len(palette)]
        im = Image.new("RGB", (g.w, g.h), (238, 232, 220))
        d = ImageDraw.Draw(im)
        d.rectangle((0, int(0.18 * g.h), g.w, int(0.52 * g.h)), fill=bg)
        check_glyphs(tfk, book.title)
        d.text((g.w / 2, 0.36 * g.h), book.title, font=get_font(tfk, g.pt(30 if book.lang == "zh" else 26)),
               anchor="ms", fill=(250, 245, 235))
        check_glyphs(fk, book.author)
        d.text((g.w / 2, 0.62 * g.h), book.author, font=get_font(fk, g.pt(14)), anchor="ms", fill=(40, 30, 30))
        d.text((g.w / 2, 0.9 * g.h), book.publisher, font=get_font(fk, g.pt(12)), anchor="ms", fill=(40, 30, 30))
        pg.photo = im
        return pg
    pg.d.rectangle((int(0.08 * g.w), int(0.08 * g.h), int(0.92 * g.w), int(0.12 * g.h)), fill=0)
    pg.text(g.w / 2, 0.34 * g.h, book.title, tfk, 30 if book.lang == "zh" else 26, anchor="ms")
    pg.text(g.w / 2, 0.6 * g.h, book.author, fk, 14, anchor="ms")
    pg.text(g.w / 2, 0.9 * g.h, book.publisher, fk, 12, anchor="ms")
    return pg


def render_front_simple(book: Book, g: Geom, kind: str, recto: bool, rng: random.Random, folio: str | None):
    pg = Page(g, recto)
    fk = "song" if book.lang == "zh" else "times"
    tfk = "hei_bold" if book.lang == "zh" else "times_bold"
    if kind in ("title", "halftitle"):
        pg.text(g.w / 2, 0.3 * g.h, book.title, tfk, 24 if book.lang == "zh" else 22, anchor="ms")
        if kind == "title":
            pg.text(g.w / 2, 0.45 * g.h, book.author, fk, 13, anchor="ms")
            pg.text(g.w / 2, 0.85 * g.h, book.publisher, fk, 12, anchor="ms")
    elif kind == "copyright":
        if book.lang == "zh":
            isbn = f"ISBN 978-7-{rng.randint(100, 999)}-{rng.randint(10000, 99999)}-{rng.randint(0, 9)}"
            lines = ["图书在版编目（CIP）数据", f"{book.title} / {book.author.split('　')[0]}. —{book.publisher[:2]}：",
                     f"{book.publisher[3:]}，2024.{rng.randint(1, 12)}", isbn, "",
                     f"中国版本图书馆CIP数据核字（2024）第{rng.randint(100000, 299999)}号", "",
                     f"开本 787mm×1092mm 1/{16 if book.trim == '16k' else 32}　印张 {rng.randint(8, 25)}.5",
                     f"字数 {rng.randint(200, 600)}千字", "2024年9月第1版　2024年9月第1次印刷",
                     f"定价 {rng.randint(28, 89)}.00元"]
        else:
            lines = [f"Copyright © 2024 {book.author}", "All rights reserved.", "",
                     f"ISBN 978-1-{rng.randint(1000, 9999)}-{rng.randint(1000, 9999)}-{rng.randint(0, 9)}",
                     f"Printed in 2024. First edition, {rng.randint(1, 9)} 8 7 6 5 4 3 2 1",
                     "No part of this book may be reproduced without permission."]
        y = 0.52 * g.h
        # Everything on this page is made up; say so (drawn above the block so nothing else moves).
        pg.text(pg.left, y - g.pt(30), "本书为测试用虚构图书，书号和CIP数据均为虚构" if book.lang == "zh"
                else "A fictional book made for software testing; the ISBN is made up.", fk, 9, anchor="ls")
        for ln in lines:
            pg.text(pg.left, y, ln, fk, 9, anchor="ls")
            y += g.pt(15)
    elif kind == "intro":
        head = "内容简介" if book.lang == "zh" else "About this book"
        pg.text(g.w / 2, 0.2 * g.h, head, tfk, 14, anchor="ms")
        para = filler_paragraphs(book, rng, 7)
        y = 0.28 * g.h
        for ln, first in wrap_body(book, pg, para, fk, 10.5, pg.right - pg.left, g.pt(21)):
            pg.text(pg.left + (g.pt(21) if first else 0), y, ln, fk, 10.5)
            y += g.pt(18)
    elif kind == "dedication":
        pg.text(g.w / 2, 0.3 * g.h, "For the people who keep the lights on.", "times", 12, anchor="ms")
    if folio:
        draw_folio(book, pg, folio, "footer-center")
    return pg


def render_text_page(book: Book, g: Geom, recto: bool, rng: random.Random, heading: str | None,
                     start_entries: list[Entry], running: str | None, folio: str | None, folio_where: str,
                     page_kind: str, top_heading_size: float = 16):
    pg = Page(g, recto)
    fk = book.body_font
    tfk = "hei_bold" if book.lang == "zh" else "times_bold"
    body_pt = 10.5
    lead = g.pt(body_pt) * (1.75 if book.lang == "zh" else 1.45)
    y = pg.top
    if running is not None:
        draw_running_head(book, pg, running, folio_where == "header-outer")
    if folio:
        draw_folio(book, pg, folio, folio_where)
    if heading is not None:  # preface / back matter heading
        y = pg.top + 0.08 * g.h
        pg.text(g.w / 2, y, heading, tfk, 16, anchor="ms")
        y += g.pt(34)
    blocks = list(start_entries)
    opener = blocks and blocks[0].kind in ("chapter", "back")
    if opener:
        e = blocks.pop(0)
        y = pg.top + 0.1 * g.h
        if book.heading_style == "two-line" and e.num:
            pg.text(g.w / 2, y, e.num, tfk, 18, anchor="ms")
            y += g.pt(30)
            y = draw_heading_lines(book, pg, e.text, tfk, 18, y, center=True)
        else:
            y = draw_heading_lines(book, pg, e.printed_title, tfk, 18 if book.lang == "zh" else 17, y, center=True)
        y += g.pt(26)
    capacity = int((pg.bottom - y) // lead)
    n_head = len(blocks)
    free = max(0, capacity - 3 * n_head)
    gaps = [rng.random() + 0.15 for _ in range(n_head + 1)]
    if not opener and heading is None and n_head:
        gaps[0] = gaps[0] * 0.8 + 0.2
    total = sum(gaps)
    counts = [int(free * x / total) for x in gaps]
    for k in range(n_head + 1):
        n = counts[k]
        if n > 0:
            para = filler_paragraphs(book, rng, max(2, n * (2 if book.lang == "zh" else 1)))
            lines = wrap_body(book, pg, para, fk, body_pt, pg.right - pg.left, g.pt(21))
            for ln, first in lines[:n]:
                if y + lead > pg.bottom:
                    break
                y += lead
                pg.text(pg.left + (g.pt(21) if first and book.lang == "zh" else 0), y, ln, fk, body_pt)
            # an occasional figure box
            if n >= 10 and rng.random() < 0.18 and y + 0.2 * g.h < pg.bottom:
                y += g.pt(10)
                bw, bh = (pg.right - pg.left) * 0.6, 0.14 * g.h
                bx = (pg.left + pg.right - bw) / 2
                pg.d.rectangle((bx, y, bx + bw, y + bh), outline=0, width=max(2, int(g.pt(0.8))))
                for _ in range(6):
                    xa, ya = bx + rng.random() * bw, y + rng.random() * bh
                    xb, yb = bx + rng.random() * bw, y + rng.random() * bh
                    pg.d.line((xa, ya, xb, yb), fill=0, width=max(2, int(g.pt(0.8))))
                y += bh + g.pt(14)
                cap = f"图{rng.randint(1, 9)}-{rng.randint(1, 9)}　示意图" if book.lang == "zh" else \
                    f"Figure {rng.randint(1, 12)}.{rng.randint(1, 9)} Overview"
                pg.text(g.w / 2, y, cap, fk, 9, anchor="ms")
                y += g.pt(8)
        if k < n_head:
            e = blocks[k]
            size = {1: 13, 2: 11.5, 3: 10.5}.get(e.level if book.levels[0].kind != "part" else e.level - 1, 11)
            if e.kind == "part":
                size = 20
            y += g.pt(size) * 1.9
            if y > pg.bottom - g.pt(size):
                y = pg.bottom - g.pt(size)
            y = draw_heading_lines(book, pg, e.printed_title, tfk, size, y, center=False) + g.pt(size) * 0.6
    return pg


def draw_heading_lines(book, pg: Page, text: str, fk: str, pt: float, y: float, center: bool) -> float:
    g = pg.g
    width = pg.right - pg.left
    pieces = split_title(book, pg, text, fk, pt, width, width)
    for k, piece in enumerate(pieces):
        if k:
            y += g.pt(pt) * 1.5
        if center:
            pg.text(g.w / 2, y, piece, fk, pt, anchor="ms")
        else:
            pg.text(pg.left, y, piece, fk, pt, anchor="ls")
    return y


def render_part_page(book: Book, g: Geom, recto: bool, e: Entry, folio: str | None):
    pg = Page(g, recto)
    tfk = "hei_bold" if book.lang == "zh" else "times_bold"
    pg.text(g.w / 2, 0.38 * g.h, e.num, tfk, 22, anchor="ms")
    pg.text(g.w / 2, 0.38 * g.h + g.pt(40), e.text, tfk, 22, anchor="ms")
    if folio:
        draw_folio(book, pg, folio, book.folio)
    return pg


def render_back_page(book: Book, g: Geom, recto: bool, rng: random.Random, e: Entry | None, cont: bool,
                     running: str | None, folio: str | None, idx_state: dict):
    pg = Page(g, recto)
    fk = book.body_font
    tfk = "hei_bold" if book.lang == "zh" else "times_bold"
    if running is not None:
        draw_running_head(book, pg, running, book.folio == "header-outer")
    if folio:
        draw_folio(book, pg, folio, book.folio)
    y = pg.top
    title = e.text if e is not None else idx_state.get("title", "")
    if e is not None:
        y = pg.top + 0.1 * g.h
        pg.text(g.w / 2, y, e.printed_title, tfk, 18, anchor="ms")
        y += g.pt(36)
        idx_state["title"] = e.text
        idx_state["n"] = 0
    kind = "refs" if any(k in title for k in ("参考文献", "Bibliography")) else \
        "index" if any(k in title for k in ("索引", "Index")) else "text"
    lead = g.pt(10) * 1.7
    while y + lead < pg.bottom:
        y += lead
        idx_state["n"] = idx_state.get("n", 0) + 1
        n = idx_state["n"]
        if kind == "refs":
            if book.lang == "zh":
                au = rng.choice(SURNAMES) + rng.choice(GIVEN) + (rng.choice(GIVEN) if rng.random() < .5 else "")
                ln = f"[{n}] {au}. {rng.choice(VOCAB['econ_sec'])}研究[M]. {rng.choice(PUBLISHERS)}，" \
                     f"{rng.randint(1985, 2023)}：{rng.randint(1, 200)}-{rng.randint(201, 400)}."
            else:
                ln = f"[{n}] Author, A. ({rng.randint(1985, 2023)}). {rng.choice(VOCAB['sys_ch'])}. " \
                     f"Journal of Systems, {rng.randint(1, 60)}({rng.randint(1, 12)}), {rng.randint(1, 300)}-" \
                     f"{rng.randint(301, 600)}."
            pg.text(pg.left, y, ln, fk, 9)
        elif kind == "index":
            voc = VOCAB["econ_sec"] if book.lang == "zh" else VOCAB["sys_sec"]
            half = (pg.right - pg.left) / 2
            for c in range(2):
                t = rng.choice(voc)
                pnums = ", ".join(str(rng.randint(1, 99)) for _ in range(rng.randint(1, 3)))
                s = f"{t} {pnums}"
                while pg.width(s, fk, 9) > half - g.pt(8) and len(t) > 2:
                    t = t[:-1]
                    s = f"{t} {pnums}"
                pg.text(pg.left + c * half, y, s, fk, 9)
        else:
            para = filler_paragraphs(book, rng, 2)
            lines = wrap_body(book, pg, para, fk, 10.5, pg.right - pg.left, 0)
            pg.text(pg.left, y, lines[0][0], fk, 10.5)
    return pg


def render_back_cover(book: Book, g: Geom, rng: random.Random):
    pg = Page(g, False)
    x0 = int(0.62 * g.w)
    y0 = int(0.82 * g.h)
    x = x0
    while x < int(0.88 * g.w):
        wbar = rng.choice([2, 3, 4, 6])
        pg.d.rectangle((x, y0, x + wbar, y0 + int(0.06 * g.h)), fill=0)
        x += wbar + rng.choice([3, 4, 6])
    fk = "song" if book.lang == "zh" else "times"
    price = f"定价：{rng.randint(28, 89)}.00元" if book.lang == "zh" else f"US ${rng.randint(20, 60)}.99"
    pg.text(x0, y0 + int(0.09 * g.h), price, fk, 10)
    return pg


# ============================================================================
# scan degradation + encoding
# ============================================================================

def degrade(pg: Page, book: Book, rng: random.Random, seed: int) -> tuple[bytes, str]:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
    prof = PROFILES[book.profile]
    nrng = np.random.default_rng(seed)
    g = pg.g
    scale = g.dpi / 300.0
    sign = 1 if book.rotation >= 0 else -1
    if rng.random() < 0.3:
        sign = -sign
    ang = sign * min(1.2, max(0.3, abs(book.rotation) * rng.uniform(0.85, 1.15)))
    shift = (rng.randint(-18, 18) * scale, rng.randint(-14, 14) * scale)
    if pg.photo is not None:  # color cover, JPEG
        im = pg.photo.rotate(ang, resample=Image.BICUBIC, translate=shift, fillcolor=(245, 245, 245))
        im = im.filter(ImageFilter.GaussianBlur(0.8 * scale))
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=78, dpi=(g.dpi, g.dpi))
        return buf.getvalue(), "jpeg-rgb"
    im = pg.im.rotate(ang, resample=Image.BICUBIC, translate=shift, fillcolor=255)
    if prof["blur"]:
        im = im.filter(ImageFilter.GaussianBlur(prof["blur"] * scale))
    a = np.asarray(im, dtype=np.float32)
    if prof["thr"] is None:  # grayscale scan: paper tone, ink tone, uneven light
        paper, ink = prof["paper"], prof["ink"]
        a = ink + (a / 255.0) * (paper - ink)
        yy = np.linspace(0, 1, g.h, dtype=np.float32)[:, None]
        xx = np.linspace(0, 1, g.w, dtype=np.float32)[None, :]
        light = 1.0 - 0.06 * (xx - rng.random()) ** 2 - 0.05 * (yy - rng.random()) ** 2
        a = a * light
    a += nrng.normal(0, prof["noise"], a.shape).astype(np.float32)
    if prof["shadow"]:
        wshadow = int(rng.uniform(40, 90) * scale)
        ramp = np.linspace(170, 0, wshadow, dtype=np.float32)
        if pg.recto:
            a[:, :wshadow] -= ramp[None, :]
        else:
            a[:, -wshadow:] -= ramp[::-1][None, :]
    if prof["thr"] is not None:
        thr = prof["thr"] + rng.uniform(-6, 6)
        bw = a >= thr  # True = white
        if prof["broken"]:
            drop = nrng.random(bw.shape) < prof["broken"]
            bw = bw | drop
        out = Image.fromarray((bw * 255).astype(np.uint8), mode="L").convert("1", dither=Image.Dither.NONE)
        d = ImageDraw.Draw(out)
        n_speck = int(prof["speckle"] * g.w * g.h / 1e6)
        for _ in range(n_speck):
            x, y = rng.randrange(g.w), rng.randrange(g.h)
            r = rng.choice((1, 1, 2, 2, 3, 4))
            d.ellipse((x, y, x + r, y + r), fill=0)
        buf = io.BytesIO()
        out.save(buf, format="TIFF", compression="group4", dpi=(g.dpi, g.dpi))
        return buf.getvalue(), "g4"
    a = np.clip(a, 0, 255).astype(np.uint8)
    out = Image.fromarray(a, mode="L")
    d = ImageDraw.Draw(out)
    n_speck = int(prof["speckle"] * g.w * g.h / 1e6)
    for _ in range(n_speck):
        x, y = rng.randrange(g.w), rng.randrange(g.h)
        r = rng.choice((1, 1, 2, 3))
        d.ellipse((x, y, x + r, y + r), fill=rng.randint(40, 120))
    buf = io.BytesIO()
    out.save(buf, format="JPEG", quality=prof["quality"], dpi=(g.dpi, g.dpi))
    return buf.getvalue(), "jpeg-gray"


# ============================================================================
# assembling a book
# ============================================================================

def build_book(book: Book, out: Path, preview: Path | None = None) -> dict:
    import img2pdf
    import pikepdf
    t0 = time.time()
    seed = zlib.crc32(book.name.encode())
    g = geometry(book)

    # ---- structure
    rng = random.Random(seed)
    body = build_entries(book, rng)
    back_entries = [Entry(0, "", "", t, "back") for t, _ in book.back]
    for be, (_, npages) in zip(back_entries, book.back):
        be.range_end = npages  # page count, consumed by paginate
    # split "附录A 常用协议端口号" style titles into number + text for printing
    for be in back_entries:
        for pre in ("附录A", "附录B", "Appendix A", "Appendix B"):
            if be.text.startswith(pre + " "):
                be.num, be.sep, be.text = pre, (" " if pre.startswith("A") else "　"), be.text[len(pre) + 1:]
    body_all = body + back_entries
    back_pages = {id(be): n for be, (_, n) in zip(back_entries, book.back)}

    chosen = None
    for attempt, factor in enumerate([1.0, 1.15, 0.9, 1.3, 0.8, 1.5, 0.7, 1.75, 0.6, 2.0, 2.4, 2.8, 0.5]):
        for be in back_entries:
            be.range_end = back_pages[id(be)]
        prng = random.Random(seed * 31 + attempt)
        n_body, kinds = paginate(book, body_all, factor, prng)
        total = book.offset + n_body + (1 if book.back_cover else 0)
        if book.pages_range[0] <= total <= book.pages_range[1]:
            chosen = (factor, n_body, kinds)
            break
    if chosen is None:
        raise SystemExit(f"{book.name}: could not paginate into {book.pages_range} pages (last total {total})")
    factor, n_body, kinds = chosen

    # ---- front matter entries (roman) and the printed TOC
    front_entries: list[Entry] = []
    for item in book.front:
        if item[0] in ("preface", "ack") and item[3]:
            front_entries.append(Entry(0, "", "", item[1], "front"))
    entries = front_entries + body_all

    # the TOC's page count depends on its layout; lay it out once to learn it
    drawers, scripts = typeset_toc(book, entries, g, True)
    n_toc = len(drawers)

    # physical layout of the front matter
    fixed = sum(it[2] if it[0] in ("preface", "ack") else (n_toc if it[0] == "toc" else (0 if it[0] == "pad" else 1))
                for it in book.front)
    pad = book.offset - fixed
    if pad < 0:
        raise SystemExit(f"{book.name}: front matter needs {fixed} pages but offset is {book.offset} "
                         f"(TOC has {n_toc} pages)")
    if pad and not any(it[0] == "pad" for it in book.front):
        raise SystemExit(f"{book.name}: {pad} pages short of offset {book.offset} and no pad item")
    front_pages: list[tuple[str, object]] = []   # (kind, detail)
    for it in book.front:
        k = it[0]
        if k in ("preface", "ack"):
            for q in range(it[2]):
                front_pages.append((k, (it[1], q)))
        elif k == "toc":
            for q in range(n_toc):
                front_pages.append(("toc", q))
        elif k == "pad":
            for _ in range(pad):
                front_pages.append(("blank", None))
        else:
            front_pages.append((k, None))
    assert len(front_pages) == book.offset
    roman_start = next(i for i, (k, _) in enumerate(front_pages) if k == book.roman_from) + 1  # physical, 1-based
    front_matter_offset = roman_start - 1

    # printed roman pages of front entries
    fe_iter = iter(front_entries)
    seen = set()
    for i, (k, det) in enumerate(front_pages):
        if k in ("preface", "ack") and det[1] == 0:
            item = next(it for it in book.front if it[0] == k and it[1] == det[0])
            if item[3] and det[0] not in seen:
                e = next(fe_iter)
                assert e.text == det[0]
                e.printed = roman(i + 1 - front_matter_offset)
                seen.add(det[0])
    # re-typeset now that roman page labels are known (widths may change, page count must not)
    drawers, scripts = typeset_toc(book, entries, g, True)
    assert len(drawers) == n_toc, f"{book.name}: TOC page count changed on re-layout"

    # physical pages of every entry
    for e in entries:
        if isinstance(e.printed, str):
            v = roman_value(e.printed)
            e.physical = v + front_matter_offset
        else:
            e.physical = e.printed + book.offset
    # sanity: non-decreasing printed pages among arabic entries and physical pages overall
    phys = [e.physical for e in entries]
    assert phys == sorted(phys), f"{book.name}: physical pages not monotonic"

    # ---- render every physical page
    blobs: list[bytes] = []
    encodings: list[str] = []
    folios: dict[int, str | None] = {}
    toc_physical: list[int] = []
    rng_r = random.Random(seed ^ 0x5EED)
    page_no = 0

    def emit(pg: Page, folio: str | None):
        nonlocal page_no
        page_no += 1
        data, enc = degrade(pg, book, rng_r, seed * 1000 + page_no)
        blobs.append(data)
        encodings.append(enc)
        folios[page_no] = folio
        if preview is not None and (page_no in preview_pages):
            from PIL import Image
            im = Image.open(io.BytesIO(data)).convert("L")
            im.thumbnail((1100, 1600))
            im.save(preview / f"{book.name}_p{page_no:03d}.png")

    toc_start_phys = next(i for i, (k, _) in enumerate(front_pages) if k == "toc") + 1
    preview_pages = set(range(toc_start_phys, toc_start_phys + n_toc)) | {book.offset + 3, book.offset + 4}

    for i, (k, det) in enumerate(front_pages):
        phys_no = i + 1
        recto = phys_no % 2 == 1
        rom = roman(phys_no - front_matter_offset) if phys_no > front_matter_offset else None
        if k == "cover":
            emit(render_cover(book, g, rng_r), None)
        elif k == "blank":
            emit(Page(g, recto), None)
        elif k in ("title", "halftitle", "copyright", "dedication"):
            emit(render_front_simple(book, g, k, recto, rng_r, None), None)
        elif k == "intro":
            f = folio_text(rom, "plain") if rom else None
            emit(render_front_simple(book, g, "intro", recto, rng_r, f), f)
        elif k in ("preface", "ack"):
            name, q = det
            f = rom
            pg = render_text_page(book, g, recto, rng_r, name if q == 0 else None, [], None, f, "footer-center",
                                  "front")
            emit(pg, f)
        elif k == "toc":
            toc_physical.append(phys_no)
            pg = Page(g, recto)
            drawers[det](pg)
            f = rom if (book.toc_folio and rom) else None
            if f:
                draw_folio(book, pg, f, "footer-center")
            emit(pg, f)

    by_page: dict[int, list[Entry]] = {}
    for e in body_all:
        by_page.setdefault(e.printed, []).append(e)
    current_chapter = ""
    idx_state: dict = {}
    for q in range(1, n_body + 1):
        phys_no = book.offset + q
        recto = q % 2 == 1
        kind = kinds[q]
        starts = by_page.get(q, [])
        for e in starts:
            if e.kind == "chapter":
                current_chapter = e.printed_title.replace("　", " ")
        f_text = folio_text(q, book.folio_style)
        running = None
        if book.running_head:
            running = book.title if not recto else current_chapter
        if kind == "blank":
            emit(Page(g, recto), None)
            continue
        if kind == "part":
            e = starts[0]
            f = f_text if book.part_folio else None
            emit(render_part_page(book, g, recto, e, f), f)
            continue
        if kind in ("back", "back_cont"):
            be = starts[0] if (starts and starts[0].kind == "back") else None
            if be is not None:
                current_chapter = be.printed_title
            f = f_text
            where_running = None if be is not None else running
            emit(render_back_page(book, g, recto, rng_r, be, be is None, where_running, f, idx_state), f)
            continue
        folio_where = book.folio
        f = f_text
        if kind == "opener":
            running = None
            if book.opener_folio == "none":
                f = None
            elif book.opener_folio == "footer-center":
                folio_where = "footer-center"
                f = folio_text(q, "plain")
        pg = render_text_page(book, g, recto, rng_r, None, starts, running, f, folio_where, kind)
        emit(pg, f)
    if book.back_cover:
        emit(render_back_cover(book, g, rng_r), None)

    n_pages = len(blobs)
    assert n_pages == book.offset + n_body + (1 if book.back_cover else 0)
    assert book.pages_range[0] <= n_pages <= book.pages_range[1]
    assert 40 <= n_pages <= 120

    # ---- PDF
    pdf_bytes = img2pdf.convert(blobs, nodate=True, title=book.title, author=book.author.replace("　", " "),
                                creator="mulu make_books.py", engine=img2pdf.Engine.internal)
    pdf_path = out / f"{book.name}.pdf"
    pdf_path.write_bytes(pdf_bytes)
    if book.resave_objstm:
        with pikepdf.open(pdf_path, allow_overwriting_input=True) as pdf:
            pdf.save(pdf_path, object_stream_mode=pikepdf.ObjectStreamMode.generate, deterministic_id=True)
    with pikepdf.open(pdf_path) as pdf:
        assert len(pdf.pages) == n_pages, (len(pdf.pages), n_pages)
        for pg_i, pgo in enumerate(pdf.pages):
            imgs = [v for _, v in pgo.images.items()]
            assert len(imgs) == 1
            filt = imgs[0].get("/Filter")
            want = "/CCITTFaxDecode" if encodings[pg_i] == "g4" else "/DCTDecode"
            got = str(filt[0] if isinstance(filt, pikepdf.Array) else filt)
            assert got == want, f"{book.name} page {pg_i + 1}: filter {got}, want {want}"

    # ---- sidecars
    truth_entries = []
    for e in entries:
        truth_entries.append({
            "title": e.title,
            "level": e.level,
            "printed_page": e.printed,
            "printed_page_text": page_text(book, e),
            "physical_page": e.physical,
            "front_matter": isinstance(e.printed, str),
            "toc_lines": e.lines,
        })
    toc_pages_arg = f"{toc_physical[0]}-{toc_physical[-1]}" if len(toc_physical) > 1 else str(toc_physical[0])
    truth = {
        "book": book.name,
        "title": book.title,
        "language": book.lang,
        "pages": n_pages,
        "offset": book.offset,
        "front_matter_offset": front_matter_offset,
        "toc_pages": toc_physical,
        "toc_pages_arg": toc_pages_arg,
        "folio_position": book.folio,
        "folio_style": book.folio_style,
        "first_body_physical": book.offset + 1,
        "levels": max(e.level for e in entries) + 1,
        "features": book.features,
        "entries": truth_entries,
        "folios": {str(k): v for k, v in folios.items()},
        "render": {
            "trim": book.trim, "size_px": [g.w, g.h], "dpi": g.dpi, "mode": book.mode, "profile": book.profile,
            "profile_params": PROFILES[book.profile], "rotation_deg_nominal": book.rotation,
            "encodings": sorted(set(encodings)), "object_streams": book.resave_objstm,
            "fonts": dict(sorted(FONTS_USED.items())), "pagination_factor": factor,
        },
    }
    (out / f"{book.name}.truth.json").write_text(json.dumps(truth, ensure_ascii=False, indent=1) + "\n",
                                                 encoding="utf-8")
    lines = []
    for k, s in enumerate(scripts):
        lines.extend(s)
        if book.toc_folio:
            f = folios[toc_physical[k]]
            if f:
                lines.append(f)
    (out / f"{book.name}.toc_lines.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    toc_txt = [f"# {book.name}: correct outline, PHYSICAL pages (mulu apply --offset 0)"]
    for e in entries:
        toc_txt.append("\t" * e.level + e.title + "\t" + str(e.physical))
    (out / f"{book.name}.toc.txt").write_text("\n".join(toc_txt) + "\n", encoding="utf-8")
    expected = [{"title": e.title, "level": e.level, "page_index": e.physical - 1} for e in entries]
    (out / f"{book.name}.expected.json").write_text(json.dumps(expected, ensure_ascii=False, indent=1) + "\n",
                                                    encoding="utf-8")
    return {
        "book": book.name, "pages": n_pages, "offset": book.offset, "toc_pages": toc_physical,
        "entries": len(entries), "levels": truth["levels"], "mode": book.mode, "dpi": book.dpi,
        "folio": book.folio, "bytes": pdf_path.stat().st_size, "features": book.features,
        "seconds": round(time.time() - t0, 1), "fonts": truth["render"]["fonts"],
    }


def roman_value(s: str) -> int:
    vals = {"i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000}
    total, prev = 0, 0
    for ch in reversed(s.lower()):
        v = vals[ch]
        total = total - v if v < prev else total + v
        prev = max(prev, v)
    return total


def _worker(name: str, out: str, preview: str | None):
    book = next(b for b in BOOKS if b.name == name)
    return build_book(book, Path(out), Path(preview) if preview else None)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="", help="comma-separated book names")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--list", action="store_true", help="list the books and exit")
    ap.add_argument("--preview", default="", help="also write PNG previews of TOC pages here")
    ap.add_argument("--jobs", type=int, default=2, help="parallel book builders (default 2, keep the Mac responsive)")
    args = ap.parse_args()
    if args.list:
        for b in BOOKS:
            print(f"{b.name:28s} {b.lang} {b.trim:4s} {b.mode:4s} {b.dpi}dpi offset {b.offset:2d}  "
                  f"{'; '.join(b.features)}")
        return 0
    only = {x for x in args.only.split(",") if x}
    unknown = only - {b.name for b in BOOKS}
    if unknown:
        print(f"make_books: unknown book(s) {sorted(unknown)}", file=sys.stderr)
        return 2
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    preview = None
    if args.preview:
        preview = Path(args.preview)
        preview.mkdir(parents=True, exist_ok=True)
    todo = [b for b in BOOKS if not only or b.name in only]
    rows = []
    failed: list[str] = []
    t0 = time.time()
    jobs = max(1, min(args.jobs, 2))
    with cf.ProcessPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(_worker, b.name, str(out), str(preview) if preview else None): b.name for b in todo}
        for fut in cf.as_completed(futs):
            try:
                r = fut.result()
            except BaseException as e:  # noqa: BLE001  (SystemExit from a config check, or a crash)
                failed.append(futs[fut])
                print(f"[books] {futs[fut]:28s} FAILED: {e}", file=sys.stderr, flush=True)
                continue
            rows.append(r)
            print(f"[books] {r['book']:28s} {r['pages']:3d} pages  offset {r['offset']:2d}  toc {r['toc_pages']}  "
                  f"{r['entries']:3d} entries  {r['bytes'] / 1e6:5.1f} MB  {r['seconds']:5.1f}s", flush=True)
    rows.sort(key=lambda r: [b.name for b in BOOKS].index(r["book"]))
    man_path = out / "manifest.json"
    manifest = {}
    if man_path.exists() and only:
        try:
            manifest = {r["book"]: r for r in json.loads(man_path.read_text(encoding="utf-8"))["books"]}
        except (ValueError, KeyError):
            manifest = {}
    for r in rows:
        manifest[r["book"]] = r
    ordered = [manifest[b.name] for b in BOOKS if b.name in manifest]
    man_path.write_text(json.dumps({"generator": "tools/fixtures/make_books.py", "books": ordered},
                                   ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"[books] {len(rows)} book(s) in {time.time() - t0:.0f}s -> {out}")
    if failed:
        print(f"[books] FAILED: {', '.join(sorted(failed))}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
