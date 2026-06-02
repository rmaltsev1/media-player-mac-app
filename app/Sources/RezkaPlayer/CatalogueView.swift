import SwiftUI

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
    @State private var collection: String = "best"   // best | latest
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
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
        .navigationTitle(mode.title)
        .toolbar {
            if !isHome {
                ToolbarItem(placement: .primaryAction) {
                    Picker("", selection: $collection) {
                        Text("Top-ranked").tag("best")
                        Text("Latest").tag("latest")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
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

    private var isHome: Bool { mode == .home }
    private var taskKey: String { "\(mode.category)-\(collection)-\(isHome)" }

    private func load() async {
        guard case .ready = state.sidecar.state else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let coll = isHome ? "watching" : collection
            items = try await state.api.browse(collection: coll, category: mode.category)
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
