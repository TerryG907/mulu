import Foundation
import Testing
@testable import MuluCore

@Suite struct TOCInteropTests {
    static let sample: [TOCEntry] = [
        TOCEntry(title: "前言", level: 0, page: 3, line: 1),
        TOCEntry(title: "第一章 绪论", level: 0, page: 9, line: 2),
        TOCEntry(title: "1.1 背景 & \"动机\" <draft>", level: 1, page: 9, line: 3),
        TOCEntry(title: "1.1.1 It's 'quoted'", level: 2, page: 10, line: 4),
        TOCEntry(title: "1.2 方法", level: 1, page: 14, line: 5),
        TOCEntry(title: "第二章 Results", level: 0, page: 30, line: 6),
        TOCEntry(title: "Index", level: 0, page: 99, line: 7),
    ]

    func triples(_ e: [TOCEntry]) -> [String] { e.map { "\($0.level)|\($0.title)|\($0.page)" } }

    @Test(arguments: [TOCFormat.mulu, .pdfpatcherXML, .opml, .json, .pdfdir])
    func roundTrip(_ format: TOCFormat) throws {
        let text = TOCInterop.write(Self.sample, format: format, title: "Book")
        let back = try TOCInterop.read(Array(text.utf8), format: format)
        #expect(triples(back.entries) == triples(Self.sample))
        #expect(back.warnings.isEmpty)
        #expect(TOCInterop.detect(Array(text.utf8), fileName: nil) == (format == .pdfdir ? .mulu : format))
    }

    // MARK: PDFPatcher

