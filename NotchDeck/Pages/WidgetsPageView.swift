import SwiftUI

/// Widgets in rows of three columns (tiles can span), one row per page height, row-snapped scroll.
struct WidgetsPageView: View {
    let tint: Color
    private let store = WidgetStore.shared
    private static let addTile = "__add"
    @State private var menu: (kind: String, at: CGPoint)?

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 6
            let unit = (geo.size.width - spacing * 2) / 3
            ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: spacing) {
                            ForEach(row, id: \.self) { kind in
                                let span = CGFloat(span(of: kind))
                                tile(kind).frame(width: unit * span + spacing * (span - 1), height: geo.size.height)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: geo.size.height)
                    }
                }
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.never)

                if let menu { menuOverlay(menu, in: geo.size) }
            }
            .coordinateSpace(name: "widgets")
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private var rows: [[String]] {
        var items = store.kinds.map { (id: $0, span: span(of: $0)) }
        if !store.addable.isEmpty { items.append((Self.addTile, 1)) }
        return WidgetStore.pack(items)
    }

    private func span(of kind: String) -> Int { WidgetRegistry.type(for: kind)?.span ?? 1 }

    @ViewBuilder private func tile(_ kind: String) -> some View {
        if kind == Self.addTile {
            addTile
        } else if let type = WidgetRegistry.type(for: kind), let view = WidgetRegistry.view(for: kind, tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                header(type)
                view.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(6)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                GeometryReader { g in
                    RightClickCatcher { p in
                        let origin = g.frame(in: .named("widgets")).origin
                        withAnimation(.easeOut(duration: 0.12)) {
                            menu = (kind, CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                        }
                    }
                }
            }
            .dropDestination(for: WidgetDragID.self) { items, _ in
                guard let dragged = items.first else { return false }
                withAnimation(.easeInOut(duration: 0.2)) { store.move(dragged.kind, before: kind) }
                return true
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(type.title)
            .accessibilityAction(named: "Move earlier") { store.shift(kind, by: -1) }
            .accessibilityAction(named: "Move later") { store.shift(kind, by: 1) }
            .accessibilityAction(named: "Remove widget") { store.remove(kind) }
        }
    }

    /// Title strip: drag handle for reordering, right-click for move/remove.
    private func header(_ type: any NotchWidget.Type) -> some View {
        HStack(spacing: 4) {
            Image(systemName: type.symbol)
            Text(type.title)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white.opacity(0.45))
        .frame(height: 10)
        .contentShape(Rectangle())
        .draggable(WidgetDragID(kind: type.kind)) {
            Label(type.title, systemImage: type.symbol).padding(6).background(.black, in: Capsule()).foregroundStyle(.white)
        }
    }

    private func menuItems(for kind: String) -> [WidgetMenu.Item] {
        let extra = (WidgetRegistry.type(for: kind)?.menuActions ?? []).map { a in
            WidgetMenu.Item(title: a.title, action: a.action)
        }
        return extra + [
            .init(title: String(localized: "Move Earlier")) { withAnimation(.easeInOut(duration: 0.2)) { store.shift(kind, by: -1) } },
            .init(title: String(localized: "Move Later")) { withAnimation(.easeInOut(duration: 0.2)) { store.shift(kind, by: 1) } },
            .init(title: String(localized: "Remove Widget"), destructive: true) {
                withAnimation(.easeInOut(duration: 0.2)) { store.remove(kind) }
            },
        ]
    }

    /// Click-away catcher plus the menu, clamped inside the page.
    @ViewBuilder private func menuOverlay(_ m: (kind: String, at: CGPoint), in size: CGSize) -> some View {
        let items = m.kind == Self.addTile
            ? store.addable.map { type in
                WidgetMenu.Item(title: type.title) { withAnimation(.easeInOut(duration: 0.2)) { store.add(type.kind) } }
            }
            : menuItems(for: m.kind)
        let close = { withAnimation(.easeOut(duration: 0.12)) { menu = nil } }
        Color.black.opacity(0.001)
            .frame(width: size.width, height: size.height)
            .onTapGesture(perform: close)
            .overlay { RightClickCatcher { _ in close() } }
        WidgetMenu(items: items, dismiss: close)
            .offset(x: min(max(m.at.x, 0), size.width - WidgetMenu.width),
                    y: min(max(m.at.y, 0), size.height - WidgetMenu.height(rows: items.count)))
    }

    private var addTile: some View {
        GeometryReader { g in
            Button {
                let f = g.frame(in: .named("widgets"))
                withAnimation(.easeOut(duration: 0.12)) { menu = (Self.addTile, CGPoint(x: f.minX + 8, y: f.minY + 8)) }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                    Text("Add widget").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add widget")
        }
    }
}
