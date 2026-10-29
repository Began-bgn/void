import SwiftUI
import UniformTypeIdentifiers
import Observation
import os

/// A widget on the Widgets page. To add one: make a View conforming to this, then list it in
/// `WidgetRegistry.all`. Persist its state with `WidgetStorage`.
@MainActor
protocol NotchWidget: View {
    /// Stable identifier, stored in the layout file.
    static var kind: String { get }
    static var title: String { get }
    static var symbol: String { get }
    /// Grid columns the tile spans (1–3).
    static var span: Int { get }
    init(tint: Color)
    /// Extra entries for the widget's right-click menu.
    static var menuActions: [(title: String, action: @MainActor () -> Void)] { get }
}

extension NotchWidget {
    static var menuActions: [(title: String, action: @MainActor () -> Void)] { [] }
}

@MainActor
enum WidgetRegistry {
    static let all: [any NotchWidget.Type] = [CalendarWidget.self, TimerWidget.self, NotesWidget.self, LauncherWidget.self]

    static func type(for kind: String) -> (any NotchWidget.Type)? { all.first { $0.kind == kind } }

    static func view(for kind: String, tint: Color) -> AnyView? {
        guard let type = type(for: kind) else { return nil }
        return AnyView(type.init(tint: tint))
    }
}

/// Codable JSON files in Application Support/NotchDeck/Widgets.
enum WidgetStorage {
    static let directory = URL.applicationSupportDirectory.appending(path: "NotchDeck/Widgets", directoryHint: .isDirectory)
    private static let log = Logger(subsystem: "com.notchdeck.app", category: "widgets")

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(name).json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appending(path: "\(name).json"), options: .atomic)
        } catch {
            log.error("Saving \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Which widgets are on the page, in order.
@MainActor @Observable
final class WidgetStore {
    static let shared = WidgetStore()
    static let defaultLayout = ["calendar", "timer", "notes", "launcher"]

    private(set) var kinds: [String]

    private init() {
        kinds = (WidgetStorage.load("layout", as: [String].self) ?? Self.defaultLayout)
            .filter { WidgetRegistry.type(for: $0) != nil }
    }

    var addable: [any NotchWidget.Type] { WidgetRegistry.all.filter { !kinds.contains($0.kind) } }

    func add(_ kind: String) {
        guard !kinds.contains(kind) else { return }
        kinds.append(kind); save()
    }

    func remove(_ kind: String) {
        kinds.removeAll { $0 == kind }; save()
    }

    /// Moves `kind` to just before `target` (or to the end when target is nil).
    func move(_ kind: String, before target: String?) {
        guard kind != target, let from = kinds.firstIndex(of: kind) else { return }
        kinds.remove(at: from)
        let to = target.flatMap { kinds.firstIndex(of: $0) } ?? kinds.endIndex
        kinds.insert(kind, at: to)
        save()
    }

    func shift(_ kind: String, by delta: Int) {
        guard let i = kinds.firstIndex(of: kind) else { return }
        let j = min(max(i + delta, 0), kinds.count - 1)
        guard i != j else { return }
        kinds.swapAt(i, j); save()
    }

    private func save() { WidgetStorage.save(kinds, "layout") }

    /// Greedy row packing: a tile that doesn't fit the current row starts the next one.
    nonisolated static func pack(_ items: [(id: String, span: Int)], columns: Int = 3) -> [[String]] {
        var rows: [[String]] = [], current: [String] = [], used = 0
        for item in items {
            let span = min(max(item.span, 1), columns)
            if used + span > columns { rows.append(current); current = []; used = 0 }
            current.append(item.id); used += span
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

extension UTType {
    /// Declared in Info.plist; private so widget drags never land in the shelf as text.
    static let notchWidgetID = UTType(exportedAs: "com.notchdeck.widget-id")
}

struct WidgetDragID: Codable, Transferable {
    let kind: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .notchWidgetID)
    }
}
