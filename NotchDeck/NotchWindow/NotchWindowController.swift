import AppKit
import SwiftUI

/// One notch overlay on one display: owns the panel and the dwell/expand/collapse state machine.
@MainActor
final class NotchWindowController {
    private(set) var screen: NSScreen
    let model = NotchModel()

    private let panel = NotchPanel()
    private let settings = SettingsStore.shared
    private var dwellTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var scrollAccum: CGFloat = 0
    private var scrollFired = false
    private var lastScroll: TimeInterval = 0
    private var gestures = GestureRecognizer()
    private var longPressTask: Task<Void, Never>?
    private var pressStarted: TimeInterval?

    var isExpanded: Bool { model.isExpanded }

    /// Transparent margin around the expanded shape so its shadow isn't clipped.
    private let shadowPad: CGFloat = 24

    init(screen: NSScreen) {
        self.screen = screen
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        model.onDropTargetChanged = { [weak self] targeted in self?.dropTargetChanged(targeted) }
        update(screen: screen)
        panel.orderFrontRegardless()
    }

    func close() {
        dwellTask?.cancel(); closeTask?.cancel()
        panel.orderOut(nil)
    }

    /// Re-anchor after display hot-plug, wake, or resolution change.
    func update(screen: NSScreen) {
        self.screen = screen
        model.notchSize = screen.notchSize
        panel.setFrame(windowFrame, display: true)
    }

    // MARK: Geometry

    /// Fixed frame big enough for every state. The window never resizes while open/closing (resizing
    /// glitched in Mission Control); clicks outside the visible notch pass through instead.
    private var windowFrame: CGRect {
        let width = max(model.expandedSize.width, model.plainSize.width + NotchModel.maxSideWidth * 2, model.popupSize.width)
        let height = max(model.expandedSize.height + model.flashRowHeight, model.popupSize.height)
        return screen.topCentered(CGSize(width: width + shadowPad * 2, height: height + shadowPad))
    }

    /// Cursor region that starts the dwell. Inflated 1pt so the very top screen edge counts.
    private var hitRect: CGRect { screen.topCentered(model.dwellSize).insetBy(dx: -4, dy: -1) }
    /// Everything visible while collapsed (includes a pop-up).
    private var collapsedRect: CGRect { screen.topCentered(model.collapsedSize).insetBy(dx: -4, dy: -1) }
    /// Expanded body; leaving it starts the close grace delay.
    var bodyRect: CGRect { screen.topCentered(model.openSize).insetBy(dx: -6, dy: -6) }

    // MARK: Input

    func mouseMoved(to point: NSPoint) {
        updateMagnet(point)
        updatePassThrough(point)
        if !model.isExpanded, model.popupVisible, screen.frame.insetBy(dx: -1, dy: -1).contains(point) {
            ActivityCenter.shared.setHovering(collapsedRect.contains(point) && !hitRect.contains(point))
        }
        if model.isExpanded {
            if bodyRect.contains(point) { closeTask?.cancel(); closeTask = nil } else { scheduleClose() }
        } else if settings.openOnHover, hitRect.contains(point), !isSuppressed {
            startDwell()
        } else {
            cancelDwell()
        }
    }

    /// The panel takes mouse events only over the visible notch. Also runs during drags, so files
    /// dragged onto the collapsed notch reach its drop target.
    private func updatePassThrough(_ point: NSPoint = NSEvent.mouseLocation) {
        let m = model.magnet, c = collapsedRect
        let grown = c.insetBy(dx: -(c.width * (m.scaleX - 1) / 2 + abs(m.offsetX)), dy: -c.height * (m.scaleY - 1))
        let interactive = model.isExpanded ? bodyRect.contains(point) : grown.contains(point)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }

    /// Closed notch leans toward a nearby cursor; never while open, dragging, or with Reduce Motion.
    private func updateMagnet(_ point: NSPoint) {
        let off = model.isExpanded || isSuppressed || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = off ? .identity : NotchMagnet.at(point, notch: screen.topCentered(model.collapsedSize))
        guard target != model.magnet else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { model.magnet = target }
    }

