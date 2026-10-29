import Foundation
import Testing
@testable import NotchDeck

@MainActor @Suite struct ShelfStoreTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ShelfTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(in dir: URL, _ name: String = "a.txt") -> URL {
        let url = dir.appending(path: name)
        try? "hi".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func addsNewestFirstAndDedupes() {
        let store = ShelfStore(directory: tempDir())
        store.add(text: "one")
        store.add(link: URL(string: "https://example.com")!)
        store.add(text: "one")
        store.add(text: "   ")
        #expect(store.items.count == 2)
        #expect(store.items.first?.content == .link(URL(string: "https://example.com")!))
    }

    @Test func persistsAndReloads() {
        let dir = tempDir()
        let file = makeFile(in: dir)
        let a = ShelfStore(directory: dir)
        a.add(fileURL: file)
        a.add(text: "note")

        let b = ShelfStore(directory: dir)
        b.load()
        #expect(b.items.map(\.displayName) == ["note", "a.txt"])
    }

    @Test func reloadDropsMissingFiles() throws {
        let dir = tempDir()
        let file = makeFile(in: dir)
        let a = ShelfStore(directory: dir)
        a.add(fileURL: file)
        try FileManager.default.removeItem(at: file)

        let b = ShelfStore(directory: dir)
        b.load()
        #expect(b.items.isEmpty)
    }

    @Test func noPersistenceWhenDisabled() {
        let dir = tempDir()
        let a = ShelfStore(directory: dir)
        a.persist = false
        a.add(text: "x")
        let b = ShelfStore(directory: dir)
        b.load()
        #expect(b.items.isEmpty)
    }

    @Test func copyModeOwnsAndDeletesCopy() throws {
        let dir = tempDir()
        let source = makeFile(in: tempDir())
        let store = ShelfStore(directory: dir)
        store.copyFiles = true
        store.add(fileURL: source)
        let copy = try #require(store.items.first?.fileURL)
        #expect(copy.path.hasPrefix(dir.path))
        #expect(FileManager.default.fileExists(atPath: copy.path))

        store.clear()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: source.path)) // original untouched
    }

    @Test func removingReferenceNeverDeletesOriginal() {
        let dir = tempDir()
        let file = makeFile(in: dir)
        let store = ShelfStore(directory: dir)
        store.add(fileURL: file)
        store.clear()
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func pruneExpired() {
        let store = ShelfStore(directory: tempDir())
        store.add(text: "old")
        store.autoClearHours = 1
        store.pruneExpired(now: .now.addingTimeInterval(30 * 60))
        #expect(store.items.count == 1)
        store.pruneExpired(now: .now.addingTimeInterval(2 * 3600))
        #expect(store.items.isEmpty)
    }

    @Test func selection() {
        let store = ShelfStore(directory: tempDir())
        store.add(text: "a"); store.add(text: "b")
        let (b, a) = (store.items[0].id, store.items[1].id)
        store.click(a, extend: false)
        #expect(store.selection == [a])
        store.click(b, extend: true)
        #expect(store.selection == [a, b])
        #expect(store.selectedOrAll.count == 2)
        store.click(b, extend: false)
        #expect(store.selection == [b])
        store.remove([b])
        #expect(store.selection.isEmpty)
        #expect(store.selectedOrAll.map(\.id) == [a])
    }

    @Test func dropProvidersBecomeShelfItems() async throws {
        let dir = tempDir()
        let file = makeFile(in: dir, "dropped.txt")
        let store = ShelfStore(directory: dir)
        let providers = [
            try #require(NSItemProvider(contentsOf: file)),
            NSItemProvider(object: URL(string: "https://example.com/x")! as NSURL),
            NSItemProvider(object: "plain text" as NSString),
        ]
        await withCheckedContinuation { c in
            DropPayload.load(providers) { payloads in
                store.add(payloads)
                c.resume()
            }
        }
        #expect(store.items.count == 3)
        #expect(store.items.contains { $0.fileURL?.lastPathComponent == "dropped.txt" })
        #expect(store.items.contains { $0.content == .text("plain text") })
    }
}
