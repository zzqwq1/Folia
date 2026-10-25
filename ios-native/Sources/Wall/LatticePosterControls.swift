import SwiftUI

/// 展开卡底部的播放控制条。对应 LatticeChrome.css：
/// 宽 `min(100%, 480)`、transport 行 `min-height 44`、按钮 44×44 圆角 12、图标 20，
/// 下方 2px 进度条（整条读数的命中区高 36）。
struct LatticePosterControls: View {
    @EnvironmentObject private var player: PlayerEngine

    let item: WallItem
    /// 原版 revealed = expanded && (hovered || touchOpen || keyboardFocus)
    let revealed: Bool
    /// 卡片当前世界宽度，用来判定 ≤640 档
    let width: CGFloat
    /// 「打开集合 / 打开播放器」由墙面接管
    var onOpenCollection: (() -> Void)? = nil
    var onOpenPlayer: (() -> Void)? = nil

    var body: some View {
        if case .collection = item.source {
            collectionChrome
        } else {
            songChrome
        }
    }

    // MARK: - 集合：只有一颗「打开」

    private var collectionChrome: some View {
        chrome {
            HStack(spacing: 0) {
                Button {
                    onOpenCollection?()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: compact ? 30 : 20, weight: .medium))
                        Text("打开")
                            .font(.system(size: compact ? 22 : 14, weight: .semibold))
                            .tracking((compact ? 22 : 14) * 0.04)
                            .fixedSize()
                    }
                    .padding(.leading, compact ? 22 : 12)
                    .padding(.trailing, compact ? 28 : 16)
                    .frame(height: buttonSize)
                    .background(Color.primary.opacity(0.0))
                    .contentShape(Rectangle())
                }
                .buttonStyle(WallChromeButtonStyle(corner: buttonCorner))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 歌曲：transport + 进度

    private var songTile: WallTile? {
        if case .song(let tile) = item.source { return tile }
        return nil
    }

    private var isCurrentSong: Bool {
        guard let tile = songTile, let song = player.currentSong else { return false }
        return WallTile.key(for: song) == tile.id
    }

    private var canControlCurrent: Bool { isCurrentSong }

    private var duration: Double {
        if canControlCurrent, player.duration > 0 { return player.duration }
        return max(0, Double(songTile?.song.durationMs ?? 0) / 1000)
    }

    private var songChrome: some View {
        chrome {
            VStack(alignment: .leading, spacing: compact ? 16 : 10) {
                HStack(spacing: compact ? 4 : 8) {
                    Button {
                        if canControlCurrent {
                            player.togglePlayPause()
                        } else if let index = songTile?.queueIndex {
                            player.play(at: index)
                        }
                    } label: {
                        chromeIcon(player.isPlaying && canControlCurrent ? "pause.fill" : "play.fill", filled: true)
                    }
                    .buttonStyle(WallChromeButtonStyle(corner: buttonCorner))

                    // details：横向撑开，0fr → 1fr
                    HStack(spacing: 0) {
                        if revealed {
                            extraControls
                        }
                    }
                    .frame(width: revealed ? nil : 0, alignment: .leading)
                    .clipped()
                    .animation(.easeInOut(duration: 0.18), value: revealed)
                    .animation(.easeIn(duration: 0.15), value: revealed)

                    Spacer(minLength: 0)

                    Text("\(timeText(canControlCurrent ? player.currentTime : 0)) / \(timeText(duration))")
                        .font(.system(size: compact ? 20 : 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(theme.ink)
                        .opacity(revealed ? 0.6 : 0)
                        .animation(.easeInOut(duration: 0.18), value: revealed)
                        .padding(.leading, 8)

                    Button {
                        onOpenPlayer?()
                    } label: {
                        chromeIcon("arrow.up.right", filled: false)
                    }
                    .buttonStyle(WallChromeButtonStyle(corner: buttonCorner, dimmed: true))
                }
                .frame(minHeight: buttonSize)

                progressBar
                    .padding(.trailing, compact ? 28 : 12)
            }
        }
    }

    @ViewBuilder
    private var extraControls: some View {
        HStack(spacing: compact ? 4 : 8) {
            Button { player.previous() } label: {
                chromeIcon("backward.fill", filled: true)
            }
            .buttonStyle(WallChromeButtonStyle(corner: buttonCorner, dimmed: true))
            .disabled(!canControlCurrent)

            Button { player.isShuffleEnabled.toggle() } label: {
                chromeIcon("shuffle", filled: false, active: player.isShuffleEnabled)
            }
            .buttonStyle(WallChromeButtonStyle(corner: buttonCorner, dimmed: !player.isShuffleEnabled))
            .disabled(!canControlCurrent)

            Button { cycleRepeat() } label: {
                chromeIcon(repeatIcon, filled: false, active: player.repeatMode != .off)
            }
            .buttonStyle(WallChromeButtonStyle(corner: buttonCorner, dimmed: player.repeatMode == .off))
            .disabled(!canControlCurrent)

            Button { player.next() } label: {
                chromeIcon("forward.fill", filled: true)
            }
            .buttonStyle(WallChromeButtonStyle(corner: buttonCorner, dimmed: true))
            .disabled(!canControlCurrent)
        }
    }

    private var repeatIcon: String {
        player.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    /// 2px 进度条，命中区 36（≤640 为 86）
    private var progressBar: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width, 1)
            let fraction = duration > 0
                ? min(max((canControlCurrent ? player.currentTime : 0) / duration, 0), 1)
                : 0

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(theme.ink.opacity(0.20))
                Rectangle()
                    .fill(theme.ink)
                    .frame(width: usable * fraction)
            }
            .frame(height: 2)
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canControlCurrent, duration > 0 else { return }
                        let ratio = min(max(value.location.x / usable, 0), 1)
                        player.seek(to: ratio * duration)
                    }
            )
        }
        .frame(height: compact ? 86 : 36)
        .opacity(canControlCurrent ? 1 : 0.6)
    }

    // MARK: - 外观

    private var compact: Bool { width < 640 }
    private var buttonSize: CGFloat { compact ? 86 : 44 }
    private var buttonCorner: CGFloat { compact ? 20 : 12 }
    private var iconSize: CGFloat { compact ? 30 : 20 }
    private var theme: WallTheme { .midnight }

    private func chrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: compact ? 640 : 480, alignment: .leading)
            .shadow(color: Color.black.opacity(0.55), radius: 1.5, x: 0, y: 1)
    }

    private func chromeIcon(_ name: String, filled: Bool, active: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: iconSize, weight: .regular))
            .symbolVariant(filled ? .fill : .none)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Rectangle())
            .opacity(active ? 1 : 0.65)
    }

    private func timeText(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(safe.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 44×44 的方形热区：按下时给 16% 底色与 26% 描边。
/// 次要按钮常驻 65% 不透明度（`.lattice-secondary-action / .lattice-chrome-actions button`），
/// 按下或启用态时回到 1；禁用时 25%。
struct WallChromeButtonStyle: ButtonStyle {
    let corner: CGFloat
    var dimmed: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(configuration.isPressed ? 0.26 : 0), lineWidth: 1)
            )
            .opacity(isEnabled ? (dimmed && !configuration.isPressed ? 0.65 : 1) : 0.25)
            .contentShape(Rectangle())
    }
}
