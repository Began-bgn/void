import SwiftUI
import Observation

@MainActor @Observable
final class NotchModel {
    var isExpanded = false
    var isDwelling = false
    var dwellDuration: Double = 0.8
    var notchSize = CGSize(width: 180, height: 30)
    var expandedSize = CGSize(width: 420, height: 165)
    var page: NotchPage = .music
    /// Direction of the last page change, for the push transition.
    var pageForward = true
    var isDropTargeted = false
    /// Horizontal kick of the collapsed cover after a swipe skip.
    var nudge: CGFloat = 0
    /// Elastic pull of the closed notch toward a nearby cursor.
    var magnet = NotchMagnet.identity
    @ObservationIgnored var onDropTargetChanged: (@MainActor (Bool) -> Void)?

    func show(_ newPage: NotchPage) {
        guard newPage != page else { return }
        pageForward = newPage.rawValue > page.rawValue
        page = newPage
    }

    func step(_ delta: Int) {
        if let p = NotchPage(rawValue: page.rawValue + delta) { show(p) }
    }

    /// Width added on each side of the physical notch; depends on what the sides show.
    var sideWidth: CGFloat {
        let item = notchSize.height - 10
        switch ActivityCenter.shared.flash {
        case .battery: return 100
        case .hud: return Self.hudSideWidth
        case .focus: return 78
        case .lock: return PadlockPillView.sideWidth
        case nil: break
        }
        if ActivityCenter.shared.live == .timer { return item * 2 + 6 + 14 } // cover + bars, or room for "10:00"
        return notchSize.height + 12
    }

    // +2: overlap the physical notch edges by 1pt so no seam shows.
    // Slightly larger than the physical notch on every side so none of it shows.
    static let overlap: CGFloat = 2
    static let maxSideWidth: CGFloat = 130
    static let hudSideWidth: CGFloat = 96
    /// Idle and reveal start: exactly the physical notch height, so nothing shows below it at rest.
    var plainSize: CGSize { CGSize(width: notchSize.width + Self.overlap * 2, height: notchSize.height) }
    /// The extra strip below the notch appears only once it opens out.
    var sidesSize: CGSize { CGSize(width: plainSize.width + sideWidth * 2, height: notchSize.height + Self.overlap + 1) }
    var popupSize: CGSize { CGSize(width: max(sidesSize.width, 340), height: notchSize.height + 46) }

    /// Live activity, music, or a Focus badge occupies the side areas.
    var sidesVisible: Bool {
        ActivityCenter.shared.flash != nil || ActivityCenter.shared.live != nil || MusicStore.shared.hasPlayback
            || (SettingsStore.shared.activityFocus && FocusMonitor.shared.isFocused)
    }
    var popupVisible: Bool { ActivityCenter.shared.popup != nil && ActivityCenter.shared.flash == nil }

    /// Hover target for opening (pop-ups excluded so hovering one only keeps it up).
    var dwellSize: CGSize { sidesVisible ? sidesSize : plainSize }
    var collapsedSize: CGSize {
        if ActivityCenter.shared.revealing { return plainSize }
        return popupVisible ? popupSize : dwellSize
    }

    /// Extra row in the open notch for volume/brightness/battery/Focus/lock flashes.
    var flashRowHeight: CGFloat { notchSize.height }
    var openSize: CGSize {
        ActivityCenter.shared.flash == nil ? expandedSize
            : CGSize(width: expandedSize.width, height: expandedSize.height + flashRowHeight)
    }
}

struct NotchView: View {
    let model: NotchModel
    private let music = MusicStore.shared
    private let settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { settings.tint(music.tint) }
    private var shape: NotchShape {
        NotchShape(topRadius: model.isExpanded ? 14 : 6,
                   bottomRadius: model.isExpanded ? 28 : (model.popupVisible ? 20 : 10))
    }

    var body: some View {
        let size = model.isExpanded ? model.openSize : model.collapsedSize
        // Opening may bounce a little; closing and resizing never overshoot (overshoot clipped the cover).
        let open: Animation = reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.8)
        let settle: Animation = reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.34)
        // Launch/lock/unlock: slower slide out of the physical notch.
        let reveal = ActivityCenter.revealAnimation(reduceMotion: reduceMotion)

        ZStack(alignment: .top) {
            shape
                .fill(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1))
                // Clip to the notch so nothing (page slides, collapse fade) ever draws outside it.
                .overlay { content.clipShape(shape) }
                .shadow(color: .black.opacity(model.isExpanded ? 0.35 : 0), radius: 12, y: 4)
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: model.magnet.scaleX, y: model.magnet.scaleY, anchor: .top)
                .offset(x: model.magnet.offsetX)
                // The whole notch is a drop target: dragging onto it opens the shelf.
                .onDrop(of: DropPayload.acceptedTypes.map { .init($0)! },
                        isTargeted: Binding(get: { model.isDropTargeted }, set: { model.onDropTargetChanged?($0) })) { providers in
                    if SettingsStore.shared.notchDropAirDrop {
                        AirDrop.shared.send(providers: providers)
                    } else {
                        ShelfStore.shared.add(providers: providers)
                        model.show(.shelf)
                    }
                    return true
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsOpener())
        // Innermost, so it wins over `settle` when the reveal is what changed the size.
        .animation(reveal, value: ActivityCenter.shared.revealing)
        .animation(model.isExpanded ? open : settle, value: model.isExpanded)
        .animation(settle, value: model.collapsedSize)
    }

    @ViewBuilder private var content: some View {
        if ActivityCenter.shared.revealHidesContent, !model.isExpanded {
            EmptyView()
        } else if model.isExpanded {
            ExpandedView(model: model)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
                    removal: .opacity.animation(.easeIn(duration: 0.08))))
        } else if ActivityCenter.shared.flash != nil {
            CollapsedSidesView(model: model)
                .id(ActivityCenter.shared.flashID)
                .transition(.blurFade)
        } else if let popup = ActivityCenter.shared.popup {
            ActivityPopupView(popup: popup, notchHeight: model.notchSize.height)
                .id(popup.id)
                .transition(.opacity)
        } else if model.sidesVisible {
            CollapsedSidesView(model: model)
                // Appear once the closing notch has settled, so nothing pokes past its edge.
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.18)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
        }
    }

}
