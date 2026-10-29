import SwiftUI

struct MusicPageView: View {
    private let store = MusicStore.shared
    private let settings = SettingsStore.shared

    var body: some View {
        if let snap = store.active {
            PlayerView(snap: snap, store: store, tint: settings.tint(store.tint))
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("Nothing playing").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach(MusicSource.allCases, id: \.self) { source in
                    Button("Open \(source.displayName)") { store.open(source) }
                        .controlSize(.small)
                        .disabled(NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) == nil)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PlayerView: View {
    let snap: MusicSnapshot
    let store: MusicStore
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                progress
                controls
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .environment(\.colorScheme, .dark) // black notch: kit colours resolve to white
    }

    // MARK: Pieces

    private var cover: some View {
        ZStack {
            if let image = store.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.12).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: LG.Radius.small, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let icon = store.appIcon(for: snap.source) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16).padding(4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Album art, \(snap.source.displayName)")
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: snap.title.isEmpty ? "Unknown" : snap.title, font: LG.Font.body.weight(.semibold))
                MarqueeText(text: snap.artist, font: LG.Font.caption, color: LG.Tone.secondary)
            }
            if let fav = snap.isFavorite {
                Button { store.toggleFavorite() } label: {
                    Image(systemName: fav ? "heart.fill" : "heart").foregroundStyle(fav ? tint : .white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(fav ? "Remove from favourites" : "Add to favourites")
            }
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: snap.state == .playing ? 0.25 : 60)) { ctx in
            GlassSlider(value: snap.elapsed(at: ctx.date), duration: snap.duration, fill: tint, trackHeight: 8) { store.seek(to: $0) }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            toggle("shuffle", on: snap.shuffle, label: "Shuffle") { store.toggleShuffle() }
            Spacer(minLength: 0)
            TransportControls(isPlaying: snap.state == .playing, size: 0.7,
                              previous: { store.previous() }, playPause: { store.playPause() }, next: { store.next() })
            Spacer(minLength: 0)
            toggle("repeat", on: snap.repeating, label: "Repeat") { store.toggleRepeat() }
        }
    }

    private func toggle(_ symbol: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? tint : LG.Tone.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
    }
}
