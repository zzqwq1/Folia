import SwiftUI

/// 播放面板：复刻原版 Web 的 UnifiedPanel（src/components/UnifiedPanel.tsx 及 panelTab/shell 家族）。
///
/// 层级：玻璃外壳（20pt 圆角 / 12pt 内边距）→ 歌曲头部（大封面 + 歌名/歌手/专辑 + 操作行）
/// → 1px 分隔线 → tab 内容 → 36pt 分段 Dock → 右下 48pt 圆形关闭把手（外壳底部预留 60pt）。
/// 像素值取自原版 Tailwind 类与 panelTheme / kitTheme 的 CSS 变量；
/// 原版面板没有 `@media (max-width:640px)` 分支（固定 `w-[360px] max-w-[calc(100vw-2rem)]`），
/// 手机竖屏唯一差别就是这层宽度约束，所以宽屏也走同一套数值。
struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var covers: WallCoverLoader
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .cover
    @State private var lyrics: [LyricLine] = []
    /// 拖动进度条时只改本地值（原版 Kit Slider 是先动后提交）
    @State private var scrub: Double?
    /// 由外壳实测的可滚动内容高度（原版 `--pn-room`）
    @State private var tabRoom: CGFloat = 0
    /// 下拉关闭的位移
    @State private var dragOffset: CGFloat = 0
    @State private var appeared = false

    enum Tab: String, CaseIterable, Identifiable {
        case cover = "封面"
        case controls = "播放"
        case queue = "队列"
        case lyrics = "歌词"

        var id: String { rawValue }

        /// 原版 tab 图标（lucide Disc / SlidersHorizontal / ListMusic / FileText）
        var icon: String {
            switch self {
            case .cover: return "opticaldisc"
            case .controls: return "slider.horizontal.3"
            case .queue: return "music.note.list"
            case .lyrics: return "text.alignleft"
            }
        }
    }

    // MARK: - 原版常量

    /// PanelShell / SongHeader / QueueTab 的像素常量
    private enum M {
        static let padding: CGFloat = 12          // PanelShell PADDING_PX
        static let corner: CGFloat = 20           // rounded-[20px]
        static let handleRoom: CGFloat = 60       // HANDLE_ROOM_PX
        static let dockHeight: CGFloat = 36       // DOCK_HEIGHT_PX
        static let dockGap: CGFloat = 12          // DOCK_GAP_PX
        static let bodyGap: CGFloat = 12          // BODY_TOP_PX.gap
        static let hairline: CGFloat = 1          // BODY_TOP_PX.line
        static let bodyUnder: CGFloat = 8         // BODY_TOP_PX.under
        static let folded: CGFloat = 48           // FOLDED_PX
        static let coverGap: CGFloat = 14         // COVER_GAP_PX
        static let minCover: CGFloat = 96         // MIN_COVER_PX
        static let queueRow: CGFloat = 48         // ROW_PX
        static let queueHead: CGFloat = 36        // HEAD_PX
        static let queueMaxRows: CGFloat = 7.5    // LIST_MAX_PX
        static let fade: CGFloat = 32             // FADE
        /// 封面下方文字块高度：26（标题）+ 2 + 20（歌手）+ 18（专辑）+ 14 + 32（操作行）
        static let coverUnder: CGFloat = 112
        /// 原版 `w-[360px] max-w-[calc(100vw-2rem)]`
        static let maxWidth: CGFloat = 360
        /// 手机竖屏两侧留白（原版 max-w 的 2rem 语义）
        static let sideInset: CGFloat = 16
    }

    /// 与原版 CSS 变量一一对应（panelTheme.ts 的 --pn-*，kitTheme.ts 的 --st-*）
    private enum C {
        static let t1 = FoliaTheme.text
        static let t2 = FoliaTheme.text.opacity(0.62)
        static let t3 = FoliaTheme.text.opacity(0.42)
        static let line = FoliaTheme.text.opacity(0.08)
        static let fill = FoliaTheme.text.opacity(0.07)
        static let track = FoliaTheme.text.opacity(0.17)
        /// 暗色主题才有的 --st-raise
        static let raise = Color.white.opacity(0.18)
        static let accent = WallTheme.midnight.accent
        /// --pn-glass 暗色：rgba(28,28,31,0.8)
        static let glass = Color(hex: 0x1C1C1F).opacity(0.8)
        /// --pn-shadow 里的 1px 白描边
        static let glassEdge = Color.white.opacity(0.09)
    }

    private var song: Song? { player.currentSong }

    // MARK: - 主体

    var body: some View {
        GeometryReader { geo in
            let shellBottom = shellBottomInset(geo.safeAreaInsets)
            let shellHeight = max(geo.size.height - shellBottom - shellTopGap(geo.safeAreaInsets), 200)

            // 先算尺寸再进 ZStack：避免在容器里写 let 造成类型推断歧义
            layout(available: geo.size, safeArea: geo.safeAreaInsets, shellBottom: shellBottom, shellHeight: shellHeight)
                .onAppear {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)) { appeared = true }
                }
        }
        .background(WallTheme.midnight.bg.ignoresSafeArea())
        .task(id: song?.id) {
            guard let id = song?.id else {
                lyrics = []
                return
            }
            lyrics = (try? await NeteaseAPI.shared.lyrics(songId: id)) ?? []
        }
    }

    /// 外壳底边到屏幕底部的距离：安全区 + 60pt 把手预留 + 8pt 余量
    private func shellBottomInset(_ safeArea: EdgeInsets) -> CGFloat {
        max(safeArea.bottom, 0) + M.handleRoom + 8
    }

    /// 外壳顶边到屏幕顶部的距离：安全区 + 48pt（原版 TOP_MARGIN 56 在手机上去掉系统状态栏部分）
    private func shellTopGap(_ safeArea: EdgeInsets) -> CGFloat {
        max(safeArea.top, 0) + 48
    }

    private func layout(available: CGSize, safeArea: EdgeInsets, shellBottom: CGFloat, shellHeight: CGFloat) -> some View {
        let width = min(available.width - 2 * M.sideInset, M.maxWidth)
        let topStrip: CGFloat = max(safeArea.top, 24)
        return ZStack(alignment: .bottomTrailing) {
            WallBackdrop(theme: .midnight, hasVignette: true)

            // 顶部下滑关闭的手势区，只占最上面一条，不挡面板操作
            VStack(spacing: 0) {
                dragToDismiss
                    .frame(height: topStrip)
                Spacer(minLength: 0)
            }

            surface(width: width, height: shellHeight)
                .padding(.trailing, M.sideInset)
                .padding(.bottom, shellBottom + dragOffset)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.92, anchor: .bottomTrailing)

            handle
                .padding(.trailing, M.sideInset + 4)
                .padding(.bottom, max(safeArea.bottom, 12) + dragOffset)
                .opacity(appeared ? 1 : 0)
                .offset(x: appeared ? 0 : 20, y: appeared ? 0 : 12)
        }
    }

    // MARK: - 外壳（PanelShell）

    private func surface(width: CGFloat, height: CGFloat) -> some View {
        // 内容区可用高度：--pn-room = 外壳高 - 2*12(内边距) - 12(dock 间距) - 36(dock)
        let room = max(height - 2 * M.padding - M.dockGap - M.dockHeight, M.minCover)
        let showsBody = tab != .cover
        return VStack(alignment: .leading, spacing: 0) {
            header(room: room)
                .background(
                    // 量出头部高度，供队列 / 歌词夹住自身的滚动区
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { tabRoom = proxy.size.height }
                            .onChange(of: proxy.size.height) { value in tabRoom = value }
                    }
                )

            Group {
                if showsBody {
                    Rectangle()
                        .fill(C.line)
                        .frame(height: M.hairline)
                        .padding(.top, M.bodyGap)
                        .padding(.bottom, M.bodyUnder)

                    tabBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            dock
                .frame(height: M.dockHeight)
                .padding(.top, M.dockGap)
        }
        .padding(M.padding)
        .frame(width: width, height: height)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: M.corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: M.corner, style: .continuous)
                    .fill(C.glass)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: M.corner, style: .continuous)
                .strokeBorder(C.glassEdge, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: M.corner, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 40, x: 0, y: 15)
    }

    // MARK: - 歌曲头部（SongHeader）

    @ViewBuilder
    private func header(room: CGFloat) -> some View {
        if tab == .cover {
            // 封面高 = clamp(96, room - 下方文字块, 可用宽)
            let coverHeight = min(max(room - M.coverUnder - M.coverGap, M.minCover), room)
            VStack(alignment: .leading, spacing: 0) {
                coverSquare(size: coverHeight)
                credits
                    .padding(.top, M.coverGap)
            }
        } else {
            HStack(spacing: 12) {
                coverSquare(size: M.folded, corner: 8, iconSize: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song?.name ?? "未在播放")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(C.t1)
                        .lineLimit(1)
                        .frame(height: 20)
                    Text(song?.artistNames ?? " ")
                        .font(.system(size: 12))
                        .foregroundStyle(C.t2)
                        .lineLimit(1)
                        .frame(height: 18)
                }
                Spacer(minLength: 0)
            }
            .frame(height: M.folded)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(panelAnimation) { tab = .cover } }
        }
    }

    /// 封面：`bg-[var(--st-fill)]` + `rounded-[10px]` + 内嵌 1px 描边；无图时 Disc
    private func coverSquare(size: CGFloat, corner: CGFloat = 10, iconSize: CGFloat = 40) -> some View {
        ZStack {
            C.fill
            coverImage(iconSize: iconSize)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(C.line, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    /// 封面优先走进程内缓存（原版 512 档），未命中退回 AsyncImage
    @ViewBuilder
    private func coverImage(iconSize: CGFloat) -> some View {
        if let cached = covers.image(for: song?.album.coverUrl, tier: .medium) {
            Image(uiImage: cached)
                .resizable()
                .scaledToFill()
        } else if let url = WallCoverLoader.resized(song?.album.coverUrl, tier: .medium) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    discPlaceholder(iconSize: iconSize)
                }
            }
            .onAppear { covers.load(song?.album.coverUrl, tier: .medium) }
        } else {
            discPlaceholder(iconSize: iconSize)
        }
    }

    private func discPlaceholder(iconSize: CGFloat) -> some View {
        Image(systemName: "opticaldisc")
            .font(.system(size: iconSize))
            .foregroundStyle(C.t3)
    }

    /// SongCredits：18pt/26 semibold 两行、13pt/20 --st-t2、12pt/18 --st-t3、操作行 mt-14
    private var credits: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(song?.name ?? "未在播放")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(C.t1)
                .lineLimit(2)
                .frame(height: 52, alignment: .top)
            Text(song?.artistNames ?? " ")
                .font(.system(size: 13))
                .foregroundStyle(C.t2)
                .lineLimit(1)
                .frame(height: 20, alignment: .top)
                .padding(.top, 2)
            Text(song?.album.name ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(C.t3)
                .lineLimit(1)
                .frame(height: 18, alignment: .top)
            actionsRow
                .padding(.top, 14)
        }
    }

    /// SongActions：gap-1.5，按钮 32×32 / 圆角 8
    private var actionsRow: some View {
        HStack(spacing: 6) {
            PanelIconButton(icon: "shuffle", label: "随机播放", active: player.isShuffleEnabled) {
                player.isShuffleEnabled.toggle()
            }
            PanelIconButton(icon: "backward.fill", label: "上一首") {
                player.previous()
            }
            PanelIconButton(icon: "forward.fill", label: "下一首") {
                player.next()
            }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
    }

    // MARK: - tab 内容

    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .cover:
            EmptyView()
        case .controls:
            playbackTab
        case .lyrics:
            lyricsTab
        case .queue:
            queueTab
        }
    }

    /// 播放 tab：原版 ControlsTab 只有音量 + 快捷开关，没有进度与传输键；
    /// 这里保留工程要求的功能，尺寸沿用 kit 的 Slider / QuickTile 词表 + 48pt 圆形播放键。
    private var playbackTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(Song.formatDuration(scrub ?? player.currentTime))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(C.t1)
                Spacer(minLength: 0)
                Text(Song.formatDuration(max(player.duration, 0)))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(C.t3)
            }
            SeekBar(
                value: player.currentTime,
                duration: max(player.duration, 1),
                onChange: { scrub = $0 },
                onCommit: { value in
                    player.seek(to: value)
                    scrub = nil
                }
            )
            .padding(.top, 8)

            HStack(spacing: 10) {
                PanelIconButton(icon: "shuffle", label: "随机播放", active: player.isShuffleEnabled) {
                    player.isShuffleEnabled.toggle()
                }
                PanelIconButton(icon: "backward.fill", label: "上一首") {
                    player.previous()
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: playingIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(WallTheme.midnight.bg)
                        .frame(width: 48, height: 48)
                        .background(WallTheme.midnight.accent, in: Circle())
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(WallBackButtonStyle())
                .disabled(song == nil)
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                PanelIconButton(icon: "forward.fill", label: "下一首") {
                    player.next()
                }
                PanelIconButton(icon: repeatIcon, label: "循环模式", active: player.repeatMode != .off) {
                    cycleRepeat()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)

            if player.isPreview {
                Text("仅可试听片段")
                    .font(.system(size: 12))
                    .foregroundStyle(C.t3)
                    .padding(.top, 10)
            }
            if let message = player.errorMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(C.t2)
                    .lineLimit(2)
                    .padding(.top, 10)
            }
            if !player.contextName.isEmpty {
                Text("来自 \(player.contextName)")
                    .font(.system(size: 12))
                    .foregroundStyle(C.t3)
                    .lineLimit(1)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
    }

    /// 歌词：当前行高亮 + 自动居中，上下两端渐隐
    private var lyricsTab: some View {
        Group {
            if lyrics.isEmpty {
                EmptyState(icon: "text.alignleft", text: "这首歌还没有歌词")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                                lyricLine(text: line.text, active: index == activeIndex)
                                    .id(index)
                            }
                        }
                        // 半屏留白，保证第一行 / 最后一行也能滚到正中
                        .padding(.vertical, max(tabRoom / 2, 0))
                    }
                    .mask(lyricsMask)
                    .onChange(of: activeIndex) { index in
                        guard let index else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricLine(text: String, active: Bool) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 15, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? C.t1 : C.t2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
    }

    private var lyricsMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.1),
                .init(color: .black, location: 0.9),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 队列：36pt 头行 + 最多 7.5 行的滚动列表，底部 32pt 渐隐
    private var queueTab: some View {
        Group {
            if player.queue.isEmpty {
                EmptyState(icon: "music.note.list", text: "队列是空的，挑一首歌开始播放")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("播放队列")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(C.t2)
                        Text("\(player.queue.count)")
                            .font(.system(size: 13))
                            .foregroundStyle(C.t3)
                            .padding(.leading, 6)
                        Spacer(minLength: 0)
                        PanelIconButton(
                            icon: "shuffle",
                            label: "随机播放",
                            size: 28,
                            iconSize: 15,
                            active: player.isShuffleEnabled
                        ) {
                            player.isShuffleEnabled.toggle()
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.bottom, 4)
                    .frame(height: M.queueHead)

                    queueList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 列表高 = clamp(0, tabRoom - 36, min(行数, 7.5 行) * 48)
    private var queueListHeight: CGFloat {
        let rows = max(min(CGFloat(player.queue.count), M.queueMaxRows), 1) * M.queueRow
        return min(max(tabRoom - M.queueHead, 0), rows)
    }

    @ViewBuilder
    private var queueList: some View {
        let height = queueListHeight
        let fadeNeeded = CGFloat(player.queue.count) * M.queueRow > height + 4
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, item in
                        QueueRow(
                            song: item,
                            isActive: index == player.currentIndex,
                            duration: player.duration,
                            onPlay: { player.play(at: index) },
                            onRemove: { player.remove(at: index) }
                        )
                        .frame(height: M.queueRow)
                        .id(index)
                    }
                }
            }
            .frame(height: height)
            .mask(
                Group {
                    if fadeNeeded {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: max(0, 1 - M.fade / max(height, 1))),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        Color.black
                    }
                }
            )
            .onChange(of: player.currentIndex) { index in
                guard index >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(max(index - 1, 0), anchor: .top)
                }
            }
        }
    }

    // MARK: - 分段 Dock（TabDock = Segments size l / fill）

    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                let selected = item == tab
                Button {
                    guard !selected else { return }
                    withAnimation(panelAnimation) { tab = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 16))
                        Text(item.rawValue)
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selected ? C.t1 : C.t2)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Group {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(C.raise)
                                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
            }
        }
        .padding(2)
        .background(C.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 把手（PanelHandle：48pt 圆，打开时白底黑 X）

    private var handle: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.black)
                .frame(width: 48, height: 48)
                .background(Color.white, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 8)
                .contentShape(Circle())
        }
        .buttonStyle(WallBackButtonStyle())
        .accessibilityLabel("关闭播放面板")
    }

    /// 顶部下滑关闭：sheet 里没有系统下拉把手，补一条与拖拽方向一致的滑区
    private var dragToDismiss: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dismissDrag)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 80 || value.predictedEndTranslation.height > 160 {
                    dragOffset = 0
                    dismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                }
            }
    }

    // MARK: - 辅助

    private var panelAnimation: Animation { .timingCurve(0.22, 1, 0.36, 1, duration: 0.22) }

    private var playingIcon: String { player.isPlaying ? "pause.fill" : "play.fill" }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    private var activeIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        var result: Int?
        for (index, line) in lyrics.enumerated() where line.start <= player.currentTime + 0.15 {
            result = index
        }
        return result
    }
}

