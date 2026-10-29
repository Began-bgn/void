import SwiftUI
import ServiceManagement
import EventKit
import Intents
import OSLog
import KeyboardShortcuts
import Sparkle

extension KeyboardShortcuts.Name {
    static let toggleNotch = Self("toggleNotch")
    static let playPause = Self("playPause")
    static let nextTrack = Self("nextTrack")
    static let previousTrack = Self("previousTrack")
}

/// Captures SwiftUI's `openSettings` from inside the notch's hosting view. Since macOS 14 there is
/// no other working way to open the Settings scene from AppKit (status menu, app reopen).
struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    @MainActor private static var action: OpenSettingsAction?

    var body: some View { Color.clear.onAppear { Self.action = openSettings } }

    /// Activate first: a window shown while the app is inactive draws its sidebar icons grey, then
    /// recolours them on activation (a visible flash).
    @MainActor static func open() {
        // Regular app while Settings is open, so it shows in ⌘-Tab; the tracker reverts on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        action?()
    }
}

/// Sparkle. The feed URL and signing key come with the release build (scripts/release.sh); until
/// then the updater stays off and the button is disabled.
@MainActor
enum Updates {
    static let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    static var configured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }
    static func start() { if configured { controller.startUpdater() } }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, music, lockScreen, faceUnlock, shelf, widgets, accessibility, activities, hud, gestures, shortcuts, permissions, privacy, about
    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .music: String(localized: "Music")
        case .lockScreen: String(localized: "Lock Screen")
        case .faceUnlock: String(localized: "Face Unlock")
        case .shelf: String(localized: "Shelf")
        case .widgets: String(localized: "Widgets")
        case .accessibility: String(localized: "Accessibility")
        case .activities: String(localized: "Live Activities")
        case .hud: String(localized: "HUD")
        case .gestures: String(localized: "Gestures")
        case .shortcuts: String(localized: "Shortcuts")
        case .permissions: String(localized: "Permissions")
        case .privacy: String(localized: "Privacy")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .music: "music.note"
        case .lockScreen: "lock"
        case .faceUnlock: "faceid"
        case .shelf: "tray"
        case .widgets: "square.grid.2x2"
        case .accessibility: "accessibility"
        case .activities: "bolt.circle"
        case .hud: "speaker.wave.2"
        case .gestures: "hand.draw"
        case .shortcuts: "command"
        case .permissions: "lock.shield"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    @Binding var selection: SettingsPane?

    var body: some View {
        let selected = selection == pane
        // Custom row, not Label/List: the system sidebar restyles icons on every key/inactive
        // change, which blanked them for a moment when the window was re-entered.
        Button { selection = pane } label: {
            GlassSidebarRow(title: pane.title, systemImage: pane.symbol, color: pane.color, selected: selected)
        }
        .buttonStyle(.plain)
    }
}

