import Foundation

/// The numbering scheme a printed-TOC title starts with.
public enum HeadingKind: String, Sendable, CaseIterable {
    case part         // 第一篇 第一部分 第一编 第一卷 上篇 / Part I, Book One, Unit 2
    case subpart      // 第一分编 第一分册 (a division of a part)
    case chapter      // 第一章 第1章 第一回 第一讲 第一课 / Chapter 1, Lecture 3
    case section      // 第一节 考点一 / Section 4, §4
    case appendix     // 附录A 附录一 / Appendix A
    case dotted       // 1.1  1.1.1  A.1  Section 2.3 (depth = number of components)
    case arabic       // 1.  1、  1 Title
    case cnEnum       // 一、 二．
    case cnParen      // （一） (二)
    case arabicParen  // (1) （1） 1) ①
    case matter       // front/back matter: 前言 序 目录 参考文献 索引 后记 / Preface, Index
    case container    // a bare 附录 / Appendices heading that groups the appendix entries after it
    case trailer      // per-chapter items: 本章小结 习题 思考题 / Summary, Exercises
    case tocHeading   // 目录 / Contents with no page: the heading of the TOC page itself
    case none         // unnumbered
}

public struct Heading: Sendable, Equatable {
    public var kind: HeadingKind
    /// Numbers of the numbering, e.g. [3, 2] for "3.2"; empty when unnumbered.
    public var numbers: [Int] = []
    /// Normalised keyword for matter/trailer/tocHeading entries.
    public var keyword: String = ""
    /// True when OCR confusions (l → 1, O → 0) were repaired inside the numbering.
    public var ocrCorrected = false
    /// ① ② … (a circled number ranks below (1) (2) …).
    public var circled = false

    public var depth: Int { kind == .dotted ? numbers.count : 1 }
}

/// Recognises the numbering at the start of a printed-TOC title.
public enum HeadingClassifier {
    static let leadingMarkers: Set<Character> = ["*", "※", "△", "▲", "☆", "★", "▪", "■", "□", "◆", "◇", "●", "○", "►", "▶"]

    public static func classify(_ title: String) -> Heading {
        var h = Array(TOCChars.halfWidth(title))
        // Optional-section markers ("*1.5", "※第五节").
        while let f = h.first, leadingMarkers.contains(f) || f.isWhitespace { h.removeFirst() }
        while let l = h.last, l.isWhitespace { h.removeLast() }
        guard !h.isEmpty else { return Heading(kind: .none) }

        if let k = keywordHeading(h) { return k }
        if let k = chineseOrdinal(h) { return k }
        if let k = englishWord(h) { return k }
        if let k = symbolNumbering(h) { return k }
        if let k = dottedOrArabic(h) { return k }
        if let k = cnEnumeration(h) { return k }
        return Heading(kind: .none)
    }

    // MARK: keywords (matter, trailer, TOC heading, bare appendix)

    static func normalizedKey(_ h: [Character]) -> String {
        var s = String(h.filter { !$0.isWhitespace }).lowercased()
        while let l = s.last, ":：.。-—·".contains(l) { s.removeLast() }
        return s
    }

    static let tocHeadings: Set<String> = ["目录", "目次", "目錄", "contents", "tableofcontents", "简明目录", "详细目录", "总目录", "目录页", "brief contents", "briefcontents", "detailedcontents",
                                           // OCR slips of 目录 (目 read as 日 / 自, 录 as 彔)
                                           "日录", "自录", "目彔", "日錄",
                                           // other languages
                                           "tabledesmatières", "tabledesmatieres", "sommaire", "inhaltsverzeichnis", "inhalt",
                                           "índice", "indicegeneral", "contenido", "contenidos", "sumário", "sumario", "indice"]
    /// Continuation marks after a TOC heading: "目录（续）", "Contents (continued)".
    static let continuedSuffixes = ["(续)", "(續)", "(续前)", "续", "(continued)", "continued", "(cont'd)", "(cont.)", "(cont)", "(contd)"]
    /// Words of a column header line ("Chapter          Page", "章节 页码").
    static let columnHeaderWords: Set<String> = ["chapter", "chapters", "page", "pages", "section", "title", "contents", "part", "no", "pg", "p"]
    static let columnHeaderCN: Set<String> = ["章节页码", "章节页次", "页码", "页次", "标题页码", "内容页码"]
    /// Headings of a list of figures / tables (not part of the TOC proper).
    static let figureListHeadings: Set<String> = ["图表目录", "图目录", "表目录", "插图目录", "图表索引", "图片目录", "附图目录", "附表目录",
                                                  "插图与表格目录", "图与表目录", "listoffigures", "listoftables", "listofillustrations",
                                                  "listoffiguresandtables", "listoftablesandfigures", "figures", "tables", "illustrations"]

