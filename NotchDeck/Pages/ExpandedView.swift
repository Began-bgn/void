import SwiftUI

enum NotchPage: Int, CaseIterable, Identifiable {
    case music, shelf, widgets

    var id: Int { rawValue }
    var symbol: String {
        switch self {
        case .music: "music.note"
        case .shelf: "tray.full"
        case .widgets: "square.grid.2x2"
        }
    }
    var title: String {
        switch self {
        case .music: String(localized: "Music")
        case .shelf: String(localized: "Shelf")
        case .widgets: String(localized: "Widgets")
        }
    }
}

/// Header band beside the physical notch (page tabs, page actions) above the paged content.
struct ExpandedView: View {
    let model: NotchModel
    private let shelf = ShelfStore.shared
    private let music = MusicStore.shared
    private let settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { settings.tint(music.tint) }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: model.notchSize.height)
            // Same flash as the closed notch, in its own row (the open notch grows by this row).
            if ActivityCenter.shared.flash != nil {
                CollapsedSidesView(model: model)
                    .frame(width: model.sidesSize.width, height: model.flashRowHeight)
                    .id(ActivityCenter.shared.flashID)
                    .transition(.blurFade)
            }
            ZStack {
                page(model.page)
                    .id(model.page)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    /// Short slide + fade; stays inside the notch (the content is clipped to the notch shape).
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let shift: CGFloat = model.pageForward ? 28 : -28
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: shift)),
                           removal: .opacity.combined(with: .offset(x: -shift)))
    }

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(NotchPage.allCases) { p in
                Button { withAnimation(.easeInOut(duration: 0.22)) { model.show(p) } } label: {
                    Image(systemName: p.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.page == p ? .white : .white.opacity(0.4))
                        .frame(width: 26, height: 20)
                        .background(model.page == p ? Color.white.opacity(0.14) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.title)
                .accessibilityAddTraits(model.page == p ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
            Button { SettingsOpener.open() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            if settings.activityFocus {
                let focused = FocusMonitor.shared.isFocused
                Button { FocusMonitor.shared.toggle() } label: {
                    Image(systemName: focused ? "moon.fill" : "moon")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(focused ? Color.indigo : .white.opacity(0.5))
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(focused ? "Turn Focus off" : "Turn Focus on")
            }
            // Live: updates when plugging in or out with the notch open. Hidden on Macs without a battery.
            if let battery = BatteryMonitor.shared.reading {
                // Level printed inside the icon; the fill is dimmed so the white number stays readable.
                HStack(spacing: 2) {
                    if battery.onAC {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(BatteryMonitor.chargeColor)
                    }
                    BatteryIcon(fraction: Double(battery.percent) / 100,
                                color: battery.percent <= 20 && !battery.onAC ? .red : battery.onAC ? BatteryMonitor.chargeColor : .white.opacity(0.45),
                                glyph: nil, text: "\(battery.percent)")
                }
                .padding(.leading, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Battery \(battery.percent)%\(battery.onAC ? ", charging" : "")")
            }
            if model.page == .shelf, !shelf.items.isEmpty {
                Button("Clear") { shelf.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityLabel("Clear shelf")
            }
        }
        .padding(.horizontal, 22)
    }

    @ViewBuilder private func page(_ page: NotchPage) -> some View {
        switch page {
        case .music: MusicPageView()
        case .shelf: ShelfPageView(tint: tint)
        case .widgets: WidgetsPageView(tint: tint)
        }
    }
}
