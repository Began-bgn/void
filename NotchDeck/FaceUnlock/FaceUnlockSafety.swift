import Foundation
import Security

/// At most one scan every `minInterval`; after failures the wait grows (5 s, then 30 s).
struct ScanRateLimiter: Equatable {
    var minInterval: Double = 2
    var cooldowns: [Double] = [5, 30]
    private(set) var lastStart: Double?

    /// Seconds to wait before a scan may start, 0 when it may start now.
    func wait(at now: Double, failures: Int) -> Double {
        guard let lastStart else { return 0 }
        let gap = failures == 0 ? minInterval : cooldowns[min(failures, cooldowns.count) - 1]
        return max(0, lastStart + gap - now)
    }

    mutating func started(at now: Double) { lastStart = now }
}

/// Conditions under which Face Unlock refuses to run at all.
enum FaceUnlockSupport {
    /// NotchDeck is intact and signed by its own team. A modified or re-signed binary could
    /// otherwise read the keychain item it would no longer be entitled to (it can't), or feed
    /// the input path; refusing is cheap.
    static let codeSignatureValid: Bool = {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"F63KU4246G\"" as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }()

    /// Why Face Unlock can't run, or nil when it can.
    @MainActor static var blocker: String? {
        if !codeSignatureValid { return "Void's code signature check failed" }
        if FaceCaptureService.builtInCamera == nil { return "No built-in camera" }
        if !FaceCaptureService.isAuthorized { return "Camera access not granted" }
        if FaceUnlockCoordinator.recognizer == nil { return "Face model failed to load" }
        return nil
    }
}
