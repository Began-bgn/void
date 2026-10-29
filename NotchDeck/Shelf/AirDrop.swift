import AppKit
import Quartz

/// Sends items via AirDrop. The share sheet needs the app active, so focus is handed back to the
/// previously frontmost app when sharing ends.
@MainActor
final class AirDrop: NSObject, NSSharingServiceDelegate {
    static let shared = AirDrop()
    private var previousApp: NSRunningApplication?

    @discardableResult
    func send(_ items: [Any]) -> Bool {
        guard !items.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: items) else {
            NSSound.beep()
            return false
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        service.delegate = self
        NSApp.activate()
        service.perform(withItems: items)
        return true
    }

    /// Loads dropped providers and sends them.
    func send(providers: [NSItemProvider]) {
        DropPayload.load(providers) { payloads in
            self.send(payloads.compactMap { p -> Any? in
                switch p {
                case .url(let url): url as NSURL
                case .text(let text): text as NSString
                case .image(let data): NSImage(data: data)
                }
            })
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { restoreFocus() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) { restoreFocus() }

    private func restoreFocus() {
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        previousApp = nil
    }
}

/// Quick Look data source for the shelf.
@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = ShelfQuickLook()
    /// Only touched on the main thread; Quick Look calls the data source there.
    nonisolated(unsafe) private var urls: [URL] = []

    func toggle(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        guard !urls.isEmpty else { return }
        self.urls = urls
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    static var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
