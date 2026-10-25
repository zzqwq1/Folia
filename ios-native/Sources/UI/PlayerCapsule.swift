import SwiftUI

/// 底部居中的播放胶囊，逐条移植 `src/components/FloatingPlayerControls.tsx` +
/// `src/components/ProgressBar.tsx` + `src/components/floating-player/PlayerControlSlotButton.tsx`。
///
/// 原版两种形态：
/// - 收起（墙面 / 播放中）：`px-4 py-2`、`bg-black/20`、`border-white/5`、宽 `min(100%, 80%)`，
///   里面是一条 32 高的进度条
/// - 展开（悬停 / 暂停时）：`p-3`、`bg-black/40`、`border-white/5`、宽 100%，
///   加上 `grid-cols-[1fr_auto_1fr]`：第一行居中标题，第二行「上一首 / 播放 / 下一首 / 循环 / 歌词」，
///   第三行时间 + 进度条
///
/// 触屏没有 hover，所以：暂停或拖进度时按展开，播放中按收起（和原版 `canAutoExpand` 一致）。
struct PlayerCapsule: View {
    @EnvironmentObject private var player: PlayerEngine

    /// 桌面端外层是 `max-w-[32rem]`（512）居中，`bottom-8`（32）
    static let maxWidth: CGFloat = 512
    static let bottomInset: CGFloat = 32

    var onOpenPlayer: () -> Void

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    /// 暂停时展开；用户点过胶囊内部的空白也展开
    @State private var isPeeking = false

    private var duration: Double { max(player.duration, 0) }
    private var displayTime: Double {
        isScrubbing ? scrubValue : player.currentTime
    }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayTime / duration))
    }
    private var isExpanded: Bool {
        duration <= 0 || !player.isPlaying || isScrubbing || isPeeking
    }

    var body: some View {
        VStack(spacing: 0) {
            capsule
        }
        .frame(maxWidth: Self.maxWidth)
        .padding(.horizontal, 16)
        .padding(.bottom, Self.bottomInset)
    }

    // MARK: - 胶囊

    private var capsule: some View {
        Group {
            if isExpanded { expanded } else { collapsed }
        }
        .frame(maxWidth: isExpanded ? .infinity : Self.maxWidth * 0.8)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(isExpanded ? 0.40 : 0.20))
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
        .clipShape(Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 25, x: 0, y: 25)
        .animation(.easeOut(duration: 0.24), value: isExpanded)
        .onTapGesture { onOpenPlayer() }
    }

    /// `px-4 py-2` + `h-8` 的收起态：只有一条进度条
    private var collapsed: some View {
        progressRow(showTimes: false)
            .frame(height: 32)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// `p-3` + 三行网格
    private var expanded: some View {
        VStack(spacing: 8) {
            Text(player.currentSong?.name ?? "未在播放")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(FoliaTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)

            HStack(spacing: 0) {
                Button {
                    player.togglePlayPause()
                } label: {
                    ZStack {
                        Circle().fill(FoliaTheme.text)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(FoliaTheme.background)
                            .offset(x: player.isPlaying ? 0 : 1)
                    }
                    .frame(width: 48, height: 48)
                }
                .buttonStyle(CapsuleButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    player.previous()
                } label: {
                    slotIcon("backward.end")
                }
                .buttonStyle(CapsuleButtonStyle())
                .frame(maxWidth: .infinity, alignment: .center)

                Button {
                    player.next()
                } label: {
                    slotIcon("forward.end")
                }
                .buttonStyle(CapsuleButtonStyle())
                .frame(maxWidth: .infinity, alignment: .center)

                Button {
                    player.cycleRepeatMode()
                } label: {
                    slotIcon(loopIcon)
                }
                .buttonStyle(CapsuleButtonStyle())
                .frame(maxWidth: .infinity, alignment: .center)

                Button(action: onOpenPlayer) {
                    slotIcon("text.alignleft")
                }
                .buttonStyle(CapsuleButtonStyle())
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            progressRow(showTimes: true)
                .padding(.horizontal, 8)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
    }

    /// `PlayerControlSlotButton`：`rounded-full p-2`、图标 20（`sm` 档 18）、常态 40% 透明
    private func slotIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(FoliaTheme.text)
            .opacity(0.40)
            .padding(8)
            .contentShape(Circle())
    }

    private var loopIcon: String {
        player.repeatMode == .one ? "repeat.1" : "repeat"
    }

    // MARK: - 进度条

    /// `ProgressBar`：`gap-3`、时间 10px mono 60% 宽 32、轨道 `h-1.5` 圆角、填充强调色
    private func progressRow(showTimes: Bool) -> some View {
        HStack(spacing: 12) {
            if showTimes {
                Text(Self.format(displayTime))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(FoliaTheme.textSecondary)
                    .frame(width: 32, alignment: .trailing)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 6)

                    Capsule(style: .continuous)
                        .fill(FoliaTheme.text)
                        .frame(width: max(0, geo.size.width * progress), height: 6)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            isScrubbing = true
                            let ratio = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                            scrubValue = ratio * duration
                        }
                        .onEnded { _ in
                            guard duration > 0 else { return }
                            player.seek(to: scrubValue)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 12)

            if showTimes {
                Text(Self.format(duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(FoliaTheme.textSecondary)
                    .frame(width: 32, alignment: .leading)
            }
        }
    }

    private static func format(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "00:00" }
        let total = Int(time)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
