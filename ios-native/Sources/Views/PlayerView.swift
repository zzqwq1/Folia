import SwiftUI

/// 全屏播放页：对齐桌面 1.8.5 播放界面 ——
/// VisualizerShell 全屏壳（左上 40×40 圆形返回钮 + 封面模糊背景换色 1s）
/// + 中央歌词滚动（无歌词时对齐 SongHeader 的大封面）
/// + 底部悬浮玻璃胶囊控制栏（对齐 FloatingPlayerControls 展开态 + ProgressBar）。
struct PlayerView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var player: PlayerModel

    @State private var lyricLines: [LyricLine] = []
    @State private var scrubActive = false
    @State private var scrubValue: Double = 0

    var body: some View {
        Group {
            if let track = player.current {
                content(track: track)
            } else {
                ZStack {
                    FoliaTheme.bg.ignoresSafeArea()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Content

    private func content(track: Track) -> some View {
        ZStack {
            // 背景：封面超大模糊 + 暗色（对齐 VisualizerShell 的换色 1s 过渡）
            if let url = track.coverUrl, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    }
                }
                .blur(radius: 80)
                .opacity(0.35)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1.0), value: track.id)
            }
            FoliaTheme.bg.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 0) {
                // 左上 40×40 圆形返回钮（对齐 VisualizerShell）
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(FoliaTheme.t1)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.2), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer()

                centerContent(track: track)

                Spacer()

                controlsCapsule(track: track)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
            }
        }
        .task(id: track.id) { await loadLyrics(id: track.id) }
    }

    // MARK: - 中央：歌词滚动 / 大封面

    private func centerContent(track: Track) -> some View {
        Group {
            if lyricLines.isEmpty {
                // 无歌词：大封面 + 信息（对齐 SongHeader 大封面形态）
                VStack(spacing: 0) {
                    AsyncImage(url: URL(string: track.coverUrl ?? "")) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default:
                            ZStack {
                                FoliaTheme.fill
                                Image(systemName: "opticaldisc")
                                    .font(.system(size: 64))
                                    .foregroundStyle(FoliaTheme.t3)
                            }
                        }
                    }
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(FoliaTheme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 32, y: 16)
                    .padding(.bottom, 28)

                    VStack(spacing: 6) {
                        Text(track.title)
                            .font(FoliaFont.serif(26, .bold))
                            .foregroundStyle(FoliaTheme.t1)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(track.artist)
                            .font(FoliaFont.sans(14))
                            .foregroundStyle(FoliaTheme.t2)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 32)
                }
            } else {
                lyricScroll
            }
        }
        .animation(.easeInOut(duration: 0.3), value: lyricLines.isEmpty)
    }

    // MARK: - 歌词滚动（对齐 VisualizerSubtitleOverlay：主行 + 翻译 + 辉光感）

    private var lyricScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    // 上下留白，保证第一行 / 最后一行也能滚到中央
                    Color.clear.frame(height: 200)
                    ForEach(Array(lyricLines.enumerated()), id: \.element.id) { index, line in
                        LyricRow(line: line, isCurrent: index == currentLineIndex)
                            .id(index)
                    }
                    Color.clear.frame(height: 200)
                }
            }
            .frame(maxHeight: 340)
            .onChange(of: currentLineIndex) { newIndex in
                guard newIndex >= 0, newIndex < lyricLines.count else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    /// 当前时间命中的歌词行下标。
    private var currentLineIndex: Int {
        guard !lyricLines.isEmpty else { return -1 }
        var idx = 0
        for i in 0..<lyricLines.count {
            if lyricLines[i].time <= player.currentTime { idx = i } else { break }
        }
        return idx
    }

    private func loadLyrics(id: String) async {
        guard player.current?.provider == .netease else { return }
        do {
            let result = try await FoliaAPI.neteaseLyric(id: id)
            let merged = LyricParser.merge(main: result.lrc ?? "", translation: result.tlyric)
            // 纯伴奏/无正文歌词 → 空数组走大封面
            lyricLines = merged
        } catch {
            lyricLines = []
        }
    }

    // MARK: - 底部玻璃胶囊控制栏（对齐 FloatingPlayerControls 展开态 + ProgressBar）

    private func controlsCapsule(track: Track) -> some View {
        VStack(spacing: 16) {
            // 行1：标题导航（prev / 标题+艺术家 / next）
            HStack(spacing: 12) {
                Button { player.playPrevious() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(FoliaTheme.t2)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(player.queue.isEmpty)

                VStack(spacing: 3) {
                    Text(track.title)
                        .font(FoliaFont.serif(17, .bold))
                        .foregroundStyle(FoliaTheme.t1)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(FoliaFont.sans(11))
                        .foregroundStyle(FoliaTheme.t2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                Button { player.playNext() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(FoliaTheme.t2)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(player.queue.isEmpty)
            }

            // 行2：进度条（对齐 ProgressBar：前导钮 + 时间 + 轨道 + 时长）
            HStack(spacing: 10) {
                Button { player.toggleLoop() } label: {
                    Image(systemName: player.loopMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(player.loopMode == .off ? FoliaTheme.t3 : FoliaTheme.t1)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(formatTime(player.currentTime))
                    .font(FoliaFont.mono(10))
                    .foregroundStyle(FoliaTheme.t2)
                    .frame(width: 36, alignment: .trailing)

                Slider(value: timeBinding, in: 0...max(player.duration, 1)) { editing in
                    if editing {
                        scrubActive = true
                        scrubValue = player.currentTime
                    } else {
                        player.seek(to: scrubValue)
                        scrubActive = false
                    }
                }
                .tint(FoliaTheme.accent)
                .controlSize(.mini)

                Text(formatTime(player.duration))
                    .font(FoliaFont.mono(10))
                    .foregroundStyle(FoliaTheme.t2)
                    .frame(width: 36, alignment: .leading)
            }

            // 行3：主控制组（上一首 / 播放 / 下一首）
            HStack(spacing: 44) {
                Button { player.playPrevious() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(FoliaTheme.t2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(player.queue.isEmpty)

                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(FoliaTheme.onAccent)
                        .frame(width: 56, height: 56)
                        .background(FoliaTheme.accent, in: Circle())
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                }
                .buttonStyle(.plain)

                Button { player.playNext() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(FoliaTheme.t2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(player.queue.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).fill(.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(FoliaTheme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    /// 进度条绑定：拖动时暂停跟随播放时间，松手再 seek。
    private var timeBinding: Binding<Double> {
        Binding(
            get: { scrubActive ? scrubValue : player.currentTime },
            set: { newValue in
                scrubValue = newValue
                if !scrubActive { player.seek(to: newValue) }
            }
        )
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 单行歌词（主行 + 翻译）：对齐 VisualizerSubtitleOverlay ——
/// 当前行高亮放大，非当前行轻微缩小 + 模糊。
struct LyricRow: View {
    let line: LyricLine
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 5) {
            Text(line.text)
                .font(FoliaFont.serif(isCurrent ? 21 : 17, isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? FoliaTheme.t1 : FoliaTheme.t2)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .blur(radius: isCurrent ? 0 : 0.6)
            if let trans = line.translation, !trans.isEmpty {
                Text(trans)
                    .font(FoliaFont.sans(isCurrent ? 13 : 12))
                    .foregroundStyle(isCurrent ? FoliaTheme.t2 : FoliaTheme.t3)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 36)
        .scaleEffect(isCurrent ? 1 : 0.94)
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}
