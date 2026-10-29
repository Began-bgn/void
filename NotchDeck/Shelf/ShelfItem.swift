import AppKit

struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    enum Content: Codable, Equatable, Sendable {
        /// `owned`: the file lives in NotchDeck's shelf folder (copy mode or dropped image data).
        case file(path: String, bookmark: Data?, owned: Bool)
        case link(URL)
        case text(String)
    }

    var id = UUID()
    var content: Content
    var addedAt = Date()

    var fileURL: URL? {
        if case .file(let path, _, _) = content { return URL(fileURLWithPath: path) }
        return nil
    }

    var displayName: String {
        switch content {
        case .file(let path, _, _): return (path as NSString).lastPathComponent
        case .link(let url): return url.host() ?? url.absoluteString
        case .text(let text):
            return String(text.split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
        }
    }

    var symbol: String {
        switch content {
        case .file: "doc"
        case .link: "link"
        case .text: "text.alignleft"
        }
    }

    /// What goes on the drag/AirDrop pasteboard.
    var pasteboardWriter: NSPasteboardWriting {
        switch content {
        case .file(let path, _, _): NSURL(fileURLWithPath: path)
        case .link(let url): url as NSURL
        case .text(let text): text as NSString
        }
    }
}
