import SwiftUI
import Observation
import OSLog

/// Drives `FaceUnlockState` from the notch: hover dwell, cancel, and the scan pipeline.
/// With `useCamera` (lock screen) the scan is real: camera, Vision gate, liveness, FaceNet match,
/// then the stored password is typed once. Without it (demo window) `fakeOutcome` scripts it all.
@MainActor @Observable
final class FaceUnlockCoordinator {
    static let shared = FaceUnlockCoordinator()

    enum FakeOutcome: String, CaseIterable, Identifiable {
        case success, notRecognised, livenessFails, noFace, entryFails
        var id: Self { self }
    }

    private(set) var state = FaceUnlockState()
    /// 0...1 while the cursor rests on the notch; the hint ring fills with it.
    private(set) var dwellProgress: Double = 0
    var fakeOutcome: FakeOutcome = .success
    /// Hover time before a scan starts. Settings range 0.3 to 3 s (step 6).
    var dwell: Double = 0.8
    /// Real camera for the face step. Off in the demo window.
    var useCamera = false
    /// For Settings → Diagnostics.
    private(set) var lastError: String?
    /// Median match score of the last scan that reached matching, for calibration.
    private(set) var lastScore: Float?
    var matcher = FaceMatcher()
    @ObservationIgnored var input: any LockScreenInput = CGEventLockScreenInput()

    @ObservationIgnored private var limiter = ScanRateLimiter()
    @ObservationIgnored private let settings = SettingsStore.shared

    /// Opt-in (default off), and nothing blocks it: signature, camera, model.
    static var enabledSetting: Bool { SettingsStore.shared.faceUnlockEnabled && FaceUnlockSupport.blocker == nil }

