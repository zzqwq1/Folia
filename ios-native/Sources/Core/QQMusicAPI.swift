import Foundation
import CommonCrypto

/// QQ 音乐。照 `src/services/onlineMusic/qq/` 的 transport / normalize / provider 三段移植：
///
/// - 基础地址 `https://app.folia-api.top/api/qq`，路径见 `Route.path`
/// - 会话是 cookie 名 `qqmusic_session`：同源请求走 `X-QQ-Session` 头（裸 token），
///   跨源 / 其它平台走 `?cookie=<整串>`；每次请求都补一个 `timestamp` 破缓存
/// - 状态码：401 → 需要登录、404 → 该接口不支持、其余非 2xx → 网络错误、429 带 retryAfter
/// - 匿名也要能搜索：退回 `u.y.qq.com/cgi-bin/musicu.fcg`（`music.search.SearchCgiService`）
actor QQMusicAPI {
    static let shared = QQMusicAPI()

    private let base = "https://app.folia-api.top/api/qq"
    private let musicu = "https://u.y.qq.com/cgi-bin/musicu.fcg"
    private let session: URLSession

    /// 登录态：整串 `qqmusic_session=<token>`
    private var signInCookie: String? {
        didSet { Keychain.set(signInCookie, for: Self.cookieKey) }
    }

    private static let cookieKey = "folia.qq.cookie"

    private init() {
        session = foliaURLSession()
        signInCookie = Keychain.get(Self.cookieKey)
    }

    var isSignedIn: Bool { signInCookie != nil }

    // MARK: - 错误

    struct APIError: LocalizedError {
        let code: Int?
        let message: String
        var errorDescription: String? { message }
    }

    /// 上游的真实失败原因（`auth-required` / `unsupported` / `invalid-response` …）
    private struct UpstreamError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - 路由表（qqTransport.ts 的 ENDPOINTS）

    private enum Route: String {
        case loginQRKey = "login_qr_key"
        case loginQRCreate = "login_qr_create"
        case loginQRCheck = "login_qr_check"
        case loginQRCancel = "login_qr_cancel"
        case loginStatus = "login_status"
        case logout
        case userDetail = "user_detail"
        case userPlaylist = "user_playlist"
        case userAlbums = "user_albums"
        case userLikedSongs = "user_liked_songs"
        case userPlaylistDetail = "user_playlist_detail"
        case userVip = "user_vip"
        case recommendToplists = "recommend_toplists"
        case recommendToplist = "recommend_toplist"
        case radioList = "radio_list"
        case radioTracks = "radio_tracks"
        case musicPlay = "music_play"
        case songListDetail = "song_list_detail"
        case songInfo = "song_info"
        case albumInfo = "album_info"
        case artistAlbums = "artist_albums"
        case artistSongs = "artist_songs"
        case search

        var path: String {
            switch self {
            case .loginQRKey: return "/login/qr/key"
            case .loginQRCreate: return "/login/qr/create"
            case .loginQRCheck: return "/login/qr/check"
            case .loginQRCancel: return "/login/qr/cancel"
            case .loginStatus: return "/login/status"
            case .logout: return "/logout"
            case .userDetail: return "/user/detail"
            case .userPlaylist: return "/user/playlist"
            case .userAlbums: return "/user/albums"
            case .userLikedSongs: return "/user/liked-songs"
            case .userPlaylistDetail: return "/user/playlist-detail"
            case .userVip: return "/user/vip"
            case .recommendToplists: return "/recommend/toplists"
            case .recommendToplist: return "/recommend/toplist"
            case .radioList: return "/radio/list"
            case .radioTracks: return "/radio/tracks"
            case .musicPlay: return "/getMusicPlay"
            case .songListDetail: return "/getSongListDetail"
            case .songInfo: return "/getSongInfo"
            case .albumInfo: return "/getAlbumInfo"
            case .artistAlbums: return "/getSingerAlbum"
            case .artistSongs: return "/getSingerHotsong"
            case .search: return "/search"
            }
        }
    }

    /// `CATALOG_STATUS_NODES`：这些接口回的是 musicu 原样结构，要**先看节点里的 `code`**
    private static let catalogNodes: [Route: [[String]]] = [
        .albumInfo: [["response"]],
        .songListDetail: [["response"]],
        .artistSongs: [["response"], ["response", "singer"]],
        .artistAlbums: [["response"], ["response", "singer"]],
    ]

    private static let postOnly: Set<Route> = [
        .loginQRCheck, .loginQRCancel,
    ]

    // MARK: - 基础请求

    /// 发一个 GET（少数接口上游只接 POST，这里按表切）。
    private func send(
        _ route: Route,
        pathArgs: [String] = [],
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var path = route.path
        for arg in pathArgs {
            path += "/" + (arg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? arg)
        }
        guard var components = URLComponents(string: base + path) else {
            throw APIError(code: nil, message: "bad route \(path)")
        }

        var items = components.queryItems ?? []
        for (key, value) in query {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: value))
        }
        items.append(URLQueryItem(
            name: "timestamp",
            value: String(Int(Date().timeIntervalSince1970 * 1000))
        ))
        components.queryItems = items

        guard let url = components.url else {
            throw APIError(code: nil, message: "bad url for \(path)")
        }
        var request = URLRequest(url: url)
        request.setValue("https://app.folia-api.top", forHTTPHeaderField: "Referer")
        request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")
        if let token = signInCookie.flatMap(Self.token(from:)) {
            request.setValue(token, forHTTPHeaderField: "X-QQ-Session")
        }
        if Self.postOnly.contains(route) || body != nil {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: nil, message: "no response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            signInCookie = nil
            throw UpstreamError(status: 401, message: "登录已失效，请重新扫码")
        case 404:
            throw UpstreamError(status: 404, message: "这个接口暂不支持")
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 5
            throw UpstreamError(status: 429, message: "请求太频繁，\(Int(retry)) 秒后再试")
        default:
            let text = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw UpstreamError(status: http.statusCode, message: "HTTP \(http.statusCode) \(text)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpstreamError(status: http.statusCode, message: "返回的不是 JSON")
        }
        try Self.checkCatalogStatus(route: route, json: json)
        return json
    }

    /// 曲库接口的 `response.code !== 0` 要当错误冒出来，而不是当成空列表
    private static func checkCatalogStatus(route: Route, json: [String: Any]) throws {
        guard let nodes = catalogNodes[route] else { return }
        for path in nodes {
            var cursor: Any? = json
            for key in path {
                cursor = (cursor as? [String: Any])?[key]
            }
            guard let node = cursor as? [String: Any] else { continue }
            if let code = intValue(node["code"]), code != 0 {
                let message = (node["msg"] as? String) ?? (node["message"] as? String) ?? "曲库返回 code \(code)"
                throw UpstreamError(status: 200, message: message)
            }
        }
    }

    /// 从整串 cookie 里取 `qqmusic_session` 的值
    private static func token(from cookie: String) -> String? {
        for piece in cookie.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("qqmusic_session=") else { continue }
            let value = String(trimmed.dropFirst("qqmusic_session=".count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - musicu（匿名兜底）

    /// `requestQqMusicu`：body 是 `{ comm, <key>: { module, method, param } }`，回 `body[key].data`
    private func requestMusicu(
        key: String,
        module: String,
        method: String,
        param: [String: Any],
        extraHeaders: [String: String] = [:]
    ) async throws -> [String: Any] {
        guard let url = URL(string: musicu) else {
            throw APIError(code: nil, message: "bad musicu url")
        }
        let payload: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            key: ["module": module, "method": method, "param": param],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = json[key] as? [String: Any],
              let body = node["data"] as? [String: Any] else {
            throw APIError(code: nil, message: "musicu 返回异常")
        }
        return body
    }

    // MARK: - 账号

    func currentAccount() async throws -> Account? {
        guard signInCookie != nil else { return nil }
        guard let json = try? await send(.loginStatus) else { return nil }
        let data = json["data"] as? [String: Any] ?? json
        if let profile = data["profile"] as? [String: Any] {
            var account = Self.account(from: profile)
            if let vip = try? await send(.userVip) {
                let vipType = intValue(vip["vipType"])
                    ?? intValue((vip["data"] as? [String: Any])?["vipType"])
                if let vipType {
                    account = Account(
                        userId: account.userId,
                        provider: .qq,
                        nickname: account.nickname,
                        avatarUrl: account.avatarUrl,
                        vipType: vipType
                    )
                }
            }
            return account
        }
        // 没有 profile 就是没登录：清掉会话，别每次启动都白打一遍
        signInCookie = nil
        return nil
    }

    private static func account(from raw: [String: Any]) -> Account {
        let userId = stringValue(raw["str_musicid"])
            ?? stringValue(raw["musicid"])
            ?? stringValue(raw["uin"])
            ?? stringValue(raw["id"])
            ?? ""
        let avatar = (raw["avatarUrl"] as? String)
            ?? ((raw["info"] as? [String: Any])?["logo"] as? String)
        return Account(
            userId: userId == "0" ? "" : userId,
            provider: .qq,
            nickname: (raw["nickname"] as? String) ?? (raw["nick"] as? String)
                ?? (raw["name"] as? String) ?? "",
            avatarUrl: avatar,
            vipType: intValue(raw["vipType"])
        )
    }

    func signOut() async {
        _ = try? await send(.logout)
        signInCookie = nil
    }

    // MARK: - 扫码登录

    func qrKey() async throws -> String {
        let json = try await send(.loginQRKey, query: ["channel": "qq"])
        let data = json["data"] as? [String: Any] ?? json
        guard let key = (data["unikey"] as? String) ?? (data["key"] as? String), !key.isEmpty else {
            throw APIError(code: nil, message: "没有拿到二维码 key")
        }
        return key
    }

    /// `data:image/png;base64,...`
    func qrImage(key: String) async throws -> String {
        let json = try await send(.loginQRCreate, query: ["key": key])
        let data = json["data"] as? [String: Any] ?? json
        guard let image = (data["qrimg"] as? String) ?? (data["image"] as? String), !image.isEmpty else {
            throw APIError(code: nil, message: "没有拿到二维码")
        }
        return image
    }

    enum QRState {
        case waiting
        case scanned
        case confirmed
        case expired
        case failed(String)
    }

    /// 最近一次轮询的码（801/802/803/800）
    private var lastQRCodeValue = 0
    func lastQRCode() -> Int { lastQRCodeValue }

    func checkQR(key: String) async -> QRState {
        guard let json = try? await send(.loginQRCheck, query: ["key": key]) else {
            return .failed("网络异常，稍后重试")
        }
        lastQRCodeValue = intValue(json["code"]) ?? 0
        switch lastQRCodeValue {
        case 800: return .expired
        case 801: return .waiting
        case 802: return .scanned
        case 803:
            let cookie = (json["cookie"] as? String)
                ?? ((json["data"] as? [String: Any])?["cookie"] as? String)
            if let cookie, !cookie.isEmpty {
                signInCookie = cookie
                return .confirmed
            }
            return .failed("登录成功但没有拿到登录状态")
        default:
            let message = (json["message"] as? String) ?? (json["msg"] as? String) ?? "未知错误"
            return .failed("code \(lastQRCodeValue): \(message)")
        }
    }

    func cancelQR(key: String) async {
        _ = try? await send(.loginQRCancel, query: ["key": key])
    }

    // MARK: - 曲库

    /// 用户歌单：这个接口不传 uid，一次回整份，分页在本地做
    func userPlaylists(userId: String) async throws -> [MusicCollection] {
        let json = try await send(.userPlaylist)
        let raw = Self.list(from: json, keys: ["playlist", "data", "list", "disslist"])
        var result = raw.enumerated().compactMap { index, item in
            Self.collection(from: item, fallbackId: "qq-dir-\(index)")
        }
        // 收藏的专辑也铺到墙上（原版 userAlbums 与歌单并列）
        if let json = try? await send(.userAlbums, query: ["offset": "0", "limit": "100"]) {
            let list = Self.list(from: json, keys: ["albums", "data", "list"])
            result += list.enumerated().compactMap { index, item -> MusicCollection? in
                let id = stringValue(item["albumMID"]) ?? stringValue(item["albummid"])
                    ?? stringValue(item["mid"]) ?? "qq-album-\(index)"
                guard let name = (item["albumName"] as? String) ?? (item["albumname"] as? String)
                    ?? (item["name"] as? String) else { return nil }
                let rawCover = (item["pic"] as? String) ?? (item["picUrl"] as? String)
                return MusicCollection(
                    id: id,
                    provider: .qq,
                    name: name,
                    kind: .album,
                    coverUrl: rawCover.flatMap(Self.albumCover) ?? rawCover,
                    description: nil,
                    trackCount: intValue(item["total_song_num"]) ?? intValue(item["songNum"]),
                    isLiked: false,
                    creatorName: (item["singerName"] as? String) ?? (item["singer_name"] as? String)
                )
            }
        }
        return result
    }

    /// 歌单曲目。自己创建的歌单（`dirName` 存在）走 `user/playlist-detail`，
    /// 「我喜欢」是 `dirId == 201` 走 `user/liked-songs`，其余走公开的 `getSongListDetail`。
    func playlistTracks(id: String) async throws -> [Song] {
        if let spec = Self.ownedSpec(id) {
            if spec.dirId == 201 {
                return try await likedSongs()
            }
            if let songs = try? await ownedPlaylistTracks(tid: spec.tid, dirId: spec.dirId) {
                return songs
            }
        }
        let json = try await send(.songListDetail, pathArgs: [id])
        let response = json["response"] as? [String: Any] ?? json
        let cd = (response["cdlist"] as? [[String: Any]])?.first
        if let cd, let songs = cd["songlist"] as? [[String: Any]] {
            return songs.compactMap(Self.song)
        }
        if let songs = response["songlist"] as? [[String: Any]] {
            return songs.compactMap(Self.song)
        }
        if let data = json["data"] as? [String: Any],
           let songs = data["songlist"] as? [[String: Any]] {
            return songs.compactMap(Self.song)
        }
        return []
    }

    /// 自己歌单的 id 编码：`tid:dirId`（`userPlaylists` 生成时写入）
    struct OwnedSpec {
        let tid: Int
        let dirId: Int
    }

    static func ownedSpec(_ id: String) -> OwnedSpec? {
        let parts = id.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return OwnedSpec(tid: parts[0], dirId: parts[1])
    }

    private func likedSongs() async throws -> [Song] {
        var all: [Song] = []
        var offset = 0
        while true {
            let json = try await send(.userLikedSongs, query: [
                "offset": String(offset), "limit": "100",
            ])
            let songs = Self.list(from: json, keys: ["songs", "data", "list"])
                .compactMap(Self.song)
            all += songs
            let more = (json["more"] as? Bool) ?? ((json["data"] as? [String: Any])?["more"] as? Bool)
            offset += songs.count
            if more != true || songs.isEmpty || offset >= 2000 { break }
        }
        return all
    }

    private func ownedPlaylistTracks(tid: Int, dirId: Int) async throws -> [Song] {
        var all: [Song] = []
        var offset = 0
        while true {
            let json = try await send(
                .userPlaylistDetail,
                query: ["tid": String(tid), "dirid": String(dirId),
                        "offset": String(offset), "limit": "100"],
                body: ["tid": tid, "dirid": dirId, "offset": offset, "limit": 100]
            )
            let songs = Self.list(from: json, keys: ["songs", "data", "list"])
                .compactMap(Self.song)
            all += songs
            let more = (json["more"] as? Bool) ?? ((json["data"] as? [String: Any])?["more"] as? Bool)
            offset += songs.count
            if more != true || songs.isEmpty || offset >= 2000 { break }
        }
        return all
    }

    /// 专辑曲目
    func album(id: String) async throws -> [Song] {
        let json = try await send(.albumInfo, query: ["albummid": id])
        var songs: [Song] = []
        if let response = json["response"] as? [String: Any] {
            if let data = response["data"] as? [String: Any] {
                songs = (data["list"] as? [[String: Any]])?.compactMap(Self.song) ?? []
            }
            if songs.isEmpty {
                songs = (response["songlist"] as? [[String: Any]])?.compactMap(Self.song) ?? []
                if songs.isEmpty {
                    songs = (response["list"] as? [[String: Any]])?.compactMap(Self.song) ?? []
                }
            }
        }
        if songs.isEmpty, let data = json["data"] as? [String: Any] {
            if let list = data["list"] as? [[String: Any]] {
                songs = list.compactMap(Self.song)
            } else if let inner = data["data"] as? [String: Any],
                      let list = inner["list"] as? [[String: Any]] {
                songs = list.compactMap(Self.song)
            }
        }
        return songs
    }

    func artistSongs(id: String, limit: Int = 50, page: Int = 1) async throws -> [Song] {
        let json = try await send(.artistSongs, query: [
            "singermid": id, "limit": String(limit), "page": String(page),
        ])
        return Self.list(from: json, keys: ["songlist", "list", "songs", "data"]).compactMap(Self.song)
    }

    func artistAlbums(id: String, limit: Int = 30, page: Int = 1) async throws -> [MusicCollection] {
        let json = try await send(.artistAlbums, query: [
            "singermid": id, "limit": String(limit), "begin": String((page - 1) * limit),
        ])
        return Self.list(from: json, keys: ["albumList", "list", "data"]).enumerated().compactMap { index, item in
            let albumId = stringValue(item["albumMID"]) ?? stringValue(item["albummid"])
                ?? stringValue(item["mid"]) ?? "\(id)-album-\(index)"
            guard let name = (item["albumName"] as? String) ?? (item["albumname"] as? String)
                ?? (item["name"] as? String) else { return nil }
            let cover = (item["pic"] as? String) ?? (item["picUrl"] as? String)
            return MusicCollection(
                id: albumId,
                provider: .qq,
                name: name,
                kind: .album,
                coverUrl: cover.flatMap(Self.albumCover) ?? cover,
                description: nil,
                trackCount: intValue(item["songNum"]) ?? intValue(item["total_song_num"]),
                isLiked: false,
                creatorName: nil
            )
        }
    }

    /// 搜索：有会话先走代理的 `/search`，首页空且没有更多就回落匿名 musicu
    func search(_ keywords: String, limit: Int = 50, offset: Int = 0) async throws -> [Song] {
        let keyword = String(keywords.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let pageSize = max(1, min(limit, 20))
        let page = offset / pageSize + 1

        if signInCookie != nil,
           let json = try? await send(.search, query: [
               "keyword": keyword, "type": "song", "page": String(page), "limit": String(pageSize),
           ]) {
            let songs = Self.list(from: json, keys: ["items", "songs", "data", "list"]).compactMap(Self.song)
            let more = (json["more"] as? Bool) ?? ((json["data"] as? [String: Any])?["more"] as? Bool)
            if !songs.isEmpty || more == true { return songs }
        }

        // 匿名：musicu 的 SearchCgiService
        let body = try await requestMusicu(
            key: "search",
            module: "music.search.SearchCgiService",
            method: "DoSearchForQQMusicLite",
            param: [
                "search_id": String(Int(Date().timeIntervalSince1970 * 1000)),
                "remoteplace": "search.android.keyboard",
                "query": keyword,
                "search_type": 7,
                "num_per_page": pageSize,
                "page_num": page,
                "highlight": 0,
                "nqc_flag": 0,
                "page_id": 1,
                "grp": 1,
            ]
        )
        let inner = body["body"] as? [String: Any] ?? body
        let songs = (inner["item_song"] as? [[String: Any]]) ?? (inner["song"] as? [String: Any])
            .flatMap { ($0["list"] as? [[String: Any]]) } ?? []
        return songs.compactMap(Self.song)
    }

    // MARK: - 播放地址

    /// 音质降档：要的没有就往下降，最后回 128k
    private static func qualityChain(_ quality: String) -> [String] {
        switch quality {
        case "lossless", "hires": return ["flac", "320", "128"]
        case "high", "ultra": return ["320", "128"]
        default: return ["128"]
        }
    }

    func audio(for song: Song, quality: String = "high") async throws -> (url: URL, isPreview: Bool) {
        let songmid = song.id
        let songid = (song.id.split(separator: ":").last).flatMap { Int($0) }

        for level in Self.qualityChain(quality) {
            var query = ["songmid": songmid, "quality": level]
            if let songid { query["mediaId"] = String(songid) }
            guard let json = try? await send(.musicPlay, query: query) else { continue }
            if let text = Self.playURL(from: json, songmid: songmid), let url = httpsURL(text) {
                return (url, false)
            }
        }

        // 没有直链但有会话：再试一次 preview
        if signInCookie != nil,
           let json = try? await send(.musicPlay, query: ["songmid": songmid, "preview": "1"]),
           let text = Self.playURL(from: json, songmid: songmid),
           let url = httpsURL(text) {
            return (url, true)
        }
        throw APIError(code: nil, message: "这首歌暂时没有可播放的音源")
    }

    private static func playURL(from json: [String: Any], songmid: String) -> String? {
        let data = json["data"] as? [String: Any] ?? json
        if let map = data["playUrl"] as? [String: Any] {
            if let direct = map[songmid] as? String, !direct.isEmpty { return direct }
            for value in map.values {
                if let text = value as? String, !text.isEmpty { return text }
            }
        }
        if let entry = data["playUrl"] as? String, !entry.isEmpty { return entry }
        return (data["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - 歌词

    /// 逐字歌词（QRC）。直发 musicu，hex → 3DES → raw deflate。
    func lyrics(for song: Song) async throws -> [LyricLine] {
        let tail = song.id.split(separator: ":").last.flatMap { Int($0) }
        guard let songid = tail ?? Int(song.id) else { return [] }
        let body = try await requestMusicu(
            key: "request",
            module: "music.musichallSong.PlayLyricInfo",
            method: "GetPlayLyricInfo",
            param: [
                "albumName": Self.base64(song.album.name),
                "crypt": 1,
                "ct": 19,
                "cv": 2111,
                "interval": song.durationMs / 1000,
                "lrc_t": 0,
                "qrc": 1,
                "qrc_t": 0,
                "roma": 1,
                "roma_t": 0,
                "singerName": Self.base64(song.artistNames),
                "songID": songid,
                "songName": Self.base64(song.name),
                "trans": 1,
                "trans_t": 0,
                "type": 0,
            ],
            extraHeaders: [
                "Cookie": "tmeLoginType=-1;",
                "User-Agent": "okhttp/3.14.9",
            ]
        )
        // requestMusicu 返回的是 `request` 节点里的 data；这里再允许一层 data
        let payload = (body["data"] as? [String: Any]) ?? body
        let hex = (payload["lyric"] as? String) ?? ""
        guard !hex.isEmpty, let plain = QrcCipher.decrypt(hex: hex) else {
            return []
        }
        let text = String(data: plain, encoding: .utf8) ?? ""
        return LyricParser.parse(text)
    }

    private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    // MARK: - JSON → 模型

    /// 兼容 `{ key: [...] }` / `{ data: { key: [...] } }` / 直接数组
    private static func list(from json: [String: Any], keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let list = json[key] as? [[String: Any]], !list.isEmpty { return list }
        }
        for key in keys {
            if let data = (json["data"] as? [String: Any]) ?? (json["response"] as? [String: Any]),
               let list = data[key] as? [[String: Any]] {
                return list
            }
        }
        for key in keys {
            if let list = json[key] as? [[String: Any]] { return list }
        }
        return []
    }

    /// 收藏专辑的封面常常只给一个专辑 mid
    private static func albumCover(_ text: String) -> String? {
        guard text.range(of: "^[0-9A-Za-z]{10,}$", options: .regularExpression) != nil else { return nil }
        return "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(text).jpg?max_age=2592000"
    }

    private static func collection(from raw: [String: Any], fallbackId: String) -> MusicCollection? {
        let owned = raw["dirName"] != nil || raw["dirname"] != nil
        let tid = intValue(raw["tid"])
        let dirId = intValue(raw["dirId"]) ?? intValue(raw["dirid"])
        let dissId = stringValue(raw["dissid"]) ?? stringValue(raw["dissId"])
        let plainId = stringValue(raw["id"])

        let id: String
        if owned, let tid, let dirId {
            id = "\(tid):\(dirId)"
        } else {
            id = dissId ?? (tid.map { String($0) }) ?? dirId.map { String($0) } ?? plainId ?? fallbackId
        }

        let name = (raw["dirName"] as? String) ?? (raw["dirname"] as? String)
            ?? (raw["dissname"] as? String) ?? (raw["title"] as? String) ?? (raw["name"] as? String)
        guard let name, !name.isEmpty else { return nil }

        let cover = (raw["bigpicUrl"] as? String) ?? (raw["picUrl"] as? String) ?? (raw["picurl"] as? String)
        return MusicCollection(
            id: id,
            provider: .qq,
            name: name,
            kind: .playlist,
            coverUrl: cover,
            description: raw["desc"] as? String,
            trackCount: intValue(raw["songNum"]) ?? intValue(raw["songnum"]),
            isLiked: owned && dirId == 201,
            creatorName: (raw["creator"] as? [String: Any])?["nick"] as? String
        )
    }

    /// 对齐 qqNormalize.ts 的 normalizeQqSong
    static func song(from raw: [String: Any]) -> Song? {
        let inner = raw["songInfo"] as? [String: Any] ?? raw["songinfo"] as? [String: Any] ?? raw
        let track = inner["track_info"] as? [String: Any] ?? inner

        let mid = (track["qqMid"] as? String) ?? (track["mid"] as? String)
            ?? (track["songmid"] as? String) ?? (raw["qqMid"] as? String)
            ?? (raw["mid"] as? String) ?? (raw["songmid"] as? String)
        let numericId = stringValue(raw["songid"]) ?? stringValue(raw["songId"])
            ?? stringValue(track["id"])
        let id = mid ?? numericId
        guard let id, !id.isEmpty else { return nil }

        let albumRaw = (track["album"] as? [String: Any]) ?? (raw["album"] as? [String: Any]) ?? [:]
        let albumMid = (albumRaw["mid"] as? String) ?? (albumRaw["albummid"] as? String)
            ?? (albumRaw["albumMid"] as? String) ?? (albumRaw["albumMID"] as? String)
            ?? (track["albummid"] as? String) ?? (raw["albummid"] as? String)
            ?? ((track["file"] as? [String: Any])?["media_mid"] as? String)

        let cover = albumMid.flatMap { albumCover($0) }
            ?? (albumRaw["pic"] as? String) ?? (raw["albumPic"] as? String)

        let singers = (track["singer"] as? [[String: Any]])
            ?? (track["singers"] as? [[String: Any]])
            ?? (track["artists"] as? [[String: Any]])
            ?? (raw["singer"] as? [[String: Any]]) ?? []

        let seconds = intValue(track["interval"]) ?? intValue(raw["interval"])
            ?? intValue(track["duration"])
        let durationMs = seconds.map { $0 * 1000 } ?? normalizeDurationMs(track["durationMs"])

        let name = (track["title"] as? String) ?? (track["name"] as? String)
            ?? (track["songname"] as? String) ?? (raw["title"] as? String) ?? (raw["name"] as? String)

        let artists = singers.enumerated().compactMap { index, singer -> Artist? in
            let singerName = (singer["name"] as? String) ?? (singer["title"] as? String) ?? ""
            guard !singerName.isEmpty else { return nil }
            return Artist(id: stringValue(singer["mid"]) ?? stringValue(singer["id"]) ?? "\(index)", name: singerName)
        }

        return Song(
            id: id,
            provider: .qq,
            name: name ?? "未知歌曲",
            artists: artists,
            album: Album(id: albumMid ?? "", name: (albumRaw["name"] as? String) ?? (albumRaw["title"] as? String) ?? "", coverUrl: cover),
            durationMs: durationMs,
            isCloud: false,
            fee: intValue(track["pay"]),
            st: nil
        )
    }
}

// MARK: - QRC 解密

/// QQ 逐字歌词（QRC）：上游给的是 hex 文本 → 3DES（key `!@#)(*$%123ZXC!@!@#)(NHL`，
/// 三段 schedule：key[0..16] 加密、key[8..16] 解密、key[0..8] 加密）→ raw deflate。
enum QrcCipher {
    private static let key: [UInt8] = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    static func decrypt(hex: String) -> Data? {
        guard let cipher = data(fromHex: hex), !cipher.isEmpty else { return nil }
        guard let plain = tripleDES(cipher) else { return nil }
        return inflateRaw(plain)
    }

    private static func data(fromHex hex: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        return Data(bytes)
    }

    /// CommonCrypto 的 3DES，ECB / 无填充（末尾补 0 再截回原长）
    private static func tripleDES(_ input: Data) -> Data? {
        let schedule: [(Int, CCOperation)] = [(0, CCOperation(kCCEncrypt)), (8, CCOperation(kCCDecrypt)), (0, CCOperation(kCCEncrypt))]
        var buffer = [UInt8](input)
        if buffer.count % 8 != 0 {
            buffer += [UInt8](repeating: 0, count: 8 - buffer.count % 8)
        }
        let padded = buffer.count
        guard padded > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: padded + kCCBlockSize3DES)
        for (offset, operation) in schedule {
            var keyBytes = Array(key[offset..<(offset + 8)])
            var length = 0
            var status: CCCryptorStatus = CCCryptorStatus(kCCSuccess)
            buffer.withUnsafeBytes { inputRaw in
                output.withUnsafeMutableBytes { outRaw in
                    keyBytes.withUnsafeBytes { keyRaw in
                        status = CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithm3DES),
                            CCOptions(0),
                            keyRaw.baseAddress, 8,
                            nil,
                            inputRaw.baseAddress, padded,
                            outRaw.baseAddress, padded + kCCBlockSize3DES,
                            &length
                        )
                    }
                }
            }
            guard status == CCCryptorStatus(kCCSuccess) else { return nil }
            buffer = Array(output[0..<max(length, padded)])
        }
        guard buffer.count >= input.count else { return nil }
        return Data(buffer[0..<input.count])
    }

    /// raw deflate（无 zlib 头）：先去掉 2 字节头，再退回带头的
    private static func inflateRaw(_ data: Data) -> Data? {
        for skipHeader in [true, false] {
            var source = [UInt8](data)
            if skipHeader {
                guard source.count > 2 else { continue }
                source = Array(source[2...])
            }
            guard !source.isEmpty else { continue }
            var capacity = max(source.count * 8, 4096)
            while capacity <= 8 * 1024 * 1024 {
                var output = [UInt8](repeating: 0, count: capacity)
                let written = source.withUnsafeBufferPointer { input -> Int in
                    output.withUnsafeMutableBufferPointer { out -> Int in
                        compression_decode_buffer(
                            out.baseAddress!, capacity,
                            input.baseAddress!, source.count,
                            nil, COMPRESSION_ZLIB
                        )
                    }
                }
                if written > 0 && written < capacity {
                    return Data(output[0..<written])
                }
                capacity *= 4
            }
        }
        return nil
    }
}
