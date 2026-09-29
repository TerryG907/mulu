import Foundation
import Testing
@testable import MuluCore

@Suite struct TOCTests {
    @Test func tabsSpacesCommentsAndUnicode() throws {
        let text = "\u{FEFF}# comment\r\nIntro 1\r\n  Two spaces 2\r\n\tTab 3\r    Four spaces 4\n\t  Mixed 5\n\nZurück 6  \n中文 标题 99 7\n# trailing comment"
        let e = try TOCParser.parse(text)
        #expect(e.map(\.title) == ["Intro", "Two spaces", "Tab", "Four spaces", "Mixed", "Zurück", "中文 标题 99"])
        #expect(e.map(\.level) == [0, 1, 1, 2, 2, 0, 0])
        #expect(e.map(\.page) == [1, 2, 3, 4, 5, 6, 7])
        #expect(e.map(\.line) == [2, 3, 4, 5, 6, 8, 9])
    }

    @Test func titleMayContainTabsAndDigits() throws {
        let e = try TOCParser.parse("Chapter\t1984\t12\n")
        #expect(e == [TOCEntry(title: "Chapter\t1984", level: 0, page: 12, line: 1)])
    }

    @Test func oddSpaceIndentRoundsDown() throws {
        let e = try TOCParser.parse("A 1\n   B 2")
        #expect(e.map(\.level) == [0, 1])
        #expect(e[1].title == "B")
    }

    @Test func emptyTOC() throws {
        #expect(try TOCParser.parse("") == [])
        #expect(try TOCParser.parse("# only\n\n   \n") == [])
    }

    @Test(arguments: [
        "NoPage",          // no page token
        "Title 0",         // page must be positive
        "Title -3",        // not a positive integer
        "Title 1.5",       // not an integer
        "Title x",         // not a number
        "Title ３",        // full-width digit
        "\tIndented 1",    // first entry must be level 0
        "A 1\n\t\tB 2",    // level jump of 2
        "5",               // missing title
        "Title 99999999999999999999",  // overflow
    ])
    func syntaxErrors(_ text: String) {
        #expect(throws: MuluError.self) { try TOCParser.parse(text) }
    }

    @Test func errorsNameTheLine() {
        #expect(throws: MuluError.tocSyntax(line: 3, message: "page must be a positive integer, got 'x'")) {
            try TOCParser.parse("A 1\n# c\nB x")
        }
    }
}
