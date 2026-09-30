import AppKit
import MuluAppModel

/// Drives one document through `SmokeRunner` (load → optional recognition → optional write),
/// adds the app facts, writes the JSON and quits: 0 = ok, 1 = error (GUI_SPEC §9.3).
/// With `MULU_SMOKE_CLOSE=1` it then closes the window and checks that the document is freed
/// (`SmokeCloseProbe`: 0 = freed, 4 = still alive). No alerts or panels are shown in smoke mode;
/// the one exception is `MULU_SMOKE_STOP=result` with a hold, which shows the recognition result
/// panel for a screenshot.
@MainActor
enum SmokeDriver {
    static func run(_ config: SmokeConfig, session: DocumentSession, appState: AppState) async {
        var report = await SmokeRunner.run(config, document: session.model)
        await settleWindows(appState)
        report.app = appFacts()
        guard SmokeGate.claim() else { return }
        do {
            try SmokeRunner.write(report, to: config.output)
        } catch {
            FileHandle.standardError.write(Data("mulu smoke: cannot write report: \(error)\n".utf8))
            exit(1)
        }
        guard report.status == "ok" else { exit(1) }
        if config.hold > 0 {
            // MULU_SMOKE_STOP=result: show the result panel the recognition is waiting in.
            if config.stop == .result, case .finished = session.model.recognition {
                session.sheet = .recognize
            }
            try? await Task.sleep(for: .seconds(config.hold))
        }
        if config.closeCheck {
            SmokeCloseProbe.start(session)
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Gives spare cold-launch windows (F8) up to two seconds to close before counting windows.
    private static func settleWindows(_ appState: AppState) async {
        for _ in 0..<20 where appState.emptyWindowCount > 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func appFacts() -> SmokeAppFacts {
        let bundle = Bundle.main
        let policy = switch NSApp.activationPolicy() {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
        return SmokeAppFacts(
            bundled: bundle.bundleIdentifier != nil,
            bundleIdentifier: bundle.bundleIdentifier,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            activationPolicy: policy,
            windowsVisible: NSApp.windows.count { $0.isVisible && !($0 is NSPanel) },
            language: bundle.preferredLocalizations.first)
    }
}
