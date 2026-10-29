import SwiftUI

/// Face ID-style enrolment ring: mirrored camera image in a circle, surrounded by tick marks that
/// grow and turn green as each direction is captured. Ticks near the current head direction are
/// highlighted so the user sees where to move next.
struct EnrolmentRing: View {
    let session: EnrolmentSession
    var diameter: CGFloat = 220

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ticks = 72

    var body: some View {
        let plan = session.plan
        ZStack {
            preview
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            ForEach(0..<ticks, id: \.self) { i in
                let lit = isLit(i, plan)
                Capsule()
                    .fill(lit ? Color.green : (isNearHead(i) ? Color.white.opacity(0.8) : Color.white.opacity(0.25)))
                    .frame(width: 3, height: lit ? 18 : 10)
                    .offset(y: -(diameter / 2 + 18))
                    // Tick 0 at screen right, counter-clockwise, matching `EnrolmentPlan.sector`.
                    .rotationEffect(.radians(.pi / 2 - angle(i)))
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.6), value: lit)
            }
            if session.finished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: diameter + 60, height: diameter + 60)
        .animation(LG.Motion.ui(reduceMotion: reduceMotion), value: session.finished)
        .accessibilityElement()
        .accessibilityLabel("Face enrolment")
        .accessibilityValue("\(Int(plan.progress * 100)) percent. \(session.hint)")
    }

    @ViewBuilder private var preview: some View {
        if let image = session.preview {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color.black.overlay(Image(systemName: "faceid").font(.system(size: 60)).foregroundStyle(.white.opacity(0.4)))
        }
    }

    private func angle(_ i: Int) -> Double { Double(i) / Double(ticks) * 2 * .pi }

    /// Centre frames light the whole ring dimly in steps; each sector lights its own ticks.
    private func isLit(_ i: Int, _ plan: EnrolmentPlan) -> Bool {
        if plan.isComplete { return true }
        return plan.filled.contains(Int(angle(i) / (2 * .pi) * Double(plan.sectors)) % plan.sectors)
    }

    private func isNearHead(_ i: Int) -> Bool {
        guard let d = session.headDirection, (d.x * d.x + d.y * d.y).squareRoot() > 0.08 else { return false }
        var head = atan2(d.y, d.x)
        if head < 0 { head += 2 * .pi }
        let diff = abs(angle(i) - head)
        return min(diff, 2 * .pi - diff) < .pi / 10
    }
}
