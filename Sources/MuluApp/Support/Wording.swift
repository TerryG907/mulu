import Foundation
import MuluAppModel
import MuluCore
import MuluOCR

/// User-facing wording for the model's enums (GUI_SPEC §7). Keys are the Chinese source text;
/// English comes from Localizable.xcstrings. English engine messages (MuluError, OCR notes,
/// OffsetReport.reason) are never translated and are shown as details.
enum Wording {
    /// "+8", "−3" or "0", with a real minus sign.
    static func signed(_ n: Int) -> String {
        if n > 0 { return "+\(n)" }
        if n < 0 { return "−\(-n)" }
        return "0"
    }

    static func formatName(_ format: TOCFormat) -> String {
        switch format {
        case .mulu: String(localized: "Mulu 文本")
        case .pdfpatcherXML: String(localized: "PDF补丁丁 XML")
        case .pdfdir: String(localized: "pdfdir 文本")
        case .opml: "OPML"
        case .json: "JSON"
        }
    }

    static func mergeMode(_ mode: MergeMode) -> String {
        switch mode {
        case .replace: String(localized: "替换当前目录")
        case .append: String(localized: "追加到末尾")
        case .insertAfterFocused: String(localized: "插入到选中行之后")
        }
    }

    // MARK: Rows

    static func doubt(_ reason: DoubtReason) -> String {
        switch reason.kind {
        case .unstableTitle:
            return String(localized: "标题在不同分辨率下读法不一致，请核对文字")
        case .enlargedTitle:
            return String(localized: "标题只从放大图里读出，请核对文字")
        case .lowConfidence:
            let share = reason.confidence.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "?"
            return String(localized: "识别把握低（\(share)）")
        case .pageOrder:
            return String(localized: "印刷页码比上一条小")
        case .noPage:
            return String(localized: "没有页码")
        case .locatedFromHeading:
            return String(localized: "页码是在正文页上找到标题后得出的")
        case .unresolvedDestination:
            return String(localized: "原目录项无法解析到页面，暂用上一条的页")
        case .importWarning:
            return String(localized: "导入时的提示")
        }
    }

    static func issue(_ issue: RowIssue) -> String {
        switch issue {
        case .emptyTitle:
            String(localized: "标题是空的")
        case .noPhysicalPage:
            String(localized: "没有页码")
        case let .pageOutOfRange(page, pageCount):
            String(localized: "第 \(page) 页超出范围（共 \(pageCount) 页）")
        case .pageBeforePrevious(let previous):
            String(localized: "页码比上一条（第 \(previous) 页）小")
        case .leadingHash:
            String(localized: "开头的 # 会写成 ＃（目录文本里行首的 # 表示注释）")
        }
    }

    static func status(_ status: RowStatus) -> String {
        switch status {
        case .ok: String(localized: "正常")
        case .doubtful: String(localized: "可疑")
        case .confirmed: String(localized: "已核对")
        case .error: String(localized: "有错")
        }
    }

    /// Every issue and reason of a row in Chinese, one per line; the parser's notes are
    /// translated where a pattern is known (the English originals are in `reasonDetails`).
    static func reasonLines(_ row: DisplayRow) -> [String] {
        row.issues.map(issue) + row.doubts.map(doubtLine)
    }

    /// The verbatim English notes behind the reasons (shown under 详情).
    static func reasonDetails(_ row: DisplayRow) -> [String] {
        row.doubts.map(\.detail).filter { !$0.isEmpty }
    }

    /// Tooltip of the check column: status, the Chinese reasons, then the English details.
    static func reasonTooltip(_ row: DisplayRow, status: String) -> String {
        var text = ([status] + reasonLines(row)).joined(separator: "\n")
        let details = reasonDetails(row)
        if !details.isEmpty {
            text += "\n\n" + String(localized: "详情：") + "\n" + details.joined(separator: "\n")
        }
        return text
    }

    /// One reason: its Chinese title plus the translated notes that add something to it.
    static func doubtLine(_ reason: DoubtReason) -> String {
        let base = doubt(reason)
        let notes: [String]
        switch reason.kind {
        case .lowConfidence, .noPage:
            notes = NoteTranslation.translate(reason.detail).filter { $0 != base && $0 != NoteTranslation.noPageNumber }
        default:
            notes = []
        }
        guard !notes.isEmpty else { return base }
        return String(localized: "\(base)：\(notes.joined(separator: String(localized: "；")))")
    }

