import Foundation

/// 各平台归一化后的 API。原生 App 走 Worker 的 /api/native/netease 路径：
/// 不依赖家用/服务器隧道（这两条只有电脑开着才通），全走 Worker 自带的 weapi，
/// 保证 iPhone 上「电脑关机也能登录/拿数据」。
enum FoliaAPI {

    // MARK: - 网易云

    /// 拿当前登录用户信息（基于 Cookie）。返回空表示未登录或 Cookie 失效。
    static func neteaseAccount(cookie: String) async throws -> UserProfile {
        struct Resp: Decodable {
            let code: Int?
            struct Profile: Decodable {
                let userId: Int
                let nickname: String?
                let avatarUrl: String?
            }
            let profile: Profile?
            let account: Profile?
        }
        let data = try await APIClient.get(
            "/api/native/netease/user/account",
            query: ["cookie": cookie],
            provider: .netease,
            cookie: nil
        )
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        guard let p = decoded.profile ?? decoded.account, let name = p.nickname else {
            throw APIClient.APIError.notLoggedIn
        }
        return UserProfile(provider: .netease, userId: String(p.userId), nickname: name, avatarUrl: p.avatarUrl)
    }

    /// 拿用户的歌单（创建的 + 收藏的）。
    static func neteaseUserPlaylists(userId: String, cookie: String) async throws -> [Playlist] {
        struct Resp: Decodable {
            struct P: Decodable {
                let id: Int
                let name: String?
                let coverImgUrl: String?
                let trackCount: Int?
                let creator: C?
                struct C: Decodable { let nickname: String? }
            }
            let code: Int?
            let playlist: [P]?
        }
        let data = try await APIClient.get(
            "/api/native/netease/user/playlist",
            query: ["uid": userId, "cookie": cookie],
            provider: .netease,
            cookie: nil
        )
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        let list = decoded.playlist ?? []
        return list.map { p in
            Playlist(
                id: String(p.id),
                provider: .netease,
                title: p.name ?? "未命名",
                coverUrl: p.coverImgUrl,
                trackCount: p.trackCount ?? 0,
                creator: p.creator?.nickname
            )
        }
    }

    /// 推荐歌单（无需登录）。
    static func neteaseRecommendPlaylists(cookie: String?) async throws -> [Playlist] {
        struct Resp: Decodable {
            struct P: Decodable {
                let id: Int
                let name: String?
                let picUrl: String?
                let copywriter: String?
            }
            let code: Int?
            let result: [P]?
            let recommend: [P]?
        }
        var query: [String: String] = [:]
        if let cookie, !cookie.isEmpty { query["cookie"] = cookie }
        let data = try await APIClient.get(
            "/api/native/netease/personalized",
            query: query,
            provider: .netease,
            cookie: nil
        )
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        let list = decoded.result ?? decoded.recommend ?? []
        return list.map { p in
            Playlist(
                id: String(p.id),
                provider: .netease,
                title: p.name ?? "未命名",
                coverUrl: p.picUrl,
                trackCount: 0,
                creator: nil
            )
        }
    }

    /// 歌单详情（含全部曲目）。
    static func neteasePlaylistTracks(id: String, cookie: String) async throws -> [Track] {
        struct Resp: Decodable {
            struct P: Decodable {
                struct T: Decodable {
                    let id: Int
                    let name: String?
                    let ar: [A]?
                    let al: AL?
                    let dt: Int?
                    struct A: Decodable { let name: String? }
                    struct AL: Decodable { let name: String?; let picUrl: String? }
                }
                let tracks: [T]?
            }
            let code: Int?
            let playlist: P?
        }
        let data = try await APIClient.get(
            "/api/native/netease/playlist/detail",
            query: ["id": id, "cookie": cookie],
            provider: .netease,
            cookie: nil
        )
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        let tracks = decoded.playlist?.tracks ?? []
        return tracks.map { t in
            let artists = (t.ar ?? []).compactMap { $0.name }.joined(separator: " / ")
            return Track(
                id: String(t.id),
                provider: .netease,
                title: t.name ?? "未知",
                artist: artists.isEmpty ? "未知艺人" : artists,
                album: t.al?.name,
                coverUrl: t.al?.picUrl,
                durationMs: t.dt
            )
        }
    }

    /// 单曲播放地址。
    static func neteaseSongUrl(id: String, cookie: String) async throws -> URL {
        struct Resp: Decodable {
            struct D: Decodable { let url: String? }
            let code: Int?
            let data: [D]?
        }
        let data = try await APIClient.get(
            "/api/native/netease/song/url",
            query: ["id": id],
            provider: .netease,
            cookie: cookie
        )
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        guard let urlStr = decoded.data?.first?.url, !urlStr.isEmpty, let url = URL(string: urlStr) else {
            throw APIClient.APIError.badStatus(404, "song url not available")
        }
        return url
    }
}
