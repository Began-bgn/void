import SwiftUI
import Observation

/// A short pop-up under the notch (battery, timer done, …).
struct ActivityPopup: Identifiable, Equatable {
    let id = UUID()
    /// A newer pop-up with the same key replaces the queued/visible one.
    var key: String
    var priority: Int
    var symbol: String
    var color: Color = .white
    var title: String
    var subtitle: String?
    var trailing: String?
    var trailingColor: Color = .white
    var pulse = false

    enum Priority {
        static let lowBattery = 90, timer = 80, power = 50, charged = 40, focus = 20
    }
}

/// Short iPhone-style event that widens the notch sideways (notch height) for ~2 s.
enum ActivityFlash: Equatable {
    /// Charging, on battery, low, fully charged.
    case battery(percent: Int, title: String, color: Color, glyph: String?)
    /// Volume / brightness / keyboard backlight level (0…1), replacing the system HUD.
    case hud(kind: HUDKind, level: Double)
    case focus(on: Bool)
    /// Screen locked / unlocked padlock.
    case lock(locked: Bool)

    var key: String {
        switch self {
        case .battery: "battery"
        case .hud: "hud"
        case .focus: "focus"
        case .lock: "lock"
        }
    }
}

/// Ongoing activity shown in the collapsed notch's side areas.
enum LiveActivity: Equatable {
    case timer
}

/// Priority queue of pop-ups (one visible at a time, auto-dismissed, hover pauses) and the
/// current live activity.
@MainActor @Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    private(set) var popup: ActivityPopup?
    private(set) var flash: ActivityFlash?
    /// Changes per new flash so its entry animation restarts.
    private(set) var flashID = UUID()
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    /// True for a moment while the notch snaps back to the physical notch, so it can slide out again.
    private(set) var revealing = false
    /// Side content stays hidden while the notch slides out, then fades in as it settles.
    private(set) var revealHidesContent = false
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    /// End of the slide in flight; reveals asked for before then are absorbed.
    @ObservationIgnored private var revealEnds = Date.distantPast

    @ObservationIgnored private var queue: [ActivityPopup] = []
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private let settings = SettingsStore.shared

    private init() {}

    /// Ongoing activity: a running timer.
    var live: LiveActivity? {
        settings.activityTimer && TimerModel.shared.state.isRunning ? .timer : nil
    }

    /// Shows a flash for 2 s. Posting the same key again updates it in place and keeps it up a
    /// little longer. Volume/brightness hides after 1.5 s without a key press.
    func show(_ f: ActivityFlash) {
        let update = flash?.key == f.key
        flash = f
        if !update { flashID = UUID() }
        flashTask?.cancel()
        let hold = update || f.key == "hud" ? 1.5 : 2
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    /// Launch, lock, unlock: the notch jumps to the physical notch size, then slides out to its
    /// current width. `hold` waits out the busy moment (app start-up, screen wake) first, so the
    /// slide doesn't drop frames. `flash` changes the width in the same no-animation transaction
    /// as the snap, so the reveal is the only animation that moves the edge.
    /// Returns false when a slide already in flight absorbed this one (a repeated lock event, or a
    /// lock and unlock within one slide): restarting it snapped the notch back mid-slide.
    @discardableResult
    func reveal(hold: Double = 0.25, flash f: ActivityFlash? = nil) -> Bool {
        guard Date.now >= revealEnds else {
            if let f { show(f) }
            return false
        }
        revealEnds = .now + hold + Self.revealDuration
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            revealing = true; revealHidesContent = true
            if let f { show(f) }
        }
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.revealing = false
            // Content fades in over the last part of the slide, so it lands with the edge.
            try? await Task.sleep(for: .seconds(Self.revealDuration * 0.65))
            guard !Task.isCancelled, let self else { return }
            self.revealHidesContent = false
            // A flash posted with the reveal (unlock padlock) gets its full time once visible.
            if let f = self.flash { self.show(f) }
        }
        return true
    }

    static let revealDuration = 0.7
    /// Critically damped spring: gentle start, no jump on the first frame, no overshoot.
    static func revealAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: revealDuration, bounce: 0)
    }

    func post(_ p: ActivityPopup) {
        if popup?.key == p.key {
            popup = p
            restartTimer()
            return
        }
        queue = Self.enqueue(p, into: queue)
        if popup == nil { showNext() }
    }

    /// Replaces any queued pop-up with the same key; higher priority first, FIFO within a priority.
    nonisolated static func enqueue(_ p: ActivityPopup, into queue: [ActivityPopup]) -> [ActivityPopup] {
        var q = queue.filter { $0.key != p.key }
        let index = q.firstIndex { $0.priority < p.priority } ?? q.endIndex
        q.insert(p, at: index)
        return q
    }

    func dismiss() {
        dismissTask?.cancel(); dismissTask = nil
        guard popup != nil else { return }
        popup = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350)) // let the notch retract before the next one
            self?.showNext()
        }
    }

    func setHovering(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside { dismissTask?.cancel(); dismissTask = nil } else { restartTimer(after: 1.5) }
    }

    func tap() {
        dismiss()
    }

    private func showNext() {
        guard popup == nil, !queue.isEmpty else { return }
        popup = queue.removeFirst()
        restartTimer()
    }

    private func restartTimer(after delay: Double? = nil) {
        dismissTask?.cancel(); dismissTask = nil
        guard popup != nil, !hovering else { return }
        dismissTask = Task { [weak self, duration = delay ?? settings.popupDuration] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}
