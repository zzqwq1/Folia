import Foundation

/// 波点音乐。对齐原版 `src/services/onlineMusic/bodian/` 下的
/// `bodianTransport.ts` / `bodianProvider.ts` / `bodianLibrary.ts` / `bodianCatalog.ts` / `bodianNormalize.ts`。
///
/// - 走自建代理 `https://app.folia-api.top/api/bodian`
/// - 所有接口都是同一个地址 + `op` 参数：`?op=<name>&uid=..&token=..&dev=<32位hex>`
/// - 取值参数（`id` / `limit` / `offset` / `quality` / `freeSign` / `moduleId` / `index` / `source` / `liked`）
/// - 代理内部把 op 名字换成上游的：`login_qr_key → qr_key`、`login_qr_check → qr_check`、
///   `user_playlists → playlists`、`song_detail → song_detail`
/// - `limit` 最大 100，超过按 100 截
/// - 扫码：`qr_create` 回 `{ imageUrl }`；`qr_check` 回 `{ state, body: { session: { uid, token } } }`
actor BodianAPI {
    static let shared = BodianAPI()

    private let base = "https://app.folia-api.top/api/bodian"
    private let session: URLSession

    /// 设备号：32 位 hex，第一次用时生成后固定下来
    private var deviceId: String

    /// 登录会话：`uid` + `token`，可选带一份用户资料
    private struct StoredSession: Codable {
        var uid: String
        var token: String
        var nickname: String?
        var avatar: String?
    }

    private var stored: StoredSession?

    private static let deviceKey = "folia.bodian.deviceId"
    private static let sessionKey = "folia.bodian.session"

    private init() {
        session = foliaURLSession()
        if let saved = Keychain.get(Self.deviceKey), saved.count >= 16 {
            deviceId = saved
        } else {
            let fresh = Self.randomDeviceId()
            deviceId = fresh
            Keychain.set(fresh, for: Self.deviceKey)
        }
        if let text = Keychain.get(Self.sessionKey), let data = text.data(using: .utf8) {
            stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        }
    }

    private static func randomDeviceId() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%x", Int.random(in: 0..<16, using: &generator)) }.joined()
    }

    var isSignedIn: Bool {
        guard let stored else { return false }
        return !stored.uid.isEmpty && !stored.token.isEmpty
    }

    private func save(_ value: StoredSession?) {
        stored = value
        if let value, let data = try? JSONEncoder().encode(value),
           let text = String(data: data, encoding: .utf8) {
            Keychain.set(text, for: Self.sessionKey)
        } else {
            Keychain.set(nil, for: Self.sessionKey)
        }
    }

    // MARK: - 基础请求

    struct APIError: LocalizedError {
        let code: Int?
        let message: String
        var errorDescription: String? { message }
    }

    /// 上游 op 名（代理做了一层映射，这里直接用上游的名字）
    private enum Op: String {
        case qrKey = "login_qr_key"
        case qrCreate = "qr_create"
        case qrCheck = "login_qr_check"
        case loginStatus = "login_status"
        case logout = "logout"
        case userPlaylists = "user_playlists"
        case playlistTracks = "playlist_tracks"
        case playlistDetail = "playlist_detail"
        case likedSongs = "liked_songs"
        case albumTracks = "album_tracks"
        case albumDetail = "album_detail"
        case artistDetail = "artist_detail"
        case artistSongs = "artist_songs"
        case artistAlbums = "artist_albums"
        case aiPlaylistDetail = "ai_playlist_detail"
        case search = "search"
        case songDetail = "song_detail"
        case audio = "audio"
        case lyrics = "lyrics"
    }

    /// 拼一个请求地址
    private func url(_ op: Op, params: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: base) else {
            throw APIError(code: nil, message: "bad base url")
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "op", value: op.rawValue),
            URLQueryItem(name: "uid", value: stored?.uid ?? "-1"),
            URLQueryItem(name: "token", value: stored?.token ?? ""),
            URLQueryItem(name: "dev", value: deviceId),
        ]
        for (key, value) in params where !value.isEmpty {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw APIError(code: nil, message: "bad url for \(op.rawValue)")
        }
        return url
    }

    private func send(_ op: Op, params: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: try url(op, params: params))
        request.setValue("https://app.folia-api.top", forHTTPHeaderField: "Referer")
        request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: nil, message: "no response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            save(nil)
            throw APIError(code: http.statusCode, message: "登录已失效，请重新扫码")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw APIError(code: http.statusCode, message: "HTTP \(http.statusCode) \(text)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: nil, message: "返回的不是 JSON")
        }
        return json
    }

    /// 有的接口把数据包在 `body` 里
    private static func payload(_ json: [String: Any]) -> [String: Any] {
        if let body = json["body"] as? [String: Any] { return body }
        return json
    }

    /// 曲目列表统一从 `data.list` / `list` / `<key>` 里取
    private static func list(from json: [String: Any], keys: [String]) -> [[String: Any]] {
        let body = payload(json)
        let data = body["data"] as? [String: Any] ?? body
        for key in keys {
            if let list = data[key] as? [[String: Any]] { return list }
        }
        for key in keys {
            if let list = body[key] as? [[String: Any]] { return list }
        }
        for key in keys {
            if let list = json[key] as? [[String: Any]] { return list }
        }
        return []
    }

    // MARK: - 账号

    func currentAccount() async throws -> Account? {
        guard let stored, isSignedIn else { return nil }
        // 有会话就先给账号：`login_status` 拿不到资料时也要能上墙
        if let json = try? await send(.loginStatus) {
            let body = Self.payload(json)
            let data = body["data"] as? [String: Any] ?? body
            let raw = (data["user"] as? [String: Any]) ?? (body["user"] as? [String: Any])
                ?? (json["user"] as? [String: Any]) ?? [:]
            if let account = Self.account(from: raw, fallback: stored) { return account }
        }
        return Account(
            userId: stored.uid,
            provider: .bodian,
            nickname: stored.nickname ?? "波点账号",
            avatarUrl: stored.avatar,
            vipType: nil
        )
    }

    private static func account(from raw: [String: Any], fallback: StoredSession) -> Account? {
        guard !raw.isEmpty else { return nil }
        let id = stringValue(raw["id"]) ?? stringValue(raw["uid"]) ?? stringValue(raw["userId"]) ?? fallback.uid
        guard !id.isEmpty else { return nil }
        let nickname = (raw["nickname"] as? String) ?? (raw["nickName"] as? String)
            ?? (raw["name"] as? String) ?? fallback.nickname ?? "波点账号"
        let avatar = (raw["avatar"] as? String) ?? (raw["avatarUrl"] as? String)
            ?? (raw["headImg"] as? String) ?? (raw["pic"] as? String) ?? fallback.avatar
        let vip = intValue(raw["vipType"]) ?? intValue(raw["vip_type"])
            ?? intValue(raw["isVip"]) ?? intValue(raw["vip"])
        return Account(
            userId: id,
            provider: .bodian,
            nickname: nickname,
            avatarUrl: avatar,
            vipType: vip
        )
    }

    func signOut() async {
        _ = try? await send(.logout)
        save(nil)
    }

    // MARK: - 扫码登录

    /// 取一个二维码 key
    func qrKey() async throws -> String {
        let json = try await send(.qrKey)
        guard let key = Self.qrKeyValue(json) else {
            throw APIError(code: nil, message: "没有拿到二维码 key")
        }
        return key
    }

    private static func qrKeyValue(_ json: [String: Any]) -> String? {
        let body = payload(json)
        let data = body["data"] as? [String: Any] ?? body
        for source in [data, body] {
            for key in ["key", "qrKey", "qr_key", "unikey", "ticket"] {
                if let value = stringValue(source[key]), !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// 取二维码图片地址（`qr_create` 只回 `{ imageUrl }`）
    func qrImage(key: String) async throws -> String {
        let json = try await send(.qrCreate, params: ["key": key])
        let body = Self.payload(json)
        let data = body["data"] as? [String: Any] ?? body
        for source in [data, body] {
            for name in ["imageUrl", "image", "url", "qrimg", "base64"] {
                if let value = source[name] as? String, !value.isEmpty { return value }
            }
        }
        throw APIError(code: nil, message: "没有拿到二维码")
    }

    enum QRState {
        case waiting
        case scanned
        case confirmed
        case expired
        case failed(String)
    }

    private var lastQRCodeValue = 0
    func lastQRCode() -> Int { lastQRCodeValue }

    /// 轮询：`{ state: 'waiting' | 'scanned' | 'confirmed' | 'expired', body: { session: { uid, token } } }`
    func checkQR(key: String) async -> QRState {
        guard let json = try? await send(.qrCheck, params: ["key": key]) else {
            return .failed("网络异常，稍后重试")
        }
        let body = Self.payload(json)
        let state = ((json["state"] as? String) ?? (body["state"] as? String)
            ?? (json["status"] as? String) ?? "").lowercased()
        lastQRCodeValue = 0

        switch state {
        case "confirmed", "success", "ok":
            let session = Self.sessionValue(body) ?? Self.sessionValue(json)
            if let session {
                save(StoredSession(uid: session.uid, token: session.token,
                                   nickname: session.nickname, avatar: session.avatar))
                return .confirmed
            }
            return .failed("登录成功但没有拿到登录状态")
        case "scanned", "scan", "scaning", "scanning":
            return .scanned
        case "expired", "timeout", "invalid":
            return .expired
        case "waiting", "pending", "new", "":
            return .waiting
        default:
            let message = (json["message"] as? String) ?? (body["message"] as? String) ?? state
            return .failed("登录没有成功：\(message)")
        }
    }

    private static func sessionValue(_ json: [String: Any])
        -> (uid: String, token: String, nickname: String?, avatar: String?)? {
        let data = json["data"] as? [String: Any] ?? [:]
        let candidates: [[String: Any]] = [
            json["session"] as? [String: Any] ?? [:],
            data["session"] as? [String: Any] ?? [:],
        ]
        for raw in candidates where !raw.isEmpty {
            guard let uid = stringValue(raw["uid"]) ?? stringValue(raw["id"]),
                  let token = stringValue(raw["token"]), !uid.isEmpty, !token.isEmpty else { continue }
            let user = raw["user"] as? [String: Any] ?? [:]
            let nickname = (user["nickname"] as? String) ?? (raw["nickname"] as? String)
            let avatar = (user["avatar"] as? String) ?? (raw["avatar"] as? String)
            return (uid, token, nickname, avatar)
        }
        return nil
    }

    func cancelQR(key: String) async {
        _ = key
    }

    // MARK: - 曲库

    func userPlaylists(userId: String) async throws -> [MusicCollection] {
        var result: [MusicCollection] = []
        var seen = Set<String>()
        func append(_ list: [[String: Any]], owned: Bool) {
            for (index, item) in list.enumerated() {
                guard let collection = Self.collection(
                    from: item, owned: owned, fallbackId: "bodian-\(owned ? "own" : "col")-\(index)"
                ) else { continue }
                if seen.insert(collection.idString).inserted {
                    result.append(collection)
                }
            }
        }

        // 第一页同时带 liked 与 owned
        let first = try await send(.userPlaylists, params: ["limit": "100", "offset": "0"])
        let data = Self.payload(first)["data"] as? [String: Any]
            ?? Self.payload(first)
        if let liked = data["liked"] as? [String: Any], let collection = Self.likedCollection(from: liked) {
            seen.insert(collection.idString)
            result.append(collection)
        }
        let owned = (data["owned"] as? [String: Any])?["playLists"] as? [[String: Any]] ?? []
        append(owned, owned: true)

        // 之后翻收藏的歌单
        let collectedMeta = data["collected"] as? [String: Any] ?? [:]
        let collected = collectedMeta["playLists"] as? [[String: Any]] ?? []
        append(collected, owned: false)

        var offset = 100
        var total = intValue(collectedMeta["total"]) ?? collected.count
        let pageSize = 100
        while offset < total && offset <= 3000 {
            let json = try await send(.userPlaylists, params: [
                "limit": String(pageSize), "offset": String(offset),
            ])
            let pageData = Self.payload(json)["data"] as? [String: Any] ?? Self.payload(json)
            let meta = pageData["collected"] as? [String: Any] ?? [:]
            let page = meta["playLists"] as? [[String: Any]] ?? []
            if page.isEmpty { break }
            append(page, owned: false)
            if let next = intValue(meta["total"]) { total = next }
            if page.count < pageSize { break }
            offset += pageSize
        }
        return result
    }

    /// 我喜欢
    func likedSongs() async throws -> [Song] {
        let json = try await send(.likedSongs, params: ["limit": "100", "offset": "0"])
        return Self.list(from: json, keys: ["list", "songs", "musics"]).compactMap(Self.song)
    }

    func playlistTracks(id: String) async throws -> [Song] {
        // AI 歌单（首页发现位）的 id 形如 `discover-3`
        if id.hasPrefix("discover-") {
            let index = String(id.dropFirst("discover-".count))
            let json = try await send(.aiPlaylistDetail, params: ["index": index])
            let data = Self.payload(json)["data"] as? [String: Any] ?? Self.payload(json)
            let list = data["musicList"] as? [[String: Any]]
                ?? data["list"] as? [[String: Any]] ?? []
            return list.compactMap(Self.song)
        }
        if id == "liked" || id.hasPrefix("liked") {
            return try await likedSongs()
        }
        // own = 5，收藏 = 4
        let source = id.hasPrefix("own-") ? "5" : "4"
        let realId = id.hasPrefix("own-") ? String(id.dropFirst("own-".count)) : id
        let json = try await send(.playlistTracks, params: ["id": realId, "source": source])
        return Self.list(from: json, keys: ["list", "songs", "musics"]).compactMap(Self.song)
    }

    func album(id: String) async throws -> [Song] {
        let json = try await send(.albumTracks, params: ["id": id])
        return Self.list(from: json, keys: ["list", "songs", "musics"]).compactMap(Self.song)
    }

    func artistSongs(id: String, limit: Int = 50, offset: Int = 0) async throws -> [Song] {
        let json = try await send(.artistSongs, params: [
            "id": id, "limit": String(min(max(limit, 1), 100)), "offset": String(max(offset, 0)),
        ])
        return Self.list(from: json, keys: ["list", "songs"]).compactMap(Self.song)
    }

    func artistAlbums(id: String, limit: Int = 30, offset: Int = 0) async throws -> [MusicCollection] {
        let json = try await send(.artistAlbums, params: [
            "id": id, "limit": String(min(max(limit, 1), 100)), "offset": String(max(offset, 0)),
        ])
        return Self.list(from: json, keys: ["list", "albums"]).enumerated().compactMap { index, item in
            Self.collection(from: item, type: .album, owned: false, fallbackId: "bodian-album-\(index)")
        }
    }

    func search(_ keywords: String, limit: Int = 50, offset: Int = 0) async throws -> [Song] {
        let keyword = String(keywords.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let json = try await send(.search, params: [
            "query": keyword,
            "limit": String(min(max(limit, 1), 100)),
            "offset": String(max(offset, 0)),
        ])
        return Self.list(from: json, keys: ["resultList", "list", "songs"]).compactMap(Self.song)
    }

    // MARK: - 播放地址

    private static func qualityValue(_ quality: String) -> String {
        switch quality {
        case "standard": return "128k"
        case "lossless", "hires": return "flac"
        case "ultra": return "320k"
        default: return "320k"
        }
    }

    private static func qualityChain(_ quality: String) -> [String] {
        switch quality {
        case "hires": return ["flac", "320k", "128k"]
        case "lossless": return ["flac", "320k", "128k"]
        case "high", "ultra": return ["320k", "128k"]
        default: return ["128k"]
        }
    }

    func audio(for song: Song, quality: String = "high") async throws -> (url: URL, isPreview: Bool) {
        let freeSign = Self.freeSign(of: song.id)
        let realId = Self.songIdPart(song.id)
        var lastError: Error?
        for level in Self.qualityChain(quality) {
            var params = ["id": realId, "quality": level]
            if let freeSign { params["freeSign"] = freeSign }
            do {
                let json = try await send(.audio, params: params)
                if let found = Self.audioURL(from: json) {
                    return (url: found.url, isPreview: found.preview)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError(code: nil, message: "这首歌暂时没有可播放的音源")
    }

    /// song.id 可能带 `#<freeSign>` 尾巴（收藏页里的免费标识）
    private static func songIdPart(_ id: String) -> String {
        id.components(separatedBy: "#").first ?? id
    }

    private static func freeSign(of id: String) -> String? {
        let pieces = id.components(separatedBy: "#")
        guard pieces.count > 1, !pieces[1].isEmpty else { return nil }
        return pieces[1]
    }

    private static func audioURL(from json: [String: Any]) -> (url: URL, preview: Bool)? {
        let body = payload(json)
        let data = body["data"] as? [String: Any] ?? body
        var text: String?
        for key in ["url", "playUrl", "play_url", "src"] {
            if let value = data[key] as? String, !value.isEmpty { text = value; break }
        }
        if text == nil, let list = data["list"] as? [[String: Any]] {
            for item in list {
                for key in ["url", "playUrl", "play_url", "src"] {
                    if let value = item[key] as? String, !value.isEmpty { text = value; break }
                }
                if text != nil { break }
            }
        }
        guard let text, let url = httpsURL(text) else { return nil }
        let preview = (data["preview"] as? Bool) ?? (body["preview"] as? Bool) ?? false
        return (url, preview)
    }

    // MARK: - 歌词

    func lyrics(for song: Song) async throws -> [LyricLine] {
        let json = try await send(.lyrics, params: ["id": Self.songIdPart(song.id)])
        let body = Self.payload(json)
        let data = body["data"] as? [String: Any] ?? body
        // 优先逐字（awlrc），没有就整行
        let word = (data["wordByWordText"] as? String) ?? (body["wordByWordText"] as? String)
        let main = (data["mainText"] as? String) ?? (body["mainText"] as? String)
        let text = (word?.isEmpty == false ? word : main) ?? ""
        guard !text.isEmpty else { return [] }
        return LyricParser.parse(text)
    }

    // MARK: - JSON → 模型

    /// 对齐 bodianNormalize.ts 的 normalizeBodianSong
    static func song(from raw: [String: Any]) -> Song? {
        guard let rawId = stringValue(raw["id"]) ?? stringValue(raw["rid"]) ?? stringValue(raw["songId"]),
              !rawId.isEmpty else { return nil }

        let freeSign = stringValue(raw["freeSign"]) ?? stringValue(raw["fsig"])
        let id = freeSign.map { "\(rawId)#\($0)" } ?? rawId

        let title = (raw["songName"] as? String) ?? (raw["name"] as? String)
            ?? (raw["title"] as? String) ?? "未知歌曲"

        var artists: [Artist] = []
        if let list = raw["artists"] as? [[String: Any]] {
            artists = list.compactMap { item in
                guard let name = (item["name"] as? String) ?? (item["artist"] as? String),
                      !name.isEmpty else { return nil }
                let artistId = stringValue(item["id"]) ?? stringValue(item["artistId"]) ?? name
                return Artist(id: artistId, name: name)
            }
        }
        if artists.isEmpty, let single = (raw["artist"] as? String) ?? (raw["singer"] as? String),
           !single.isEmpty {
            let names = single.components(separatedBy: CharacterSet(charactersIn: "、&/"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            artists = names.enumerated().map { Artist(id: "\($0.offset)", name: $0.element) }
        }

        let albumId = stringValue(raw["albumId"]) ?? stringValue(raw["album_id"]) ?? ""
        let albumName = (raw["album"] as? String) ?? (raw["albumName"] as? String) ?? ""
        var cover = (raw["albumPic"] as? String) ?? (raw["pic"] as? String) ?? (raw["cover"] as? String)
        if let value = cover, value.hasPrefix("http://") {
            cover = "https://" + value.dropFirst("http://".count)
        }

        // 波点给的 duration 是秒
        let duration = normalizeDurationMs(raw["duration"] ?? raw["durationMs"] ?? raw["length"])

        return Song(
            id: id,
            provider: .bodian,
            name: title,
            artists: artists,
            album: Album(id: albumId, name: albumName, coverUrl: cover),
            durationMs: duration,
            isCloud: false,
            fee: nil,
            st: nil
        )
    }

    /// 对齐 bodianNormalize.ts 的 normalizeBodianCollection
    private static func collection(
        from raw: [String: Any],
        type: CollectionKind = .playlist,
        owned: Bool = false,
        fallbackId: String
    ) -> MusicCollection? {
        let isAlbum = type == .album || raw["album"] != nil
        let name = (raw["name"] as? String) ?? (raw["title"] as? String) ?? ""
        guard !name.isEmpty else { return nil }

        let rawId = stringValue(raw["albumId"]) ?? stringValue(raw["id"]) ?? fallbackId
        guard !rawId.isEmpty else { return nil }

        let kind: CollectionKind = isAlbum ? .album : .playlist

        // 自己的歌单与收藏走不同的 source，用前缀区分
        let id = isAlbum ? rawId : (owned ? "own-\(rawId)" : rawId)

        var pic = (raw["pic"] as? String) ?? (raw["cover"] as? String) ?? (raw["albumPic"] as? String)
        if let value = pic, value.hasPrefix("http://") {
            pic = "https://" + value.dropFirst("http://".count)
        }

        return MusicCollection(
            id: id,
            provider: .bodian,
            name: name,
            kind: kind,
            coverUrl: pic,
            description: (raw["description"] as? String) ?? (raw["info"] as? String)
                ?? (raw["desc"] as? String),
            trackCount: intValue(raw["musicCount"]) ?? intValue(raw["musicCnt"])
                ?? intValue(raw["count"]),
            isLiked: false,
            creatorName: (raw["creatorName"] as? String) ?? (raw["nickname"] as? String)
        )
    }

    private static func likedCollection(from raw: [String: Any]) -> MusicCollection? {
        let count = intValue(raw["musicCount"]) ?? intValue(raw["count"]) ?? intValue(raw["total"])
        return MusicCollection(
            id: "liked",
            provider: .bodian,
            name: (raw["name"] as? String) ?? "我喜欢",
            kind: .playlist,
            coverUrl: (raw["pic"] as? String) ?? (raw["cover"] as? String),
            description: nil,
            trackCount: count,
            isLiked: true,
            creatorName: nil
        )
    }
}
