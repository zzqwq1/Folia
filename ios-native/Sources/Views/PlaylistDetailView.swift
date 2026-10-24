import SwiftUI

/// 歌单详情：对齐 GridView 的「模糊封面背景 + 信息面板 + 曲目行」
struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var player: PlayerModel
    @Environment(\.dismiss) var dismiss

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            FoliaTheme.bg.ignoresSafeArea()

            // 背景：超大模糊封面（对齐 GridView 的整页铺背景）
            if let url = playlist.coverUrl, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    }
                }
                .blur(radius: 60)
                .opacity(0.18)
                .ignoresSafeArea()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 信息面板（对齐 w-80 rounded-3xl p-6）
                    VStack(alignment: .leading, spacing: 14) {
                        AsyncImage(url: URL(string: playlist.coverUrl ?? "")) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default: FoliaTheme.fill
                            }
                        }
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(FoliaTheme.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.title)
                                .font(FoliaFont.serif(22, .bold))
                                .foregroundStyle(FoliaTheme.t1)
                            if let creator = playlist.creator {
                                Text("by \(creator)")
                                    .font(FoliaFont.sans(12))
                                    .foregroundStyle(FoliaTheme.t2)
                            }
                            if playlist.trackCount > 0 {
                                Text("\(playlist.trackCount) 首")
                                    .font(FoliaFont.mono(10))
                                    .foregroundStyle(FoliaTheme.t3)
                            }
                        }

                        // 播放全部按钮（对齐 GridView 的 accent 底大按钮）
                        Button {
                            if let first = tracks.first {
                                Task {
                                    let cookie = session.cookie(for: first.provider) ?? ""
                                    await player.play(first, cookie: cookie)
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("播放全部")
                                    .font(FoliaFont.sans(15, .semibold))
                            }
                            .foregroundStyle(FoliaTheme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(FoliaTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(tracks.isEmpty)
                        .opacity(tracks.isEmpty ? 0.5 : 1)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FoliaTheme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(FoliaTheme.line, lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    // 曲目行
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView().tint(FoliaTheme.t2)
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else if let err = errorMessage {
                        Text(err)
                            .font(FoliaFont.sans(13))
                            .foregroundStyle(FoliaTheme.t3)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(
                                    index: index + 1,
                                    track: track,
                                    isCurrent: player.current?.id == track.id,
                                    isPlaying: player.isPlaying
                                ) {
                                    Task {
                                        let cookie = session.cookie(for: track.provider) ?? ""
                                        await player.play(track, cookie: cookie)
                                    }
                                }
                                if index < tracks.count - 1 {
                                    Divider().background(FoliaTheme.line).padding(.leading, 68)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    Color.clear.frame(height: 120)
                }
            }

            // 左上返回钮（对齐 GridView 的 40px 圆形返回钮）
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FoliaTheme.t1)
                    .frame(width: 40, height: 40)
                    .background(FoliaTheme.card.opacity(0.8), in: Circle())
                    .overlay(Circle().stroke(FoliaTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .padding(.top, 8)
        }
        .navigationBarHidden(true)
        .task { await load() }
    }

    private func load() async {
        guard tracks.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let cookie = session.cookie(for: playlist.provider) ?? ""
            switch playlist.provider {
            case .netease:
                tracks = try await FoliaAPI.neteasePlaylistTracks(id: playlist.id, cookie: cookie)
            default:
                errorMessage = "\(playlist.provider.displayName) 暂未接进原生版"
            }
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }
}

/// 曲目行：对齐 TrackListItem（40px 封面 + 14 歌名 + 10 艺术家）
struct TrackRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(FoliaFont.mono(11))
                    .foregroundStyle(FoliaTheme.t3)
                    .frame(width: 24, alignment: .trailing)

                AsyncImage(url: URL(string: track.coverUrl ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: FoliaTheme.fill
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(FoliaFont.sans(14, .semibold))
                        .foregroundStyle(isCurrent ? Color(hex: track.provider.accentColorHex) : FoliaTheme.t1)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(FoliaFont.sans(10))
                        .foregroundStyle(FoliaTheme.t3)
                        .lineLimit(1)
                }

                Spacer()

                if isCurrent {
                    Image(systemName: isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: track.provider.accentColorHex))
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