    /// The heading of a list of figures or tables ("图表目录", "List of Figures").
    public static func isFigureListHeading(_ title: String) -> Bool {
        let key = normalizedKey(Array(TOCChars.halfWidth(title))).filter { !$0.isWhitespace }
        return figureListHeadings.contains(key)
    }

    /// An entry of a list of figures or tables: "图1-1 需求曲线", "表 2.3 …", "Figure 4.1 …".
    public static func isFigureEntry(_ title: String) -> Bool {
        let h = Array(TOCChars.halfWidth(title))
        var i = 0
        for p in ["附图", "附表", "图", "表", "插图"] where String(h).hasPrefix(p) { i = p.count; break }
        if i == 0 {
            let lower = String(h).lowercased()
            for p in ["figure", "fig.", "fig", "table", "plate", "illustration"] where lower.hasPrefix(p) { i = p.count; break }
            guard i > 0 else { return false }
        }
        while i < h.count && h[i].isWhitespace { i += 1 }
        guard i < h.count else { return false }
        return TOCChars.isDigit(h[i]) || (TOCChars.isCNNumeral(h[i]) && i + 1 < h.count && !TOCChars.isCJK(h[i + 1]))
    }

    static let containers: Set<String> = ["附录", "附錄", "附录部分", "appendices", "appendixes", "appendix"]
    static let trailerPrefixesCN = [
        "本章", "本节", "本编", "本篇", "本部分", "本讲", "小结", "习题", "練習", "练习", "思考题", "复习思考题", "复习题", "思考与练习",
        "课后", "阅读材料", "延伸阅读", "拓展阅读", "扩展阅读", "案例分析", "真题", "历年真题", "典型例题", "强化训练",
        "知识框架", "知识结构", "学习目标", "学习要点", "章末", "同步练习", "自测题", "综合练习", "巩固练习",
    ]
    static let trailerEN: Set<String> = [
        "summary", "chaptersummary", "exercises", "exercise", "problems", "questions", "reviewquestions",
        "discussionquestions", "keyterms", "keyconcepts", "furtherreading", "suggestedreading", "suggestedreadings",
        "bibliographicnotes", "casestudy", "selftest", "self-test", "chapterreview", "review", "practice", "quiz",
        "keypoints", "learningobjectives", "objectives", "practiceproblems", "programmingexercises", "projects",
        "chapterexercises", "summaryandexercises", "checkyourunderstanding", "wrap-up", "recap",
    ]
    static let matterCN: Set<String> = [
        "序", "序言", "自序", "代序", "原序", "总序", "前言", "引言", "导言", "导论", "绪论", "緒論", "绪言", "楔子", "引子",
        "序章", "序幕", "尾声", "终章", "后记", "後記", "跋", "结语", "结束语", "结论", "结论与展望", "总结", "总结与展望", "参考文献", "参考书目",
        "主要参考文献", "参考资料", "索引", "名词索引", "人名索引", "主题索引", "术语表", "词汇表", "注释", "致谢", "谢辞",
        "鸣谢", "摘要", "中文摘要", "英文摘要", "内容提要", "内容简介", "出版说明", "出版者的话", "编者的话", "编者按",
        "写在前面", "作者简介", "作者介绍", "译者简介", "译后记", "译者后记", "译者序", "符号说明", "符号表", "主要符号表",
        "缩略语", "缩略词表", "图目录", "表目录", "插图目录", "版权", "封面", "扉页", "版权页", "献词", "题记", "使用说明",
        "阅读指南", "本书导读", "导读", "封底", "书名页", "编委会", "作者的话", "再版说明", "修订说明", "总复习题", "总习题",
    ]
    static let matterEN: Set<String> = [
        "preface", "foreword", "prologue", "epilogue", "afterword", "introduction", "contents", "acknowledgments",
        "acknowledgements", "acknowledgment", "acknowledgement", "dedication", "abstract", "bibliography", "references",
        "index", "glossary", "notes", "endnotes", "conclusion", "conclusions", "copyright", "colophon", "credits",
        "epigraph", "halftitle", "titlepage", "aboutthisbook", "abouttheauthor", "abouttheauthors", "abouttheeditors",
        "alsoby", "permissions", "nomenclature", "abbreviations", "sources", "cover", "subjectindex", "nameindex",
        "authorindex", "indexofnames", "selectedbibliography", "furtherresources", "illustrations", "maps",
        "timeline", "chronology", "praise", "frontispiece", "coda", "interlude", "postscript", "resume", "vita",
    ]

