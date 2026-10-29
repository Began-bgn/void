import AppKit
import SwiftUI

/// AppKit overlay for shelf cells: click / double-click / context menu, and multi-item drag-out
/// (SwiftUI's `onDrag` can only carry one item).
struct DragSource: NSViewRepresentable {
    var onClick: (_ extend: Bool, _ clickCount: Int) -> Void
    var dragItems: () -> [(writer: NSPasteboardWriting, image: NSImage)]
    /// Right-click location in the view (top-left origin).
    var onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.onClick = onClick
        view.dragItems = dragItems
        view.onRightClick = onRightClick
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var onClick: ((Bool, Int) -> Void)?
    var dragItems: (() -> [(writer: NSPasteboardWriting, image: NSImage)])?
    var onRightClick: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Shelf selection drives Space (Quick Look) and Delete, which need key focus.
    override var needsPanelToBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let items = dragItems?(), !items.isEmpty else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        mouseDownEvent = nil
        let origin = convert(down.locationInWindow, from: nil)
        let dragging = items.enumerated().map { i, item in
            let d = NSDraggingItem(pasteboardWriter: item.writer)
            let offset = CGFloat(i) * 6
            d.setDraggingFrame(NSRect(x: origin.x - 20 + offset, y: origin.y - 20 - offset, width: 40, height: 40),
                               contents: item.image)
            return d
        }
        beginDraggingSession(with: dragging, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onClick?(event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift), event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(convert(event.locationInWindow, from: nil)) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy, never move: dragging out of the shelf leaves the original where it was.
        context == .outsideApplication ? [.copy, .generic, .link] : []
    }
}
