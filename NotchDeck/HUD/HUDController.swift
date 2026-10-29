import AppKit
import ApplicationServices
import OSLog

enum HUDKind: Equatable, Sendable {
    case volume(muted: Bool)
    case brightness
    case keyboard
}

/// Replaces the system volume/brightness HUD: a CGEventTap swallows the media keys, applies the
/// change itself, and shows a notch flash. Keys it can't handle (no Accessibility, unsupported
/// device or display) pass through to macOS, which then shows its native HUD.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionPoll: Task<Void, Never>?
    private let brightness: BrightnessControl = DisplayServicesBrightness()
    private let log = Logger(subsystem: "com.notchdeck.app", category: "HUD")

    private init() {}

    var isRunning: Bool { tap != nil }

    /// Starts when Accessibility is granted; otherwise asks for it and starts once granted.
    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { requestPermission(); return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED: media / brightness keys
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: hudTapCallback, userInfo: nil) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        permissionPoll?.cancel(); permissionPoll = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    /// Shows the system Accessibility prompt, then starts as soon as it's granted.
    func requestPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        waitForPermission()
    }

    private func waitForPermission() {
        guard permissionPoll == nil else { return }
        permissionPoll = Task { [weak self] in
            while !Task.isCancelled, !AXIsProcessTrusted() { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            self?.permissionPoll = nil
            if SettingsStore.shared.hudEnabled { self?.start() }
        }
    }

    fileprivate func reenable(_ reason: CGEventType) {
        log.notice("event tap disabled (\(reason.rawValue)), re-enabling")
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Called on lock. The tap is not torn down on lock, but one the system switched off
    /// (timeout while the Mac was busy locking) stays off until re-enabled.
    func ensureEnabled() {
        guard let tap else { return }
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        log.notice("lock: event tap enabled=\(enabled)")
        if !enabled { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: Keys

    private enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        case illuminationUp = 21, illuminationDown = 22, illuminationToggle = 23
    }

    /// True = handled here (swallow the event).
    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard SettingsStore.shared.hudEnabled,
              let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8,
              let key = Key(rawValue: (ns.data1 & 0xFFFF0000) >> 16) else { return false }
        let mods = ns.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌥ alone opens the matching System Settings pane: leave that to macOS.
        if mods.contains(.option), !mods.contains(.shift) { return false }
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        // ⇧⌥ = quarter steps, like macOS.
        let step: Float = mods.contains([.shift, .option]) ? 1 / 64 : 1 / 16

        switch key {
        case .soundUp, .soundDown, .mute:
            guard SystemVolume.volume != nil else { return false }
            if isDown { volumeKey(key, step: step) }
        case .brightnessUp, .brightnessDown:
            guard let display = targetDisplay, brightness.brightness(of: display) != nil else { return false }
            if isDown { changeBrightness(by: key == .brightnessUp ? step : -step, display: display) }
        case .illuminationUp, .illuminationDown, .illuminationToggle:
            guard KeyboardBacklight.shared.level != nil else { return false }
            if isDown { keyboardKey(key, step: step) }
        }
        return true
    }

    /// Public entry for gestures: nudges volume and shows the HUD.
    func changeVolume(by delta: Float) {
        guard let v = SystemVolume.volume else { return }
        if SystemVolume.isMuted, delta > 0 { SystemVolume.isMuted = false }
        let new = (v + delta).clamped(to: 0...1)
        SystemVolume.volume = new
        show(.volume(muted: SystemVolume.isMuted), new)
    }

    private func volumeKey(_ key: Key, step: Float) {
        switch key {
        case .mute:
            SystemVolume.isMuted.toggle()
            show(.volume(muted: SystemVolume.isMuted), SystemVolume.volume ?? 0)
        default:
            changeVolume(by: key == .soundUp ? step : -step)
        }
    }

    private func changeBrightness(by delta: Float, display: CGDirectDisplayID) {
        guard let b = brightness.brightness(of: display) else { return }
        let new = (b + delta).clamped(to: 0...1)
        brightness.setBrightness(new, of: display)
        show(.brightness, new)
    }

    private func keyboardKey(_ key: Key, step: Float) {
        let kb = KeyboardBacklight.shared
        if key == .illuminationToggle {
            if let l = kb.toggle() { show(.keyboard, l) }
            return
        }
        guard let l = kb.level else { return }
        let new = (l + (key == .illuminationUp ? step : -step)).clamped(to: 0...1)
        kb.set(new)
        show(.keyboard, new)
    }

    /// The display under the cursor, like macOS.
    private var targetDisplay: CGDirectDisplayID? {
        let p = NSEvent.mouseLocation
        return (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main)?.displayID
    }

    private func show(_ kind: HUDKind, _ level: Float) {
        ActivityCenter.shared.show(.hud(kind: kind, level: Double(level)))
    }
}

/// Runs on the main run loop (the tap's source is added there).
private let hudTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { HUDController.shared.reenable(type) }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14 else { return Unmanaged.passUnretained(event) }
    nonisolated(unsafe) let e = event // already on the main thread
    let handled = MainActor.assumeIsolated { HUDController.shared.handle(e) }
    return handled ? nil : Unmanaged.passUnretained(event)
}

