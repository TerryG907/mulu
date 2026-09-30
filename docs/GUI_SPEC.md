# Mulu GUI v0.1 规格（GUI_SPEC）

状态：定稿，分两部分并行实现（A：模型层，B：界面层）。基线：`main` @ `04161b2`。日期：2026-09-30。

> 实现之后又做过一轮评审和修改（预览栏、审阅栏、分段校准、关窗释放文档等）。用法和最终行为以 [GUI.md](GUI.md) 为准；本文保留为设计记录。

> 一句话：真实扫描书上自动识别目录很弱（17 本里 1 本自动成功，0 本写错），所以 GUI 的核心不是「一键成功」，而是**先给出草稿，再让人快速改对**：点一行，右边预览立刻跳到那一页；改偏移，全部页码立刻跟着变；最后用和 `mulu apply` 完全相同的写入路径（含自检）另存为新 PDF，原文件一个字节都不动。

目录

0. 目标、非目标、分工
1. 已验证的事实（本次实验）
2. 目标与 Package.swift 改动（精确）
3. 与现有代码的关系
4. 文档模型
5. 流程
6. 窗口布局与交互
7. 文案与本地化
8. 打包
9. 测试计划
10. 公共 API 契约（MuluAppModel）
11. 风险与 v0.2 清单

---

## 0. 目标、非目标、分工

### 0.1 v0.1 目标（P0 = 必须，P1 = 应该，P2 = 可以）

| # | 功能 | 优先级 |
|---|---|---|
| G1 | 打开 PDF：拖放、⌘O、Finder「打开方式」 | P0 |
| G2 | 已有目录的 PDF：自动载入目录供编辑 | P0 |
| G3 | 识别目录页：缩略图里点选或输入页码范围 → OCR + 解析 + 偏移检测（后台、有进度、可取消）→ 替换或合并到草稿；可疑行高亮并写明原因 | P0 |
| G4 | 偏移：全局偏移；选中行（一段）±N；用当前预览页校准偏移 | P0 |
| G5 | 行编辑：改标题、改页码、缩进/减少缩进、上移/下移、添加同级/子级、删除；撤销/重做 | P0 |
| G6 | 点一行 → 预览跳到它的物理页；预览停在别的页时可一键「设为本行页码」 | P0 |
| G7 | 审阅模式：逐条（或只看可疑）走一遍，回车确认并下一条 | P0 |
| G8 | 导入/导出：mulu、PDF补丁丁 XML、pdfdir、OPML、JSON（MuluCore TOCInterop） | P0 |
| G9 | 写入：「写入目录…」→ 保存面板，默认 `<name>-目录.pdf`，v0.1 永不覆盖输入文件；走 `Mulu.apply`（含自检）；成功横幅「原文件字节未改动，追加了 N KB」+ 在 Finder 中显示；失败显示写入器原文 | P0 |
| G10 | 中文界面 + 英文本地化（Localizable.xcstrings，已验证 SwiftPM 能编译） | P0 |
| G11 | `scripts/package_app.sh` 打出 `dist/Mulu.app` + zip（ad-hoc 签名） | P0 |
| G12 | 烟雾模式 `MULU_SMOKE`（打开 → 可选识别 → 可选写入 → JSON → 20 秒内退出） | P0 |
| G13 | 粘贴目录文字（相当于 `mulu toc parse`：从豆瓣/书店复制的目录直接变草稿） | P1 |
| G14 | 关闭有未写入修改的窗口时确认；退出时确认 | P1（退出确认 P0） |
| G15 | 最近打开菜单、草稿自动保存、拖动排序、App 图标 | P2 |

### 0.2 非目标（v0.1 不做）

- 覆盖原文件、原地保存。（写入永远是新文件。）
- 加密 PDF（MuluCore 拒绝；界面给出说明）。
- 竖排目录、分析式老目录的专门识别（见 docs/REALSCAN.md）。
- App Sandbox、公证（notarization，需要 Developer ID，见 §8.5）、Mac App Store。
- 通用二进制（v0.1 只出 arm64，见 §8.1）。

### 0.3 分工（两部分并行）

| | A：模型 | B：界面 |
|---|---|---|
| 负责目录 | `Sources/MuluAppModel/`、`Tests/MuluAppModelTests/`、`Package.swift`、`.gitignore`、MuluOCR 的两处**纯加法**钩子（§3.2）及其测试 | `Sources/MuluApp/`（含 `Resources/Localizable.xcstrings`）、`scripts/package_app.sh`、`scripts/smoke_app.sh`、`scripts/check_strings.py` |
| 第一件事 | 30 分钟内落地 §10 全部公共类型和方法签名（方法体可以是最小实现），保证 `swift build` 通过；之后只做**增量**修改，签名冻结 | 先用 `DocumentModel(previewRows:pageCount:)`（§10）搭界面，不等识别流水线 |
| 构建 | `nice -n 15 swift build` / `swift test`（默认 `.build`） | `nice -n 15 swift build --scratch-path .build-ui --product MuluApp`（避免与 A 抢 `.build` 锁） |

规则：

- 两部分各自开发时**不提交、不推送**，集成后统一提交。不改 MuluCore 的任何文件。MuluOCR 只允许 §3.2 的两处加法。
- 签名冻结后如需改 API：只能新增（新方法、新 case 需同时更新 §10 表格并告知对方），不能改名或删。
- 长命令一律后台运行、输出写日志、`sleep 20; tail -5 log` 轮询；单个前台命令不超过约 90 秒。
- 只有任务明确要求时才开 GUI 窗口；开了要马上关；不留下运行中的 App。测试和烟雾只用程序生成的 PDF 或仓库 `Fixtures/generated`、`Fixtures/books` 下的合成书，**不读用户的个人文件**。**不要**用 `Fixtures/regression/` 里的 PDF 做 GUI 测试（那些是故意构造的恶意文件，README 说明了会让某些 PDF 库崩溃；PDFKit 不应打开它们）。

验收（v0.1 完成的定义）：`swift test` 全绿（原有 185 个 + 新增）；`tools/run_all.sh` 仍是 31/31 + 47/47；`scripts/smoke_app.sh` 的 A–D 段通过（§9.3）；`scripts/package_app.sh` 产出能启动的 `dist/Mulu.app`；§9.5 的手工清单由维护者过一遍。

---

## 1. 已验证的事实（本次实验，2026-09-30）

环境：Apple M5 Pro，macOS 26.6.2（25G83），Xcode 27（SDK macosx27.0），Swift 6.4（swiftlang-6.4.0.34.1）。在一个临时目录里建了一个最小 SwiftPM 包（`swift-tools-version: 6.0`，`defaultLocalization: "zh-Hans"`，一个 `executableTarget`，`@main struct …: App` + `WindowGroup`，`resources: [.process("Localizable.xcstrings")]`），做完已删除，LaunchServices 注册已用 `lsregister -u` 撤销，没有进程残留。

| # | 事实 | 对设计的影响 |
|---|---|---|
| F1 | `swift build` 5.7 秒构建成功；从 `.build/debug/ExpApp` 直接运行：SwiftUI 生命周期正常（视图的 `.task` 执行了），`NSApp.windows` 有 1 个 `isVisible == true` 的 900×450 窗口，窗口服务器里有对应的窗口（layer 0，bounds 900×450），2 秒后 `NSApp.terminate` 正常退出，退出码 0。 | SwiftPM 可执行目标 + SwiftUI App 生命周期可行。 |
| F2 | 未打包运行时 `NSApp.activationPolicy()` 为 `.prohibited`（rawValue 2）：没有 Dock 图标、没有菜单栏、不能成为活跃应用。 | 未打包运行（`Bundle.main.bundleIdentifier == nil`）时，在 `applicationWillFinishLaunching` 里 `NSApp.setActivationPolicy(.regular)`，`applicationDidFinishLaunching` 里 `NSApp.activate()`。打包后通过 LaunchServices 启动时策略本来就是 `.regular`（已验证）。 |
| F3 | 实验时用户前台是一个全屏 App（屏幕上只有它的窗口），我们的窗口创建了但不在当前 Space 上（`isOnActiveSpace == false`，窗口服务器不报 onscreen），`.regular` 策略、`canJoinAllSpaces`、`fullScreenAuxiliary` 都不改变这一点。 | **自动化测试不能断言窗口在屏幕上或处于活跃状态**。烟雾模式只报告 `NSApp.windows.filter(\.isVisible).count`。「窗口真的画出来了」由维护者在 §9.5 里用眼睛确认。 |
| F4 | SwiftPM 把 `Localizable.xcstrings` 编译进资源包：`<包名>_<目标名>.bundle/Contents/Resources/en.lproj/Localizable.strings`（源语言 zh-Hans 不生成 lproj，键本身就是中文文案；包的 Info.plist 有 `CFBundleDevelopmentRegion = zh-Hans`）。`Bundle.module.localizations == ["en", "zh-Hans"]`；英文查表：「打开」→ "Open"，「共 %lld 页」→ "%lld pages"。 | 可以做中英双语。命令行 SwiftPM **不会**像 Xcode 那样自动把代码里的字符串抽取进 xcstrings，必须手工维护（用 `scripts/check_strings.py` 检查，§7.3）。 |
| F5 | 生成的 `resource_bundle_accessor.swift` 先在 `Bundle.main.resourceURL` 找资源包，其次 `Bundle.main.bundleURL`；找不到就 `fatalError`。把资源包复制到 `.app/Contents/Resources/` 后 `Bundle.module` 能找到（已验证）。`.build/debug` 实际指向 `.build/out/Products/Debug`。 | 打包脚本用 `swift build --show-bin-path` 取产物路径，把 `mulu_MuluApp.bundle` 复制进 `Contents/Resources/`。 |
| F6 | 打包后的 App 在 Info.plist 写了 `CFBundleDevelopmentRegion = zh-Hans` 和 `CFBundleLocalizations = [zh-Hans, en]`：以 `-AppleLanguages (zh-Hans)` 启动，`Bundle.main`/`Bundle.module` 的 `preferredLocalizations == ["zh-Hans"]`；按本机默认语言（en-AU 优先，zh-Hans-AU 其次）启动为 `["en"]`。未打包运行时 `Bundle.module` 永远选 `en`（因为主包没有本地化信息）。 | Info.plist 必须写 `CFBundleLocalizations`。**这台 Mac 的首选语言是英文**，所以手工验收时默认看到英文界面；看中文用 `-AppleLanguages "(zh-Hans)"`。 |
| F7 | 用 `open -a Exp.app file.pdf`（与 Finder「打开方式」相同的 odoc 事件）：文件 URL 交给了 SwiftUI 的 `.onOpenURL`；`NSApplicationDelegateAdaptor` 的 `application(_:open:)` 被调用但**收到空数组**（SwiftUI 已经拿走）。 | **不要**依赖 AppDelegate 收文件；只用 `.onOpenURL`。 |
| F8 | 默认 `WindowGroup`：冷启动时带文件 → 出现 2 个窗口（1 个空的 + 1 个收到 URL 的）。加上场景的 `.handlesExternalEvents(matching: ["*"])` 和根视图的 `.handlesExternalEvents(preferring: ["*"], allowing: ["*"])` 后：运行中再打开第二个文件 → 交给已有窗口的 `.onOpenURL`，不再新建窗口；冷启动带文件仍是 2 个窗口。 | 窗口路由按 §6.8 做：收到 URL 的窗口自己决定「接管」还是 `openWindow(value:)`；冷启动时多出来的空窗口自行关闭。改成 `WindowGroup(for: URL.self)` 后需要重新确认（烟雾 C 段）。 |
| F9 | 在 Swift 6 严格并发下，`@MainActor @Observable` 类用 `undoManager.registerUndo(withTarget: self) { t in MainActor.assumeIsolated { … } }` 做「整份快照」撤销能编译；`groupsByEvent = false` 且每次修改自己 `beginUndoGrouping`/`endUndoGrouping` 时，撤销、重做结果正确。窗口里的 `@Environment(\.undoManager)` 非 nil。 | §4.7 的撤销方案可行。 |
| F10 | `LSHandlerRank = None` 的 App 仍可被 `open -a` 指定打开 PDF。 | 正式 Info.plist 用 `LSHandlerRank = Alternate`：出现在「打开方式」里，但永远不会抢走「预览」的默认打开（§8.3）。 |

---

## 2. 目标与 Package.swift 改动（精确）

### 2.1 新 Package.swift（完整替换）

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mulu",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MuluCore", targets: ["MuluCore"]),
        .executable(name: "mulu", targets: ["mulu"]),
        .executable(name: "MuluApp", targets: ["MuluApp"]),
    ],
    targets: [
        // Pure-Swift PDF reader + incremental-update writer. No dependencies beyond
        // Foundation and Apple's Compression framework (for inflate).
        .target(name: "MuluCore"),
        // Vision/CoreGraphics OCR of printed TOC pages and page-number offset detection
        // (macOS only). Linked into the CLI and the app; MuluCore stays framework-free.
        .target(name: "MuluOCR"),
        // GUI logic without views: document and outline-draft model, recognition pipeline,
        // writer glue, thumbnails, smoke runner. Unit-tested; no SwiftUI/PDFKit.
        .target(name: "MuluAppModel", dependencies: ["MuluCore", "MuluOCR"]),
        .executableTarget(name: "mulu", dependencies: ["MuluCore", "MuluOCR"]),
        // The macOS app: SwiftUI App lifecycle, views, AppKit/PDFKit bridges.
        // scripts/package_app.sh bundles the binary into dist/Mulu.app.
        .executableTarget(
            name: "MuluApp",
            dependencies: ["MuluAppModel", "MuluCore", "MuluOCR"],
            resources: [.process("Resources/Localizable.xcstrings")]),
        .testTarget(name: "MuluCoreTests", dependencies: ["MuluCore"]),
        .testTarget(name: "MuluOCRTests", dependencies: ["MuluOCR"]),
        .testTarget(name: "MuluAppModelTests", dependencies: ["MuluAppModel", "MuluCore", "MuluOCR"]),
    ]
)
```

与现状的差异只有：`defaultLocalization`、`MuluApp` 产品、`MuluAppModel` 与 `MuluApp` 两个目标、`MuluAppModelTests`。`MuluCore`、`MuluOCR`、`mulu` 的定义不变。

命名约束：

- 可执行产品叫 `MuluApp`，**不能叫 `Mulu`**：macOS 文件系统默认不区分大小写，`.build/release/Mulu` 会和 CLI 的 `.build/release/mulu` 撞名。打包时再改名为 `Mulu.app/Contents/MacOS/Mulu`。
- `@main` 的结构体叫 `MuluMacApp`，不要和模块名 `MuluApp` 同名（同名会让 `MuluApp.X` 这类限定名产生歧义）。
- SwiftPM 资源包名是 `mulu_MuluApp.bundle`（包名 `mulu` + 目标名）。

### 2.2 .gitignore 增加

```
# GUI build/packaging outputs
.build-ui/
dist/
```

### 2.3 目录结构

```
Sources/MuluAppModel/
  Draft/        OutlineRow.swift  OutlineDraft.swift  DraftOperations.swift  PageMapping.swift
                RowIssues.swift  DisplayRows.swift
  Document/     DocumentModel.swift (+ DocumentModel+Editing/Selection/Review/ImportExport/Write.swift)
                PDFSummary.swift  FileFingerprint.swift
  Recognition/  RecognitionTypes.swift  RecognitionPipeline.swift  DraftBuilder.swift
                AutoHeuristics.swift   ← 移植自 Sources/mulu/AutoCommand.swift（§3.3）
  Write/        OutlineWriter.swift
  Thumbnails/   ThumbnailRenderer.swift
  Smoke/        SmokeConfig.swift  SmokeReport.swift  SmokeRunner.swift
