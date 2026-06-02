import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home, films, series, cartoons, animation, search, downloads

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Now Watching"
        case .films: return "Films"
        case .series: return "Series"
        case .cartoons: return "Cartoons"
        case .animation: return "Anime"
        case .search: return "Search"
        case .downloads: return "Downloads"
        }
    }
    var systemImage: String {
        switch self {
        case .home: return "flame"
        case .films: return "film"
        case .series: return "tv"
        case .cartoons: return "teddybear"
        case .animation: return "sparkles"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle"
        }
    }
    /// HDRezka category path for catalogue sections (nil for non-catalogue).
    var category: String? {
        switch self {
        case .films: return "films"
        case .series: return "series"
        case .cartoons: return "cartoons"
        case .animation: return "animation"
        default: return nil
        }
    }
}

/// A pushed video target (streaming or local file).
struct PlayerTarget: Hashable {
    let title: String
    let urlString: String
    let isLocal: Bool
    var subtitleURL: String? = nil
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var selection: SidebarSection = .home
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidecarStatusBar() }
        } detail: {
            NavigationStack(path: $path) {
                sectionRoot
                    .navigationDestination(for: CatalogueItem.self) { item in
                        DetailView(item: item)
                    }
                    .navigationDestination(for: PlayerTarget.self) { target in
                        PlayerView(target: target)
                    }
            }
        }
        .onChange(of: selection) { _, _ in path = NavigationPath() }
    }

    @ViewBuilder private var sectionRoot: some View {
        switch selection {
        case .home:
            CatalogueView(mode: .home)
        case .films, .series, .cartoons, .animation:
            CatalogueView(mode: .category(selection.category!, title: selection.title))
        case .search:
            SearchView()
        case .downloads:
            DownloadsView()
        }
    }
}

/// Small status pill showing whether the Python helper is up.
struct SidecarStatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if case .failed = state.sidecar.state {
                Button("Retry") { state.sidecar.restart() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var color: Color {
        switch state.sidecar.state {
        case .ready: return .green
        case .starting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }
    private var label: String {
        switch state.sidecar.state {
        case .ready(let p): return "Helper ready · :\(p)"
        case .starting: return "Starting helper…"
        case .stopped: return "Helper stopped"
        case .failed(let m): return m
        }
    }
}
