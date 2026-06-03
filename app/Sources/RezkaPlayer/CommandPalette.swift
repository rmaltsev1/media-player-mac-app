import SwiftUI

/// A global ⌘K command palette: jump to any sidebar section or search HDRezka titles
/// inline, all from the keyboard. Presented as a sheet from `RootView`; results are
/// surfaced to the app via `AppState.pendingSection` / `AppState.pendingItem`.
struct CommandPalette: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    @State private var query = ""
    @State private var results: [CatalogueItem] = []
    @State private var loading = false
    /// The debounced search task; cancelled and replaced on each keystroke.
    @State private var searchTask: Task<Void, Never>?

    private let width: CGFloat = 620

    /// Sidebar sections matching the current query (all when the query is empty).
    private var matchingSections: [SidebarSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SidebarSection.allCases }
        return SidebarSection.allCases.filter { $0.title.lowercased().contains(q) }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: width)
        .frame(maxHeight: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Go to a section or search titles…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit { activateFirst() }
            if loading {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Results

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !matchingSections.isEmpty {
                    sectionHeader("Go to")
                    ForEach(matchingSections) { section in
                        Button { choose(section: section) } label: {
                            sectionRow(section)
                        }
                        .buttonStyle(PaletteRowStyle())
                    }
                }

                if !trimmedQuery.isEmpty {
                    sectionHeader("Titles")
                    if !results.isEmpty {
                        ForEach(results) { item in
                            Button { choose(item: item) } label: {
                                titleRow(item)
                            }
                            .buttonStyle(PaletteRowStyle())
                        }
                    } else if loading {
                        Text("Searching…")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    } else {
                        Text("No titles found")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2).bold()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8).padding(.bottom, 2)
    }

    private func sectionRow(_ section: SidebarSection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(section.title)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func titleRow(_ item: CatalogueItem) -> some View {
        HStack(spacing: 12) {
            PosterImage(urlString: item.image)
                .frame(width: 32, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let info = item.info, !info.isEmpty {
                    Text(info).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let r = item.rating {
                Text(String(format: "%.1f", r))
                    .font(.caption).bold()
                    .foregroundStyle(.yellow)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Return-key behaviour: prefer the first matching title, otherwise the first section.
    private func activateFirst() {
        if !trimmedQuery.isEmpty, let first = results.first {
            choose(item: first)
        } else if let section = matchingSections.first {
            choose(section: section)
        }
    }

    private func choose(section: SidebarSection) {
        state.pendingSection = section
        dismiss()
    }

    private func choose(item: CatalogueItem) {
        state.pendingItem = item
        dismiss()
    }

    // MARK: Debounced search

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = trimmedQuery
        guard !q.isEmpty else {
            results = []; loading = false
            return
        }
        loading = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard case .ready = state.sidecar.state else {
                await MainActor.run { loading = false }
                return
            }
            // Best-effort: search failures just show nothing.
            let found = (try? await state.api.search(q, advanced: true)) ?? []
            if Task.isCancelled { return }
            await MainActor.run {
                results = found
                loading = false
            }
        }
    }
}

/// A subtle hover/press highlight for palette rows.
private struct PaletteRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.30 : (hovering ? 0.18 : 0)))
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
