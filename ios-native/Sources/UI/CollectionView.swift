import SwiftUI

/// 集合页（歌单 / 专辑）：逐条移植桌面端 `GridView.tsx` 的 `mode="tracks"`（`GridCollectionSurface`）。
///
/// 结构（原版类名 → Swift）：
/// - 整页 `fixed inset-0 z-[110]`，背景是低清封面 `opacity 0.12` + `blur(30px)` + `scale(1.1)`
/// - 左上 `.lattice-back` 式的 40×40 玻璃圆返回钮（`left-6 top-5`）
/// - 中上标题块：`px-5 py-2 rounded-2xl`、底 `color-mix(bg 20%)` + `backdrop-blur-md`，
///   标题 `text-lg font-bold`，副标题 `text-xs opacity-50 line-clamp-2`；点它开合切入信息面板
/// - 切入信息面板（`showCutInPanel`）：`left-6 top-24 w-80 rounded-3xl p-6`，
///   封面 `aspect-square rounded-2xl mb-4`、标题 `text-xl font-bold`、创作者、曲数/播放数、
///   描述 `text-xs opacity-65 max-h-40`，按钮区 `mt-4 pt-4 border-t`：「播放全部」+「全部加入队列」
/// - 右下 `GridListSearchButton`（48 圆、黑 40% + blur）+ 上方 `GridLocateButton`（40 圆）
/// - 右侧 `SidePanelList`：`right-6 top-24 w-80 rounded-3xl p-6`，行高 60 的 `TrackListItem`
///
/// 曲面网格用手机档卡盒（`resolveGridViewCardBox` 的 `<768` 分支）：180×280、间距 205×270。
struct CollectionView: View {
    @EnvironmentObject private var player: PlayerEngine
    let collection: MusicCollection
    /// 与首页墙面同一份墙数据：定位按钮在墙上把正在播的那首找出来
    let wallItems: [WallItem]
    let onLocate: (String) -> Void
    let onDismiss: () -> Void

    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var showInfo = false
    @State private var showList = false
    @State private var appeared = false
    @State private var locatePresses = 0

    private var theme: WallTheme { .midnight }
    private var ink: Color { theme.ink }

    /// 标题块副标题：原版 `subtitle = creator?.nickname || artists?.[0]?.name || description`
    private var subtitle: String {
        collection.creatorName ?? collection.description ?? ""
    }

    private var playCountLine: String {
        let count = collection.trackCount ?? songs.count
        return "\(count) 首"
    }

