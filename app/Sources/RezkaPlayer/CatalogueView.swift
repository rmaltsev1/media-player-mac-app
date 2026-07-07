import SwiftUI

/// Genre slugs/labels mirrored from the sidecar's `browse.GENRES` so the catalogue can
/// populate its Genre menu without a round-trip. Keep in sync with browse.py.
enum CatalogueGenres {
    struct Genre: Hashable { let slug: String; let label: String }

    static let shared: [Genre] = [
        .init(slug: "comedy", label: "Comedy"),
        .init(slug: "drama", label: "Drama"),
        .init(slug: "melodrama", label: "Melodrama"),
        .init(slug: "thriller", label: "Thriller"),
        .init(slug: "horror", label: "Horror"),
        .init(slug: "boevik", label: "Action"),
        .init(slug: "fantastika", label: "Sci-Fi"),
        .init(slug: "fjentezi", label: "Fantasy"),
        .init(slug: "detektiv", label: "Detective"),
        .init(slug: "priklyucheniya", label: "Adventure"),
        .init(slug: "kriminal", label: "Crime"),
        .init(slug: "military", label: "War"),
        .init(slug: "istoricheskiy", label: "History"),
        .init(slug: "semeyniy", label: "Family"),
        .init(slug: "western", label: "Western"),
        .init(slug: "biographicheskiy", label: "Biography"),
        .init(slug: "arthouse", label: "Arthouse"),
    ]

    static let animation: [Genre] = [
        .init(slug: "anime", label: "Anime"),
        .init(slug: "comedy", label: "Comedy"),
        .init(slug: "drama", label: "Drama"),
        .init(slug: "melodrama", label: "Melodrama"),
        .init(slug: "boevik", label: "Action"),
        .init(slug: "fantastika", label: "Sci-Fi"),
        .init(slug: "fjentezi", label: "Fantasy"),
        .init(slug: "priklyucheniya", label: "Adventure"),
        .init(slug: "detektiv", label: "Detective"),
        .init(slug: "semeyniy", label: "Family"),
    ]

    static func forCategory(_ category: String) -> [Genre] {
        category == "animation" ? animation : shared
    }
}

struct CatalogueView: View {
    enum Mode: Equatable {
        case home
        case category(String, title: String)

        var title: String {
            switch self {
            case .home: return "Now Watching"
            case .category(_, let t): return t
            }
        }
        var category: String {
            switch self {
            case .home: return "films"       // ignored for the "watching" collection
            case .category(let c, _): return c
            }
        }
    }

    let mode: Mode
    @EnvironmentObject var state: AppState

    @State private var items: [CatalogueItem] = []
    @State private var sort: String = "best"         // best | last | popular | watching
    @State private var genre: String = ""            // "" == All
    @State private var year: Int = 0                 // 0 == All
    @State private var loading = false
    @State private var error: String?

    // "Because you watched" recommendation rows (Home only). Loaded best-effort in `.task`;
    // empty rows simply render nothing.
    @State private var becauseItems: [CatalogueItem] = []      // similar to most-recent watched
    @State private var becauseTitle: String = ""               // e.g. "Because you watched Dune"
    @State private var moreGenreItems: [CatalogueItem] = []    // top-genre catalogue
    @State private var moreGenreTitle: String = ""             // e.g. "More Drama"

    /// Sort options shown in the picker -> (sidecar sort value, label).
    private static let sortOptions: [(String, String)] = [
        ("best", "Top-ranked"),
        ("last", "Latest"),
        ("popular", "Popular"),
        ("watching", "Watching"),
    ]

