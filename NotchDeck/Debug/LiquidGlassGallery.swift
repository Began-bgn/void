#if DEBUG
import SwiftUI
import AppKit

/// Liquid Glass catalogue. Page 0: core parts in every look (light, dark, tinted, Reduce
/// Transparency, Increase Contrast, bright/dark/saturated backdrops). Page 1: every component.
/// `open Void.app --args -LiquidGlassGallery -LiquidGlassGalleryPage 1`, or the previews below.
struct LiquidGlassGallery: View {
    var page = UserDefaults.standard.integer(forKey: "LiquidGlassGalleryPage")

    var body: some View {
        if page == 1 { GalleryComponents() } else { GalleryStates() }
    }

    @MainActor static func open() {
        let host = NSHostingView(rootView: LiquidGlassGallery())
        let size = host.fittingSize
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Fixed spot (40 pt from the top-left of the main screen) so it can be screenshotted.
        let screen = NSScreen.main?.frame ?? .zero
        window.setFrame(CGRect(x: screen.minX + 40, y: screen.maxY - 40 - size.height, width: size.width, height: size.height), display: true)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        gallery = window
    }
    @MainActor private static var gallery: NSWindow?
}

// MARK: - Backdrops

private enum Backdrop {
    case bright, dark, saturated

    var colors: [Color] {
        switch self {
        case .bright: [Color(white: 0.97), Color(red: 0.85, green: 0.9, blue: 1)]
        case .dark: [Color(white: 0.05), Color(red: 0.1, green: 0.1, blue: 0.2)]
        case .saturated: [Color(red: 0.1, green: 0.2, blue: 0.85), Color(red: 0.55, green: 0.1, blue: 0.7)]
        }
    }

    /// Gradient plus bright diagonal bands, so refraction at glass edges is visible.
    var view: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(0..<8) { i in
                Capsule().fill(.white.opacity(0.35))
                    .frame(width: 34, height: 1400)
                    .rotationEffect(.degrees(30))
                    .offset(x: CGFloat(i) * 120 - 420)
            }
        }
        .clipped()
    }
}

// MARK: - Page 0: states

private struct GalleryStates: View {
    private struct Look: Identifiable {
        let id: String
        let backdrop: Backdrop
        let scheme: ColorScheme
        var forced = LGAccessibility()
        var tint: Color?
    }

    private let looks = [
        Look(id: "Light · bright", backdrop: .bright, scheme: .light),
        Look(id: "Dark · bright", backdrop: .bright, scheme: .dark),
        Look(id: "Dark · dark", backdrop: .dark, scheme: .dark),
        Look(id: "Tinted · saturated", backdrop: .saturated, scheme: .dark, tint: .orange),
        Look(id: "Reduce Transparency", backdrop: .saturated, scheme: .dark, forced: .init(reduceTransparency: true)),
        Look(id: "Increase Contrast", backdrop: .bright, scheme: .dark, forced: .init(increaseContrast: true)),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(looks) { look in
                StateColumn(title: look.id, tint: look.tint)
                    .padding(LG.Space.m)
                    .frame(width: 230)
                    .background { look.backdrop.view }
                    .environment(\.colorScheme, look.scheme)
                    .environment(\.lgForced, look.forced)
            }
        }
    }
}

private struct StateColumn: View {
    let title: String
    let tint: Color?
    @State private var on = true
    @State private var mode = 0

    var body: some View {
        VStack(spacing: LG.Space.m) {
            Text(title).font(LG.Font.caption).foregroundStyle(Color.gray)
            GlassCard(title: "Card", tint: tint) { Text("Regular glass").font(LG.Font.body) }
            GlassCard(title: "Media", variant: .clear, tint: tint) { Text("Clear glass").font(LG.Font.body) }
            HStack(spacing: LG.Space.xs) {
                GlassButton(systemImage: "backward.fill", label: "Previous") {}
                GlassButton(title: "Play", systemImage: "play.fill", prominent: true, tint: tint) {}
            }
            GlassCard {
                VStack(spacing: LG.Space.s) {
                    Toggle("Toggle", isOn: $on).toggleStyle(GlassToggleStyle()).font(LG.Font.body)
                    GlassSegmentedPicker(selection: $mode, options: [(0, "Notch"), (1, "Widget")])
                    GlassSlider(value: 44, duration: 231) { _ in }
                }
            }
        }
    }
}

// MARK: - Page 1: components

private struct GalleryComponents: View {
    @State private var playing = true
    @State private var shuffle = true
    @State private var stepper = 3
    @State private var chip = 0

    private var info: NowPlayingInfo {
        NowPlayingInfo(title: "All The Stars (with SZA)", artist: "Kendrick Lamar", artwork: Self.artwork,
                       duration: 231, isPlaying: playing, elapsed: { _ in 44 }, tint: .indigo)
    }