    static func keywordHeading(_ h: [Character]) -> Heading? {
        let key = normalizedKey(h)
        guard !key.isEmpty else { return nil }
        if tocHeadings.contains(key) { return Heading(kind: .tocHeading, keyword: key) }
        for suffix in continuedSuffixes where key.hasSuffix(suffix) && tocHeadings.contains(String(key.dropLast(suffix.count))) {
            return Heading(kind: .tocHeading, keyword: String(key.dropLast(suffix.count)))
        }
        if containers.contains(key) { return Heading(kind: .container, keyword: key) }
        if columnHeaderCN.contains(key) { return Heading(kind: .tocHeading, keyword: key) }
        let hasCJK = h.contains(where: TOCChars.isCJK)
        // Bilingual keyword: "Index 索引", "目录 Contents", "Preface 前言".
        if hasCJK, h.allSatisfy({ TOCChars.isCJK($0) || $0.isWhitespace || ($0.isASCII && $0.isLetter) || "&/·:：-—".contains($0) }) {
            let latin = String(h.filter { $0.isASCII && $0.isLetter }).lowercased()
            let cjk = String(h.filter(TOCChars.isCJK))
            if !latin.isEmpty && !cjk.isEmpty {
                if tocHeadings.contains(cjk) && tocHeadings.contains(latin) { return Heading(kind: .tocHeading, keyword: cjk) }
                if matterCN.contains(cjk) && matterEN.contains(latin) { return Heading(kind: .matter, keyword: cjk) }
            }
        }
        if !hasCJK {
            let words = String(h).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            if words.count >= 2, words.count <= 4, words.contains(where: { $0 == "page" || $0 == "pages" || $0 == "pg" }),
               words.allSatisfy(columnHeaderWords.contains), !h.contains(where: TOCChars.isDigit),
               words.contains(where: { ["chapter", "chapters", "section", "contents", "part", "no"].contains($0) }) {
                return Heading(kind: .tocHeading, keyword: "column header")
            }
        }
        if hasCJK {
            // Numbered exercises "习题一", "习题 1.2" are trailers too.
            for p in trailerPrefixesCN where key.hasPrefix(p) && key.count <= p.count + 14 {
                // "习题1-1" / "习题 2.3": exercises of a section (numbers kept to scope them)
                var numbers: [Int] = []
                var cur = ""
                for c in key.dropFirst(p.count) {
                    if let d = TOCChars.digit(c) { cur.append(Character(String(d))) }
                    else { if let v = Int(cur) { numbers.append(v) }; cur = "" }
                }
                if let v = Int(cur) { numbers.append(v) }
                return Heading(kind: .trailer, numbers: numbers, keyword: p)
            }
            if matterCN.contains(key) { return Heading(kind: .matter, keyword: key) }
            let n = key.count
            for suffix in ["序", "序言", "前言", "后记", "跋"] where key.hasSuffix(suffix) && n <= 10 && n > suffix.count {
                // "第二版序", "中文版序言", "译者前言"; not "程序" / "顺序" / "有序"
                let head = key.dropLast(suffix.count)
                if head.hasSuffix("版") || head.hasSuffix("者") || head.hasSuffix("本") || head.hasSuffix("文")
                    || head.hasSuffix("总") || head.hasSuffix("再") || head.hasSuffix("新") || head.hasSuffix("译")
                    || head.hasSuffix("自") || head.hasSuffix("作") || head.hasSuffix("原") || head.hasSuffix("代")
                    || head.hasSuffix("的") || head.hasSuffix("书") || head.hasSuffix("丛") || head.hasSuffix("主编") {
                    return Heading(kind: .matter, keyword: suffix)
                }
            }
            for p in ["参考文献", "攻读", "致谢", "索引", "主要符号", "作者简介"] where key.hasPrefix(p) {
                return Heading(kind: .matter, keyword: p)
            }
            if key.contains("声明") && n <= 16 && (key.contains("原创") || key.contains("独创") || key.contains("授权")) {
                return Heading(kind: .matter, keyword: "声明")
            }
            return nil
        }
        // English keywords only at the very start of the title ("3 Summary" is numbered).
        guard let f = h.first, f.isLetter else { return nil }
        let letters = key.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if trailerEN.contains(letters) { return Heading(kind: .trailer, keyword: letters) }
        if matterEN.contains(letters) { return Heading(kind: .matter, keyword: letters) }
        let words = String(h).lowercased().split(whereSeparator: { !$0.isLetter })
        if let first = words.first {
            let two = words.count >= 2 ? first + " " + words[1] : String(first)
            if ["preface", "foreword", "prologue", "epilogue", "afterword", "acknowledgments", "acknowledgements",
                "bibliography", "glossary", "index"].contains(String(first)) && words.count <= 8 {
                return Heading(kind: .matter, keyword: String(first))
            }
            if ["about the", "list of", "index of", "notes on", "notes to", "introduction to", "praise for", "also by",
                "table of"].contains(two) && words.count <= 8 {
                return Heading(kind: .matter, keyword: two)
            }
            if ["summary", "exercises", "problems"].contains(String(first)) && words.count <= 4 {
                return Heading(kind: .trailer, keyword: String(first))
            }
        }
        return nil
    }