// MARK: - 面板图标按钮（PanelIconButton：m = 32×32 / s = 28×28，圆角 8，底 --st-fill）

private struct PanelIconButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 32
    var iconSize: CGFloat = 17
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(active ? FoliaTheme.text : FoliaTheme.text.opacity(0.62))
                .frame(width: size, height: size)
                .background(
                    FoliaTheme.text.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityLabel(label)
    }
}

/// 原版 `--st-t-fast`（0.12s）+ `active:scale-[0.96]`
private struct PanelPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 进度条（kit Slider：h-1 轨道、16pt 白 thumb）

private struct SeekBar: View {
    let value: Double
    let duration: Double
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var dragging = false
    @State private var localValue: Double = 0

    private var fraction: Double {
        let shown = dragging ? localValue : value
        guard duration > 0 else { return 0 }
        return min(max(shown / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(FoliaTheme.text.opacity(0.17))
                    .frame(height: 4)
                Capsule()
                    .fill(WallTheme.midnight.accent)
                    .frame(width: width * fraction, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.14), radius: 0, x: 0, y: 0)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                    .offset(x: width * fraction - 8)
            }
            .frame(width: width, height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        localValue = min(max(gesture.location.x / width, 0), 1) * duration
                        onChange(localValue)
                    }
                    .onEnded { gesture in
                        let target = min(max(gesture.location.x / width, 0), 1) * duration
                        dragging = false
                        onCommit(target)
                    }
            )
        }
        .frame(height: 20)
    }
}

