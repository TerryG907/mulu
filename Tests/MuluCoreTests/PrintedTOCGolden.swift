// Generated golden outputs for PrintedTOCParser (offset 0, default options).
// Every case was reviewed by hand; regenerate only after checking the diff.
@testable import MuluCore

struct GoldenCase: Sendable {
    let name: String
    let input: String
    let expected: String
    let lowConfidenceLines: [Int]
    init(_ name: String, input: String, expected: String, lowConfidenceLines: [Int]) {
        self.name = name
        self.input = input
        self.expected = expected
        self.lowConfidenceLines = lowConfidenceLines
    }
}

enum PrintedTOCGolden {
    static let cases: [GoldenCase] = [
        GoldenCase("cn_calculus", input: #"""
第一章 函数与极限 …………………… 1
第一节 映射与函数 ………………… 1
一、映射 …………………………… 1
二、函数 …………………………… 3
习题1-1 ………………………… 16
第二节 数列的极限 ………………… 18
一、数列极限的定义 ……………… 18
二、收敛数列的性质 ……………… 22
习题1-2 ………………………… 25
第二章 导数与微分 ………………… 74
第一节 导数概念 ………………… 74
"""#, expected: #"""
第一章 函数与极限 1
	第一节 映射与函数 1
		一、映射 1
		二、函数 3
		习题1-1 16
	第二节 数列的极限 18
		一、数列极限的定义 18
		二、收敛数列的性质 22
		习题1-2 25
第二章 导数与微分 74
	第一节 导数概念 74
"""#, lowConfidenceLines: []),
        GoldenCase("cn_geo_parts", input: #"""
导论 ……………………………………………… 1
第一篇 自然地理总论 ……………………… 21
第一章 地球表层的结构及演化规律 ………… 23
第一节 地貌的多样性与区域差异性 ……… 23
一、岩石及其风化过程 …………………… 23
（一）岩石类型 ………………………… 23
（二）风化的主要方式 ………………… 26
二、土壤的形成与分布 …………………… 30
第二节 水文循环和气候变化过程 ……… 38
第二章 生物群落及其空间规律 ………… 62
第二篇 人文地理专论 …………… 101
第三章 城市的形成及规律 …………… 103
结束语 ……………………………………… 287
后记 ………………………………………… 295
"""#, expected: #"""
导论 1
第一篇 自然地理总论 21
	第一章 地球表层的结构及演化规律 23
		第一节 地貌的多样性与区域差异性 23
			一、岩石及其风化过程 23
				（一）岩石类型 23
				（二）风化的主要方式 26
			二、土壤的形成与分布 30
		第二节 水文循环和气候变化过程 38
	第二章 生物群落及其空间规律 62
第二篇 人文地理专论 101
	第三章 城市的形成及规律 103
结束语 287
后记 295
"""#, lowConfidenceLines: []),
        GoldenCase("cn_thesis", input: #"""
摘  要 ……………………………………………… I
ABSTRACT ………………………………………… III
第1章 绪论 ………………………………………… 1
1.1 研究背景与意义 ……………………………… 1
1.1.1 研究背景 ………………………………… 1
1.1.2 研究意义 ………………………………… 3
1.2 国内外研究现状 ……………………………… 4
1.3 本文主要研究内容 …………………………… 8
第2章 相关理论与技术 …………………………… 10
2.1 深度学习基础 ………………………………… 10
2.1.1 卷积神经网络 …………………………… 11
2.1.2 注意力机制 ……………………………… 14
2.2 本章小结 ……………………………………… 18
第3章 总结与展望 ………………………………… 50
参考文献 …………………………………………… 53
攻读硕士学位期间取得的研究成果 ……………… 58
致  谢 ……………………………………………… 59
"""#, expected: #"""
第1章 绪论 1
	1.1 研究背景与意义 1
		1.1.1 研究背景 1
		1.1.2 研究意义 3
	1.2 国内外研究现状 4
	1.3 本文主要研究内容 8
第2章 相关理论与技术 10
	2.1 深度学习基础 10
		2.1.1 卷积神经网络 11
		2.1.2 注意力机制 14
	2.2 本章小结 18
第3章 总结与展望 50
参考文献 53
攻读硕士学位期间取得的研究成果 58
致谢 59
"""#, lowConfidenceLines: [1, 2]),
        GoldenCase("cn_novel_hongloumeng", input: #"""
第一回 甄士隐梦幻识通灵 贾雨村风尘怀闺秀 …… 1
第二回 贾夫人仙逝扬州城 冷子兴演说荣国府 …… 17
第三回 托内兄如海荐西宾 接外孙贾母惜孤女 …… 31
第四回 薄命女偏逢薄命郎 葫芦僧乱判葫芦案 …… 52
第五回 游幻境指迷十二钗 饮仙醪曲演红楼梦 …… 65
"""#, expected: #"""
第一回 甄士隐梦幻识通灵 贾雨村风尘怀闺秀 1
第二回 贾夫人仙逝扬州城 冷子兴演说荣国府 17
第三回 托内兄如海荐西宾 接外孙贾母惜孤女 31
第四回 薄命女偏逢薄命郎 葫芦僧乱判葫芦案 52
第五回 游幻境指迷十二钗 饮仙醪曲演红楼梦 65
"""#, lowConfidenceLines: []),
        GoldenCase("cn_novel_parts", input: #"""
第一部 疯狂年代 ………………………………… 1
科学边界 ………………………………………… 3
台球 ……………………………………………… 17
射手和农场主 …………………………………… 29
第二部 三体 ……………………………………… 101
宇宙闪烁 ………………………………………… 103
尾声 ……………………………………………… 301
"""#, expected: #"""
第一部 疯狂年代 1
	科学边界 3
	台球 17
	射手和农场主 29
第二部 三体 101
	宇宙闪烁 103
尾声 301
"""#, lowConfidenceLines: []),
        GoldenCase("cn_novel_plain", input: #"""
一 ………………………………………………… 1
二 ………………………………………………… 25
三 ………………………………………………… 51
"""#, expected: #"""
一 1
二 25
三 51
"""#, lowConfidenceLines: []),
        GoldenCase("cn_cs_textbook", input: #"""
前言 ……………………………………………… xv
第1章 数据库系统概览 ………………………… 1
1.1 数据就是记录+结构 ……………………… 1
1.2 查询被优化器改写成不同的计划 ……… 2
1.4.1 存储的物理组织 ………………………… 4
第一部分 数据模型和查询 ……………………… 21
第2章 关系的表示和运算 ……………………… 22
2.1 关系代数 …………………………………… 24
"""#, expected: #"""
第1章 数据库系统概览 1
	1.1 数据就是记录+结构 1
	1.2 查询被优化器改写成不同的计划 2
		1.4.1 存储的物理组织 4
第一部分 数据模型和查询 21
	第2章 关系的表示和运算 22
		2.1 关系代数 24
"""#, lowConfidenceLines: [1]),
        GoldenCase("cn_kaoyan_math", input: #"""
第一篇 高等数学
第一章 函数、极限、连续 …………………… 1
考点一 函数的概念与性质 ………………… 1
考点二 极限的概念与计算 ………………… 6
典型例题 …………………………………… 12
第二章 一元函数微分学 …………………… 35
考点一 导数与微分 ………………………… 35
第二篇 线性代数 …………………………… 301
第一章 行列式 ……………………………… 303
"""#, expected: #"""
第一篇 高等数学 1
	第一章 函数、极限、连续 1
		考点一 函数的概念与性质 1
		考点二 极限的概念与计算 6
		典型例题 12
	第二章 一元函数微分学 35
		考点一 导数与微分 35
第二篇 线性代数 301
	第一章 行列式 303
"""#, lowConfidenceLines: [1]),
        GoldenCase("cn_kaoyan_politics", input: #"""
专题一 马克思主义基本原理 ………………… 1
一、马克思主义哲学 ……………………………… 1
（一）唯物论 ……………………………………… 1
1. 物质观 …………………………………………… 1
2. 意识观 …………………………………………… 4
（二）辩证法 ……………………………………… 8
二、政治经济学 …………………………………… 30
专题二 毛泽东思想 …………………………… 60
"""#, expected: #"""
专题一 马克思主义基本原理 1
	一、马克思主义哲学 1
		（一）唯物论 1
			1. 物质观 1
			2. 意识观 4
		（二）辩证法 8
	二、政治经济学 30
专题二 毛泽东思想 60
"""#, lowConfidenceLines: []),
        GoldenCase("cn_programming_book", input: #"""
第一部分 基础知识
第1章 起步 ……………………………………………… 2
1.1 安装开发工具 …………………………………… 2
1.1.1 Python版本 …………………………………… 2
1.2 在不同操作系统中安装Python开发工具 ………… 3
1.3 小结 ……………………………………………… 12
第2章 表达式和基本类型 …………………… 13
第二部分 项目
项目1 贪吃蛇游戏
第12章 绘制地图 ……………………………………… 226
附录A 常见错误排查 ……………………………… 460
附录B 代码编辑器和IDE …………………………… 466
"""#, expected: #"""
第一部分 基础知识 2
	第1章 起步 2
		1.1 安装开发工具 2
			1.1.1 Python版本 2
		1.2 在不同操作系统中安装Python开发工具 3
		1.3 小结 12
	第2章 表达式和基本类型 13
第二部分 项目 226
	项目1 贪吃蛇游戏 226
	第12章 绘制地图 226
附录A 常见错误排查 460
附录B 代码编辑器和IDE 466
"""#, lowConfidenceLines: [1, 8, 9]),
        GoldenCase("cn_appendix_container", input: #"""
第五章 结论 ………………………………………… 90
附录 ……………………………………………………… 95
附录A 符号表 ……………………………………… 95
附录B 证明 ………………………………………… 97
索引 ……………………………………………………… 110
"""#, expected: #"""
第五章 结论 90
附录 95
	附录A 符号表 95
	附录B 证明 97
索引 110
"""#, lowConfidenceLines: []),
        GoldenCase("cn_per_chapter_refs", input: #"""
第一章 细胞 ……………………………………… 1
第一节 细胞的结构 ……………………………… 2
第二节 细胞的功能 ……………………………… 10
思考题 ……………………………………………… 20
参考文献 …………………………………………… 21
第二章 组织 ……………………………………… 22
第一节 上皮组织 ………………………………… 23
思考题 ……………………………………………… 40
参考文献 …………………………………………… 41
第三章 器官 ……………………………………… 42
参考文献 …………………………………………… 60
"""#, expected: #"""
第一章 细胞 1
	第一节 细胞的结构 2
	第二节 细胞的功能 10
	思考题 20
	参考文献 21
第二章 组织 22
	第一节 上皮组织 23
	思考题 40
	参考文献 41
第三章 器官 42
	参考文献 60
"""#, lowConfidenceLines: []),
        GoldenCase("cn_fullwidth_digits", input: #"""
第一章　总论　……………………………………　１
第一节　概述　……………………………………　３
第二节　历史　……………………………………　１２
第二章　分论　……………………………………　１０５
"""#, expected: #"""
第一章 总论 1
	第一节 概述 3
	第二节 历史 12
第二章 分论 105
"""#, lowConfidenceLines: []),
        GoldenCase("cn_page_ranges", input: #"""
第一讲 导论 ………………………… 1-10
第二讲 方法 ………………………… 11–20
第三讲 应用 ………………………… 21~35
"""#, expected: #"""
第一讲 导论 1
第二讲 方法 11
第三讲 应用 21
"""#, lowConfidenceLines: []),
        GoldenCase("cn_brackets", input: #"""
第一章 总则（1）
第二章 分则（15）
第三章 附则【30】
"""#, expected: #"""
第一章 总则 1
第二章 分则 15
第三章 附则 30
"""#, lowConfidenceLines: []),
        GoldenCase("cn_glued_pages", input: #"""
新版序言
前言
第1章城市规划导论2
第一编空间结构
第2章街道与街区32
第3章交通和土地利用69
结语605
参考文献606
"""#, expected: #"""
新版序言 2
前言 2
第1章城市规划导论 2
第一编空间结构 32
	第2章街道与街区 32
	第3章交通和土地利用 69
结语 605
参考文献 606
"""#, lowConfidenceLines: [1, 2, 4]),
        GoldenCase("cn_ocr_noise", input: #"""
第一章 绪论 ...... l
1.1 背景 ...... 3
1.2 问题 ...... I5
第二章 方法 ...... 2O
2.1 模型 ...... 2l
2.2 算法 ...... 3O。
第三章 实验 ...... 4O'
"""#, expected: #"""
第一章 绪论 1
	1.1 背景 3
	1.2 问题 15
第二章 方法 20
	2.1 模型 21
	2.2 算法 30
第三章 实验 40
"""#, lowConfidenceLines: [1, 3, 4, 5, 6, 7]),
        GoldenCase("cn_ocr_numbering_noise", input: #"""
l.1 引言 ……………… 1
1.2 相关工作 ………… 3
1:3 方法 ……………… 5
1。4 总结 ……………… 9
"""#, expected: #"""
l.1 引言 1
1.2 相关工作 3
1:3 方法 5
1。4 总结 9
"""#, lowConfidenceLines: []),
        GoldenCase("cn_gibberish", input: #"""
3.3 线性密码分析TISCUNRTeACnbwelawemwenonances 61
3.3.3 SPN 的线性密码分析 66
4.6 注释与参考文献cuNUaAUeaie 119
"""#, expected: #"""
3.3 线性密码分析 61
	3.3.3 SPN 的线性密码分析 66
4.6 注释与参考文献 119
"""#, lowConfidenceLines: [1, 3]),
        GoldenCase("cn_wrapped", input: #"""
第一章 社会主义市场经济体制的建立与
完善 ……………………………………………… 1
第二章 经济全球化背景下的对外开放 ………… 25
第三章 新时代中国特色社会主义思想的形成、
发展及其历史地位 ……………………………… 49
"""#, expected: #"""
第一章 社会主义市场经济体制的建立与完善 1
第二章 经济全球化背景下的对外开放 25
第三章 新时代中国特色社会主义思想的形成、发展及其历史地位 49
"""#, lowConfidenceLines: []),
        GoldenCase("cn_page_on_own_line", input: #"""
第一章 概论 ……
1
第二章 发展 ……
15
3
第三章 趋势 …… 40
"""#, expected: #"""
第一章 概论 1
第二章 发展 15
第三章 趋势 40
"""#, lowConfidenceLines: []),
        GoldenCase("cn_running_header", input: #"""
经济学原理
第一章 十大原理 ………… 3
第二章 像经济学家一样思考 ………… 21
经济学原理
第三章 相互依存性 ………… 49
"""#, expected: #"""
第一章 十大原理 3
第二章 像经济学家一样思考 21
第三章 相互依存性 49
"""#, lowConfidenceLines: []),
        GoldenCase("cn_two_column", input: #"""
第一章 绪论 ………… 1        第五章 实验 ………… 88
第二章 理论 ………… 20       第六章 结论 ………… 120
"""#, expected: #"""
第一章 绪论 1
第二章 理论 20
第五章 实验 88
第六章 结论 120
"""#, lowConfidenceLines: []),
        GoldenCase("cn_upper_lower", input: #"""
上篇 理论基础 ……………………………… 1
第一章 概述 ………………………………… 3
第二章 原理 ………………………………… 20
下篇 实践应用 ……………………………… 101
第三章 案例 ………………………………… 103
"""#, expected: #"""
上篇 理论基础 1
	第一章 概述 3
	第二章 原理 20
下篇 实践应用 101
	第三章 案例 103
"""#, lowConfidenceLines: []),
        GoldenCase("cn_starred", input: #"""
第一章 线性空间 …………………………… 1
§1 集合与映射 ……………………………… 1
§2 线性空间的定义 ………………………… 5
*§3 商空间 ………………………………… 12
第二章 线性映射 ………………………… 30
"""#, expected: #"""
第一章 线性空间 1
	§1 集合与映射 1
	§2 线性空间的定义 5
	*§3 商空间 12
第二章 线性映射 30
"""#, lowConfidenceLines: []),
        GoldenCase("cn_cnparen_nested", input: #"""
一、总体要求 ………………………………… 1
（一）指导思想 …………………………… 1
（二）基本原则 …………………………… 2
1. 坚持党的领导 ………………………… 2
2. 坚持以人民为中心 …………………… 3
（1）具体措施 …………………………… 3
二、主要任务 ………………………………… 5
"""#, expected: #"""
一、总体要求 1
	（一）指导思想 1
	（二）基本原则 2
		1. 坚持党的领导 2
		2. 坚持以人民为中心 3
			（1）具体措施 3
二、主要任务 5
"""#, lowConfidenceLines: []),
        GoldenCase("cn_indent_unnumbered", input: #"""
前言 1
  写作背景 2
  本书结构 3
第一章 起源 5
  远古时期 5
    石器时代 6
  农业革命 12
第二章 文明 30
"""#, expected: #"""
前言 1
	写作背景 2
	本书结构 3
第一章 起源 5
	远古时期 5
		石器时代 6
	农业革命 12
第二章 文明 30
"""#, lowConfidenceLines: []),
        GoldenCase("cn_volumes_units", input: #"""
第一单元 我们的国家
第1课 中华人民共和国成立 ………… 2
第2课 抗美援朝 ………………… 8
第二单元 社会主义制度的建立
第3课 土地改革 ………………… 14
"""#, expected: #"""
第一单元 我们的国家 2
	第1课 中华人民共和国成立 2
	第2课 抗美援朝 8
第二单元 社会主义制度的建立 14
	第3课 土地改革 14
"""#, lowConfidenceLines: [1, 4]),
        GoldenCase("cn_lectures_spaced_toc", input: #"""
目 录
前 言 ………………………………………… 1
第一讲 绪论 ………………………………… 3
第二讲 方法论 ……………………………… 17
后 记 ………………………………………… 201
"""#, expected: #"""
前言 1
第一讲 绪论 3
第二讲 方法论 17
后记 201
"""#, lowConfidenceLines: []),
        GoldenCase("en_textbook_calculus", input: #"""
Preface ix
To the Student xiii
1 Functions and Models 9
1.1 Four Ways to Represent a Function 10
1.2 Mathematical Models 23
1.3 New Functions from Old Functions 36
2 Limits and Derivatives 77
2.1 The Tangent and Velocity Problems 78
Appendixes	A1
Index	A133
"""#, expected: #"""
1 Functions and Models 9
	1.1 Four Ways to Represent a Function 10
	1.2 Mathematical Models 23
	1.3 New Functions from Old Functions 36
2 Limits and Derivatives 77
	2.1 The Tangent and Velocity Problems 78
"""#, lowConfidenceLines: [1, 2, 9, 10]),
        GoldenCase("en_chapter_word", input: #"""
Contents
Preface . . . . . . . . . . . . . . . . . . . . . xi
Acknowledgments . . . . . . . . . . . . . . . xv
Chapter 1 Introduction . . . . . . . . . . . . . 1
1.1 What Is an Algorithm? . . . . . . . . . . . . 3
1.2 Analyzing Algorithms . . . . . . . . . . . . . 9
1.2.1 Worst-case Analysis . . . . . . . . . . . 11
Chapter 2 Getting Started . . . . . . . . . . . . 16
Summary . . . . . . . . . . . . . . . . . . . . 42
Exercises . . . . . . . . . . . . . . . . . . . . 43
Appendix A Summations . . . . . . . . . . . . 1145
Bibliography . . . . . . . . . . . . . . . . . . 1231
Index . . . . . . . . . . . . . . . . . . . . . . 1251
"""#, expected: #"""
Chapter 1 Introduction 1
	1.1 What Is an Algorithm? 3
	1.2 Analyzing Algorithms 9
		1.2.1 Worst-case Analysis 11
Chapter 2 Getting Started 16
	Summary 42
	Exercises 43
Appendix A Summations 1145
Bibliography 1231
Index 1251
"""#, lowConfidenceLines: [2, 3]),
        GoldenCase("en_novel_parts", input: #"""
PART ONE
The Boy Who Lived 1
The Vanishing Glass 17
PART TWO
The Letters from No One 31
Epilogue 301
"""#, expected: #"""
PART ONE 1
	The Boy Who Lived 1
	The Vanishing Glass 17
PART TWO 31
	The Letters from No One 31
Epilogue 301
"""#, lowConfidenceLines: [1, 4]),
        GoldenCase("en_novel_chapters_words", input: #"""
Chapter One: Down the Rabbit-Hole 1
Chapter Two: The Pool of Tears 13
Chapter Three: A Caucus-Race and a Long Tale 25
"""#, expected: #"""
Chapter One: Down the Rabbit-Hole 1
Chapter Two: The Pool of Tears 13
Chapter Three: A Caucus-Race and a Long Tale 25
"""#, lowConfidenceLines: []),
        GoldenCase("en_parts_roman", input: #"""
Foreword vii
Introduction xi
Part I Foundations 1
1 The Nature of Things 3
1.1 Matter 4
1.2 Energy 9
2 Motion 20
Part II Applications 101
3 Machines 103
Notes 301
Index 320
"""#, expected: #"""
Part I Foundations 1
	1 The Nature of Things 3
		1.1 Matter 4
		1.2 Energy 9
	2 Motion 20
Part II Applications 101
	3 Machines 103
Notes 301
Index 320
"""#, lowConfidenceLines: [1, 2]),
        GoldenCase("en_section_words", input: #"""
Chapter 1 Basics 1
Section 1.1 Sets 2
Section 1.2 Functions 7
Chapter 2 Logic 15
Section 2.1 Propositions 16
"""#, expected: #"""
Chapter 1 Basics 1
	Section 1.1 Sets 2
	Section 1.2 Functions 7
Chapter 2 Logic 15
	Section 2.1 Propositions 16
"""#, lowConfidenceLines: []),
        GoldenCase("en_wrapped", input: #"""
1 The Origins of Power, Prosperity, and
Poverty 1
2 Theories That Don't Work 45
3 The Making of Prosperity and
Poverty in the Modern World 70
"""#, expected: #"""
1 The Origins of Power, Prosperity, and Poverty 1
2 Theories That Don't Work 45
3 The Making of Prosperity and Poverty in the Modern World 70
"""#, lowConfidenceLines: []),
        GoldenCase("en_lowercase_continuation", input: #"""
Chapter 3 A very long chapter title that keeps going
and going 55
Chapter 4 Short 80
"""#, expected: #"""
Chapter 3 A very long chapter title that keeps going and going 55
Chapter 4 Short 80
"""#, lowConfidenceLines: []),
        GoldenCase("en_hyphenated", input: #"""
Chapter 1 Computational Linear Alge-
bra Revisited 1
Chapter 2 Graphs 30
"""#, expected: #"""
Chapter 1 Computational Linear Algebra Revisited 1
Chapter 2 Graphs 30
"""#, lowConfidenceLines: []),
        GoldenCase("en_page_prefix", input: #"""
Introduction p. 1
Chapter 1 Early Life p. 7
Chapter 2 War Years pp. 45-60
"""#, expected: #"""
Introduction 1
Chapter 1 Early Life 7
Chapter 2 War Years 45
"""#, lowConfidenceLines: []),
        GoldenCase("en_ocr_noise", input: #"""
Chapter 1 Intro ....... l
Chapter 2 Growth ....... 1O
Chapter 3 Decline ....... I9
Chapter 4 Rebirth ....... 3l
"""#, expected: #"""
Chapter 1 Intro 1
Chapter 2 Growth 10
Chapter 3 Decline 19
Chapter 4 Rebirth 31
"""#, lowConfidenceLines: [1, 2, 3, 4]),
        GoldenCase("en_title_ending_numbers", input: #"""
Windows 95 and Beyond 12
The Year 1984 Revisited 30
Catch-22 Explained 41
"""#, expected: #"""
Windows 95 and Beyond 12
The Year 1984 Revisited 30
Catch-22 Explained 41
"""#, lowConfidenceLines: []),
        GoldenCase("en_part_pageless", input: #"""
Part 1
Chapter 1 Beginnings 3
Chapter 2 Middles 20
Part 2
Chapter 3 Endings 41
"""#, expected: #"""
Part 1 3
	Chapter 1 Beginnings 3
	Chapter 2 Middles 20
Part 2 41
	Chapter 3 Endings 41
"""#, lowConfidenceLines: [1, 4]),
        GoldenCase("en_world_war", input: #"""
The Road to World War II
Causes 3
World War II 20
Aftermath 55
"""#, expected: #"""
The Road to World War II 3
Causes 3
World War II 20
Aftermath 55
"""#, lowConfidenceLines: [1]),
        GoldenCase("en_lecture_notes", input: #"""
Lecture 1 Overview 1
Lecture 2 Probability 12
Lecture 3 Estimation 25
"""#, expected: #"""
Lecture 1 Overview 1
Lecture 2 Probability 12
Lecture 3 Estimation 25
"""#, lowConfidenceLines: []),
        GoldenCase("en_roman_after_arabic", input: #"""
Chapter 1 Alpha 1
Chapter 2 Beta ...... I
Chapter 3 Gamma 20
"""#, expected: #"""
Chapter 1 Alpha 1
Chapter 2 Beta 1
Chapter 3 Gamma 20
"""#, lowConfidenceLines: [2]),
        GoldenCase("en_monotonic_violation", input: #"""
Chapter 1 A 1
Chapter 2 B 15
Chapter 3 C 51
Chapter 4 D 32
Chapter 5 E 40
"""#, expected: #"""
Chapter 1 A 1
Chapter 2 B 15
Chapter 3 C 51
Chapter 4 D 32
Chapter 5 E 40
"""#, lowConfidenceLines: [3]),
        GoldenCase("en_indent_only", input: #"""
Getting Started 1
    Installing 2
    First Steps 5
        Hello World 6
Advanced Topics 20
    Concurrency 21
"""#, expected: #"""
Getting Started 1
	Installing 2
	First Steps 5
		Hello World 6
Advanced Topics 20
	Concurrency 21
"""#, lowConfidenceLines: []),
        GoldenCase("en_book_units", input: #"""
Unit 1 Cells 1
Chapter 1 The Cell 3
Chapter 2 Membranes 20
Unit 2 Genetics 50
Chapter 3 DNA 52
"""#, expected: #"""
Unit 1 Cells 1
	Chapter 1 The Cell 3
	Chapter 2 Membranes 20
Unit 2 Genetics 50
	Chapter 3 DNA 52
"""#, lowConfidenceLines: []),
        GoldenCase("en_appendix_letters", input: #"""
Chapter 9 Conclusion 200
Appendix A Proofs 210
A.1 Lemma 1 210
A.2 Lemma 2 213
Appendix B Data 220
References 230
"""#, expected: #"""
Chapter 9 Conclusion 200
Appendix A Proofs 210
	A.1 Lemma 1 210
	A.2 Lemma 2 213
Appendix B Data 220
References 230
"""#, lowConfidenceLines: []),
        GoldenCase("en_dotted_leaders_mixed", input: #"""
1 Introduction ··········· 1
1.1 Motivation ··········· 2
1.2 Outline ················ 4
2 Background ——————— 7
2.1 Prior Art ____________ 8
"""#, expected: #"""
1 Introduction 1
	1.1 Motivation 2
	1.2 Outline 4
2 Background 7
	2.1 Prior Art 8
"""#, lowConfidenceLines: []),
        GoldenCase("en_numbered_decimal", input: #"""
1. The Beginning 1
2. The Middle 50
3. The End 99
"""#, expected: #"""
1. The Beginning 1
2. The Middle 50
3. The End 99
"""#, lowConfidenceLines: []),
        GoldenCase("en_chapter_per_summary", input: #"""
Chapter 1 Numbers 1
1.1 Integers 2
1.2 Rationals 6
Chapter Summary 10
Review Questions 11
Chapter 2 Algebra 13
2.1 Variables 14
Chapter Summary 20
"""#, expected: #"""
Chapter 1 Numbers 1
	1.1 Integers 2
	1.2 Rationals 6
	Chapter Summary 10
	Review Questions 11
Chapter 2 Algebra 13
	2.1 Variables 14
	Chapter Summary 20
"""#, lowConfidenceLines: []),
        GoldenCase("en_contents_with_page", input: #"""
Title Page 1
Copyright 2
Contents 3
Chapter 1 Start 5
"""#, expected: #"""
Title Page 1
Copyright 2
Contents 3
Chapter 1 Start 5
"""#, lowConfidenceLines: []),
        GoldenCase("cn_ocr_tab_output", input: #"""
前言	i
第一章 绪论	1
  1.1 研究背景	2
  1.2 研究内容	5
第二章 理论基础	9
  2.1 基本概念	9
    2.1.1 定义	10
"""#, expected: #"""
第一章 绪论 1
	1.1 研究背景 2
	1.2 研究内容 5
第二章 理论基础 9
	2.1 基本概念 9
		2.1.1 定义 10
"""#, lowConfidenceLines: [1]),
        GoldenCase("cn_mixed_cnenum_dotted", input: #"""
第一章 总论 1
一、基本概念 1
二、研究方法 5
第二章 分论 10
1.1 细分 10
1.2 深入 15
"""#, expected: #"""
第一章 总论 1
	一、基本概念 1
	二、研究方法 5
第二章 分论 10
	1.1 细分 10
	1.2 深入 15
"""#, lowConfidenceLines: []),
        GoldenCase("cn_textbook_full_chain", input: #"""
第一编 总则
第一章 绪论 …………………………… 1
第一节 概念 …………………………… 1
一、定义 …………………………………… 1
（一）广义 …………………………… 1
1. 学说 ………………………………… 2
（1）甲说 …………………………… 2
（2）乙说 …………………………… 3
2. 评价 ………………………………… 4
（二）狭义 …………………………… 5
二、特征 …………………………………… 6
第二节 历史 …………………………… 8
第二编 分则
第二章 犯罪 …………………………… 20
"""#, expected: #"""
第一编 总则 1
	第一章 绪论 1
		第一节 概念 1
			一、定义 1
				（一）广义 1
					1. 学说 2
						（1）甲说 2
						（2）乙说 3
					2. 评价 4
				（二）狭义 5
			二、特征 6
		第二节 历史 8
第二编 分则 20
	第二章 犯罪 20
"""#, lowConfidenceLines: [1, 13]),
        GoldenCase("cn_circled", input: #"""
第一章 综述 1
① 背景 1
② 目标 3
第二章 实施 8
"""#, expected: #"""
第一章 综述 1
	① 背景 1
	② 目标 3
第二章 实施 8
"""#, lowConfidenceLines: []),
        GoldenCase("cn_exercises_numbered", input: #"""
第一章 集合 …………………………… 1
1.1 集合的概念 ……………………… 1
习题一 ……………………………… 8
第二章 函数 …………………………… 10
2.1 函数的定义 ……………………… 10
习题二 ……………………………… 20
总复习题 …………………………… 30
"""#, expected: #"""
第一章 集合 1
	1.1 集合的概念 1
	习题一 8
第二章 函数 10
	2.1 函数的定义 10
	习题二 20
总复习题 30
"""#, lowConfidenceLines: []),
        GoldenCase("cn_trailer_section", input: #"""
第一章 力学 ………………………… 1
第一节 运动 ………………………… 1
本节小结 …………………………… 9
第二节 力 …………………………… 10
本章小结 …………………………… 20
"""#, expected: #"""
第一章 力学 1
	第一节 运动 1
		本节小结 9
	第二节 力 10
	本章小结 20
"""#, lowConfidenceLines: []),
        GoldenCase("cn_stray_punct", input: #"""
第一章 引论…………1，
第二章 方法…………12;
第三章 结果………… 30 |
"""#, expected: #"""
第一章 引论 1
第二章 方法 12
第三章 结果 30
"""#, lowConfidenceLines: []),
        GoldenCase("cn_decorative_folio", input: #"""
第一章 起源 ………… 1
第二章 发展 ………… 9
· 2 ·
第三章 衰落 ………… 20
— 3 —
"""#, expected: #"""
第一章 起源 1
第二章 发展 9
第三章 衰落 20
"""#, lowConfidenceLines: []),
        GoldenCase("cn_front_roman_mapped", input: #"""
序 …………………………………… i
前言 ………………………………… iii
第一章 开端 ………………………… 1
"""#, expected: #"""
第一章 开端 1
"""#, lowConfidenceLines: [1, 2]),
        GoldenCase("cn_no_pages", input: #"""
第一章 开端
第二章 发展
"""#, expected: #"""

"""#, lowConfidenceLines: [1, 2]),
        GoldenCase("en_trailing_period_pages", input: #"""
1 Overview 1.
2 Details 9.
3 Summary 20.
"""#, expected: #"""
1 Overview 1
2 Details 9
3 Summary 20
"""#, lowConfidenceLines: []),
        GoldenCase("en_thesis_caps", input: #"""
ABSTRACT ii
ACKNOWLEDGEMENTS iv
LIST OF FIGURES vii
CHAPTER 1 INTRODUCTION 1
1.1 Background 1
1.2 Research Questions 4
CHAPTER 2 LITERATURE REVIEW 9
2.1 Prior Work 9
2.1.1 Early Studies 10
REFERENCES 88
APPENDIX A SURVEY INSTRUMENT 95
"""#, expected: #"""
CHAPTER 1 INTRODUCTION 1
	1.1 Background 1
	1.2 Research Questions 4
CHAPTER 2 LITERATURE REVIEW 9
	2.1 Prior Work 9
		2.1.1 Early Studies 10
REFERENCES 88
APPENDIX A SURVEY INSTRUMENT 95
"""#, lowConfidenceLines: [1, 2, 3]),
        GoldenCase("en_tech_parts_chapters", input: #"""
Part I. Getting Started
Chapter 1. Installing the Toolchain ........ 3
1.1 Downloading ........ 4
1.2 Verifying the Install ........ 7
Chapter 2. Your First Program ........ 11
Part II. Core Concepts
Chapter 3. Ownership ........ 41
3.1 Moves and Copies ........ 42
Index ........ 401
"""#, expected: #"""
Part I. Getting Started 3
	Chapter 1. Installing the Toolchain 3
		1.1 Downloading 4
		1.2 Verifying the Install 7
	Chapter 2. Your First Program 11
Part II. Core Concepts 41
	Chapter 3. Ownership 41
		3.1 Moves and Copies 42
Index 401
"""#, lowConfidenceLines: [1, 6]),
        GoldenCase("cn_novel_numbered", input: #"""
序 ………………………………………………… 1
一 ………………………………………………… 3
二 ………………………………………………… 29
三 ………………………………………………… 52
再印小记 ………………………………………… 351
"""#, expected: #"""
序 1
一 3
二 29
三 52
再印小记 351
"""#, lowConfidenceLines: []),
        GoldenCase("cn_kaoyan_english", input: #"""
第一部分 英语知识运用
第一章 完形填空 ……………………………… 3
第一节 命题规律 …………………………… 3
第二节 解题技巧 …………………………… 8
第二部分 阅读理解
第二章 传统阅读 ……………………………… 57
第三章 新题型 ………………………………… 120
附录 历年真题 ………………………………… 301
"""#, expected: #"""
第一部分 英语知识运用 3
	第一章 完形填空 3
		第一节 命题规律 3
		第二节 解题技巧 8
第二部分 阅读理解 57
	第二章 传统阅读 57
	第三章 新题型 120
附录 历年真题 301
"""#, lowConfidenceLines: [1, 5]),
        GoldenCase("cn_high_school", input: #"""
第一章 集合与常用逻辑用语 ………… 1
1.1 集合的概念 ……………………… 2
1.2 集合间的基本关系 ……………… 7
阅读与思考 集合中元素的个数 …… 10
1.3 集合的基本运算 ………………… 11
小结 ………………………………… 30
复习参考题1 ……………………… 32
第二章 一元二次函数、方程和不等式 …… 35
"""#, expected: #"""
第一章 集合与常用逻辑用语 1
	1.1 集合的概念 2
	1.2 集合间的基本关系 7
	阅读与思考 集合中元素的个数 10
	1.3 集合的基本运算 11
	小结 30
	复习参考题1 32
第二章 一元二次函数、方程和不等式 35
"""#, lowConfidenceLines: []),
        GoldenCase("cn_ocr_agent_format", input: #"""
前言	iii
第一章 数据结构绪论	1
  1.1 开场白	2
  1.2 你数据结构怎么学的?	3
  1.3 数据结构起源	4
第二章 算法	17
  2.1 开场白	18
  2.2 数据结构与算法关系	18
    2.2.1 两种算法的比较	19
附录A 参考答案	451
"""#, expected: #"""
第一章 数据结构绪论 1
	1.1 开场白 2
	1.2 你数据结构怎么学的? 3
	1.3 数据结构起源 4
第二章 算法 17
	2.1 开场白 18
	2.2 数据结构与算法关系 18
		2.2.1 两种算法的比较 19
附录A 参考答案 451
"""#, lowConfidenceLines: [1]),
        GoldenCase("en_ocr_messy", input: #"""
Chapter l Introduction ..... 1
Chapter 2 Background ..... 1l
Chapter 3 Methods ..... 2S
Chapter 4 Results ..... 48 '
"""#, expected: #"""
Chapter l Introduction 1
Chapter 2 Background 11
Chapter 3 Methods 25
Chapter 4 Results 48
"""#, lowConfidenceLines: [2, 3]),
        GoldenCase("cn_law_articles", input: #"""
第一编 总则
第一章 基本规定 ………………………… 1
第二章 自然人 …………………………… 5
第一节 民事权利能力和民事行为能力 …… 5
第二节 监护 ……………………………… 12
第二编 物权
第一分编 通则
第一章 一般规定 ………………………… 60
"""#, expected: #"""
第一编 总则 1
	第一章 基本规定 1
	第二章 自然人 5
		第一节 民事权利能力和民事行为能力 5
		第二节 监护 12
第二编 物权 60
	第一分编 通则 60
		第一章 一般规定 60
"""#, lowConfidenceLines: [1, 6, 7]),
        GoldenCase("cn_journal_volume", input: #"""
卷首语 …………………………………… 1
特稿
人工智能与教育的未来 ………………… 3
专题研究
大模型时代的课程设计 ………………… 15
编后记 …………………………………… 96
"""#, expected: #"""
卷首语 1
特稿 3
人工智能与教育的未来 3
专题研究 15
大模型时代的课程设计 15
编后记 96
"""#, lowConfidenceLines: [2, 4]),
        GoldenCase("en_prefixed", input: #"""
Chapter 2 Limits 77
Appendixes ........ A1
Index		A133
"""#, expected: #"""
Chapter 2 Limits 77
"""#, lowConfidenceLines: [2, 3]),
    ]
}
