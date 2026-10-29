import AppKit
import SwiftUI
import Observation
import OSLog

/// macOS versions the lock screen player was checked on. Others count as experimental and the
/// feature defaults to off there.
enum LockScreenSupport {
    /// Major versions manually QA'd (README → Manual QA). 27 = development machine.
    static let testedMajorVersions: Set<Int> = [27]
    static var osMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    static var isTestedOS: Bool { testedMajorVersions.contains(osMajor) }

    /// `NotchDeck --lockscreen-diagnostics`: prints and exits, touches no window.
    static func report() -> String {
        let missing = SkyLightAPI.missingSymbols()
        return """
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString) — \(isTestedOS ? "tested" : "untested (experimental)")
        SkyLight symbols: \(missing.isEmpty ? "all \(SkyLightAPI.symbolNames.count) resolved" : "missing \(missing.joined(separator: ", "))")
        Screen locked now: \(LockStateMonitor.screenIsLocked)
        Input on the lock screen: turn on Settings → Lock Screen → Diagnostics → Show test window, lock, click it, unlock and read the count.
        """
    }
}

/// Glue between lock state, the now-playing store and the presenter. Fails safe: any presenter
/// error swaps in `NullLockScreenPresenter` for the rest of the session.
@MainActor @Observable
final class LockScreenController {
    static let shared = LockScreenController()

    /// The card's appear/disappear animation follows this.
    private(set) var cardShown = false
    /// Bumped per lock so the padlock replays its animation.
    private(set) var lockCount = 0
    private(set) var missingSymbols: [String] = []
    private(set) var lastError: String?
    private(set) var presenterSupported = false

    /// Diagnostics spike: shows a plain test window on the next lock and counts clicks on it.
    var spikeArmed = false { didSet { refresh() } }
    private(set) var clicksThisLock = 0
    /// Clicks seen during the last lock that showed a window; nil until one happened.
    private(set) var clicksLastLock: Int?

    @ObservationIgnored private var presenter: any LockScreenPresenter = NullLockScreenPresenter()
    @ObservationIgnored private let monitor = LockStateMonitor()
    @ObservationIgnored private let music = MusicStore.shared
    @ObservationIgnored private let settings = SettingsStore.shared
    @ObservationIgnored private let log = Logger(subsystem: "com.notchdeck.app", category: "LockScreen")
    @ObservationIgnored private var cardWindow: NSPanel?
    @ObservationIgnored private var padlockWindow: NSPanel?
    @ObservationIgnored private var scanWindow: NSPanel?
    @ObservationIgnored private var hudWindow: NSPanel?
    @ObservationIgnored private let faceUnlock = FaceUnlockCoordinator.shared
    @ObservationIgnored private var escMonitor: Any?
    @ObservationIgnored private var showing = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var clickMonitor: Any?

    private init() {}

