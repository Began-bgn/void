import SwiftUI

// Small parts: list row, chip, badge, tooltip, empty state, alert. Each sits on whatever glass
// surface hosts it, so only the chip (a floating control) and the alert carry glass of their own.

/// Icon, title, subtitle, trailing accessory; highlights on hover. No glass (it lives in a card).
struct GlassListRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: LG.Space.s) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 14, weight: .medium)).frame(width: 24)
                    .foregroundStyle(LG.Tone.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(LG.Font.body)
                if let subtitle { Text(subtitle).font(LG.Font.caption).foregroundStyle(LG.Tone.secondary) }
            }
            Spacer(minLength: LG.Space.xs)
            trailing
        }
        .padding(.horizontal, LG.Space.s)
        .frame(minHeight: 44)
        .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: LG.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(LG.Motion.fade, value: hovering)
        .accessibilityElement(children: .combine)
    }
}

extension GlassListRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

/// Filter / tag capsule. Selected chips are prominent (tinted) glass.
struct GlassChip: View {
    let title: String
    var systemImage: String?
    var selected = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: LG.Space.xxs) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(LG.Font.caption)
            .padding(.horizontal, LG.Space.s)
            .frame(minHeight: 28)
            .contentShape(Capsule())
            .liquidGlass(selected ? .prominent : .regular, in: Capsule(), interactive: true)
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Count or status dot. Solid colour, not glass: it must read at a glance.
struct GlassBadge: View {
    var count: Int?
    var color: Color = .red

    var body: some View {
        Group {
            if let count {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(color, in: Capsule())
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel(count.map { "\($0) new" } ?? "New")
    }
}

extension View {
    /// Glass capsule above the view after a short hover. Also sets the system tooltip text.
    func glassTooltip(_ text: String) -> some View { modifier(GlassTooltip(text: text)) }
}

private struct GlassTooltip: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if shown {
                    Text(text)
                        .font(LG.Font.caption)
                        .padding(.horizontal, LG.Space.xs).padding(.vertical, LG.Space.xxs)
                        .background { GlassScrim().clipShape(Capsule()) }
                        .liquidGlass(.regular, in: Capsule())
                        .fixedSize()
                        .offset(y: -30)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onHover { inside in
                hoverTask?.cancel()
                if inside {
                    hoverTask = Task { try? await Task.sleep(for: .seconds(0.6)); if !Task.isCancelled { shown = true } }
                } else {
                    shown = false
                }
            }
            .animation(LG.Motion.fade, value: shown)
            .help(text)
    }
}

/// Large glyph, title, message, optional action.
struct GlassEmptyState: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: LG.Space.xs) {
            Image(systemName: systemImage).font(.system(size: 28, weight: .light)).foregroundStyle(LG.Tone.tertiary)
                .padding(.bottom, LG.Space.xxs)
            Text(title).font(LG.Font.headline)
            if let message {
                Text(message).font(LG.Font.body).foregroundStyle(LG.Tone.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle {
                GlassButton(title: actionTitle, action: action).padding(.top, LG.Space.xs)
            }
        }
        .padding(LG.Space.xl)
        .frame(maxWidth: .infinity)
    }
}

/// Floating alert: one prominent action, one cancel.
struct GlassAlert: View {
    let title: String
    var message: String?
    let actionTitle: String
    var destructive = false
    var action: () -> Void = {}
    var cancel: () -> Void = {}

    var body: some View {
        VStack(spacing: LG.Space.m) {
            VStack(spacing: LG.Space.xxs) {
                Text(title).font(LG.Font.headline)
                if let message { Text(message).font(LG.Font.body).foregroundStyle(LG.Tone.secondary).multilineTextAlignment(.center) }
            }
            HStack(spacing: LG.Space.xs) {
                GlassButton(title: "Cancel", action: cancel).keyboardShortcut(.cancelAction)
                GlassButton(title: actionTitle, prominent: true, tint: destructive ? .red : nil, action: action)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(LG.Space.xl)
        .frame(width: 300)
        .background { GlassScrim().clipShape(RoundedRectangle(cornerRadius: LG.Radius.card, style: .continuous)) }
        .liquidGlass(.regular)
        .elevation(.floating)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
