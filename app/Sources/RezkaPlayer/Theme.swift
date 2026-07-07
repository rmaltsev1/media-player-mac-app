import SwiftUI

/// Shared design tokens so radii, tile sizing, and accents stay consistent across views
/// instead of being sprinkled as literals. Tweak here to restyle the whole app.
enum Theme {
    /// Corner radii.
    static let posterRadius: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let tileRadius: CGFloat = 8

    /// Poster grid tile sizing (also used by skeletons so they line up 1:1).
    static let tileMin: CGFloat = 158
    static let tileMax: CGFloat = 200
    static let tileSpacing: CGFloat = 20
    static let posterAspect: CGFloat = 2.0 / 3.0

    /// Brand accent used for primary actions / progress.
    static let accent = Color.accentColor
}

// MARK: - Cached async image

/// Process-wide decoded-image cache. `AsyncImage` re-fetches/re-decodes as cells recycle
/// during scrolling; this keeps posters instant once seen.
private final class ImageMemoryCache {
    static let shared = ImageMemoryCache()
    private let cache = NSCache<NSURL, NSImage>()
    init() { cache.countLimit = 400 }
    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

@MainActor
private final class CachedImageLoader: ObservableObject {
    enum Phase { case empty, success(NSImage), failure }
    @Published var phase: Phase = .empty

    private var task: Task<Void, Never>?
    private var currentURL: URL?

    func load(_ url: URL?) {
        guard let url else { phase = .empty; return }
        if currentURL == url, case .success = phase { return }
        currentURL = url

        if let cached = ImageMemoryCache.shared.image(for: url) {
            phase = .success(cached); return
        }
        phase = .empty
        task?.cancel()
        task = Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                guard let img = NSImage(data: data) else {
                    await MainActor.run { self?.phase = .failure }; return
                }
                ImageMemoryCache.shared.insert(img, for: url)
                await MainActor.run {
                    guard self?.currentURL == url else { return }
                    self?.phase = .success(img)
                }
            } catch is CancellationError {
                // superseded; leave state alone
            } catch {
                await MainActor.run {
                    guard self?.currentURL == url else { return }
                    self?.phase = .failure
                }
            }
        }
    }
}

/// A memory-cached async image with success / loading / failure placeholder slots.
/// Drop-in replacement for `AsyncImage` that survives grid cell recycling smoothly.
struct CachedAsyncImage<Success: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image) -> Success
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder

    @StateObject private var loader = CachedImageLoader()

    var body: some View {
        Group {
            switch loader.phase {
            case .success(let img): content(Image(nsImage: img))
            case .failure:          placeholder(true)
            case .empty:            placeholder(false)
            }
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { _, new in loader.load(new) }
    }
}