Sources/MuluApp/
  MuluMacApp.swift  AppDelegate.swift  AppState.swift  Commands.swift
  Window/       DocumentWindow.swift  EmptyStateView.swift  FailedView.swift  WindowAccessor.swift
  Sidebar/      ThumbnailSidebar.swift
  Preview/      PDFPreview.swift (NSViewRepresentable)  PreviewOverlay.swift
  Editor/       OutlineEditor.swift  OutlineTable.swift (NSViewRepresentable + NSTableView 子类)
                OffsetBar.swift  AdvisoryList.swift  ReviewHUD.swift  StatusBar.swift
  Sheets/       RecognizeSheet.swift  PasteTOCSheet.swift  WriteFlow.swift  ImportExportFlow.swift
  Smoke/        SmokeDriver.swift
  Resources/    Localizable.xcstrings
Tests/MuluAppModelTests/   见 §9.1
Tests/MuluOCRTests/ProgressHookTests.swift   （新文件，§3.2）
scripts/  package_app.sh  smoke_app.sh  check_strings.py
```

---

## 3. 与现有代码的关系

### 3.1 用到的现有公共 API（只读，不改）

| 用途 | API | 备注 |
|---|---|---|
| 打开、读已有目录 | `PDFFile(bytes:)`、`.isEncrypted`、`.pageRefs()`、`.readOutline() -> [OutlineItemInfo]`、`.info() -> DocumentInfo` | `PDFFile` 是非 Sendable 的 class：只在后台任务里局部创建、用完即弃，不跨 actor 传递。 |
| 写入 | `Mulu.apply(pdf: [UInt8], tocText: String, offset: Int) throws -> ApplyResult` | **唯一的写入入口**，与 `mulu apply` 相同，内部含 `selfCheck`（前缀、重新解析、坐标系、startxref、目录回读、页数、无扫描修补）。`selfCheck` 不是 public，所以不能绕开 `apply` 自己拼 `IncrementalWriter`。 |
| 草稿 → 文本 | `MuluTOCFormat.write([TOCEntry])`、`MuluTOCFormat.oneLine(_:)` | 行格式 `TABs + 标题 + 空格 + 页码`；标题里的换行/TAB/控制字符变空格、连续空白合并；**0 级标题以 `#` 开头时写成全角 `＃`**（否则是注释）。 |
| 导入导出 | `TOCFormat`、`TOCInterop.read/detect/write/entries(fromOutline:)/decodeText` | 除 pdfdir 外页码都是物理页；pdfdir 是印刷页（§5.9）。 |
| 印刷目录解析 | `PrintedTOCParser.parse(_:options:)`、`PrintedTOCOptions`、`PrintedTOCResult`（`entries`、`tocEntries`、`lowConfidenceEntries`、`orderViolations`、`warnings`、`muluText(header:annotate:)`）、`PrintedTOCEntry`、`PrintedPage`、`HeadingKind` | |
| OCR | `TOCPageReader(url:).read(pages:options:)`、`TOCReadResult`（`lines`、`warnings`、`folios`）、`TOCPageReader.unstableNote`、`.enlargedTitleNote`、`parsePageList(_:pageCount:)`、`maxTOCPageCount`（40） | |
| 偏移 | `OffsetDetector(url:).detect(options:progress:) -> OffsetReport`、`.detectRoman(pages:known:)` | |
| 章标题核对 | `HeadingLocator(url:)`、`.band`、`.topLines(page:)`、`.pages(showing:among:)`、`HeadingLocator.matches(lines:title:)` | |
| 错误文案 | `MuluError.description`、`OCRError.description` | 英文原文，界面照原样显示在「详情」里。 |

### 3.2 MuluOCR 的两处纯加法（A 部分做）

识别要能取消、要有进度。现有接口一次读完所有目录页（最多 40 页，每页 1–2.5 秒），中途无法停。不能改成逐页调用 `read`：`read` 读完所有页后会跨页做一次 `resolveOneOrI`（用印刷顺序决定 "1" 还是 "i"），逐页调用结果会不同。所以加钩子：

1. `TOCPageReader.read`：
   ```swift
   public func read(pages: [Int], options: TOCReadOptions = TOCReadOptions(),
                    progress: ((_ done: Int, _ total: Int) throws -> Void)? = nil) throws -> TOCReadResult
   ```
   读第 k 页（从 0 数）之前调用 `try progress?(k, pages.count)`，全部读完、`resolveOneOrI` 之前再调用一次 `try progress?(pages.count, pages.count)`。闭包抛出的错误（`CancellationError`）原样向外抛。
2. `OffsetDetector.detect`：参数类型从 `((OffsetSample) -> Void)?` 改为 `((OffsetSample) throws -> Void)?`，两处调用改成 `try progress?(…)`。

约束：`progress == nil` 或闭包不抛出时，结果与现在逐字节相同；CLI 调用处无需改动（不抛出的闭包可以传给 throws 闭包参数）。新增 `Tests/MuluOCRTests/ProgressHookTests.swift`：用 `SyntheticPDF` 生成 3 页目录，断言进度序列为 (0,3)(1,3)(2,3)(3,3)，以及第二次回调抛 `CancellationError` 时 `read` 抛出同一错误。

### 3.3 `mulu auto` 启发式的移植（为什么、范围、同步规则）

`mulu auto` 的第 3–4 步（章标题核对、在正文页找标题、罗马页码偏移、可疑判定、拒绝门槛）写在 CLI 目标 `Sources/mulu/AutoCommand.swift` 里，都是 `private`，库里没有。v0.1 的做法：

- **把下列代码逐字复制到 `Sources/MuluAppModel/Recognition/AutoHeuristics.swift`（internal）**：`AutoPolicy`（常量）、`HeadingCheck`（含 `Verdict`、`verify(offset:)`）、`locateByHeadings(_:pageCount:url:tocPages:)`、`RomanFinding` + `findRomanOffset(entries:frontPages:read:url:)`，以及 `runAuto` 里第 2–4 步的判定逻辑（`printedOnly` 解析、`arabic`/`lowShare`、偏移三分支、`competitorConfirmed`、`leadingRun`、`firstNumbered`/`tocAtBack`、`beyond`、罗马偏移、最终解析、`unstable`/`enlarged`/`low`/`violations`/`romanLeftOut` 的可疑分类、`allowed` 门槛）。
- 允许的偏差只有两种：(a) 所有「拒绝并退出」改为生成一条 `Advisory`（§4.6）并**继续**产出草稿；(b) 在循环之间插入取消检查（`try Task.checkCancellation()`，或给 `locateByHeadings` 加一个 `shouldStop: () -> Bool` 参数）。不改任何阈值、顺序、字符串比较。
- 文件头注释写明来源：`Port of Sources/mulu/AutoCommand.swift @ 04161b2 — keep in sync; v0.2 moves both callers into a shared target`。
- **不改 CLI**：`mulu auto` 的回归面（`tools/run_all.sh --books`、`week1_regress.py` 的 56 项）很大，而本期必须保持绿的只有 `swift test` 和默认的 `tools/run_all.sh`，它们覆盖不到 `auto` 的端到端。重构 CLI 的风险大于复制的代价。
- 一致性由两处保证：`RecognitionResult.muluText` 必须与 `mulu auto --dry-run` 在同一 PDF、同一目录页上的 stdout **逐字节相同**（当 `auto` 接受时）；`RecognitionResult.autoWouldAccept` 必须等于 `auto` 的退出码是否为 0。检查脚本见 §9.4。

### 3.4 不改 MuluCore

写入行为、TOC 文本格式、解析器一律不动。GUI 只通过 `Mulu.apply` 写文件。

---

## 4. 文档模型

### 4.1 打开的 PDF

`DocumentModel`（`@MainActor @Observable final class`，每个窗口一个）持有：

- `url`：标准化后的文件 URL（`standardizedFileURL`）。
- `phase`：`.loading` → `.ready` 或 `.failed(OpenFailure)`。
- `summary: PDFSummary?`：`pageCount`、`fileSize`、`info: DocumentInfo`（MuluCore）、`existingOutline: [OutlineItemInfo]`、`fingerprint: FileFingerprint`（大小、修改时间、inode、device，打开时记录）。
- 打开时在后台任务里读全部字节、`PDFFile(bytes:)` 解析、取页数和已有目录，然后**丢掉字节**；写入时重新从磁盘读（§5.11）。
- 失败：`MuluError.notPDF` → `.notPDF`；加密 → `.encrypted`；零页 → `.noPages`；其他解析错误 → `.unreadable(描述原文)`。界面显示失败视图（§6.6），不显示编辑器。

### 4.2 草稿：扁平行 + 层级

目录树用**按显示顺序（先序）排列的扁平行数组**表示，每行带 0 起的 `level`。这与 Mulu 文本格式、`OutlineSpec`、`readOutline()` 的表示完全一致，树操作也更简单、可测。

不变式（每个公开操作之后都必须成立，测试逐步检查）：

- 非空时 `rows[0].level == 0`；
- 对所有 i ≥ 1：`0 ≤ rows[i].level ≤ rows[i-1].level + 1`。

「子项」= 紧跟在某行后面、`level` 更大的连续行；某行的「块」= 它自己加全部子项。孩子的顺序就是数组顺序。

`OutlineRow` 字段（完整签名见 §10）：

| 字段 | 含义 |
|---|---|
| `id: UUID` | 稳定标识，撤销/重做后不变 |
| `title: String` | 标题（编辑提交时用 `MuluTOCFormat.oneLine` 规范化） |
| `level: Int` | 0 起 |
| `printedPage: PrintedPageRef?` | 印刷页码：阿拉伯数字或罗马数字（`value`、`style`、`display`）。来自识别、粘贴或 pdfdir 导入 |
| `sectionShift: Int` | 本行额外偏移（分段偏移），默认 0 |
| `manualPage: Int?` | 手动/固定的物理页（1 起）。非 nil ⇔ `pageOverride == true` |
| `doubts: [DoubtReason]` | 识别/导入时的可疑原因（§4.5） |
| `confirmed: Bool` | 人已核对（✓） |

### 4.3 页码换算

`PageMapping { offset: Int; romanOffset: Int? }` 是草稿的一部分（可撤销）。某行的物理页：

```
if let m = row.manualPage                     → m                         （固定页，不随偏移变）
else if printedPage.style == .arabic          → value + offset + sectionShift
else if printedPage.style == .roman, let r = romanOffset → value + r + sectionShift
else                                          → nil（没有页码）
```

规则：

- 全局偏移只移动「按印刷页换算」的行；`pageOverride` 的行不动（界面用图钉标出，§6.4）。
- **任何手动改页码**（在页码格里输入、⌘L「设为当前预览页」）都写 `manualPage`，变成固定页。「清除手动页码」恢复为印刷页 + 偏移（没有印刷页的行清除后变成「没有页码」）。
- 选中行 ±N（§5.6）：作用于选中行**及其全部子项**；固定页的行 `manualPage += N`，印刷页的行 `sectionShift += N`，没有页码的行不变。
- 校准偏移（§5.6）：`offset = 预览页 − printedPage.value − sectionShift`，只对「阿拉伯印刷页、非固定」的行可用。
- 物理页 < 1 或 > pageCount 不在换算时截断，而是作为行问题（§4.5）。

### 4.4 显示行与展开状态

- 折叠状态 `collapsed: Set<UUID>` 属于界面状态，**不进撤销**，不算修改。
- `displayRows: [DisplayRow]`：跳过被折叠祖先下的行；每项带 `index`（在 `draft.rows` 里的位置）、`level`、`title`、`printedPage`、`physicalPage`、`pageOverride`、`sectionShift`、`hasChildren`、`isExpanded`、`status`、`doubts`、`issues`。
- 每次草稿或折叠状态变化：重算 `displayRows`、`counts`，`revision += 1`。视图只看 `revision` 决定是否 `reloadData()`（§6.4）。5000 行以内全量重算即可。

### 4.5 可疑原因、行问题、行状态

**可疑原因 `DoubtReason`**（识别/导入时生成，存进行里，可撤销）：

| kind | 来源（与 `mulu auto` 相同） | 作用范围 | 算可疑？ |
|---|---|---|---|
| `unstableTitle` | 该条的 OCR 行带 `TOCPageReader.unstableNote` | 标题 | 是 |
| `enlargedTitle` | OCR 行带 `enlargedTitleNote` | 标题 | 是 |
| `lowConfidence` | `confidence < PrintedTOCOptions.lowConfidence`（0.75）；`detail` = notes 用 `; ` 连接，`confidence` 存数值 | 标题+页码 | 是 |
| `pageOrder` | 行号在 `orderViolations` 里 | 页码 | 是 |
| `noPage` | 解析器给不出物理页（没有页码、罗马页未映射、附录式页码、超出范围）；`detail` = 最后一条 note | 页码 | 是 |
| `locatedFromHeading` | 页码由 `locateByHeadings` 在正文页找到 | 页码 | 否（提示） |
| `unresolvedDestination` | 已有目录里 `pageIndex == nil`，按 TOCInterop 规则借用上一条的页 | 页码 | 是 |
| `importWarning` | 导入时的 TOCInterop 警告，`detail` 原文 | 标题+页码 | 是 |