    /// Kill switch (Settings and menu bar): off now, camera stopped, password and face data wiped.
    func killSwitch() {
        settings.faceUnlockEnabled = false
        send(.enabled(false))
        TemplateStore().wipe()
        state.failures = 0
        defaults.removeObject(forKey: Self.failuresKey)
        Task { await CredentialVault.shared.wipe() }
        log.notice("kill switch: Face Unlock off, data wiped")
    }

    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Logger(subsystem: "com.notchdeck.app", category: "FaceUnlock")
    private static let failuresKey = "faceUnlockFailures"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state.failures = defaults.integer(forKey: Self.failuresKey)
    }

    func send(_ event: FaceUnlockState.Event) {
        let old = state
        state.apply(event)
        if state.failures != old.failures { defaults.set(state.failures, forKey: Self.failuresKey) }
        if state.phase != old.phase {
            log.notice("\(String(describing: event), privacy: .public): \(String(describing: old.phase), privacy: .public) -> \(String(describing: self.state.phase), privacy: .public) failures \(self.state.failures) score \(self.lastScore ?? -1) error \(self.lastError ?? "-", privacy: .public)")
        }
        if state.phase != old.phase, let text = Self.message(for: state.phase) {
            AccessibilityNotification.Announcement(text).post()
        }
        // Stop the pipeline on cancel, unlock and kill switch. Not on failure: it still has to
        // show the message and send `.failureShown`.
        if event == .cancelled || state.phase == .idle || state.phase == .disabled {
            scanTask?.cancel(); scanTask = nil
            dwellTask?.cancel(); dwellTask = nil
            dwellProgress = 0
        }
    }

    /// Cursor entered or left the notch hit area.
    func hover(_ inside: Bool) {
        dwellTask?.cancel(); dwellTask = nil
        guard inside else {
            dwellProgress = 0
            if state.isScanning { cancel() }
            return
        }
        guard state.phase == .armed, !useCamera || settings.faceUnlockTrigger == .hover else { return }
        let dwell = useCamera ? min(max(settings.faceUnlockDwell, 0.3), 3) : self.dwell
        withAnimation(.linear(duration: dwell)) { dwellProgress = 1 }
        dwellTask = Task { [weak self, dwell] in
            try? await Task.sleep(for: .seconds(dwell))
            guard let self, !Task.isCancelled else { return }
            self.dwellProgress = 0
            self.trigger()
        }
    }

    /// Hover dwell finished, the notch was clicked, or the screen woke (per Settings).
    func trigger() {
        guard state.phase == .armed else { return }
        if useCamera {
            let now = ProcessInfo.processInfo.systemUptime
            let wait = limiter.wait(at: now, failures: state.failures)
            guard wait == 0 else { return log.notice("rate limited, \(wait, format: .fixed(precision: 1)) s left") }
            limiter.started(at: now)
            state.lockoutThreshold = settings.faceUnlockLockout
            matcher.threshold = Float(settings.faceUnlockThreshold)
        }
        lastError = nil; lastScore = nil // per-scan values in the log line
        send(.triggered)
        scanTask = Task { [weak self] in
            guard let self else { return }
            if self.useCamera { await self.realScan() } else { await self.fakeScan() }
        }
    }

    /// Cursor left, Esc, sleep. Ignored once the password is being entered.
    func cancel() {
        send(.cancelled)
    }

    // MARK: Real pipeline

    /// FaceNet, loaded on first use. Nil if the model is missing or fails to load.
    nonisolated static let recognizer: CoreMLFaceRecognizer? = try? CoreMLFaceRecognizer()

    /// One camera session for the whole scan: find a face, run the liveness challenge, then match
    /// the embeddings taken from the frames of that same challenge. A camera that stops early is
    /// an error (cancel, not counted).
    private func realScan() async {
        let templates = (try? TemplateStore().load()) ?? []
        guard !templates.isEmpty, let recognizer = Self.recognizer else {
            lastError = templates.isEmpty ? "Not enrolled" : "Face model failed to load"
            return send(.cancelled)
        }
        let challenge = Self.challenges(for: settings.faceUnlockLiveness).randomElement()!
        let camera = FaceCaptureService()
        let watchdog = Task { try? await Task.sleep(for: .seconds(8)); camera.stop() }
        defer { watchdog.cancel(); camera.stop() }
        let gate = FaceGate()
        // While the head turns or blinks, quality dips and the face drifts: embed any single,
        // large enough face, not only frames that pass the strict entry gate.
        let embedGate = FaceGate(maxCentreOffset: 0.35, minQuality: 0)
        let findDeadline = Date.now.addingTimeInterval(2)
        var liveness: LivenessChecker?
        var passedAt: Double?
        var embeddings: [[Float]] = []
        do {
            for await frame in try await camera.start() {
                guard !Task.isCancelled else { return }
                let wantEmbedding = liveness != nil
                let (faces, embedding) = await Task.detached { () -> ([FaceSample], [Float]?) in
                    let faces = (try? FaceDetector.detect(frame)) ?? []
                    guard wantEmbedding, case .ok(let face) = embedGate.check(faces) else { return (faces, nil) }
                    return (faces, try? recognizer.embedding(of: frame, face: face))
                }.value
                guard !Task.isCancelled else { return }

                guard var checker = liveness else {
                    let verdict = gate.check(faces)
                    if case .ok = verdict {
                        liveness = LivenessChecker(challenge: challenge)
                        send(.faceFound(challenge))
                    } else if verdict == .multipleFaces {
                        send(.multipleFaces)
                        return await finishFailure()
                    } else if Date.now > findDeadline {
                        send(.noFace)
                        return await finishFailure()
                    }
                    continue
                }
                if let embedding { embeddings.append(embedding) }

                if let passedAt {
                    // Liveness passed on too few embeddable frames: collect a few more (still
                    // exactly one face) for up to 1 s, then match.
                    guard faces.count <= 1 else { lastError = "Second face after liveness"; return send(.cancelled) }
                    if embeddings.count < matcher.minimumFrames, frame.time - passedAt < 1 { continue }
                    return await match(embeddings, templates: templates, camera: camera)
                }
                switch checker.feed(faces, at: frame.time) {
                case .pending:
                    liveness = checker
                case .failed(let reason):
                    lastError = "Liveness: \(reason)"
                    send(.livenessFailed)
                    return await finishFailure()
                case .passed:
                    send(.livenessPassed)
                    if embeddings.count >= matcher.minimumFrames {
                        return await match(embeddings, templates: templates, camera: camera)
                    }
                    passedAt = frame.time
                }
            }
        } catch {
            lastError = "Camera: \(error)"
            return send(.cancelled)
        }
        if !Task.isCancelled {
            lastError = "Camera stopped during the scan"
            send(.cancelled)
        }
    }

    private func match(_ embeddings: [[Float]], templates: [[Float]], camera: FaceCaptureService) async {
        camera.stop()
        guard embeddings.count >= matcher.minimumFrames else {
            // Not the user's fault (e.g. the face was turned away the whole time): not counted.
            lastError = "Only \(embeddings.count) usable frames"
            return send(.cancelled)
        }
        let scores = embeddings.map { FaceMatcher.score($0, templates: templates) }.sorted()
        lastScore = scores[scores.count / 2]
        let ok = matcher.matches(embeddings, templates: templates)
        send(ok ? .matched : .notMatched)
        guard ok else { return await finishFailure() }
        await enterPassword()
    }

    /// Lock-screen password entry. Exactly one attempt; any problem goes to `.entryFailed`,
    /// which locks Face Unlock out until a normal unlock, so a bad password is never retried.
    private func enterPassword() async {
        var password: [UInt8]
        do {
            password = try await CredentialVault.shared.verifiedPassword()
        } catch {
            lastError = error as? CredentialVault.VaultError == .wrongPassword
                ? "Stored password no longer matches; update it in Settings" : "No stored password"
            send(.entryFailed)
            return await finishFailure()
        }
        defer { password.resetBytes() }
        guard !Task.isCancelled, state.phase == .unlocking else { return }
        if await input.enterPassword(password) {
            send(.entered) // the unlock notification follows and resets everything
        } else {
            lastError = CGEventLockScreenInput.isAllowed ? "Lock screen did not unlock" : "No Accessibility access"
            send(.entryFailed)
            await finishFailure()
        }
    }

    nonisolated static func challenges(for liveness: FaceUnlockLiveness) -> [FaceUnlockState.Challenge] {
        switch liveness {
        case .blink: [.blink]
        case .turn: [.turnLeft, .turnRight]
        case .both: FaceUnlockState.Challenge.allCases
        }
    }

    // MARK: Fake pipeline (demo window)

    private func fakeScan() async {
        let outcome = fakeOutcome
        let challenge = FaceUnlockState.Challenge.allCases.randomElement()!
        guard await step(0.7, outcome == .noFace ? .noFace : .faceFound(challenge)), outcome != .noFace,
              await step(1.4, outcome == .livenessFails ? .livenessFailed : .livenessPassed), outcome != .livenessFails,
              await step(0.6, outcome == .notRecognised ? .notMatched : .matched), outcome != .notRecognised,
              await step(0.6, outcome == .entryFails ? .entryFailed : .entered), outcome != .entryFails
        else { return await finishFailure() }
    }

    /// Waits, then sends `event` unless the scan was cancelled meanwhile.
    private func step(_ seconds: Double, _ event: FaceUnlockState.Event) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return false }
        send(event)
        return true
    }

    private func finishFailure() async {
        guard case .failure = state.phase else { return }
        try? await Task.sleep(for: .seconds(1.6)) // long enough to read the message
        guard !Task.isCancelled else { return }
        send(.failureShown)
    }

    // MARK: Copy

    /// Notch text and VoiceOver announcement for each phase.
    static func message(for phase: FaceUnlockState.Phase) -> String? {
        switch phase {
        case .idle, .disabled: nil
        case .armed: "Face Unlock"
        case .scanning: "Scanning"
        case .liveness(.blink): "Blink"
        case .liveness(.turnLeft): "Turn head left"
        case .liveness(.turnRight): "Turn head right"
        case .matching: "Checking"
        case .unlocking: "Unlocking"
        case .success: "Unlocked"
        case .failure(.noFace): "No face found"
        case .failure(.multipleFaces): "Only one face, please"
        case .failure(.liveness), .failure(.notRecognised): "Not recognised. Try again"
        case .failure(.entry): "Couldn't unlock. Use password"
        case .lockedOut: "Use password"
        }
    }
}
