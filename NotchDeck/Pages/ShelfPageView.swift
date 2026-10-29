import SwiftUI
import QuickLookThumbnailing

struct ShelfPageView: View {
    let tint: Color
    private let store = ShelfStore.shared
    private let settings = SettingsStore.shared
    @State private var menu: (item: ShelfItem, at: CGPoint)?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        dropBox
                        AirDropTile(tint: tint)
                    }
                }
                if let menu { menuOverlay(menu, in: geo.size) }
            }
            .coordinateSpace(name: "shelf")
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    /// In-notch item menu (AppKit menus would open beneath the notch window).
    private func menuItems(for item: ShelfItem) -> [WidgetMenu.Item] {
        var items: [WidgetMenu.Item] = [.init(title: String(localized: "Open")) { store.open(item) }]
        if let url = item.fileURL {
            items.append(.init(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        items.append(.init(title: String(localized: "AirDrop")) { AirDrop.shared.send([item.pasteboardWriter]) })
        items.append(.init(title: String(localized: "Remove"), destructive: true) { store.remove([item.id]) })
        return items
    }

    @ViewBuilder private func menuOverlay(_ m: (item: ShelfItem, at: CGPoint), in size: CGSize) -> some View {
        let items = menuItems(for: m.item)
        let close = { withAnimation(.easeOut(duration: 0.12)) { menu = nil } }
        Color.black.opacity(0.001)
            .frame(width: size.width, height: size.height)
            .onTapGesture(perform: close)
            .overlay { RightClickCatcher { _ in close() } }
        WidgetMenu(items: items, dismiss: close)
            .offset(x: min(max(m.at.x, 0), size.width - WidgetMenu.width),
                    y: min(max(m.at.y, 0), size.height - WidgetMenu.height(rows: items.count)))
    }

    /// Dashed box: hint when empty, otherwise the items in one row (three visible at a time),
    /// scrolling sideways for more.
    private var dropBox: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .overlay {
                if store.items.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 18))
                        Text("Drop files, images, text or links").font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityElement(children: .combine)
                } else {
                    grid.padding(5)
                }
            }
    }

    private var grid: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let cell = CGSize(width: (geo.size.width - spacing * 2) / 3, height: geo.size.height)
            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(store.items) { item in
                        ShelfItemCell(item: item, selected: store.selection.contains(item.id), tint: tint, size: cell) { p in
                            withAnimation(.easeOut(duration: 0.12)) { menu = (item, p) }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .background(Color.black.opacity(0.001).onTapGesture { store.selection = [] })
        }
    }
}

private struct ShelfItemCell: View {
    let item: ShelfItem
    let selected: Bool
    let tint: Color
    let size: CGSize
    /// Right-click, with the location in the shelf page's coordinates.
    let onMenu: (CGPoint) -> Void
    private let store = ShelfStore.shared
    @State private var thumbnail: NSImage?

    @State private var isPhoto = false

    private var thumbSide: CGFloat { max(16, min(size.height - 30, size.width - 14)) }

