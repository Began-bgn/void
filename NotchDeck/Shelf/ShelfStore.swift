import AppKit
import Observation
import os

/// Shelf items, held by reference (bookmark) by default or copied into the shelf folder.
@MainActor @Observable
final class ShelfStore {
    static let shared = ShelfStore(directory: URL.applicationSupportDirectory
        .appending(path: "NotchDeck/Shelf", directoryHint: .isDirectory))

    private(set) var items: [ShelfItem] = []
    var selection: Set<UUID> = []

    @ObservationIgnored let directory: URL
    @ObservationIgnored var persist = true
    @ObservationIgnored var copyFiles = false
    /// 0 = never.
    @ObservationIgnored var autoClearHours: Double = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.notchdeck.app", category: "shelf")

    private var indexURL: URL { directory.appending(path: "shelf.json") }
    private var filesDir: URL { directory.appending(path: "Files", directoryHint: .isDirectory) }

    init(directory: URL) { self.directory = directory }

    /// Selected items, or everything when nothing is selected.
    var selectedOrAll: [ShelfItem] {
        let picked = items.filter { selection.contains($0.id) }
        return picked.isEmpty ? items : picked
    }

    // MARK: Persistence

    func load() {
        guard persist, let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded.compactMap(Self.resolved)
        pruneExpired()
    }

    func save() {
        do {
            guard persist else {
                if FileManager.default.fileExists(atPath: indexURL.path) { try FileManager.default.removeItem(at: indexURL) }
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
        } catch {
            log.error("Shelf save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Follows bookmarks to moved/renamed files; drops items whose file is gone.
    private static func resolved(_ item: ShelfItem) -> ShelfItem? {
        guard case .file(var path, let bookmark, let owned) = item.content else { return item }
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                path = url.path
            }
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var copy = item
        copy.content = .file(path: path, bookmark: bookmark, owned: owned)
        return copy
    }

    // MARK: Adding

    func add(fileURL url: URL) {
        guard !items.contains(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) else { return }
        var item = ShelfItem(content: .text(""))
        if copyFiles, let copied = copyIntoShelf(url, id: item.id) {
            item.content = .file(path: copied.path, bookmark: nil, owned: true)
        } else {
            item.content = .file(path: url.path, bookmark: try? url.bookmarkData(), owned: false)
        }
        insert(item)
    }

    func add(link url: URL) {
        guard !items.contains(where: { $0.content == .link(url) }) else { return }
        insert(ShelfItem(content: .link(url)))
    }

    func add(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !items.contains(where: { $0.content == .text(text) }) else { return }
        insert(ShelfItem(content: .text(text)))
    }

    /// Image data dragged from an app (not a file): stored as a PNG the shelf owns.
    func add(imageData: Data) {
        let id = UUID()
        let dir = filesDir.appending(path: id.uuidString, directoryHint: .isDirectory)
        let url = dir.appending(path: "Image.png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try imageData.write(to: url)
            insert(ShelfItem(id: id, content: .file(path: url.path, bookmark: nil, owned: true)))
        } catch {
            log.error("Saving dropped image failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func copyIntoShelf(_ url: URL, id: UUID) -> URL? {
        let dir = filesDir.appending(path: id.uuidString, directoryHint: .isDirectory)
        let dest = dir.appending(path: url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            log.error("Copy into shelf failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func insert(_ item: ShelfItem) {
        items.insert(item, at: 0)
        save()
    }

    func add(_ payloads: [DropPayload]) {
        for p in payloads {
            switch p {
            case .url(let url): url.isFileURL ? add(fileURL: url) : add(link: url)
            case .image(let data): add(imageData: data)
            case .text(let text): add(text: text)
            }
        }
    }

    func add(providers: [NSItemProvider]) {
        DropPayload.load(providers) { [weak self] in self?.add($0) }
    }

    // MARK: Removing

    func remove(_ ids: Set<UUID>) {
        for item in items where ids.contains(item.id) {
            if case .file(let path, _, true) = item.content {
                // Only delete what the shelf itself created: its per-item folder.
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                if dir.deletingLastPathComponent().standardizedFileURL == filesDir.standardizedFileURL {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    func clear() { remove(Set(items.map(\.id))) }

    func pruneExpired(now: Date = .now) {
        guard autoClearHours > 0 else { return }
        let cutoff = now.addingTimeInterval(-autoClearHours * 3600)
        let expired = Set(items.filter { $0.addedAt < cutoff }.map(\.id))
        if !expired.isEmpty { remove(expired) }
    }

    // MARK: Selection

    func click(_ id: UUID, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    func open(_ item: ShelfItem) {
        switch item.content {
        case .file(let path, _, _): NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .link(let url): NSWorkspace.shared.open(url)
        case .text(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// Sendable form of whatever was dropped.
enum DropPayload: Sendable, Equatable {
    case url(URL), image(Data), text(String)

    static let acceptedTypes: [String] = ["public.file-url", "public.url", "public.image", "public.plain-text"]

    /// Starts every load immediately: drop providers are backed by the drag pasteboard and stop
    /// delivering data once the drop handler has returned.
    @MainActor
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([DropPayload]) -> Void) {
        let results = Results(count: providers.count)
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            loadOne(p) { results.set(i, $0); group.leave() }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(results.values) } }
    }

    /// URL first (files and links), then raw image data, then text.
    private static func loadOne(_ p: NSItemProvider, done: @escaping @Sendable (DropPayload?) -> Void) {
        // SwiftUI offers a dropped text or image *file* only as its content type (e.g. public.plain-text),
        // not as a file URL. If the content is backed by the original file, keep the file.
        if !p.canLoadObject(ofClass: NSURL.self), let type = p.registeredTypeIdentifiers.first {
            nonisolated(unsafe) let provider = p
            _ = p.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, _ in
                if let url, inPlace { done(.url(url)) } else { loadObject(provider, done: done) }
            }
        } else {
            loadObject(p, done: done)
        }
    }

    private static func loadObject(_ p: NSItemProvider, done: @escaping @Sendable (DropPayload?) -> Void) {
        if p.canLoadObject(ofClass: NSURL.self) {
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                // Finder can hand over file *reference* URLs (/.file/id=…); store the real path.
                let url = (obj as? NSURL).flatMap { $0.isFileReferenceURL() ? $0.filePathURL : $0 as URL }
                done(url.map { .url($0) })
            }
        } else if p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in done((obj as? NSImage).flatMap(pngData).map { .image($0) }) }
        } else if p.canLoadObject(ofClass: NSString.self) {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in done((obj as? NSString).map { .text($0 as String) }) }
        } else {
            done(nil)
        }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [DropPayload?]
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ v: DropPayload?) { lock.withLock { slots[i] = v } }
        var values: [DropPayload] { lock.withLock { slots.compactMap { $0 } } }
    }
}

func pngData(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}
