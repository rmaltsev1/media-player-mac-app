import SwiftUI

struct SearchView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var items: [CatalogueItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searched = false

    // Live as-you-type suggestions (fast search) shown before a full submit.
    @State private var suggestions: [CatalogueItem] = []
    @State private var suggesting = false
    @State private var suggestTask: Task<Void, Never>?

    // Recent queries, newest first (persisted).
    @AppStorage("recentSearches") private var recentsRaw = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var recents: [String] {
        recentsRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        ScrollView {
            if loading {
                SkeletonPosterGrid()
            } else if let error {
                CenteredMessage(systemImage: "exclamationmark.triangle",
                                title: "Search failed", subtitle: error).frame(minHeight: 360)
            } else if searched {
                if displayItems.isEmpty {
                    CenteredMessage(systemImage: "magnifyingglass",
                                    title: "No results for “\(trimmedQuery)”").frame(minHeight: 360)
                } else {
                    PosterGrid(items: displayItems)
                }
            } else if !trimmedQuery.isEmpty {
                suggestionList
            } else {
                idleView
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Title…")
        .onSubmit(of: .search) { Task { await run() } }
        .onChange(of: query) { _, _ in
            searched = false
            error = nil
            scheduleSuggest()
        }
    }

    /// `items` with watched titles removed when "Hide watched" is on.
    private var displayItems: [CatalogueItem] {
        guard state.hideWatched else { return items }
        return items.filter { !state.watched.isWatched(url: $0.url) }
    }

    // MARK: Idle (recent searches + prompt)

    @ViewBuilder private var idleView: some View {
        if recents.isEmpty {
            CenteredMessage(systemImage: "magnifyingglass",
                            title: "Search HDRezka",
                            subtitle: "Find films, series, cartoons and anime by title.")
                .frame(minHeight: 360)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    Button("Clear") { recentsRaw = "" }
                        .buttonStyle(.link).font(.callout)
                }
                .padding(.bottom, 2)

                ForEach(recents, id: \.self) { q in
                    Button {
                        query = q
                        Task { await run() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text(q)
                            Spacer()
                            Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                    Divider()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Live suggestions

    @ViewBuilder private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if suggesting && suggestions.isEmpty {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 12) {
                        SkeletonBox(cornerRadius: 4).frame(width: 40, height: 58)
                        SkeletonBox(cornerRadius: 4).frame(width: 200, height: 12)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            } else if suggestions.isEmpty {
                CenteredMessage(systemImage: "magnifyingglass",
                                title: "No matches for “\(trimmedQuery)”",
                                subtitle: "Press Return to run a full search.")
                    .frame(minHeight: 260)
            } else {
                ForEach(suggestions) { item in
                    NavigationLink(value: item) { SuggestionRow(item: item) }
                        .buttonStyle(.plain)
                    Divider()
                }
                Button {
                    Task { await run() }
                } label: {
                    Label("Search all results for “\(trimmedQuery)”", systemImage: "magnifyingglass")
                }
                .buttonStyle(.link)
                .padding(.top, 10)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    /// Debounced fast-search for the suggestion list.
    private func scheduleSuggest() {
        suggestTask?.cancel()
        let q = trimmedQuery
        guard q.count >= 2, case .ready = state.sidecar.state else {
            suggestions = []; suggesting = false; return
        }
        suggesting = true
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let results = (try? await state.api.search(q, advanced: false)) ?? []
            guard !Task.isCancelled, trimmedQuery == q else { return }
            suggestions = Array(results.prefix(8))
            suggesting = false
        }
    }

    private func run() async {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        guard case .ready = state.sidecar.state else {
            error = "The helper isn't ready yet."; return
        }
        suggestTask?.cancel()
        loading = true; error = nil; searched = true
        defer { loading = false }
        do {
            // Advanced search returns posters with images; nicer for a grid.
            items = try await state.api.search(q, advanced: true)
            remember(q)
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            items = []
        }
    }

    /// Prepend `q` to the recents list, de-duped (case-insensitive), capped at 8.
    private func remember(_ q: String) {
        var list = recents.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentsRaw = list.prefix(8).joined(separator: "\n")
    }
}

/// A compact search-suggestion row: small poster thumb + title + subtitle.
private struct SuggestionRow: View {
    let item: CatalogueItem

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(urlString: item.image)
                .frame(width: 40, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let info = item.info {
                    Text(info).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let r = item.rating {
                Text(String(format: "%.1f", r)).font(.caption).bold().foregroundStyle(.yellow)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}
