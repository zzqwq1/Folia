import SwiftUI

struct RootView: View {
    @StateObject private var library = LibraryStore()
    @EnvironmentObject private var player: PlayerEngine
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            FoliaTheme.background.ignoresSafeArea()

            HomeView()

            if let song = player.currentSong {
                MiniPlayerBar(song: song) { showPlayer = true }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environmentObject(library)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.currentSong)
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .environmentObject(player)
                .environmentObject(library)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task {
            await library.refresh()
        }
    }
}
