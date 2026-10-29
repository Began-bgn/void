import Foundation

/// Active liveness: the user must perform a random challenge (blink, or turn the head) within a
/// short window, with exactly one face in every frame and some natural movement. Pure: fed one
/// frame's detection at a time.
struct LivenessChecker {
    enum Verdict: Equatable {
        case pending
        case passed
        case failed(Reason)
    }

    enum Reason: Equatable {
        case faceLost, multipleFaces, timedOut, staticInput
    }

    let challenge: FaceUnlockState.Challenge
    // ponytail: thresholds for a MacBook camera; calibrate with recorded sequences in tests.
    var window: Double = 3
    /// Eye-aspect-ratio drop (relative to the open-eye baseline) that counts as closed.
    var closedRatio = 0.6
    var reopenRatio = 0.85
    /// Yaw change from the start, radians. Vision yaw grows when the user turns to their left
    /// (confirmed in enrolment on the MacBook camera).
    var turn = 0.3
    var leftYawSign = 1.0
    /// Below this spread of face-centre positions across the window, the input is a still image.
    var minMovement: CGFloat = 0.002

    private var start: Double?
    private var baselineEAR: [Double] = []
    private var baselineYaw: Double?
    private var eyesClosed = false
    private var centres: [CGPoint] = []

    init(challenge: FaceUnlockState.Challenge) { self.challenge = challenge }

    /// Eye aspect ratio from a Vision eye contour: height over width of its bounding box.
    static func ear(_ eye: [CGPoint]) -> Double? {
        guard eye.count >= 4, let minX = eye.map(\.x).min(), let maxX = eye.map(\.x).max(), maxX > minX,
              let minY = eye.map(\.y).min(), let maxY = eye.map(\.y).max() else { return nil }
        return Double((maxY - minY) / (maxX - minX))
    }

    /// `faces` is every face Vision found in the frame at `time` (seconds).
    mutating func feed(_ faces: [FaceSample], at time: Double) -> Verdict {
        let t0 = start ?? time
        start = t0
        if time - t0 > window { return .failed(.timedOut) }
        guard let face = faces.first else { return .failed(.faceLost) }
        guard faces.count == 1 else { return .failed(.multipleFaces) }
        centres.append(CGPoint(x: face.box.midX, y: face.box.midY))

        let passed: Bool
        switch challenge {
        case .blink:
            guard let l = Self.ear(face.leftEye), let r = Self.ear(face.rightEye) else { return .pending }
            let ear = (l + r) / 2
            if baselineEAR.count < 3 { baselineEAR.append(ear); return .pending }
            let open = baselineEAR.sorted()[baselineEAR.count / 2]
            if ear < open * closedRatio { eyesClosed = true }
            passed = eyesClosed && ear > open * reopenRatio
        case .turnLeft, .turnRight:
            let base = baselineYaw ?? face.yaw
            baselineYaw = base
            let sign = challenge == .turnLeft ? leftYawSign : -leftYawSign
            passed = (face.yaw - base) * sign > turn
        }
        guard passed else { return .pending }
        return movement >= minMovement ? .passed : .failed(.staticInput)
    }

    /// Largest spread of the face centre on either axis.
    private var movement: CGFloat {
        guard let minX = centres.map(\.x).min(), let maxX = centres.map(\.x).max(),
              let minY = centres.map(\.y).min(), let maxY = centres.map(\.y).max() else { return 0 }
        return max(maxX - minX, maxY - minY)
    }
}