分类顺序照搬 `auto`：有 `unstableTitle` 就只记它；否则有 `enlargedTitle` 就只记它；否则依次检查 `lowConfidence`、`pageOrder`、`noPage`。

清除规则：`setTitle` 删除「标题」范围的原因；改页码（输入、⌘L、清除固定页、±N、校准）删除「页码」范围的原因；「标题+页码」范围的原因只有打 ✓ 才算处理（原因保留，状态变为已核对）。

**行问题 `RowIssue`**（每次根据当前草稿实时计算，不存储）：

| issue | 阻止写入？ |
|---|---|
| `emptyTitle`（规范化后为空） | 是 |
| `noPhysicalPage` | 是 |
| `pageOutOfRange(page:pageCount:)`（< 1 或 > pageCount） | 是 |
| `pageBeforePrevious(previous:)`（物理页小于上一行的物理页） | 否（警告） |

**行状态 `RowStatus`**：有阻止写入的问题 → `.error`；否则 `confirmed` → `.confirmed`；否则有「算可疑」的原因或有警告 → `.doubtful`；否则 `.ok`。

### 4.6 识别结果与提示（Advisory）

`RecognitionResult` 是一次识别（或粘贴解析）的完整产物：行、`PageMapping`、偏移来源和证据、`advisories`、统计、`muluText`（与 `auto --toc-out` 相同的注释草稿）、`autoWouldAccept`。

`Advisory.kind` 对应 `auto` 的拒绝或警告（`blocksAuto == true` 的就是 `auto` 会拒绝的那几种）：

| kind | 触发 | blocksAuto |
|---|---|---|
| `noText` | 目录页没有识别出文字 | 是 |
| `fewEntries` | 带阿拉伯页码的条目 < 3，或最终可映射条目 < 3 | 是 |
| `notTOCLike` | 超过一半的行低置信度（「不像目录」） | 是 |
| `offsetUncertain` | 偏移无法确定（`detail` = `OffsetReport.reason` + 竞争偏移说明） | 是 |
| `offsetHeadingsDisagree` | 页码说 +a，但 ≥2 个章标题一致地落在 +b。检测得到的偏移 → 是；用户给定的偏移 → 否（只警告） | 视情况 |
| `offsetMayChange` | `leadingRun` 延伸到第一章（是）；或 `OffsetReport.conflict` 非空但已接受（否） | 视情况 |
| `firstChapterBeforeTOC` | 偏移把第一章放在目录页上或之前 | 是 |
| `entriesBeyondLastPage` | 超过一半条目落在最后一页之后 | 是 |
| `romanUnresolved` | 罗马页码偏移找不到 | 否 |
| `tooManyDoubtful` | 可疑数 > `max(1, Int(0.15 × 条目数))` | 是 |
| `ocrWarning` | `TOCReadResult.warnings`（双栏、旋转重试等） | 否 |
| `parserWarning` | 不属于任何条目的解析警告（丢弃的行等） | 否 |

`autoWouldAccept = advisories 里没有 blocksAuto 的 && 可映射条目 ≥ 3`。

识别产生的草稿里**保留**所有条目（包括 `auto` 会省略的罗马未映射条目），它们带 `noPage`，写入前必须处理（设前言偏移、改页码或删除，§5.11 提供「删除没有页码的行」一键操作）。

### 4.7 撤销/重做

- 可撤销单位 = `OutlineDraft`（`rows` + `mapping`，值类型，Sendable）。每个修改草稿的公开方法恰好登记**一个**撤销步骤：记下修改前的快照，修改，`beginUndoGrouping` → `registerUndo(withTarget: self) { m in MainActor.assumeIsolated { m.restore(old) } }` → `setActionName(…)` → `endUndoGrouping`。恢复时对称地登记重做（F9 已验证）。
- 快照同时记录 `selection` 和 `focusedRowID`，撤销后恢复选中。
- 不进撤销的：折叠状态、选择、预览页、目录页选择（`tocPages`）、识别状态、横幅。
- `undoManager` 默认是模型自己新建的实例；窗口视图在创建模型时传入 `@Environment(\.undoManager)`（在任何编辑之前）。这样「编辑 ▸ 撤销」菜单和文本框自己的输入撤销都走窗口的撤销管理器。测试里传入 `groupsByEvent = false` 的新实例。
- 打开文件时载入已有目录、`load()` 本身不进撤销栈；写入成功后不清撤销栈（仍可撤回去改）。
- 操作名用 `String(localized: "…")`（中文键，打包后查主包的 en.lproj，§7）：修改标题、修改页码、设为当前预览页、清除手动页码、增加缩进、减少缩进、上移、下移、添加条目、删除、页码偏移、分段偏移、校准偏移、标为已核对、导入目录、使用识别结果。

### 4.8 修改标记（dirty）

`isDirty` = 当前草稿的**输出投影**（每行的规范化标题、level、物理页）≠ 基线的输出投影。基线 = 载入完成时的草稿，或最近一次成功写入的草稿。打 ✓、折叠、改偏移但所有物理页不变，都不算修改。

---

## 5. 流程

### 5.1 打开（P0）

入口：窗口空状态的拖放区、⌘O（NSOpenPanel，只允许 PDF，可多选，每个文件一个窗口）、Finder「打开方式 ▸ Mulu」/拖到 Dock 图标（`.onOpenURL`，F7）、运行中再次打开（F8）。

步骤：窗口拿到 URL → 同一文件已在别的窗口打开则把那个窗口提到前面（`openWindow(value:)` 自带去重）→ 否则创建 `DocumentModel(url:undoManager:)` → `await load()`：显示加载中（大文件解析可能要 0.1–1 秒）→ `.ready` 时显示三栏界面；PDFKit 的 `PDFDocument(url:)` 由视图层在主线程创建（PDFKit 不是 Sendable，不进模型）。

### 5.2 载入已有目录（P0）

`load()` 发现 `existingOutline` 非空：直接由 `readOutline()` 的结果建行（层级用 `OutlineDraft.clampedLevels` 保证不变式）：`manualPage = pageIndex + 1`（固定页），`pageIndex == nil` 的借用上一条的页并加 `unresolvedDestination`（与 `TOCInterop.entries(fromOutline:)` 相同；但第一条就无法解析时不像它那样默认第 1 页，而是 `manualPage = nil`，成为错误行，让人决定）。`offsetInfo.source = .existingOutline`。设为基线（不脏）。横幅：「已载入 PDF 里原有的目录（N 条）」。写入时新目录**替换**原目录（旧目录的字节仍留在文件前部，只是不再被引用）。

### 5.3 识别目录页（P0）

1. 选页：左栏缩略图 ⌘-点击切换「目录页」标记（徽标「目录」）；或在识别面板里输入「5-7」「3,5,8-9」这种范围（`parsePageList`，1 起的物理页，即缩略图下的页码）。最多 40 页（`maxTOCPageCount`），超过时在面板里直接提示，不开始。
2. 可选：面板里「我知道偏移」输入框（等于 `auto --offset N`）。
3. 开始：`startRecognition(pages:knownOffset:)`。在 `Task.detached(priority: .userInitiated)` 里同步运行 `RecognitionPipeline.run(…)`；进度用 `AsyncStream<RecognitionProgress>`（`bufferingNewest(1)`）回到主线程，更新 `recognition = .running(progress)`。同一时刻只允许一个识别任务。
4. 流水线（与 `auto` 第 1–4 步一致，§3.3）：

   | 阶段 `phase` | 做什么 | 进度区间 |
   |---|---|---|
   | `readingTOC` | `TOCPageReader.read(pages:progress:)`，每页回调 | 0.00–0.60 |
   | `parsing` | `PrintedTOCParser.parse(rawText, options(pageCount))`（只含印刷页） | 0.60–0.62 |
   | `detectingOffset` | 给定偏移则跳过；否则 `OffsetDetector.detect(progress:)`，每个抽样页回调（24 个） | 0.62–0.90 |
   | `checkingHeadings` | `HeadingCheck.verify`（检测到的偏移和竞争偏移） | 0.90–0.95 |
   | `frontMatter` | 有罗马页码时 `findRomanOffset` | 0.95–0.97 |
   | `locatingHeadings` | 用最终偏移重新解析 + `locateByHeadings` | 0.97–0.99 |
   | `finishing` | 可疑分类、建行（`DraftBuilder`）、advisories、`muluText` | 1.00 |

   偏移选择（不拒绝版）：
   - 给定偏移 → `offsetSource = .given`；标题核对不一致只加警告型 `offsetHeadingsDisagree`。
   - `OffsetReport.status == .ok` → `.detected`；标题一致地偏到别处 → 加 `offsetHeadingsDisagree`（blocksAuto），偏移仍用检测值。
   - 否则满足 `auto` 的回退条件（`bestGuess`、无 `conflict`、`agreeing ≥ 3`、≥3 个章标题全部确认、无竞争偏移被确认）→ `.pageNumbersAndHeadings`。
   - 否则 → 偏移取 `bestGuess ?? 0`，`offsetSource = .bestGuess` 或 `.none`，加 `offsetUncertain`。草稿照样生成（用印刷页），用户再用 §5.6 的「校准偏移」改对。
5. 取消：面板的「取消」、Esc、⌘.（`cancelRecognition()`）。取消在下一个检查点生效：最多等一页 OCR（约 2.5 秒）或一个抽样页；状态变为 `.cancelled`，草稿不变。
6. 失败：打不开、渲染全失败等 → `.failed(描述原文)`。
7. 结果面板（`.finished(result)`）：摘要「识别出 N 条，其中 M 条可疑」、偏移一行（「偏移 +8：24 个抽样页中 22 页一致」/「偏移没能确定，先按 +0 放置」）、advisories 列表（中文标题 + 可展开的英文原文）。按钮：
   - 草稿为空时：「使用结果」（= `.replace`）。
   - 草稿不空时：「替换当前目录」（默认）、「追加到末尾」、「插入到选中行之后」、「放弃」。
8. 合并规则（`acceptRecognition(mode)`，一个撤销步骤）：
   - `.replace`：草稿 = 结果的行 + 结果的 `mapping`。
   - `.append` / `.insertAfterFocused`：新行插到末尾 / 焦点行的块之后，层级整体加上插入点的层级（`.append` 为 0）；为保持新行的物理页不变，新行的 `sectionShift += 结果.offset − 草稿.offset`；草稿没有 `romanOffset` 时采用结果的，有且不同时罗马行的 `sectionShift` 同样补差。
   - 之后：`advisories` 显示在编辑器上方（可逐条关闭）；`offsetInfo` 记下来源与证据（供偏移栏说明文字用）；若有可疑行，横幅提示「有 M 条可疑，按 ⌘⇧R 逐条核对」。

### 5.4 粘贴目录文字（P1，= `mulu toc parse`）

编辑 ▸「粘贴目录文字…」（⌘⇧V）打开面板：多行文本框（预填剪贴板文本）、「偏移」输入框（可空）、复选「自动找偏移」（默认勾选；勾选且没填偏移时运行 `OffsetDetector` 与标题核对）。运行同一个流水线，输入是 `RecognitionInput.text(String)`：跳过 OCR；`firstChapterBeforeTOC` 检查不做（没有目录页）；罗马偏移只用正文前几页的页眉页脚（`folios` 为空）。结果面板与 §5.3 相同，`source = .pastedText`。

### 5.5 选择与预览联动（P0）

- 单击一行 → `select([id], focus: id)` → 若该行有物理页，`previewRequest = (page, serial+1)`，预览跳过去（同一页再点也会重新跳，所以带 serial）。
- 焦点行的物理页因任何修改而变化（改偏移、±N、撤销）→ 自动发新的 `previewRequest`，预览跟着走。
- 预览翻页（滚动、方向键、缩略图）→ 视图调用 `previewDidShow(page:)` 更新 `previewPage`。
- 预览上方的浮层（§6.3）在「预览页 ≠ 焦点行的物理页」时出现两个按钮：「设为本行页码 ⌘L」「按这一页校准偏移 ⌘⇧L」——这是纠错的主循环：点一行 → 看预览 → 不对就翻到真正的章首页 → 一键修正。

### 5.6 偏移编辑（P0）

