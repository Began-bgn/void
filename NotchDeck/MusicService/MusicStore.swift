import AppKit
import SwiftUI
import Observation
import ImageIO

@MainActor @Observable
final class MusicStore {
    static let shared = MusicStore()

    private(set) var active: MusicSnapshot?
    private(set) var artwork: NSImage?
    private(set) var tint: Color = .white
    private(set) var runningSources: Set<MusicSource> = []

    var hasPlayback: Bool { active != nil }

    @ObservationIgnored private var snapshots: [MusicSource: MusicSnapshot] = [:]
    @ObservationIgnored private let services: [MusicSource: any MusicService] = [
        .spotify: SpotifyService(), .appleMusic: AppleMusicService(),
    ]
    @ObservationIgnored private let settings = SettingsStore.shared
    @ObservationIgnored private let artworkCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var tintCache: [String: Color] = [:]
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var iconCache: [MusicSource: NSImage] = [:]
    /// Bumped by every command; refreshes that began earlier are stale and dropped (stops UI flicker).
    @ObservationIgnored private var epoch = 0
    /// Apps report the old play state for a moment after `playpause`; hold the optimistic one
    /// until the app agrees or the hold expires.
    @ObservationIgnored private var pendingState: (source: MusicSource, state: PlaybackState, until: Date)?
    @ObservationIgnored private var lastVolumeSend: Date = .distantPast
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {}

    // MARK: Lifecycle

