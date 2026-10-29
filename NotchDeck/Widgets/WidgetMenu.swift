import SwiftUI
import AppKit

/// Catches right-clicks over a SwiftUI area (left clicks and everything else pass through) and
/// reports the location in the view's own top-left coordinates.
struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.onRightClick = onRightClick }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let type = NSApp.currentEvent?.type
            guard type == .rightMouseDown || type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(convert(event.locationInWindow, from: nil))
        }
    }
}

/// In-notch replacement for the system context menu: clipped to the notch, dismissed with it,
/// and the highlight glides between rows instead of jumping.
struct WidgetMenu: View {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        var destructive = false
        let action: () -> Void
    }

    let items: [Item]
    let dismiss: () -> Void

    /// Row under the cursor.
    @State private var hovered: Int?

    private static let rowHeight: CGFloat = 22
    static let width: CGFloat = 132
    static func height(rows: Int) -> CGFloat { CGFloat(rows) * rowHeight + 8 }

    /// An AppKit tracking area over the whole menu picks the row: SwiftUI's hover sometimes stops
    /// updating in the (non-key) notch panel, and per-row hover only fired over the text.
    /// Each row fades its own highlight; rapid changes retarget the fade instead of restarting it.
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button {
                    item.action()
                    dismiss()
                } label: {
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundStyle(hovered == i ? .white : (item.destructive ? .red : .white.opacity(0.9)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: Self.rowHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(item.destructive ? Color(nsColor: .systemRed) : Color.accentColor)
                                .opacity(hovered == i ? 1 : 0)
                        )
                        .animation(.smooth(duration: 0.16), value: hovered == i)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(HoverTracker { p in
            // Padding counts as the nearest row, so row edges never drop the highlight.
            hovered = p.map { min(max(Int((($0.y - 4) / Self.rowHeight).rounded(.down)), 0), items.count - 1) }
        })
        .frame(width: Self.width)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
    }
}

/// Reports the cursor position (top-left origin) over its frame, or nil when it leaves. Works in
/// inactive apps and never takes clicks.
private struct HoverTracker: NSViewRepresentable {
    var onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }
    func updateNSView(_ view: TrackerView, context: Context) { view.onMove = onMove }

    final class TrackerView: NSView {
        var onMove: ((CGPoint?) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
        override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onMove?(nil) }
    }
}

/// Closes any open AppKit menu (SwiftUI `Menu`s) when the notch collapses.
@MainActor
final class MenuTracker {
    static let shared = MenuTracker()
    private var open: [NSMenu] = []

    private init() {
        let nc = NotificationCenter.default
        // Delivered on the main queue, so handing the menu to the main actor is safe.
        _ = nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { n in
            nonisolated(unsafe) let menu = n.object as? NSMenu
            MainActor.assumeIsolated { if let menu { MenuTracker.shared.open.append(menu) } }
        }
        _ = nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { n in
            let id = n.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated { MenuTracker.shared.open.removeAll { ObjectIdentifier($0) == id } }
        }
    }

    func start() {}

    func cancelAll() {
        open.forEach { $0.cancelTracking() }
        open.removeAll()
    }
}