    static func pageTooltip(_ row: DisplayRow, mapping: PageMapping) -> String {
        if row.pageOverride, let page = row.physicalPage {
            return String(localized: "手动固定为 PDF 第 \(page) 页")
        }
        guard let printed = row.printedPage else { return String(localized: "没有页码") }
        let offset = printed.style == .arabic ? mapping.offset : mapping.romanOffset
        guard let offset, let page = row.physicalPage else {
            return String(localized: "印刷页 \(printed.display) 还没有对应的 PDF 页：请设置前言偏移")
        }
        if row.sectionShift != 0 {
            return String(localized: "印刷页 \(printed.display) + 偏移 \(signed(offset)) + 本段 \(signed(row.sectionShift)) → PDF 第 \(page) 页")
        }
        return String(localized: "印刷页 \(printed.display) + 偏移 \(signed(offset)) → PDF 第 \(page) 页")
    }

    // MARK: Documents

    static func openFailureTitle(_ failure: OpenFailure) -> String {
        switch failure {
        case .encrypted: String(localized: "这个 PDF 已加密")
        case .notPDF: String(localized: "这不是 PDF 文件")
        case .noPages: String(localized: "这个 PDF 没有页面")
        case .unreadable: String(localized: "Mulu 无法处理这个 PDF")
        }
    }

    /// What the student can do next.
    static func openFailureAdvice(_ failure: OpenFailure) -> String {
        switch failure {
        case .encrypted:
            String(localized: "Mulu v0.1 还不能给加密的 PDF 写目录。如果你知道密码，可以在「预览」里打开它，用「文件 ▸ 导出为 PDF…」存一份不加密的副本，再用 Mulu 打开那份副本。")
        case .notPDF:
            String(localized: "Mulu 只能打开 PDF 文件。")
        case .noPages:
            String(localized: "没有页面的 PDF 没法加目录。")
        case .unreadable:
            String(localized: "文件可能已损坏。可以试试在「预览」里打开，用「文件 ▸ 导出为 PDF…」另存一份，再用 Mulu 打开。")
        }
    }

    // MARK: Recognition

    static func progress(_ progress: RecognitionProgress) -> String {
        switch progress.phase {
        case .readingTOC:
            let total = max(progress.total, 1)
            let current = min(progress.step + 1, total)
            return String(localized: "正在识别目录页（第 \(current)/\(total) 页）…")
        case .parsing: return String(localized: "正在解析目录文字…")
        case .detectingOffset: return String(localized: "正在找页码偏移…")
        case .checkingHeadings: return String(localized: "正在核对章标题…")
        case .frontMatter: return String(localized: "正在找前言页码…")
        case .locatingHeadings: return String(localized: "正在正文页里找标题…")
        case .finishing: return String(localized: "正在整理结果…")
        }
    }

    static func recognitionError(_ error: any Error) -> String {
        guard let error = error as? RecognitionError else { return String(describing: error) }
        switch error {
        case .notReady:
            return String(localized: "文档还没准备好。")
        case .alreadyRunning:
            return String(localized: "已经在识别了。")
        case .noPages:
            return String(localized: "请先选择目录页：在缩略图上按住 ⌘ 点选，或在这里输入页码范围。")
        case .tooManyPages(let count):
            return String(localized: "选了 \(count) 页。目录页最多 \(maxTOCPageCount) 页。")
        case .invalidPages(let detail):
            return String(localized: "页码范围看不懂：\(detail)")
        }
    }

    /// The headline of an advisory; an OCR note names its page ("第 5 页：识别提示").
    static func advisoryTitle(_ advisory: Advisory) -> String {
        if advisory.kind == .ocrWarning, let page = NoteTranslation.pageNumber(in: advisory.detail) {
            return String(localized: "第 \(page) 页：识别提示")
        }
        return advisoryTitle(advisory.kind)
    }

    /// The English detail as shown: without the CLI's advice ("review the TOC with --toc-out").
    static func advisoryDetail(_ advisory: Advisory) -> String {
        NoteTranslation.withoutCLIAdvice(advisory.detail)
    }

    /// What to do about it, in one line (nil when there is nothing to do).
    static func advisoryHint(_ kind: Advisory.Kind) -> String? {
        switch kind {
        case .noText:
            String(localized: "检查目录页选得对不对：在预览里翻到目录页，勾选「这是目录页」，再识别。")
        case .fewEntries:
            String(localized: "目录页可能没选全，或者选的不是目录页；也可以粘贴目录文字。")
        case .notTOCLike:
            String(localized: "检查选的是不是目录页；表格里的条目要逐条核对。")
        case .offsetUncertain, .offsetHeadingsDisagree:
            String(localized: "点一行，把预览翻到这一章真正的第一页，按 ⌘⇧L（按这一页校准偏移）。")
        case .offsetMayChange:
            String(localized: "找到页码开始错开的那一章，点它，把预览翻到它真正的第一页，用「从这一行起按这一页校准」（⌥⌘L）。")
        case .firstChapterBeforeTOC, .entriesBeyondLastPage:
            String(localized: "偏移多半不对：点第一章，把预览翻到它真正的第一页，按 ⌘⇧L。")
        case .romanUnresolved:
            String(localized: "在「前言偏移」里填上前言页的偏移，或者给这些行手动设页码（⌘L）。")
        case .tooManyDoubtful:
            String(localized: "按 ⌘⇧R 逐条审阅，改好再写入。")
        case .ocrWarning, .parserWarning:
            nil
        }
    }