    func start() {
        let events: [(String, MusicSource)] = [
            ("com.spotify.client.PlaybackStateChanged", .spotify),
            ("com.apple.Music.playerInfo", .appleMusic),
        ]
        let dnc = DistributedNotificationCenter.default()
        for (name, source) in events {
            observe(dnc, Notification.Name(name)) { [weak self] _ in self?.scheduleRefresh(source) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didLaunchApplicationNotification) { [weak self] s in
            if let s { self?.scheduleRefresh(s) }
        }
        observe(ws, NSWorkspace.didTerminateApplicationNotification) { [weak self] s in
            guard let s else { return }
            self?.snapshots[s] = nil
            self?.recompute()
        }
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { [weak self] _ in self?.recompute() }
        for source in MusicSource.allCases { scheduleRefresh(source) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (MusicSource?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { n in
            let source = Self.source(of: n)
            MainActor.assumeIsolated { body(source) }
        }
        observers.append((center, token))
    }

    private nonisolated static func source(of n: Notification) -> MusicSource? {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return MusicSource(bundleID: app?.bundleIdentifier)
    }

    private func scheduleRefresh(_ source: MusicSource) {
        Task { await refresh(source) }
    }

    /// Re-reads every source; after a music setting changes.
    func reload() { MusicSource.allCases.forEach(scheduleRefresh) }

    func refresh(_ source: MusicSource) async {
        guard settings.isEnabled(source) else { snapshots[source] = nil; recompute(); return }
        guard let service = services[source] else { return }
        let started = epoch
        var snap = await service.snapshot()
        guard started == epoch else { return }
        if let pending = pendingState, pending.source == source, var s = snap {
            if s.state == pending.state || Date.now > pending.until {
                pendingState = nil
            } else {
                s.state = pending.state
                snap = s
            }
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty {
            runningSources.remove(source)
        } else {
            runningSources.insert(source)
        }
        snapshots[source] = snap
        recompute()
    }

    // MARK: Active source

    /// Playing beats paused; ties go to the preferred source.
    private func recompute() {
        let all = Array(snapshots.values)
        let playing = all.filter { $0.state == .playing }
        let pool = playing.isEmpty ? all : playing
        let new = pool.first { $0.source == settings.preferredSource } ?? pool.first

        let oldKey = active.map { "\($0.source.rawValue)|\($0.trackKey)" }
        if active != new { active = new }
        if new.map({ "\($0.source.rawValue)|\($0.trackKey)" }) != oldKey { loadArtwork(for: new) }

        // No audio tap in Low Power Mode: the bars rest then.
        if new?.state == .playing, settings.visualizerEnabled, settings.visualizerRealAudio,
           !ProcessInfo.processInfo.isLowPowerModeEnabled {
            VisualizerEngine.shared.start()
        } else {
            VisualizerEngine.shared.stop()
        }
    }

    // MARK: Artwork

    private func loadArtwork(for snap: MusicSnapshot?) {
        artworkTask?.cancel()
        guard let snap, let service = services[snap.source] else {
            artwork = nil; artworkKey = nil; tint = .white
            return
        }
        let key = "\(snap.source.rawValue)|\(snap.trackKey)"
        artworkKey = key
        if let image = artworkCache.object(forKey: key as NSString) {
            artwork = image; tint = tintCache[key] ?? .white
            return
        }
        artwork = nil; tint = .white
        artworkTask = Task { [weak self] in
            guard let data = await service.artworkData(for: snap), !Task.isCancelled else { return }
            let rgb = await Task.detached { dominantColor(of: data) }.value
            guard let self, self.artworkKey == key, let image = NSImage(data: data) else { return }
            let color = rgb.map { Self.vivid(red: $0.0, green: $0.1, blue: $0.2) } ?? .white
            self.artworkCache.setObject(image, forKey: key as NSString)
            if self.tintCache.count > 100 { self.tintCache.removeAll() }
            self.tintCache[key] = color
            self.artwork = image
            self.tint = color
        }
    }

    /// Lifts dark averages so tinted bars stay visible on the black notch.
    private static func vivid(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        NSColor(red: red, green: green, blue: blue, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return Color(hue: h, saturation: min(max(s, 0.25), 1), brightness: max(b, 0.7))
    }

    func appIcon(for source: MusicSource) -> NSImage? {
        if let icon = iconCache[source] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[source] = icon
        return icon
    }

    func open(_ source: MusicSource) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Commands (optimistic local update, then script, then re-sync)

    private func perform(optimistic: (inout MusicSnapshot) -> Void,
                         _ action: @escaping @Sendable (any MusicService) async -> Void) {
        guard var snap = active, let service = services[snap.source] else { return }
        epoch += 1
        optimistic(&snap)
        snapshots[snap.source] = snap
        recompute()
        let source = snap.source
        Task { await action(service); await refresh(source) }
    }

    func playPause() {
        guard let snap = active else { return }
        let target: PlaybackState = snap.state == .playing ? .paused : .playing
        let hold = 1.5
        pendingState = (snap.source, target, .now + hold)
        perform(optimistic: {
            $0.position = $0.elapsed(); $0.capturedAt = .now
            $0.state = target
        }) { await $0.send("playpause") }
        // Re-sync once the hold expires in case the command didn't take.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold + 0.1))
            await self?.refresh(snap.source)
        }
    }

    func next() { perform(optimistic: { _ in }) { await $0.send("next track") } }
    func previous() { perform(optimistic: { _ in }) { await $0.send("previous track") } }

    func seek(to seconds: TimeInterval) {
        let target = (seconds * 10).rounded() / 10
        perform(optimistic: { $0.position = target; $0.capturedAt = .now }) {
            await $0.send("set player position to \(target)")
        }
    }

    /// Live drags send at most every 80 ms; `commit` sends the final value and re-syncs.
    func setVolume(_ volume: Int, commit: Bool) {
        let v = min(max(volume, 0), 100)
        if commit {
            perform(optimistic: { $0.volume = v }) { await $0.send("set sound volume to \(v)") }
            return
        }
        guard var snap = active, let service = services[snap.source] else { return }
        epoch += 1
        snap.volume = v
        snapshots[snap.source] = snap
        recompute()
        guard Date.now.timeIntervalSince(lastVolumeSend) > 0.08 else { return }
        lastVolumeSend = .now
        Task { await service.send("set sound volume to \(v)") }
    }

    func toggleShuffle() {
        guard let on = active?.shuffle.inverted else { return }
        perform(optimistic: { $0.shuffle = on }) { await $0.send($0.shuffleStatement(on)) }
    }

    func toggleRepeat() {
        guard let on = active?.repeating.inverted else { return }
        perform(optimistic: { $0.repeating = on }) { await $0.send($0.repeatStatement(on)) }
    }

    func toggleFavorite() {
        guard let current = active?.isFavorite else { return }
        perform(optimistic: { $0.isFavorite = !current }) { service in
            if let s = service.favoriteStatement(!current) { await service.send(s) }
        }
    }
}

private extension Bool {
    var inverted: Bool { !self }
}

/// Most visually dominant colour: largest weighted bucket of saturated, non-dark pixels
/// (falls back to the plain average for greyscale covers).
func dominantColor(of data: Data) -> (CGFloat, CGFloat, CGFloat)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 32,
          ] as CFDictionary) else { return nil }
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { return nil }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let drawn: Bool = px.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { return nil }

    struct Bucket { var weight = 0.0; var r = 0, g = 0, b = 0, n = 0 }
    var buckets: [Int: Bucket] = [:]
    var total = Bucket()
    for i in 0..<(w * h) {
        let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
        total.r += r; total.g += g; total.b += b; total.n += 1
        let mx = max(r, g, b), mn = min(r, g, b)
        let sat = mx == 0 ? 0 : Double(mx - mn) / Double(mx)
        let val = Double(mx) / 255
        guard sat > 0.25, val > 0.2 else { continue }
        let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
        buckets[key, default: Bucket()].weight += sat * val
        buckets[key, default: Bucket()].r += r
        buckets[key, default: Bucket()].g += g
        buckets[key, default: Bucket()].b += b
        buckets[key, default: Bucket()].n += 1
    }
    let pick = buckets.values.max { $0.weight < $1.weight } ?? total
    guard pick.n > 0 else { return nil }
    let n = CGFloat(pick.n) * 255
    return (CGFloat(pick.r) / n, CGFloat(pick.g) / n, CGFloat(pick.b) / n)
}
