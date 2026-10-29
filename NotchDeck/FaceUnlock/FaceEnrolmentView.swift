import SwiftUI
import Observation

/// Enrol the face and read live match scores to calibrate the threshold. Opened with
/// `NotchDeck -FaceUnlockEnrol` until the Settings tab exists (step 6).
struct FaceEnrolmentView: View {
    @State private var enrolment: EnrolmentSession?
    @State private var calibration = FaceCalibration()
    @State private var enrolled = ((try? TemplateStore().load()) ?? []).count
    @State private var password = ""
    @State private var passwordStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LG.Space.m) {
            Text("Face Unlock (software, camera-based)").font(LG.Font.title)
            Text("This is weaker than your password or Touch ID: anyone who can fool the camera check can unlock this Mac. Face data stays on this Mac, in the keychain, as numbers only, never photos.")
                .font(LG.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox("Enrol") {
                VStack(alignment: .leading, spacing: LG.Space.xs) {
                    if let enrolment {
                        EnrolmentRing(session: enrolment).frame(maxWidth: .infinity)
                        Text(enrolment.error ?? (enrolment.finished ? "Enrolled" : enrolment.hint))
                            .font(LG.Font.headline).frame(maxWidth: .infinity)
                    } else {
                        Text(enrolled > 0 ? "\(enrolled) templates stored." : "Not enrolled.")
                    }
                    HStack {
                        Button(enrolled > 0 ? "Re-enrol" : "Enrol") { startEnrolment() }
                            .disabled(FaceUnlockCoordinator.recognizer == nil || enrolment.map { !$0.finished && $0.error == nil } == true)
                        Button("Delete face data", role: .destructive) {
                            TemplateStore().wipe(); enrolled = 0; enrolment = nil
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Login password") {
                VStack(alignment: .leading, spacing: LG.Space.xs) {
                    Text("Typed into the lock screen after a verified scan. Checked against your account before it's saved. Stored only in this Mac's keychain, readable only by NotchDeck.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecureField("Password", text: $password).frame(width: 200)
                            .onSubmit(savePassword)
                        Button("Save", action: savePassword).disabled(password.isEmpty)
                        Button("Delete", role: .destructive) {
                            Task { await CredentialVault.shared.wipe(); passwordStatus = "Deleted" }
                        }
                    }
                    Text(passwordStatus).foregroundStyle(.secondary)
                    if !CGEventLockScreenInput.isAllowed {
                        Text("Void needs Accessibility access to type the password.").foregroundStyle(.red)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .task { passwordStatus = await CredentialVault.shared.isStored ? "Stored" : "Not stored" }

            GroupBox("Calibrate") {
                VStack(alignment: .leading, spacing: LG.Space.xs) {
                    Text("Live score against your templates. Match needs ≥ \(FaceUnlockCoordinator.shared.matcher.threshold, specifier: "%.2f"). Try yourself, a photo on a phone, and another person.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(calibration.score.map { String(format: "%.3f", $0) } ?? "–").font(LG.Font.numeric.monospacedDigit()).font(.largeTitle)
                    Text(calibration.status).foregroundStyle(.secondary)
                    Button(calibration.running ? "Stop" : "Start camera") {
                        calibration.running ? calibration.stop() : calibration.start()
                    }
                    .disabled(enrolled == 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if FaceUnlockCoordinator.recognizer == nil { Text("Face model failed to load.").foregroundStyle(.red) }
        }
        .padding(LG.Space.l)
        .frame(width: 440)
        .onDisappear { enrolment?.cancel(); calibration.stop() }
    }

    private func savePassword() {
        var bytes = Array(password.utf8)
        password = "" // the field's String can't be zeroed; drop it at once
        passwordStatus = "Checking…"
        Task {
            do {
                try await CredentialVault.shared.store(&bytes)
                passwordStatus = "Stored"
            } catch {
                passwordStatus = error as? CredentialVault.VaultError == .wrongPassword ? "That isn't your login password" : "Couldn't save"
            }
        }
    }

    private func startEnrolment() {
        guard let recognizer = FaceUnlockCoordinator.recognizer else { return }
        calibration.stop()
        let session = EnrolmentSession(recognizer: recognizer)
        enrolment = session
        session.start()
        Task {
            while !session.finished, session.error == nil { try? await Task.sleep(for: .milliseconds(300)) }
            enrolled = ((try? TemplateStore().load()) ?? []).count
        }
    }

    @MainActor private static var window: NSWindow?
    @MainActor static func open() {
        let w = window ?? NSWindow(contentViewController: NSHostingController(rootView: FaceEnrolmentView()))
        w.title = "Face Unlock"
        w.isReleasedWhenClosed = false
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

/// Streams live match scores (no liveness, no unlocking) so the threshold can be set from data.
@MainActor @Observable
final class FaceCalibration {
    private(set) var score: Float?
    private(set) var status = ""
    private(set) var running = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var camera: FaceCaptureService?

    func start() {
        guard let recognizer = FaceUnlockCoordinator.recognizer, let templates = try? TemplateStore().load(), !templates.isEmpty else {
            status = "Enrol first"; return
        }
        let camera = FaceCaptureService()
        self.camera = camera
        running = true
        task = Task { [weak self] in
            defer { camera.stop(); self?.running = false }
            let gate = FaceGate()
            do {
                for await frame in try await camera.start() {
                    guard !Task.isCancelled else { return }
                    let (verdict, score) = await Task.detached { () -> (FaceGate.Verdict, Float?) in
                        let verdict = gate.check((try? FaceDetector.detect(frame)) ?? [])
                        guard case .ok(let face) = verdict, let e = try? recognizer.embedding(of: frame, face: face) else { return (verdict, nil) }
                        return (verdict, FaceMatcher.score(e, templates: templates))
                    }.value
                    self?.score = score
                    self?.status = score == nil ? "Gate: \(verdict)" : "Face OK"
                }
            } catch {
                self?.status = "Camera: \(error)"
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        camera?.stop(); camera = nil
        running = false
    }
}
