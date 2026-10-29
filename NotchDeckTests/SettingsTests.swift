import AppKit
import SwiftUI
import Testing
@testable import NotchDeck

@MainActor @Suite struct SettingsTests {
    /// Smoke test: every pane lays out. Permissions is skipped: its live checks would raise
    /// privacy prompts attributed to the test runner.
    @Test func everyPaneRenders() {
        for pane in SettingsPane.allCases where pane != .permissions {
            let host = NSHostingView(rootView: SettingsView(pane: pane))
            host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width >= 700, "\(pane)")
        }
    }

    @Test func fixedTintOnlyWhenArtworkTintOff() {
        let s = SettingsStore.shared
        let saved = (s.tintFromArtwork, s.fixedTint)
        defer { s.tintFromArtwork = saved.0; s.fixedTint = saved.1 }
        s.fixedTint = .red
        s.tintFromArtwork = true
        #expect(s.tint(.blue) == .blue)
        s.tintFromArtwork = false
        #expect(s.tint(.blue) == .red)
    }
}

@MainActor @Suite struct QuitCommandTests {
    @Test func onlySettingsWindowIsClosedInsteadOfQuitting() {
        let w = NSWindow()
        #expect(!NotchDeckApp.isSettingsWindow(w))
        w.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        #expect(NotchDeckApp.isSettingsWindow(w))
    }

    /// ⌘W must close Settings: some menu item carries it.
    @Test func mainMenuHasCloseShortcut() {
        func items(_ m: NSMenu?) -> [NSMenuItem] { (m?.items ?? []).flatMap { [$0] + items($0.submenu) } }
        let all = items(NSApp.mainMenu)
        #expect(all.contains { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command })
        #expect(all.contains { $0.keyEquivalent == "q" && $0.title == "Quit NotchDeck" })
    }
}
