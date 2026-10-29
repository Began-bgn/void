import Foundation

/// What the desktop widget shows. The app writes it into the App Group container; the widget
/// extension reads it.
struct WidgetNowPlaying: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var source: String
    var isPlaying: Bool
    var position: TimeInterval
    var duration: TimeInterval
    var capturedAt: Date
    /// Artwork colour (sRGB), nil when there is none.
    var tint: [Double]?

    /// When the track would have started had it played without pauses: drives timer text and progress.
    var startDate: Date { capturedAt.addingTimeInterval(-position) }

    func elapsed(at date: Date = .now) -> TimeInterval {
        let t = isPlaying ? position + date.timeIntervalSince(capturedAt) : position
        return duration > 0 ? min(max(t, 0), duration) : max(t, 0)
    }
}

enum WidgetShared {
    /// Team-prefixed, so it is valid for a Developer ID app without a provisioning profile.
    static let appGroup = "F63KU4246G.com.notchdeck.shared"
    static let kind = "NowPlaying"

    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }
    static var stateURL: URL? { container?.appending(path: "nowplaying.json") }
    static var artworkURL: URL? { container?.appending(path: "artwork.png") }

    /// Widget buttons. The sandboxed extension can't script Spotify or Music, so it posts these as
    /// Darwin notifications and the app performs them.
    enum Command: String, CaseIterable, Sendable {
        case previous, playPause, next
        var notification: String { "com.notchdeck.widget.\(rawValue)" }
    }
}
