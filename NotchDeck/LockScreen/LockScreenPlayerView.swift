import SwiftUI
import AVKit
import CoreAudio

/// What the card reveals for a track under the "Hide song details" setting.
struct LockScreenText: Equatable {
    var title: String?
    var artist: String?
    var showsCover: Bool

    init(_ snap: MusicSnapshot, mode: LockDetails) {
        switch mode {
        case .show: self.init(title: snap.title, artist: snap.artist, showsCover: true)
        case .coverAndControls: self.init(title: nil, artist: nil, showsCover: true)
        case .genericLabel: self.init(title: String(localized: "Now playing"), artist: nil, showsCover: false)
        }
    }

    init(title: String?, artist: String?, showsCover: Bool) {
        self.title = title; self.artist = artist; self.showsCover = showsCover
    }
}

// MARK: - Card

struct LockScreenPlayerView: View {
    private let controller = LockScreenController.shared
    private let music = MusicStore.shared
    private let settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: LG.Radius.card, style: .continuous) }
    private var highContrast: Bool { contrast == .increased }

    var body: some View {
        ZStack {
            if controller.cardShown {
                Group {
                    if controller.spikeArmed {
                        SpikeTestView(clicks: controller.clicksThisLock)
                    } else if let snap = music.active {
                        card(snap)
                    }
                }
                .scaleEffect(settings.lockScale)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85),
                   value: controller.cardShown)
        .environment(\.colorScheme, .dark)
    }

    private func card(_ snap: MusicSnapshot) -> some View {
        let text = LockScreenText(snap, mode: settings.lockDetails)
        return VStack(spacing: 14) {
            header(snap, text)
            progress(snap)
            controls(snap)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(width: LockScreenController.cardSize.width, height: LockScreenController.cardSize.height)
        // Untinted clear glass: the wallpaper shows through. "Text shading" (0–25%, off by default)
        // adds a scrim for white text on bright wallpapers.
        .background {
            if settings.lockGlassIntensity > 0 {
                GlassScrim(top: 0.1 * settings.lockGlassIntensity, bottom: 0.25 * settings.lockGlassIntensity).clipShape(shape)
            }
        }
        .liquidGlass(.clear, in: shape, tint: settings.lockTintFromArtwork && music.active != nil ? LG.accent(from: music.tint) : nil)
        .elevation(.floating)
        .animation(LG.Motion.fade, value: music.tint)
        .foregroundStyle(.white)
    }

    // MARK: Rows

    private func header(_ snap: MusicSnapshot, _ text: LockScreenText) -> some View {
        HStack(spacing: 12) {
            if text.showsCover {
                cover
                    .opacity(snap.state == .playing ? 1 : 0.55)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = text.title {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                        if settings.lockHeartBesideTitle, let fav = snap.isFavorite {
                            Button { music.toggleFavorite() } label: {
                                Image(systemName: fav ? "heart.fill" : "heart").font(.system(size: 11, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(fav ? "Remove from favourites" : "Add to favourites")
                        }
                    }
                }
                if let artist = text.artist {
                    Text(artist).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.white.opacity(highContrast ? 0.85 : 0.55))
                }
            }
            Spacer(minLength: 8)
            VisualizerBars(isPlaying: snap.state == .playing, color: .white.opacity(0.55))
                .frame(width: 18, height: 14)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 64)
        .id(snap.trackKey)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
        .animation(.smooth(duration: 0.35), value: snap.trackKey)
    }

    private var cover: some View {
        let r = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if let art = music.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                r.fill(.white.opacity(0.15)).overlay { Image(systemName: "music.note").font(.system(size: 22)) }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(r)
    }

    private func progress(_ snap: MusicSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            GlassSlider(value: snap.elapsed(at: ctx.date), duration: snap.duration) { music.seek(to: $0) }
        }
    }

    private func controls(_ snap: MusicSnapshot) -> some View {
        HStack(spacing: 0) {
            slot(settings.lockLeftSlot, snap)
            Spacer(minLength: 0)
            TransportControls(isPlaying: snap.state == .playing,
                              previous: { music.previous() }, playPause: { music.playPause() }, next: { music.next() })
            Spacer(minLength: 0)
            slot(settings.lockRightSlot, snap)
        }
    }

    @ViewBuilder private func slot(_ slot: LockSlot, _ snap: MusicSnapshot) -> some View {
        switch slot {
        case .shuffle:
            control("shuffle", size: 15, label: snap.shuffle ? "Shuffle on" : "Shuffle off") { music.toggleShuffle() }
                .opacity(snap.shuffle ? 1 : 0.5)
        case .favorite:
            if let fav = snap.isFavorite {
                control(fav ? "heart.fill" : "heart", size: 16, label: fav ? "Remove from favourites" : "Add to favourites") {
                    music.toggleFavorite()
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        case .output:
            OutputButton()
        case .none:
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func control(_ symbol: String, size: CGFloat, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .fontDesign(.rounded)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Output

/// Current output device, from CoreAudio (public).
@MainActor @Observable
final class AudioOutput {
    static let shared = AudioOutput()
    private(set) var name = ""
    private(set) var symbol = "speaker.wave.2.fill"
    @ObservationIgnored private var listening = false

    private static var defaultDevice: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        guard !listening else { return }
        listening = true
        read()
        var addr = Self.defaultDevice
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            MainActor.assumeIsolated { AudioOutput.shared.read() }
        }
    }

    private func read() {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = Self.defaultDevice
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return }

        var cfName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cfName) == noErr, let cfName {
            name = cfName.takeRetainedValue() as String
        }

        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyTransportType
        _ = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport)
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: symbol = "headphones"
        case kAudioDeviceTransportTypeAirPlay: symbol = "airplayaudio"
        default: symbol = "speaker.wave.2.fill"
        }
    }
}

