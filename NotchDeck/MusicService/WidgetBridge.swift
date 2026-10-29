import AppKit
import SwiftUI
import WidgetKit
import os

/// Feeds the desktop widget (state file + artwork in the App Group container) and runs its buttons.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    /// Outer nil = nothing written yet.
    private var last: WidgetNowPlaying??
    private var lastArtwork: NSImage?
    private let log = Logger(subsystem: "com.notchdeck.app", category: "widget")

    private init() {}

    func start() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in WidgetShared.Command.allCases {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let raw = name?.rawValue as String?,
                      let command = WidgetShared.Command.allCases.first(where: { $0.notification == raw }) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { WidgetBridge.run(command) } }
            }, command.notification as CFString, nil, .deliverImmediately)
        }
        observe()
        push()
    }

    private static func run(_ command: WidgetShared.Command) {
        let music = MusicStore.shared
        switch command {
        case .previous: music.previous()
        case .playPause: music.playPause()
        case .next: music.next()
        }
    }

    /// Re-arms itself: observation fires once per change.
    private func observe() {
        let music = MusicStore.shared
        withObservationTracking {
            _ = (music.active, music.artwork, music.tint)
        } onChange: {
            Task { @MainActor in
                WidgetBridge.shared.observe()
                WidgetBridge.shared.push()
            }
        }
    }

    /// chronod runs at most one app-requested reload per 5 s while the widget is visible; a second
    /// one waits out the window (that was the ~3 s lag after a skip). A skip lands as several
    /// changes (old track reset, new title, then its cover), so let them settle and send one reload.
    private var flushTask: Task<Void, Never>?

    private func push() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            // A new track's cover arrives a moment after its title: wait up to 1 s more for it.
            var waits = 0
            while waits < 10, self?.awaitingArtwork == true {
                try? await Task.sleep(for: .milliseconds(100))
                waits += 1
            }
            self?.flushTask = nil
            self?.flush()
        }
    }

    private var awaitingArtwork: Bool {
        let music = MusicStore.shared
        guard let s = music.active, music.artwork == nil else { return false }
        let previous = last ?? nil
        return s.title != previous?.title || s.artist != previous?.artist
    }

    private func flush() {
        let music = MusicStore.shared
        let (snap, artwork, tint) = (music.active, music.artwork, music.tint)
        let state = snap.map { s in
            WidgetNowPlaying(title: s.title, artist: s.artist, source: s.source.displayName,
                             isPlaying: s.state == .playing, position: s.position, duration: s.duration,
                             capturedAt: s.capturedAt, tint: artwork == nil ? nil : Self.rgb(tint))
        }
        var changed = false
        if artwork !== lastArtwork {
            lastArtwork = artwork
            writeArtwork(artwork)
            changed = true
        }
        if last.map({ !Self.same($0, state) }) ?? true {
            last = .some(state)
            write(state)
            changed = true
        }
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.kind) }
    }

    /// Refreshes that only confirm the expected position don't count (they'd waste widget reloads).
    private static func same(_ a: WidgetNowPlaying?, _ b: WidgetNowPlaying?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.title == b.title && a.artist == b.artist && a.source == b.source && a.isPlaying == b.isPlaying
            && a.duration == b.duration && a.tint == b.tint && abs(a.elapsed() - b.elapsed()) < 0.25
    }

    private func write(_ state: WidgetNowPlaying?) {
        guard let url = WidgetShared.stateURL else { return log.error("No App Group container") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            log.error("Widget state write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Downscaled: the widget never shows it larger than ~180 pt.
    private func writeArtwork(_ image: NSImage?) {
        guard let url = WidgetShared.artworkURL else { return }
        guard let image else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let side: CGFloat = 360
        let small = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        guard let data = pngData(small) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func rgb(_ color: Color) -> [Double] {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
    }
}
