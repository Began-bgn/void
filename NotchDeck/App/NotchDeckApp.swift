import SwiftUI
import AppKit
import KeyboardShortcuts

@main
struct NotchDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { SettingsView() }
            .commands {
                // ⌘Q in Settings closes the window only; quitting an agent app would kill the notch.
                // The status menu's Quit calls NSApplication.terminate directly, so it still quits.
                CommandGroup(replacing: .appTermination) {
                    Button("Quit Void") {
                        if let window = NSApp.keyWindow, Self.isSettingsWindow(window) {
                            window.performClose(nil)
                        } else {
                            NSApp.terminate(nil)
                        }
                    }
                    .keyboardShortcut("q")
                }
                // A Settings-only app gets no File > Close, so ⌘W would do nothing.
                CommandGroup(after: .newItem) {
                    Button("Close") { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("w")
                }
            }
    }

    /// SwiftUI tags the `Settings` scene's window with this identifier.
    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI wraps its delegate, so `NSApp.delegate` isn't this object.
    private(set) static weak var shared: AppDelegate?
    let notch = NotchManager()
    private(set) var statusItem: NSStatusItem?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host the app; privacy prompts (Calendar, Focus…) are attributed to the test
        // runner there and abort it, so stay inert.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if CommandLine.arguments.contains("--lockscreen-diagnostics") {
            print(LockScreenSupport.report())
            exit(0)
        }
        let settings = SettingsStore.shared
        let shelf = ShelfStore.shared
        shelf.persist = settings.shelfPersist
        shelf.copyFiles = settings.shelfCopyFiles
        shelf.autoClearHours = settings.shelfAutoClearHours
        shelf.load()
        _ = TimerModel.shared // re-arms a timer that was running at quit
        MusicStore.shared.start()
        WidgetBridge.shared.start()
        BatteryMonitor.shared.start()
        if settings.activityFocus { FocusMonitor.shared.start() }
        // First frame at the physical notch; slide out once start-up work is done.
        ActivityCenter.shared.reveal(hold: 0.6)
        notch.start()
        // The spike owns the lock screen alone so the player's windows can't skew its hover counts.
        if FaceUnlockSpike.isRequested { FaceUnlockSpike.shared.start() } else { LockScreenController.shared.start() }
        if settings.hudEnabled { HUDController.shared.start() }
        MenuTracker.shared.start()
        Updates.start()
        if CommandLine.arguments.contains("-FaceUnlockEnrol") { FaceEnrolmentView.open() }
        #if DEBUG
        if CommandLine.arguments.contains("-LiquidGlassGallery") { LiquidGlassGallery.open() }
        if CommandLine.arguments.contains("-FaceUnlockDemo") { FaceUnlockDemo.open() }
        // Screenshot hooks for the converted screens.
        if CommandLine.arguments.contains("-OpenSettings") {
            Task { try? await Task.sleep(for: .seconds(1.5)); SettingsOpener.open() }
        }
        if CommandLine.arguments.contains("-OpenNotch") {
            Task { try? await Task.sleep(for: .seconds(1.5)); notch.toggle() }
        }
        #endif

        KeyboardShortcuts.onKeyUp(for: .toggleNotch) { [weak self] in self?.notch.toggle() }
        KeyboardShortcuts.onKeyUp(for: .playPause) { MusicStore.shared.playPause() }
        KeyboardShortcuts.onKeyUp(for: .nextTrack) { MusicStore.shared.next() }
        KeyboardShortcuts.onKeyUp(for: .previousTrack) { MusicStore.shared.previous() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Void", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.isVisible = settings.showMenuBarIcon
        statusItem = item
    }

    /// Opening the app again (Finder, Spotlight) shows Settings: the way back with the icon hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsOpener.open()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        LockScreenController.shared.teardown()
        FaceUnlockSpike.shared.teardown()
        FaceUnlockCoordinator.shared.cancel() // stops the camera mid-scan
        NotesModel.shared.flush()
    }

    @objc private func toggleNotch() { notch.toggle() }
    @objc private func openSettings() { SettingsOpener.open() }

    /// Menu bar logo: black hole as a photon ring with a lens-shaped accretion disk across it,
    /// separated from the ring by a thin gap. Template, so it follows the menu bar's tint.
    private static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setFillColor(NSColor.black.cgColor)
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.setLineWidth(1.3) // ring
            cg.strokeEllipse(in: CGRect(x: 4.6, y: 4.6, width: 8.8, height: 8.8))
            cg.setBlendMode(.clear) // gap around the disk
            cg.fillEllipse(in: CGRect(x: 0, y: 7.6, width: 18, height: 2.8))
            cg.setBlendMode(.normal) // disk: thick middle, sharp ends
            cg.fillEllipse(in: CGRect(x: 0, y: 8.2, width: 18, height: 1.6))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Void"
        return image
    }()
}
