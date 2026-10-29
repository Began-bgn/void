import AppKit

protocol MusicService: Sendable {
    var source: MusicSource { get }
    /// Script returning the unit-separator joined state string (see `MusicSnapshot.parse`).
    var fetchScript: String { get }
    func artworkData(for snapshot: MusicSnapshot) async -> Data?
    func shuffleStatement(_ on: Bool) -> String
    func repeatStatement(_ on: Bool) -> String
    /// nil when the source has no AppleScript favourite support.
    func favoriteStatement(_ on: Bool) -> String?
}

extension MusicService {
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty }

    /// Never launches the app: `tell application` would start a quit Spotify/Music.
    func snapshot() async -> MusicSnapshot? {
        guard isRunning, let raw = await ScriptRunner.shared.run(fetchScript) else { return nil }
        return MusicSnapshot.parse(raw, source: source)
    }

    func send(_ statement: String) async {
        guard isRunning else { return }
        _ = await ScriptRunner.shared.run("tell application id \"\(source.bundleID)\" to \(statement)")
    }

    func favoriteStatement(_ on: Bool) -> String? { nil }
}

private func fetchScript(bundleID: String, artwork: String, id: String, repeatExpr: String, extra: String) -> String {
    """
    try
        tell application id "\(bundleID)"
            set stateText to player state as text
            if stateText is "stopped" then return "stopped"
            set sep to ASCII character 31
            set trk to current track
            return stateText & sep & (name of trk) & sep & (artist of trk) & sep & (album of trk) & sep & (duration of trk) & sep & (player position) & sep & \(artwork) & sep & (sound volume) & sep & \(id) & sep & \(repeatExpr)\(extra)
        end tell
    on error
        return "stopped"
    end try
    """
}

struct SpotifyService: MusicService {
    let source = MusicSource.spotify

    var fetchScript: String {
        NotchDeck.fetchScript(
            bundleID: source.bundleID, artwork: "(artwork url of trk)", id: "(id of trk)",
            repeatExpr: "(shuffling as text) & sep & (repeating as text)", extra: "")
    }

    func artworkData(for snapshot: MusicSnapshot) async -> Data? {
        guard let url = snapshot.artworkURL else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    func shuffleStatement(_ on: Bool) -> String { "set shuffling to \(on)" }
    func repeatStatement(_ on: Bool) -> String { "set repeating to \(on)" }
    // Liking needs the Web API (PKCE OAuth); added with the Spotify account settings.
}

struct AppleMusicService: MusicService {
    let source = MusicSource.appleMusic

    var fetchScript: String {
        NotchDeck.fetchScript(
            bundleID: source.bundleID, artwork: "\"\"", id: "((database ID of trk) as text)",
            repeatExpr: "(shuffle enabled as text) & sep & ((song repeat) as text)",
            extra: " & sep & ((loved of trk) as text)")
    }

    func artworkData(for snapshot: MusicSnapshot) async -> Data? {
        await ScriptRunner.shared.runData("""
        tell application id "\(source.bundleID)" to return data of artwork 1 of current track
        """)
    }

    func shuffleStatement(_ on: Bool) -> String { "set shuffle enabled to \(on)" }
    func repeatStatement(_ on: Bool) -> String { "set song repeat to \(on ? "all" : "off")" }
    func favoriteStatement(_ on: Bool) -> String? { "set loved of current track to \(on)" }
}
