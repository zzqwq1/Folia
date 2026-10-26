//
//  PlaylistDetailView.swift
//  Folia
//
//  歌单详情：顶部封面 + 播放全部，下面是曲目列表。
//  用 LazyVStack，只为可视区域的行创建视图，滚动多少建多少。
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)

                if isLoading {
                    loadingPlaceholder
                } else if failed {
                    errorPlaceholder
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.play(track, in: tracks)
                        } label: {
                            TrackRow(track: track,
                                     index: index + 1,
                                     isCurrent: player.current?.id == track.id)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .overlay(Theme.stroke)
                            .padding(.leading, 62)
                    }
                }
            }
            .padding(.bottom, 130)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 14) {
            CoverArt(url: playlist.coverURL, size: 104, radius: 16)

            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                Text("\(playlist.trackCount) 首 · \(playlist.source.displayName)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)

                Button {
                    guard let first = tracks.first else { return }
                    player.play(first, in: tracks)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)
                .opacity(tracks.isEmpty ? 0.45 : 1)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 10) {
            ForEach(0..<7, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surfaceHigh)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceHigh)
                            .frame(width: 170, height: 11)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceHigh.opacity(0.6))
                            .frame(width: 110, height: 9)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private var errorPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("曲目加载失败")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Button("重试") { Task { await load() } }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func load() async {
        isLoading = true
        failed = false
        do {
            tracks = try await library.tracks(of: playlist)
        } catch {
            failed = true
        }
        isLoading = false
    }
}

// MARK: - 曲目行

struct TrackRow: View {
    let track: Track
    let index: Int?
    var isCurrent: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                } else if let index {
                    Text("\(index)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    CoverArt(url: track.artworkURL, size: 44, radius: 9)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                Text(track.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if track.duration > 0 {
                Text(Self.format(track.duration))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