    /// No dwell during any mouse-button drag, or while the menu bar is hidden by a full-screen app.
    private var isSuppressed: Bool {
        NSEvent.pressedMouseButtons != 0 || (settings.suppressInFullScreen && screen.menuBarHidden)
    }

    // MARK: State

    private func startDwell() {
        guard dwellTask == nil else { return }
        model.dwellDuration = settings.hoverDelay
        model.isDwelling = true
        dwellTask = Task { [weak self, delay = settings.hoverDelay] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.expand()
        }
    }

    private func cancelDwell() {
        guard dwellTask != nil || model.isDwelling else { return }
        dwellTask?.cancel(); dwellTask = nil
        model.isDwelling = false
    }

    func expand() {
        cancelDwell()
        guard !model.isExpanded else { return }
        ShelfStore.shared.pruneExpired()
        model.isExpanded = true
        model.magnet = .identity
        updatePassThrough()
        if settings.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    func collapse() {
        closeTask?.cancel(); closeTask = nil
        guard model.isExpanded else { return }
        model.isExpanded = false
        MenuTracker.shared.cancelAll()
        returnKeyFocus()
        updatePassThrough()
    }

    /// Keyboard open: take key focus so Esc and arrow keys work.
    func toggle() {
        if isExpanded { collapse() } else { expand(); panel.makeKey() }
    }

    /// Hover-open never takes key focus, but a click inside the panel does. Ordering the key panel
    /// out and back hands keyboard focus back to the app the user was typing in.
    /// Runs after the close animation so the reorder can't interrupt it.
    private func returnKeyFocus() {
        guard panel.isKeyWindow else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !self.model.isExpanded, self.panel.isKeyWindow else { return }
            self.panel.orderOut(nil)
            self.panel.orderFrontRegardless()
        }
    }

    private func scheduleClose() {
        guard closeTask == nil, !ShelfQuickLook.isVisible else { return }
        closeTask = Task { [weak self, delay = settings.closeDelay] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    // MARK: Paging, keys, drops

    private func turnPage(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.22)) { model.step(delta) }
    }

    /// Two-finger horizontal swipe over the expanded notch turns the page once per gesture; over the
    /// collapsed notch it skips tracks (and vertical swipes change volume, if enabled).
    /// Returns true when the event was consumed.
    func handleScroll(dx: CGFloat, dy: CGFloat, began: Bool, momentum: Bool, inverted: Bool, at point: NSPoint) -> Bool {
        if !model.isExpanded { return collapsedSwipe(dx: dx, dy: dy, began: began, momentum: momentum, inverted: inverted, at: point) }
        guard bodyRect.contains(point), !momentum, !overSidewaysScroller(point) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if began || now - lastScroll > 0.3 { scrollAccum = 0; scrollFired = false }
        lastScroll = now
        guard abs(dx) > abs(dy) else { return false }
        scrollAccum += dx
        if !scrollFired, abs(scrollAccum) > 40 {
            scrollFired = true
            turnPage(scrollAccum < 0 ? 1 : -1)
        }
        return true
    }

    /// True when the cursor is over a horizontally scrollable view (calendar days, shelf row): the
    /// swipe scrolls it instead of turning the page, and never scrolls the page up or down.
    func overSidewaysScroller(_ screenPoint: NSPoint) -> Bool {
        guard model.isExpanded, bodyRect.contains(screenPoint) else { return false }
        // hitTest takes the point in the superview's (window) coordinates, not the flipped hosting view's.
        var view = panel.contentView?.hitTest(panel.convertPoint(fromScreen: screenPoint))
        while let v = view {
            if let sv = v as? NSScrollView, let doc = sv.documentView,
               doc.frame.width > sv.contentView.bounds.width + 1 { return true }
            view = v.superview
        }
        return false
    }

    private func collapsedSwipe(dx: CGFloat, dy: CGFloat, began: Bool, momentum: Bool, inverted: Bool, at point: NSPoint) -> Bool {
        guard collapsedRect.contains(point), settings.gestureSwipe || settings.gestureVolume else { return false }
        guard !momentum else { return true }
        gestures.threshold = 60 / settings.gestureSensitivity
        gestures.invert = settings.gestureInvert
        gestures.swipeEnabled = settings.gestureSwipe
        gestures.verticalVolume = settings.gestureVolume
        // Natural scrolling reports content motion; convert to finger motion (+x right, +y up).
        let fx = inverted ? dx : -dx, fy = inverted ? -dy : dy
        switch gestures.feed(dx: fx, dy: fy, began: began, at: ProcessInfo.processInfo.systemUptime) {
        case .next?: skip(forward: true)
        case .previous?: skip(forward: false)
        case .volume(let delta)?: HUDController.shared.changeVolume(by: delta)
        case nil: break
        }
        return true
    }