    // MARK: 第X章 / 第X节 / 上篇 / 附录A / 考点一

    static let cnUnits: [(String, HeadingKind)] = [
        ("分编", .subpart), ("分册", .subpart), ("分卷", .subpart), ("分篇", .subpart),
        ("部分", .part), ("单元", .part), ("模块", .part), ("专题", .part), ("章", .chapter), ("节", .section),
        ("篇", .part), ("编", .part), ("卷", .part), ("部", .part), ("册", .part), ("集", .part), ("回", .chapter),
        ("讲", .chapter), ("课", .chapter), ("讲座", .chapter), ("幕", .part), ("场", .chapter), ("季", .part),
        ("辑", .part), ("單元", .part), ("節", .section), ("編", .part), ("講", .chapter), ("課", .chapter),
    ]

    static func readNumber(_ h: [Character], _ i: Int) -> (Int, Int, Bool)? {
        // CN numeral, ASCII digits (with OCR l/O repair when mixed with digits) or Roman.
        var j = i
        while j < h.count && TOCChars.isCNNumeral(h[j]) && j - i < 8 { j += 1 }
        if j > i, let v = TOCChars.chineseNumber(h[i..<j]) { return (v, j, false) }
        j = i
        var digits = "", fixed = false
        while j < h.count && j - i < 5 {
            if let d = TOCChars.digit(h[j]) { digits.append(Character(String(d))) }
            else if (h[j] == "l" || h[j] == "I" || h[j] == "O" || h[j] == "o") && (!digits.isEmpty || (j + 1 < h.count && TOCChars.isDigit(h[j + 1]))) {
                digits.append(h[j] == "l" || h[j] == "I" ? "1" : "0"); fixed = true
            } else { break }
            j += 1
        }
        if !digits.isEmpty, digits.contains(where: { $0 != "1" && $0 != "0" }) || !fixed || digits.count > 1,
           let v = Int(digits) { return (v, j, fixed) }
        j = i
        while j < h.count && TOCChars.isRomanChar(h[j]) && j - i < 8 { j += 1 }
        if j > i, let v = TOCChars.romanValue(h[i..<j]), j == h.count || !TOCChars.isLatinLetter(h[j]) { return (v, j, false) }
        return nil
    }