- 全局偏移：偏移栏的数字框 + 步进器（±1），直接输入整数（|n| ≤ `TOCParser.maxPage`）。每次提交一个撤销步骤。标签「PDF 页 = 印刷页 + 偏移」。有罗马印刷页的行时再显示「前言偏移」框（可空 = 未映射）。
- 分段偏移：选中若干行（通常是从某章开始到末尾，⇧-点击选范围）→ ⌃⌘] / ⌃⌘[（或表格聚焦时按 `]` / `[`，`}` / `{` 为 ±10）→ `shiftPages(ids, by:)`。
- 校准：选中一行（阿拉伯印刷页、非固定页）→ 把预览翻到这一章真正开始的页 → ⌘⇧L → `calibrateOffset(using:physicalPage: previewPage)`。偏移来源变为 `.calibrated`。
- 说明文字：偏移栏下方小字显示来源：「自动检测：24 个抽样页中 22 页一致」「页码 + 章标题共同确认」「猜测，未确认」「手动设置」「按第 N 页校准」。

### 5.7 行编辑（P0）

| 操作 | 方法 | 语义 |
|---|---|---|
| 改标题 | `setTitle(id, text)` | 回车/双击进入编辑；提交时规范化；未变化不登记撤销 |
| 改页码 | `setPhysicalPage(id, n)` | 输入物理页 → 固定页；输入非正整数 → 拒绝（嘟一声，恢复原值）；清空 → 等同「清除手动页码」 |
| 设为当前预览页 | `pinToPreviewPage(id)` | `manualPage = previewPage` |
| 清除手动页码 | `clearOverride(ids)` | `manualPage = nil` |
| 增加缩进 | `indent(ids)` | 对选中的「块首」（祖先未被选中的行）按文档顺序处理：若 `level ≤ 上一行 level`，本块整体 +1（成为前一个兄弟的最后一个孩子）；否则跳过。顺序不变 |
| 减少缩进 | `outdent(ids)` | `level > 0` 的块首，本块整体 −1。**顺序不变**：原来排在它后面的兄弟会变成它的孩子（与缩进式文本一致，保持页码顺序） |
| 上移 / 下移 | `moveUp(ids)` / `moveDown(ids)` | 块首必须是同一父下的连续兄弟；整组与前一个 / 后一个兄弟的块交换；不跨父级。不满足条件时返回 false |
| 添加同级 | `addSibling(after: id)` | 在该行块之后插入同级新行；`id == nil` 时追加到末尾（level 0） |
| 添加子级 | `addChild(of: id)` | 在该行块的末尾插入 level+1 的新行 |
| 新行默认值 | | 标题空、`manualPage = previewPage`（用户正看着哪页就指向哪页）；选中新行并发出 `editRequest(.title)`，界面立刻进入标题编辑 |
| 删除 | `delete(ids, keepChildren: false)` | 删除选中行及其子项。之后选中原位置的下一行（没有则上一行） |
| 删除但保留子项 | `delete(ids, keepChildren: true)` | 只删选中行，它的子项整体 −1 级上提（用于删掉 OCR 误认出来的「假父级」） |
| 标为已核对 | `setConfirmed(ids, Bool)` | 切换 ✓ |

所有方法返回是否改变了草稿（`Bool` 或新行 id）；没变化时不登记撤销。每个操作后检查不变式（debug 构建下 `assert`）。

### 5.8 审阅模式（P0）

- 进入：⌘⇧R 或状态栏「审阅」按钮。选项「只看可疑」（默认：有可疑或错误行时勾选）。队列 = 符合条件的行（文档顺序），从当前焦点行之后的第一个开始。
- 每一步：选中当前行、展开其祖先、预览跳到它的页、表格滚动到可见。底部浮层显示「审阅 5/12」、该行的原因（中文 + 英文原文）。
- 按键：↓ / ↑ 下一条/上一条；回车 = 标为已核对并下一条（`reviewConfirmAndAdvance()`，一个撤销步骤）；回车前可以先改标题/页码（改完焦点回到表格）；Esc 退出。
- 走完最后一条：浮层显示「全部看完了：已核对 N 条」+「写入目录…」按钮。
- 审阅中草稿被修改（删行、导入）→ 队列里不存在的 id 自动跳过。

### 5.9 导入 / 导出（P0）

- 导入：文件 ▸「导入目录…」（⌘⇧I），或把 `.txt/.xml/.opml/.json` 拖到编辑器。格式自动识别（`TOCInterop.detect`），面板里可手动指定。读取用 `TOCInterop.read`（文本解码由它负责：UTF-8、UTF-16 BOM、GB18030）。
  - pdfdir → 行的 `printedPage = .arabic(page)`、非固定（pdfdir 的页码是印刷页，随全局偏移）。
  - 其他格式 → `manualPage = page`（物理页，固定）。
  - `TOCInteropResult.warnings` → 横幅列出，前 3 条原文；对应不到具体行的不挂在行上。
  - 草稿为空 → 直接替换；否则询问「替换当前目录 / 追加到末尾 / 取消」。一个撤销步骤。
  - Mulu 格式里 `auto --toc-out` 写的 `# ?` 注释 v0.1 忽略（v0.2 恢复为可疑原因）。
- 导出：文件 ▸「导出目录 ▸」子菜单，五种格式各一项（⌘⇧E = 上次用的格式，首次为 Mulu 文本）。有阻止写入的问题时拒绝并说明（与写入同一套检查，因为没有物理页就没法导出）。页码一律是物理页（与 `mulu export-outline` 相同，包括 pdfdir）。`title` 参数 = PDF 文件名去扩展名。默认文件名：`<name>-目录.txt`（mulu、pdfdir）、`.xml`、`.opml`、`.json`。写文件用临时文件 + rename，不能覆盖打开的 PDF。

### 5.10 键入的页码与印刷页（说明）

页码列显示和编辑的是**物理页**（PDF 第几页，即缩略图下的数字），因为写进 PDF 的就是它，预览也按它跳。印刷页以灰色小字显示在旁边供对照目录页（「印 12」）。v0.1 不在表格里直接编辑印刷页；`setPrintedPage(id, …)` 已在 API 里，界面可以放在右键菜单「修改印刷页码…」（P2）。

### 5.11 写入（P0）

1. 触发：文件 ▸「写入目录…」（⌘S）或工具栏按钮。
2. 检查 `writeReadiness()`：
   - `blockers` 非空 → 警告框列出前 5 条（「第 12 条「第三章 …」没有页码」），按钮「定位到第一条」（选中并滚动）；若全部是 `noPhysicalPage`，再给「删除这 N 行（保留子项）」按钮（`delete(ids, keepChildren: true)`）。不继续。
   - `unconfirmedDoubtful > 0` 或 `orderWarnings > 0` → 确认框「还有 N 条可疑没有核对 / M 条页码比上一条小。仍然写入？」［仍然写入］［先审阅］［取消］。
3. NSSavePanel（`beginSheetModal(for:)`）：标题「写入带目录的新 PDF」，按钮「写入」，`directoryURL` = 输入文件所在文件夹，`nameFieldStringValue` = `defaultOutputURL(suffix: String(localized: "-目录")).lastPathComponent`（`<name>-目录.pdf`；后缀用单独的键「-目录」，英文 `-outline`，不与菜单名「目录」共用键），`allowedContentTypes = [.pdf]`，允许新建文件夹。面板 delegate 的 `panel(_:validate:)` 调 `validateOutputURL(_:)`：与输入是同一个文件（路径标准化 + 解析符号链接后相同，或 (device, inode) 相同）→ 抛 `.wouldOverwriteInput`，面板内显示「不能覆盖原文件。Mulu 只写新文件。」；目标是文件夹或所在文件夹不可写 → `.notWritable`。
4. `try await write(to:)`（`isWriting = true`，窗口显示小进度圈，写入期间禁止编辑和再次写入），在后台任务里：
   1. 重新 stat 输入文件，`FileFingerprint` 与打开时不同 → `.inputChanged`（「原文件在打开后被改动过，请重新打开再写入」）。
   2. 读全部字节；输出投影 → `[TOCEntry]`（行序号作为 `line`）→ `MuluTOCFormat.write` → `Mulu.apply(pdf:tocText:offset: 0)`。`MuluError` → `.refused(error.description)`，原文显示。
   3. 额外核对（与 `auto` 相同）：`output.count > input.count` 且 `output` 以 `input` 为前缀，否则 `.verificationFailed`。
   4. 原子写：目标文件夹里的 `.<name>.mulu-<pid>-<UUID>.tmp`，`.withoutOverwriting`，然后 `rename(2)` 到目标（目标已存在时替换——用户已在保存面板确认过）。失败删除临时文件，抛 `.io(原因)`。
   5. **写后复核**：从磁盘重新读输出文件，检查前缀 == 输入字节，`PDFFile(bytes:).readOutline()` 的 (title, level, pageIndex) 与 `TOCParser.parse(同一段文本)` 得到的期望逐项相同（这样 `#`→`＃`、空白合并等规范化被正确计入）。不符 → 删除输出文件，抛 `.verificationFailed(说明)`。
5. 成功：`lastWrite = WriteReport`，基线 = 当前草稿（不脏），横幅「已写入 <文件名>：原文件字节未改动，追加了 6.8 KB（48 条书签）」（字节数用 `ByteCountFormatter`，`.file` 风格），按钮［在 Finder 中显示］（`NSWorkspace.activateFileViewerSelecting`）［打开］（用默认 App 打开输出文件）。窗口继续编辑原文件，不切换到输出文件。
6. 失败：警告框标题「写入失败，没有生成文件」，正文 = 中文说明 + 写入器/系统原文（`WriteError.description`）。

---

## 6. 窗口布局与交互

### 6.1 总体布局

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│ 工具栏: [识别目录页…] [粘贴目录文字…] │ 页码偏移 [ +8 ]⇅ (前言偏移 [+2]) │ [审阅] │ [导入][导出▾] │ [写入目录…] │
├──────────────┬──────────────────────────────────┬─────────────────────────────────────────┤
│ 缩略图        │ 预览 (PDFView)                    │ 提示(advisories，可关闭)                  │
│ ┌──┐ 1       │ ┌ 浮层: PDF 第 20 页 / 共 312 页 ─┐ │ ┌────────────────────────┬──────┬───┐ │
│ └──┘         │ │ 「第二章 方法」→ 第 20 页          │ │ │ 标题                    │ 页码  │ 核对│ │
│ ┌──┐ 2 目录  │ │ [设为本行页码 ⌘L][校准偏移 ⌘⇧L] │ │ ├────────────────────────┼──────┼───┤ │
│ └──┘         │ └──────────────────────────────────┘ │ │ ▾ 第一章 绪论            │印1  9│ ✓ │ │
│ ...          │                                    │ │     1.1 背景             │印2 10│ ? │ │
│ 目录页: 5-7   │                                    │ │ ▸ 第二章 方法            │📌 20 │ ! │ │
│ [识别…]       │                                    │ └────────────────────────┴──────┴───┘ │
│              │                                    │ [+同级][+子级][−] [⇤][⇥] [↑][↓] [−1][+1] │
│              │                                    │ 48 条 · 5 条可疑 · 1 条有错 · 已核对 12 [审阅]│
└──────────────┴──────────────────────────────────┴─────────────────────────────────────────┘
```

- `NavigationSplitView`（sidebar / content / detail）：sidebar = 缩略图，content = 预览，detail = 目录编辑器。宽度：缩略图 140–240（理想 170），预览 ≥ 360，编辑器 ≥ 380（理想 480）。窗口 `.defaultSize(width: 1400, height: 880)`，最小 1100×680（实验里未指定时默认只有 900×450）。
- 窗口标题 = 文件名，`.navigationDocument(url)` 提供标题栏代理图标；`isDirty` 时关闭按钮带圆点（`window.isDocumentEdited`，用 `WindowAccessor` 设置）。

### 6.2 缩略图栏

- `ScrollView` + `LazyVStack`，每页一格：缩略图（`ThumbnailRenderer` 在后台渲染，`maxPixelWidth: 240`，未就绪时显示灰色占位）、页码（物理页）、目录页徽标「目录」、当前预览页高亮框。`ScrollViewReader` 让当前预览页保持可见。
- 单击 → `requestPreview(page:)`；⌘-单击 → `toggleTOCPage(page)`；右键菜单「标为目录页 / 取消目录页」「从这一页开始识别…」。
- 底部固定条：「目录页：5-7」（`tocPagesSpec`，没选时显示「在缩略图上 ⌘-点选目录页」）+「识别…」按钮（打开识别面板，页码范围预填）。

### 6.3 预览

- `PDFPreview: NSViewRepresentable` 包 `PDFView`：`autoScales = true`，`displayMode = .singlePageContinuous`，`displaysPageBreaks = true`。
- 观察 `previewRequest.serial` 变化 → `go(to: document.page(at: page - 1))`。监听 `.PDFViewPageChanged` → `model.previewDidShow(page:)`（用协调器里的标志避免「程序跳页 → 回调 → 再请求」的循环）。
- 顶部浮层（`PreviewOverlay`）：「PDF 第 N 页 / 共 M 页」；有焦点行时加「「标题」→ 第 P 页（印刷页 12 + 偏移 8）」；`previewPage != P` 时显示两个按钮（§5.5）。
- ⌥← / ⌥→（编辑器聚焦时也可用）= 预览上一页/下一页；⌘+ / ⌘− 缩放（PDFView 自带）。

### 6.4 目录编辑器（表格）

用 AppKit `NSTableView`（view-based，**不用 NSOutlineView、不用 SwiftUI Table**）：键盘行为（Tab 缩进、回车编辑、方括号 ±1）和行内编辑需要完全可控；扁平行 + 模型提供的折叠状态正好对应 `displayRows`。

- 列：
  - 「标题」：左缩进 `level × 16 pt`；有子项时显示展开三角（点击 = `toggleExpanded`，⌥-点击 = 全部展开/折叠）；可编辑 `NSTextField`。
  - 「页码」（宽 96）：右对齐等宽数字，物理页；印刷页时前面灰色小字「印 12」（罗马数字照原样，如「印 iv」）；固定页显示 `pin.fill` 小图标；没有页码显示红色「—」。可编辑（只接受正整数）。工具提示：「印刷页 12 + 偏移 8 + 本段 +2 → PDF 第 22 页」或「手动固定为 PDF 第 22 页」。
  - 「核对」（宽 30）：按 `status` 显示 `exclamationmark.triangle.fill`（红，错误）/ `questionmark.circle.fill`（橙，可疑）/ `checkmark.circle.fill`（绿，已核对）/ `circle`（浅灰，正常）；点击切换 ✓（错误行不可切换）；工具提示列出全部原因和问题。
- 行底色：错误 = systemRed 12%，可疑 = systemOrange 12%，审阅当前行 = accentColor 20%。
- 多选（⇧/⌘ 点击）。表格选择变化 → `model.select(ids, focus:)`；模型的 `selection` 变化 → 表格同步（协调器标志防循环）。
- 刷新：`updateNSView` 读 `model.revision`，与上次不同才 `reloadData()`，然后按 id 恢复选择和滚动位置。
- 编辑请求：观察 `model.editRequest`（行 id + 字段 + serial）→ `editColumn(_:row:with:select:)`。
- 行内编辑提交（`controlTextDidEndEditing`）→ `setTitle` / `setPhysicalPage`；Esc 取消编辑。编辑标题时 Tab 跳到页码格，⇧Tab 回到标题（标准行为）。
- 右键菜单：编辑标题、设为当前预览页、清除手动页码、页码 +1 / −1、添加同级 / 子级、增加 / 减少缩进、标为已核对 / 取消、删除、删除但保留子项。
- 编辑器上方：advisories 列表（每条：图标 + 中文标题 + 「详情」展开英文原文 + ×）。下方：按钮条（添加同级、添加子级、删除、减少缩进、增加缩进、上移、下移、页码 −1、页码 +1）+ 状态栏（「48 条 · 5 条可疑 · 1 条有错 · 已核对 12」+［审阅］）。审阅浮层叠在表格底部（§5.8）。

### 6.5 空状态

| 情况 | 显示 |
|---|---|
| 没有打开文档（启动窗口） | 整窗拖放区：大图标 `doc.badge.plus`，「把 PDF 拖到这里」，副标题「或按 ⌘O 打开。Mulu 只在文件末尾追加目录，原来的字节一个都不改。」，按钮［打开 PDF…］。拖入时边框高亮。 |
| 加载中 | 居中进度圈 +「正在读取 <文件名>…」 |
| 文档已打开、草稿为空 | 编辑器区：「这个 PDF 还没有目录」+ 三个按钮［识别目录页…］（主按钮）［粘贴目录文字…］［导入目录文件…］+ 链接按钮［手动添加第一条］+ 提示「在左边缩略图里按住 ⌘ 点选目录所在的页，然后识别。」 |
| 识别中 | 识别面板（sheet）：阶段文字（「正在识别目录页（第 2/3 页）…」「正在找页码偏移…」「正在核对章标题…」「正在找前言页码…」「正在正文页里找标题…」）+ 确定进度条 +［取消］ |

### 6.6 失败视图

居中：图标 `exclamationmark.triangle`，标题按 `OpenFailure`：加密 →「这个 PDF 已加密。Mulu v0.1 不能给加密的 PDF 写目录。」；非 PDF →「这不是 PDF 文件」；零页 →「这个 PDF 没有页面」；其他 →「Mulu 无法处理这个 PDF」；下方灰字显示英文原文；按钮［关闭窗口］［打开其他文件…］。

### 6.7 快捷键与菜单

表格聚焦且不在编辑时才生效的按键（在 `NSTableView` 子类的 `keyDown` 里处理，**不做成菜单快捷键**，否则会吞掉文本框的输入）标为「表格」。

| 操作 | 快捷键 | 菜单 |
|---|---|---|
| 新窗口 | ⌘N | 文件 |
| 打开 PDF… | ⌘O | 文件 |
| 关闭窗口 | ⌘W | 文件 |
| 写入目录… | ⌘S | 文件 |
| 导入目录… | ⌘⇧I | 文件 |
| 导出目录（上次的格式）… | ⌘⇧E | 文件 ▸ 导出目录 ▸ 五种格式 |
| 撤销 / 重做 | ⌘Z / ⌘⇧Z | 编辑（系统） |
| 粘贴目录文字… | ⌘⇧V | 编辑 |
| 识别目录页… | ⌘R | 目录 |
| 取消识别 | Esc / ⌘.（识别面板里） | — |
| 标为目录页（当前预览页） | ⌘⇧T | 目录 |
| 审阅模式 开/关 | ⌘⇧R | 目录 |
| 编辑标题 | 回车（表格）/ 双击 | — |
| 增加缩进 / 减少缩进 | Tab / ⇧Tab（表格）；⌘] / ⌘[ | 目录 |
| 上移 / 下移 | ⌥⌘↑ / ⌥⌘↓ | 目录 |
| 添加同级 / 添加子级 | ⌘↩ / ⌘⇧↩ | 目录 |
| 删除（连同子项） | ⌫（表格）；⌘⌫ | 目录 |
| 删除但保留子项 | ⌥⌘⌫ | 目录 |
| 选中行页码 +1 / −1 | `]` / `[`（表格），`}` / `{` = ±10；⌃⌘] / ⌃⌘[ | 目录 |
| 设为当前预览页 | ⌘L | 目录 |
| 按当前预览页校准偏移 | ⌘⇧L | 目录 |
| 清除手动页码 | — | 目录 / 右键 |
| 标为已核对（切换） | 空格（表格）；⌘K | 目录 |
| 展开 / 折叠 | → / ←（表格） | 目录 ▸ 全部展开 / 全部折叠 |
| 预览上一页 / 下一页 | ⌥← / ⌥→ | 显示 |
| 审阅：下一条 / 上一条 / 确认并下一条 / 退出 | ↓ / ↑ / 回车 / Esc | — |

菜单用 SwiftUI `.commands`：`CommandGroup(replacing: .newItem)` 放「新窗口」「打开 PDF…」；`CommandGroup(replacing: .saveItem)` 放「写入目录…」「导入目录…」「导出目录」；新增 `CommandMenu("目录")`。当前窗口的模型通过 `@FocusedValue(\.documentModel)` 取得（`DocumentWindow` 用 `.focusedSceneValue` 提供）；没有文档或条件不满足时菜单项禁用（用模型的 `canIndent(_:)` 等查询方法）。

### 6.8 窗口路由（MuluApp 内，F7/F8）

```swift
WindowGroup(id: "document", for: URL.self) { $url in
    DocumentWindow(url: $url)
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
}
.handlesExternalEvents(matching: ["*"])
.defaultSize(width: 1400, height: 880)
.commands { MuluCommands() }
```

- `AppState`（`@MainActor @Observable`，App 级单例，环境注入）记录每个窗口 token → 当前 URL，以及 `launchedAt`。
- 统一入口 `open(url)`（`.onOpenURL`、拖放、⌘O 都走它）：非 PDF（扩展名不是 pdf 且前 1024 字节里没有 `%PDF-`）→ 若本窗口有文档且是目录文件扩展名则当作导入，否则提示；已有窗口打开同一文件 → `openWindow(value:)`（提到前面）；本窗口 `url == nil` → `url = incoming`（接管）；否则 `openWindow(value: incoming)`。
- 冷启动多余空窗口（F8）：启动后 3 秒内，只要 `AppState` 里有窗口持有文档，所有仍为空、且用户没有操作过（没点按钮、没拖放）的窗口都关闭自己（空窗口观察 `AppState.documentWindowCount`，出现与消失的先后顺序都能处理）。
- 状态恢复：WindowGroup(for:) 会在下次启动时恢复窗口及 URL；文件不在了 → 失败视图。烟雾模式启动参数加 `-ApplePersistenceIgnoreState YES`。
- 实现后必须用烟雾 C 段（§9.3）确认：Finder 冷启动打开 1 个文件 → 恰好 1 个可见窗口；运行中再打开另一个文件 → 2 个窗口；再打开同一个文件 → 仍是 2 个。

### 6.9 AppDelegate

- `applicationWillFinishLaunching`：`Bundle.main.bundleIdentifier == nil`（从 `.build` 直接运行）→ `NSApp.setActivationPolicy(.regular)`（F2）。读取 `SmokeConfig(environment:)`。
- `applicationDidFinishLaunching`：未打包时 `NSApp.activate()`；烟雾模式启动看门狗（§9.3）。
- `applicationShouldTerminate`：非烟雾模式下，有 `isDirty` 的文档 → NSAlert「有 N 个窗口的目录修改还没有写入 PDF。仍然退出？」［退出］［取消］（P0）。
- `applicationShouldTerminateAfterLastWindowClosed` → `false`（Mac 惯例，菜单栏还能 ⌘O/⌘N）。
- 关闭单个脏窗口的确认（P1）：`WindowAccessor` 给 NSWindow 装一个转发代理，只拦截 `windowShouldClose(_:)`，其余消息全部转发给 SwiftUI 原来的 delegate；做不稳就只保留关闭按钮圆点 + 退出确认。

### 6.10 并发要点（Swift 6 语言模式）

- `DocumentModel` 全部在主 actor。重活（打开解析、识别、写入、缩略图）在 `Task.detached` 或 actor 里做，只传 Sendable 值（URL、页码、`OutlineDraft`、`[TOCEntry]`、结果结构体），**不要**把 `DocumentModel`、`PDFFile`、`TOCPageReader`、`PDFDocument` 捕获进后台闭包。
- `TOCPageReader`/`OffsetDetector`/`HeadingLocator`/`PDFRasterizer` 不是线程安全的：流水线在一个后台任务里顺序创建和使用；缩略图用自己的 `CGPDFDocument`（在 `ThumbnailRenderer` actor 内）；预览用 PDFKit 自己的文档。同一文件同时有三个独立的 CoreGraphics 文档实例，这是有意的。
- 不用 `@concurrent`（需要 Swift 6.2；README 承诺 Xcode 16 也能构建）。
- 若 SDK 里 `CGImage` 不是 Sendable，用 `ThumbnailImage: @unchecked Sendable` 包一层（§10）。

---

## 7. 文案与本地化

### 7.1 做法（F4–F6 已验证）

- `Sources/MuluApp/Resources/Localizable.xcstrings`，`sourceLanguage = zh-Hans`，每个键（中文原文）都有 `en` 翻译，`state = translated`。
- 视图里直接写中文字面量：`Text("打开 PDF…")`、`Button("写入目录…")`、`.help("…")`；代码里需要字符串时用 `String(localized: "…")`。**不要**写 `bundle: .module`。这些查的是 `Bundle.main`：
  - 打包后：`package_app.sh` 把 SwiftPM 编译出的 `en.lproj/Localizable.strings`（和 `.stringsdict`，如有）复制到 `Mulu.app/Contents/Resources/en.lproj/`，并建 `zh-Hans.lproj/`（可以为空；F6 的实验包里主包没有任何 lproj，只靠 `CFBundleLocalizations` 也能选中 zh-Hans，建它只是与 Xcode 产物保持一致，烟雾 D 段验证）；Info.plist 写 `CFBundleDevelopmentRegion = zh-Hans`、`CFBundleLocalizations = [zh-Hans, en]`。系统首选中文 → 中文（键本身），首选英文 → 英文。
  - 从 `.build` 直接运行：主包没有 lproj，永远显示中文键。这是可接受的开发行为。
- 插值：`Text("共 \(n) 页")` 的键是 `共 %lld 页`，`String` 插值是 `%@`。英文避免依赖复数形态（写成 "Pages: %lld"、"%lld entries" 之类不别扭的说法）；xcstrings 的 plural variations 本期不用（未验证 SwiftPM 是否编译成 .stringsdict）。
- MuluAppModel 里的用户可见文案只有撤销操作名（§4.7），同样用 `String(localized:)` + 中文键，键也放进 MuluApp 的 xcstrings。其余一律是枚举，由视图翻译。
- 英文原文（`MuluError`、`OCRError`、解析器 notes、`OffsetReport.reason`）不翻译，放在「详情」里原样显示。

### 7.2 核心文案（键 → 英文）

| 中文（键） | English |
|---|---|
| 打开 PDF… | Open PDF… |
| 新窗口 | New Window |
| 写入目录… | Write Outline… |
| 写入带目录的新 PDF | Write a New PDF with the Outline |
| -目录 | -outline |
| 写入 | Write |
| 导入目录… | Import Outline… |
| 导出目录 | Export Outline |
| Mulu 文本 | Mulu Text |
| PDF补丁丁 XML | PDFPatcher XML |
| pdfdir 文本 | pdfdir Text |
| 粘贴目录文字… | Paste TOC Text… |
| 识别目录页… | Recognize TOC Pages… |
| 目录 | Outline |
| 审阅模式 | Review Mode |
| 标题 | Title |
| 页码 | Page |
| 核对 | Check |
| 页码偏移 | Page Offset |
| 前言偏移 | Front-Matter Offset |
| PDF 页 = 印刷页 + 偏移 | PDF page = printed page + offset |
| 目录页：%@ | TOC pages: %@ |
| 印 %@ | p. %@ |
| 增加缩进 / 减少缩进 | Indent / Outdent |
| 上移 / 下移 | Move Up / Move Down |
| 添加同级条目 / 添加子条目 | Add Sibling / Add Child |
| 删除 / 删除但保留子项 | Delete / Delete, Keep Children |
| 页码 +1 / 页码 −1 | Page +1 / Page −1 |
| 设为当前预览页 | Use Current Preview Page |
| 按当前预览页校准偏移 | Calibrate Offset from Preview Page |
| 清除手动页码 | Clear Manual Page |
| 标为已核对 | Mark as Checked |
| 标为目录页 | Mark as TOC Page |
| 全部展开 / 全部折叠 | Expand All / Collapse All |
| 把 PDF 拖到这里 | Drop a PDF Here |
| 或按 ⌘O 打开。Mulu 只在文件末尾追加目录，原来的字节一个都不改。 | Or press ⌘O. Mulu only appends an outline at the end of the file; every original byte stays unchanged. |
| 这个 PDF 还没有目录 | This PDF has no outline yet |
| 在左边缩略图里按住 ⌘ 点选目录所在的页，然后识别。 | ⌘-click the table-of-contents pages in the thumbnails, then recognize them. |
| 手动添加第一条 | Add the First Entry |
| 正在识别目录页（第 %lld/%lld 页）… | Reading TOC page %lld of %lld… |
| 正在找页码偏移… | Finding the page offset… |
| 正在核对章标题… | Checking chapter headings… |
| 识别出 %lld 条，其中 %lld 条可疑 | Found %lld entries; %lld need checking |
| 替换当前目录 / 追加到末尾 / 插入到选中行之后 / 放弃 | Replace Current Outline / Append to End / Insert After Selection / Discard |
| 偏移 %@：%lld 个抽样页中 %lld 页一致 | Offset %@: %lld of %lld sampled pages agree |
| 偏移没能确定，先按 %@ 放置 | Offset not determined; placed at %@ for now |
| 已写入 %@：原文件字节未改动，追加了 %@（%lld 条书签） | Wrote %@: original bytes unchanged, %@ appended (%lld bookmarks) |
| 在 Finder 中显示 | Show in Finder |
| 写入失败，没有生成文件 | Writing failed; no file was created |
| 不能覆盖原文件。Mulu 只写新文件。 | Mulu never overwrites the original. Choose a new name. |
| 原文件在打开后被改动过，请重新打开再写入。 | The original file changed after it was opened. Reopen it, then write again. |
| 还有 %lld 条可疑没有核对。仍然写入？ | %lld entries still need checking. Write anyway? |
| 先审阅 / 仍然写入 | Review First / Write Anyway |
| %lld 条没有页码 | %lld entries have no page |
| 删除这些行（保留子项） | Delete These Entries (Keep Children) |
| 已载入 PDF 里原有的目录（%lld 条） | Loaded the PDF's existing outline (%lld entries) |
| 这个 PDF 已加密。Mulu v0.1 不能给加密的 PDF 写目录。 | This PDF is encrypted. Mulu 0.1 cannot add an outline to encrypted PDFs. |
| 审阅 %lld/%lld | Review %lld/%lld |
| 全部看完了：已核对 %lld 条 | All done: %lld entries checked |
| 有 %lld 个窗口的目录修改还没有写入 PDF。仍然退出？ | %lld windows have outline changes that are not written to a PDF. Quit anyway? |

可疑原因与提示的中文标题（`DoubtReason.Kind` / `Advisory.Kind` → 文案）：标题在不同分辨率下读法不一致，请核对文字 / 标题只从放大图里读出，请核对文字 / 识别把握低（%@） / 印刷页码比上一条小 / 没有页码 / 页码是在正文页上找到标题后得出的 / 原目录项无法解析到页面，暂用上一条的页 / 导入时的提示；这几页没有识别出文字，它们是目录页吗？ / 带页码的条目太少 / 大部分行不像目录 / 页码偏移没能确定 / 页码和章标题给出的偏移不一致 / 偏移可能在书中间改变 / 偏移让第一章落在目录页之前 / 大部分条目超出了最后一页 / 前言（罗马数字）页码没能对上 / 可疑条目太多 / 识别提示 / 解析提示。英文按同样语气翻译。

### 7.3 `scripts/check_strings.py`（P1）

用 `uv run --python 3.12` 或系统 `python3` 运行。扫描 `Sources/MuluApp/**/*.swift` 和 `Sources/MuluAppModel/**/*.swift` 里 `Text(`、`Button(`、`Label(`、`Toggle(`、`Menu(`、`.help(`、`.navigationTitle(`、`String(localized:`、`LocalizedStringKey(` 的**含中文**字符串字面量，把 `\(…)` 插值换成 `%lld`（整数上下文无法判断时两种都接受）/`%@`，检查每个键在 xcstrings 里存在且有 `en` 翻译；缺失时列出并退出 1。

---

## 8. 打包

### 8.1 `scripts/package_app.sh`

```
用法: scripts/package_app.sh [--version 0.1.0] [--skip-build]
输出: dist/Mulu.app、dist/Mulu-<version>-macos-arm64.zip（并打印 SHA-256）
```

步骤（`set -euo pipefail`，全部 `nice -n 15`）：

1. `swift build -c release --product MuluApp`（后台运行时由调用者负责；脚本本身前台，约 1–3 分钟，自动化调用时建议放后台并轮询日志）。`BIN=$(swift build -c release --show-bin-path)`。
2. `rm -rf dist/Mulu.app`；建 `Contents/MacOS`、`Contents/Resources`。
3. `cp "$BIN/MuluApp" dist/Mulu.app/Contents/MacOS/Mulu`。
4. 资源：`cp -R "$BIN/mulu_MuluApp.bundle" Contents/Resources/`（F5，防止任何 `Bundle.module` 访问崩溃）；建 `Contents/Resources/en.lproj` 和 `zh-Hans.lproj`，把资源包里的 `en.lproj/Localizable.strings`（及 `*.stringsdict`）复制进 `en.lproj/`（§7.1）。
5. 写 Info.plist（§8.3，`VERSION`、`BUILD = git rev-list --count HEAD`，失败则 1），`plutil -lint`。可选：`Resources/AppIcon.icns` 存在时复制并加 `CFBundleIconFile`（P2）。
6. 签名：`codesign --force --sign - --options runtime --timestamp=none dist/Mulu.app`，然后 `codesign --verify --strict --verbose=2 dist/Mulu.app`。不需要任何 entitlements（不沙盒；Vision、CoreGraphics、PDFKit、文件读写都不需要权限声明）。
7. 压缩：`ditto -c -k --sequesterRsrc --keepParent dist/Mulu.app dist/Mulu-$VERSION-macos-arm64.zip`；`shasum -a 256`。
8. 打印产物路径、大小、架构（`lipo -archs`）。

v0.1 只出 arm64（本机架构）。通用二进制需要 `swift build --arch arm64 --arch x86_64`（走 Xcode 构建系统，产物路径不同），留到 v0.2 并在 Intel Mac 上测过再说。

### 8.2 dist 目录结构

```
dist/Mulu.app/Contents/
  Info.plist
  MacOS/Mulu
  Resources/en.lproj/Localizable.strings
  Resources/zh-Hans.lproj/            (空目录)
  Resources/mulu_MuluApp.bundle/
  _CodeSignature/
```

### 8.3 Info.plist（完整）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.terryg907.mulu</string>
  <key>CFBundleName</key><string>Mulu</string>
  <key>CFBundleDisplayName</key><string>Mulu</string>
  <key>CFBundleExecutable</key><string>Mulu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 TerryG907. MIT License.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
```

`LSHandlerRank = Alternate`：Mulu 出现在「打开方式」里，但不会成为 PDF 的默认打开程序（「预览」不受影响）。`CFBundleDocumentTypes` 只有在 App 被 LaunchServices 注册后才生效（第一次启动或拷进「应用程序」文件夹后）。

### 8.4 首次打开的提示（写进 README 的 GUI 小节）

ad-hoc 签名的 App 从网上下载（带隔离属性）后，Gatekeeper 会拦：macOS 14 上右键 ▸ 打开；macOS 15 及以后要去「系统设置 ▸ 隐私与安全性」点「仍要打开」。自己从源码构建的不受影响。

### 8.5 公证

公证（`notarytool`）需要 Apple Developer Program 的 Developer ID Application 证书（年费 99 美元），v0.1 不做。以后要做：用 Developer ID 签名（`--options runtime --timestamp`）→ `xcrun notarytool submit … --wait` → `xcrun stapler staple dist/Mulu.app` → 再压缩。

---

## 9. 测试计划

所有测试用 Swift Testing（`import Testing`），需要主 actor 的测试标 `@MainActor`。OCR 相关的 suite 标 `.serialized`。测试用到的 PDF **全部在测试里生成**，放在 `FileManager.default.temporaryDirectory` 下带 pid 的文件名，`defer` 删除（照搬 `SyntheticPDF.tempURL` 的做法）。新增测试总耗时目标 < 60 秒。

### 9.1 MuluAppModelTests

辅助：`Tests/MuluAppModelTests/SyntheticBook.swift`，从 `Tests/MuluOCRTests/SyntheticPDF.swift` 复制需要的部分（`vectorPDF`、`scanned`、`paintTOC`、字体、`draw*`），`@testable import MuluOCR`（`GrayImage.makeContext`、`init(context:)` 是 internal）。另加：

- `plainPDF(pages: Int) -> URL`：CoreGraphics 画 N 页、每页一行大字「Page N」的矢量 PDF（写入往返用，毫秒级）。
- `scannedBook(tocCopies: Int = 1, folios: Bool = true) -> (url: URL, tocPages: [Int], offset: Int, entries: [(title: String, printed: Int, level: Int)])`：第 1 页书名；第 2 页目录（6 条、两级、标题互不相似，例如「第一章 市场与价格 1 / 第一节 需求 3 / 第二章 消费者行为 9 / 第二节 效用 12 / 第三章 生产与成本 17 / 第四章 市场结构 25」，带引导点、右对齐页码）；第 3 页空白；第 4 页起正文印刷页 1–32（每章首页顶部大字章标题、其余页有页眉，页脚外侧页码，照 `SyntheticPDF.book` 的画法）→ 偏移 +3，共 35 页。`tocCopies > 1` 时目录页重复画在第 2…(1+tocCopies) 页，正文顺延（偏移随之变大）；`folios: false` 时不画页脚页码。200 dpi 二值化扫描。

| 测试 | 内容 |
|---|---|
| `DraftOperationTests`（纯值，无文件） | 表驱动：indent/outdent/moveUp/moveDown/addSibling/addChild/delete/delete(keepChildren:) 各种位置（首行、末行、带子项、多选连续兄弟、多选非连续）→ 期望的 `[(title, level)]`；不能操作时返回 false 且草稿不变。性质测试：固定种子随机 500 步操作序列，每步后不变式成立；然后全部撤销，草稿与初始逐字段相等；再全部重做，与结束时相等。 |
| `MappingTests` | 印刷页 + 偏移、罗马页 + 前言偏移（nil 时无页）、固定页不随偏移、`shiftPages` 对固定页/印刷页/无页三种行和子项的作用、`calibrateOffset`、越界产生 `pageOutOfRange`、`pageBeforePrevious` 只是警告、可疑原因的清除规则（改标题只清标题范围）、行状态派生、`isDirty` 只看输出投影（打 ✓ 不脏）。 |
| `DocumentRoundTripTests` | **主往返**：`plainPDF(40)` → `DocumentModel(url:undoManager:)`（`groupsByEvent = false`）→ `load()` → `.ready`、40 页、无行 → `startRecognition(RecognitionRequest(input: .text(五行印刷目录), knownOffset: nil, detectOffset: false))` + `await waitForRecognition()` 产生 5 行印刷页草稿（偏移 0）→ `acceptRecognition(.replace)` → `setOffset(4)` → 断言物理页 → `shiftPages`（后两章 +2）→ 改标题、缩进、上移、添加、删除 → 逐步撤销并断言每一步的输出投影，再重做回来 → `write(to: 临时/out.pdf)` → 断言 `report.originalBytesUnchanged`、`appendedBytes > 0`、`items == 行数`；磁盘上输出文件前 N 字节与输入逐字节相等（N = 输入大小）；`PDFFile(bytes:).readOutline()` 的 (title, level, pageIndex) 与期望完全相同；输入文件 SHA-256 前后不变。**再写一次到同一路径**成功（替换）。`validateOutputURL(输入)` 与 `write(to: 输入)` 都抛 `.wouldOverwriteInput`；指向输入的符号链接同样被拒。 |
| | **已有目录**：用 `Mulu.apply` 给 `plainPDF(12)` 写 3 条目录 → 打开输出 → 行 = 3，`manualPage` 正确，`isDirty == false`，撤销栈为空。 |
| | **写入失败**：输出文件夹不存在 / 只读（`chmod 0555` 的临时文件夹）→ `.notWritable` 或 `.io`，文件夹里没有残留的 `.mulu-*.tmp`；打开后向输入文件追加 1 字节 → `.inputChanged`；有空标题 / 无页码 / 越界的行 → `.blocked`，且 `writeReadiness().blockers` 列出对应行。 |
| `RecognitionTests`（`.serialized`） | **识别合成扫描书**：`scannedBook()` → 打开 → `startRecognition(pages: [2])` → `await waitForRecognition()` → `.finished`；行数 6；每个标题与真值的字符相似度 ≥ 0.9（照搬 `OCRIntegrationTests.similarity`）；层级正确；`mapping.offset == 3`、`offsetSource == .detected`；可疑 0；`autoWouldAccept == true`；进度回调出现过 `readingTOC` 和 `detectingOffset`，`fraction` 单调不减 → `acceptRecognition(.replace)` → 写入 → 回读的 pageIndex == 印刷页 + 3 − 1。 |
| | **取消**：`scannedBook(tocCopies: 6)`（同一目录页画 6 遍，第 2–7 页）→ `startRecognition(pages: [2, 3, 4, 5, 6, 7])`；收到第一个 `readingTOC` 进度后 `cancelRecognition()` → 5 秒内状态为 `.cancelled`，草稿不变，`recognition` 之后可以重新开始。 |
| | **偏移不确定**：生成没有页脚页码的扫描书（`folios: false` 的画法）→ 识别仍 `.finished`，行存在，`offsetSource ∈ {.bestGuess, .none}`，advisories 含 `offsetUncertain`，`autoWouldAccept == false`；随后 `calibrateOffset(using: 第一章, physicalPage: 4)` → `offset == 3`，全部物理页正确。 |
| `InteropTests` | 5 种格式 × `exportText` → `importOutline(bytes:fileName:format:mode: .replace)` → 输出投影相同（pdfdir 导入后是印刷页、偏移 0，物理页仍相同）；特殊标题（中英混排、`&<>"`、全角空格、以 `#` 开头的 0 级标题——期望值按各格式写入器的规则计算：mulu 格式写成 `＃`，其他格式保持 `#`，测试逐格式写明）；GB18030 编码的 pdfdir 文本能导入；PDF补丁丁 XML 用中文元素名。`.append` 模式层级和偏移补差正确。 |
| `SmokeTests` | `SmokeConfig(environment:)`：未设置 → nil；各变量解析、超时夹在 5–120；`SmokeReport` 编码成 JSON 后字段名与 §9.3 一致（用固定值比对）。`SmokeRunner.run` 在 `plainPDF` 上（无识别、有写入）→ `status == "ok"`，写出的文件回读正确。 |
| `ThumbnailTests` | `ThumbnailRenderer` 渲染第 1 页，宽 ≤ `maxPixelWidth`，同一页第二次命中缓存（返回同一对象或计数器）；页码越界抛错。 |
| MuluOCRTests/`ProgressHookTests` | §3.2。 |

`swift test` 全部通过的同时，`tools/run_all.sh`（默认参数）仍须 31/31 + 47/47（MuluCore 未改，这一项主要是确认没有误改）。

### 9.2 界面层

MuluApp 没有单元测试目标（SwiftUI 视图、AppKit 桥接），靠：`swift build` 通过、烟雾测试、`check_strings.py`、§9.5 手工清单。把能放进模型的逻辑都放进模型。

### 9.3 烟雾模式（`MULU_SMOKE`）

环境变量：

| 变量 | 含义 |
|---|---|
| `MULU_SMOKE` | PDF 的绝对路径；或字面量 `@odoc`：不主动打开，等外部 odoc 事件（`open -a Mulu.app file.pdf`）送来的 URL，最多 10 秒 |
| `MULU_SMOKE_TOC` | 可选，目录页范围（如 `4-5`）：打开后识别并以 `.replace` 采用 |
| `MULU_SMOKE_OFFSET` | 可选，已知偏移（等于识别面板的「我知道偏移」） |
| `MULU_SMOKE_WRITE` | 可选，输出 PDF 路径：执行 `write(to:)`（不能等于输入，所在文件夹须存在） |
| `MULU_SMOKE_OUT` | JSON 输出路径（原子写）；未设置时打印到 stdout |
| `MULU_SMOKE_TIMEOUT` | 秒，默认 20，夹在 5–120 |
| `MULU_SMOKE_HOLD` | 可选，秒（0–60，默认 0）：写完 JSON 后窗口再保留这么久才退出（截图用） |
| `MULU_SMOKE_CLOSE` | 可选，`1`：写完 JSON 后像点关闭按钮一样关掉窗口，确认会话、模型、PDFKit 文档和缩略图渲染器都被释放；退出码 0 = 已释放，4 = 关窗 4 秒后仍在内存里（stderr 有一行说明） |

行为：`AppDelegate` 读到配置 → 设 `appState.smoke` → 启动窗口接管 `MULU_SMOKE` 的 URL（与正常打开走同一路径）→ `SmokeRunner.run(config, document:)`：`await load()` → 可选识别（`waitForRecognition`）→ 可选写入 → 生成 `SmokeReport` → App 层补上 `app` 字段 → 写 JSON → `NSApp.terminate(nil)`。看门狗：`DispatchQueue.main.asyncAfter(timeout − 0.5 s)` 若还没写 JSON，就写 `status: "timeout"` 并 `exit(3)`。烟雾模式下不弹任何警告框、保存面板，不做退出确认，不读写 `MULU_SMOKE_OUT`/`MULU_SMOKE_WRITE` 以外的文件。退出码：0 = ok，1 = error，3 = timeout。

JSON（`schema: 1`，字段名固定，`SmokeTests` 锁定）：

```json
{
  "schema": 1,
  "status": "ok",
  "error": null,
  "elapsed": 7.93,
  "app": {"bundled": true, "bundleIdentifier": "io.github.terryg907.mulu", "version": "0.1.0",
          "activationPolicy": "regular", "windowsVisible": 1, "language": "zh-Hans"},
  "document": {"path": "/…/book.pdf", "phase": "ready", "pageCount": 42, "existingOutlineItems": 0},
  "recognition": {"status": "finished", "tocPages": [4, 5], "rows": 33, "doubtful": 0, "offset": 6,
                  "offsetSource": "detected", "autoWouldAccept": true, "advisories": [], "seconds": 8.1,
                  "muluText": "# Mulu TOC from a printed TOC: …\n…"},
  "draft": {"rows": 33, "errors": 0, "doubtful": 0, "dirty": true},
  "write": {"output": "/…/out.pdf", "appendedBytes": 6973, "items": 33, "originalBytesUnchanged": true}
}
```

`status` 为 `error` 的情况：文档加载失败、识别以 failed/cancelled 结束、写入失败；`error` 字段为原文。没有识别/写入时对应字段为 `null`。

`scripts/smoke_app.sh [--bin <MuluApp 可执行文件> | --app dist/Mulu.app]`（默认 `--app`，不存在则用 `swift build --show-bin-path` 下的 `MuluApp`）：每段带 25 秒强杀保护、`-ApplePersistenceIgnoreState YES`，用 `python3 -c` 校验 JSON，最后确认没有 Mulu 进程残留。总时长约 1 分钟，自动化调用时放后台并轮询。

| 段 | 输入 | 期望 |
|---|---|---|
| A 打开 + 已有目录 + 写入 | `Fixtures/generated/existing_outline.pdf`（没有就提示先跑一次 `tools/run_all.sh`，跳过），`MULU_SMOKE_WRITE=$TMPDIR/…/out.pdf` | `status ok`、`document.existingOutlineItems ≥ 1`、`draft.rows` 相同、`write.originalBytesUnchanged true`、`app.windowsVisible ≥ 1` |
| B 识别 | `Fixtures/books/zh_finance_small_jpeg.pdf`（42 页，目录页 4–5，偏移 +6，33 条；没有则跳过并说明），`MULU_SMOKE_TOC=4-5` | `recognition.status finished`、`offset == 6`、`rows ≥ 30` |
| C Finder 打开（仅 `--app`） | `open -n -a dist/Mulu.app --env MULU_SMOKE=@odoc --env MULU_SMOKE_OUT="$OUT" "$PDF" --args -ApplePersistenceIgnoreState YES`（`$PDF` = A 段的文件；`open` 立即返回，脚本轮询 `$OUT` 出现，最多 25 秒） | `status ok`、`app.windowsVisible == 1`（验证 §6.8 的空窗口自关） |
| D 语言（仅 `--app`） | 直接执行 `dist/Mulu.app/Contents/MacOS/Mulu -AppleLanguages "(zh-Hans)"`，再以 `"(en)"` 各跑一次，`MULU_SMOKE` = A 段的文件 | `app.language` 分别为 `zh-Hans`、`en`（`Bundle.main.preferredLocalizations.first`） |
| E 关窗释放文档 | `MULU_SMOKE` = A 段的文件，`MULU_SMOKE_CLOSE=1` | `status ok`、退出码 0（关窗后会话、模型、PDF 文档、缩略图都已释放） |

烟雾只证明「能启动、能走通、能退出」，不证明窗口画在屏幕上（F3）。

### 9.4 与 `mulu auto` 的一致性检查（P1，`scripts/smoke_app.sh --parity`）

对 `Fixtures/books/` 下存在的每本合成书（`manifest.json` 给出目录页）：跑 `mulu auto <pdf> --toc-pages <p> --dry-run`（stdout 是 muluText，退出码 0/2）和烟雾 B 段；断言 `recognition.autoWouldAccept == (退出码 == 0)`，接受时 `recognition.muluText` 与 stdout 逐字节相同。13 本约 2 分钟，必须后台运行。

### 9.5 手工验收清单（发布前在真机上看一遍）

1. `dist/Mulu.app` 双击启动：有 Dock 图标、菜单栏、空状态窗口；以 `-AppleLanguages "(zh-Hans)"` 启动显示中文，默认（本机英文优先）显示英文。
2. 把合成书拖进窗口 → 缩略图、预览、空编辑器；⌘-点目录页 → ⌘R → 进度 → 结果 → 替换 → 点行预览跳页 → 改偏移全部跟着变 → 选后半段 `]` → Tab/⇧Tab → ⌥⌘↑ → ⌘Z 一路撤回 → ⌘⇧Z → ⌘⇧R 审阅走完 → ⌘S 默认名 `<name>-目录.pdf` → 横幅 → 在 Finder 中显示 → 用「预览」打开输出，目录正确。
3. 保存面板里选原文件名 → 面板内报错，不写。
4. Finder 右键 ▸ 打开方式 ▸ Mulu（App 未运行时）→ 只有一个窗口。
5. 有未写入修改时 ⌘Q → 确认框。
6. 加密 PDF → 失败视图。

---

## 10. 公共 API 契约（MuluAppModel）

以下是界面层（B）可以调用的**全部**公共接口。模型层（A）必须一字不差地提供这些签名（可以多加，不能少、不能改）。所有值类型都是 `Sendable`；所有 `DocumentModel` 成员都在 `@MainActor`。

```swift
import Foundation
import CoreGraphics
import MuluCore
import MuluOCR

// MARK: - Draft values

public struct PrintedPageRef: Sendable, Hashable, Codable {
    public enum Style: String, Sendable, Hashable, Codable { case arabic, roman }
    public var style: Style
    public var value: Int
    public var display: String                     // "12" or "iv" as printed
    public init(style: Style, value: Int, display: String? = nil)
}

public struct DoubtReason: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case unstableTitle, enlargedTitle, lowConfidence, pageOrder, noPage,
             locatedFromHeading, unresolvedDestination, importWarning
    }
    public enum Scope: String, Sendable, Hashable, Codable { case title, page, both }
    public var kind: Kind
    public var detail: String                      // verbatim English note; may be empty
    public var confidence: Double?                 // lowConfidence only
    public init(kind: Kind, detail: String = "", confidence: Double? = nil)
    public var scope: Scope { get }
    public var isDoubt: Bool { get }               // false for .locatedFromHeading
}

public struct OutlineRow: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var title: String
    public var level: Int
    public var printedPage: PrintedPageRef?
    public var sectionShift: Int
    public var manualPage: Int?
    public var doubts: [DoubtReason]
    public var confirmed: Bool
    public var pageOverride: Bool { get }          // manualPage != nil
    public init(id: UUID = UUID(), title: String, level: Int, printedPage: PrintedPageRef? = nil,
                sectionShift: Int = 0, manualPage: Int? = nil, doubts: [DoubtReason] = [], confirmed: Bool = false)
}

public struct PageMapping: Sendable, Hashable, Codable {
    public var offset: Int
    public var romanOffset: Int?
    public init(offset: Int = 0, romanOffset: Int? = nil)
    public func physicalPage(for row: OutlineRow) -> Int?
}

public struct OutlineDraft: Sendable, Hashable, Codable {
    public var rows: [OutlineRow]
    public var mapping: PageMapping
    public init(rows: [OutlineRow] = [], mapping: PageMapping = PageMapping())
    public static func levelsAreValid(_ rows: [OutlineRow]) -> Bool
    /// Clamps levels so the invariant holds (first row 0, each row at most one deeper than the previous).
    public static func clampedLevels(_ rows: [OutlineRow]) -> [OutlineRow]
    /// One entry per row (title normalized with MuluTOCFormat.oneLine, level, physical page, line = index + 1);
    /// nil when any row has no physical page.
    public func outputEntries() -> [TOCEntry]?
}

public enum RowIssue: Sendable, Hashable {
    case emptyTitle
    case noPhysicalPage
    case pageOutOfRange(page: Int, pageCount: Int)
    case pageBeforePrevious(previous: Int)
    public var blocksWrite: Bool { get }           // all but .pageBeforePrevious
}

public enum RowStatus: String, Sendable, Hashable { case ok, doubtful, confirmed, error }

public struct DisplayRow: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let index: Int                          // position in draft.rows
    public let level: Int
    public let title: String
    public let printedPage: PrintedPageRef?
    public let physicalPage: Int?
    public let pageOverride: Bool
    public let sectionShift: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
    public let status: RowStatus
    public let doubts: [DoubtReason]
    public let issues: [RowIssue]
}

public struct DraftCounts: Sendable, Hashable {
    public var rows: Int
    public var doubtful: Int                       // status == .doubtful
    public var confirmed: Int
    public var errors: Int                         // status == .error
}

// MARK: - Document

public struct FileFingerprint: Sendable, Hashable {
    public var size: Int
    public var modified: Date
    public var device: UInt64
    public var inode: UInt64
    public static func of(_ url: URL) throws -> FileFingerprint
}

public struct PDFSummary: Sendable, Equatable {
    public var pageCount: Int
    public var fileSize: Int
    public var info: DocumentInfo                  // MuluCore
    public var existingOutline: [OutlineItemInfo]  // MuluCore
    public var fingerprint: FileFingerprint
}

public enum OpenFailure: Error, Sendable, Hashable, CustomStringConvertible {
    case notPDF(String), encrypted, noPages, unreadable(String)
    public var description: String { get }         // English detail (MuluError text)
}

public enum DocumentPhase: Sendable, Hashable { case loading, ready, failed(OpenFailure) }

public struct PreviewRequest: Sendable, Hashable { public var page: Int; public var serial: Int }

public struct EditRequest: Sendable, Hashable {
    public enum Field: String, Sendable, Hashable { case title, page }
    public var rowID: UUID
    public var field: Field
    public var serial: Int
}

public enum MergeMode: String, Sendable, Hashable, CaseIterable { case replace, append, insertAfterFocused }

public struct ReviewSession: Sendable, Hashable {
    public var queue: [UUID]
    public var position: Int
    public var onlyDoubtful: Bool
    public var finished: Bool
    public var current: UUID? { get }
}

public struct ImportReport: Sendable, Hashable {
    public var format: TOCFormat
    public var count: Int
    public var warnings: [String]
    public var mode: MergeMode
}

public enum OffsetSource: String, Sendable, Hashable {
    case given, detected, pageNumbersAndHeadings, bestGuess, none, manual, calibrated, existingOutline
}

public struct OffsetEvidence: Sendable, Hashable {
    public var agreeing: Int
    public var samples: Int
    public var confidence: Double
    public var headingsChecked: Int
    public var headingsConfirmed: Int
    public var reason: String                      // OffsetReport.reason, verbatim
}

public struct OffsetInfo: Sendable, Hashable {
    public var source: OffsetSource
    public var evidence: OffsetEvidence?
    public var calibratedFromPage: Int?
}

public enum Banner: Sendable, Hashable {
    case loadedExisting(count: Int)
    case recognitionApplied(count: Int, doubtful: Int)
    case imported(ImportReport)
    case wrote(WriteReport)
}

// MARK: - Recognition

public enum RecognitionInput: Sendable, Hashable { case tocPages([Int]), text(String) }

public struct RecognitionRequest: Sendable, Hashable {
    public var input: RecognitionInput
    public var knownOffset: Int?
    public var detectOffset: Bool                  // false: use knownOffset ?? 0 without detection
    public init(input: RecognitionInput, knownOffset: Int? = nil, detectOffset: Bool = true)
}

public struct RecognitionProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case readingTOC, parsing, detectingOffset, checkingHeadings, frontMatter, locatingHeadings, finishing
    }
    public var phase: Phase
    public var step: Int                           // e.g. TOC page index (0-based) or offset sample count
    public var total: Int
    public var fraction: Double                    // overall 0...1, non-decreasing
}

public struct Advisory: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case noText, fewEntries, notTOCLike, offsetUncertain, offsetHeadingsDisagree, offsetMayChange,
             firstChapterBeforeTOC, entriesBeyondLastPage, romanUnresolved, tooManyDoubtful,
             ocrWarning, parserWarning
    }
    public enum Severity: String, Sendable, Hashable { case info, warning }
    public let id: UUID
    public var kind: Kind
    public var severity: Severity
    public var blocksAuto: Bool
    public var detail: String                      // verbatim English
}

public struct RecognitionResult: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable { case ocr, pastedText }
    public var source: Source
    public var tocPages: [Int]
    public var rows: [OutlineRow]
    public var mapping: PageMapping
    public var offsetInfo: OffsetInfo
    public var advisories: [Advisory]
    public var ocrLines: Int
    public var doubtfulCount: Int                  // counted exactly like `mulu auto`
    public var autoWouldAccept: Bool
    public var muluText: String                    // PrintedTOCResult.muluText(header: true, annotate: true)
    public var seconds: Double
}

public enum RecognitionState: Sendable, Hashable {
    case idle
    case running(RecognitionProgress)
    case finished(RecognitionResult)
    case failed(String)
    case cancelled
}

public enum RecognitionError: Error, Sendable, Hashable, CustomStringConvertible {
    case notReady, alreadyRunning, noPages, tooManyPages(Int), invalidPages(String)
    public var description: String { get }
}

/// Synchronous, heavy: call off the main actor. Throws CancellationError when the current task is cancelled.
public struct RecognitionPipeline: Sendable {
    public init(url: URL, pageCount: Int)
    public func run(_ request: RecognitionRequest,
                    progress: @escaping @Sendable (RecognitionProgress) -> Void) throws -> RecognitionResult
}

// MARK: - Write

public enum WriteBlocker: Sendable, Hashable {
    case notReady, busy, noRows
    case row(id: UUID, index: Int, issue: RowIssue)
}

public struct WriteReadiness: Sendable, Hashable {
    public var blockers: [WriteBlocker]
    public var unconfirmedDoubtful: Int
    public var orderWarnings: Int
    public var canWrite: Bool { get }
}

public struct WriteReport: Sendable, Hashable {
    public var output: URL
    public var inputSize: Int
    public var outputSize: Int
    public var appendedBytes: Int
    public var items: Int
    public var pageCount: Int
    public var originalBytesUnchanged: Bool        // verified on the file re-read from disk
    public var seconds: Double
}

public enum WriteError: Error, Sendable, Hashable, CustomStringConvertible {
    case blocked([WriteBlocker])
    case wouldOverwriteInput
    case notWritable(String)
    case inputChanged
    case refused(String)                           // MuluError.description, verbatim
    case io(String)
    case verificationFailed(String)
    public var description: String { get }
}

// MARK: - DocumentModel

@MainActor @Observable
public final class DocumentModel: Identifiable {
    public nonisolated let id: UUID
    public nonisolated let url: URL

    public init(url: URL, undoManager: UndoManager? = nil)
    /// UI development without a file: phase .ready, writing blocked with .notReady.
    public init(previewRows: [OutlineRow], pageCount: Int, mapping: PageMapping = PageMapping())

    // Loading
    public private(set) var phase: DocumentPhase
    public private(set) var summary: PDFSummary?
    public var pageCount: Int { get }
    public func load() async

    // Draft and derived state
    public private(set) var draft: OutlineDraft
    public private(set) var displayRows: [DisplayRow]
    public private(set) var counts: DraftCounts
    public private(set) var revision: Int
    public private(set) var isDirty: Bool
    public private(set) var offsetInfo: OffsetInfo?
    public private(set) var advisories: [Advisory]
    public private(set) var banner: Banner?
    @ObservationIgnored public var undoManager: UndoManager
    public func row(_ id: UUID) -> OutlineRow?
    public func physicalPage(of id: UUID) -> Int?
    public func dismissAdvisory(_ id: UUID)
    public func dismissBanner()

    // Selection, preview, editing requests
    public private(set) var selection: Set<UUID>
    public private(set) var focusedRowID: UUID?
    public private(set) var previewRequest: PreviewRequest?
    public private(set) var previewPage: Int                    // 1-based
    public private(set) var editRequest: EditRequest?
    public func select(_ ids: Set<UUID>, focus: UUID?)
    public func requestPreview(page: Int)
    public func previewDidShow(page: Int)
    public func requestEdit(_ id: UUID, field: EditRequest.Field)

    // Expansion (not undoable)
    public func isExpanded(_ id: UUID) -> Bool
    public func toggleExpanded(_ id: UUID)
    public func setExpanded(_ id: UUID, _ expanded: Bool)
    public func expandAll()
    public func collapseAll()

    // Editing: each call is at most one undo step; returns whether the draft changed
    @discardableResult public func setTitle(_ id: UUID, _ title: String) -> Bool
    @discardableResult public func setPhysicalPage(_ id: UUID, _ page: Int?) -> Bool
    @discardableResult public func setPrintedPage(_ id: UUID, _ page: PrintedPageRef?) -> Bool
    @discardableResult public func pinToPreviewPage(_ id: UUID) -> Bool
    @discardableResult public func clearOverride(_ ids: Set<UUID>) -> Bool
    @discardableResult public func indent(_ ids: Set<UUID>) -> Bool
    @discardableResult public func outdent(_ ids: Set<UUID>) -> Bool
    @discardableResult public func moveUp(_ ids: Set<UUID>) -> Bool
    @discardableResult public func moveDown(_ ids: Set<UUID>) -> Bool
    @discardableResult public func addSibling(after id: UUID?, title: String = "") -> UUID
    @discardableResult public func addChild(of id: UUID, title: String = "") -> UUID
    @discardableResult public func delete(_ ids: Set<UUID>, keepChildren: Bool = false) -> Bool
    @discardableResult public func setConfirmed(_ ids: Set<UUID>, _ confirmed: Bool) -> Bool
    @discardableResult public func shiftPages(_ ids: Set<UUID>, by delta: Int) -> Bool
    @discardableResult public func setOffset(_ offset: Int) -> Bool
    @discardableResult public func setRomanOffset(_ offset: Int?) -> Bool
    @discardableResult public func calibrateOffset(using id: UUID, physicalPage: Int) -> Bool
    public func replaceDraft(_ draft: OutlineDraft, actionName: String)
    public func canIndent(_ ids: Set<UUID>) -> Bool
    public func canOutdent(_ ids: Set<UUID>) -> Bool
    public func canMoveUp(_ ids: Set<UUID>) -> Bool
    public func canMoveDown(_ ids: Set<UUID>) -> Bool
    public func canCalibrate(using id: UUID) -> Bool

    // TOC pages (not undoable)
    public private(set) var tocPages: [Int]                    // sorted, unique
    public var tocPagesSpec: String { get }                     // "5-7,9"
    public func toggleTOCPage(_ page: Int)
    public func setTOCPages(_ pages: [Int])
    public func setTOCPages(spec: String) throws                // RecognitionError.invalidPages / .tooManyPages

    // Recognition
    public private(set) var recognition: RecognitionState
    public func startRecognition(pages: [Int]? = nil, knownOffset: Int? = nil) throws   // nil pages → tocPages
    public func startRecognition(_ request: RecognitionRequest) throws
    public func cancelRecognition()
    public func waitForRecognition() async
    public func acceptRecognition(_ mode: MergeMode)
    public func discardRecognition()

    // Review
    public private(set) var review: ReviewSession?
    public func startReview(onlyDoubtful: Bool)
    public func reviewMove(_ delta: Int)
    public func reviewConfirmAndAdvance()
    public func endReview()

    // Import / export
    @discardableResult
    public func importOutline(from url: URL, format: TOCFormat? = nil, mode: MergeMode = .replace) throws -> ImportReport
    @discardableResult
    public func importOutline(bytes: [UInt8], fileName: String?, format: TOCFormat?, mode: MergeMode) throws -> ImportReport
    public func exportText(format: TOCFormat) throws -> String  // WriteError.blocked when rows lack pages
    public func export(to url: URL, format: TOCFormat) throws
    public func defaultExportURL(format: TOCFormat, suffix: String = "-目录") -> URL  // "<dir>/<name><suffix>.<ext>"

    // Write
    public private(set) var isWriting: Bool
    public private(set) var lastWrite: WriteReport?
    public func writeReadiness() -> WriteReadiness
    public func defaultOutputURL(suffix: String = "-目录") -> URL  // "<dir>/<name><suffix>.pdf"
    public func validateOutputURL(_ url: URL) throws            // WriteError.wouldOverwriteInput / .notWritable
    public func write(to output: URL) async throws -> WriteReport   // throws WriteError
}

// MARK: - Thumbnails

public struct ThumbnailImage: @unchecked Sendable {
    public let page: Int
    public let cgImage: CGImage
}

public actor ThumbnailRenderer {
    public init(url: URL) throws
    public var pageCount: Int { get }
    public func thumbnail(page: Int, maxPixelWidth: Int) throws -> ThumbnailImage   // cached (LRU, ~300)
}

// MARK: - Smoke

public struct SmokeConfig: Sendable, Hashable {
    public enum Target: Sendable, Hashable { case file(URL), openEvent }
    public var target: Target
    public var tocPages: String?
    public var knownOffset: Int?
    public var writeTo: URL?
    public var output: URL?
    public var timeout: Double
    public init?(environment: [String: String])
}

public struct SmokeAppFacts: Sendable, Hashable, Codable {
    public var bundled: Bool
    public var bundleIdentifier: String?
    public var version: String?
    public var activationPolicy: String
    public var windowsVisible: Int
    public var language: String?
    public init(bundled: Bool, bundleIdentifier: String?, version: String?, activationPolicy: String,
                windowsVisible: Int, language: String?)
}

public struct SmokeReport: Sendable, Hashable, Codable {
    // Field layout exactly as the JSON in §9.3 (nested structs Document/Recognition/Draft/Write).
    public var status: String                     // "ok" | "error" | "timeout"
    public var app: SmokeAppFacts?
    public func jsonData() throws -> Data          // sorted keys, "schema": 1
}

@MainActor public enum SmokeRunner {
    public static func run(_ config: SmokeConfig, document: DocumentModel) async -> SmokeReport
    public static func timeoutReport(_ config: SmokeConfig, elapsed: Double) -> SmokeReport
    public static func write(_ report: SmokeReport, to url: URL?) throws
}
```

实现要求补充：

- `parsePastedTOC` 不单独公开：粘贴流程调用 `startRecognition(RecognitionRequest(input: .text(s), knownOffset:, detectOffset:))`，结果同样出现在 `recognition`。
- `select` 之外的方法改变行集合时，模型自己维护 `selection`/`focusedRowID`（删除后选下一行，添加后选新行并发 `editRequest(.title)`）。
- 所有方法对未知 id 静默返回 false/不变；对 `phase != .ready` 的模型，编辑方法可用（预览模型）但写入被 `.notReady` 阻止。
- 横幅、提示、状态的文案全部由视图根据枚举生成（§7.2）。

---

## 11. 风险与 v0.2 清单

| 风险 | 缓解 |
|---|---|
| `WindowGroup(for: URL.self)` + `handlesExternalEvents` 的外部打开行为与实验里的普通 WindowGroup 不同 | §6.8 的规则 + 烟雾 C 段；不行就退回普通 `WindowGroup` + 窗口内 `@State var url` + `AppState` 去重 |
| 移植的 auto 启发式与 CLI 漂移 | 文件头注明来源；§9.4 的逐字节一致性检查；v0.2 抽到共享目标，CLI 与 App 共用 |
| 大文件（数百 MB）写入时内存约为文件大小的 3 倍（输入、输出、解析） | v0.1 接受；写入期间显示进度圈；v0.2 考虑 mmap 读输入 |
| 未打包运行不在当前 Space / 不激活（F2、F3） | 开发时用 `open dist/Mulu.app` 验证界面；自动化只看烟雾 JSON |
| NSTableView 与 SwiftUI 状态双向同步产生循环 | 协调器用「程序正在设置」标志；只按 `revision` 刷新 |
| 用户把输出文件名选成原文件 | 面板 delegate 校验 + `write` 内再次校验（(device, inode) 比较），双保险 |

v0.2 候选：auto 启发式抽成共享目标并让 `mulu auto` 调用；导入时把 `# ?` 注释恢复为可疑原因；印刷页码列内编辑；拖动排序；草稿自动保存；最近打开菜单；App 图标；通用二进制；公证；分段偏移的自动检测（REALSCAN 里 3 本书的失败原因）；竖排目录。

---

## 12. 界面实现记录（2026-09-30）

### 12.1 窗口路由：实测结果与 §6.8 的差异

| # | 事实（打包后的 App，`open -g -n -a Mulu.app file.pdf`，macOS 26.6.2） | 做法 |
|---|---|---|
| F11 | 用 `WindowGroup(for: URL.self)` 时，Finder 式打开的文件 URL 交给 `AppDelegate.application(_:open:)`，`.onOpenURL` 收不到。这与 F7（普通 `WindowGroup`）正好相反。 | `application(_:open:)` → `AppState.receiveExternal(_:)`。最早出现、用户没动过的空窗口接管文件；没有这样的窗口时，由 key 窗口按 §6.8 规则路由：已打开的文件把那个窗口提到前面，否则 `openWindow(value:)`。还没有窗口时先排队，第一个出现的窗口取走。`.onOpenURL` 保留为第二条路径，用 `claimedURL` 去重。 |
| F12 | 场景用 `.handlesExternalEvents(matching: ["*"])` 时，SwiftUI 会为打开事件多开一个空窗口。已有空窗口通过 `url` 绑定接管文件后，会被 SwiftUI 拆掉，最后只剩那个空窗口。 | 场景改用 `.handlesExternalEvents(matching: [])`：不再多开窗口，设置绑定也正常。冷启动空窗口自关规则（§6.8）保留作兜底，实测已不再触发。 |

验证：
- 烟雾 C 段通过：冷启动恰好 1 个可见窗口。
- 手工跟踪（调试代码已删除）：运行中打开第二个文件后是 2 个窗口；再打开第一个文件，仍是 2 个窗口。

### 12.2 其他实现要点

- **File 菜单**：`CommandGroup(replacing: .saveItem)` 会把「关闭 ⌘W」一起去掉，所以改用 `after: .saveItem`。
- **加载的位置**：文档加载放在 `onChange(of: url)` 启动的独立 Task 里，不放在 `.task(id: url)` 里。窗口接管 URL 时，SwiftUI 会取消并重启 `.task`，被取消的加载会让 `phase` 一直停在 `.loading`。
- **撤销分组**：窗口的撤销管理器 `groupsByEvent = true`，自动组要等 AppKit 处理完一个真实事件（按键、点击）才关闭。所以没有事件的程序化修改会并成一步撤销。这只影响自动化测试，真实使用时每个操作都是单独的一步。
- **菜单与编辑中的文字**：菜单快捷键比文本框先拿到按键。所以编辑标题时，行操作命令什么也不做（`TextInputGuard`），⌘⌫、⌥←、⌥→ 转成文本框自己的删除和移动。
- **表格自测**：用临时自测（程序化按键加字段编辑器命令，共 34 项）检查过，连续 3 次全部通过，之后删除。覆盖：
  - 选择双向同步；
  - `]`、`}`、`[`、`{`；
  - Tab / ⇧Tab；
  - 撤销 / 重做；
  - 回车编辑标题并提交、Esc 取消；
  - Tab 从标题跳到页码；
  - 全角页码；未改动的页码不会被固定；非法页码被拒绝；
  - 空格切换 ✓；
  - ← / → 折叠、展开、回到父级；
  - ⌫ 删除；
  - 添加条目后自动进入编辑；
  - 审阅的回车、↓、Esc。
- **离屏截图**：`cacheDisplay` 抓不到 PDFKit 异步绘制的文字页，预览区是白的；布局本身正确（缩放、页面位置已核对）。

### 12.3 契约请求

无。§10 的接口已够用。
