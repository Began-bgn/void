import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class LauncherModel {
    static let shared = LauncherModel()

    private(set) var apps: [URL]
    /// Shows remove badges on the icons.
    var editing = false
    @ObservationIgnored private var icons: [URL: NSImage] = [:]

    private init() {
        apps = (WidgetStorage.load("launcher", as: [String].self) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for url in urls where url.pathExtension == "app" && !apps.contains(url) { apps.append(url) }
        save()
    }

    func remove(_ url: URL) { apps.removeAll { $0 == url }; save() }

    func launch(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func icon(_ url: URL) -> NSImage {
        if let icon = icons[url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = icon
        return icon
    }

    /// The open panel needs NotchDeck active; hand focus back afterwards.
    func choose() {
        let previous = NSWorkspace.shared.frontmostApplication
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add")
        NSApp.activate()
        if panel.runModal() == .OK { add(panel.urls) }
        if let previous, previous != .current { previous.activate() }
    }

    private func save() { WidgetStorage.save(apps.map(\.path), "launcher") }
}

struct LauncherWidget: NotchWidget {
    static let kind = "launcher"
    static let title = String(localized: "Apps")
    static let symbol = "square.grid.3x3"
    static let span = 1
    static var menuActions: [(title: String, action: @MainActor () -> Void)] {
        [(LauncherModel.shared.editing ? String(localized: "Done Editing Apps") : String(localized: "Edit Apps"),
          { LauncherModel.shared.editing.toggle() })]
    }

    let tint: Color
    private let model = LauncherModel.shared
    @State private var targeted = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(model.apps, id: \.self) { url in
                    Button { model.editing ? model.remove(url) : model.launch(url) } label: {
                        Image(nsImage: model.icon(url)).resizable().frame(width: 26, height: 26)
                            .overlay(alignment: .topLeading) {
                                if model.editing {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white, .red)
                                        .offset(x: -3, y: -3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(url.deletingPathExtension().lastPathComponent)")
                    .accessibilityAction(named: "Remove") { model.remove(url) }
                }
                Button { model.editing ? model.editing = false : model.choose() } label: {
                    Image(systemName: model.editing ? "checkmark" : "plus").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel(model.editing ? "Done editing" : "Add app")
            }
        }
        .scrollIndicators(.never)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(targeted ? 0.2 : 0)))
        // Drag apps in from Finder.
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            DropPayload.load(providers) { payloads in
                model.add(payloads.compactMap { if case .url(let u) = $0 { u } else { nil } })
            }
            return true
        }
    }
}
