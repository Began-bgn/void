import AppKit

/// Pure lock/unlock state machine, fed by `LockStateMonitor`.
struct LockState: Equatable {
    var locked = false
    /// False while another user is switched in (fast user switching).
    var sessionActive = true

    enum Event: Equatable {
        case locked, unlocked
        case sessionResigned
        /// Session back, or the Mac woke; `locked` is the window server's current answer.
        case resynced(locked: Bool)
    }

    mutating func apply(_ event: Event) {
        switch event {
        case .locked: locked = true
        case .unlocked: locked = false
        case .sessionResigned: sessionActive = false
        case .resynced(let l): locked = l; sessionActive = true
        }
    }

    /// This user's lock screen is up.
    var onLockScreen: Bool { locked && sessionActive }

    /// Show the card only on our lock screen, with a track loaded (paused tracks if allowed).
    func showsPlayer(enabled: Bool, track: MusicSnapshot?, showWhenPaused: Bool) -> Bool {
        guard enabled, onLockScreen, let track else { return false }
        return track.state == .playing || showWhenPaused
    }
}

/// Observes screen lock, session switching and sleep/wake. No event taps, no keyboard access.
@MainActor
final class LockStateMonitor {
    private(set) var state = LockState()
    var onChange: ((_ old: LockState, _ new: LockState) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Window-server answer, public CoreGraphics.
    nonisolated static var screenIsLocked: Bool {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        return dict?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func start() {
        guard observers.isEmpty else { return }
        state.locked = Self.screenIsLocked
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, "com.apple.screenIsLocked") { .locked }
        observe(dnc, "com.apple.screenIsUnlocked") { .unlocked }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.sessionDidResignActiveNotification.rawValue) { .sessionResigned }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            observe(ws, name.rawValue) { .resynced(locked: Self.screenIsLocked) }
        }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    /// Re-reads the window server; the watchdog calls this while the card is up.
    func resync() { send(.resynced(locked: Self.screenIsLocked)) }

    /// Repeats of the current state (lock + sleep/wake resyncs) are dropped here.
    func send(_ event: LockState.Event) {
        let old = state
        state.apply(event)
        if state != old { onChange?(old, state) }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ event: @escaping @MainActor () -> LockState.Event) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(event()) }
        }
        observers.append((center, token))
    }
}
