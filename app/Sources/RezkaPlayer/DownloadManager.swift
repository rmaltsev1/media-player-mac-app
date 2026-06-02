import Foundation
import Combine

enum DownloadState: String, Codable {
    case downloading, completed, failed, paused
}

struct DownloadItem: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var pageURL: String          // HDRezka page this came from
    var streamURL: String        // direct .mp4 that was downloaded
    var quality: String
    var posterURL: String?
    var fileName: String         // relative file name in the media dir
    var state: DownloadState
    var bytesReceived: Int64
    var totalBytes: Int64
    var addedAt: Date
    var seasonEpisode: String?   // e.g. "S1E3" for series

    var progress: Double {
        totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : 0
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadItem] = []

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private var taskToItem: [Int: UUID] = [:]
    private let fm = FileManager.default

    override init() {
        super.init()
        load()
    }

    // MARK: Paths

    private var appSupportDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RezkaPlayer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var mediaDir: URL {
        let d = appSupportDir.appendingPathComponent("Media", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var libraryFile: URL { appSupportDir.appendingPathComponent("library.json") }

    func localURL(for item: DownloadItem) -> URL {
        mediaDir.appendingPathComponent(item.fileName)
    }

    // MARK: Public API

    /// Begin downloading a stream URL. `key` lets callers de-dupe (e.g. pageURL+quality+ep).
    func startDownload(title: String, pageURL: String, streamURL: String,
                       quality: String, posterURL: String?, seasonEpisode: String? = nil) {
        let id = UUID()
        let fileName = "\(id.uuidString).mp4"
        var item = DownloadItem(
            id: id, title: title, pageURL: pageURL, streamURL: streamURL,
            quality: quality, posterURL: posterURL, fileName: fileName,
            state: .downloading, bytesReceived: 0, totalBytes: 0,
            addedAt: Date(), seasonEpisode: seasonEpisode
        )
        items.insert(item, at: 0)
        save()

        guard let url = URL(string: streamURL) else {
            item.state = .failed
            update(item)
            return
        }
        let task = session.downloadTask(with: url)
        taskToItem[task.taskIdentifier] = id
        task.resume()
    }

    func delete(_ item: DownloadItem) {
        try? fm.removeItem(at: localURL(for: item))
        items.removeAll { $0.id == item.id }
        save()
    }

    func isDownloaded(pageURL: String, quality: String, seasonEpisode: String?) -> Bool {
        items.contains {
            $0.pageURL == pageURL && $0.quality == quality
            && $0.seasonEpisode == seasonEpisode && $0.state == .completed
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data)
        else { return }
        // Anything left "downloading" from a previous run is stale -> mark failed.
        items = decoded.map { var i = $0; if i.state == .downloading { i.state = .failed }; return i }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: libraryFile, options: .atomic)
        }
    }

    private func update(_ item: DownloadItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
            save()
        }
    }

    private func item(forTask id: Int) -> DownloadItem? {
        guard let uuid = taskToItem[id] else { return nil }
        return items.first { $0.id == uuid }
    }
}

// URLSession delegate callbacks arrive on the session's delegate queue (not main).
extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        let tid = downloadTask.taskIdentifier
        Task { @MainActor in
            guard var it = self.item(forTask: tid) else { return }
            it.bytesReceived = totalBytesWritten
            it.totalBytes = totalBytesExpectedToWrite
            self.update(it)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        let tid = downloadTask.taskIdentifier
        // The temp file is removed as soon as this method returns, so move it to a stable
        // staging path *synchronously* now, then promote to the final destination on main.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("rezka-\(tid)-\(UUID().uuidString).mp4")
        var moved = false
        do {
            try FileManager.default.moveItem(at: location, to: staging)
            moved = true
        } catch {
            moved = false
        }
        Task { @MainActor in
            guard var it = self.item(forTask: tid) else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            let dest = self.localURL(for: it)
            try? self.fm.removeItem(at: dest)
            if moved, (try? self.fm.moveItem(at: staging, to: dest)) != nil {
                it.state = .completed
            } else {
                it.state = .failed
            }
            self.update(it)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               didCompleteWithError error: Error?) {
        let tid = task.taskIdentifier
        Task { @MainActor in
            self.taskToItem[tid] = nil
            guard error != nil, var it = self.item(forTask: tid) else { return }
            if it.state != .completed { it.state = .failed }
            self.update(it)
        }
    }
}
