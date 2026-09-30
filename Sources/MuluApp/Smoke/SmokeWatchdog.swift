import AppKit
import Foundation
import MuluAppModel

/// Smoke-mode deadlines (GUI_SPEC §9.3). Runs off the main actor so it still fires if the main
/// thread hangs: at `timeout − 0.5 s` it writes a `"timeout"` report and exits with code 3.
enum SmokeWatchdog {
    /// How long `MULU_SMOKE=@odoc` waits for Finder's open event.
    static let openEventWait: Double = 10

    @MainActor
    static func start(_ config: SmokeConfig, appState: AppState) {
        let deadline = max(1, config.timeout - 0.5)
        let fallback = (try? SmokeRunner.timeoutReport(config, elapsed: deadline).jsonData())
            ?? Data(#"{"schema":1,"status":"timeout"}"#.utf8)
        let output = config.output
        Task.detached(priority: .high) {
            try? await Task.sleep(for: .seconds(deadline))
            guard SmokeGate.claim() else { return }
            emit(fallback, to: output)
            exit(3)
        }
        if case .openEvent = config.target {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(openEventWait))
                guard !appState.smokeStarted, SmokeGate.claim() else { return }
                let report = SmokeRunner.timeoutReport(config, elapsed: openEventWait)
                emit((try? report.jsonData()) ?? fallback, to: output)
                exit(3)
            }
        }
    }

    /// Writes the JSON atomically to `url`, or to stdout.
    static func emit(_ data: Data, to url: URL?) {
        if let url {
            try? data.write(to: url, options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
