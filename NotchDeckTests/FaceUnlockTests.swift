import Foundation
import Testing
@testable import NotchDeck

@Suite struct FaceUnlockStateTests {
    /// Enabled and on the lock screen.
    private func armed(failures: Int = 0) -> FaceUnlockState {
        var s = FaceUnlockState()
        s.failures = failures
        s.apply(.enabled(true))
        s.apply(.locked)
        return s
    }

    @Test func disabledByDefaultAndIgnoresTrigger() {
        var s = FaceUnlockState()
        s.apply(.locked)
        s.apply(.triggered)
        #expect(s.phase == .disabled)
    }

    @Test func happyPath() {
        var s = armed()
        #expect(s.phase == .armed)
        s.apply(.triggered); #expect(s.phase == .scanning)
        s.apply(.faceFound(.blink)); #expect(s.phase == .liveness(.blink))
        s.apply(.livenessPassed); #expect(s.phase == .matching)
        s.apply(.matched); #expect(s.phase == .unlocking)
        s.apply(.entered); #expect(s.phase == .success)
        s.apply(.unlocked); #expect(s.phase == .idle)
    }

    @Test func outOfOrderEventsIgnored() {
        var s = armed()
        s.apply(.matched)
        s.apply(.entered)
        #expect(s.phase == .armed)
        s.apply(.triggered)
        s.apply(.matched) // matching before liveness must not skip it
        #expect(s.phase == .scanning)
    }

    @Test func threeCountedFailuresLockOut() {
        var s = armed()
        for i in 1...3 {
            s.apply(.triggered); s.apply(.faceFound(.turnLeft))
            if i == 2 { s.apply(.livenessFailed) } else { s.apply(.livenessPassed); s.apply(.notMatched) }
            #expect(s.failures == i)
            s.apply(.failureShown)
        }
        #expect(s.phase == .lockedOut)
        s.apply(.triggered)
        #expect(s.phase == .lockedOut)
    }

    @Test func noFaceAndCancelDoNotCount() {
        var s = armed()
        s.apply(.triggered); s.apply(.noFace)
        #expect(s.phase == .failure(.noFace))
        s.apply(.failureShown)
        s.apply(.triggered); s.apply(.faceFound(.blink)); s.apply(.cancelled)
        #expect(s.phase == .armed)
        #expect(s.failures == 0)
    }

    @Test func cancelIgnoredWhileEnteringPassword() {
        var s = armed()
        s.apply(.triggered); s.apply(.faceFound(.blink)); s.apply(.livenessPassed); s.apply(.matched)
        s.apply(.cancelled)
        #expect(s.phase == .unlocking)
    }

    @Test func entryFailureLocksOutWithoutRetry() {
        var s = armed()
        s.apply(.triggered); s.apply(.faceFound(.blink)); s.apply(.livenessPassed); s.apply(.matched)
        s.apply(.entryFailed); s.apply(.failureShown)
        #expect(s.phase == .lockedOut)
    }

    @Test func lockoutPersistsAcrossLockUntilUnlock() {
        var s = armed(failures: 3)
        #expect(s.phase == .lockedOut)
        s.apply(.unlocked)
        #expect(s.failures == 0)
        s.apply(.locked)
        #expect(s.phase == .armed)
    }

    @Test func killSwitchFromAnyPhase() {
        var s = armed()
        s.apply(.triggered); s.apply(.faceFound(.blink))
        s.apply(.enabled(false))
        #expect(s.phase == .disabled)
        s.apply(.enabled(true))
        #expect(s.phase == .armed)
    }

    @MainActor @Test func coordinatorPersistsFailureCount() {
        let defaults = UserDefaults(suiteName: "FaceUnlockTests")!
        defaults.removePersistentDomain(forName: "FaceUnlockTests")
        let c = FaceUnlockCoordinator(defaults: defaults)
        c.send(.enabled(true)); c.send(.locked); c.send(.triggered)
        c.send(.faceFound(.blink)); c.send(.livenessFailed)
        #expect(FaceUnlockCoordinator(defaults: defaults).state.failures == 1)
    }
}

private func face(x: CGFloat = 0.5, y: CGFloat = 0.5, w: CGFloat = 0.3, yaw: Double = 0, pitch: Double = 0, q: Float? = 0.6) -> FaceSample {
    FaceSample(box: CGRect(x: x - w / 2, y: y - w / 2, width: w, height: w), yaw: yaw, roll: 0, pitch: pitch, quality: q)
}

