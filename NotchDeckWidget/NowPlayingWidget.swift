import WidgetKit
import SwiftUI
import AppIntents

@main
struct NotchDeckWidgets: WidgetBundle {
    var body: some Widget { NowPlayingWidget() }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.kind, provider: Provider()) { NowPlayingView(entry: $0) }
            .configurationDisplayName("Now Playing")
            .description("What's playing in Spotify or Apple Music, with playback controls.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Timeline

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: WidgetNowPlaying?
    let artwork: NSImage?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, state: WidgetNowPlaying(title: "Song Title", artist: "Artist", source: "Music",
                                                             isPlaying: false, position: 72, duration: 214, capturedAt: .now),
                        artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let entry = load()
        completion(context.isPreview && entry.state == nil ? placeholder(in: context) : entry)
    }

    /// The app reloads the timeline on every track or play-state change. While playing, also
    /// reload when the track should end, so the bar never sits full on a finished song.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = load()
        let end = entry.state.flatMap { s in
            s.isPlaying && s.duration > 0 ? s.startDate.addingTimeInterval(s.duration + 1) : nil
        }
        completion(Timeline(entries: [entry], policy: end.map { .after($0) } ?? .never))
    }

    private func load() -> NowPlayingEntry {
        let state = WidgetShared.stateURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(WidgetNowPlaying?.self, from: $0) } ?? nil
        let artwork = state == nil ? nil : WidgetShared.artworkURL.flatMap { NSImage(contentsOf: $0) }
        return NowPlayingEntry(date: .now, state: state, artwork: artwork)
    }
}

// MARK: - Buttons

/// Runs in the sandboxed extension, which can't script the music apps: it hands the command to
/// NotchDeck (which must be running) as a Darwin notification.
struct PlaybackCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Playback"
    static let isDiscoverable = false

    @Parameter(title: "Command") var command: String

    init() {}
    init(_ command: WidgetShared.Command) { self.command = command.rawValue }

    /// The widget reloads as soon as this returns, so wait (up to 2 s) for NotchDeck to write the
    /// new state: the reload then shows it straight away instead of a later, throttled one. Next
    /// waits for the new title, not just any write (the old track's position reset can come first).
    func perform() async throws -> some IntentResult {
        guard let c = WidgetShared.Command(rawValue: command) else { return .result() }
        let before = Self.read()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(c.notification as CFString), nil, nil, true)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = Self.read()
            if c == .next ? now?.title != before?.title || now?.artist != before?.artist : now != before { break }
        }
        return .result()
    }

    private static func read() -> WidgetNowPlaying? {
        WidgetShared.stateURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(WidgetNowPlaying?.self, from: $0) } ?? nil
    }
}

// MARK: - Views

