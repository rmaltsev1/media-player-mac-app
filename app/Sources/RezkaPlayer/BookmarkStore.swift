import Foundation
import Combine

/// "Watch Later" bookmarks, persisted to Application Support/RezkaPlayer/watchlater.json.
@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var items: [CatalogueItem] = []
    private let fm = FileManager.default

    init() { load() }

    private var file: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RezkaPlayer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("watchlater.json")
    }

    func isBookmarked(_ item: CatalogueItem) -> Bool { isBookmarked(url: item.url) }
    func isBookmarked(url: String) -> Bool { items.contains { $0.url == url } }

    /// Add if absent, remove if present.
    func toggle(_ item: CatalogueItem) {
        if let idx = items.firstIndex(where: { $0.url == item.url }) {
            items.remove(at: idx)
        } else {
            items.insert(item, at: 0)
        }
        save()
    }

    func remove(_ item: CatalogueItem) {
        items.removeAll { $0.url == item.url }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([CatalogueItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
