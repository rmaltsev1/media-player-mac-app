import Foundation
import Combine

/// "Watched" history — titles the user has marked watched or finished playing.
/// Persisted to Application Support/RezkaPlayer/watched.json.
@MainActor
final class WatchedStore: ObservableObject {
    struct Entry: Codable, Identifiable, Hashable {
        let url: String          // pageURL — the stable id
        var title: String
        var posterURL: String?
        var watchedAt: Date

        var id: String { url }
    }

    @Published private(set) var items: [Entry] = []
    private let fm = FileManager.default
    private let cap = 200

    init() { load() }

    // MARK: Public API

    func mark(item: CatalogueItem) {
        mark(url: item.url, title: item.title, posterURL: item.image)
    }

    /// Record (or refresh) a watched entry, moving it to the front of the history.
    func mark(url: String, title: String, posterURL: String?) {
        if let idx = items.firstIndex(where: { $0.url == url }) {
            var e = items[idx]
            e.title = title
            e.posterURL = posterURL ?? e.posterURL
            e.watchedAt = Date()
            items.remove(at: idx)
            items.insert(e, at: 0)
        } else {
            items.insert(Entry(url: url, title: title, posterURL: posterURL, watchedAt: Date()), at: 0)
        }
        if items.count > cap { items.removeLast(items.count - cap) }
        save()
    }

    func unmark(url: String) {
        items.removeAll { $0.url == url }
        save()
    }

    func isWatched(url: String) -> Bool { items.contains { $0.url == url } }

    /// History as catalogue tiles, most recent first.
    func history() -> [CatalogueItem] {
        items.sorted { $0.watchedAt > $1.watchedAt }.map {
            CatalogueItem(title: $0.title, url: $0.url, image: $0.posterURL,
                          rating: nil, category: nil, info: nil, postId: nil)
        }
    }

    // MARK: Persistence

    private var file: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RezkaPlayer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("watched.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