    static func chineseOrdinal(_ h: [Character]) -> Heading? {
        var i = 0
        func skipSpaces() { while i < h.count && h[i].isWhitespace { i += 1 } }
        if h[0] == "第" {
            i = 1
            skipSpaces()
            guard let (v, end, fixed) = readNumber(h, i) else {
                // OCR lost the numeral: "第节", "第：节", "第-章" (flagged, number unknown)
                var k = i
                while k < h.count && k - i < 2 && !TOCChars.isCJK(h[k]) && !TOCChars.isLatinLetter(h[k]) { k += 1 }
                let rest = String(h[k...])
                for (unit, kind) in cnUnits where ["章", "节", "篇", "编", "部分"].contains(unit) && rest.hasPrefix(unit) {
                    return Heading(kind: kind, numbers: [], ocrCorrected: true)
                }
                return nil
            }
            i = end
            skipSpaces()
            let rest = String(h[i...])
            for (unit, kind) in cnUnits where rest.hasPrefix(unit) {
                return Heading(kind: kind, numbers: [v], ocrCorrected: fixed)
            }
            return nil
        }
        // 上篇 / 下编 / 中卷 / 上册
        if h.count >= 2, "上中下".contains(h[0]), "篇编卷册部".contains(h[1]) {
            return Heading(kind: .part, numbers: [h[0] == "上" ? 1 : h[0] == "中" ? 2 : 3])
        }
        // 附录A / 附录 一 / 附录1
        let s = String(h)
        for p in ["附录", "附錄", "附 录"] where s.hasPrefix(p) {
            i = p.count
            skipSpaces()
            if i < h.count, h[i].isASCII, h[i].isUppercase, h[i].isLetter, i + 1 == h.count || !TOCChars.isLatinLetter(h[i + 1]) {
                return Heading(kind: .appendix, numbers: [Int(h[i].asciiValue! - 64)])
            }
            if let (v, _, fixed) = readNumber(h, i) { return Heading(kind: .appendix, numbers: [v], ocrCorrected: fixed) }
            return Heading(kind: .appendix, numbers: [])
        }
        // 考点一 / 知识点 3 / 题型二 / 专题一 / 单元一
        for (p, kind) in [("考点", HeadingKind.section), ("知识点", .section), ("题型", .section), ("专题", .chapter),
                          ("单元", .part), ("模块", .part), ("项目", .chapter), ("任务", .section), ("实验", .chapter)] where s.hasPrefix(p) {
            i = p.count
            skipSpaces()
            if let (v, end, fixed) = readNumber(h, i), end == h.count || !TOCChars.isLatinLetter(h[end]) {
                return Heading(kind: kind, numbers: [v], ocrCorrected: fixed)
            }
        }
        return nil
    }

    // MARK: Chapter 1 / Part I / Section 2.3 / Appendix A

    static let englishWords: [String: HeadingKind] = [
        "chapter": .chapter, "chap": .chapter, "ch": .chapter, "lecture": .chapter, "lesson": .chapter, "scene": .chapter,
        "part": .part, "book": .part, "volume": .part, "vol": .part, "unit": .part, "module": .part, "act": .part,
        "section": .section, "sec": .section, "appendix": .appendix, "annex": .appendix,
        // French / German / Spanish / Italian
        "chapitre": .chapter, "kapitel": .chapter, "capítulo": .chapter, "capitulo": .chapter, "capitolo": .chapter,
        "partie": .part, "teil": .part, "parte": .part, "annexe": .appendix, "anhang": .appendix,
    ]

    static func englishWord(_ h: [Character]) -> Heading? {
        var i = 0
        while i < h.count && h[i].isASCII && h[i].isLetter { i += 1 }
        guard i > 0 else { return nil }
        let word = String(h[0..<i]).lowercased()
        guard let kind = englishWords[word] else { return nil }
        // "PART", "Part", "part" — but "Chapter" must be followed by a number.
        if i < h.count && h[i] == "." { i += 1 }
        let wordEnd = i
        while i < h.count && h[i].isWhitespace { i += 1 }
        guard i < h.count, i > wordEnd || !TOCChars.isLatinLetter(h[i]) else { return nil }
        if kind == .appendix, h[i].isASCII, h[i].isUppercase, h[i].isLetter, i + 1 == h.count || !TOCChars.isLatinLetter(h[i + 1]) {
            return Heading(kind: .appendix, numbers: [Int(h[i].asciiValue! - 64)])
        }
        if TOCChars.isDigit(h[i]) {
            var comps: [Int] = []
            var j = i
            while j < h.count {
                var k = j
                while k < h.count && TOCChars.isDigit(h[k]) && k - j < 4 { k += 1 }
                guard k > j, let v = Int(TOCChars.halfWidth(String(h[j..<k]))) else { break }
                comps.append(v)
                j = k
                if j + 1 < h.count && h[j] == "." && TOCChars.isDigit(h[j + 1]) { j += 1 } else { break }
            }
            guard !comps.isEmpty, j == h.count || !TOCChars.isLatinLetter(h[j]) else { return nil }
            if comps.count >= 2 { return Heading(kind: .dotted, numbers: comps) }
            return Heading(kind: kind, numbers: comps)
        }
        // Roman numeral or number word
        var j = i
        while j < h.count && (h[j].isLetter || h[j] == "-") && h[j].isASCII { j += 1 }
        let token = String(h[i..<j])
        if let v = TOCChars.romanValue(token) ?? TOCChars.englishNumber(token) {
            return Heading(kind: kind, numbers: [v])
        }
        // OCR: "Chapter s" / "Chapter l" (5 / 1)
        if j - i == 1, kind != .part, kind != .appendix, let d = PageTokenizer.looseConfusables[h[i]], let v = Int(String(d)) {
            return Heading(kind: kind, numbers: [v], ocrCorrected: true)
        }
        if j > i, h[i].isUppercase, j - i == 1, kind == .part || kind == .section {
            return Heading(kind: kind, numbers: [Int(h[i].asciiValue! - 64)])
        }
        return nil
    }

