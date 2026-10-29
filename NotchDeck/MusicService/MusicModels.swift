import AppKit

enum MusicSource: String, CaseIterable, Sendable {
    case spotify, appleMusic

    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var displayName: String { self == .spotify ? "Spotify" : "Music" }

    init?(bundleID: String?) {
        guard let match = Self.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = match
    }
}

enum PlaybackState: Sendable { case playing, paused }

struct MusicSnapshot: Equatable, Sendable {
    var source: MusicSource
    var state: PlaybackState
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var capturedAt: Date
    var volume: Int
    var artworkURL: URL?
    var trackID: String
    var shuffle: Bool
    var repeating: Bool
    /// nil when the source cannot report or set favourites.
    var isFavorite: Bool?

    var trackKey: String { trackID.isEmpty ? "\(title)|\(artist)|\(album)" : trackID }

    func elapsed(at date: Date = .now) -> TimeInterval {
        let t = state == .playing ? position + date.timeIntervalSince(capturedAt) : position
        return duration > 0 ? min(max(t, 0), duration) : max(t, 0)
    }
}

extension MusicSnapshot {
    static let separator: Character = "\u{1F}"

    /// Parses the unit-separator joined reply of the fetch scripts. nil for stopped/garbage.
    /// Fields: state, title, artist, album, duration, position, artworkURL, volume, id, shuffle, repeat[, loved].
    /// Spotify reports duration in ms, Music in seconds.
    static func parse(_ raw: String, source: MusicSource, now: Date = .now) -> MusicSnapshot? {
        let f = raw.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 11 else { return nil }

        let state: PlaybackState
        switch f[0].lowercased() {
        case "playing", "fast forwarding", "rewinding": state = .playing
        case "paused": state = .paused
        default: return nil
        }
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        func flag(_ s: String) -> Bool { !["false", "off", ""].contains(s.lowercased()) }

        let duration = source == .spotify ? num(f[4]) / 1000 : num(f[4])
        return MusicSnapshot(
            source: source, state: state, title: f[1], artist: f[2], album: f[3],
            duration: duration, position: num(f[5]), capturedAt: now,
            volume: Int(num(f[7])), artworkURL: f[6].isEmpty ? nil : URL(string: f[6]),
            trackID: f[8], shuffle: flag(f[9]), repeating: flag(f[10]),
            isFavorite: f.count > 11 ? f[11].lowercased() == "true" : nil
        )
    }
}
