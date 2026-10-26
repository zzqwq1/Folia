//
//  MiniPlayerBar.swift
//  Folia
//
//  底部播放条：封面 + 曲名 + 播放/暂停 + 极细进度线。
//  用 matchedGeometryEffect 与播放页共享封面，转场时封面连续放大。
//

import SwiftUI

struct MiniPlayerBar: View {
    var transition: Namespace.ID
    var onTap: () -> Void

    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        Group {
            if let track = player.current {
                bar(track)
            }
        }
    }

    private func bar(_ track: Track) -> some View {
        VStack(spacing: 0) {
            progressLine

            HStack(spacing: 11) {
                CoverArt(url: track.artworkURL, size: 40, radius: 9)
                    .matchedGeometryEffect(id: "artwork", in: transition)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Theme.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var progressLine: some View {
        GeometryReader { proxy in
            let ratio = player.duration > 0
                ? min(1, max(0, player.currentTime / player.duration))
                : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.06))
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: proxy.size.width * ratio)
            }
        }
        .frame(height: 2)
    }
}