/// Shows the current output; a near-invisible system route picker on top opens the picker.
private struct OutputButton: View {
    private let output = AudioOutput.shared

    var body: some View {
        Image(systemName: output.symbol)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 44, height: 44)
            .overlay { RoutePicker().opacity(0.02) }
            .onAppear { output.start() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Audio output")
            .accessibilityValue(output.name)
            .accessibilityAddTraits(.isButton)
    }
}

private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: - Spike

/// Plain test panel for Diagnostics: proves the window shows and whether clicks arrive.
private struct SpikeTestView: View {
    let clicks: Int

    var body: some View {
        VStack(spacing: 6) {
            Text("Void lock screen test").font(.headline)
            Text("Click here. Clicks received: \(clicks)").monospacedDigit()
        }
        .foregroundStyle(.white)
        .frame(width: 300, height: 120)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Padlock

/// iPhone-style padlock: chunky rounded body, thick shackle. Unlocking lifts the shackle and slides
/// it right until its left leg sits on the body's right edge, with a short free right leg; locking
/// runs the same path back and settles with a small dip. One animated value drives both moves.
struct PadlockGlyph: View {
    let locking: Bool
    let tint: Color
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 = closed, 1 = open.
    @State private var open: Double
    @State private var glow = false

    /// Body width as a share of the 20 pt frame; every other size is relative to it.
    fileprivate static let bodyShare: CGFloat = 0.6

    init(locking: Bool, tint: Color, animated: Bool) {
        self.locking = locking; self.tint = tint; self.animated = animated
        // Animated: start in the opposite state and move to the final one.
        let startOpen = animated ? locking : !locking
        _open = State(initialValue: startOpen ? 1 : 0)
    }

    var body: some View {
        ZStack {
            Shackle(open: open)
                .stroke(tint, style: StrokeStyle(lineWidth: 20 * Self.bodyShare * 0.18, lineCap: .round))
            LockBody().fill(tint)
        }
        .frame(width: 20, height: 20)
        .brightness(glow ? 0.35 : 0)
        .task {
            let target: Double = locking ? 0 : 1
            guard animated, open != target else { return }
            try? await Task.sleep(for: .seconds(0.1))
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.2)) { open = target }
                return
            }
            if locking {
                withAnimation(.spring(duration: 0.45, bounce: 0.3)) { open = 0 }
            } else {
                withAnimation(.spring(duration: 0.5, bounce: 0.2)) { open = 1; glow = true }
                try? await Task.sleep(for: .seconds(0.4))
                withAnimation(.easeOut(duration: 0.3)) { glow = false }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(locking ? "Locked" : "Unlocked")
    }

    /// Body rectangle shared by both shapes: bottom of the frame, one point in from the left so the
    /// open shackle still fits on the right.
    fileprivate static func bodyRect(in r: CGRect) -> CGRect {
        let b = r.width * bodyShare
        return CGRect(x: r.minX + 1, y: r.maxY - 0.88 * b, width: b, height: 0.88 * b)
    }

    private struct LockBody: Shape {
        func path(in r: CGRect) -> Path {
            let body = PadlockGlyph.bodyRect(in: r)
            return RoundedRectangle(cornerRadius: body.width * 0.17, style: .continuous).path(in: body)
        }
    }

    /// Upside-down U. `open` 0…0.4 lifts it, 0.35…1 slides it right and shortens the right leg;
    /// values below 0 (spring overshoot) push it into the body for the closing "click".
    private struct Shackle: Shape {
        var open: Double
        var animatableData: Double {
            get { open }
            set { open = newValue }
        }

        func path(in r: CGRect) -> Path {
            let body = PadlockGlyph.bodyRect(in: r)
            let b = body.width
            let lift = CGFloat(min(1, max(-0.3, open / 0.4)))
            let slide = CGFloat(max(0, (open - 0.35) / 0.65))
            let width = 0.64 * b
            let radius = width / 2
            let left = body.midX - radius + slide * width
            let arcY = body.minY - 0.1 * b - 0.2 * b * lift
            let leftEnd = body.minY + 0.25 * b
            let rightEnd = body.minY + 0.25 * b - min(1, slide) * 0.33 * b

            var p = Path()
            p.move(to: CGPoint(x: left, y: leftEnd))
            p.addLine(to: CGPoint(x: left, y: arcY))
            p.addArc(center: CGPoint(x: left + radius, y: arcY), radius: radius,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: left + width, y: max(arcY, rightEnd)))
            return p
        }
    }
}

