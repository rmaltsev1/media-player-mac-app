import SwiftUI
import AVKit

struct PlayerView: View {
    let target: PlayerTarget
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else {
                CenteredMessage(systemImage: "play.slash", title: "Can't play this stream")
            }
        }
        .navigationTitle(target.title)
        .onAppear(perform: setup)
    }

    private func setup() {
        guard player == nil else { return }
        let url: URL?
        if target.isLocal {
            url = URL(fileURLWithPath: target.urlString)
        } else {
            url = URL(string: target.urlString)
        }
        guard let url else { return }

        let item: AVPlayerItem
        if target.isLocal {
            item = AVPlayerItem(url: url)
        } else {
            // HDRezka CDN expects a browser-like User-Agent.
            let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                           "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            item = AVPlayerItem(asset: asset)
        }
        let p = AVPlayer(playerItem: item)
        p.play()
        player = p
    }
}
