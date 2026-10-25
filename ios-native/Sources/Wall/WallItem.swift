import SwiftUI

/// 单张海报的展示数据。墙上的每一格都指向队列里的某一首歌；
/// 队列为空时墙面改铺首页的集合（歌单 / 专辑 / 推荐）。
struct WallItem: Identifiable, Equatable {
    enum Source: Equatable {
        /// 队列里的歌（首页播放墙）
        case song(WallTile)
        /// 首页集合海报
        case collection(MusicCollection)
    }

    let id: String
    var source: Source
    /// 探索墙上这一格属于哪一段（队列墙没有）
    var sectionKey: String? = nil
    /// 这一段的标题（标题格用段落自己的 title，海报卡用段标题当歌手行）
    var heading: String? = nil
    /// 徽标文案：探索墙是种类词（专辑 / 歌单 / 推荐 / 歌手 / 单曲）
    var label: String? = nil
    /// 这一格是哪种条目；探索墙按它排序，也按它统计段摘要
    var entryKind: WallEntryKind? = nil

    var title: String {
        switch source {
        case .song(let tile): return tile.title
        case .collection(let collection): return collection.name
        }
    }

    var subtitle: String {
        if let heading, !heading.isEmpty { return heading }
        switch source {
        case .song(let tile): return tile.artist
        case .collection(let collection):
            return collection.creatorName ?? "\(collection.trackCount ?? 0) 首"
        }
    }

    var coverUrl: String? {
        switch source {
        case .song(let tile): return tile.coverUrl
        case .collection(let collection): return collection.coverUrl
        }
    }

    /// 徽标：歌曲是序号，集合是「歌单 / 专辑 / 推荐」这类种类词（原版 explore 墙是单词，队列墙是数字）
    var badge: String {
        if let label { return label }
        switch source {
        case .song(let tile): return tile.badgeNumber
        case .collection(let collection):
            switch collection.kind {
            case .playlist: return collection.isLiked ? "我喜欢的音乐" : "歌单"
            case .album: return "专辑"
            case .radio: return "推荐"
            case .cloud: return "云盘"
            case .artist: return "歌手"
            }
        }
    }

    var isCurrent: Bool {
        if case .song(let tile) = source { return tile.section == .now }
        return false
    }

    var kind: CollectionKind? {
        if case .collection(let collection) = source { return collection.kind }
        return nil
    }

    static func songs(_ tiles: [WallTile]) -> [WallItem] {
        tiles.map { WallItem(id: $0.id, source: .song($0)) }
    }

    static func collections(_ list: [MusicCollection]) -> [WallItem] {
        list.map { WallItem(id: "collection:\($0.idString)", source: .collection($0)) }
    }
}

// MARK: - 探索墙（原版 exploreWall.ts）

extension WallItem {
    /// 原版 `kindOf`：单曲 → song；集合按 type 分歌手 / 专辑，其余分推荐 / 歌单
    static func entryKind(of collection: MusicCollection) -> WallEntryKind {
        switch collection.kind {
        case .artist: return .artist
        case .album: return .album
        case .radio, .cloud: return .mix
        case .playlist: return .playlist
        }
    }

    /// 原版 `buildExploreTiles`：把几段集合摊成一张张海报，同一条目只留第一次出现的那格
    static func explore(sections: [WallSectionSpec], collections: [MusicCollection]) -> [WallItem] {
        var seen = Set<String>()
        var result: [WallItem] = []
        for section in sections {
            for entry in section.entries {
                guard entry.index >= 0, entry.index < collections.count else { continue }
                let collection = collections[entry.index]
                let key: String
                switch entry.kind {
                case .song:
                    key = collection.idString
                default:
                    key = "collection:\(collection.kind):\(collection.idString)"
                }
                let id = collection.isLiked ? "\(section.key):\(key)" : key
                guard seen.insert(id).inserted else { continue }
                result.append(
                    WallItem(
                        id: id,
                        source: .collection(collection),
                        sectionKey: section.key,
                        heading: section.heading,
                        label: entry.kind.label,
                        entryKind: entry.kind
                    )
                )
            }
        }
        return result
    }

    /// 原版 `sectionsOfTiles`：按 `sectionKey` 连续的一段一段切（key 变了就起新段）
    static func sections(of tiles: [WallItem]) -> [WallSectionSpec] {
        var result: [WallSectionSpec] = []
        for (index, tile) in tiles.enumerated() {
            let key = tile.sectionKey ?? ""
            if result.last?.key != key {
                result.append(
                    WallSectionSpec(key: key, heading: tile.heading ?? "", entries: [])
                )
            }
            result[result.count - 1].entries.append(
                WallSectionSpec.Entry(index: index, kind: tile.entryKind ?? .song)
            )
        }
        return result
    }

    /// 原版 `markPlayingTile`：正在播的那首在墙上就点亮它
    static func markPlaying(_ tiles: [WallItem], currentSong: Song?) -> [WallItem] {
        guard let currentSong else { return tiles }
        let key = currentSong.playbackKey
        guard let index = tiles.firstIndex(where: { $0.id == key }) else { return tiles }
        var copy = tiles
        if case .song(var tile) = copy[index].source {
            tile = WallTile(
                id: tile.id,
                queueIndex: tile.queueIndex,
                song: tile.song,
                title: tile.title,
                artist: tile.artist,
                coverUrl: tile.coverUrl,
                section: .now
            )
            copy[index].source = .song(tile)
        }
        return copy
    }
}
