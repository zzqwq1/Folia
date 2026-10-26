//
//  Models.swift
//  Folia
//

import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let duration: TimeInterval
    /// 实际可播放的音频地址（由音源解析得到）。
    let streamURL: URL?
    let source: MusicSource

    var subtitle: String {
        album.map { "\(artist) · \($0)" } ?? artist
    }
}

enum MusicSource: String, Codable, CaseIterable {
    case kugou
    case netease
    case qq

    var displayName: String {
        switch self {
        case .kugou:   return "酷狗"
        case .netease: return "网易云"
        case .qq:      return "QQ 音乐"
        }
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let coverURL: URL?
    let trackCount: Int
    let description: String?
    let source: MusicSource
    /// 若为本地/内置歌单，则直接携带曲目。
    let tracks: [Track]?
}

struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}