/// Minimal, Apple Now Playing style: cover and titles, one progress row, bare glyph buttons.
/// Background is a low-saturation artwork colour; the system adds real glass in its clear and
/// tinted widget styles, and flattens it in accented/vibrant mode. No custom blur (the system
/// would flatten it, and it fights the system material).
struct NowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: NowPlayingEntry

    private var tint: Color {
        guard let rgb = entry.state?.tint, rgb.count == 3 else { return Color(white: 0.35) }
        return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    var body: some View {
        Group {
            if let s = entry.state { player(s) } else { empty }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { background }
        .environment(\.colorScheme, .dark) // white text; GlassScrim darkens
    }

    @ViewBuilder private var background: some View {
        if renderingMode == .fullColor {
            let accent = LG.accent(from: tint)
            LinearGradient(colors: [accent.opacity(0.75), accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { GlassScrim() } // white text stays above 4.5:1 on light covers
        } else {
            Color.clear // accented / vibrant: the system draws the material
        }
    }

    @ViewBuilder private func player(_ s: WidgetNowPlaying) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    cover(size: 40)
                    titles(s, size: 12)
                }
                Spacer(minLength: 6)
                progress(s, times: false)
                Spacer(minLength: 6)
                controls(s, size: 16)
            }
        case .systemLarge:
            VStack(alignment: .leading, spacing: 0) {
                cover(size: 150).frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                titles(s, size: 17)
                Spacer(minLength: 12)
                progress(s, times: true)
                Spacer(minLength: 12)
                controls(s, size: 26)
            }
        default:
            // Full-height cover on the left; titles, bar and buttons stacked beside it.
            HStack(spacing: 14) {
                GeometryReader { cover(size: $0.size.height) }
                    .aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 0) {
                    titles(s, size: 14)
                    Spacer(minLength: 6)
                    progress(s, times: true)
                    Spacer(minLength: 6)
                    controls(s, size: 20)
                }
            }
        }
    }

    private func cover(size: CGFloat) -> some View {
        Group {
            if let image = entry.artwork, renderingMode == .fullColor {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let image = entry.artwork {
                // Desktop widgets go vibrant (monochrome) while a window is in front; an opaque
                // cover then renders as a flat grey block. Brightness → alpha keeps the artwork readable.
                Image(nsImage: image).resizable().scaledToFill().luminanceToAlpha()
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .accessibilityHidden(true)
    }

    private func titles(_ s: WidgetNowPlaying, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(s.title).font(.system(size: size, weight: .semibold)).lineLimit(1)
            Text(s.artist).font(.system(size: size - 1)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
    }

    /// One fixed-height row (elapsed · bar · remaining). The bar is the same timer-driven view
    /// playing or paused (paused = a years-long interval, so it sits still): two different progress
    /// views drew their bars at different heights, which made it jump on play/pause.
    private func progress(_ s: WidgetNowPlaying, times: Bool) -> some View {
        let end = s.startDate.addingTimeInterval(s.duration)
        let range: ClosedRange<Date>
        if s.isPlaying, s.duration > 0 {
            range = s.startDate...end
        } else {
            let frozen: TimeInterval = 100_000_000
            let start = Date.now.addingTimeInterval(-(s.duration > 0 ? s.elapsed() / s.duration : 0) * frozen)
            range = start...start.addingTimeInterval(frozen)
        }
        return HStack(spacing: 8) {
            if times {
                Group {
                    if s.isPlaying { Text(s.startDate, style: .timer) } else { Text(formatTime(s.elapsed())) }
                }
                // Live timer text spans its frame and centres by default; pin it to the same edge as the paused text.
                .multilineTextAlignment(.leading)
                .frame(width: 34, alignment: .leading)
            }
            ProgressView(timerInterval: range, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .labelsHidden()
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(.white.opacity(0.9))
            .frame(height: 4)
            if times {
                Group {
                    if s.isPlaying { Text("-\(Text(end, style: .timer))") } else { Text("-" + formatTime(s.duration - s.elapsed())) }
                }
                .multilineTextAlignment(.trailing)
                .frame(width: 38, alignment: .trailing)
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
        .frame(height: 14)
    }

    /// Bare glyphs, play/pause the largest. Fixed frames, so swapping play ↔ pause shifts nothing.
    private func controls(_ s: WidgetNowPlaying, size: CGFloat) -> some View {
        HStack(spacing: size * 1.2) {
            button(.previous, symbol: "backward.fill", label: "Previous", size: size * 0.78)
            button(.playPause, symbol: s.isPlaying ? "pause.fill" : "play.fill", label: s.isPlaying ? "Pause" : "Play", size: size * 1.1)
            button(.next, symbol: "forward.fill", label: "Next", size: size * 0.78)
        }
        .frame(maxWidth: .infinity)
    }

    private func button(_ command: WidgetShared.Command, symbol: String, label: String, size: CGFloat) -> some View {
        Button(intent: PlaybackCommandIntent(command)) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .frame(width: size * 1.6, height: size * 1.3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.6))
            Text("Nothing playing").font(.system(size: 12, weight: .medium))
            Text("Play something in Spotify or Music.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
