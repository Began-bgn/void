import SwiftUI
import Observation

@MainActor @Observable
final class NotesModel {
    static let shared = NotesModel()

    private struct Stored: Codable { var text: String }

    var text: String { didSet { scheduleSave() } }
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() { text = WidgetStorage.load("notes", as: Stored.self)?.text ?? "" }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        WidgetStorage.save(Stored(text: text), "notes")
    }
}

struct NotesWidget: NotchWidget {
    static let kind = "notes"
    static let title = String(localized: "Notes")
    static let symbol = "note.text"
    static let span = 2

    let tint: Color
    @Bindable private var model = NotesModel.shared

    init(tint: Color) { self.tint = tint }

    var body: some View {
        TextEditor(text: $model.text)
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .padding(4)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("Quick note…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .tint(tint)
            .accessibilityLabel("Notes")
    }
}