@Suite struct FaceGateTests {
    let gate = FaceGate()

    @Test func acceptsOneCentredFace() { #expect(gate.check([face()]) == .ok(face())) }
    @Test func rejectsNone() { #expect(gate.check([]) == .noFace) }
    @Test func rejectsTwo() { #expect(gate.check([face(), face(x: 0.3)]) == .multipleFaces) }
    @Test func rejectsSmall() { #expect(gate.check([face(w: 0.1)]) == .tooSmall) }
    @Test func rejectsOffCentre() { #expect(gate.check([face(x: 0.85)]) == .offCentre) }
    @Test func rejectsLowQuality() { #expect(gate.check([face(q: 0.1)]) == .lowQuality) }
    @Test func missingQualityIsNotRejected() { #expect(gate.check([face(q: nil)]) == .ok(face(q: nil))) }
}

@Suite struct EnrolmentPlanTests {
    @Test func centreFirstThenEverySectorOnce() {
        var plan = EnrolmentPlan(sectors: 4, centreFrames: 2)
        func offer(_ f: FaceSample) -> Bool { plan.offer(f) }
        #expect(!offer(face(yaw: 0.5))) // turned before centre is not taken
        #expect(offer(face()))
        #expect(offer(face()))
        #expect(!offer(face())) // centre done, straight adds nothing
        // Vision yaw > 0 = user's left = screen left in the mirrored preview: sector 2 of 4.
        #expect(plan.sector(face(yaw: 0.4)) == 2)
        #expect(offer(face(yaw: 0.4)))
        #expect(!offer(face(yaw: 0.5))) // same sector again
        #expect(offer(face(yaw: -0.4)))
        #expect(offer(face(pitch: -0.4))) // tilt up
        #expect(!plan.isComplete)
        #expect(offer(face(pitch: 0.4)))
        #expect(plan.isComplete)
        #expect(plan.progress == 1)
    }

    @Test func smallMovementsFillNothing() {
        let plan = EnrolmentPlan()
        #expect(plan.sector(face(yaw: 0.1, pitch: 0.1)) == nil)
    }
}

@Suite(.serialized) struct TemplateStoreTests {
    let store = TemplateStore(service: "com.notchdeck.faceunlock.tests")

    @Test func roundTripAndWipe() throws {
        store.wipe()
        #expect(try store.load().isEmpty)
        try store.save([[0.1, 0.2], [0.3, -0.4]])
        #expect(try store.load() == [[0.1, 0.2], [0.3, -0.4]])
        #expect(store.wipe())
        #expect(try store.load().isEmpty)
    }
}

/// Eye contour with the given openness (height/width), around `x`.
private func eye(_ x: CGFloat, open: CGFloat) -> [CGPoint] {
    [CGPoint(x: x - 0.03, y: 0.6), CGPoint(x: x, y: 0.6 + 0.03 * open), CGPoint(x: x + 0.03, y: 0.6), CGPoint(x: x, y: 0.6 - 0.03 * open)]
}

/// A face whose centre drifts slightly frame to frame, like a real head.
private func live(_ i: Int, yaw: Double = 0, open: CGFloat = 0.5) -> FaceSample {
    var f = face(x: 0.5 + CGFloat(i % 3) * 0.003, yaw: yaw)
    f.leftEye = eye(0.45, open: open)
    f.rightEye = eye(0.55, open: open)
    return f
}

@Suite struct LivenessTests {
    /// Feeds `frames` at 30 fps; returns the first non-pending verdict.
    private func run(_ challenge: FaceUnlockState.Challenge, _ frames: [[FaceSample]]) -> LivenessChecker.Verdict {
        var c = LivenessChecker(challenge: challenge)
        for (i, f) in frames.enumerated() {
            let v = c.feed(f, at: Double(i) / 30)
            if v != .pending { return v }
        }
        return .pending
    }

    @Test func blinkPasses() {
        let opens: [CGFloat] = [0.5, 0.5, 0.5, 0.5, 0.2, 0.1, 0.2, 0.5]
        #expect(run(.blink, opens.enumerated().map { [live($0.offset, open: $0.element)] }) == .passed)
    }

    @Test func noBlinkStaysPendingThenTimesOut() {
        #expect(run(.blink, (0..<120).map { [live($0)] }) == .failed(.timedOut))
    }

    @Test func turnLeftPassesTurnRightDoesNot() {
        let yaws = [0, 0.1, 0.2, 0.35] // Vision yaw grows turning to the user's left
        #expect(run(.turnLeft, yaws.enumerated().map { [live($0.offset, yaw: $0.element)] }) == .passed)
        #expect(run(.turnRight, yaws.enumerated().map { [live($0.offset, yaw: $0.element)] }) == .pending)
    }

    @Test func faceLostOrSecondFaceFails() {
        #expect(run(.blink, [[live(0)], []]) == .failed(.faceLost))
        #expect(run(.blink, [[live(0)], [live(1), live(2)]]) == .failed(.multipleFaces))
    }

    @Test func perfectlyStillInputIsRejected() {
        // A photo held in a stand: the head "turns" (e.g. a video frame) but the box never moves.
        let still = [0, 0.2, 0.4].map { yaw -> [FaceSample] in [face(yaw: yaw)] }
        #expect(run(.turnLeft, still) == .failed(.staticInput))
    }
}

@Suite struct FaceMatcherTests {
    @Test func cosineBasics() {
        #expect(FaceMatcher.cosine([1, 0], [1, 0]) == 1)
        #expect(abs(FaceMatcher.cosine([1, 0], [0, 1])) < 1e-6)
        #expect(FaceMatcher.cosine([1], [1, 0]) == -1) // size mismatch never matches
    }

    @Test func thresholdDecides() {
        let me: [Float] = [1, 0, 0]
        let templates: [[Float]] = [me, [0.95, 0.31, 0], [0.9, 0, 0.43]]
        let matcher = FaceMatcher(threshold: 0.7)
        #expect(matcher.matches([me, me, [0.9, 0.1, 0.1]], templates: templates))
        #expect(!matcher.matches([[0, 1, 0], [0, 0, 1], me], templates: templates)) // median decides
        #expect(!matcher.matches([me], templates: templates)) // too few frames
        #expect(!matcher.matches([me, me], templates: [])) // not enrolled
    }

    @Test func cropIsSquareWithMarginAndClamped() {
        let c = CoreMLFaceRecognizer.crop(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        #expect(abs(c.width - 0.24) < 1e-6 && abs(c.height - 0.24) < 1e-6)
        #expect(CoreMLFaceRecognizer.crop(CGRect(x: 0.9, y: 0.9, width: 0.2, height: 0.2)).maxX <= 1)
    }

    @Test func modelLoads() {
        #expect(FaceUnlockCoordinator.recognizer != nil)
    }
}

@Suite struct FaceUnlockMultipleFacesTests {
    @Test func secondFaceFailsWithoutCounting() {
        var s = FaceUnlockState()
        s.apply(.enabled(true)); s.apply(.locked); s.apply(.triggered)
        s.apply(.multipleFaces)
        #expect(s.phase == .failure(.multipleFaces))
        #expect(s.failures == 0)
    }

    @Test func tooFewFramesCancelsFromMatching() {
        var s = FaceUnlockState()
        s.apply(.enabled(true)); s.apply(.locked); s.apply(.triggered)
        s.apply(.faceFound(.blink)); s.apply(.livenessPassed); s.apply(.cancelled)
        #expect(s.phase == .armed)
        #expect(s.failures == 0)
    }
}

@Suite struct CredentialVaultTests {
    // No test calls `verify` with a wrong password: each one counts as a failed login attempt
    // on the real account.

    @Test func resetBytesZeroes() {
        var b: [UInt8] = [1, 2, 3]
        b.resetBytes()
        #expect(b.isEmpty)
    }
}

@Suite struct ScanRateLimiterTests {
    @Test func firstScanFreeThenTwoSeconds() {
        var r = ScanRateLimiter()
        #expect(r.wait(at: 100, failures: 0) == 0)
        r.started(at: 100)
        #expect(r.wait(at: 101, failures: 0) == 1)
        #expect(r.wait(at: 102, failures: 0) == 0)
    }

    @Test func cooldownEscalatesWithFailures() {
        var r = ScanRateLimiter()
        r.started(at: 0)
        #expect(r.wait(at: 1, failures: 1) == 4)
        #expect(r.wait(at: 1, failures: 2) == 29)
        #expect(r.wait(at: 1, failures: 5) == 29)
    }

    @Test func livenessSettingPicksChallenges() {
        #expect(FaceUnlockCoordinator.challenges(for: .blink) == [.blink])
        #expect(FaceUnlockCoordinator.challenges(for: .turn) == [.turnLeft, .turnRight])
        #expect(FaceUnlockCoordinator.challenges(for: .both).count == 3)
    }
}