    var body: some View {
        HStack(alignment: .top, spacing: LG.Space.xl) {
            // Players
            VStack(alignment: .leading, spacing: LG.Space.l) {
                label("Now Playing · lock screen")
                NowPlayingCard(info: info, actions: .init(playPause: { playing.toggle() })) {
                    VisualizerBars(isPlaying: playing, color: .white)
                } leading: {
                    Image(systemName: "shuffle").font(.system(size: 15, weight: .semibold))
                } trailing: {
                    Image(systemName: "headphones").font(.system(size: 16, weight: .semibold))
                }
                .frame(width: 350)
                label("Now Playing · desktop")
                NowPlayingCard(info: info, size: .desktop) { VisualizerBars(isPlaying: playing, color: .white) }
                    .frame(width: 330)
                label("Now Playing · notch (no glass)")
                NowPlayingCard(info: info, size: .notch) { VisualizerBars(isPlaying: playing, color: .white) }
                    .frame(width: 350)
                    .background(.black, in: RoundedRectangle(cornerRadius: LG.Radius.card, style: .continuous))
            }
            .frame(width: 350)

            // HUDs, transport, chips, alert
            VStack(alignment: .leading, spacing: LG.Space.l) {
                label("HUD pills")
                GlassHUD(item: .init(symbol: "speaker.wave.2.fill", title: "Volume", level: 0.6))
                GlassHUD(item: .init(symbol: "sun.max.fill", title: "Brightness", level: 0.85))
                GlassHUD(item: .init(symbol: "battery.100.bolt", title: "Charging", detail: "82%"))
                GlassHUD(item: .init(symbol: "airpods.pro", title: "AirPods Pro", detail: "L 90% · R 85%"))
                label("Transport (morphing glass group)")
                TransportControls(isPlaying: playing, glass: true, previous: {}, playPause: { playing.toggle() }, next: {})
                label("Chips and badges")
                HStack(spacing: LG.Space.xs) {
                    GlassChip(title: "Music", systemImage: "music.note", selected: chip == 0) { chip = 0 }
                    GlassChip(title: "Shelf", selected: chip == 1) { chip = 1 }
                    GlassBadge(count: 3)
                    GlassBadge()
                }
                label("Alert")
                GlassAlert(title: "Clear the shelf?", message: "This removes 4 files from the shelf.", actionTitle: "Clear", destructive: true)
            }
            .frame(width: 320)

            // Settings
            VStack(alignment: .leading, spacing: LG.Space.l) {
                label("Settings")
                HStack(alignment: .top, spacing: LG.Space.s) {
                    VStack(spacing: 2) {
                        GlassSidebarRow(title: "General", systemImage: "gearshape.fill", color: .gray, selected: true)
                        GlassSidebarRow(title: "Notch", systemImage: "rectangle.topthird.inset.filled", color: .blue)
                        GlassSidebarRow(title: "Lock Screen", systemImage: "lock.fill", color: .indigo)
                        GlassSidebarRow(title: "Widgets", systemImage: "square.grid.2x2.fill", color: .orange)
                    }
                    .frame(width: 150)
                    VStack(alignment: .leading, spacing: LG.Space.xs) {
                        GlassSectionHeader(title: "Playback")
                        GlassSettingsRow(title: "Shuffle", help: "Applies to Spotify and Music.") {
                            Toggle("", isOn: $shuffle).toggleStyle(GlassToggleStyle()).labelsHidden()
                        }
                        GlassSettingsRow(title: "Bars", onReset: { stepper = 3 }) {
                            GlassStepper(label: "Bars", value: $stepper, range: 1...8)
                        }
                        GlassSectionHeader(title: "Recent").padding(.top, LG.Space.xs)
                        GlassListRow(title: "Downloads", subtitle: "4 items", systemImage: "arrow.down.circle") { GlassBadge(count: 4) }
                        GlassListRow(title: "Screenshots", systemImage: "camera.viewfinder")
                    }
                    .padding(LG.Space.s)
                    .frame(width: 260)
                    // Flat content background: glass is for controls, never the whole content area.
                    .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: LG.Radius.control, style: .continuous))
                }
                label("Empty state")
                GlassCard {
                    GlassEmptyState(systemImage: "tray", title: "Shelf is empty", message: "Drop files on the notch to keep them here.",
                                    actionTitle: "Open Finder")
                }
                .frame(width: 420)
            }
        }
        .padding(LG.Space.xl)
        .background { Backdrop.saturated.view }
        .environment(\.colorScheme, .dark)
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(LG.Font.caption).foregroundStyle(.white.opacity(0.75))
    }

    /// Stand-in album cover.
    @MainActor private static let artwork: NSImage? = {
        let view = ZStack {
            LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "star.fill").font(.system(size: 60)).foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 128, height: 128)
        let r = ImageRenderer(content: view)
        r.scale = 2
        return r.nsImage
    }()
}

#Preview("States") { LiquidGlassGallery(page: 0) }
#Preview("Components") { LiquidGlassGallery(page: 1) }
#endif
