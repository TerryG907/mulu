import Foundation
import MuluAppModel

/// Chinese for the parser's and the OCR reader's English notes (`ParserNote`). Notes without a
/// translation are left out of the Chinese line; the English text is always under 详情.
enum NoteTranslation {
    static var noPageNumber: String { String(localized: "目录上没有页码") }

    /// The translated notes of a doubt's detail, in order, without repeats.
    static func translate(_ detail: String) -> [String] {
        var out: [String] = []
        for note in ParserNote.parse(detail) {
            if let text = chinese(note), !out.contains(text) { out.append(text) }
        }
        return out
    }

    static func chinese(_ note: ParserNote) -> String? {
        switch note {
        case .noPageUsingNext(let title?):
            String(localized: "目录上没有页码，暂用下一条「\(title)」的页码")
        case .noPageUsingNext(nil):
            String(localized: "目录上没有页码，暂用下一条的页码")
        case .noPageUsingPrevious(let title?):
            String(localized: "目录上没有页码，暂用上一条「\(title)」的页码")
        case .noPageUsingPrevious(nil):
            String(localized: "目录上没有页码，暂用上一条的页码")
        case .noPage:
            noPageNumber
        case .unnumberedIndentation:
            String(localized: "没有编号，层级按缩进推断")
        case .unnumberedContext:
            String(localized: "没有编号，层级是按上下文猜的")
        case .levelLowered:
            String(localized: "层级被调低了（上面没有它的上一级条目）")
        case .pageTouchesTitle:
            String(localized: "页码和标题连在一起")
        case .pageLookAlikes:
            String(localized: "页码里有形近字（O、l、I），已按数字读")
        case .noTitleText:
            String(localized: "没有读出标题文字")
        case .twoColumnSplit:
            String(localized: "一行里有两栏，已拆开")
        case .secondColumn:
            String(localized: "这是一行里的第二栏")
        case .numeralRestored(let numbering):
            String(localized: "编号没识别出来，按前后章节补成「\(numbering)」")
        case let .numberingReadAs(read, meaning):
            String(localized: "编号「\(read)」按 \(meaning) 理解")
        case let .romanNumeralReadAs(read, meaning):
            String(localized: "罗马数字「\(read)」按 \(meaning) 理解")
        case .numberingDot:
            String(localized: "编号后面的点已处理")
        case .pageSplit(let page):
            String(localized: "页码 \(page) 被拆开识别，已合并")
        case .columnRereadsDisagree:
            String(localized: "页码列几次重读的结果不一致")
        case let .columnRereadKept(read, kept):
            String(localized: "页码列重读得到 \(read)，保留了 \(kept)")
        case let .columnRereadInstead(read, before):
            String(localized: "页码列重读为 \(read)（原来读成 \(before)）")
        case .singleLetterRoman:
            String(localized: "页码是单个字母的罗马数字")
        case .droppedFromTitle(let text):
            String(localized: "从标题末尾去掉了「\(text)」（误读的页码）")
        case .pageFromGlyph(let page):
            String(localized: "页码 \(page) 是按字形认出来的（没有识别出文字）")
        case .pageFromColumn(let page):
            String(localized: "页码 \(page) 是从整列页码里读出的")
        case let .titleChanged(from, to):
            String(localized: "标题有改动：「\(from)」→「\(to)」")
        case .titleFromRegion:
            String(localized: "标题是单独从标题区域读出的")
        case .readAsRomanI:
            String(localized: "读成 i，按页码顺序应为 1")
        case .readAsArabic1:
            String(localized: "读成 1，按页码顺序应为 i")
        case let .romanPageKept(first, second, kept):
            String(localized: "罗马数字页码读成 \(first) 和 \(second)，保留了 \(kept)")
        case .foundFromHeading(let page):
            String(localized: "页码是在正文第 \(page) 页找到标题后得出的")
        case .pageOrder:
            String(localized: "印刷页码比上一条小")
        case .unstableTitle:
            String(localized: "标题在不同分辨率下读法不一致")
        case .enlargedTitle:
            String(localized: "标题只从放大图里读出")
        case .other:
            nil
        }
    }

    static func pageNumber(in detail: String) -> Int? {
        ParserNote.pageNumber(in: detail)
    }

    static func withoutCLIAdvice(_ detail: String) -> String {
        ParserNote.withoutCLIAdvice(detail)
    }
}
