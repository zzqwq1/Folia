import Foundation

/// 墙面上的一张卡。原版 latticeModel.ts 的 buildLatticeTiles：
/// 队列里的每首歌都是一张海报，`section` 决定徽标文案与描边强度。
struct WallTile: Identifiable, Equatable {
    enum Section: String {
        case now      // 正在播放
        case played   // 已播放
        case upcoming // 待播放
    }

    let id: String
    let queueIndex: Int
    let song: Song
    let title: String
    let artist: String
    let coverUrl: String?
    let section: Section

    /// 原版 `getPlaybackSongKey` = `${provider}:${id}`；同一首歌在队列里出现两次时也当作两张卡
    static func key(for song: Song) -> String { song.playbackKey }

    /// 徽标序号：`String(queueIndex + 1).padStart(2, '0')`
    var badgeNumber: String { String(format: "%02d", queueIndex + 1) }

    /// 文案块的歌手行：`getSongArtistLabel(song) || album.name || 'Unknown artist'`
    static func artistLabel(for song: Song) -> String {
        let names = song.artists.map(\.name).filter { !$0.isEmpty }
        if !names.isEmpty { return names.joined(separator: " / ") }
        return song.album.name.isEmpty ? "Unknown artist" : song.album.name
    }

    static func build(queue: [Song], currentIndex: Int) -> [WallTile] {
        queue.enumerated().map { index, song in
            let section: Section
            if index == currentIndex {
                section = .now
            } else if index < currentIndex {
                section = .played
            } else {
                section = .upcoming
            }
            return WallTile(
                id: key(for: song),
                queueIndex: index,
                song: song,
                title: song.name,
                artist: artistLabel(for: song),
                coverUrl: song.album.coverUrl,
                section: section
            )
        }
    }
}

/// 首页墙上的一个「集合」：歌单 / 专辑 / 推荐电台。
/// 原版桌面首页铺的是收藏的集合，点开后进集合页再播放曲目；这里保持同一层级。
struct WallEntry: Identifiable, Equatable {
    let id: String
    let collection: MusicCollection

    static func build(_ collections: [MusicCollection]) -> [WallEntry] {
        collections.map { WallEntry(id: $0.idString, collection: $0) }
    }
}