    static func advisoryTitle(_ kind: Advisory.Kind) -> String {
        switch kind {
        case .noText: String(localized: "这几页没有识别出文字，它们是目录页吗？")
        case .fewEntries: String(localized: "带页码的条目太少")
        case .notTOCLike: String(localized: "大部分行不像目录")
        case .offsetUncertain: String(localized: "页码偏移没能确定")
        case .offsetHeadingsDisagree: String(localized: "页码和章标题给出的偏移不一致")
        case .offsetMayChange: String(localized: "偏移可能在书中间改变")
        case .firstChapterBeforeTOC: String(localized: "偏移让第一章落在目录页之前")
        case .entriesBeyondLastPage: String(localized: "大部分条目超出了最后一页")
        case .romanUnresolved: String(localized: "前言（罗马数字）页码没能对上")
        case .tooManyDoubtful: String(localized: "可疑条目太多")
        case .ocrWarning: String(localized: "识别提示")
        case .parserWarning: String(localized: "解析提示")
        }
    }

    /// Where the current offset came from, for the line under the offset field (GUI_SPEC §5.6).
    static func offsetCaption(_ info: OffsetInfo?) -> String? {
        guard let info else { return nil }
        switch info.source {
        case .given:
            return String(localized: "识别时给定的偏移")
        case .detected:
            if let evidence = info.evidence, evidence.samples > 0 {
                return String(localized: "自动检测：\(evidence.samples) 个抽样页中 \(evidence.agreeing) 页一致")
            }
            return String(localized: "自动检测")
        case .pageNumbersAndHeadings:
            return String(localized: "页码 + 章标题共同确认")
        case .bestGuess:
            return String(localized: "猜测，未确认")
        case .none:
            return String(localized: "偏移没能确定")
        case .manual:
            return String(localized: "手动设置")
        case .calibrated:
            if let page = info.calibratedFromPage {
                return String(localized: "按第 \(page) 页校准")
            }
            return String(localized: "按预览页校准")
        case .existingOutline:
            return String(localized: "PDF 原有目录的页码是固定页，不随偏移变")
        }
    }

    /// The offset line of a recognition result (GUI_SPEC §5.3 step 7).
    static func resultOffsetLine(_ result: RecognitionResult) -> String {
        let offset = signed(result.mapping.offset)
        switch result.offsetInfo.source {
        case .given:
            return String(localized: "偏移 \(offset)（你给定的）")
        case .detected:
            if let evidence = result.offsetInfo.evidence, evidence.samples > 0 {
                return String(localized: "偏移 \(offset)：\(evidence.samples) 个抽样页中 \(evidence.agreeing) 页一致")
            }
            return String(localized: "偏移 \(offset)")
        case .pageNumbersAndHeadings:
            let confirmed = result.offsetInfo.evidence?.headingsConfirmed ?? 0
            return String(localized: "偏移 \(offset)：页码和 \(confirmed) 个章标题共同确认")
        case .bestGuess, .none:
            return String(localized: "偏移没能确定，先按 \(offset) 放置")
        case .manual, .calibrated, .existingOutline:
            return String(localized: "偏移 \(offset)")
        }
    }

    // MARK: Writing

    static func writeError(_ error: WriteError) -> String {
        switch error {
        case .blocked: String(localized: "目录里还有需要先处理的条目。")
        case .wouldOverwriteInput: String(localized: "不能覆盖原文件。Mulu 只写新文件。")
        case .notWritable: String(localized: "不能写到这个位置。")
        case .inputChanged: String(localized: "原文件在打开后被改动过，请重新打开再写入。")
        case .refused: String(localized: "写入器拒绝了这份目录。")
        case .io: String(localized: "写文件时出错。")
        case .verificationFailed: String(localized: "写出的文件没有通过复核，已经删除。")
        }
    }

    static func blocker(_ blocker: WriteBlocker, title: String?) -> String {
        switch blocker {
        case .notReady:
            return String(localized: "文档还没准备好。")
        case .busy:
            return String(localized: "正在写入或识别，请稍候。")
        case .noRows:
            return String(localized: "目录是空的。")
        case let .row(_, index, rowIssue):
            let shown = shortTitle(title)
            return String(localized: "第 \(index + 1) 条「\(shown)」：\(issue(rowIssue))")
        }
    }

    static func shortTitle(_ title: String?) -> String {
        let trimmed = MuluTOCFormat.oneLine(title ?? "")
        guard !trimmed.isEmpty else { return String(localized: "（无标题）") }
        return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
    }
}
