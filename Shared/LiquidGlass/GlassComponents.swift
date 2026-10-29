import SwiftUI
import AppKit

// MARK: - Card

/// Floating glass container with an optional caption title. A scrim sits under the white text
/// by default: glass over a bright wallpaper is light grey, and white on it failed 4.5:1.
struct GlassCard<Content: View>: View {
    var title: String?
    var variant: GlassVariant = .regular
    var tint: Color?
    var scrim = true
    var padding: CGFloat = LG.Space.m
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: LG.Radius.card, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: LG.Space.xs) {
            if let title {
                Text(title.uppercased()).font(LG.Font.caption).foregroundStyle(LG.Tone.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if scrim { GlassScrim().clipShape(shape) } }
        .liquidGlass(variant, in: shape, tint: tint)
        .elevation(.raised)
        .foregroundStyle(LG.Tone.primary)
    }
}

// MARK: - Button

/// Glass capsule. 44 pt hit area, press scale + dim, hover lift, keyboard focus ring.
struct GlassButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, prominent: prominent, tint: tint)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(LG.Font.body.weight(.semibold))
            .padding(.horizontal, LG.Space.m)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
            .background { if !prominent { GlassScrim().clipShape(Capsule()) } }
            .liquidGlass(prominent ? .prominent : .regular, in: Capsule(), tint: tint, interactive: true)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? LG.Motion.pressScale : hovering ? LG.Motion.hoverScale : 1)
            .elevation(hovering && !configuration.isPressed ? .raised : .rest)
            .overlay { if isFocused { Capsule().stroke(LG.accent, lineWidth: 2).padding(-3) } }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 && isEnabled }
            .animation(LG.Motion.ui(reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(LG.Motion.ui(reduceMotion: reduceMotion), value: hovering)
    }
}

/// Icon, text, or both. Icon-only buttons need `label` for VoiceOver.
struct GlassButton: View {
    var title: String?
    var systemImage: String?
    var label: String?
    var prominent = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LG.Space.xs) {
                if let systemImage { Image(systemName: systemImage) }
                if let title { Text(title) }
            }
        }
        .buttonStyle(GlassButtonStyle(prominent: prominent, tint: tint))
        .accessibilityLabel(label ?? title ?? "")
    }
}

// MARK: - Slider

/// Playback scrubber: thin track, white fill, knob only while dragging, `m:ss` / `-m:ss` labels,
/// haptic detents at each quarter.
struct GlassSlider: View {
    /// Elapsed seconds.
    let value: Double
    let duration: Double
    var showsTimes = true
    /// Played part of the track; the notch uses the artwork colour.
    var fill: Color = .primary
    /// Fixed track thickness (grows 2 pt while dragging). Nil keeps the original look, where the
    /// track fills the row (about 12 pt).
    var trackHeight: CGFloat? = nil
    var onSeek: (Double) -> Void

    @State private var dragValue: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Double { dragValue ?? value }
    private var track: CGFloat? { trackHeight.map { dragValue == nil ? $0 : $0 + 2 } }
    private var fraction: Double { duration > 0 ? min(max(shown / duration, 0), 1) : 0 }

    var body: some View {
        HStack(spacing: LG.Space.s) {
            if showsTimes { time(formatTime(shown)).frame(width: 40, alignment: .leading) }
            GeometryReader { g in
                let dragging = dragValue != nil
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.2)).frame(height: track)
                    Capsule().fill(fill).frame(width: max(0, g.size.width * fraction), height: track)
                    Circle().fill(Color.primary)
                        .frame(width: 12, height: 12)
                        .elevation(.rest)
                        .offset(x: g.size.width * fraction - 6)
                        .opacity(dragging ? 1 : 0)
                        .scaleEffect(dragging ? 1 : 0.4)
                }
                .frame(height: dragging ? 7 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard duration > 0 else { return }
                        let new = min(max(drag.location.x / g.size.width, 0), 1) * duration
                        if let old = dragValue, Int(old / duration * 4) != Int(new / duration * 4) {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                        dragValue = new
                    }
                    .onEnded { _ in
                        if let v = dragValue { onSeek(v) }
                        dragValue = nil
                    })
                .animation(LG.Motion.ui(reduceMotion: reduceMotion), value: dragging)
            }
            .frame(height: 20)
            if showsTimes { time(remainingTime(elapsed: shown, duration: duration)).frame(width: 44, alignment: .trailing) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(shown)) of \(formatTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(duration, value + 10))
            case .decrement: onSeek(max(0, value - 10))
            @unknown default: break
            }
        }
    }

    private func time(_ s: String) -> some View {
        Text(s).font(LG.Font.numeric).foregroundStyle(LG.Tone.secondary)
    }
}
