import SwiftUI
import AppKit

// MARK: - Transport

/// Previous / play-pause / next. `glass: true` puts them in one glass container where the play
/// button morphs between states; `false` (inside a card) keeps them bare: no glass on glass.
struct TransportControls: View {
    let isPlaying: Bool
    var glass = false
    var size: CGFloat = 1
    let previous: () -> Void
    let playPause: () -> Void
    let next: () -> Void

    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        group {
            HStack(spacing: glass ? LG.Space.xs : LG.Space.xl) {
                button("backward.fill", 20, "Previous track", "prev", previous)
                button(isPlaying ? "pause.fill" : "play.fill", 30, isPlaying ? "Pause" : "Play", "play", playPause)
                button("forward.fill", 20, "Next track", "next", next)
            }
        }
        .animation(LG.Motion.morph(reduceMotion: reduceMotion), value: isPlaying)
    }

    @ViewBuilder private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if glass, #available(macOS 26, *) { GlassEffectContainer(spacing: LG.Space.xs) { c() } } else { c() }
    }

    @ViewBuilder
    private func button(_ symbol: String, _ pt: CGFloat, _ label: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        let b = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: pt * size, weight: .semibold))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(width: 44 * max(size, 1), height: 44 * max(size, 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        if glass {
            if #available(macOS 26, *) {
                b.glassEffect(.regular.interactive(), in: Circle()).glassEffectID(id, in: ns)
            } else {
                b.liquidGlass(.regular, in: Circle(), interactive: true)
            }
        } else {
            b
        }
    }
}

/// Bare control press feedback: scale + dim.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? LG.Motion.pressScale : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(LG.Motion.ui, value: configuration.isPressed)
    }
}

// MARK: - Now Playing

/// What a Now Playing card shows. Plain values so the app and the widget can both build one.
struct NowPlayingInfo {
    var title: String
    var artist: String
    var artwork: NSImage?
    var duration: Double
    var isPlaying: Bool
    /// Elapsed seconds at a given time (playback keeps moving between updates).
    var elapsed: (Date) -> Double
    var tint: Color?
}

struct NowPlayingActions {
    var previous: () -> Void = {}
    var playPause: () -> Void = {}
    var next: () -> Void = {}
    var seek: (Double) -> Void = { _ in }
}

/// Cover, title/artist, audio bars, progress, transport. `.lockScreen` and `.desktop` float on
/// untinted clear glass; `.notch` draws no glass (the notch stays black).
struct NowPlayingCard<Bars: View, Leading: View, Trailing: View>: View {
    enum Size { case notch, desktop, lockScreen }

    let info: NowPlayingInfo
    var size: Size = .lockScreen
    var actions = NowPlayingActions()
    /// Audio bars beside the title (the app passes its visualizer).
    @ViewBuilder var bars: Bars
    /// Optional slots beside the transport (shuffle, output, favourite).
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: LG.Radius.card, style: .continuous) }
    private var cover: CGFloat { size == .desktop ? 52 : 64 }

    var body: some View {
        let content = VStack(spacing: size == .desktop ? LG.Space.s : LG.Space.m) {
            header
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                GlassSlider(value: info.elapsed(ctx.date), duration: info.duration, onSeek: actions.seek)
            }
            HStack(spacing: 0) {
                leading.frame(width: 44)
                Spacer(minLength: 0)
                TransportControls(isPlaying: info.isPlaying, size: size == .desktop ? 0.85 : 1,
                                  previous: actions.previous, playPause: actions.playPause, next: actions.next)
                Spacer(minLength: 0)
                trailing.frame(width: 44)
            }
        }
        .padding(.horizontal, LG.Space.l).padding(.vertical, LG.Space.m)
        .foregroundStyle(LG.Tone.primary)

        if size == .notch {
            content
        } else {
            content
                .liquidGlass(.clear, in: shape) // untinted, no scrim: the backdrop shows through
                .elevation(.floating)
                .environment(\.colorScheme, .dark) // media card: white text
        }
    }

    private var header: some View {
        HStack(spacing: LG.Space.s) {
            Group {
                if let art = info.artwork { Image(nsImage: art).resizable().scaledToFill() }
                else { Color.primary.opacity(0.15).overlay { Image(systemName: "music.note") } }
            }
            .frame(width: cover, height: cover)
            .clipShape(RoundedRectangle(cornerRadius: LG.Radius.small, style: .continuous))
            .elevation(.rest)
            .opacity(info.isPlaying ? 1 : 0.6)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(LG.Font.headline).lineLimit(1)
                Text(info.artist).font(LG.Font.body).foregroundStyle(LG.Tone.secondary).lineLimit(1)
            }
            Spacer(minLength: LG.Space.xs)
            bars.frame(width: 18, height: 14).foregroundStyle(LG.Tone.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension NowPlayingCard where Leading == EmptyView, Trailing == EmptyView {
    init(info: NowPlayingInfo, size: Size = .lockScreen, actions: NowPlayingActions = .init(), @ViewBuilder bars: () -> Bars) {
        self.init(info: info, size: size, actions: actions, bars: bars, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

// MARK: - HUD pill

/// Capsule HUD for volume, brightness, battery, AirPods. Present with `.glassHUD(_:)`.
struct GlassHUDItem: Equatable, Identifiable {
    let id = UUID()
    var symbol: String
    var title: String
    /// 0…1 shows a level bar; nil shows `detail` text instead.
    var level: Double?
    var detail: String?
}

struct GlassHUD: View {
    let item: GlassHUDItem

    var body: some View {
        HStack(spacing: LG.Space.s) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            if let level = item.level {
                Capsule().fill(Color.primary.opacity(0.2))
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(Color.primary).frame(width: max(6, g.size.width * level)) }
                    }
                    .clipShape(Capsule())
                    .frame(width: 120, height: 6)
                    .animation(LG.Motion.ui, value: level)
            } else {
                Text(item.title).font(LG.Font.body.weight(.semibold))
                if let detail = item.detail { Text(detail).font(LG.Font.numeric).foregroundStyle(LG.Tone.secondary) }
            }
        }
        .padding(.horizontal, LG.Space.m)
        .frame(height: 44)
        .background { GlassScrim().clipShape(Capsule()) }
        .liquidGlass(.regular, in: Capsule())
        .elevation(.floating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.level.map { "\(Int(($0 * 100).rounded()))%" } ?? item.detail ?? "")
    }
}

extension View {
    /// Shows `item` as a HUD pill at the top, springs in and out, dismisses after 3 s.
    func glassHUD(_ item: Binding<GlassHUDItem?>) -> some View {
        modifier(GlassHUDPresenter(item: item))
    }
}

private struct GlassHUDPresenter: ViewModifier {
    @Binding var item: GlassHUDItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let current = item {
                GlassHUD(item: current)
                    .padding(.top, LG.Space.s)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .task(id: current.id) {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        item = nil
                    }
            }
        }
        .animation(LG.Motion.morph(reduceMotion: reduceMotion), value: item)
    }
}
