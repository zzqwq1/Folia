import Foundation

/// 各平台归一化后的 API。底层都打 app.folia-api.top，原生 App 只关心业务模型。
enum FoliaAPI {

    // MARK: - 网易云

    /// 拿当前登录用户信息（基于 Cookie）。
    static func neteaseAccount(cookie: String) async throws -> UserProfile {
        struct Resp: Decodable {
            struct Profile: Decodable {
                let userId: Int
                let nickname: String
                let avatarUrl: String?
            }
            let profile: Profile?
            let account: Profile?
        }
        let data = try await APIClient.get("/api/netease/user/account", provider: .netease, cookie: cookie)
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        guard let p = decoded.profile ?? decoded.account else {
            throw APIClient.APIError.badStatus(401, "not logged in")
        }
        return UserProfile(provider: .netease, userId: String(p.userId), nickname: p.nickname, avatarUrl: p.avatarUrl)
    }

    /// 拿用户的歌单（收藏的 + 创建的）。
    static func neteaseUserPlaylists(userId: String, cookie: String) async throws -> [Playlist] {
        struct Resp: Decodable {
            struct P: Decodable {
                let id: Int
                let name: String
                let coverImgUrl: String?
                let trackCount: Int?
                let creator: C?
                struct C: Decodable { let nickname: String? }
            }
            let playlist: [P]?
        }
        let data = try await APIClient.get("/api/netease/user/playlist", query: ["uid": userId], provider: .netease, cookie: cookie)
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        return (decoded.playlist ?? []).map {
            Playlist(
                id: String($0.id),
                provider: .netease,
                title: $0.name,
                coverUrl: $0.coverImgUrl,
                trackCount: $0.trackCount ?? 0,
                creator: $0.creator?.nickname
            )
        }
    }

    /// 推荐歌单（未登录也能用）。
    static func neteaseRecommendPlaylists(cookie: String?) async throws -> [Playlist] {
        struct Resp: Decodable {
            struct P: Decodable {
                let id: Int
                let name: String
                let picUrl: String?
                let playCount: Int?
                let trackCount: Int?
            }
            let result: [P]?
            let recommend: [P]?
        }
        let data = try await APIClient.get("/api/netease/personalized", provider: .netease, cookie: cookie)
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        let list = decoded.result ?? decoded.recommend ?? []
        return list.map {
            Playlist(
                id: String($0.id),
                provider: .netease,
                title: $0.name,
                coverUrl: $0.picUrl,
                trackCount: $0.trackCount ?? 0,
                creator: nil
            )
        }
    }

    /// 歌单详情里的所有曲目。
    static func neteasePlaylistTracks(id: String, cookie: String) async throws -> [Track] {
        struct Resp: Decodable {
            struct P: Decodable {
                struct T: Decodable {
                    let id: Int
                    let name: String
                    let ar: [A]?
                    let al: AL?
                    let dt: Int?
                    struct A: Decodable { let name: String? }
                    struct AL: Decodable { let name: String?; let picUrl: String? }
                }
                let tracks: [T]?
            }
            let playlist: P?
        }
        let data = try await APIClient.get(
            "/api/netease/playlist/detail",
            query: ["id": id],
            provider: .netease,
            cookie: cookie
        )
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        return (decoded.playlist?.tracks ?? []).map {
            Track(
                id: String($0.id),
                provider: .netease,
                title: $0.name,
                artist: ($0.ar ?? []).compactMap { $0.name }.joined(separator: " / "),
                album: $0.al?.name,
                coverUrl: $0.al?.picUrl,
                durationMs: $0.dt
            )
        }
    }

    /// 单曲播放地址。
    static func neteaseSongUrl(id: String, cookie: String) async throws -> URL {
        struct Resp: Decodable {
            struct D: Decodable { let url: String? }
            let data: [D]?
        }
        let data = try await APIClient.get(
            "/api/netease/song/url",
            query: ["id": id],
            provider: .netease,
            cookie: cookie
        )
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        guard let urlStr = decoded.data?.first?.url, let url = URL(string: urlStr) else {
            throw APIClient.APIError.badStatus(404, "no url")
        }
        return url
    }

    // MARK: - 波点

    static func bodianRecommendPlaylists(cookie: String?) async throws -> [Playlist] {
        struct Resp: Decodable {
            struct P: Decodable {
                let id: String?
                let name: String?
                let img: String?
                let count: Int?
            }
            let list: [P]?
        }
        let data = try await APIClient.get(
            "/api/bodian",
            query: ["op": "playlists"],
            provider: .bodian,
            cookie: cookie
        )
        let decoded = try APIClient.decodeJSON(Resp.self, from: data)
        return (decoded.list ?? []).map {
            Playlist(
                id: $0.id ?? UUID().uuidString,
                provider: .bodian,
                title: $0.name ?? "未命名",
                coverUrl: $0.img,
                trackCount: $0.count ?? 0,
                creator: nil
            )
        }
    }

    // MARK: - 酷狗 / QQ 暂用占位（这些平台在 Worker 上还不全）
    // 第一版只让入口「存在但提示敬请期待」，避免承诺做不到的功能。
}
