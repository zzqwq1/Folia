import SwiftUI

/// 歌单 / 专辑详情：头部信息 + 曲目列表。点任意一首即用整个列表做队列播放。
struct CollectionView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    let collection: MusicCollection

    @State private var songs: [Song] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                FoliaTheme.background.ignoresSafeArea()

                if isLoading {
                    ProgressView().tint(FoliaTheme.textSecondary)
                } else {
                    List {
                        Section {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                SongRow(song: song, isCurrent: player.currentSong?.id == song.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        player.play(songs, startIndex: index, contextName: collection.name)
                                    }
                                    .listRowBackground(FoliaTheme.background)
                            }
                        } header: {
                            header
                                .textCase(nil)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard !songs.isEmpty else { return }
                        player.play(songs, startIndex: 0, contextName: collection.name)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(songs.isEmpty)
                }
            }
        }
        .tint(FoliaTheme.text)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: collection.cover(size: 400)) { phase in
                    ZStack {
                        FoliaTheme.surface
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        }
                    }
                }
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(FoliaTheme.text)
                        .lineLimit(3)
                    if let creator = collection.creatorName {
                        Text(creator)
                            .font(.system(size: 12))
                            .foregroundStyle(FoliaTheme.textSecondary)
                    }
                    if let count = collection.trackCount ?? (songs.isEmpty ? nil : songs.count) {
                        Text("\(count) 首")
                            .font(.system(size: 12))
                            .foregroundStyle(FoliaTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let description = collection.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(FoliaTheme.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.top, 8)
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

struct SongRow: View {
    let song: Song
    var isCurrent: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? FoliaTheme.text : FoliaTheme.text)
                    .lineLimit(1)
                Text(song.artistNames)
                    .font(.system(size: 11))
                    .foregroundStyle(FoliaTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(song.durationText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(FoliaTheme.textSecondary)
        }
        .padding(.vertical, 2)
        .opacity(song.isPlayable ? 1 : 0.4)
    }
}