    /// "1.1给药方案" / "4.2.1Checklist" → "1.1 给药方案" / "4.2.1 Checklist" (OCR drops the space).
    public static func spaceAfterNumbering(_ title: String) -> String {
        let cs = Array(title)
        var start = 0
        while start < cs.count && leadingMarkers.contains(cs[start]) { start += 1 }
        let h = cs.map(TOCChars.halfWidth)
        guard let m = dotted(h, from: start), m.numbers.count >= 2, m.end < cs.count else { return title }
        let next = cs[m.end]
        guard TOCChars.isCJK(next) || TOCChars.isLatinLetter(next) else { return title }
        return String(cs[..<m.end]) + " " + String(cs[m.end...])
    }

    // MARK: § 1.2, ①, (一), (1)

    static func symbolNumbering(_ h: [Character]) -> Heading? {
        let first = h[0]
        if first == "§" {
            var i = 1
            while i < h.count && h[i].isWhitespace { i += 1 }
            if let d = dotted(h, from: i) {
                return d.numbers.count >= 2 ? Heading(kind: .dotted, numbers: d.numbers, ocrCorrected: d.fixed)
                    : Heading(kind: .section, numbers: d.numbers, ocrCorrected: d.fixed)
            }
            return nil
        }
        if let v = TOCChars.scalar(first) {
            switch v {
            case 0x2460...0x2473: return Heading(kind: .arabicParen, numbers: [Int(v - 0x2460) + 1], circled: true)
            case 0x2474...0x2487: return Heading(kind: .arabicParen, numbers: [Int(v - 0x2474) + 1])
            case 0x2488...0x249B: return Heading(kind: .arabic, numbers: [Int(v - 0x2488) + 1])
            case 0x3220...0x3229: return Heading(kind: .cnParen, numbers: [Int(v - 0x3220) + 1])  // ㈠
            default: break
            }
        }
        let closers: [Character: Character] = ["(": ")", "[": "]", "〔": "〕", "【": "】", "<": ">"]
        guard let close = closers[first] else { return nil }
        var i = 1
        while i < h.count && h[i].isWhitespace { i += 1 }
        var j = i
        while j < h.count && TOCChars.isCNNumeral(h[j]) && j - i < 6 { j += 1 }
        var kind = HeadingKind.cnParen
        var value = j > i ? TOCChars.chineseNumber(h[i..<j]) : nil
        if value == nil {
            j = i
            while j < h.count && TOCChars.isDigit(h[j]) && j - i < 3 { j += 1 }
            if j > i { value = Int(TOCChars.halfWidth(String(h[i..<j]))); kind = .arabicParen }
        }
        guard let v = value else { return nil }
        while j < h.count && h[j].isWhitespace { j += 1 }
        guard j < h.count, h[j] == close || (close == ")" && h[j] == "）") else { return nil }
        return Heading(kind: kind, numbers: [v])
    }

    // MARK: 1.1 / 1.1.1 / A.1 / 1. / 1、 / 1 Title / 1)

    static let dottedSeparators: Set<Character> = [".", ":", "。", "·", ",", "-", "–", "_", "．", "•"]

    struct DottedMatch { var numbers: [Int]; var end: Int; var fixed: Bool; var letterFirst: Bool }

    static func dotted(_ h: [Character], from start: Int) -> DottedMatch? {
        var comps: [Int] = []
        var i = start
        var fixed = false
        var realDigits = 0
        var letterFirst = false
        while i < h.count && comps.count < 7 {
            var j = i
            var digits = ""
            while j < h.count && j - i < 3 {
                if let d = TOCChars.digit(h[j]) { digits.append(Character(String(d))); realDigits += 1 }
                else if h[j] == "l" || h[j] == "I" || h[j] == "O" || h[j] == "o" {
                    // OCR: "l.1" / "1.l" — only between separators/digits
                    let prevOK = j == i
                    let nextOK = j + 1 >= h.count || TOCChars.isDigit(h[j + 1]) || dottedSeparators.contains(h[j + 1]) || h[j + 1].isWhitespace
                    guard prevOK || !digits.isEmpty, nextOK else { break }
                    digits.append(h[j] == "l" || h[j] == "I" ? "1" : "0")
                    fixed = true
                } else { break }
                j += 1
            }
            if digits.isEmpty {
                // A single upper-case letter may open an appendix numbering: "A.1"
                if comps.isEmpty, i < h.count, h[i].isASCII, h[i].isUppercase, h[i].isLetter,
                   i + 2 < h.count, h[i + 1] == ".", TOCChars.isDigit(h[i + 2]) {
                    comps.append(Int(h[i].asciiValue! - 64))
                    letterFirst = true
                    j = i + 1
                } else {
                    break
                }
            } else {
                comps.append(Int(digits)!)
            }
            i = j
            if i + 1 < h.count, dottedSeparators.contains(h[i]),
               TOCChars.isDigit(h[i + 1]) || ((h[i + 1] == "l" || h[i + 1] == "I") && (i + 2 >= h.count || !TOCChars.isLatinLetter(h[i + 2]))) {
                i += 1
            } else {
                break
            }
        }
        guard !comps.isEmpty, realDigits > 0 else { return nil }
        if i < h.count && TOCChars.isDigit(h[i]) { return nil }
        return DottedMatch(numbers: comps, end: i, fixed: fixed, letterFirst: letterFirst)
    }