    @Test func pdfPatcherInfoFileInGB2312() throws {
        // Modeled on PDFPatcher's info-file format: GB2312, nested <书签>, 页码 = physical page.
        let xml = """
            <?xml version="1.0" encoding="gb2312"?>
            <PDF信息 程序名称="PDFPatcher" 程序版本="1.0" 导出时间="2026年01月01日 00:00:00">
            \t<度量单位 单位="点" />
            \t<文档书签>
            \t\t<书签 页码="1" 文本="封面" 动作="转到页面" />
            \t\t<书签 页码="2" 文本="第一章 总论" 动作="转到页面" 默认打开="是">
            \t\t\t<书签 页码="3" 文本="第一节 概述" 动作="转到页面">
            \t\t\t\t<书签 页码="3" 文本="一、定义" 动作="转到页面" 显示方式="坐标缩放" 上="792" />
            \t\t\t</书签>
            \t\t\t<书签 页码="5" 文本="第二节 历史" 动作="转到页面" />
            \t\t</书签>
            \t\t<书签 页码="10" 文本="附录 &amp; 索引" 动作="转到页面" />
            \t</文档书签>
            </PDF信息>
            """
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let bytes = [UInt8](try #require(xml.data(using: gb)))
        #expect(String(bytes: bytes, encoding: .utf8) == nil)  // really not UTF-8
        #expect(TOCInterop.detect(bytes, fileName: "info.xml") == .pdfpatcherXML)
        let r = try TOCInterop.read(bytes, format: .pdfpatcherXML)
        #expect(triples(r.entries) == ["0|封面|1", "0|第一章 总论|2", "1|第一节 概述|3", "2|一、定义|3", "1|第二节 历史|5", "0|附录 & 索引|10"])
        #expect(r.warnings.isEmpty)
    }

    @Test func pdfPatcherEnglishNamesAndNonLinks() throws {
        let xml = """
            <Info><Bookmarks>
              <Bookmark Title="Intro" Page="1"><Bookmark Title="Sub" Page="2"/></Bookmark>
              <Bookmark Title="Website" Action="打开网址" />
            </Bookmarks></Info>
            """
        let r = try TOCInterop.read(Array(xml.utf8), format: .pdfpatcherXML)
        #expect(triples(r.entries) == ["0|Intro|1", "1|Sub|2", "0|Website|2"])
        #expect(r.warnings.count == 2)
        #expect(r.warnings[0].contains("not a page link"))
    }

    @Test func pdfPatcherOutputShape() {
        let text = TOCInterop.write([TOCEntry(title: "A<&>", level: 0, page: 1, line: 1),
                                     TOCEntry(title: "B", level: 1, page: 2, line: 2)], format: .pdfpatcherXML)
        #expect(text == """
            <?xml version="1.0" encoding="utf-8"?>
            <PDF信息 程序名称="Mulu" 程序版本="0.3.3">
            \t<文档书签>
            \t\t<书签 文本="A&lt;&amp;&gt;" 动作="转到页面" 页码="1">
            \t\t\t<书签 文本="B" 动作="转到页面" 页码="2" />
            \t\t</书签>
            \t</文档书签>
            </PDF信息>

            """)
    }

    // MARK: OPML / JSON

    @Test func opmlWithMissingPagesAndTitleAttribute() throws {
        let opml = """
            <?xml version="1.0"?>
            <!-- exported by an outliner -->
            <opml version="1.0"><head><title>x</title></head><body>
            <outline title="Part One"><outline text="Ch 1" page="5"/><outline text="Ch 2" _page="17"/></outline>
            <outline text="Notes &#x4E00;" page="  40 "/>
            </body></opml>
            """
        let r = try TOCInterop.read(Array(opml.utf8), format: .opml)
        #expect(triples(r.entries) == ["0|Part One|1", "1|Ch 1|5", "1|Ch 2|17", "0|Notes 一|40"])
        #expect(r.warnings == ["line 4: 'Part One' has no page; using page 1"])
        #expect(throws: MuluError.self) { try TOCInterop.read(Array("<x/>".utf8), format: .opml) }
    }

    @Test func jsonShapes() throws {
        let flat = #"[{"title": "A", "level": 0, "page": 1}, {"title": "B", "level": 1, "page": "2"}]"#
        #expect(triples(try TOCInterop.read(Array(flat.utf8), format: .json).entries) == ["0|A|1", "1|B|2"])
        let nested = #"{"outline": [{"text": "A", "page": 1, "children": [{"name": "B", "page": 3}]}]}"#
        #expect(triples(try TOCInterop.read(Array(nested.utf8), format: .json).entries) == ["0|A|1", "1|B|3"])
        // `mulu dump-outline` output (0-based page_index, null for unresolvable)
        let dump = #"[{"title": "X", "level": 0, "page_index": 0}, {"title": "Y", "level": 3, "page_index": null}]"#
        let r = try TOCInterop.read(Array(dump.utf8), format: .json)
        #expect(triples(r.entries) == ["0|X|1", "1|Y|1"])
        #expect(r.warnings.count == 2)
        #expect(throws: MuluError.self) { try TOCInterop.read(Array("{\"a\": 1}".utf8), format: .json) }
        #expect(throws: MuluError.self) { try TOCInterop.read(Array("[1, 2]".utf8), format: .json) }
        #expect(throws: MuluError.self) { try TOCInterop.read(Array("[{".utf8), format: .json) }
        #expect(TOCInterop.write([], format: .json) == "[]\n")
    }

    // MARK: pdfdir

    @Test func pdfdirTitlePageConvention() throws {
        // Mirrors pdfdir's title+page convention: the page is glued to the title and optional.
        let text = """
            新版序言
            致读者
            前言
            第1章城市规划导论2
            第一编空间结构
            第2章街道与街区32
            结语605
            参考文献606
            """
        let r = try TOCInterop.read(Array(text.utf8), format: .pdfdir)
        #expect(triples(r.entries) == ["0|新版序言|1", "0|致读者|1", "0|前言|1", "0|第1章城市规划导论|2",
                                       "0|第一编空间结构|2", "0|第2章街道与街区|32", "0|结语|605", "0|参考文献|606"])
        #expect(r.warnings.count == 4)
    }

    @Test func pdfdirBracketsIndentAndOffset() throws {
        let text = "Intro (1)\n  Part A【3】\n    Deep 7\n  Part B - 9\nEnd [12]\n"
        let r = try TOCInterop.read(Array(text.utf8), format: .pdfdir)
        #expect(triples(r.entries) == ["0|Intro|1", "1|Part A|3", "2|Deep|7", "1|Part B|9", "0|End|12"])
        let shifted = try TOCInterop.shift(r.entries, by: 10)
        #expect(shifted.map(\.page) == [11, 13, 17, 19, 22])
        #expect(throws: MuluError.self) { try TOCInterop.shift(r.entries, by: -5) }
        #expect(TOCInterop.pdfdirSplit("Chapter-3").1 == -3)
        #expect(TOCInterop.pdfdirSplit("No page").1 == nil)
    }

    @Test func pdfdirGB18030Text() throws {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let bytes = [UInt8](try #require("第一章 总论 1\n第二章 分论 9\n".data(using: gb)))
        let r = try TOCInterop.read(bytes, format: .pdfdir)
        #expect(triples(r.entries) == ["0|第一章 总论|1", "0|第二章 分论|9"])
        #expect(TOCInterop.decodeText(bytes) == "第一章 总论 1\n第二章 分论 9\n")
    }

    // MARK: Mulu writer

    @Test func muluWriterAlwaysParses() throws {
        let tricky = [
            TOCEntry(title: "# not a comment", level: 0, page: 1, line: 1),
            TOCEntry(title: "  line\nbreak\ttab ", level: 1, page: 2, line: 2),
            TOCEntry(title: "", level: 1, page: 3, line: 3),
            TOCEntry(title: "\u{3000}全角缩进", level: 0, page: 4, line: 4),
            TOCEntry(title: "Ends with number 1984", level: 0, page: 5, line: 5),
            TOCEntry(title: "#tag", level: 1, page: 6, line: 6),
        ]
        let text = MuluTOCFormat.write(tricky)
        let back = try TOCParser.parse(text)
        #expect(triples(back) == ["0|＃ not a comment|1", "1|line break tab|2", "1|(untitled)|3", "0|全角缩进|4",
                                  "0|Ends with number 1984|5", "1|#tag|6"])
    }

    @Test func levelJumpsAreClampedWithWarnings() throws {
        let json = #"[{"title": "A", "level": 2, "page": 1}, {"title": "B", "level": 4, "page": 2}, {"title": "", "level": 1, "page": 0}]"#
        let r = try TOCInterop.read(Array(json.utf8), format: .json)
        #expect(triples(r.entries) == ["0|A|1", "1|B|2", "1|(untitled)|2"])
        #expect(r.warnings.count == 5)
    }

    @Test func outlineExport() {
        let items = [OutlineItemInfo(title: "A", level: 0, pageIndex: 0), OutlineItemInfo(title: "B", level: 1, pageIndex: nil),
                     OutlineItemInfo(title: "C", level: 0, pageIndex: 7)]
        let r = TOCInterop.entries(fromOutline: items)
        #expect(triples(r.entries) == ["0|A|1", "1|B|1", "0|C|8"])
        #expect(r.warnings == ["outline item 2: 'B' has no page; using page 1"])
    }

    @Test func detectFormats() {
        #expect(TOCInterop.detect(Array("  [ ]".utf8)) == .json)
        #expect(TOCInterop.detect(Array("<opml version='2.0'/>".utf8)) == .opml)
        #expect(TOCInterop.detect(Array("<PDF信息/>".utf8)) == .pdfpatcherXML)
        #expect(TOCInterop.detect(Array("A 1\n\tB 2\n".utf8)) == .mulu)
        #expect(TOCInterop.detect(Array("第1章导论2\n\t\t跳级 3\n".utf8)) == .pdfdir)
        #expect(TOCInterop.detect([], fileName: "x.opml") == .opml)
    }

    // MARK: MiniXML

    @Test func miniXMLParsesTheUsualConstructs() throws {
        let root = try MiniXML.parse("""
            <?xml version="1.0"?>
            <!DOCTYPE opml>
            <!-- c --><r a='1' b="&lt;&#65;&#x42;&amp;&quot;&apos;"><![CDATA[<ignored>]]><c/>text<d
              e = "multi
            line"/></r>
            """)
        #expect(root.name == "r")
        #expect(root.attribute("b") == "<AB&\"'")
        #expect(root.children.map(\.name) == ["c", "d"])
        #expect(root.children[1].attribute("E") == "multi line")  // case-insensitive fallback
        #expect(root.children[1].line == 3)
    }

    @Test(arguments: ["<a><b></a>", "<a b=1/>", "<a b='1' b='2'/>", "<a>", "", "<a/><b/>", "text<a/>",
                      "<!DOCTYPE a [<!ENTITY x 'y'>]><a/>", "<a b='&bogus;'/>", "<a b='<'/>"])
    func miniXMLRejects(_ xml: String) {
        #expect(throws: MiniXML.ParseError.self) { try MiniXML.parse(xml) }
    }

    @Test func xmlEscaping() {
        #expect(MiniXML.escape("a&b<c>\"d\"\te\u{01}") == "a&amp;b&lt;c&gt;&quot;d&quot;&#9;e")
    }
}

@Suite struct PrintedTOCEndToEndTests {
    /// Printed TOC → Mulu TOC → incremental update → outline read back → every export format.
    @Test func printedTOCThroughTheWriterAndBack() throws {
        let printed = """
            目　录
            前言 ………………………………… 1
            第一章 绪论 ………………………… 3
              1.1 研究背景 ……………………… 3
              1.2 研究意义与
                  方法 ………………………… 6
            第二章 相关工作 …………………… l2
              2.1 国内研究 ……………………… 13
              本章小结 ………………………… 20
            参考文献 …………………………… 45
            """
        let r = PrintedTOCParser.parse(printed, options: PrintedTOCOptions(offset: 4, pageCount: 60))
        #expect(triples(r.tocEntries) == ["0|前言|5", "0|第一章 绪论|7", "1|1.1 研究背景|7", "1|1.2 研究意义与方法|10",
                                          "0|第二章 相关工作|16", "1|2.1 国内研究|17", "1|本章小结|24", "0|参考文献|49"])
        let pdf = Fixtures.classic(pages: 60)
        let applied = try Mulu.apply(pdf: pdf, tocText: r.muluText(), offset: 0)
        #expect(Array(applied.output.prefix(pdf.count)) == pdf)
        let outline = try PDFFile(bytes: applied.output).readOutline()
        let exported = TOCInterop.entries(fromOutline: outline)
        #expect(exported.warnings.isEmpty)
        #expect(triples(exported.entries) == triples(r.tocEntries))
        for format in TOCFormat.allCases {
            let text = TOCInterop.write(exported.entries, format: format)
            #expect(triples(try TOCInterop.read(Array(text.utf8), format: format).entries) == triples(r.tocEntries), "\(format)")
        }
    }

    func triples(_ e: [TOCEntry]) -> [String] { e.map { "\($0.level)|\($0.title)|\($0.page)" } }
}

@Suite struct TOCInteropFuzzTests {
    @Test func readersNeverCrashOnGarbage() {
        var rng = PrintedTOCFuzzTests.XorShift(state: 0xD1B5_4A32_D192_ED03)
        let pieces = ["<", ">", "/", "书签", " 文本=\"", "\"", " 页码=\"", "3", "outline", "<opml>", "<body>", "&amp;", "&#",
                      "[", "]", "{", "}", "\"title\"", ":", ",", "\"page\"", "12", "\n", "\t", "  ", "第1章", "(", ")", "-", "页",
                      "<?xml", "?>", "<!--", "-->", "<![CDATA[", "]]>", "é", "\u{0}", "=", "'"]
        for _ in 0..<600 {
            var s = ""
            for _ in 0..<Int.random(in: 0...30, using: &rng) { s += pieces.randomElement(using: &rng)! }
            let bytes = Array(s.utf8)
            for format in TOCFormat.allCases {
                if let r = try? TOCInterop.read(bytes, format: format) {
                    for e in r.entries { #expect(e.page >= 1 && e.level >= 0 && !e.title.isEmpty) }
                    _ = try? TOCParser.parse(TOCInterop.write(r.entries, format: .mulu))
                }
            }
            _ = TOCInterop.detect(bytes)
        }
    }
}
