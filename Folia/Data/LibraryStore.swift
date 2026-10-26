//
//  LibraryStore.swift
//  Folia
//
//  数据层：歌单、曲目、播放地址、歌词、搜索。
//  接口沿用 Web 版的 /api/<source> 约定，走 Folia 官方 API 网关。
//

import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?

    private let base = FoliaConfig.apiBase
    private var streamCache: [String: URL] = [:]

    // MARK: - 首页歌单

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let remote = try await fetchHotPlaylists(limit: 24)
            if !remote.isEmpty { playlists = remote }
        } catch {
            errorMessage = "歌单加载失败"
        }
    }

    private func fetchHotPlaylists(limit: Int) async throws -> [Playlist] {
        let root = try await getJSON(path: "/api/netease/top/playlist",
                                     query: ["order": "hot",
                                             "limit": String(limit),
                                             "offset": "0"])
        guard let list = root["playlists"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = Self.stringValue(item["id"]),
                  let name = item["name"] as? String else { return nil }
            return Playlist(
                id: id,
                name: name,
                coverURL: Self.urlValue(item["coverImgUrl"]),
                trackCount: Self.intValue(item["trackCount"]) ?? 0,
                description: item["description"] as? String,
                source: .netease,
                tracks: nil
            )
        }
    }

    // MARK: - 歌单详情

    func tracks(of playlist: Playlist) async throws -> [Track] {
        if let local = playlist.tracks { return local }

        let root = try await getJSON(path: "/api/netease/playlist/detail",
                                     query: ["id": playlist.id])
        guard let detail = root["playlist"] as? [String: Any],
              let list = detail["tracks"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return list.compactMap { Self.track(from: $0) }
    }

    // MARK: - 播放地址

    func streamURL(for track: Track) async throws -> URL {
        if let cached = streamCache[track.id] { return cached }

        let root = try await getJSON(path: "/api/\(track.source.rawValue)/song/url",
                                     query: ["id": track.id])
        guard let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let raw = first["url"] as? String,
              let url = URL(string: raw) else {
            throw URLError(.resourceUnavailable)
        }
        streamCache[track.id] = url
        return url
    }

    // MARK: - 歌词

    func lyrics(for track: Track) async throws -> [LyricLine] {
        let root = try await getJSON(path: "/api/\(track.source.rawValue)/lyric",
                                     query: ["id": track.id])
        let lrc = root["lrc"] as? [String: Any]
        guard let text = lrc?["lyric"] as? String else { return [] }
        return Self.parseLRC(text)
    }

    // MARK: - 搜索

    func search(_ keyword: String) async throws -> [Track] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        isSearching = true
        defer { isSearching = false }

        let root = try await getJSON(path: "/api/netease/search",
                                     query: ["keywords": trimmed,
                                             "type": "1",
                                             "limit": "40"])
        guard let result = root["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return [] }
        return songs.compactMap { Self.track(from: $0) }
    }

    // MARK: - 解析工具

    private static func track(from item: [String: Any]) -> Track? {
        guard let id = stringValue(item["id"]),
              let name = item["name"] as? String else { return nil }

        var artistNames: [String] = []
        if let artists = item["ar"] as? [[String: Any]] {
            artistNames = artists.compactMap { $0["name"] as? String }
        } else if let artists = item["artists"] as? [[String: Any]] {
            artistNames = artists.compactMap { $0["name"] as? String }
        }

        let album = item["al"] as? [String: Any] ?? item["album"] as? [String: Any]
        let durationMs = doubleValue(item["dt"]) ?? doubleValue(item["duration"]) ?? 0

        return Track(
            id: id,
            title: name,
            artist: artistNames.isEmpty ? "未知艺人" : artistNames.joined(separator: " / "),
            album: album?["name"] as? String,
            artworkURL: urlValue(album?["picUrl"]) ?? urlValue(item["picUrl"]),
            duration: durationMs / 1000,
            streamURL: nil,
            source: .netease
        )
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]",
                                                  options: []) else { return [] }
        text.enumerateLines { raw, _ in
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { return }
            let content = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return }
            for match in matches {
                let minute = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let second = Double(ns.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: match.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                lines.append(LyricLine(time: minute * 60 + second + fraction, text: content))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    // MARK: - 网络

    private func getJSON(path: String, query: [String: String]) async throws -> [String: Any] {
        guard var comps = URLComponents(string: base + path) else { throw URLError(.badURL) }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FoliaNative/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func urlValue(_ value: Any?) -> URL? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }
}
