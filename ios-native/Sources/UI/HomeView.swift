import SwiftUI

/// 首页：无限拖拽的海报墙（原版 Lattice）。
///
/// 墙面铺两套来源，和桌面端一致：
/// - 有队列时 → 队列墙（每首歌一张卡，当前播放描边、徽标是序号）
/// - 没有队列时 → 资料库墙（收藏的歌单 / 专辑）
struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var mode: Mode = .library
    @State private var openCollection: MusicCollection?
    @State private var showSettings = false
    @State private var showPlayer = false

    enum Mode: Equatable {
        case library
        case queue
    }

    private var theme: WallTheme { .midnight }

    private var queueItems: [WallItem] {
        WallItem.songs(WallTile.build(queue: player.queue, currentIndex: player.currentIndex))
    }

    private var libraryItems: [WallItem] {
        WallItem.collections(library.collections)
    }

    private var items: [WallItem] {
        mode == .queue ? queueItems : libraryItems
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WallBackdrop(theme: theme, hasVignette: true)

            LatticeWallView(
                items: items,
                theme: theme,
                lightsOut: false,
                hasPosterTint: false,
                autoFocusOnSongChange: mode == .queue,
                emptyTitle: mode == .queue ? "队列是空的" : "还没有歌单",
                emptyText: mode == .queue
                    ? "开始播放任意歌曲后，队列会在这里铺开。"
                    : "在设置里扫码登录网易云，墙面就会铺满你的收藏。",
                toolbar: AnyView(toolbar),
                onOpenItem: { item in
                    if case .collection(let collection) = item.source {
                        openCollection = collection
                    }
                },
                onOpenPlayer: { showPlayer = true }
            )
            .id(mode)
        }
        .sheet(item: $openCollection) { collection in
            CollectionView(collection: collection)
                .environmentObject(player)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(library)
                .environmentObject(player)
        }
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .environmentObject(player)
                .environmentObject(library)
        }
        .onChange(of: player.queue.isEmpty) { empty in
            // 队列空了回到资料库墙，有歌了自动进队列墙
            mode = empty ? .library : .queue
        }
        .onAppear {
            if !player.queue.isEmpty { mode = .queue }
        }
    }

    /// 右下角工具区：资料库 / 队列切换 + 设置
    private var toolbar: some View {
        VStack(alignment: .trailing, spacing: 10) {
            chromeButton(
                icon: mode == .queue ? "square.grid.2x2" : "music.note.list",
                help: mode == .queue ? "资料库" : "播放队列"
            ) {
                mode = mode == .queue ? .library : .queue
            }
            chromeButton(icon: "person.crop.circle", help: "设置 / 账号") {
                showSettings = true
            }
        }
    }

    private func chromeButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(theme.ink)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().fill(Color.white.opacity(0.08)))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.24), radius: 15, x: 0, y: 10)
                .contentShape(Circle())
        }
        .buttonStyle(WallBackButtonStyle())
        .accessibilityLabel(help)
    }
}
