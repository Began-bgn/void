import AppKit

/// Owns one controller per target display and feeds them the (throttled) global cursor stream.
@MainActor
final class NotchManager {
    private let settings = SettingsStore.shared
    private var controllers: [CGDirectDisplayID: NotchWindowController] = [:]
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var lastTick: TimeInterval = 0
    private var trailing: Task<Void, Never>?
    private let minInterval: TimeInterval = 1.0 / 30

    func start() {
        syncScreens()

        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }) { monitors.append(m) }
        // Global monitors miss events delivered to our own panel.
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.cursorMoved() }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let began = event.phase.contains(.began), momentum = !event.momentumPhase.isEmpty
            let inverted = event.isDirectionInvertedFromDevice
            let (consumed, sideways) = MainActor.assumeIsolated {
                (self?.scrolled(dx: dx, dy: dy, began: began, momentum: momentum, inverted: inverted) ?? false,
                 self?.overSidewaysScroller() ?? false)
            }
            if consumed { return nil }
            return sideways ? Self.horizontalOnly(event) : event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedSomewhere() }
        }) { monitors.append(m) }
        // Clicks on the collapsed notch land in our panel.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self] event in
            let down = event.type == .leftMouseDown
            MainActor.assumeIsolated {
                let p = NSEvent.mouseLocation
                self?.controllers.values.forEach { $0.handleMouse(down: down, at: p) }
            }
            return event
        }) { monitors.append(m) }
        // Esc closes a hover-opened notch without clicking it first (needs Accessibility).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.controllers.values.filter(\.isExpanded).forEach { $0.collapse() } }
        }) { monitors.append(m) }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncScreens() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncScreens() }
        })
    }

    func toggle() {
        let p = NSEvent.mouseLocation
        let target = controllers.values.first { $0.screen.frame.insetBy(dx: -1, dy: -1).contains(p) } ?? controllers.values.first
        target?.toggle()
    }

    // MARK: Cursor stream

    /// Leading + trailing throttle: the last event of a burst is never dropped.
    private func cursorMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTick < minInterval {
            guard trailing == nil else { return }
            trailing = Task { [weak self, interval = minInterval] in
                try? await Task.sleep(for: .seconds(interval))
                self?.trailing = nil
                self?.process()
            }
            return
        }
        lastTick = now
        process()
    }

    private func process() {
        let p = NSEvent.mouseLocation
        if settings.displayMode == .cursorDisplay,
           let id = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) })?.displayID,
           controllers[id] == nil, !controllers.values.contains(where: \.isExpanded) {
            syncScreens()
        }
        for c in controllers.values { c.mouseMoved(to: p) }
    }

    private func scrolled(dx: CGFloat, dy: CGFloat, began: Bool, momentum: Bool, inverted: Bool) -> Bool {
        let p = NSEvent.mouseLocation
        return controllers.values.contains {
            $0.handleScroll(dx: dx, dy: dy, began: began, momentum: momentum, inverted: inverted, at: p)
        }
    }

    private func overSidewaysScroller() -> Bool {
        let p = NSEvent.mouseLocation
        return controllers.values.contains { $0.overSidewaysScroller(p) }
    }

    /// The scroll with its vertical part removed, so a sideways strip never moves the page under it.
    nonisolated private static func horizontalOnly(_ event: NSEvent) -> NSEvent {
        guard let cg = event.cgEvent?.copy() else { return event }
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return NSEvent(cgEvent: cg) ?? event
    }

    private func clickedSomewhere() {
        let p = NSEvent.mouseLocation
        for c in controllers.values where c.isExpanded && !c.bodyRect.contains(p) { c.collapse() }
    }

    // MARK: Displays

    func syncScreens() {
        let screens = NSScreen.screens
        let targets: [NSScreen]
        switch settings.displayMode {
        case .allDisplays:
            targets = screens
        case .cursorDisplay:
            let p = NSEvent.mouseLocation
            let s = screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(p) } ?? NSScreen.main ?? screens.first
            targets = s.map { [$0] } ?? []
        }
        let wanted = Dictionary(targets.compactMap { s in s.displayID.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })

        for (id, c) in controllers where wanted[id] == nil {
            c.close()
            controllers[id] = nil
        }
        for (id, screen) in wanted {
            if let c = controllers[id] { c.update(screen: screen) }
            else { controllers[id] = NotchWindowController(screen: screen) }
        }
    }
}
