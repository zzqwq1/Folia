import SwiftUI

/// 底部悬浮的迷你播放条：封面 + 标题 + 播放/暂停 + 下一首。点击整条打开播放面板。
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerEngine
    let song: Song
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: song.album.cover(size: 160)) { phase in
                ZStack {
                    FoliaTheme.surfaceRaised
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").foregroundStyle(FoliaTheme.textSecondary)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FoliaTheme.text)
                    .lineLimit(1)
                Text(song.artistNames)
                    .font(.system(size: 11))
                    .foregroundStyle(FoliaTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(FoliaTheme.text)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(FoliaTheme.text)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(FoliaTheme.border, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }
}
