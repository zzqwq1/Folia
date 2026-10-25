import SwiftUI

/// 播放面板：封面 / 歌词 / 队列三个 tab，底部一排控制键对齐原版 UnifiedPanel。
struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .cover
    @State private var lyrics: [LyricLine] = []

    enum Tab: String, CaseIterable, Identifiable {
        case cover = "封面"
        case lyrics = "歌词"
        case queue = "队列"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Group {
                switch tab {
                case .cover: coverTab
                case .lyrics: lyricsTab
                case .queue: queueTab
                }
            }
            .frame(maxHeight: .infinity)

            controls
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
        .background(FoliaTheme.background.ignoresSafeArea())
        .task(id: player.currentSong?.id) {
            guard let id = player.currentSong?.id else { return }
            lyrics = (try? await NeteaseAPI.shared.lyrics(songId: id)) ?? []
        }
    }

    private var coverTab: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            AsyncImage(url: player.currentSong?.album.cover(size: 900)) { phase in
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FoliaTheme.surface)
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundStyle(FoliaTheme.textSecondary)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 32)
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)

            VStack(spacing: 6) {
                Text(player.currentSong?.name ?? "未在播放")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(FoliaTheme.text)
                    .lineLimit(1)
                Text(player.currentSong?.artistNames ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(FoliaTheme.textSecondary)
                    .lineLimit(1)
                if player.isPreview {
                    Text("仅可试听片段")
                        .font(.system(size: 11))
                        .foregroundStyle(FoliaTheme.textSecondary)
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
    }

    private var lyricsTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                        Text(line.text)
                            .font(.system(size: isActive(index) ? 17 : 15, weight: isActive(index) ? .semibold : .regular))
                            .foregroundStyle(isActive(index) ? FoliaTheme.text : FoliaTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
            }
            .onChange(of: activeIndex) { index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private var queueTab: some View {
        List {
            ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, song in
                HStack {
                    SongRow(song: song, isCurrent: index == player.currentIndex)
                    if index == player.currentIndex {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundStyle(FoliaTheme.text)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { player.play(at: index) }
                .listRowBackground(FoliaTheme.background)
                .swipeActions {
                    Button(role: .destructive) {
                        player.remove(at: index)
                    } label: { Label("移除", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 1)
                )
                .tint(FoliaTheme.text)

                HStack {
                    Text(Song.formatDuration(player.currentTime))
                    Spacer()
                    Text(Song.formatDuration(player.duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(FoliaTheme.textSecondary)
            }

            HStack(spacing: 0) {
                Button {
                    player.repeatMode = nextRepeat(player.repeatMode)
                } label: {
                    Image(systemName: repeatIcon)
                        .frame(maxWidth: .infinity)
                }

                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 24)).frame(maxWidth: .infinity)
                }

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .frame(maxWidth: .infinity)
                }

                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 24)).frame(maxWidth: .infinity)
                }

                Button {
                    player.isShuffleEnabled.toggle()
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.isShuffleEnabled ? FoliaTheme.text : FoliaTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 18))
            .foregroundStyle(FoliaTheme.text)
            .buttonStyle(.plain)
        }
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func nextRepeat(_ mode: PlayerEngine.RepeatMode) -> PlayerEngine.RepeatMode {
        switch mode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    private var activeIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        var result: Int?
        for (index, line) in lyrics.enumerated() where line.start <= player.currentTime + 0.15 {
            result = index
        }
        return result
    }

    private func isActive(_ index: Int) -> Bool {
        activeIndex == index
    }
}
