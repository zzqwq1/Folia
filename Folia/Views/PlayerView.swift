//
//  PlayerView.swift
//  Folia
//
//  播放页：大封面 + 曲目信息 + 进度条 + 歌词/封面切换 + 传输控制。
//  封面用外层容器做连续旋转（每圈 24s），全程只改 transform，不重绘内容。
//

import SwiftUI

struct PlayerView: View {
    var transition: Namespace.ID

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: LibraryStore

    @Environment(\.dismiss) private var dismiss

    @State private var lyrics: [LyricLine] = []
    @State private var showLyrics = true
    @State private var draggingTime: TimeInterval?
    @State private var spin: Double = 0
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                content
                    .frame(maxHeight: .infinity)

                progressBar
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                controls
                    .padding(.top, 18)
                    .padding(.bottom, 18)
            }
        }
        .task(id: player.current?.id) { await loadLyrics() }
        .onAppear { startSpin() }
    }

    // MARK: - 背景

    private var background: some View {
        ZStack {
            Theme.background

            if let url = player.current?.artworkURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 70, opaque: true)
                            .saturation(1.5)
                            .opacity(0.42)
                    }
                }
                .ignoresSafeArea()
            }

            LinearGradient(
                colors: [.black.opacity(0.28), Theme.background.opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(player.current?.source.displayName ?? "Folia")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surfaceHigh.opacity(0.7), in: Capsule())

            Spacer()

            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    showLyrics.toggle()
                }
            } label: {
                Image(systemName: showLyrics ? "photo" : "text.alignleft")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 主体

    private var content: some View {
        GeometryReader { proxy in
            ZStack {
                if showLyrics {
                    if lyrics.isEmpty {
                        VStack(spacing: 14) {
                            artwork(size: max(140, min(proxy.size.width - 80, 300)))
                            VStack(spacing: 6) {
                                Text(player.current?.title ?? "")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(player.current?.artist ?? "")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.top, 16)
                            Text(loadFailed ? "暂无歌词" : "歌词加载中…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.top, 4)
                        }
                    } else {
                        LyricView(lines: lyrics,
                                  currentTime: player.currentTime,
                                  onSeek: { player.seek(to: $0) })
                            .transition(.opacity)
                    }
                } else {
                    VStack(spacing: 18) {
                        artwork(size: max(140, min(proxy.size.width - 64, 340)))
                        VStack(spacing: 6) {
                            Text(player.current?.title ?? "")
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(player.current?.artist ?? "")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func artwork(size: CGFloat) -> some View {
        // 唱片圆盘整体缓慢旋转，只有 transform 变化，不会重绘封面。
        ZStack {
            Circle()
                .fill(Theme.surface)
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))

            CoverArt(url: player.current?.artworkURL, size: size - 34, radius: (size - 34) / 2)

            Circle()
                .fill(Theme.background)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 26, y: 14)
        .rotationEffect(.degrees(spin))
        .matchedGeometryEffect(id: "artwork", in: transition)
    }

    private func startSpin() {
        guard spin == 0 else { return }
        withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) {
            spin = 360
        }
    }

    // MARK: - 进度

    private var progressBar: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let total = max(player.duration, 0.001)
                let value = draggingTime ?? player.currentTime
                let ratio = min(1, max(0, value / total))
                let width = proxy.size.width

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 4)

                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: width * ratio, height: 4)

                    Circle()
                        .fill(Color.white)
                        .frame(width: draggingTime == nil ? 9 : 14,
                               height: draggingTime == nil ? 9 : 14)
                        .offset(x: width * ratio - (draggingTime == nil ? 4.5 : 7))
                        .shadow(color: .black.opacity(0.35), radius: 3)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let ratio = min(1, max(0, gesture.location.x / width))
                            draggingTime = Double(ratio) * player.duration
                        }
                        .onEnded { _ in
                            if let target = draggingTime { player.seek(to: target) }
                            draggingTime = nil
                        }
                )
            }
            .frame(height: 20)

            HStack {
                Text(TrackRow.format(draggingTime ?? player.currentTime))
                Spacer()
                Text(TrackRow.format(player.duration))
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - 控制

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.shuffle ? Theme.accent : Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(Theme.accent)
                    if player.isLoadingTrack {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: player.isPlaying ? 0 : 1.5)
                    }
                }
                .frame(width: 68, height: 68)
                .shadow(color: Theme.accent.opacity(0.42), radius: 16, y: 6)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .frame(height: 44)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)

            Button {
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? Theme.textTertiary : Theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - 歌词加载

    private func loadLyrics() async {
        guard let track = player.current else { return }
        lyrics = []
        loadFailed = false
        do {
            lyrics = try await library.lyrics(for: track)
        } catch {
            loadFailed = true
        }
    }
}
