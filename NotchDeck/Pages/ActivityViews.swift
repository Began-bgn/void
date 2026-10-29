import SwiftUI

/// Pop-up content: sits below the physical notch.
struct ActivityPopupView: View {
    let popup: ActivityPopup
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 10) {
                Image(systemName: popup.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(popup.color)
                    .symbolEffect(.pulse, isActive: popup.pulse)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(popup.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if let subtitle = popup.subtitle {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
                if let trailing = popup.trailing {
                    Text(trailing).font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(popup.trailingColor)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { ActivityCenter.shared.tap() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Side areas of the collapsed notch: flash > live activity (+ music) > music > Focus badge.
struct CollapsedSidesView: View {
    let model: NotchModel
    private let activities = ActivityCenter.shared
    private let music = MusicStore.shared
    private let settings = SettingsStore.shared
    private let timer = TimerModel.shared
    private let feedback = PlayPauseFeedback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { settings.tint(music.tint) }
    private var item: CGFloat { model.notchSize.height - 10 }

    var body: some View {
        let width = model.sideWidth - 14
        HStack(spacing: 0) {
            left.frame(width: width, height: item, alignment: .leading)
            Spacer(minLength: model.notchSize.width)
            right.frame(width: width, height: item, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    // MARK: Left

    @ViewBuilder private var left: some View {
        if let flash = activities.flash {
            switch flash {
            case .battery(_, let title, _, _):
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
            case .hud(let kind, let level):
                let symbol = Self.hudSymbol(kind, level)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.25), value: symbol)
                    // Speaker knocks down when the sound goes mute.
                    .symbolEffect(.bounce.down, options: .nonRepeating, value: reduceMotion ? false : Self.isMute(kind, level))
                    .frame(width: item, height: item)
                    .accessibilityHidden(true)
            case .focus(let on):
                Image(systemName: on ? "moon.fill" : "moon")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                    .symbolEffect(.bounce, options: .nonRepeating, value: on)
                    .frame(width: item, height: item)
                    .accessibilityLabel(on ? "Focus on" : "Focus off")
            case .lock(let locked):
                PadlockGlyph(locking: locked, tint: settings.lockPadlockTint, animated: settings.lockAnimation)
                    .frame(width: item, height: item)
            }
        } else if activities.live == .timer, music.active != nil {
            HStack(spacing: 6) { cover; bars }
        } else {
            switch activities.live {
            case .timer:
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.clockOrange)
                    .frame(width: item, height: item)
                    .accessibilityHidden(true)
            case nil:
                if music.active != nil {
                    cover
                } else if FocusMonitor.shared.isFocused {
                    Image(systemName: "moon.fill").font(.system(size: 13)).foregroundStyle(.indigo)
                        .frame(width: item, height: item)
                        .accessibilityLabel("Focus on")
                }
            }
        }
    }

    // MARK: Right

    @ViewBuilder private var right: some View {
        if let flash = activities.flash {
            switch flash {
            case .battery(let percent, _, let color, let glyph):
                HStack(spacing: 7) {
                    Text("\(percent)%")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                    BatteryIcon(fraction: Double(percent) / 100, color: color, glyph: glyph)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Battery \(percent)%")
            case .focus(let on):
                Text(on ? "On" : "Off")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                    .accessibilityHidden(true)
            case .lock:
                EmptyView()
            case .hud(let kind, let level):
                let muted = Self.isMute(kind, level)
                Group {
                    if muted {
                        Text("Muted")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .transition(reduceMotion ? .opacity : .blurFade)
                            .accessibilityLabel("Volume, muted")
                    } else {
                        Capsule().fill(.white.opacity(0.2))
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(.white)
                                        .frame(width: max(6, g.size.width * level))
                                }
                            }
                            .clipShape(Capsule())
                            .frame(height: 6)
                            // Springs to the new level; Reduce Motion: no spring.
                            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: level)
                            .transition(reduceMotion ? .opacity : .blurFade)
                            .accessibilityElement()
                            .accessibilityLabel(Self.hudName(kind))
                            .accessibilityValue("\(Int((level * 100).rounded()))%")
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3), value: muted)
            }
        } else if activities.live == .timer, music.active != nil {
            timerText
        } else {
            switch activities.live {
            case .timer:
                timerText
            case nil:
                if music.active != nil { bars }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var cover: some View {
        if let snap = music.active {
            Group {
                if let image = music.artwork { Image(nsImage: image).resizable().scaledToFill() } else { Color.white.opacity(0.15) }
            }
            .frame(width: item, height: item)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .offset(x: model.nudge)
            .accessibilityLabel("Now playing: \(snap.title) by \(snap.artist)")
        }
    }

    @ViewBuilder private var bars: some View {
        if let snap = music.active, settings.visualizerEnabled {
            ZStack {
                if let symbol = feedback.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                        .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : feedback.clicks)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                } else {
                    // Artwork tint, softened like the iPhone waveform.
                    VisualizerBars(isPlaying: snap.state == .playing, color: tint.opacity(0.8)).transition(.opacity)
                }
            }
            .frame(minWidth: item, minHeight: item, maxHeight: item)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.25, dampingFraction: 0.7),
                       value: feedback.symbol)
        }
    }

    /// Remaining time in Clock orange; digits roll like the Clock app.
    private var timerText: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let remaining = timer.state.display(at: ctx.date)
            Text(formatTime(remaining))
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.clockOrange)
                .contentTransition(.numericText(countsDown: timer.state.target != nil))
                .animation(.smooth(duration: 0.35), value: Int(remaining))
                .lineLimit(1).fixedSize()
        }
        .accessibilityLabel("Timer")
    }

    static func hudSymbol(_ kind: HUDKind, _ level: Double) -> String {
        switch kind {
        case .volume(let muted):
            if muted || level == 0 { return "speaker.slash.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness: return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard: return level == 0 ? "light.min" : "light.max"
        }
    }

    /// Mute key, or volume turned all the way down.
    static func isMute(_ kind: HUDKind, _ level: Double) -> Bool {
        if case .volume(let muted) = kind { return muted || level == 0 }
        return false
    }

    static func hudName(_ kind: HUDKind) -> String {
        switch kind {
        case .volume(let muted): muted ? "Volume, muted" : "Volume"
        case .brightness: "Brightness"
        case .keyboard: "Keyboard brightness"
        }
    }
}

/// macOS menu-bar style battery: outlined body, coloured fill, cap, optional bolt/plug glyph.
struct BatteryIcon: View {
    let fraction: Double
    let color: Color
    let glyph: String?
    /// Drawn inside the battery instead of a glyph (the level, without "%").
    var text: String?

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1.2)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(color)
                        .frame(width: max(3, g.size.width * min(max(fraction, 0), 1)))
                }
                .padding(2.2)
            }
            .frame(width: 28, height: 14)
            .overlay {
                if let text {
                    Text(text)
                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 0.6)
                } else if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 0.6)
                }
            }
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.5)).frame(width: 1.5, height: 5)
        }
        .accessibilityHidden(true)
    }
}

private struct BlurFade: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content.blur(radius: hidden ? 10 : 0).opacity(hidden ? 0 : 1)
    }
}

extension AnyTransition {
    /// iPhone Dynamic Island content: blurs in and out.
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(hidden: true), identity: BlurFade(hidden: false))
            .animation(.easeInOut(duration: 0.3))
    }
}