// MARK: - 队列行（QueueTab：48pt，激活 7% 底 + 左侧 3pt 强调条）

private struct QueueRow: View {
    let song: Song
    let isActive: Bool
    let duration: Double
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(song.name)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(FoliaTheme.text)
                        .lineLimit(1)
                    if isActive {
                        Text(Song.formatDuration(max(duration, 0)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(FoliaTheme.text.opacity(0.42))
                    }
                }
                .frame(height: 19)
                Text(song.artistNames)
                    .font(.system(size: 12))
                    .foregroundStyle(FoliaTheme.text.opacity(0.42))
                    .lineLimit(1)
                    .frame(height: 17)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FoliaTheme.text.opacity(0.42))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelPressStyle())
            .accessibilityLabel("从队列移除")
        }
        .opacity(song.isPlayable ? 1 : 0.55)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? FoliaTheme.text.opacity(0.07) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isActive {
                // 只在上下 14pt 之间露出的 3pt 竖条，圆角用 4pt 连续圆近似 rounded-r-sm
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(WallTheme.midnight.accent)
                    .frame(width: 3)
                    .padding(.vertical, 14)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
    }
}

// MARK: - 空状态（EmptyState：min-h 180、图标 28、13pt --st-t2）

private struct EmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(FoliaTheme.text.opacity(0.42))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(FoliaTheme.text.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 264)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
    }
}
