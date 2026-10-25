import Foundation

// 与原版前端对齐的最小数据模型（src/types.ts 的 SongResult / UnifiedSong，
// src/types/onlineMusic.ts 的 ProviderCollection）。字段只保留原生界面用得到的部分。

struct Artist: Hashable, Codable, Identifiable {
    let id: Int
    let name: String
}

struct Album: Hashable, Codable {
    let id: Int
    let name: String
    let coverUrl: String?

    /// 列表里的封面常常是 http://，接口也允许 https://，统一改写避免 ATS 拦截。
    var cover: URL? { Album.url(coverUrl) }

    /// 列表封面按点阵尺寸下采样，避免整张 1080p 图被解码进内存
    func cover(size: Int) -> URL? { Album.url(coverUrl, size: size) }

    static func url(_ string: String?, size: Int? = nil) -> URL? {
        guard var text = string, !text.isEmpty else { return nil }
        if text.hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        // 网易云的图片地址支持 ?param=200y200 缩放到指定像素
        if let size, !text.contains("param=") {
            text += (text.contains("?") ? "&" : "?") + "param=\(size)y\(size)"
        }
        return URL(string: text)
    }
}

struct Song: Hashable, Codable, Identifiable {
    let id: Int
    let name: String
    let artists: [Artist]
    let album: Album
    let durationMs: Int
    /// 云盘歌曲（t = 1/2）标记，取音频地址时用到
    let isCloud: Bool
    /// 网易云的 fee：1 = VIP，8 = 低音质免费，0 = 免费
    let fee: Int?
    /// privilege.st < 0 表示下架 / 灰掉
    let st: Int?

    var artistNames: String {
        artists.map(\.name).joined(separator: " / ")
    }

    var durationText: String {
        Song.formatDuration(Double(durationMs) / 1000)
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 能否播放：原版用 privilege.st 判断（netease.ts resolveNeteaseSongAvailability）
    var isPlayable: Bool {
        guard let st else { return true }
        return st >= 0
    }
}

enum CollectionKind: String, Codable {
    case playlist
    case album
    case radio
    case cloud
    case artist
}

/// 首页墙面上的一个集合（歌单 / 专辑 / 电台 / 云盘）
struct MusicCollection: Hashable, Codable, Identifiable {
    let id: Int
    let name: String
    let kind: CollectionKind
    let coverUrl: String?
    let description: String?
    let trackCount: Int?
    let isLiked: Bool
    let creatorName: String?

    var cover: URL? { Album.url(coverUrl) }

    func cover(size: Int) -> URL? { Album.url(coverUrl, size: size) }

    var idString: String { String(id) }
}

struct Account: Hashable, Codable {
    let userId: Int
    let nickname: String
    let avatarUrl: String?
    let vipType: Int?

    var avatar: URL? { Album.url(avatarUrl) }
    var isVip: Bool { (vipType ?? 0) > 0 }
}

/// 歌词的一行；行内带逐字时间（网易云的 yrc / klyric 才有），没有就按整行时间显示。
struct LyricLine: Hashable {
    struct Word: Hashable {
        let start: Double
        let end: Double
        let text: String
    }

    let start: Double
    let end: Double?
    let text: String
    let words: [Word]
}