    private func skip(forward: Bool) {
        let music = MusicStore.shared
        guard music.active != nil else { return }
        cancelDwell() // a swipe shouldn't also open the notch
        forward ? music.next() : music.previous()
        if settings.hapticsEnabled { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduce else { return }
        withAnimation(.easeOut(duration: 0.1)) { model.nudge = forward ? 7 : -7 }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { self?.model.nudge = 0 }
        }
    }

    /// Collapsed notch: click = play/pause, long-press = open now (each optional).
    func handleMouse(down: Bool, at point: NSPoint) {
        if down {
            guard !model.isExpanded, hitRect.contains(point) else { pressStarted = nil; return }
            pressStarted = ProcessInfo.processInfo.systemUptime
            guard settings.gestureLongPress else { return }
            longPressTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                self.pressStarted = nil
                self.expand()
            }
        } else {
            longPressTask?.cancel(); longPressTask = nil
            guard let start = pressStarted else { return }
            pressStarted = nil
            guard !model.isExpanded, hitRect.contains(point), ProcessInfo.processInfo.systemUptime - start < 0.45 else { return }
            // Without hover-open, a click opens the notch (it beats the play/pause gesture).
            if !settings.openOnHover {
                expand()
            } else if settings.gestureClick, MusicStore.shared.active != nil {
                cancelDwell()
                MusicStore.shared.playPause()
                // playPause() applies the optimistic state at once and holds it until the app agrees.
                PlayPauseFeedback.shared.show(playing: MusicStore.shared.active?.state == .playing)
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let shelf = ShelfStore.shared
        switch event.keyCode {
        case 53: collapse()                                   // Esc
        case 123: turnPage(-1)                                // ←
        case 124: turnPage(1)                                 // →
        case 49 where model.page == .shelf:                   // Space: Quick Look
            ShelfQuickLook.shared.toggle(shelf.selectedOrAll.compactMap(\.fileURL))
        case 51 where model.page == .shelf, 117 where model.page == .shelf: // Delete
            shelf.remove(shelf.selection)
        default: return false
        }
        return true
    }

    /// Dragging content onto the notch opens it on the shelf, no dwell.
    private func dropTargetChanged(_ targeted: Bool) {
        model.isDropTargeted = targeted
        if targeted {
            closeTask?.cancel(); closeTask = nil
            withAnimation(.easeInOut(duration: 0.22)) { model.show(.shelf) }
            expand()
        } else if model.isExpanded, !bodyRect.contains(NSEvent.mouseLocation) {
            scheduleClose()
        }
    }
}

/// Scale and offset that pull the closed notch toward the cursor. Pure, so it is unit-tested.
struct NotchMagnet: Equatable {
    var scaleX: CGFloat = 1, scaleY: CGFloat = 1, offsetX: CGFloat = 0
    static let identity = NotchMagnet()
    static let zone: CGFloat = 40, maxScaleX: CGFloat = 1.06, maxScaleY: CGFloat = 1.10, maxOffset: CGFloat = 3

    /// Identity outside `zone` pt of `notch`; grows to full strength as the cursor reaches it.
    static func at(_ p: CGPoint, notch: CGRect) -> NotchMagnet {
        let dx = max(notch.minX - p.x, 0, p.x - notch.maxX), dy = max(notch.minY - p.y, 0, p.y - notch.maxY)
        let t = 1 - min(hypot(dx, dy) / zone, 1)
        guard t > 0, notch.width > 0 else { return .identity }
        let side = min(max((p.x - notch.midX) / (notch.width / 2), -1), 1)
        return NotchMagnet(scaleX: 1 + (maxScaleX - 1) * t, scaleY: 1 + (maxScaleY - 1) * t, offsetX: maxOffset * side * t)
    }
}
