import SwiftUI

/// The Face ID glyph as Apple Pay / Wallet animates it: the face glyph breathes while looking,
/// turns into a spinning arc while checking, and closes into a circle with a drawn checkmark on
/// success. Shakes red on failure (the notch shake does the movement).
struct WalletFaceIDGlyph: View {
    let phase: FaceUnlockState.Phase

    /// Wallet's confirmation blue.
    static let done = Color(nsColor: .systemBlue)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false
    @State private var check: CGFloat = 0

    private enum Look: Equatable { case face, spinner, done, failed }

    private var look: Look {
        switch phase {
        case .matching: .spinner
        case .unlocking, .success: .done
        case .failure, .lockedOut: .failed
        default: .face
        }
    }

    var body: some View {
        ZStack {
            switch look {
            case .face, .failed:
                Image(systemName: "faceid")
                    .resizable().scaledToFit()
                    .fontWeight(.light)
                    .foregroundStyle(look == .failed ? Color.red : .white)
                    .symbolEffect(.pulse, options: .repeating, isActive: look == .face && !reduceMotion)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .spinner:
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
                    .transition(.scale(scale: 1.3).combined(with: .opacity))
            case .done:
                ZStack {
                    Circle().stroke(Self.done, lineWidth: 3)
                    Checkmark()
                        .trim(from: 0, to: check)
                        .stroke(Self.done, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .padding(10)
                }
                .onAppear {
                    check = 0
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.35).delay(0.1)) { check = 1 }
                }
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: look)
        .accessibilityHidden(true)
    }
}

/// Checkmark stroke in a unit square, drawn left to right so `trim` animates it like Wallet.
private struct Checkmark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.02))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY - r.height * 0.12))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.14))
        return p
    }
}
