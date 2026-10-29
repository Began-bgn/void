import Foundation
import Observation
import ScreenCaptureKit
import CoreMedia
import Accelerate
import os

private let barCount = 7

/// Real audio levels from a ScreenCaptureKit system-audio tap. Only runs when Screen Recording is
/// granted and music is playing; otherwise the bars rest.
@MainActor @Observable
final class VisualizerEngine {
    static let shared = VisualizerEngine()

    /// Not observed: the bars' 30 fps timeline reads it each frame. Observing it too redrew twice per frame.
    @ObservationIgnored private(set) var levels = [Float](repeating: 0, count: barCount)
    private(set) var isCapturing = false

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var tap: AudioLevelTap?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var asked = false
    @ObservationIgnored private let log = Logger(subsystem: "com.notchdeck.app", category: "visualizer")

    private init() {}

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    func start() {
        wanted = true
        guard hasPermission else {
            // Ask once per launch; the bars have nothing to follow without it.
            if !asked { asked = true; requestPermission() }
            log.info("Audio capture skipped: Screen Recording not granted")
            return
        }
        guard stream == nil, !starting else { return }
        starting = true
        Task { [weak self] in
            guard let self else { return }
            defer { starting = false }
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else { return }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 44100
                config.channelCount = 1
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let tap = AudioLevelTap { [weak self] new in
                    Task { @MainActor in self?.apply(new) }
                }
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                 configuration: config, delegate: nil)
                let queue = DispatchQueue(label: "com.notchdeck.audiotap", qos: .utility)
                try s.addStreamOutput(tap, type: .audio, sampleHandlerQueue: queue)
                try s.addStreamOutput(tap, type: .screen, sampleHandlerQueue: queue)
                try await s.startCapture()
                guard wanted else { try? await s.stopCapture(); return }
                stream = s; self.tap = tap; isCapturing = true
            } catch {
                log.error("Audio capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        wanted = false
        guard let s = stream else { return }
        stream = nil; tap = nil; isCapturing = false
        levels = [Float](repeating: 0, count: barCount)
        Task { try? await s.stopCapture() }
    }

    private func apply(_ new: [Float]) {
        guard isCapturing || stream != nil else { return }
        // Eased both ways: quick rise, gentler fall, no frame-to-frame jumps.
        levels = zip(levels, new).map { old, target in old + (target - old) * (target > old ? 0.55 : 0.25) }
    }
}

/// Splits the system audio into frequency bands (bass to treble, one per bar) with an FFT, so
/// each bar follows its own part of the song like the iPhone's Dynamic Island waveform.
private final class AudioLevelTap: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onLevels: @Sendable ([Float]) -> Void
    private var lastEmit: CFAbsoluteTime = 0

    private static let log2n: vDSP_Length = 10
    private static let n = 1 << 10
    /// FFT bin ranges per band (~43 Hz per bin at 44.1 kHz), octave-spaced from bass to treble.
    private static let bands: [Range<Int>] = [1..<3, 3..<6, 6..<12, 12..<24, 24..<48, 48..<96, 96..<200]
    private let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    /// Last `n` samples; audio buffers can be shorter than one FFT frame.
    private var history = [Float](repeating: 0, count: n)
    /// Per-band running peak: auto gain, so quiet and loud songs both fill the bars.
    private var peaks = [Float](repeating: 0, count: barCount)

    init(onLevels: @escaping @Sendable ([Float]) -> Void) { self.onLevels = onLevels }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let buffer = list.first, let raw = buffer.mData else { return }
            let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, Self.n)
            history.removeFirst(count)
            history.append(contentsOf: UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: count))
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmit >= 1.0 / 30 else { return }
        lastEmit = now
        if let out = levels() { onLevels(out) }
    }

    private func levels() -> [Float]? {
        guard let fft else { return nil }
        let half = Self.n / 2
        let windowed = vDSP.multiply(history, window)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        return Self.bands.enumerated().map { i, band in
            let energy = vDSP.mean(mags[band])
            // ponytail: decay, floor, gate and curve are tuning knobs; raise the floor if bars twitch
            // in silence. Low floor + small gate + a lifting curve: quiet instrumentals still move.
            peaks[i] = max(energy, peaks[i] * 0.99, 0.08)
            let x = min(1, max(0, (energy / peaks[i] - 0.08) * 1.15))
            return pow(x, 0.75)
        }
    }
}