    static func dottedOrArabic(_ h: [Character]) -> Heading? {
        guard let m = dotted(h, from: 0) else { return nil }
        var i = m.end
        if m.numbers.count >= 2 {
            // A trailing dot is fine ("1.2."); the title must not continue with a digit or a unit.
            if i < h.count && (h[i] == "." || h[i] == "、") { i += 1 }
            // "1.5倍速", "1.5万亿", "2.5元": a quantity, not a section number.
            if i < h.count, "%％年月日时岁寸倍万亿千百兆元".contains(h[i]) { return nil }
            if m.numbers.count == 2 && !m.letterFirst && i < h.count && h[i] == ")" { return nil }
            return Heading(kind: .dotted, numbers: m.numbers, ocrCorrected: m.fixed)
        }
        guard !m.letterFirst, m.numbers[0] <= 999 else { return nil }
        let v = m.numbers[0]
        guard i < h.count else { return nil }  // a bare number is not a title
        let c = h[i]
        if c == ")" || c == "）" {
            return Heading(kind: .arabicParen, numbers: [v], ocrCorrected: m.fixed)
        }
        if c == "." || c == "、" || c == "．" || c == ":" || c == "," || c == "，" {
            var j = i + 1
            while j < h.count && h[j].isWhitespace { j += 1 }
            guard j < h.count, !TOCChars.isDigit(h[j]) else { return nil }
            return Heading(kind: .arabic, numbers: [v], ocrCorrected: m.fixed)
        }
        if c.isWhitespace {
            var j = i
            while j < h.count && h[j].isWhitespace { j += 1 }
            guard j < h.count, v <= 199, !TOCChars.isDigit(h[j]), !"年月日%个种项".contains(h[j]) else { return nil }
            return Heading(kind: .arabic, numbers: [v], ocrCorrected: m.fixed)
        }
        return nil
    }

    // MARK: 一、 二．

    static func cnEnumeration(_ h: [Character]) -> Heading? {
        var j = 0
        while j < h.count && TOCChars.isCNNumeral(h[j]) && j < 6 { j += 1 }
        guard j > 0, let v = TOCChars.chineseNumber(h[0..<j]) else { return nil }
        var i = j
        while i < h.count && h[i].isWhitespace { i += 1 }
        guard i < h.count else { return nil }
        if "、.,，:：·".contains(h[i]) {
            return Heading(kind: .cnEnum, numbers: [v])
        }
        if i > j && j <= 3 && !TOCChars.isDigit(h[i]) {
            return Heading(kind: .cnEnum, numbers: [v])
        }
        return nil
    }
}

// MARK: - OCR repairs of the numbering text

extension HeadingClassifier {
    /// 1...99 as Chinese numerals (一 … 十 … 九十九).
    static func chineseNumeral(_ n: Int) -> String? {
        let d: [Character] = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        switch n {
        case 1...9: return String(d[n])
        case 10: return "十"
        case 11...19: return "十" + String(d[n - 10])
        case 20...99: return String(d[n / 10]) + "十" + (n % 10 == 0 ? "" : String(d[n % 10]))
        default: return nil
        }
    }

    static let oddDottedSeparators: Set<Character> = [":", "。", ",", "·", "•"]
    static let strayAfterNumbering: Set<Character> = ["⋅", "·", "•", "∙", "・", "‧", "･"]

