import SwiftUI

struct WatchLaterView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            if state.bookmarks.items.isEmpty {
                CenteredMessage(systemImage: "star",
                                title: "Nothing saved yet",
                                subtitle: "Tap the ☆ on a title (or right-click a poster) to save it here for later.")
                    .frame(minHeight: 420)
            } else {
                PosterGrid(items: state.bookmarks.items)
            }
        }
        .navigationTitle("Watch Later")
    }
}
