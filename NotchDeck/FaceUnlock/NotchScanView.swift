import SwiftUI

/// Face Unlock UI in the closed notch on the lock screen. Black like the hardware notch (glass
/// stays on controls, per the Liquid Glass rules); grows into a pill while scanning.
struct NotchScanView: View {
    let notchSize: CGSize
    var coordinator = FaceUnlockCoordinator.shared
    private let settings = SettingsStore.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakes = 0

    static let sideWidth: CGFloat = 36
    static let expandedSize = CGSize(width: 260, height: 84)
    static let hintHeight: CGFloat = 24

    /// Window big enough for the expanded pill, flush with the top centre of `screen`.
    static func windowFrame(on screen: NSScreen) -> CGRect {
        let n = screen.notchSize
        return screen.topCentered(CGSize(width: max(n.width + 80, expandedSize.width) + 24, height: n.height + expandedSize.height + 12))
    }

    private var phase: FaceUnlockState.Phase { coordinator.state.phase }
    private var expanded: Bool {
        switch phase {
        case .scanning, .liveness, .matching, .unlocking, .success, .failure: true
        default: false
        }
    }
    private var showsHint: Bool { coordinator.dwellProgress > 0 || phase == .lockedOut }

    private var size: CGSize {
        if expanded {
            return CGSize(width: max(notchSize.width + 80, Self.expandedSize.width), height: notchSize.height + Self.expandedSize.height)
        }
        return CGSize(width: notchSize.width + Self.sideWidth * 2, height: notchSize.height + (showsHint ? Self.hintHeight : 0))
    }

    private var tint: Color {
        switch phase {
        case .success, .unlocking: .green
        case .failure, .lockedOut: .red
        default: .white
        }
    }

    var body: some View {
        let shape = NotchShape(topRadius: 6, bottomRadius: expanded ? 22 : 10)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            if expanded { scanContent.transition(.opacity) } else { compactContent.transition(.opacity) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        // Hit area is the notch itself, not the whole (larger) window.
        .contentShape(shape)
        .onHover { coordinator.hover($0) }
        .onTapGesture { coordinator.trigger() }
        .modifier(Shake(amount: reduceMotion ? 0 : 8, shakes: CGFloat(shakes)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(LG.Motion.morph(reduceMotion: reduceMotion), value: expanded)
        .animation(LG.Motion.ui(reduceMotion: reduceMotion), value: showsHint)
        .animation(LG.Motion.ui(reduceMotion: reduceMotion), value: phase)
        .onChange(of: phase) { _, new in
            if case .failure = new { withAnimation(.linear(duration: 0.4)) { shakes += 1 } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Face Unlock (software, camera-based)")
        .accessibilityValue(FaceUnlockCoordinator.message(for: phase) ?? "")
        .accessibilityAddTraits(.isButton)
        .ignoresSafeArea()
    }

    // MARK: Closed notch

    private var compactContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PadlockGlyph(locking: true, tint: phase == .lockedOut ? .red : settings.lockPadlockTint, animated: false)
                    .frame(width: Self.sideWidth)
                Spacer(minLength: notchSize.width)
                ring(progress: coordinator.dwellProgress, symbol: "faceid", size: 18)
                    .opacity(coordinator.dwellProgress > 0 ? 1 : 0)
                    .frame(width: Self.sideWidth)
            }
            .frame(height: notchSize.height)
            if showsHint {
                Text(phase == .lockedOut ? "Use password" : "Face Unlock")
                    .font(LG.Font.caption)
                    .foregroundStyle(phase == .lockedOut ? Color.red : Color.white.opacity(0.8))
                    .frame(height: Self.hintHeight)
            }
        }
    }

    // MARK: Scanning pill (Apple Pay / Wallet Face ID style)

    private var scanContent: some View {
        VStack(spacing: 6) {
            WalletFaceIDGlyph(phase: phase)
                .frame(width: 38, height: 38)
            HStack(spacing: 5) {
                if let arrow { Image(systemName: arrow) }
                Text(FaceUnlockCoordinator.message(for: phase) ?? "").contentTransition(.opacity)
            }
            .font(LG.Font.caption.weight(.semibold))
            .foregroundStyle(phase == .success || phase == .unlocking ? WalletFaceIDGlyph.done : tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, notchSize.height + 6)
        .padding(.bottom, 8)
    }

    private var arrow: String? {
        switch phase {
        case .liveness(.turnLeft): "arrow.left"
        case .liveness(.turnRight): "arrow.right"
        case .liveness(.blink): "eye"
        default: nil
        }
    }

    private func ring(progress: Double, symbol: String, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: size * 0.07)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
    }
}

/// Horizontal shake; `shakes` is bumped once per failure.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(shakes * .pi * 4), y: 0))
    }
}