    /// Recent years for the Year menu (current year down ~30).
    private static let years: [Int] = {
        let now = Calendar.current.component(.year, from: Date())
        return Array(stride(from: now, through: now - 30, by: -1))
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isHome, !continueItems.isEmpty {
                    continueWatchingSection
                }
                if isHome {
                    recommendationsSection
                }
                mainContent
            }
        }
        .navigationTitle(mode.title)
        .toolbar {
            if !isHome {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Sort", selection: $sort) {
                        ForEach(Self.sortOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Genre", selection: $genre) {
                            Text("All genres").tag("")
                            ForEach(CatalogueGenres.forCategory(mode.category), id: \.slug) { g in
                                Text(g.label).tag(g.slug)
                            }
                        }
                    } label: { Label(genreLabel, systemImage: "theatermasks") }
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Year", selection: $year) {
                            Text("All years").tag(0)
                            ForEach(Self.years, id: \.self) { y in Text(String(y)).tag(y) }
                        }
                    } label: { Label(year == 0 ? "Any year" : String(year), systemImage: "calendar") }
                }
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $state.hideWatched) {
                    Label("Hide watched", systemImage: "eye.slash")
                }
                .toggleStyle(.button)
                .help(state.hideWatched ? "Showing unwatched only" : "Hide watched titles")
            }
            ToolbarItem(placement: .automatic) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task(id: taskKey) { await load() }
        .task(id: recommendationsKey) { if isHome { await loadRecommendations() } }
        .onChange(of: state.sidecar.state) { _, new in
            if case .ready = new, items.isEmpty { Task { await load() } }
        }
    }

    @ViewBuilder private var mainContent: some View {
        if loading && items.isEmpty {
            SkeletonPosterGrid()
        } else if let error, items.isEmpty {
            CenteredMessage(systemImage: "exclamationmark.triangle",
                            title: "Couldn't load", subtitle: error)
                .frame(minHeight: 400)
        } else if items.isEmpty {
            CenteredMessage(systemImage: "film", title: "Nothing here yet")
                .frame(minHeight: 400)
        } else if displayItems.isEmpty {
            CenteredMessage(systemImage: "eye.slash", title: "All watched",
                            subtitle: "Every title here is marked watched. Turn off “Hide watched” to see them.")
                .frame(minHeight: 400)
        } else {
            PosterGrid(items: displayItems)
        }
    }

    /// `items` with watched titles removed when "Hide watched" is on.
    private var displayItems: [CatalogueItem] {
        guard state.hideWatched else { return items }
        return items.filter { !state.watched.isWatched(url: $0.url) }
    }

    /// In-progress titles (one tile per title, most-recent first) for the Home "Continue Watching" row.
    private var continueItems: [CatalogueItem] {
        var seen = Set<String>()
        var out: [CatalogueItem] = []
        for e in state.progress.recent() where !seen.contains(e.pageURL) {
            seen.insert(e.pageURL)
            out.append(CatalogueItem(
                title: e.title, url: e.pageURL, image: e.posterURL,
                rating: nil, category: nil,
                info: e.season.flatMap { s in e.episode.map { "S\(s)E\($0)" } },
                postId: nil))
        }
        return out
    }

    @ViewBuilder private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching").font(.title3).bold()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(continueItems) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item).frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    // MARK: Because-you-watched recommendations (Home only)

    @ViewBuilder private var recommendationsSection: some View {
        if !becauseItems.isEmpty {
            recommendationRow(title: becauseTitle, items: becauseItems)
        }
        if !moreGenreItems.isEmpty {
            recommendationRow(title: moreGenreTitle, items: moreGenreItems)
        }
    }

    @ViewBuilder private func recommendationRow(title: String, items: [CatalogueItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3).bold()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item).frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16)
    }

    /// Re-derive the recommendation rows from the current watch history. Best-effort:
    /// network/geo failures or empty history just leave the rows empty (nothing renders).
    private func loadRecommendations() async {
        guard case .ready = state.sidecar.state else { return }
        let history = state.watched.history()
        guard !history.isEmpty else {
            becauseItems = []; becauseTitle = ""
            moreGenreItems = []; moreGenreTitle = ""
            return
        }

        var shown = Set<String>()   // URLs already surfaced, to avoid cross-row dupes

        // Row 1 — similar to the single most-recently watched title.
        var row1: [CatalogueItem] = []
        var row1Title = ""
        let recent = history[0]
        if let info = try? await state.api.info(url: recent.url) {
            let similar = (info.similar ?? []).filter {
                !state.watched.isWatched(url: $0.url)
            }
            row1 = Array(similar.prefix(15))
            row1.forEach { shown.insert($0.url) }
            if !row1.isEmpty { row1Title = "Because you watched \(info.name)" }
        }
        becauseItems = row1
        becauseTitle = row1Title

        // Row 2 — more from the user's most-frequent (category, genre).
        var row2: [CatalogueItem] = []
        var row2Title = ""
        if let top = topGenre(from: history) {
            if let results = try? await state.api.browse(
                collection: "best", category: top.category,
                genre: top.slug, sort: "best") {
                let filtered = results.filter {
                    !state.watched.isWatched(url: $0.url) && !shown.contains($0.url)
                }
                row2 = Array(filtered.prefix(15))
                if !row2.isEmpty { row2Title = "More \(top.label)" }
            }
        }
        moreGenreItems = row2
        moreGenreTitle = row2Title
    }

    /// The most-frequent (category, genre slug, label) across the watch history, or nil if none
    /// of the URLs encode a recognisable genre.
    private func topGenre(from history: [CatalogueItem]) -> (category: String, slug: String, label: String)? {
        var counts: [String: (category: String, slug: String, label: String, n: Int)] = [:]
        for item in history {
            guard let parsed = Self.categoryGenre(fromPageURL: item.url) else { continue }
            let key = "\(parsed.category)/\(parsed.slug)"
            let n = (counts[key]?.n ?? 0) + 1
            counts[key] = (parsed.category, parsed.slug, parsed.label, n)
        }
        guard let best = counts.values.max(by: { $0.n < $1.n }) else { return nil }
        return (best.category, best.slug, best.label)
    }

    /// Parse the HDRezka category + genre slug from a page URL path, e.g.
    /// `https://host/films/drama/763-...html` → ("films", "drama", "Drama"). The genre slug
    /// is mapped to a display label via `CatalogueGenres`; returns nil if not recognised.
    static func categoryGenre(fromPageURL pageURL: String) -> (category: String, slug: String, label: String)? {
        guard let url = URL(string: pageURL) else { return nil }
        // Drop the leading "/" and any trailing filename like "763-...html".
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let category = parts[0]
        let slug = parts[1]
        guard let genre = CatalogueGenres.forCategory(category).first(where: { $0.slug == slug })
        else { return nil }
        return (category, slug, genre.label)
    }

    /// Key for the recommendations `.task`: refreshes whenever the most-recent watched title
    /// or the history size changes, plus when the sidecar becomes ready.
    private var recommendationsKey: String {
        let h = state.watched.history()
        let ready = { if case .ready = state.sidecar.state { return "1" }; return "0" }()
        return "\(ready)-\(h.count)-\(h.first?.url ?? "")"
    }

    private var isHome: Bool { mode == .home }

    private var genreLabel: String {
        guard !genre.isEmpty,
              let g = CatalogueGenres.forCategory(mode.category).first(where: { $0.slug == genre })
        else { return "All genres" }
        return g.label
    }

    private var taskKey: String {
        "\(mode.category)-\(isHome)-\(sort)-\(genre)-\(year)"
    }

    private func load() async {
        guard case .ready = state.sidecar.state else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            if isHome {
                items = try await state.api.browse(collection: "watching", category: mode.category)
            } else {
                // The sidecar derives the path from `sort`; collection just picks the base.
                let coll = sort == "last" ? "latest" : "best"
                items = try await state.api.browse(
                    collection: coll, category: mode.category,
                    genre: genre.isEmpty ? nil : genre,
                    year: year == 0 ? nil : year,
                    sort: sort)
            }
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
