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
    /// 原版 `showQueueIsland = isOpen && common.queueIslandShown`：浮岛随面板一起出现、一起收起，
    /// 这个偏好由面板快捷排的「队列」格开合（`wallToolsQueueIslandOpen`）。
    @State private var showQueueIsland = false
    @State private var isToolsOpen = false
    @State private var isTintEnabled = false
    @State private var isLightsOut = false
    /// 集合页的定位按钮：记下要定位的歌，墙视图按这个值把它移到视口中心
    @State private var locateRequest: WallLocateRequest?

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

            // 底部居中的播放胶囊（原版 `FloatingPlayerControls`，`z-60`）
            if player.currentSong != nil {
                PlayerCapsule(onOpenPlayer: { showPlayer = true })
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .zIndex(60)
            }

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
                onOpenPlayer: { showPlayer = true },
                locateRequest: locateRequest
            )
            .id(mode)

            // 集合页：原版是固定铺满的 `fixed inset-0 z-[110]`，不是系统 sheet
            if let collection = openCollection {
                CollectionView(
                    collection: collection,
                    wallItems: items,
                    onLocate: { songId in
                        locateRequest = WallLocateRequest(
                            songId: songId,
                            nonce: (locateRequest?.nonce ?? 0) + 1
                        )
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.24)) { openCollection = nil }
                    }
                )
                .environmentObject(player)
                .transition(.opacity)
                .zIndex(110)
            }
        }
        .ignoresSafeArea()
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

    /// 按钮上方的一列（column-reverse）：队列浮岛在上、工具按钮在下
    private var toolsStack: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if showQueueIsland && isToolsOpen {
                QueueIsland()
                    .frame(width: 296)
                    .transition(.opacity)
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
                    onSetLights: { lightsOn in isLightsOut = !lightsOn },
                    onOpenChange: { isToolsOpen = $0 }
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
                  keepOpen: true),
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
            // 原版是纯偏好开合，不看队列是否为空（空队列浮岛里显示「队列是空的」）
            withAnimation(.easeOut(duration: 0.18)) { showQueueIsland.toggle() }
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

// MARK: - 队列浮岛（`WallToolsQueueIsland` 1:1）

/// 逐条对齐 `WallToolsQueueIsland.css`：
/// - 与工具面板同宽（296）、r20、`rgb(0 0 0 / 40%)` + blur 24、1px 白 8%、阴影 0 24 64 / 42%
/// - 高度 = 2（上下边框）+ 36（头部）+ min(行数, 8) × 40，至少 112
/// - 头部：`padding 0 6 0 14`、标题 12/650/0.72、动作钮 28×28 r9 11/650/0.72，
///   清空两步确认（3 秒内再点）变成强调色胶囊
/// - 行 40：手柄 18×32（触屏常显 0.4）、主按钮 36 高（标记条 3×18 + 标题 12.5/550 + 歌手 10.5/0.52）、
///   动作 26×26 r7（下一首 / 移到队尾 / 移除；正在播的行只留「移到队尾」）
private struct QueueIsland: View {
    @EnvironmentObject private var player: PlayerEngine

    /// 头部 36、最多 8 行、至少 112、上下边框 2
    private static let headerHeight: CGFloat = 36
    private static let maxVisibleRows = 8
    private static let minHeight: CGFloat = 112
    private static let borderHeight: CGFloat = 2
    private static let rowHeight: CGFloat = 40
    /// 清空两步确认窗口 / 进入确认态后的保护期
    private static let clearConfirmWindow: Double = 3.0
    private static let clearConfirmGuard: Double = 0.4

    @State private var clearPending = false
    @State private var clearPendingSince = Date()
    @State private var clearResetTask: Task<Void, Never>?

    private var theme: WallTheme { .midnight }
    private var ink: Color { theme.ink }
    private var accent: Color { theme.accent }

    private var songs: [Song] { player.queue }

    private var islandHeight: CGFloat {
        max(
            Self.minHeight,
            Self.borderHeight + Self.headerHeight
                + CGFloat(min(songs.count, Self.maxVisibleRows)) * Self.rowHeight
        )
    }

