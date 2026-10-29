import AppKit
import Intents
import Observation

/// Focus status via INFocusStatusCenter (read only; macOS has no change callback, so it is
/// re-read on app switches and wake). Toggling runs a user-made Shortcut.
@MainActor @Observable
final class FocusMonitor {
    static let shared = FocusMonitor()

    private(set) var isFocused = false
    private(set) var authorized = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastReading: Bool?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        INFocusStatusCenter.default.requestAuthorization { status in
            Task { @MainActor in
                FocusMonitor.shared.authorized = status == .authorized
                FocusMonitor.shared.refresh()
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FocusMonitor.shared.refresh() }
            })
        }
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        started = false
        isFocused = false
        lastReading = nil
    }

    /// Edge-triggered: only a *change* in the system reading updates the moon. The reading on
    /// macOS can lag or stick, so a stale value must never undo a toggle made from the notch.
    func refresh() {
        guard authorized, let reading = INFocusStatusCenter.default.focusStatus.isFocused,
              reading != lastReading else { return }
        lastReading = reading
        guard reading != isFocused else { return }
        isFocused = reading
        ActivityCenter.shared.show(.focus(on: reading))
    }

    /// Runs the Shortcut named in Settings. If it doesn't exist yet, NotchDeck generates a signed
    /// one ("Set Focus → Toggle Do Not Disturb") and opens it in Shortcuts for a one-time "Add".
    /// The moon flips at once; it flips back only if the Shortcut fails.
    func toggle() {
        let name = SettingsStore.shared.focusShortcutName
        Task.detached {
            guard Self.shortcutExists(name) else {
                let file = Self.makeShortcut(named: name)
                await MainActor.run { FocusMonitor.shared.offerInstall(file) }
                return
            }
            await MainActor.run {
                FocusMonitor.shared.isFocused.toggle()
                ActivityCenter.shared.show(.focus(on: FocusMonitor.shared.isFocused))
            }
            if Self.run("/usr/bin/shortcuts", ["run", name]) == nil {
                await MainActor.run { FocusMonitor.shared.isFocused.toggle() }
            }
        }
    }

    private func offerInstall(_ file: URL?) {
        guard let file else { return }
        NSWorkspace.shared.open(file)
        ActivityCenter.shared.post(.init(
            key: "focus-setup", priority: ActivityPopup.Priority.focus, symbol: "moon", color: .indigo,
            title: String(localized: "Add the Focus shortcut"),
            subtitle: String(localized: "Click “Add Shortcut”, then press the moon again")))
    }

    nonisolated private static func shortcutExists(_ name: String) -> Bool {
        run("/usr/bin/shortcuts", ["list"])?.split(separator: "\n").contains { $0 == name } ?? false
    }

    /// Builds and signs the toggle shortcut into Application Support.
    nonisolated private static func makeShortcut(named name: String) -> URL? {
        let workflow: [String: Any] = [
            "WFWorkflowClientVersion": "2605.0.5",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowIcon": ["WFWorkflowIconGlyphNumber": 59511, "WFWorkflowIconStartColor": 4282601983],
            "WFWorkflowImportQuestions": [],
            "WFWorkflowInputContentItemClasses": [],
            "WFWorkflowTypes": [],
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                "WFWorkflowActionParameters": [
                    "Operation": "Toggle",
                    "FocusModes": ["Identifier": "com.apple.donotdisturb.mode.default", "DisplayString": "Do Not Disturb"],
                ],
            ]],
        ]
        let dir = URL.applicationSupportDirectory.appending(path: "NotchDeck", directoryHint: .isDirectory)
        let unsigned = FileManager.default.temporaryDirectory.appending(path: "notchdeck-focus.shortcut")
        let signed = dir.appending(path: "\(name).shortcut")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0),
              (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: unsigned)) != nil else { return nil }
        try? FileManager.default.removeItem(at: signed)
        _ = run("/usr/bin/shortcuts", ["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path])
        return FileManager.default.fileExists(atPath: signed.path) ? signed : nil
    }

    /// Runs a tool; stdout on success, nil on failure.
    nonisolated private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // `shortcuts run` can occasionally hang; give up after 10 s.
        let process = p
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
