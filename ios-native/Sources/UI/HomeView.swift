import SwiftUI

/// 首页：无限拖拽的海报墙（原版 Lattice）。
///
/// 墙面铺两套来源，和桌面端一致：
/// - 有队列时 → 队列墙（每首歌一张卡，当前播放描边、徽标是序号）
/// - 没有队列时 → 资料库墙（收藏的歌单 / 专辑）
///
/// 右下角是 `WallToolsPanel`（原版 `WallToolsButton` 的 1:1 版），按钮上方的队列浮岛与迷你播放条
/// 对应原版 `WallToolsQueueIsland` 与底栏。
struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var mode: Mode = .library
    @State private var openCollection: MusicCollection?
    @State private var showSettings = false
    @State private var showPlayer = false
    @State private var showQueueIsland = false
    @State private var isTintEnabled = false
    @State private var isLightsOut = false

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
                .ignoresSafeArea()

            LatticeWallView(
                items: items,
                theme: theme,
                lightsOut: isLightsOut,
                hasPosterTint: isTintEnabled,
                autoFocusOnSongChange: mode == .queue,
                emptyTitle: mode == .queue ? "队列是空的" : "还没有歌单",
                emptyText: mode == .queue
                    ? "开始播放任意歌曲后，队列会在这里铺开。"
                    : "在设置里扫码登录网易云，墙面就会铺满你的收藏。",
                toolbar: AnyView(toolsStack),
                onOpenItem: { item in
                    if case .collection(let collection) = item.source {
                        openCollection = collection
                    }
                },
                onOpenPlayer: { showPlayer = true }
            )
            .id(mode)
        }
        .ignoresSafeArea()
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
            if empty { showQueueIsland = false }
        }
        .onAppear {
            if !player.queue.isEmpty { mode = .queue }
        }
    }

    /// 按钮上方的一列（column-reverse）：队列浮岛在上、迷你播放条与工具按钮在下
    private var toolsStack: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let song = player.currentSong {
                MiniPlayerBar(song: song) { showPlayer = true }
                    .frame(maxWidth: 296)
            }
            if showQueueIsland, !player.queue.isEmpty {
                QueueIsland(
                    songs: player.queue,
                    currentIndex: player.currentIndex,
                    onSelect: { index in
                        player.play(at: index)
                    },
                    onClose: { showQueueIsland = false }
                )
                .frame(width: 296)
                .frame(maxHeight: 368)
            }
            VStack(alignment: .trailing, spacing: 8) {
                WallToolsPanel(
                    quick: quickActions,
                    entries: panelEntries,
                    isTintEnabled: isTintEnabled,
                    isLightsOut: isLightsOut,
                    helpLines: [
                        ("拖拽墙面", "拖动"),
                        ("缩放墙面", "双指"),
                        ("聚焦正在播放", "长按"),
                        ("打开 / 收起卡片", "点按"),
                    ],
                    onRoute: handle,
                    onToggleTint: { isTintEnabled.toggle() },
                    onSetLights: { lightsOn in isLightsOut = !lightsOn }
                )
                .environmentObject(player)
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    // MARK: - 面板条目

    /// 快捷排固定顺序：洗牌、主题、队列、去处、播放器、设置
    private var quickActions: [WallToolsPanel.QuickAction] {
        [
            .init(id: .shuffleQueue, icon: "shuffle", label: "打乱队列",
                  disabled: !canShuffle, keepOpen: true),
            .init(id: .generateTheme, icon: "sparkles", label: "生成主题",
                  disabled: true, keepOpen: true),
            .init(id: .queue, icon: "list.bullet", label: showQueueIsland ? "收起队列" : "播放队列",
                  disabled: player.queue.isEmpty, keepOpen: true),
            .init(id: .destination, icon: mode == .queue ? "square.grid.2x2" : "music.note.list",
                  label: mode == .queue ? "资料库" : "播放队列"),
            .init(id: .openPlayer, icon: "opticaldisc", label: "打开播放面板",
                  disabled: player.currentSong == nil),
            .init(id: .openSettings, icon: "gearshape", label: "打开设置"),
        ]
    }

    private var canShuffle: Bool { player.queue.count > 1 }

    private var panelEntries: [WallToolsPanel.Entry] {
        [
            .init(id: "wall-mode", kind: .action(
                icon: "rectangle.3.group",
                label: "墙面",
                value: mode == .queue ? "队列" : "资料库",
                disabled: false
            )),
            .init(id: "auto-focus", kind: .action(
                icon: "scope",
                label: "切歌自动聚焦",
                value: mode == .queue ? "开" : "关",
                disabled: true
            )),
        ]
    }

    private func handle(_ route: WallToolsPanel.Route) {
        switch route {
        case .shuffleQueue:
            shuffleQueue()
        case .generateTheme:
            break
        case .queue:
            showQueueIsland.toggle()
        case .destination:
            mode = mode == .queue ? .library : .queue
        case .openPlayer:
            showPlayer = true
        case .openSettings:
            showSettings = true
        }
    }

    /// 打乱队列，正在播的那首留在开头（原版 shuffleQueue）
    private func shuffleQueue() {
        guard canShuffle, let current = player.currentSong else { return }
        var rest = player.queue
        rest.removeAll { $0.id == current.id }
        rest.shuffle()
        player.play([current] + rest, startIndex: 0, contextName: player.contextName)
    }
}

/// 队列浮岛：原版 `WallToolsQueueIsland` 的窄版——宽与面板同（296）、头部 36、
/// 行最高 40、最多 8 行，当前行 10% 底。
private struct QueueIsland: View {
    let songs: [Song]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("播放队列 · \(songs.count) 首")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起队列")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 36)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.prefix(120).enumerated()), id: \.offset) { index, song in
                        Button {
                            onSelect(index)
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.42))
                                    .frame(width: 20, alignment: .trailing)
                                Text(song.name)
                                    .font(.system(size: 12, weight: index == currentIndex ? .semibold : .regular))
                                    .foregroundStyle(Color.white.opacity(index == currentIndex ? 1 : 0.82))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(song.artistNames)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.42))
                                    .lineLimit(1)
                                    .frame(maxWidth: 96, alignment: .trailing)
                            }
                            .padding(.horizontal, 4)
                            .frame(height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(index == currentIndex ? 0.10 : 0))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.40))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.42), radius: 32, x: 0, y: 24)
        )
    }
}
