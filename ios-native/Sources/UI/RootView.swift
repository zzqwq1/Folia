import SwiftUI

struct RootView: View {
    @StateObject private var library = LibraryStore()
    @EnvironmentObject private var player: PlayerEngine

    /// 首屏遮罩：原版 AppSplashGate 在首帧绘制后淡出（320ms ease）
    @State private var showSplash = true

    var body: some View {
        ZStack {
            FoliaTheme.background.ignoresSafeArea()
            HomeView()

            if showSplash {
                GeometryReader { geo in
                    SplashView(titleSize: min(max(geo.size.width * 0.17, 64), 200))
                }
                .transition(.opacity)
                .zIndex(1000)
                .allowsHitTesting(false)
            }
        }
        .environmentObject(library)
        .task {
            // 首屏数据回来（或超时）之后淡出遮罩
            let started = Date()
            await library.refresh()
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 1.1 {
                try? await Task.sleep(nanoseconds: UInt64((1.1 - elapsed) * 1_000_000_000))
            }
            withAnimation(.easeInOut(duration: 0.32)) { showSplash = false }
        }
    }
}
