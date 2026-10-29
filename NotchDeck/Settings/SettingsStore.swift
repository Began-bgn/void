import SwiftUI
import Observation

enum DisplayMode: String, CaseIterable, Sendable {
    case cursorDisplay, allDisplays
}

/// What a side slot of the lock screen player's control row holds.
enum LockSlot: String, CaseIterable, Sendable {
    case shuffle, favorite, output, none
}

/// What starts a Face Unlock scan on the lock screen.
enum FaceUnlockTrigger: String, CaseIterable, Sendable {
    case hover, click, wake
}

/// Which liveness prompts a scan asks for.
enum FaceUnlockLiveness: String, CaseIterable, Sendable {
    case blink, turn, both
}

/// How much of the track the lock screen reveals.
enum LockDetails: String, CaseIterable, Sendable {
    case show, coverAndControls, genericLabel
}

/// UserDefaults-backed settings, edited in the Settings window.
@MainActor @Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    /// Off: the collapsed notch opens on click (or the shortcut) instead of hover dwell.
    var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "openOnHover") } }
    var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    var closeDelay: Double { didSet { defaults.set(closeDelay, forKey: "closeDelay") } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    var suppressInFullScreen: Bool { didSet { defaults.set(suppressInFullScreen, forKey: "suppressInFullScreen") } }
    var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") } }

    var spotifyEnabled: Bool { didSet { defaults.set(spotifyEnabled, forKey: "spotifyEnabled") } }
    var appleMusicEnabled: Bool { didSet { defaults.set(appleMusicEnabled, forKey: "appleMusicEnabled") } }
    var preferredSource: MusicSource { didSet { defaults.set(preferredSource.rawValue, forKey: "preferredSource") } }
    var tintFromArtwork: Bool { didSet { defaults.set(tintFromArtwork, forKey: "tintFromArtwork") } }
    /// Accent when not tinting from artwork.
    var fixedTint: Color { didSet { defaults.set(Self.rgb(fixedTint), forKey: "fixedTint") } }
    var visualizerEnabled: Bool { didSet { defaults.set(visualizerEnabled, forKey: "visualizerEnabled") } }
    var visualizerRealAudio: Bool { didSet { defaults.set(visualizerRealAudio, forKey: "visualizerRealAudio") } }

    var shelfPersist: Bool { didSet { defaults.set(shelfPersist, forKey: "shelfPersist") } }
    var shelfCopyFiles: Bool { didSet { defaults.set(shelfCopyFiles, forKey: "shelfCopyFiles") } }
    /// 0 = never.
    var shelfAutoClearHours: Double { didSet { defaults.set(shelfAutoClearHours, forKey: "shelfAutoClearHours") } }
    /// Dropping onto the notch itself sends straight to AirDrop instead of adding to the shelf.
    var notchDropAirDrop: Bool { didSet { defaults.set(notchDropAirDrop, forKey: "notchDropAirDrop") } }

    var activityBattery: Bool { didSet { defaults.set(activityBattery, forKey: "activityBattery") } }
    var activityTimer: Bool { didSet { defaults.set(activityTimer, forKey: "activityTimer") } }
    var activityFocus: Bool { didSet { defaults.set(activityFocus, forKey: "activityFocus") } }
    var lowBatteryThreshold1: Int { didSet { defaults.set(lowBatteryThreshold1, forKey: "lowBatteryThreshold1") } }
    var lowBatteryThreshold2: Int { didSet { defaults.set(lowBatteryThreshold2, forKey: "lowBatteryThreshold2") } }
    var popupDuration: Double { didSet { defaults.set(popupDuration, forKey: "popupDuration") } }
    var focusShortcutName: String { didSet { defaults.set(focusShortcutName, forKey: "focusShortcutName") } }

    var hudEnabled: Bool { didSet { defaults.set(hudEnabled, forKey: "hudEnabled") } }
    var gestureSwipe: Bool { didSet { defaults.set(gestureSwipe, forKey: "gestureSwipe") } }
    var gestureInvert: Bool { didSet { defaults.set(gestureInvert, forKey: "gestureInvert") } }
    /// 0.5 (needs a long swipe) … 2 (hair trigger).
    var gestureSensitivity: Double { didSet { defaults.set(gestureSensitivity, forKey: "gestureSensitivity") } }
    var gestureClick: Bool { didSet { defaults.set(gestureClick, forKey: "gestureClick") } }
    var gestureVolume: Bool { didSet { defaults.set(gestureVolume, forKey: "gestureVolume") } }
    var gestureLongPress: Bool { didSet { defaults.set(gestureLongPress, forKey: "gestureLongPress") } }

    /// Face Unlock (software, camera-based). Opt-in; the kill switch turns it off and wipes data.
    var faceUnlockEnabled: Bool { didSet { defaults.set(faceUnlockEnabled, forKey: "faceUnlockEnabled") } }
    var faceUnlockTrigger: FaceUnlockTrigger { didSet { defaults.set(faceUnlockTrigger.rawValue, forKey: "faceUnlockTrigger") } }
    /// Hover time on the notch before a scan, 0.3 … 3 s.
    var faceUnlockDwell: Double { didSet { defaults.set(faceUnlockDwell, forKey: "faceUnlockDwell") } }
    var faceUnlockLiveness: FaceUnlockLiveness { didSet { defaults.set(faceUnlockLiveness.rawValue, forKey: "faceUnlockLiveness") } }
    /// Match threshold (cosine), 0.55 … 0.9. Higher = stricter.
    var faceUnlockThreshold: Double { didSet { defaults.set(faceUnlockThreshold, forKey: "faceUnlockThreshold") } }
    /// Failed scans before Face Unlock locks out until a normal unlock.
    var faceUnlockLockout: Int { didSet { defaults.set(faceUnlockLockout, forKey: "faceUnlockLockout") } }

    /// Master switch for anything drawn above the lock screen (player card and padlock).
    var lockScreenEnabled: Bool { didSet { defaults.set(lockScreenEnabled, forKey: "lockScreenEnabled") } }
    /// Padlock in the notch on lock/unlock.
    var lockIndicator: Bool { didSet { defaults.set(lockIndicator, forKey: "lockIndicator") } }
    var lockAnimation: Bool { didSet { defaults.set(lockAnimation, forKey: "lockAnimation") } }
    var lockPadlockTint: Color { didSet { defaults.set(Self.rgb(lockPadlockTint), forKey: "lockPadlockTint") } }
    var lockShowWhenPaused: Bool { didSet { defaults.set(lockShowWhenPaused, forKey: "lockShowWhenPaused") } }
    /// Points up (+) or down (-) from the default lower-middle spot.
    var lockOffsetY: Double { didSet { defaults.set(lockOffsetY, forKey: "lockOffsetY") } }
    var lockScale: Double { didSet { defaults.set(lockScale, forKey: "lockScale") } }
    var lockLeftSlot: LockSlot { didSet { defaults.set(lockLeftSlot.rawValue, forKey: "lockLeftSlot") } }
    var lockRightSlot: LockSlot { didSet { defaults.set(lockRightSlot.rawValue, forKey: "lockRightSlot") } }
    var lockHeartBesideTitle: Bool { didSet { defaults.set(lockHeartBesideTitle, forKey: "lockHeartBesideTitle") } }
    var lockDetails: LockDetails { didSet { defaults.set(lockDetails.rawValue, forKey: "lockDetails") } }
    var lockTintFromArtwork: Bool { didSet { defaults.set(lockTintFromArtwork, forKey: "lockTintFromArtwork") } }
    /// 0 = clear glass, 1 = strongest cover tint.
    var lockGlassIntensity: Double { didSet { defaults.set(lockGlassIntensity, forKey: "lockGlassIntensity") } }
    /// Display name to show the card on; empty = the main display (the one with the lock UI).
    var lockDisplayName: String { didSet { defaults.set(lockDisplayName, forKey: "lockDisplayName") } }

    private init() {
        let d = UserDefaults.standard
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        openOnHover = d.object(forKey: "openOnHover") as? Bool ?? true
        spotifyEnabled = d.object(forKey: "spotifyEnabled") as? Bool ?? true
        appleMusicEnabled = d.object(forKey: "appleMusicEnabled") as? Bool ?? true
        let rgb = d.array(forKey: "fixedTint") as? [Double] ?? []
        fixedTint = rgb.count == 3 ? Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2]) : .white
        hoverDelay = (d.object(forKey: "hoverDelay") as? Double ?? 0.8).clamped(to: 0.2...5.0)
        closeDelay = (d.object(forKey: "closeDelay") as? Double ?? 0.4).clamped(to: 0.0...2.0)
        hapticsEnabled = d.object(forKey: "hapticsEnabled") as? Bool ?? true
        suppressInFullScreen = d.object(forKey: "suppressInFullScreen") as? Bool ?? true
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .cursorDisplay
        preferredSource = MusicSource(rawValue: d.string(forKey: "preferredSource") ?? "") ?? .spotify
        tintFromArtwork = d.object(forKey: "tintFromArtwork") as? Bool ?? true
        visualizerEnabled = d.object(forKey: "visualizerEnabled") as? Bool ?? true
        visualizerRealAudio = d.object(forKey: "visualizerRealAudio") as? Bool ?? false
        shelfPersist = d.object(forKey: "shelfPersist") as? Bool ?? true
        shelfCopyFiles = d.object(forKey: "shelfCopyFiles") as? Bool ?? false
        shelfAutoClearHours = max(0, d.object(forKey: "shelfAutoClearHours") as? Double ?? 0)
        notchDropAirDrop = d.object(forKey: "notchDropAirDrop") as? Bool ?? false
        activityBattery = d.object(forKey: "activityBattery") as? Bool ?? true
        activityTimer = d.object(forKey: "activityTimer") as? Bool ?? true
        activityFocus = d.object(forKey: "activityFocus") as? Bool ?? true
        lowBatteryThreshold1 = (d.object(forKey: "lowBatteryThreshold1") as? Int ?? 20).clamped(to: 1...99)
        lowBatteryThreshold2 = (d.object(forKey: "lowBatteryThreshold2") as? Int ?? 10).clamped(to: 1...99)
        popupDuration = (d.object(forKey: "popupDuration") as? Double ?? 3.5).clamped(to: 1...10)
        focusShortcutName = d.string(forKey: "focusShortcutName") ?? "NotchDeck Toggle Focus"
        hudEnabled = d.object(forKey: "hudEnabled") as? Bool ?? true
        gestureSwipe = d.object(forKey: "gestureSwipe") as? Bool ?? true
        gestureInvert = d.object(forKey: "gestureInvert") as? Bool ?? false
        gestureSensitivity = (d.object(forKey: "gestureSensitivity") as? Double ?? 1).clamped(to: 0.5...2)
        gestureClick = d.object(forKey: "gestureClick") as? Bool ?? false
        gestureVolume = d.object(forKey: "gestureVolume") as? Bool ?? false
        gestureLongPress = d.object(forKey: "gestureLongPress") as? Bool ?? true
        // Untested macOS majors default to off (private API).
        faceUnlockEnabled = d.bool(forKey: "faceUnlockEnabled")
        faceUnlockTrigger = FaceUnlockTrigger(rawValue: d.string(forKey: "faceUnlockTrigger") ?? "") ?? .hover
        faceUnlockDwell = d.object(forKey: "faceUnlockDwell") as? Double ?? 0.8
        faceUnlockLiveness = FaceUnlockLiveness(rawValue: d.string(forKey: "faceUnlockLiveness") ?? "") ?? .both
        faceUnlockThreshold = d.object(forKey: "faceUnlockThreshold") as? Double ?? 0.7
        faceUnlockLockout = d.object(forKey: "faceUnlockLockout") as? Int ?? 3
        lockScreenEnabled = d.object(forKey: "lockScreenEnabled") as? Bool ?? LockScreenSupport.isTestedOS
        lockIndicator = d.object(forKey: "lockIndicator") as? Bool ?? true
        lockAnimation = d.object(forKey: "lockAnimation") as? Bool ?? true
        let lockRGB = d.array(forKey: "lockPadlockTint") as? [Double] ?? []
        lockPadlockTint = lockRGB.count == 3 ? Color(.sRGB, red: lockRGB[0], green: lockRGB[1], blue: lockRGB[2]) : .white
        lockShowWhenPaused = d.object(forKey: "lockShowWhenPaused") as? Bool ?? true
        lockOffsetY = (d.object(forKey: "lockOffsetY") as? Double ?? 0).clamped(to: -250...250)
        lockScale = (d.object(forKey: "lockScale") as? Double ?? 1).clamped(to: 0.8...1.3)
        lockLeftSlot = LockSlot(rawValue: d.string(forKey: "lockLeftSlot") ?? "") ?? .shuffle
        lockRightSlot = LockSlot(rawValue: d.string(forKey: "lockRightSlot") ?? "") ?? .output
        lockHeartBesideTitle = d.object(forKey: "lockHeartBesideTitle") as? Bool ?? false
        lockDetails = LockDetails(rawValue: d.string(forKey: "lockDetails") ?? "") ?? .show
        lockTintFromArtwork = d.object(forKey: "lockTintFromArtwork") as? Bool ?? false
        lockGlassIntensity = (d.object(forKey: "lockGlassIntensity") as? Double ?? 0).clamped(to: 0...1)
        lockDisplayName = d.string(forKey: "lockDisplayName") ?? ""
    }

    func isEnabled(_ source: MusicSource) -> Bool { source == .spotify ? spotifyEnabled : appleMusicEnabled }

    /// Accent for music UI: the artwork colour, or the fixed one.
    func tint(_ artwork: Color) -> Color { tintFromArtwork ? artwork : fixedTint }

    private static func rgb(_ color: Color) -> [Double] {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
    }

    /// Clears every stored preference (shortcuts included) and relaunches, so every part of the
    /// app starts from the defaults.
    func resetToDefaults() {
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.notchdeck.app")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
