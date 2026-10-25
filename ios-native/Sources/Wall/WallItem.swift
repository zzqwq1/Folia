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
    let source: Source

    var title: String {
        switch source {
        case .song(let tile): return tile.title
        case .collection(let collection): return collection.name
        }
    }

    var subtitle: String {
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
        list.map { WallItem(id: "collection:\($0.id)", source: .collection($0)) }
    }
}
