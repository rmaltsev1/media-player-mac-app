import SwiftUI

/// A poster tile used in catalogue / search grids.
struct PosterCard: View {
    let item: CatalogueItem
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                PosterImage(urlString: item.image)
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))

                if state.watched.isWatched(url: item.url) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if let r = item.rating {
                    Text(String(format: "%.1f", r))
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.yellow)
                        .padding(6)
                }
            }
            Text(item.title)
                .font(.callout).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let info = item.info {
                Text(info).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Async poster image with a graceful placeholder.
struct PosterImage: View {
    let urlString: String?

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                placeholder(systemImage: "photo")
            case .empty:
                placeholder(systemImage: nil)
            @unknown default:
                placeholder(systemImage: "photo")
            }
        }
        .background(Color(nsColor: .quaternarySystemFill))
    }

    @ViewBuilder private func placeholder(systemImage: String?) -> some View {
        ZStack {
            Color(nsColor: .quaternarySystemFill)
            if let systemImage {
                Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Reusable responsive grid of poster tiles that pushes DetailView on tap.
struct PosterGrid: View {
    let items: [CatalogueItem]
    @EnvironmentObject var state: AppState
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 18)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    let saved = state.bookmarks.isBookmarked(item)
                    Button { state.bookmarks.toggle(item) } label: {
                        Label(saved ? "Remove from Watch Later" : "Add to Watch Later",
                              systemImage: saved ? "star.slash" : "star")
                    }
                }
            }
        }
        .padding(20)
    }
}

/// Standard centered status view for loading/error/empty.
struct CenteredMessage: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