    /// Context-free repairs of OCR slips in the numbering text, each returned with a note:
    ///   "1:1.2 计算" → "1.1.2 计算"      (odd separator mixed with dots; "1-1" styles are kept)
    ///   "3.1.1.配置" → "3.1.1 配置"      (the space after a dotted number read as a dot)
    ///   "Part Iil …" → "Part III …"      (l / 1 / | / i for I in a roman numeral after Part/Chapter/…)
    ///   "第二节 ⋅赋役" → "第二节 赋役"     (a leader dot read between the numbering and the title)
    /// nil when nothing needs repair.
    public static func repairNumbering(_ title: String) -> (title: String, note: String)? {
        var cs = Array(title)
        var notes: [String] = []
        var start = 0
        while start < cs.count && (leadingMarkers.contains(cs[start]) || cs[start].isWhitespace) { start += 1 }
        let h = cs.map(TOCChars.halfWidth)
        if let m = dotted(h, from: start), m.numbers.count >= 2, !m.letterFirst {
            let span = h[start..<m.end]
            let seps = span.filter { !TOCChars.isDigit($0) }
            if seps.contains("."), seps.contains(where: { oddDottedSeparators.contains($0) }) {
                let canon = m.numbers.map(String.init).joined(separator: ".")
                cs.replaceSubrange(start..<m.end, with: Array(canon))
                notes.append("numbering '\(String(span))' read as \(canon)")
            }
            let end = dotted(cs.map(TOCChars.halfWidth), from: start)?.end ?? m.end
            if seps.contains(".") || m.numbers.count >= 2, end + 1 < cs.count,
               TOCChars.halfWidth(cs[end]) == ".", TOCChars.isCJK(cs[end + 1]) {
                cs[end] = " "
                notes.append("dot after the numbering read as a space")
            }
        }
        // Roman look-alikes after an English heading word.
        var i = start
        while i < cs.count && cs[i].isASCII && cs[i].isLetter { i += 1 }
        if i > start, let kind = englishWords[String(cs[start..<i]).lowercased()], [.part, .chapter, .section].contains(kind) {
            var j = i
            while j < cs.count && cs[j] == " " { j += 1 }
            var k = j
            while k < cs.count && "IiLl1|VvXx".contains(cs[k]) { k += 1 }
            let token = cs[j..<k]
            if j > i, k > j, token.count <= 6, k == cs.count || cs[k] == " ", TOCChars.romanValue(token) == nil,
               token.contains(where: { "IVX".contains($0) }) {
                let mapped = String(token.map { c -> Character in "iLl1|".contains(c) ? "I" : Character(c.uppercased()) })
                if TOCChars.romanValue(mapped) != nil {
                    cs.replaceSubrange(j..<k, with: Array(mapped))
                    notes.append("roman numeral '\(String(token))' read as \(mapped)")
                }
            }
        }
        // A leader dot between the numbering and the title.
        if let sp = cs.firstIndex(of: " "), sp <= start + 12, sp > start {
            var a = sp
            while a < cs.count && cs[a] == " " { a += 1 }
            var b = a
            while b < cs.count && strayAfterNumbering.contains(cs[b]) { b += 1 }
            if b > a, b < cs.count, cs[b].isLetter || TOCChars.isCJK(cs[b]),
               classify(String(cs[start..<sp])).kind != .none || classify(String(cs)).kind != .none {
                cs.removeSubrange(a..<b)
                notes.append("stray dot after the numbering removed")
            }
        }
        guard !notes.isEmpty else { return nil }
        return (String(cs), notes.joined(separator: "; "))
    }

    /// "第章 两汉" / "第：节 考据" — `title` with the numeral OCR lost put back ("第一章 两汉"),
    /// in Chinese numerals or digits (`chinese`). nil when the title is not such a heading.
    static func insertOrdinal(_ title: String, value: Int, chinese: Bool) -> String? {
        let cs = Array(title)
        guard let f = cs.firstIndex(of: "第"), cs[..<f].allSatisfy({ leadingMarkers.contains($0) || $0.isWhitespace }) else { return nil }
        var k = f + 1
        while k < cs.count && k - f <= 3 && !TOCChars.isCJK(cs[k]) && !TOCChars.isLatinLetter(cs[k]) { k += 1 }
        let rest = String(cs[k...])
        guard let unit = ["部分", "章", "节", "篇", "编"].first(where: { rest.hasPrefix($0) }),
              let numeral = chinese ? chineseNumeral(value) : String(value) else { return nil }
        var after = String(rest.dropFirst(unit.count))
        if let c = after.first, !c.isWhitespace { after = " " + after }
        return String(cs[..<f]) + "第" + numeral + unit + after
    }
}
