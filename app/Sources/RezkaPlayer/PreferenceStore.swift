import Foundation
import Combine

/// Remembers the last-used translator per title (pageURL -> translatorId), persisted to
/// Application Support/RezkaPlayer/lasttranslator.json. (Preferred resolution is a global
/// @AppStorage on AppState.)
@MainActor
final class PreferenceStore: ObservableObject {
    @Published private(set) var lastTranslator: [String: Int] = [:]
    private let fm = FileManager.default

    init() { load() }

    func translator(for pageURL: String) -> Int? { lastTranslator[pageURL] }

    func setTranslator(_ id: Int, for pageURL: String) {
        lastTranslator[pageURL] = id
        save()
    }

    // MARK: Persistence

    private var file: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RezkaPlayer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("lasttranslator.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        lastTranslator = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(lastTranslator) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
