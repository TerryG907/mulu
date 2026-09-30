import Foundation
import Testing

/// True when `MULU_SKIP_VISION_TESTS` is set to anything but an empty string or `0`.
let visionTestsSkipped: Bool = {
    let value = ProcessInfo.processInfo.environment["MULU_SKIP_VISION_TESTS"] ?? ""
    return !value.isEmpty && value != "0"
}()

extension Trait where Self == ConditionTrait {
    /// Marks a test or suite that runs Vision text recognition (VNRecognizeTextRequest).
    ///
    /// Vision does not work on every machine: some virtual Macs, hosted CI runners among them,
    /// cannot run text recognition at all. `MULU_SKIP_VISION_TESTS=1 swift test` skips what is
    /// marked with this trait and runs everything else. The CI workflow sets the variable only
    /// when `.github/scripts/vision_probe.swift` fails on the runner. On a Mac where Vision works,
    /// leave it unset so that every test runs.
    static var needsVision: Self {
        .disabled(if: visionTestsSkipped, "MULU_SKIP_VISION_TESTS is set: Vision text recognition is not available here")
    }
}
