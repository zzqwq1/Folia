import Foundation
import CoreGraphics

/// 探索墙的种类：一块 lot 上条目按它排序，标题格的副标题按它写种类词。
/// 逐条对应原版 `latticeModel.ts` 的 `WallEntryKind`。
enum WallEntryKind: String, CaseIterable {
    case album
    case playlist
    case mix
    case artist
    case song
}

/// 一段（section）：一面墙按页面的段落拼贴时，一块 lot 就是一个 section（太长则摊成几块）。
/// 逐条对应原版 `wallLayout.ts` 的 `WallSection`。
struct WallSectionSpec: Equatable {
    var key: String
    var heading: String
    /// 每个条目在墙的条目列表里的位置，以及它是哪一种
    var entries: [Entry]

    struct Entry: Equatable {
        var index: Int
        var kind: WallEntryKind
    }

    /// 这一段的种类词，按墙给种类排的次序：`"12 · 专辑 · 歌单 · 单曲"`
    /// （原版 `summaryOfSection`，KINDS = album, playlist, mix, artist, song）
    var summary: String {
        var parts = ["\(entries.count)"]
        for kind in WallSectionSpec.kindOrder where entries.contains(where: { $0.kind == kind }) {
            parts.append(kind.label)
        }
        return parts.joined(separator: " · ")
    }

    /// 原版 `KINDS` 的次序
    static let kindOrder: [WallEntryKind] = [.album, .playlist, .mix, .artist, .song]
}

extension WallEntryKind {
    /// 原版 `KIND_LABEL_KEYS` 的中文（`home.exploreAlbum` … `home.exploreSong`）
    var label: String {
        switch self {
        case .album: return "专辑"
        case .playlist: return "歌单"
        case .mix: return "推荐"
        case .artist: return "歌手"
        case .song: return "单曲"
        }
    }

    /// 一块 lot 上条目的次序：集合在前，于是占到大座位
    var rank: Int {
        switch self {
        case .album: return 0
        case .playlist: return 1
        case .mix: return 1
        case .artist: return 2
        case .song: return 3
        }
    }
}

/// 标题格：探索墙上的一格标题，和海报一样是墙的一块，只是没有图。
/// 对应原版 `WallHeading`。
struct WallHeadingInstance: Identifiable, Equatable {
    var instanceId: String
    /// 墙的段落里的第几段（从 0）
    var section: Int
    /// 这一段的第几块 lot（从 0）与一共几块
    var part: Int
    var parts: Int
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var id: String { instanceId }
    var rect: WallRect { WallRect(x: x, y: y, width: width, height: height) }
}

/// 一面墙的布局：队列墙是无限格点，探索墙是按段落拼贴的 lot。
/// 逐条对应原版 `wallLayout.ts` 的 `WallLayout`。
protocol WallLayoutSpec {
    var sections: [WallSectionSpec] { get }
    /// 一块 lot 的尺寸；队列墙没有 lot（nil）
    var lotSize: CGSize? { get }
    /// 视口（外扩 overscan）里要画的海报与标题格
    func near(_ bounds: WallBounds, overscan: CGFloat) -> (posters: [QueueInstance], headings: [WallHeadingInstance])
    /// 某一首歌最近的副本
    func nearest(queueIndex: Int, point: CGPoint) -> QueueInstance?
    /// 展开卡所在那块 lot 的让位表
    func grown(_ active: QueueInstance) -> [String: WallRect]
    /// 方向键从这一格出发的候选（这一块 lot 与四周八块）
    func stepCandidates(from: QueueInstance) -> [QueueInstance]
    /// 世界坐标下的点落在哪一段；街道返回 nil
    func sectionAt(_ point: CGPoint) -> Int?
    /// 某一段第一块 lot 左上角最近的位置
    func sectionStart(_ section: Int, point: CGPoint) -> CGPoint?
}
