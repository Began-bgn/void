import Foundation

/// Pure Face Unlock state machine, driven by `FaceUnlockCoordinator`. No timers, no I/O: every
/// rule (lockout, what counts as a failure, what cancels) lives here so it can be unit tested.
struct FaceUnlockState: Equatable {
    enum Challenge: CaseIterable, Equatable {
        case blink, turnLeft, turnRight
    }

    enum Failure: Equatable {
        case noFace, multipleFaces, liveness, notRecognised
        /// Password entry did not unlock. Never retried: a wrong password counts toward macOS lockout.
        case entry
        /// Counts toward the lockout. No face in view is the user not being ready, not an attack.
        var counts: Bool { self == .liveness || self == .notRecognised }
    }

    enum Phase: Equatable {
        /// Not on the lock screen.
        case idle
        /// On the lock screen, waiting for the hover/click trigger.
        case armed
        case scanning
        case liveness(Challenge)
        case matching
        /// Face verified; the password is being entered.
        case unlocking
        case success
        case failure(Failure)
        /// Too many failures, or entry failed: only the password or Touch ID unlocks from here.
        case lockedOut
        /// Feature off (kill switch, unsupported, never enabled).
        case disabled
    }

    enum Event: Equatable {
        case enabled(Bool)
        case locked
        /// Any unlock, ours or the user's. Resets the failure count.
        case unlocked
        case triggered
        case faceFound(Challenge)
        case noFace, multipleFaces
        case livenessPassed, livenessFailed
        case matched, notMatched
        case entered, entryFailed
        /// Cursor left the notch, Esc, sleep, or an error before a verdict. Not a failure.
        case cancelled
        /// The failure message has been shown; go back to waiting.
        case failureShown
    }

    var phase: Phase = .disabled
    /// Consecutive counted failures. Persisted by the coordinator so it survives lock cycles.
    var failures = 0
    var lockoutThreshold = 3
    var onLockScreen = false

    var isScanning: Bool {
        switch phase {
        case .scanning, .liveness, .matching, .unlocking: true
        default: false
        }
    }

    private var restingPhase: Phase {
        guard onLockScreen else { return .idle }
        return failures >= lockoutThreshold ? .lockedOut : .armed
    }

    mutating func apply(_ event: Event) {
        switch (event, phase) {
        case (.enabled(false), _):
            phase = .disabled
        case (.enabled(true), .disabled):
            phase = restingPhase
        case (_, .disabled):
            if event == .locked { onLockScreen = true }
            if event == .unlocked { onLockScreen = false; failures = 0 }

        case (.locked, _):
            onLockScreen = true
            if phase == .idle { phase = restingPhase }
        case (.unlocked, _):
            onLockScreen = false
            failures = 0
            phase = .idle

        case (.triggered, .armed):
            phase = .scanning
        case (.faceFound(let c), .scanning):
            phase = .liveness(c)
        case (.noFace, .scanning), (.noFace, .liveness):
            fail(.noFace)
        case (.multipleFaces, .scanning), (.multipleFaces, .liveness):
            fail(.multipleFaces)
        case (.livenessPassed, .liveness):
            phase = .matching
        case (.livenessFailed, .liveness):
            fail(.liveness)
        case (.matched, .matching):
            phase = .unlocking
        case (.notMatched, .matching):
            fail(.notRecognised)
        case (.entered, .unlocking):
            phase = .success
        case (.entryFailed, .unlocking):
            phase = .failure(.entry)

        case (.cancelled, .scanning), (.cancelled, .liveness), (.cancelled, .matching):
            // .matching included: too few usable frames is not a failed match.
            phase = restingPhase
        case (.failureShown, .failure(.entry)):
            phase = .lockedOut
        case (.failureShown, .failure):
            phase = restingPhase

        default:
            break // out-of-order events are ignored, never crash or advance
        }
    }

    private mutating func fail(_ failure: Failure) {
        if failure.counts { failures += 1 }
        phase = .failure(failure)
    }
}
