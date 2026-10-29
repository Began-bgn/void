import Foundation
import os

/// Serialises AppleScript execution off the main thread; compiled scripts are cached by source.
actor ScriptRunner {
    static let shared = ScriptRunner()
    private let log = Logger(subsystem: "com.notchdeck.app", category: "applescript")
    private var cache: [String: NSAppleScript] = [:]

    func run(_ source: String) -> String? { execute(source)?.stringValue }
    func runData(_ source: String) -> Data? { execute(source)?.data }

    private func execute(_ source: String) -> NSAppleEventDescriptor? {
        let script = cache[source] ?? NSAppleScript(source: source)
        guard let script else { return nil }
        cache[source] = script
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            log.error("AppleScript failed: \(error.description, privacy: .public)")
            return nil
        }
        return result
    }
}
