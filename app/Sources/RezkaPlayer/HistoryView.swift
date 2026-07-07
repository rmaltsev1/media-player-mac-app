import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            let history = state.watched.history()
            if history.isEmpty {
                CenteredMessage(systemImage: "clock.arrow.circlepath",
                                title: "No history yet",
                                subtitle: "Titles you mark watched (or finish playing) show up here.") {
                    Button { state.pendingSection = .films } label: {
                        Label("Browse Films", systemImage: "film")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(minHeight: 420)
            } else {
                PosterGrid(items: history)
            }
        }
        .navigationTitle("History")
    }
}
