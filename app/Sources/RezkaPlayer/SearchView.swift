import SwiftUI

struct SearchView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var items: [CatalogueItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searched = false

    var body: some View {
        ScrollView {
            if loading {
                CenteredMessage(systemImage: "hourglass", title: "Searching…").frame(minHeight: 360)
            } else if let error {
                CenteredMessage(systemImage: "exclamationmark.triangle",
                                title: "Search failed", subtitle: error).frame(minHeight: 360)
            } else if items.isEmpty && searched {
                CenteredMessage(systemImage: "magnifyingglass",
                                title: "No results for “\(query)”").frame(minHeight: 360)
            } else if items.isEmpty {
                CenteredMessage(systemImage: "magnifyingglass",
                                title: "Search HDRezka",
                                subtitle: "Find films, series, cartoons and anime by title.")
                    .frame(minHeight: 360)
            } else {
                PosterGrid(items: displayItems)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Title…")
        .onSubmit(of: .search) { Task { await run() } }
    }

    /// `items` with watched titles removed when "Hide watched" is on.
    private var displayItems: [CatalogueItem] {
        guard state.hideWatched else { return items }
        return items.filter { !state.watched.isWatched(url: $0.url) }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard case .ready = state.sidecar.state else {
            error = "The helper isn't ready yet."; return
        }
        loading = true; error = nil; searched = true
        defer { loading = false }
        do {
            // Advanced search returns posters with images; nicer for a grid.
            items = try await state.api.search(q, advanced: true)
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            items = []
        }
    }
}