private extension SettingsPane {
    /// Icon tile colour in the sidebar.
    var color: Color {
        switch self {
        case .general, .about: .gray
        case .appearance: .pink
        case .music: .red
        case .lockScreen: .indigo
        case .faceUnlock: .green
        case .shelf: .orange
        case .widgets: .teal
        case .accessibility: .blue
        case .activities: .green
        case .hud: .purple
        case .gestures: .mint
        case .shortcuts: .brown
        case .permissions: .yellow
        case .privacy: .cyan
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane?

    init(pane: SettingsPane = .general) { _pane = State(initialValue: pane) }

    var body: some View {
        // A plain HStack, not NavigationSplitView: the system sidebar column is its own glass
        // layer that redraws (blanking its icons) whenever the window is activated, e.g. from
        // Mission Control or another app. Custom rows also keep their colours in any window state.
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsPane.allCases) { p in
                        SidebarRow(pane: p, selection: $pane)
                    }
                }
                .padding(8)
            }
            .frame(width: 190)
            Divider()
            Form { detail }
                .formStyle(.grouped)
                .toggleStyle(GlassToggleStyle())
        }
        // Pin the active look so switching windows/apps doesn't redraw the icons.
        .environment(\.controlActiveState, .key)
        .navigationTitle(pane?.title ?? "")
        // Flat window background: glass is for controls (the selected sidebar row, toggle thumbs),
        // never the whole window.
        .background { ActivationPolicyTracker().ignoresSafeArea() }
        .frame(minWidth: 700, minHeight: 500)
    }

    @ViewBuilder private var detail: some View {
        switch pane ?? .general {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .music: MusicPane()
        case .lockScreen: LockScreenPane()
        case .faceUnlock: FaceUnlockPane()
        case .shelf: ShelfPane()
        case .widgets: WidgetsPane()
        case .accessibility: AccessibilityPane()
        case .activities: ActivitiesPane()
        case .hud: HUDPane()
        case .gestures: GesturesPane()
        case .shortcuts: ShortcutsPane()
        case .permissions: PermissionsPane()
        case .privacy: PrivacyPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @Bindable private var s = SettingsStore.shared
    @State private var login = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var confirmReset = false

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(get: { login != .notRegistered && login != .notFound }, set: setLogin))
            if login == .requiresApproval {
                LabeledContent("Approve Void in Login Items.") {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginError { Text(loginError).foregroundStyle(.red) }
            Toggle("Show menu bar icon", isOn: $s.showMenuBarIcon)
                .onChange(of: s.showMenuBarIcon) { _, on in AppDelegate.shared?.statusItem?.isVisible = on }
            if !s.showMenuBarIcon {
                Text("Open Void again from Finder or Spotlight to get back here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Opening and closing") {
            Toggle("Open on hover", isOn: $s.openOnHover)
            SecondsSlider(title: "Hover delay", value: $s.hoverDelay, range: 0.2...2).disabled(!s.openOnHover)
            SecondsSlider(title: "Close delay", value: $s.closeDelay, range: 0...2)
            Toggle("Haptic feedback", isOn: $s.hapticsEnabled)
        }
        Section {
            LabeledContent("Updates") {
                Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }.disabled(!Updates.configured)
            }
            LabeledContent("Reset all settings and shortcuts") {
                Button("Reset to Defaults…", role: .destructive) { confirmReset = true }
            }
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset and Relaunch", role: .destructive) { s.resetToDefaults() }
        } message: {
            Text("Shelf items, notes and widgets are kept.")
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        login = SMAppService.mainApp.status
    }
}

private struct AppearancePane: View {
    @Bindable private var s = SettingsStore.shared

    var body: some View {
        Section {
            Picker("Show the notch on", selection: $s.displayMode) {
                Text("The display with the cursor").tag(DisplayMode.cursorDisplay)
                Text("All displays").tag(DisplayMode.allDisplays)
            }
            .onChange(of: s.displayMode) { AppDelegate.shared?.notch.syncScreens() }
            Toggle("Open over full-screen apps", isOn: Binding(get: { !s.suppressInFullScreen }, set: { s.suppressInFullScreen = !$0 }))
        }
        Section("Accent colour") {
            Picker("Accent", selection: $s.tintFromArtwork) {
                Text("From the album artwork").tag(true)
                Text("Fixed").tag(false)
            }
            .pickerStyle(.radioGroup)
            if !s.tintFromArtwork { ColorPicker("Colour", selection: $s.fixedTint, supportsOpacity: false) }
        }
    }
}

private struct MusicPane: View {
    @Bindable private var s = SettingsStore.shared
    private let visualizer = VisualizerEngine.shared

    var body: some View {
        Section("Sources") {
            Toggle("Spotify", isOn: $s.spotifyEnabled)
            Toggle("Apple Music", isOn: $s.appleMusicEnabled)
            Picker("When both play, show", selection: $s.preferredSource) {
                ForEach(MusicSource.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        Section("Visualiser") {
            Toggle("Show visualiser", isOn: $s.visualizerEnabled)
            Toggle("Follow the real audio", isOn: $s.visualizerRealAudio).disabled(!s.visualizerEnabled)
            if s.visualizerEnabled, s.visualizerRealAudio, !visualizer.hasPermission {
                LabeledContent("Needs Screen & System Audio Recording.") {
                    Button("Allow…") { visualizer.requestPermission() }
                }
            }
        }
        .onChange(of: [s.spotifyEnabled, s.appleMusicEnabled, s.visualizerEnabled, s.visualizerRealAudio]) { MusicStore.shared.reload() }
        .onChange(of: s.preferredSource) { MusicStore.shared.reload() }
        Section {
            LabeledContent("Spotify account") { Text("Not available yet").foregroundStyle(.secondary) }
        } footer: {
            Text("Liking songs in Spotify needs a Spotify account connection, which isn't built yet. Apple Music favourites work.")
        }
    }
}

private struct LockScreenPane: View {
    @Bindable private var s = SettingsStore.shared
    @Bindable private var lock = LockScreenController.shared

    var body: some View {
        Section {
            Toggle("Show the player on the lock screen", isOn: $s.lockScreenEnabled)
            Toggle("Show when paused", isOn: $s.lockShowWhenPaused).disabled(!s.lockScreenEnabled)
        } footer: {
            Text(LockScreenSupport.isTestedOS
                 ? "Uses private macOS window-server calls. If they fail, Void turns this off on its own; the notch player keeps working."
                 : "Experimental on macOS \(LockScreenSupport.osMajor): not tested on this version yet.")
        }
        Section("Padlock in the notch") {
            Toggle("Show padlock on lock and unlock", isOn: $s.lockIndicator)
            Toggle("Animate", isOn: $s.lockAnimation).disabled(!s.lockIndicator)
            ColorPicker("Padlock colour", selection: $s.lockPadlockTint, supportsOpacity: false).disabled(!s.lockIndicator)
        }
        Section("Card") {
            LabeledContent("Position") {
                Slider(value: $s.lockOffsetY, in: -250...250) { Text("Position") } minimumValueLabel: { Text("Lower") } maximumValueLabel: { Text("Higher") }
                    .labelsHidden().frame(width: 240)
            }
            LabeledContent("Size") {
                Slider(value: $s.lockScale, in: 0.8...1.3).frame(width: 240)
            }
            Picker("Left button", selection: $s.lockLeftSlot) { slotOptions }
            Picker("Right button", selection: $s.lockRightSlot) { slotOptions }
            Toggle("Heart beside the title", isOn: $s.lockHeartBesideTitle)
            Picker("Song details", selection: $s.lockDetails) {
                Text("Show").tag(LockDetails.show)
                Text("Cover and controls only").tag(LockDetails.coverAndControls)
                Text("Only \u{201C}Now playing\u{201D}").tag(LockDetails.genericLabel)
            }
            Toggle("Tint from artwork", isOn: $s.lockTintFromArtwork)
            LabeledContent("Text shading") { Slider(value: $s.lockGlassIntensity, in: 0...1).frame(width: 240) }
            Picker("Display", selection: $s.lockDisplayName) {
                Text("Main display").tag("")
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
            }
        }
        .disabled(!s.lockScreenEnabled)
        Section("Diagnostics") {
            LabeledContent("Private API") {
                Text(lock.missingSymbols.isEmpty ? "All symbols resolved" : "Missing: \(lock.missingSymbols.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Status") {
                Text(lock.presenterSupported ? "Available" : "Off for this session").foregroundStyle(.secondary)
            }
            if let error = lock.lastError {
                LabeledContent("Last error") { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Toggle("Show test window on next lock", isOn: $lock.spikeArmed).disabled(!s.lockScreenEnabled)
            if let clicks = lock.clicksLastLock {
                LabeledContent("Clicks received during last lock") { Text("\(clicks)").monospacedDigit() }
            }
        }
        Section {
            Button("Turn Off and Remove Window", role: .destructive) { lock.kill() }
        } footer: {
            Text("Kill switch: hides anything on the lock screen at once and turns the feature off.")
        }
    }

    @ViewBuilder private var slotOptions: some View {
        Text("Shuffle").tag(LockSlot.shuffle)
        Text("Favourite").tag(LockSlot.favorite)
        Text("Audio output").tag(LockSlot.output)
        Text("None").tag(LockSlot.none)
    }
}

private struct ShelfPane: View {
    @Bindable private var s = SettingsStore.shared
    private let shelf = ShelfStore.shared

    var body: some View {
        Section {
            Toggle("Keep items after quitting", isOn: $s.shelfPersist)
                .onChange(of: s.shelfPersist) { _, on in shelf.persist = on; shelf.save() }
            Picker("Clear items after", selection: $s.shelfAutoClearHours) {
                Text("Never").tag(0.0)
                Text("1 hour").tag(1.0)
                Text("1 day").tag(24.0)
                Text("1 week").tag(168.0)
            }
            .onChange(of: s.shelfAutoClearHours) { _, h in shelf.autoClearHours = h; shelf.pruneExpired() }
            Picker("Dropped files", selection: $s.shelfCopyFiles) {
                Text("Keep a reference to the original").tag(false)
                Text("Copy into the shelf").tag(true)
            }
            .onChange(of: s.shelfCopyFiles) { _, on in shelf.copyFiles = on }
            Picker("Dropping on the notch", selection: $s.notchDropAirDrop) {
                Text("Add to the shelf").tag(false)
                Text("Send with AirDrop").tag(true)
            }
        } header: {
            Text("Shelf")
        } footer: {
            Text("With AirDrop, files dragged onto the notch open the AirDrop sheet so you can pick your iPhone or another nearby device. The AirDrop tile on the Shelf page always works.")
        }
    }
}

private struct WidgetsPane: View {
    private let store = WidgetStore.shared

    var body: some View {
        Section("On the Widgets page") {
            if store.kinds.isEmpty { Text("No widgets").foregroundStyle(.secondary) }
            ForEach(store.kinds, id: \.self) { kind in
                if let t = WidgetRegistry.type(for: kind) {
                    HStack {
                        Label(t.title, systemImage: t.symbol)
                        Spacer()
                        Button { store.shift(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(kind == store.kinds.first).accessibilityLabel("Move Earlier")
                        Button { store.shift(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(kind == store.kinds.last).accessibilityLabel("Move Later")
                        Button("Remove") { store.remove(kind) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        let addable = store.addable.map { ($0.kind, $0.title, $0.symbol) }
        if !addable.isEmpty {
            Section("Available") {
                ForEach(addable, id: \.0) { kind, title, symbol in
                    HStack {
                        Label(title, systemImage: symbol)
                        Spacer()
                        Button("Add") { store.add(kind) }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

private struct AccessibilityPane: View {
    @Bindable private var s = SettingsStore.shared

    var body: some View {
        Section {
            Toggle("Open on hover", isOn: $s.openOnHover)
            SecondsSlider(title: "Dwell time", value: $s.hoverDelay, range: 0.2...5).disabled(!s.openOnHover)
        } footer: {
            Text("With hover off, click the notch or use the Toggle Notch shortcut. A longer dwell avoids opening it by accident.")
        }
        Section {
            LabeledContent("Reduce Motion and Reduce Transparency") {
                Button("Display Settings…") { openSystemSettings("x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display") }
            }
        } footer: {
            Text("Void follows these system settings. With the notch open: ← → turn pages, Esc closes, Space previews shelf items.")
        }
    }
}

private struct ActivitiesPane: View {
    @Bindable private var s = SettingsStore.shared

    var body: some View {
        Section("Show") {
            Toggle("Battery", isOn: $s.activityBattery)
            Toggle("Timer", isOn: $s.activityTimer)
            Toggle("Focus", isOn: $s.activityFocus)
                .onChange(of: s.activityFocus) { _, on in on ? FocusMonitor.shared.start() : FocusMonitor.shared.stop() }
        }
        Section("Battery") {
            Stepper("First low-battery warning at \(s.lowBatteryThreshold1)%", value: $s.lowBatteryThreshold1, in: 1...99)
            Stepper("Second warning at \(s.lowBatteryThreshold2)%", value: $s.lowBatteryThreshold2, in: 1...99)
        }
        .disabled(!s.activityBattery)
        Section {
            SecondsSlider(title: "Pop-ups stay for", value: $s.popupDuration, range: 1...10)
            TextField("Focus Shortcut", text: $s.focusShortcutName)
        } footer: {
            Text("The moon in the notch runs the Focus Shortcut. If it doesn't exist yet, Void offers to add one.")
        }
    }
}

private struct HUDPane: View {
    @Bindable private var s = SettingsStore.shared

    var body: some View {
        // The timeline wraps the whole section: wrapped around just the warning row, it left an
        // empty row behind once Accessibility was granted.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Section {
                Toggle("Show volume and brightness in the notch", isOn: $s.hudEnabled)
                    .onChange(of: s.hudEnabled) { _, on in on ? HUDController.shared.start() : HUDController.shared.stop() }
                if s.hudEnabled, !AXIsProcessTrusted() {
                    LabeledContent("Needs Accessibility to read the keys.") {
                        Button("Allow…") { HUDController.shared.requestPermission() }
                    }
                }
            } footer: {
                Text("Covers volume, display brightness and keyboard backlight keys. Keys Void can't control (some external displays) still show the system HUD.")
            }
        }
    }
}

private struct GesturesPane: View {
    @Bindable private var s = SettingsStore.shared

    var body: some View {
        Section {
            Toggle("Swipe sideways to change track", isOn: $s.gestureSwipe)
            Toggle("Invert swipe direction", isOn: $s.gestureInvert).disabled(!s.gestureSwipe)
            LabeledContent("Sensitivity") {
                Slider(value: $s.gestureSensitivity, in: 0.5...2) {} minimumValueLabel: { Text("Low") } maximumValueLabel: { Text("High") }
                    .frame(width: 220)
            }
        } footer: {
            Text("Two-finger swipe over the closed notch: right for next track, left for previous.")
        }
        Section("More gestures") {
            Toggle("Click to play or pause", isOn: $s.gestureClick).disabled(!s.openOnHover)
            Toggle("Swipe up or down to change volume", isOn: $s.gestureVolume)
            Toggle("Press and hold to open", isOn: $s.gestureLongPress)
        }
    }
}

private struct ShortcutsPane: View {
    var body: some View {
        Section {
            KeyboardShortcuts.Recorder("Toggle notch", name: .toggleNotch)
            KeyboardShortcuts.Recorder("Play or pause", name: .playPause)
            KeyboardShortcuts.Recorder("Next track", name: .nextTrack)
            KeyboardShortcuts.Recorder("Previous track", name: .previousTrack)
        } footer: {
            Text("Work everywhere, even while another app is in front.")
        }
    }
}

// MARK: Permissions

private enum Permission: CaseIterable, Identifiable {
    case accessibility, screenRecording, calendars, automationSpotify, automationMusic, focus
    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility: String(localized: "Accessibility")
        case .screenRecording: String(localized: "Screen & System Audio Recording")
        case .calendars: String(localized: "Calendars")
        case .automationSpotify: String(localized: "Automation: Spotify")
        case .automationMusic: String(localized: "Automation: Music")
        case .focus: String(localized: "Focus Status")
        }
    }

    var purpose: String {
        switch self {
        case .accessibility: String(localized: "Volume and brightness keys, Esc to close")
        case .screenRecording: String(localized: "Visualiser that follows the real audio")
        case .calendars: String(localized: "Calendar widget")
        case .automationSpotify, .automationMusic: String(localized: "Show and control what's playing")
        case .focus: String(localized: "Focus moon in the notch")
        }
    }

    private var anchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .calendars: "Privacy_Calendars"
        case .automationSpotify, .automationMusic: "Privacy_Automation"
        case .focus: "Privacy_Focus"
        }
    }

    /// true = granted, false = denied, nil = not asked yet (or the app to automate isn't running).
    @MainActor var status: Bool? {
        switch self {
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .calendars:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: true
            case .notDetermined: nil
            default: false
            }
        case .automationSpotify: Self.automation(MusicSource.spotify.bundleID, ask: false)
        case .automationMusic: Self.automation(MusicSource.appleMusic.bundleID, ask: false)
        case .focus:
            switch INFocusStatusCenter.default.authorizationStatus {
            case .authorized: true
            case .notDetermined: nil
            default: false
            }
        }
    }

    /// Asks when macOS still can; otherwise opens the matching System Settings pane.
    @MainActor func resolve() {
        guard status == nil else {
            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
            return
        }
        switch self {
        case .calendars: EKEventStore().requestFullAccessToEvents { _, _ in }
        case .focus: INFocusStatusCenter.default.requestAuthorization { _ in }
        case .automationSpotify, .automationMusic:
            let id = self == .automationSpotify ? MusicSource.spotify.bundleID : MusicSource.appleMusic.bundleID
            Task.detached { _ = Self.automation(id, ask: true) } // blocks while the prompt is up
        default: openSystemSettings("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
    }

    nonisolated static func automation(_ bundleID: String, ask: Bool) -> Bool? {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask) {
        case noErr: return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return nil
        }
    }
}

private struct PermissionsPane: View {
    var body: some View {
        // Re-read every 2 s while the page is open, so changes in System Settings show up.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Section {
                ForEach(Permission.allCases) { p in
                    let status = p.status
                    HStack {
                        Image(systemName: status == true ? "checkmark.circle.fill" : status == false ? "xmark.circle.fill" : "questionmark.circle")
                            .foregroundStyle(status == true ? .green : status == false ? .red : .secondary)
                            .accessibilityLabel(status == true ? "Allowed" : status == false ? "Not allowed" : "Not asked yet")
                        VStack(alignment: .leading) {
                            Text(p.title)
                            Text(p.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if status != true {
                            Button(status == nil ? "Allow…" : "Open Settings…") { p.resolve() }
                        }
                    }
                }
            } footer: {
                Text("Automation can only be checked while Spotify or Music is running.")
            }
        }
    }
}

// MARK: Privacy & About

private struct PrivacyPane: View {
    @State private var confirmClear = false

    var body: some View {
        Section {
            Text("""
            Everything stays on this Mac. NotchDeck sends no analytics or telemetry.
            • Shelf items (links to your files, or copies), notes, pinned apps and timer state: \
            ~/Library/Application Support/NotchDeck
            • Settings and shortcuts: the app's preferences
            • Album artwork: memory only
            """)
            .fixedSize(horizontal: false, vertical: true)
            Button("Show Data in Finder") {
                let dir = URL.applicationSupportDirectory.appending(path: "NotchDeck", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
        } header: {
            Text("What is stored")
        }
        Section("Clear") {
            LabeledContent("Shelf (your original files are kept)") {
                Button("Clear Shelf…", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("Remove every item from the shelf?", isPresented: $confirmClear) {
            Button("Clear Shelf", role: .destructive) { ShelfStore.shared.clear() }
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Void").font(.title2.bold())
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
            }
        }
        Section("Open-source licences") {
            Link("Sparkle (MIT)", destination: URL(string: "https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE")!)
            Link("KeyboardShortcuts (MIT)", destination: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts/blob/main/license")!)
        }
        Section {
            LabeledContent("Version, displays, settings and the last hour of logs") {
                Button("Export Diagnostics…") { exportDiagnostics() }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Saved to a file you choose; nothing is sent anywhere.")
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Void Diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = [
            "Void \(version)",
            ProcessInfo.processInfo.operatingSystemVersionString,
            "Displays: " + NSScreen.screens.map { "\($0.localizedName) (notch: \($0.safeAreaInsets.top > 0))" }.joined(separator: ", "),
            "",
            "Settings:",
        ]
        let prefs = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        lines += prefs.sorted { $0.key < $1.key }.map { "  \($0.key) = \($0.value)" }
        lines += ["", "Log (last hour):"]
        if let store = try? OSLogStore(scope: .currentProcessIdentifier),
           let entries = try? store.getEntries(at: store.position(date: .now.addingTimeInterval(-3600)),
                                               matching: NSPredicate(format: "subsystem == %@", "com.notchdeck.app")) {
            for case let e as OSLogEntryLog in entries {
                lines.append("\(e.date.formatted(date: .omitted, time: .standard)) [\(e.category)] \(e.composedMessage)")
            }
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Helpers

/// Makes NotchDeck a regular app while Settings is open, so the window shows in ⌘-Tab (and the
/// Dock); back to a menu bar-only app once it closes.
private struct ActivationPolicyTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Tracker() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Tracker: NSView {
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NSApp.setActivationPolicy(.regular)
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

private struct SecondsSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 0.1).frame(width: 180)
                Text("\(value, format: .number.precision(.fractionLength(1))) s")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }
}

@MainActor private func openSystemSettings(_ url: String) {
    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
}
