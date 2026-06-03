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
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task(id: taskKey) { await load() }
        .onChange(of: state.sidecar.state) { _, new in
            if case .ready = new, items.isEmpty { Task { await load() } }
        }
    }

    @ViewBuilder private var mainContent: some View {
        if loading && items.isEmpty {
            CenteredMessage(systemImage: "hourglass", title: "Loading…")
                .frame(minHeight: 400)
        } else if let error, items.isEmpty {
            CenteredMessage(systemImage: "exclamationmark.triangle",
                            title: "Couldn't load", subtitle: error)
                .frame(minHeight: 400)
        } else if items.isEmpty {
            CenteredMessage(systemImage: "film", title: "Nothing here yet")
                .frame(minHeight: 400)
        } else {
            PosterGrid(items: items)
        }
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
