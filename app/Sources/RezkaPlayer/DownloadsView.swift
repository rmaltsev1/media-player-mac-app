import SwiftUI
import AppKit

struct DownloadsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.downloads.items.isEmpty {
                CenteredMessage(systemImage: "arrow.down.circle",
                                title: "No downloads yet",
                                subtitle: "Download a title from its page to watch it offline here.")
            } else {
                List {
                    ForEach(state.downloads.items) { item in
                        DownloadRow(item: item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Downloads")
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            PosterImage(urlString: item.posterURL)
                .frame(width: 54, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).lineLimit(2)
                HStack(spacing: 8) {
                    Text(item.quality).font(.caption).foregroundStyle(.secondary)
                    if let se = item.seasonEpisode {
                        Text(se).font(.caption).foregroundStyle(.secondary)
                    }
                    statusLabel
                }
                if item.state == .downloading || item.state == .paused {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                    Text(sizeText).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if item.state == .completed {
                // Carry the HDRezka page + episode numbers even though playback is local: progress
                // is keyed on them, so without them Continue Watching recorded the *file path* as a
                // page URL and later failed to load the title (404).
                NavigationLink(value: PlayerTarget(
                    title: item.title,
                    urlString: state.downloads.localURL(for: item).path,
                    isLocal: true,
                    pageURL: item.pageURL,
                    season: item.seasonEpisodeNumbers?.season,
                    episode: item.seasonEpisodeNumbers?.episode,
                    posterURL: item.posterURL,
                    downloadID: item.id)
                ) {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
            }
            if item.state == .downloading {
                Button { state.downloads.pause(item) } label: {
                    Image(systemName: "pause.circle").font(.title2)
                }
                .buttonStyle(.plain)
                .help("Pause download")
            }
            if item.state == .paused {
                Button { state.downloads.resume(item) } label: {
                    Image(systemName: "play.circle").font(.title2)
                }
                .buttonStyle(.plain)
                .help("Resume download")
            }
            Menu {
                if item.state == .completed {
                    Button { revealInFinder() } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                Button(role: .destructive) { state.downloads.delete(item) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .contextMenu {
            if item.state == .completed {
                Button { revealInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
            }
            Button(role: .destructive) { state.downloads.delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func revealInFinder() {
        let url = state.downloads.localURL(for: item)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var statusLabel: some View {
        switch item.state {
        case .completed: return Text("Ready").font(.caption).foregroundStyle(.green)
        case .downloading: return Text("Downloading").font(.caption).foregroundStyle(.blue)
        case .failed: return Text("Failed").font(.caption).foregroundStyle(.red)
        case .paused: return Text("Paused").font(.caption).foregroundStyle(.orange)
        }
    }

    private var sizeText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        let got = f.string(fromByteCount: item.bytesReceived)
        if item.totalBytes > 0 {
            return "\(got) / \(f.string(fromByteCount: item.totalBytes))"
        }
        return got
    }
}