    func start() {
        missingSymbols = SkyLightAPI.missingSymbols()
        if let skylight = SkyLightLockScreenPresenter() {
            presenter = skylight
        } else {
            lastError = "Missing SkyLight symbols: \(missingSymbols.joined(separator: ", "))"
            log.error("\(self.lastError ?? "", privacy: .public)")
        }
        presenterSupported = presenter.isSupported
        faceUnlock.useCamera = true
        faceUnlock.send(.enabled(faceUnlockOn))
        monitor.onChange = { [weak self] old, new in self?.lockChanged(from: old, to: new) }
        monitor.start()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // Counts mouse-downs on our own lock-screen windows only (the input spike). Never keys.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated {
                guard let self, let window, window === self.cardWindow || window === self.padlockWindow else { return }
                self.clicksThisLock += 1
            }
            return event
        }
        // "Scan on wake" trigger.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.faceUnlockTrigger == .wake else { return }
                Task { try? await Task.sleep(for: .seconds(0.6)); self.faceUnlock.trigger() }
            }
        })
        // Sleep or lid close cancels a scan (and so stops the camera).
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.faceUnlock.cancel() }
        })
        // Esc cancels a scan, if the lock screen lets the key reach us at all (logged to find out).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.keyCode == 53 else { return }
                self.log.notice("Esc received, locked=\(self.monitor.state.onLockScreen)")
                if self.faceUnlock.state.isScanning { self.faceUnlock.cancel() }
            }
            return event
        }
        trackChanges()
    }

    /// Face Unlock is opted in and the presenter works. Without the presenter there is no notch
    /// UI on the lock screen, so no way to trigger or see a scan: off.
    private var faceUnlockOn: Bool { FaceUnlockCoordinator.enabledSetting && presenter.isSupported }

    /// Kill switch: off now, windows gone.
    func kill() {
        settings.lockScreenEnabled = false
        spikeArmed = false
        teardown()
    }

    /// Always safe; called on unlock, on quit and by the watchdog.
    func teardown() {
        pending?.cancel(); pending = nil
        watchdog?.cancel(); watchdog = nil
        presenter.hide()
        // Fresh pill per lock: its slide starts on appear, i.e. only once `present` has moved it
        // into the lock-screen space. A reused one restarted on `lockCount` while still ordered
        // out, so it was already mid-slide (or showed last lock's full width) when it came up.
        padlockWindow?.close(); padlockWindow = nil
        // Release the card too: kept ordered out, its music bars still rendered every frame (~2% CPU).
        // close(), not just nil: AppKit keeps unclosed windows alive in its window list.
        cardWindow?.close(); cardWindow = nil
        if showing { clicksLastLock = clicksThisLock }
        showing = false
        cardShown = false
    }

    // MARK: State

    private func lockChanged(from old: LockState, to new: LockState) {
        log.notice("lock state \(String(describing: old)) -> \(String(describing: new))")
        // Only a real unlock resets Face Unlock's failure count; a user switch just cancels.
        if new.onLockScreen { faceUnlock.send(.locked) } else if !new.locked { faceUnlock.send(.unlocked) } else { faceUnlock.cancel() }
        if new.onLockScreen, !old.onLockScreen {
            HUDController.shared.ensureEnabled()
            lockCount += 1
            clicksThisLock = 0
            // No overlay: play the lock animation in the notch while the screen locks.
            let inNotch = settings.lockIndicator && !(settings.lockScreenEnabled && presenter.isSupported)
            ActivityCenter.shared.reveal(flash: inNotch ? .lock(locked: true) : nil)
        } else if !new.onLockScreen, old.onLockScreen {
            teardown()
            ActivityCenter.shared.reveal(flash: settings.lockIndicator ? .lock(locked: false) : nil)
        }
        refresh()
    }

    private func trackChanges() {
        withObservationTracking {
            _ = music.active?.state
            _ = music.active?.trackKey
            _ = settings.lockScreenEnabled; _ = settings.lockShowWhenPaused; _ = settings.lockIndicator
            _ = settings.lockOffsetY; _ = settings.lockScale; _ = settings.lockDisplayName
            _ = settings.faceUnlockEnabled; _ = settings.hudEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.trackChanges()
            }
        }
    }

    private func refresh() {
        // Settings toggle or kill switch: keep the coordinator in step.
        if faceUnlockOn != (faceUnlock.state.phase != .disabled) { faceUnlock.send(.enabled(faceUnlockOn)) }
        let state = monitor.state
        let enabled = settings.lockScreenEnabled && presenter.isSupported
        let card = state.showsPlayer(enabled: enabled, track: music.active, showWhenPaused: settings.lockShowWhenPaused)
            || (spikeArmed && enabled && state.onLockScreen)
        let padlock = (enabled && settings.lockIndicator || faceUnlockOn) && state.onLockScreen
        log.notice("refresh locked=\(state.onLockScreen) enabled=\(enabled) track=\(self.music.active != nil) card=\(card) padlock=\(padlock) showing=\(self.showing)")
        pending?.cancel()

        if !card && !padlock && !hudOn {
            guard showing else { return }
            cardShown = false
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.3)) // card fade-out
                if !Task.isCancelled { self?.teardown() }
            }
        } else if !card, cardShown {
            cardShown = false
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.3))
                if !Task.isCancelled { self?.present(card: false, padlock: padlock) }
            }
        } else if !showing {
            // Short delay so a quick lock/unlock never flashes anything.
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.35))
                guard !Task.isCancelled, self?.monitor.state.onLockScreen == true else { return }
                self?.present(card: card, padlock: padlock)
            }
        } else {
            present(card: card, padlock: padlock)
        }
    }

    private func present(card: Bool, padlock: Bool) {
        guard let main = NSScreen.screens.first else { return }
        var windows: [NSWindow] = []
        if padlock, faceUnlockOn {
            // The scan view draws the padlock too, and grows into the scanning pill.
            let w = scanWindow ?? makeWindow(NotchScanView(notchSize: main.notchSize))
            scanWindow = w
            w.setFrame(NotchScanView.windowFrame(on: main), display: true)
            windows.append(w)
        } else if padlock {
            let w = padlockWindow ?? makeWindow(PadlockPillView())
            padlockWindow = w
            w.setFrame(Self.padlockFrame(on: main), display: true)
            windows.append(w)
        }
        if hudOn {
            // Always there while locked, clear until a volume/brightness flash; above the padlock.
            hudModel.notchSize = main.notchSize
            let w = hudWindow ?? makeWindow(LockScreenHUDView(model: hudModel))
            w.ignoresMouseEvents = true
            hudWindow = w
            w.setFrame(LockScreenHUDView.windowFrame(on: main), display: true)
            windows.append(w)
        }
        if card {
            let w = cardWindow ?? makeWindow(LockScreenPlayerView())
            cardWindow = w
            w.setFrame(cardFrame(on: targetScreen ?? main), display: true)
            windows.append(w)
        }
        presenter.show(windows)
        log.notice("presented card=\(card) padlock=\(padlock) supported=\(self.presenter.isSupported)")
        guard presenter.isSupported else {
            lastError = presenter.lastError
            presenter = NullLockScreenPresenter(reason: lastError)
            presenterSupported = false
            faceUnlock.send(.enabled(false))
            teardown()
            return
        }
        showing = true
        startWatchdog()
        if card, !cardShown {
            // Next tick, so the window draws once hidden and the card animates in.
            Task { @MainActor [weak self] in self?.cardShown = true }
        }
    }

    /// Belt and braces against a missed unlock notification: poll the window server while shown.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if !LockStateMonitor.screenIsLocked {
                    self.teardown()
                    self.monitor.resync()
                    return
                }
            }
        }
    }

    // MARK: Windows

    /// Volume/brightness flashes in the lock-screen notch (the main notch window is under the lock screen).
    private var hudOn: Bool {
        settings.lockScreenEnabled && presenter.isSupported && settings.hudEnabled && monitor.state.onLockScreen
    }
    @ObservationIgnored private let hudModel = NotchModel()

    private var targetScreen: NSScreen? {
        let screens = NSScreen.screens
        return screens.first { !settings.lockDisplayName.isEmpty && $0.localizedName == settings.lockDisplayName } ?? screens.first
    }

    static let cardSize = CGSize(width: 350, height: 200)
    /// Room around the card for its shadow.
    static let shadowMargin: CGFloat = 40

    private func cardFrame(on screen: NSScreen) -> CGRect {
        let s = settings.lockScale
        let w = Self.cardSize.width * s + Self.shadowMargin * 2
        let h = Self.cardSize.height * s + Self.shadowMargin * 2
        // Lower middle: below the clock, above the user name and password field.
        let cy = screen.frame.minY + screen.frame.height * 0.36 + settings.lockOffsetY
        return CGRect(x: screen.frame.midX - w / 2, y: cy - h / 2, width: w, height: h).integral
    }

    private static func padlockFrame(on screen: NSScreen) -> CGRect {
        let n = screen.notchSize
        return screen.topCentered(CGSize(width: n.width + PadlockPillView.sideWidth * 2 + 4, height: n.height + 3))
    }

    private func makeWindow(_ view: some View) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.canBecomeVisibleWithoutLogin = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = FirstMouseHostingView(rootView: view)
        // Over the notch the window gets a top safe-area inset, which pushed the padlock pill
        // down off the screen edge. Draw edge to edge.
        host.safeAreaRegions = []
        panel.contentView = host
        return panel
    }
}

/// Buttons act on the first click: lock-screen windows never become key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
