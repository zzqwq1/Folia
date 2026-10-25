import SwiftUI

struct RootView: View {
    @StateObject private var library = LibraryStore()
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        ZStack {
            FoliaTheme.background.ignoresSafeArea()
            HomeView()
        }
        .environmentObject(library)
        .task {
            await library.refresh()
        }
    }
}
