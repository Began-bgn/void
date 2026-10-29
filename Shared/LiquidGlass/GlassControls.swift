import SwiftUI

// Settings controls. Rule: glass only on the selection thumb; tracks and wells stay flat so
// there is never glass on glass.

// MARK: - Toggle

struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassToggleBody(configuration: configuration)
    }
}

private struct GlassToggleBody: View {
    let configuration: ToggleStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var noColor

    var body: some View {
        HStack {
            configuration.label
            Spacer(minLength: LG.Space.s)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? LG.accent : Color.primary.opacity(0.15))
                // On/off glyph inside the track for Differentiate Without Colour.
                if noColor {
                    Image(systemName: configuration.isOn ? "checkmark" : "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: configuration.isOn ? .leading : .trailing)
                        .padding(.horizontal, 8)
                }
                // White knob under the glass, like the system switch: a clear knob read as part of the track.
                Circle().fill(.white)
                    .frame(width: 22, height: 22)
                    .liquidGlass(.regular, in: Circle(), interactive: true)
                    .elevation(.rest)
                    .padding(2)
            }
            .frame(width: 44, height: 26)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .animation(LG.Motion.ui(reduceMotion: reduceMotion), value: configuration.isOn)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

// MARK: - Segmented control / picker

/// Segmented picker; the selected segment is a glass thumb that slides between options.
struct GlassSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Text(option.title)
                    .font(LG.Font.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? LG.Tone.primary : LG.Tone.secondary)
                    .padding(.horizontal, LG.Space.s)
                    .frame(minHeight: 28)
                    .background {
                        if selected {
                            Capsule().fill(.white.opacity(0.01))
                                .liquidGlass(.regular, in: Capsule())
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(LG.Motion.ui(reduceMotion: reduceMotion)) { selection = option.value } }
                    .accessibilityElement()
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

// MARK: - Stepper

/// − value + in a flat well; 44 pt wide targets.
struct GlassStepper: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...100
    var step = 1

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", "Decrease") { value = max(range.lowerBound, value - step) }
                .disabled(value <= range.lowerBound)
            Text("\(value)").font(LG.Font.numeric).frame(minWidth: 32)
            stepButton("plus", "Increase") { value = min(range.upperBound, value + step) }
                .disabled(value >= range.upperBound)
        }
        .background(Color.primary.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { d in
            value = d == .increment ? min(range.upperBound, value + step) : max(range.lowerBound, value - step)
        }
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 44, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Settings rows

/// Sidebar row: coloured icon tile + label; the selected row sits on glass.
struct GlassSidebarRow: View {
    let title: String
    let systemImage: String
    var color: Color = .blue
    var selected = false

    var body: some View {
        HStack(spacing: LG.Space.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title).font(LG.Font.body)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LG.Space.xs)
        .frame(minHeight: 32)
        .background {
            if selected { Capsule().fill(.white.opacity(0.01)).liquidGlass(.regular, in: Capsule()) }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Form row: label left, control right, helper text below, optional reset.
struct GlassSettingsRow<Control: View>: View {
    let title: String
    var help: String?
    var onReset: (() -> Void)?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: LG.Space.xxs) {
            HStack(spacing: LG.Space.s) {
                Text(title).font(LG.Font.body)
                Spacer(minLength: LG.Space.s)
                control
                if let onReset {
                    Button(action: onReset) { Image(systemName: "arrow.counterclockwise").font(LG.Font.caption) }
                        .buttonStyle(.plain)
                        .foregroundStyle(LG.Tone.secondary)
                        .frame(width: 24, height: 24)
                        .help("Reset to default")
                        .accessibilityLabel("Reset \(title)")
                }
            }
            if let help {
                Text(help).font(LG.Font.caption).foregroundStyle(LG.Tone.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, LG.Space.xs)
    }
}

/// Caption-style section header for grouped settings.
struct GlassSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(LG.Font.caption).foregroundStyle(LG.Tone.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
