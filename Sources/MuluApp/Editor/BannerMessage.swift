import MuluAppModel
import SwiftUI

/// The text and buttons of a `Banner`.
struct BannerMessage: View {
    let banner: Banner
    let session: DocumentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch banner {
            case .loadedExisting(let count):
                Text("已载入 PDF 里原有的目录（\(count) 条）")
            case let .recognitionApplied(count, doubtful):
                Text("已采用识别结果：\(count) 条")
                if doubtful > 0 {
                    HStack {
                        Text("有 \(doubtful) 条可疑，按 ⌘⇧R 逐条核对")
                        Button("审阅", action: session.toggleReview)
                            .controlSize(.small)
                    }
                }
            case .imported(let report):
                Text("已导入 \(report.count) 条（来自 \(Wording.formatName(report.format))，\(Wording.mergeMode(report.mode))）")
                ForEach(Array(report.warnings.prefix(3).enumerated()), id: \.offset) { _, warning in
                    Text(verbatim: warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .wrote(let report):
                let size = Int64(report.appendedBytes).formatted(.byteCount(style: .file))
                Text("已生成「\(report.output.lastPathComponent)」（\(report.items) 条书签）。原 PDF 没有任何改动；新文件保留原文件的全部内容，只在末尾追加了 \(size)。")
                HStack {
                    Button("在 Finder 中显示") {
                        session.revealInFinder(report.output)
                    }
                    Button("打开") {
                        session.openWithDefaultApp(report.output)
                    }
                }
                .controlSize(.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