/// Notch-shaped pill with the padlock on its left, shown above the lock screen.
struct PadlockPillView: View {
    static let sideWidth: CGFloat = 36
    private let controller = LockScreenController.shared
    private let settings = SettingsStore.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Starts at the physical notch width and slides out on every lock; the padlock follows.
    @State private var grown = false
    @State private var glyphShown = false

    var body: some View {
        GeometryReader { g in
            let shape = NotchShape(topRadius: 6, bottomRadius: 10)
            shape
                .fill(Color.black)
                .overlay(alignment: .leading) {
                    if glyphShown {
                        PadlockGlyph(locking: true, tint: settings.lockPadlockTint, animated: settings.lockAnimation)
                            .frame(width: Self.sideWidth)
                            .padding(.leading, 6)
                            .id(controller.lockCount)
                            .transition(.blurFade)
                    }
                }
                .clipShape(shape)
                .frame(width: grown ? g.size.width : g.size.width - Self.sideWidth * 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .task(id: controller.lockCount) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { grown = false; glyphShown = false }
            try? await Task.sleep(for: .seconds(0.25)) // let the lock screen finish appearing
            withAnimation(ActivityCenter.revealAnimation(reduceMotion: reduceMotion)) { grown = true }
            try? await Task.sleep(for: .seconds(ActivityCenter.revealDuration * 0.65))
            glyphShown = true
        }
    }
}

/// Volume / brightness flash in the closed notch on the lock screen: the same shape, widths and
/// `CollapsedSidesView` as the unlocked notch. Clear while idle (its window ignores the mouse).
struct LockScreenHUDView: View {
    let model: NotchModel
    private let activities = ActivityCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Flush with the top centre; wide enough for the widened notch.
    static func windowFrame(on screen: NSScreen) -> CGRect {
        let n = screen.notchSize
        let w = n.width + NotchModel.overlap * 2 + NotchModel.hudSideWidth * 2
        return screen.topCentered(CGSize(width: w, height: n.height + NotchModel.overlap + 1))
    }

    private var visible: Bool {
        if case .hud = activities.flash { true } else { false }
    }

    var body: some View {
        let shape = NotchShape(topRadius: 6, bottomRadius: 10)
        // Reduce Motion: the notch keeps its width and only fades.
        let wide = visible || reduceMotion
        shape
            .fill(Color.black)
            .overlay {
                if visible {
                    CollapsedSidesView(model: model)
                        .id(activities.flashID)
                        .transition(.blurFade)
                }
            }
            .clipShape(shape)
            .frame(width: model.plainSize.width + (wide ? NotchModel.hudSideWidth * 2 : 0),
                   height: model.sidesSize.height)
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Same curves as the unlocked notch's resize.
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.34), value: visible)
            .ignoresSafeArea()
    }
}
