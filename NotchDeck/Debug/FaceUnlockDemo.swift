#if DEBUG
import SwiftUI

/// `NotchDeck -FaceUnlockDemo`: the notch scan UI in a normal window, driven by fake results, so
/// every state can be checked without locking the Mac.
struct FaceUnlockDemo: View {
    @Bindable private var coordinator = FaceUnlockCoordinator.shared
    private let notch = NSScreen.screens.first?.notchSize ?? CGSize(width: 180, height: 32)

    var body: some View {
        VStack(spacing: LG.Space.m) {
            NotchScanView(notchSize: notch)
                .frame(height: notch.height + NotchScanView.expandedSize.height)
            Text("Hover the notch for \(coordinator.dwell, specifier: "%.1f") s or click it. Move away to cancel.")
                .font(LG.Font.caption).foregroundStyle(.secondary)
            Picker("Fake result", selection: $coordinator.fakeOutcome) {
                ForEach(FaceUnlockCoordinator.FakeOutcome.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 280)
            HStack {
                Button("Enable") { coordinator.send(.enabled(true)) }
                Button("Disable") { coordinator.send(.enabled(false)) }
                Button("Lock") { coordinator.send(.locked) }
                Button("Unlock") { coordinator.send(.unlocked) }
            }
            Text("Phase: \(String(describing: coordinator.state.phase)) · failures \(coordinator.state.failures)/\(coordinator.state.lockoutThreshold)")
                .font(LG.Font.numeric)
        }
        .padding(.bottom, LG.Space.l)
        .frame(width: 460)
        .background(Color(white: 0.25))
    }

    @MainActor static func open() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: FaceUnlockDemo()))
        window.title = "Face Unlock demo"
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFrontRegardless()
        demo = window
        FaceUnlockCoordinator.shared.useCamera = CommandLine.arguments.contains("-FaceUnlockCamera")
        FaceUnlockCoordinator.shared.send(.enabled(true))
        FaceUnlockCoordinator.shared.send(.locked)
    }
    @MainActor private static var demo: NSWindow?
}
#endif