    /// Finder-style: the preview sits on a soft rounded highlight when selected, the name in an
    /// accent capsule.
    var body: some View {
        VStack(spacing: 3) {
            preview
                .frame(width: thumbSide, height: thumbSide)
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(selected ? 0.16 : 0)))
            Text(item.displayName)
                .font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(selected ? Color.accentColor : .clear))
        }
        .frame(width: size.width, height: size.height)
        .overlay(dragSource)
        .task(id: item.id) {
            let thumb = await ShelfThumbnails.shared.image(for: item)
            thumbnail = thumb?.image
            isPhoto = thumb?.isPhoto ?? false
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.click(item.id, extend: true) }
        .accessibilityAction(named: "Open") { store.open(item) }
        .accessibilityAction(named: "Remove") { store.remove([item.id]) }
    }

    /// Photos/PDFs: rounded thumbnail with a hairline edge. Other files: their full-colour icon.
    /// Text: a little note card. Links: a blue tile.
    @ViewBuilder private var preview: some View {
        switch item.content {
        case .file:
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: isPhoto ? 5 : 0, style: .continuous))
                    .overlay {
                        if isPhoto {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1.5)
            } else {
                Color.clear
            }
        case .text(let text):
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white)
                .overlay(alignment: .topLeading) {
                    Text(text).font(.system(size: 5.5)).foregroundStyle(.black.opacity(0.7))
                        .lineLimit(nil).padding(4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .aspectRatio(0.78, contentMode: .fit)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1.5)
        case .link:
            RoundedRectangle(cornerRadius: thumbSide * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: .systemTeal), Color(nsColor: .systemBlue)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    Image(systemName: "link").font(.system(size: thumbSide * 0.38, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(thumbSide * 0.08)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1.5)
        }
    }

    private var dragSource: some View {
        GeometryReader { g in
        DragSource(
            onClick: { extend, clicks in
                if clicks >= 2 { store.open(item) } else { store.click(item.id, extend: extend) }
            },
            dragItems: {
                // Dragging a selected item drags the whole selection.
                let group = store.selection.contains(item.id) ? store.items.filter { store.selection.contains($0.id) } : [item]
                return group.map { ($0.pasteboardWriter, ShelfThumbnails.shared.cached(for: $0)) }
            },
            onRightClick: { p in
                let origin = g.frame(in: .named("shelf")).origin
                onMenu(CGPoint(x: origin.x + p.x, y: origin.y + p.y))
            }
        )
        }
    }
}

private struct AirDropTile: View {
    let tint: Color
    private let store = ShelfStore.shared
    @State private var targeted = false

    var body: some View {
        Button { AirDrop.shared.send(store.selectedOrAll.map(\.pasteboardWriter)) } label: {
            VStack(spacing: 4) {
                Image(systemName: "airplayaudio").font(.system(size: 20))
                Text("AirDrop").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(targeted ? tint : .white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(targeted ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        // Square, as tall as the drop box beside it.
        .frame(maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .onDrop(of: DropPayload.acceptedTypes.map { .init($0)! }, isTargeted: $targeted) { providers in
            AirDrop.shared.send(providers: providers)
            return true
        }
        .accessibilityLabel(store.selection.isEmpty ? "AirDrop all shelf items" : "AirDrop selected items")
        .accessibilityHint("Drop files here to send them with AirDrop")
    }
}

@MainActor
final class ShelfThumbnails {
    static let shared = ShelfThumbnails()
    /// `isPhoto`: a real content thumbnail (image, PDF…) rather than the file's icon.
    final class Thumb {
        let image: NSImage
        let isPhoto: Bool
        init(image: NSImage, isPhoto: Bool) { self.image = image; self.isPhoto = isPhoto }
    }
    private let cache = NSCache<NSString, Thumb>()

    func cached(for item: ShelfItem) -> NSImage {
        if let path = item.fileURL?.path, let thumb = cache.object(forKey: path as NSString) { return thumb.image }
        if let path = item.fileURL?.path { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage()
    }

    func image(for item: ShelfItem) async -> Thumb? {
        guard let url = item.fileURL else { return nil }
        if let thumb = cache.object(forKey: url.path as NSString) { return thumb }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 2,
                                                   representationTypes: .all)
        let rep: (CGImage, Bool)? = await withCheckedContinuation { c in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                c.resume(returning: rep.map { ($0.cgImage, $0.type == .thumbnail) })
            }
        }
        let thumb = rep.map { Thumb(image: NSImage(cgImage: $0.0, size: .zero), isPhoto: $0.1) }
            ?? Thumb(image: NSWorkspace.shared.icon(forFile: url.path), isPhoto: false)
        cache.setObject(thumb, forKey: url.path as NSString)
        return thumb
    }
}
