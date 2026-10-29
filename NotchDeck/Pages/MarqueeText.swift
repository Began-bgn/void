import SwiftUI

/// Single-line text that scrolls horizontally only when it does not fit.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 14, weight: .semibold)
    var color: Color = .white

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private let lowPower = LowPowerMode.shared
    /// Low Power Mode truncates instead of scrolling, like Reduce Motion.
    private var reduceMotion: Bool { systemReduceMotion || lowPower.isOn }
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var phase: CGFloat = 0

    private let gap: CGFloat = 32
    private var overflows: Bool { textWidth > boxWidth + 0.5 && boxWidth > 0 }

    var body: some View {
        Group {
            if reduceMotion {
                Text(text).font(font).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
            } else {
                HStack(spacing: gap) {
                    label.background(GeometryReader { g in
                        Color.clear
                            .onAppear { textWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in textWidth = w }
                    })
                    if overflows { label }
                }
                .offset(x: phase)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { boxWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in boxWidth = w }
        })
        .clipped()
        .task(id: "\(text)|\(overflows)|\(reduceMotion)") { await scroll() }
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private func scroll() async {
        withTransaction(Transaction(animation: nil)) { phase = 0 }
        guard overflows, !reduceMotion else { return }
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled else { return }
        let distance = textWidth + gap
        withAnimation(.linear(duration: Double(distance) / 30).repeatForever(autoreverses: false)) {
            phase = -distance
        }
    }
}