    /// 正在播的那一行（当前曲目）
    private var currentKey: String? {
        player.currentSong.map { WallTile.key(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .frame(width: 296, height: islandHeight, alignment: .top)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.40))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.42), radius: 32, x: 0, y: 24)
        .onDisappear { cancelClearPending() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 4) {
            Text("播放队列 · \(songs.count) 首")
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.72)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if songs.count > 0 {
                Button(action: handleClear) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .regular))
                        if clearPending {
                            Text("再点一次清空")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(clearPending ? FoliaTheme.background : ink)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(clearPending ? accent : Color.clear)
                    )
                    .opacity(clearPending ? 1 : 0.72)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: clearPending ? 296 * 0.7 : nil, alignment: .trailing)
                .accessibilityLabel(clearPending ? "再点一次清空" : "清空队列")
            }
        }
        .foregroundStyle(ink)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: Self.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    /// 两步确认：3 秒内再点才清空；刚进入确认态 400ms 内的连点不算
    private func handleClear() {
        if clearPending {
            guard Date().timeIntervalSince(clearPendingSince) >= Self.clearConfirmGuard else { return }
            cancelClearPending()
            player.clearQueue()
            return
        }
        clearPendingSince = Date()
        withAnimation(.easeOut(duration: 0.16)) { clearPending = true }
        clearResetTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.clearConfirmWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.16)) { clearPending = false }
            }
        }
    }

    private func cancelClearPending() {
        clearResetTask?.cancel()
        clearResetTask = nil
        clearPending = false
    }

    // MARK: - 列表（`padding 0 4`）

    private var list: some View {
        ZStack {
            if songs.isEmpty {
                // `.lattice-tools-island-empty`：居中、12px、0.45
                Text("队列是空的")
                    .font(.system(size: 12))
                    .opacity(0.45)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                            QueueIslandRow(
                                song: song,
                                index: index,
                                isCurrent: currentKey == WallTile.key(for: song),
                                onPlay: { player.play(at: index) },
                                onPlayNext: { player.playNext(at: index) },
                                onMoveToEnd: { player.moveToEnd(at: index) },
                                onRemove: { player.remove(at: index) }
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 浮岛的一行

/// `.lattice-tools-island-row`：40 高、`padding 2 4 2 0`、r10；当前行 10% 底。
/// 触屏没有 hover，动作钮常显（原版悬停才出现）。
private struct QueueIslandRow: View {
    @EnvironmentObject private var player: PlayerEngine

    let song: Song
    let index: Int
    let isCurrent: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onMoveToEnd: () -> Void
    let onRemove: () -> Void

    private var theme: WallTheme { .midnight }
    private var ink: Color { theme.ink }
    /// `isSongUnavailable`：不可播放（VIP / 无版权 / 试听外）
    private var available: Bool { song.isPlayable }
    private var currentKey: String { WallTile.key(for: song) }
    /// 正在播的那一行：显示的那首或内部 currentSong，都不给「移除」与「下一首播放」
    private var isPlayingRow: Bool {
        currentKey == player.currentSong.map { WallTile.key(for: $0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ink)
                .frame(width: 18, height: 32)
                .opacity(0.4)

            Button(action: onPlay) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isCurrent ? theme.accent : Color.clear)
                        .frame(width: 3, height: 18)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(song.name)
                                .font(.system(size: 12.5, weight: isCurrent ? .bold : .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if !available {
                                Text("不可用")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .frame(height: 15)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                                            .strokeBorder(ink, lineWidth: 1)
                                    )
                                    .opacity(0.6)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(song.artistNames)
                            .font(.system(size: 10.5))
                            .opacity(0.52)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(ink)
                    // `.lattice-tools-island-row.is-unavailable .lattice-tools-island-text { opacity: .55 }`
                    .opacity(available ? 1 : 0.55)
                }
                .padding(.leading, 2)
                .padding(.trailing, 6)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                if isPlayingRow {
                    rowAction(icon: "text.append", label: "移到队尾", action: onMoveToEnd)
                } else {
                    rowAction(icon: "text.badge.plus", label: "下一首播放", action: onPlayNext)
                    rowAction(icon: "text.append", label: "移到队尾", action: onMoveToEnd)
                    rowAction(icon: "trash", label: "从队列中删除", action: onRemove)
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
        .padding(.trailing, 4)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isCurrent ? 0.10 : 0))
        )
    }

    private func rowAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(ink)
                .opacity(0.7)
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
