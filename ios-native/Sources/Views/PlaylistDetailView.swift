import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var player: PlayerModel

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView()
            } else if let err = errorMessage {
                Text(err).foregroundStyle(.secondary)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        Task {
                            let cookie = session.cookie(for: track.provider) ?? ""
                            await player.play(track, cookie: cookie)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if player.current?.id == track.id {
                                Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
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
