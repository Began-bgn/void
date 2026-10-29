import AppKit
import Quartz

final class NotchPanel: NSPanel {
    /// Returns true when handled.
    var onKeyDown: (@MainActor (NSEvent) -> Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar (24) and the system's notification banners (21), so those appear under
        // the notch, but just below the drag-image level (500): windows at or above it never
        // receive drops. (Hence no AppKit pop-up menus inside the notch: they'd sit below it.)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        // Only text views take key focus; buttons work without it. Avoids the focus hand-back
        // (which reorders the window) after ordinary clicks.
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = ShelfQuickLook.shared }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }
}
