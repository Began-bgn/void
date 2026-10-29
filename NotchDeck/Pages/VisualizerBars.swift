import SwiftUI

/// Audio bars. Play/pause changes ramp the bar energy in/out instead of snapping, so pausing
/// eases the bars down to rest. The timeline only runs while playing or during the ramp.
struct VisualizerBars: View {
    let isPlaying: Bool
    let color: Color
    private let engine = VisualizerEngine.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private let lowPower = LowPowerMode.shared
    /// Low Power Mode rests the bars like Reduce Motion does.
    private var reduceMotion: Bool { systemReduceMotion || lowPower.isOn }

    @State private var changedAt = Date.distantPast
    @State private var running = false
    @State private var appeared = false

    /// Dynamic Island music: seven thin bars, one per frequency band.
    private let count = 7
    /// Band shown at each position: bass in the middle, treble at the edges, like the iPhone.
    private let order = [5, 3, 1, 0, 2, 4, 6]
    /// Edge bars run shorter, giving the waveform its rounded silhouette.
    private let envelope: [CGFloat] = [0.6, 0.85, 1, 1, 1, 0.85, 0.6]
    private let pitch: CGFloat = 3.6
    private let barWidth: CGFloat = 2
    private let maxHeight: CGFloat = 18
    private let rampIn = 0.35
    private let rampOut = 0.55

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { ctx in
            bars(levels(at: ctx.date))
        }
        .task(id: [isPlaying, reduceMotion]) {
            if !appeared {
                appeared = true
                if !isPlaying { running = false; return } // already paused: start at rest, no ramp
            }
            changedAt = .now
            guard !reduceMotion else { running = false; return }
            running = true
            guard !isPlaying else { return }
            try? await Task.sleep(for: .seconds(rampOut))
            if !Task.isCancelled { running = false }
        }
        .accessibilityHidden(true)
    }

    private func levels(at date: Date) -> [CGFloat] {
        guard !reduceMotion else { return Array(repeating: 0, count: count) }
        let dt = date.timeIntervalSince(changedAt)
        var amp = isPlaying ? min(1, dt / rampIn) : max(0, 1 - dt / rampOut)
        amp = amp * amp * (3 - 2 * amp) // smoothstep
        // Real audio when the opt-in capture runs; otherwise a synthetic beat, so no recording indicator.
        let t = date.timeIntervalSinceReferenceDate
        return (0..<count).map { i in
            let level = engine.isCapturing ? CGFloat(engine.levels[order[i]]) : Self.synthetic(band: order[i], at: t)
            return level * envelope[i] * amp
        }
    }

    /// Music-like level for one band (0 bass ... 6 treble): a decaying kick on the bass, a wandering
    /// groove on the mids, fast shimmer on the treble, and a slow swell so phrases rise and fall.
    /// ponytail: fixed ~128 BPM, not synced to the song; real tempo would need audio or track BPM.
    static func synthetic(band: Int, at t: Double) -> CGFloat {
        let b = Double(band) / 6
        let p = Double(band) * 1.7
        let kick = exp(-t.truncatingRemainder(dividingBy: 0.47) * 7)
        let groove = 0.5 + 0.25 * sin(t * (2.1 + b * 3.3) + p) + 0.25 * sin(t * (5.3 + b * 7.1) + p * 2.3)
        let shimmer = 0.5 + 0.5 * sin(t * (11 + b * 9) + p * 3.1)
        let swell = 0.8 + 0.2 * sin(t * 0.4 + p * 0.3)
        // Random-looking jumps every 0.12 s, eased between steps so they don't snap.
        let step = (t / 0.12).rounded(.down)
        let f = t / 0.12 - step
        let noise = hash(step, p) + (hash(step + 1, p) - hash(step, p)) * f * f * (3 - 2 * f)
        let v = ((1 - b) * 0.7 * kick + 0.3 * groove + 0.4 * noise + b * 0.2 * shimmer) * swell
        return CGFloat(min(1, max(0, 0.06 + v)))
    }

    private static func hash(_ x: Double, _ seed: Double) -> Double {
        let s = sin(x * 12.9898 + seed * 78.233) * 43758.5453
        return s - s.rounded(.down)
    }

    /// Plain capsules, not a Canvas: a Canvas re-rasterises into an offscreen texture every frame,
    /// shapes only update their geometry (same pixels, less CPU per frame).
    /// Bars sit on a fixed pitch with a rounded cap, like the Dynamic Island waveform.
    private func bars(_ levels: [CGFloat]) -> some View {
        HStack(spacing: pitch - barWidth) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: barWidth, height: max(barWidth, maxHeight * levels[i])) // silent bar = a dot
            }
        }
        .frame(width: CGFloat(count - 1) * pitch + barWidth, height: maxHeight)
        .frame(maxHeight: .infinity)
    }
}

/// Brief play/pause glyph that replaces the collapsed-notch bars after a click.
/// `symbol` reflects the state the click produced; the bars return when the timer ends.
/// Each call restarts the timer, so the last of rapid clicks wins.
@MainActor @Observable
final class PlayPauseFeedback {
    static let shared = PlayPauseFeedback()

    private(set) var symbol: String?
    /// Bumped per click so `.symbolEffect(.bounce)` replays even when the glyph is unchanged.
    private(set) var clicks = 0
    @ObservationIgnored let duration: Duration
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(duration: Duration = .milliseconds(900)) { self.duration = duration }

    func show(playing: Bool) {
        symbol = playing ? "play.fill" : "pause.fill"
        clicks += 1
        task?.cancel()
        task = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.symbol = nil
        }
    }
}