    private var currentSongKey: String? {
        player.currentSong.map { WallTile.key(for: $0) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            FoliaTheme.background.ignoresSafeArea()

            backdrop

            if isLoading {
                ProgressView()
                    .tint(ink.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                Text("这个集合里没有可播放的歌曲")
                    .font(.system(size: 14))
                    .opacity(0.4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            backButton
            titleBlock

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: 0)
                    bottomTrailingCluster
                }
                .padding(.bottom, 16)
            }

            if showInfo { infoPanel }
            if showList { sidePanel }
        }
        .ignoresSafeArea()
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.24)) { appeared = true }
        }
        .task { await load() }
    }

    // MARK: - 背景（低清封面 12% + blur 30 + scale 1.1）

    private var backdrop: some View {
        GeometryReader { geo in
            AsyncImage(url: collection.cover(size: 120)) { phase in
                ZStack {
                    FoliaTheme.background
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 30)
                            .scaleEffect(1.1)
                    }
                }
            }
            .opacity(0.12)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 返回钮（`.lattice-back` 尺寸、`left-6 top-5`）

    private var backButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().fill(Color.white.opacity(0.08)))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.24), radius: 15, x: 0, y: 10)
                .contentShape(Circle())
        }
        .buttonStyle(WallBackButtonStyle())
        .padding(.leading, 20)
        .padding(.top, 16)
        .zIndex(5)
    }

    // MARK: - 中上标题块

    private var titleBlock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    guard !songs.isEmpty else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        showInfo.toggle()
                    }
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Text(collection.name)
                                .font(.system(size: 18, weight: .bold))
                                .tracking(-0.2)
                                .lineLimit(1)
                            Image(systemName: showInfo ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .opacity(0.4)
                        }
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .opacity(0.5)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(FoliaTheme.background.opacity(0.20))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .zIndex(4)
    }

    // MARK: - 右下：列表按钮 + 定位按钮

    private var bottomTrailingCluster: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if let key = currentSongKey, !songs.isEmpty {
                Button(action: locatePlaying) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().fill(Color.black.opacity(0.40)))
                        Image(systemName: "scope")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isPlayingHere ? theme.accent : ink)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.24), radius: 12, x: 0, y: 8)
                    .contentShape(Circle())
                }
                .buttonStyle(GridActionButtonStyle())
                .scaleEffect(locatePresses == 0 ? 1 : 1.16)
                .animation(
                    locatePresses == 0
                        ? .spring(response: 0.26, dampingFraction: 0.6)
                        : .easeOut(duration: 0.14),
                    value: locatePresses
                )
                .accessibilityLabel("定位正在播放")
                .id(key)
            }

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    showList.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.black.opacity(0.40)))
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(ink)
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 18)
                .contentShape(Circle())
            }
            .buttonStyle(GridActionButtonStyle())
            .accessibilityLabel("查看曲目列表")
        }
        .padding(.trailing, 20)
        .zIndex(6)
    }

    private var isPlayingHere: Bool {
        guard let key = currentSongKey else { return false }
        return wallItems.contains { $0.id == key }
    }

    private func locatePlaying() {
        guard let key = currentSongKey else { return }
        locatePresses += 1
        onLocate(key)
    }

    // MARK: - 切入信息面板（`left-6 top-24 w-80 rounded-3xl p-6`）

    private var infoPanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    cover
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
                        .padding(.bottom, 16)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(collection.name)
                                    .font(.system(size: 20, weight: .bold))
                                    .lineLimit(2)
                                    .foregroundStyle(ink)
                                if let creator = collection.creatorName, !creator.isEmpty {
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .font(.system(size: 20))
                                            .opacity(0.6)
                                        Text(creator)
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .opacity(0.6)
                                    .foregroundStyle(ink)
                                    .padding(.top, 8)
                                }
                                Text(playCountLine)
                                    .font(.system(size: 10))
                                    .opacity(0.4)
                                    .foregroundStyle(ink)
                                    .padding(.top, 6)
                            }

                            if let description = collection.description, !description.isEmpty {
                                Text(description)
                                    .font(.system(size: 12))
                                    .opacity(0.65)
                                    .lineSpacing(3)
                                    .foregroundStyle(ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    buttons
                }
                .padding(24)
                .frame(width: 320)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 8)
                .padding(.leading, 20)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 72)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(x: -60)).combined(with: .scale(scale: 0.95, anchor: .leading)),
            removal: .opacity.combined(with: .offset(x: -60)).combined(with: .scale(scale: 0.95, anchor: .leading))
        ))
        .zIndex(8)
    }

    @ViewBuilder
    private var cover: some View {
        AsyncImage(url: collection.cover(size: 512)) { phase in
            ZStack {
                Color.white.opacity(0.06)
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 64))
                        .opacity(0.2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 按钮区：`mt-4 pt-4 border-t`，「播放全部」实心 + 「全部加入队列」10% 底
    private var buttons: some View {
        VStack(spacing: 8) {
            Button(action: playAll) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("播放全部")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(FoliaTheme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(ink, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(songs.isEmpty)
            .opacity(songs.isEmpty ? 0.4 : 1)

            Button(action: addAllToQueue) {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                    Text("全部加入队列")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(ink.opacity(0.10), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(songs.isEmpty)
            .opacity(songs.isEmpty ? 0.4 : 1)
        }
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ink.opacity(0.12))
                .frame(height: 1)
        }
    }

    // MARK: - 右侧曲目面板（`SidePanelList`）

    private var sidePanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(collection.name)
                            .font(.system(size: 18, weight: .bold))
                            .tracking(-0.2)
                            .lineLimit(1)
                            .foregroundStyle(ink)
                        Spacer(minLength: 0)
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                showList = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(ink)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SidePanelCloseStyle())
                        .accessibilityLabel("关闭曲目列表")
                    }
                    .padding(.bottom, 16)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                                TrackListRow(
                                    song: song,
                                    index: index,
                                    isActive: currentSongKey == WallTile.key(for: song),
                                    onPlay: { player.play(songs, startIndex: index, contextName: collection.name) },
                                    onAddToQueue: { player.addToQueue([song]) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(24)
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 8)
                .padding(.trailing, 20)
            }
            .padding(.bottom, 16)
        }
        .padding(.top, 72)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(x: 60)).combined(with: .scale(scale: 0.95, anchor: .trailing)),
            removal: .opacity.combined(with: .offset(x: 60)).combined(with: .scale(scale: 0.95, anchor: .trailing))
        ))
        .zIndex(8)
    }

    // MARK: - 播放动作

    private func playAll() {
        guard !songs.isEmpty else { return }
        player.play(songs, startIndex: 0, contextName: collection.name)
    }

    private func addAllToQueue() {
        guard !songs.isEmpty else { return }
        player.addToQueue(songs)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch collection.kind {
        case .album:
            songs = (try? await NeteaseAPI.shared.album(id: collection.id))?.songs ?? []
        default:
            songs = (try? await NeteaseAPI.shared.playlistTracks(id: collection.id)) ?? []
        }
    }
}

// MARK: - 面板里的一行（`TrackListItem`，itemHeight 60）
//
// `px-2 py-1` 外层、内层 `flex items-center gap-3 p-2 rounded-lg`、封面 40 圆角 4、
// 标题 14/600 + 音轨号 10/0.45、歌手 10/0.6、悬停右侧 + 号。
private struct TrackListRow: View {
    let song: Song
    let index: Int
    let isActive: Bool
    let onPlay: () -> Void
    let onAddToQueue: () -> Void

    @State private var isPressed = false

    private var available: Bool { song.isPlayable }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                AsyncImage(url: song.album.cover(size: 100)) { phase in
                    ZStack {
                        Color.white.opacity(0.07)
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        }
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                if isPressed, available {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.black.opacity(0.40))
                        .frame(width: 40, height: 40)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(song.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .opacity(0.45)
                }
                Text(song.artistNames)
                    .font(.system(size: 10))
                    .opacity(0.60)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, alignment: .leading)

            if available {
                Button(action: onAddToQueue) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(FoliaTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(Color.white.opacity(isPressed ? 0.10 : 0))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("加入队列")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isActive ? 0.10 : (isPressed ? 0.05 : 0)))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 60)
        .opacity(available ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard available else { return }
            onPlay()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - 按钮样式

/// `hover:scale-105 active:scale-95`（150~200ms）
struct GridActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// `hover:scale-102 active:scale-98`
private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// `p-1.5 rounded-full hover:bg-white/10`
private struct SidePanelCloseStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0))
            )
    }
}
