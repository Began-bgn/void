import SwiftUI

/// Settings → Face Unlock.
struct FaceUnlockPane: View {
    @Bindable private var s = SettingsStore.shared
    private let coordinator = FaceUnlockCoordinator.shared
    @State private var confirmEnable = false
    @State private var confirmDelete = false
    @State private var templates = 0
    @State private var passwordStored = false

    var body: some View {
        Section {
            Toggle("Face Unlock (software, camera-based)", isOn: Binding(
                get: { s.faceUnlockEnabled },
                set: { on in if on { confirmEnable = true } else { s.faceUnlockEnabled = false } }))
            .disabled(FaceUnlockSupport.blocker != nil)
        } footer: {
            Text(FaceUnlockSupport.blocker.map { "Unavailable: \($0)." } ?? """
                Hover the notch on the lock screen to scan your face; on a live match NotchDeck types your \
                password. This is weaker than your password or Touch ID: anyone who can fool the camera \
                check, or read the stored password, can unlock this Mac. Not Face ID. Your password is \
                always needed after a restart.\(LockScreenSupport.isTestedOS ? "" : " Experimental on macOS \(LockScreenSupport.osMajor).")
                """)
        }
        .alert("Turn on Face Unlock?", isPresented: $confirmEnable) {
            Button("Turn On") { s.faceUnlockEnabled = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It makes this Mac easier to unlock for anyone who can fool a 2D camera or read the stored password. Use it only on a Mac you alone use.")
        }

        Section("Face and password") {
            LabeledContent("Face") { Text(templates > 0 ? "Enrolled (\(templates) samples)" : "Not enrolled").foregroundStyle(.secondary) }
            LabeledContent("Password") { Text(passwordStored ? "Stored" : "Not stored").foregroundStyle(.secondary) }
            Button(templates > 0 ? "Re-enrol Face or Update Password…" : "Enrol Face and Password…") { FaceEnrolmentView.open() }
        }

        Section("Trigger") {
            Picker("Start a scan by", selection: $s.faceUnlockTrigger) {
                Text("Hovering the notch").tag(FaceUnlockTrigger.hover)
                Text("Clicking the notch").tag(FaceUnlockTrigger.click)
                Text("Waking the screen").tag(FaceUnlockTrigger.wake)
            }
            LabeledContent("Hover time") {
                Slider(value: $s.faceUnlockDwell, in: 0.3...3, step: 0.1) { Text("Hover time") }
                    .labelsHidden().frame(width: 200)
                Text("\(s.faceUnlockDwell, specifier: "%.1f") s").monospacedDigit().frame(width: 40)
            }
            .disabled(s.faceUnlockTrigger != .hover)
        }

        Section {
            Picker("Liveness prompt", selection: $s.faceUnlockLiveness) {
                Text("Blink").tag(FaceUnlockLiveness.blink)
                Text("Turn head").tag(FaceUnlockLiveness.turn)
                Text("Blink or turn (random)").tag(FaceUnlockLiveness.both)
            }
            LabeledContent("Match strictness") {
                Slider(value: $s.faceUnlockThreshold, in: 0.55...0.9, step: 0.01) { Text("Match strictness") }
                    minimumValueLabel: { Text("Lenient") } maximumValueLabel: { Text("Strict") }
                    .labelsHidden().frame(width: 240)
            }
            Stepper("Lock out after \(s.faceUnlockLockout) failed scans", value: $s.faceUnlockLockout, in: 1...10)
        } header: {
            Text("Checks")
        } footer: {
            Text("Strictness \(s.faceUnlockThreshold, specifier: "%.2f"): how similar to your enrolled face a scan must be. Higher rejects other people more reliably but may reject you in poor light. It does not stop photos; the liveness prompt does. After the lockout, unlock once with your password or Touch ID.")
        }

        Section("Diagnostics") {
            LabeledContent("Camera") { Text(FaceCaptureService.builtInCamera == nil ? "Not found" : FaceCaptureService.isAuthorized ? "Available" : "No permission").foregroundStyle(.secondary) }
            LabeledContent("Face model") { Text(FaceUnlockCoordinator.recognizer == nil ? "Failed to load" : "FaceNet loaded").foregroundStyle(.secondary) }
            LabeledContent("Password entry") { Text(CGEventLockScreenInput.isAllowed ? "Accessibility granted" : "Needs Accessibility").foregroundStyle(.secondary) }
            LabeledContent("Code signature") { Text(FaceUnlockSupport.codeSignatureValid ? "Valid" : "Invalid").foregroundStyle(.secondary) }
            LabeledContent("Failed scans") { Text("\(coordinator.state.failures) of \(s.faceUnlockLockout)").monospacedDigit().foregroundStyle(.secondary) }
            if let score = coordinator.lastScore {
                LabeledContent("Last match score") { Text(String(format: "%.2f", score)).monospacedDigit().foregroundStyle(.secondary) }
            }
            if let error = coordinator.lastError {
                LabeledContent("Last error") { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }

        Section {
            Button("Turn Off and Delete All Face Data and Password", role: .destructive) { confirmDelete = true }
        } footer: {
            Text("Kill switch, also in the menu bar: turns Face Unlock off and deletes the stored password and face samples from the keychain.")
        }
        .alert("Delete face data and password?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { coordinator.killSwitch(); Task { await reload() } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await reload() }
    }

    private func reload() async {
        templates = ((try? TemplateStore().load()) ?? []).count
        passwordStored = await CredentialVault.shared.isStored
    }
}
