import Foundation
import CommonCrypto

/// 酷狗音乐。对齐原版 `src/services/onlineMusic/kugou/kugouTransport.ts` + `kugouProvider.ts`：
///
/// - 走自建代理 `https://app.folia-api.top/api/kugou`
/// - 每个请求都带 `?cookie=token=..; userid=..; dfid=..&timestamp=<ms>`
/// - 代理回 `{ status, body }`，真正的数据在 `body` 里（也可能只回 `data`）
/// - 需要设备校验时（errcode 20028）清掉 dfid 走一次 `register/dev` 再重试
/// - 搜索在没有登录态时可以直接打 `complexsearch.kugou.com`，签名是 md5
actor KugouAPI {
    static let shared = KugouAPI()

    private let base = "https://app.folia-api.top/api/kugou"
    private let session: URLSession

    /// 登录态：`token` / `userid` / `dfid` 三段拼成 cookie 串
    private var token: String? {
        didSet { Keychain.set(token, for: Self.tokenKey) }
    }
    private var userId: String? {
        didSet { Keychain.set(userId, for: Self.userIdKey) }
    }
    private var dfid: String? {
        didSet { Keychain.set(dfid, for: Self.dfidKey) }
    }

    private static let tokenKey = "folia.kugou.token"
    private static let userIdKey = "folia.kugou.userid"
    private static let dfidKey = "folia.kugou.dfid"

    private init() {
        session = foliaURLSession()
        token = Keychain.get(Self.tokenKey)
        userId = Keychain.get(Self.userIdKey)
        dfid = Keychain.get(Self.dfidKey)
    }

    var isSignedIn: Bool { token != nil && !(token ?? "").isEmpty }

    // MARK: - 基础请求

    struct APIError: LocalizedError {
        let code: Int?
        let message: String
        var errorDescription: String? { message }
    }

    private enum Route: String {
        case registerDev = "/register/dev"
        case loginQRKey = "/login/qr/key"
        case loginQRCreate = "/login/qr/create"
        case loginQRCheck = "/login/qr/check"
        case logout = "/logout"
        case userDetail = "/user/detail"
        case userVipDetail = "/user/vip/detail"
        case youthUnionVip = "/youth/union/vip"
        case youthDayVip = "/youth/day/vip"
        case userPlaylist = "/user/playlist"
        case userCloud = "/user/cloud"
        case search = "/search"
        case songURL = "/song/url"
        case searchLyric = "/search/lyric"
        case lyric = "/lyric"
        case playlistTrackAll = "/playlist/track/all"
        case playlistDetail = "/playlist/detail"
        case albumDetail = "/album/detail"
        case albumSongs = "/album/songs"
        case artistDetail = "/artist/detail"
        case artistAlbums = "/artist/albums"
        case artistAudios = "/artist/audios"
    }

    /// 拼当前 cookie：只有登录后才带 token，dfid 是设备号（匿名也带）
    private var cookieString: String {
        var pieces: [String] = []
        if let token, !token.isEmpty { pieces.append("token=\(token)") }
        if let userId, !userId.isEmpty { pieces.append("userid=\(userId)") }
        if let dfid, !dfid.isEmpty { pieces.append("dfid=\(dfid)") }
        return pieces.joined(separator: "; ")
    }

    /// 发一个请求，返回解包后的 body。`retryDevice` 用来处理一次设备校验。
    @discardableResult
    private func send(
        _ route: Route,
        query: [String: String] = [:],
        method: String = "GET",
        retryDevice: Bool = true
    ) async throws -> [String: Any] {
        guard var components = URLComponents(string: base + route.rawValue) else {
            throw APIError(code: nil, message: "bad route \(route.rawValue)")
        }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let cookie = cookieString
        if !cookie.isEmpty {
            items.append(URLQueryItem(name: "cookie", value: cookie))
        }
        items.append(URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        components.queryItems = items
        guard let url = components.url else {
            throw APIError(code: nil, message: "bad url for \(route.rawValue)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("https://app.folia-api.top", forHTTPHeaderField: "Referer")
        request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: nil, message: "no response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            clearSession()
            throw APIError(code: http.statusCode, message: "登录已失效，请重新扫码")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw APIError(code: http.statusCode, message: "HTTP \(http.statusCode) \(text)")
        }
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: nil, message: "返回的不是 JSON")
        }
        let payload = Self.unwrap(raw)
        persistSession(from: payload)

        if retryDevice, Self.needsDeviceVerification(payload) {
            clearDeviceIdentity()
            try? await send(.registerDev, retryDevice: false)
            return try await send(route, query: query, method: method, retryDevice: false)
        }
        return payload
    }

    /// 代理把数据包在 `body`（或 `data`）里
    private static func unwrap(_ raw: [String: Any]) -> [String: Any] {
        if let body = raw["body"] as? [String: Any] { return body }
        if let data = raw["data"] as? [String: Any] { return data }
        return raw
    }

    /// 上游登录成功会把 session 塞回响应里
    private func persistSession(from payload: [String: Any]) {
        let data = payload["data"] as? [String: Any]
        let cookie = (payload["cookie"] as? String) ?? (data?["cookie"] as? String)
        if let cookie, !cookie.isEmpty {
            for piece in cookie.split(separator: ";") {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("token=") {
                    token = String(trimmed.dropFirst("token=".count))
                } else if trimmed.hasPrefix("userid=") {
                    userId = String(trimmed.dropFirst("userid=".count))
                } else if trimmed.hasPrefix("dfid=") {
                    dfid = String(trimmed.dropFirst("dfid=".count))
                }
            }
        }
        if let value = stringValue(payload["token"]) ?? stringValue(data?["token"]), !value.isEmpty {
            token = value
        }
        if let value = stringValue(payload["userid"]) ?? stringValue(payload["user_id"])
            ?? stringValue(data?["userid"]) ?? stringValue(data?["user_id"]), !value.isEmpty {
            userId = value
        }
        if let value = stringValue(payload["dfid"]) ?? stringValue(data?["dfid"]), !value.isEmpty {
            dfid = value
        }
    }

    private static func needsDeviceVerification(_ json: [String: Any]) -> Bool {
        let code = intValue(json["errcode"]) ?? intValue(json["error_code"])
        if code == 20028 { return true }
        let message = (json["error"] as? String) ?? (json["message"] as? String) ?? ""
        return message.contains("本次请求需要验证")
    }

    private func clearDeviceIdentity() {
        dfid = nil
    }

    private func clearSession() {
        token = nil
        userId = nil
        dfid = nil
    }

    // MARK: - 账号

    func currentAccount() async throws -> Account? {
        guard let userId, !userId.isEmpty, isSignedIn else { return nil }
        guard let json = try? await send(.userDetail, query: ["userid": userId]) else { return nil }
        guard let user = Self.user(from: json), let nickname = user.nickname, !nickname.isEmpty else {
            clearSession()
            return nil
        }
        var vipType = Self.vipType(from: json)
        for route in [Route.youthUnionVip, .youthDayVip] {
            if vipType != nil, vipType ?? 0 > 0 { break }
            if let extra = try? await send(route, query: ["userid": userId]) {
                vipType = vipType ?? Self.vipType(from: extra)
            }
        }
        if vipType == nil, let extra = try? await send(.userVipDetail, query: ["userid": userId]) {
            vipType = Self.vipType(from: extra)
        }
        return Account(
            userId: user.id ?? userId,
            provider: .kugou,
            nickname: nickname,
            avatarUrl: user.avatar,
            vipType: vipType
        )
    }

    private static func user(from json: [String: Any]) -> (id: String?, nickname: String?, avatar: String?)? {
        let sources: [[String: Any]] = [
            json["user_info"] as? [String: Any] ?? [:],
            json["userinfo"] as? [String: Any] ?? [:],
            json["profile"] as? [String: Any] ?? [:],
            json["data"] as? [String: Any] ?? [:],
            json,
        ]
        for raw in sources where !raw.isEmpty {
            let id = stringValue(raw["userid"]) ?? stringValue(raw["user_id"])
                ?? stringValue(raw["id"]) ?? stringValue(raw["uid"])
            let nickname = (raw["nickname"] as? String) ?? (raw["nick_name"] as? String)
                ?? (raw["username"] as? String) ?? (raw["name"] as? String)
            let avatar = (raw["avatarUrl"] as? String) ?? (raw["avatar"] as? String)
                ?? (raw["pic"] as? String)
            if id != nil || nickname != nil {
                return (id, nickname, avatar)
            }
        }
        return nil
    }

    private static func vipType(from json: [String: Any]) -> Int? {
        let data = json["data"] as? [String: Any] ?? json
        if let value = intValue(data["vip_type"]) ?? intValue(data["vipType"]) { return value }
        if let flag = data["is_vip"] as? Bool { return flag ? 1 : 0 }
        if let list = data["busi_vip"] as? [[String: Any]] {
            for item in list {
                if (item["is_vip"] as? Bool) == true { return 1 }
            }
        }
        return nil
    }

    func signOut() async {
        _ = try? await send(.logout)
        clearSession()
    }

    // MARK: - 扫码登录

    func qrKey() async throws -> String {
        let json = try await send(.loginQRKey)
        let data = json["data"] as? [String: Any] ?? json
        guard let key = (data["qrcode"] as? String) ?? (data["qrkey"] as? String)
            ?? (data["key"] as? String) ?? (data["ticket"] as? String), !key.isEmpty else {
            throw APIError(code: nil, message: "没有拿到二维码 key")
        }
        return key
    }

    func qrImage(key: String) async throws -> String {
        let json = try await send(.loginQRCreate, query: ["key": key, "qrimg": "true"])
        let data = json["data"] as? [String: Any] ?? json
        guard let image = (data["base64"] as? String) ?? (data["qrimg"] as? String)
            ?? (data["qrcode"] as? String) ?? (data["url"] as? String), !image.isEmpty else {
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

    private var lastQRCodeValue = 0
    func lastQRCode() -> Int { lastQRCodeValue }

    func checkQR(key: String) async -> QRState {
        guard let json = try? await send(.loginQRCheck, query: ["key": key, "qrcode": key]) else {
            return .failed("网络异常，稍后重试")
        }
        let data = json["data"] as? [String: Any] ?? [:]
        let status = intValue(json["status"]) ?? intValue(data["status"])
            ?? intValue(json["code"]) ?? intValue(data["code"]) ?? 0
        lastQRCodeValue = status
        switch status {
        case 0: return .expired
        case 1: return .waiting
        case 2, 3: return .scanned
        case 4: return .confirmed
        default:
            // 有的版本直接把 token 放在 data 里算登录成功
            if let token = stringValue(data["token"]) ?? stringValue(json["token"]), !token.isEmpty {
                self.token = token
                return .confirmed
            }
            let message = (json["message"] as? String) ?? (json["error"] as? String) ?? "未知错误"
            return .failed("code \(status): \(message)")
        }
    }

    func cancelQR(key: String) async {
        _ = try? await send(.logout, query: ["key": key])
    }

    // MARK: - 曲库

    func userPlaylists(userId: String) async throws -> [MusicCollection] {
        guard !userId.isEmpty else { return [] }
        let json = try await send(.userPlaylist, query: [
            "userid": userId, "page": "1", "pagesize": "200",
        ])
        let raw = Self.list(from: json, keys: ["info", "list", "playlists", "data"])
        var result: [MusicCollection] = []
        for (index, item) in raw.enumerated() {
            // 「我喜欢」在某些返回里没有 global_collection_id，先看有没有标志
            if let collection = Self.collection(from: item, fallbackId: "kugou-list-\(index)") {
                result.append(collection)
            }
        }
        return result
    }

    func playlistTracks(id: String) async throws -> [Song] {
        // 「我喜欢」的 id 形如 `liked:<globalCollectionId>`
        let realId = id.hasPrefix("liked:") ? String(id.dropFirst("liked:".count)) : id
        var all: [Song] = []
        var page = 1
        while page <= 200 {
            let json = try await send(.playlistTrackAll, query: [
                "id": realId, "page": String(page), "pagesize": "100",
            ])
            let songs = Self.list(from: json, keys: ["songs", "audios", "list", "info"])
                .compactMap(Self.song)
            all += songs
            if songs.count < 100 { break }
            page += 1
        }
        return all
    }

    func album(id: String) async throws -> [Song] {
        var all: [Song] = []
        var page = 1
        while page <= 50 {
            let json = try await send(.albumSongs, query: [
                "id": id, "page": String(page), "pagesize": "30",
            ])
            let songs = Self.list(from: json, keys: ["songs", "audios", "list", "info"])
                .compactMap(Self.song)
            all += songs
            if songs.count < 30 { break }
            page += 1
        }
        return all
    }

    func artistSongs(id: String, limit: Int = 50, page: Int = 1) async throws -> [Song] {
        let json = try await send(.artistAudios, query: [
            "id": id, "page": String(page), "pagesize": String(limit),
        ])
        return Self.list(from: json, keys: ["songs", "audios", "list"]).compactMap(Self.song)
    }

    func artistAlbums(id: String, limit: Int = 30, page: Int = 1) async throws -> [MusicCollection] {
        let json = try await send(.artistAlbums, query: [
            "id": id, "page": String(page), "pagesize": String(limit),
        ])
        return Self.list(from: json, keys: ["albums", "list", "info"]).compactMap { item in
            Self.collection(from: item, type: .album, owned: false, fallbackId: nil)
        }
    }

    func search(_ keywords: String, limit: Int = 50, offset: Int = 0) async throws -> [Song] {
        let keyword = String(keywords.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let pageSize = max(1, min(limit, 50))
        let page = offset / pageSize + 1

        if isSignedIn, let json = try? await send(.search, query: [
            "keywords": keyword, "keyword": keyword, "type": "song",
            "page": String(page), "pagesize": String(pageSize),
        ]) {
            let songs = Self.list(from: json, keys: ["songs", "lists", "data", "list"]).compactMap(Self.song)
            if !songs.isEmpty { return songs }
        }
        return try await searchAnonymous(keyword, pageSize: pageSize, page: page)
    }

    /// 匿名搜索：直接打 complexsearch，签名是固定的 md5（salt + 排序后的 k=v 串）
    private func searchAnonymous(_ keyword: String, pageSize: Int, page: Int) async throws -> [Song] {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let seconds = ms / 1000
        let mid = Self.md5(String(ms))
        var params: [String: String] = [
            "sorttype": "0",
            "keyword": keyword,
            "pagesize": String(pageSize),
            "page": String(page),
            "userid": "0",
            "appid": "3116",
            "token": "",
            "clienttime": String(seconds),
            "iscorrection": "1",
            "uuid": "-",
            "mid": mid,
            "dfid": "-",
            "clientver": "11070",
            "platform": "AndroidFilter",
        ]
        let salt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
        let source = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        params["signature"] = Self.md5(salt + source + salt)

        guard var components = URLComponents(string: "https://complexsearch.kugou.com/v2/search/song") else {
            throw APIError(code: nil, message: "bad search url")
        }
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw APIError(code: nil, message: "bad search url")
        }
        var request = URLRequest(url: url)
        request.setValue("Android14-1070-11070-201-0-SearchSong-wifi", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "KG-Rec")
        request.setValue("1", forHTTPHeaderField: "KG-RC")
        request.setValue(String(ms), forHTTPHeaderField: "KG-CLIENTTIMEMS")
        request.setValue(mid, forHTTPHeaderField: "mid")
        request.setValue("complexsearch.kugou.com", forHTTPHeaderField: "x-router")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: nil, message: "搜索返回异常")
        }
        let errorCode = intValue(json["error_code"]) ?? 0
        guard errorCode == 0 || errorCode == 200 else {
            throw APIError(code: errorCode, message: "搜索失败")
        }
        return Self.list(from: json, keys: ["lists", "songs", "data"]).compactMap(Self.song)
    }

    // MARK: - 播放地址

    private static func qualityValue(_ quality: String) -> String {
        switch quality {
        case "lossless": return "flac"
        case "hires": return "high"
        case "ultra": return "320"
        case "standard": return "128"
        default: return "320"
        }
    }

    private static func qualityChain(_ quality: String) -> [String] {
        switch quality {
        case "hires": return ["high", "flac", "320", "128"]
        case "lossless": return ["flac", "320", "128"]
        case "high", "ultra": return ["320", "128"]
        default: return ["128"]
        }
    }

    func audio(for song: Song, quality: String = "high") async throws -> (url: URL, isPreview: Bool) {
        // 酷狗的播放地址要用 hash，song.id 就是 hash
        let hash = song.id
        let albumId = stringValue(song.album.id) ?? ""

        for level in Self.qualityChain(quality) {
            var query = ["hash": hash, "quality": level]
            if !albumId.isEmpty { query["album_id"] = albumId }
            if let json = try? await send(.songURL, query: query),
               let text = Self.audioURL(from: json),
               let url = httpsURL(text) {
                return (url, false)
            }
            // 带专辑信息失败时再只带 hash 试一次
            if !albumId.isEmpty,
               let json = try? await send(.songURL, query: ["hash": hash, "quality": level]),
               let text = Self.audioURL(from: json),
               let url = httpsURL(text) {
                return (url, false)
            }
        }

        // 最后兜底打一次移动端老接口
        if let url = await Self.legacyAudioURL(hash: hash, session: session) {
            return (url, false)
        }
        throw APIError(code: nil, message: "这首歌暂时没有可播放的音源")
    }

    private static func audioURL(from json: [String: Any]) -> String? {
        var candidates: [String] = []
        if let list = json["data"] as? [[String: Any]] {
            for item in list {
                for key in ["play_url", "playUrl", "url"] {
                    if let text = item[key] as? String { candidates.append(text) }
                }
            }
        }
        if let data = json["data"] as? [String: Any] {
            for key in ["play_url", "playUrl", "url"] {
                if let text = data[key] as? String { candidates.append(text) }
            }
        }
        for key in ["play_url", "playUrl", "url"] {
            if let text = json[key] as? String { candidates.append(text) }
        }
        for raw in candidates {
            // 有时会回 "http://a, http://b" 形式的多个地址
            for piece in raw.components(separatedBy: ",") {
                let text = piece.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("http://") || text.hasPrefix("https://") { return text }
            }
        }
        return nil
    }

    private static func legacyAudioURL(hash: String, session: URLSession) async -> URL? {
        guard let url = URL(string: "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=\(hash)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let text = (json["url"] as? String) ?? (json["backup_url"] as? String)
        return text.flatMap(httpsURL)
    }

    // MARK: - 歌词

    func lyrics(for song: Song) async throws -> [LyricLine] {
        let hash = song.id
        var searchQuery = ["hash": hash, "duration": String(song.durationMs), "man": "no"]
        if !song.album.id.isEmpty { searchQuery["album_audio_id"] = song.album.id }
        let found = try await send(.searchLyric, query: searchQuery)
        let candidates = Self.list(from: found, keys: ["candidates", "list", "data"])
        guard let first = candidates.first ?? Self.list(from: found, keys: ["songs"]).first,
              let lyricId = stringValue(first["id"]) ?? stringValue(first["lyric_id"]),
              let accessKey = stringValue(first["accesskey"]) ?? stringValue(first["access_key"]) else {
            return []
        }
        let json = try await send(.lyric, query: [
            "id": lyricId, "accesskey": accessKey, "fmt": "krc", "decode": "true",
        ])
        let data = json["data"] as? [String: Any] ?? json
        let content = (data["decodeContent"] as? String) ?? (data["lyric"] as? String)
            ?? (data["content"] as? String) ?? ""
        guard !content.isEmpty else { return [] }
        return LyricParser.parse(content)
    }

    // MARK: - 工具

    private static func md5(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 兼容 `{ key: [...] }` / `{ data: { key: [...] } }`
    private static func list(from json: [String: Any], keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let list = json[key] as? [[String: Any]], !list.isEmpty { return list }
        }
        for key in keys {
            if let data = json["data"] as? [String: Any], let list = data[key] as? [[String: Any]] {
                return list
            }
        }
        for key in keys {
            if let data = json["info"] as? [String: Any], let list = data[key] as? [[String: Any]] {
                return list
            }
        }
        for key in keys {
            if let list = json[key] as? [[String: Any]] { return list }
        }
        return []
    }

    // MARK: - JSON → 模型

    private static func cover(of raw: [String: Any]) -> String? {
        let albumInfo = raw["album_info"] as? [String: Any]
        let audioInfo = raw["audio_info"] as? [String: Any]
        let trans = audioInfo?["trans_param"] as? [String: Any]
            ?? raw["trans_param"] as? [String: Any]
        var cover = (albumInfo?["sizable_cover"] as? String) ?? (albumInfo?["cover"] as? String)
            ?? (trans?["union_cover"] as? String)
            ?? (raw["sizable_cover"] as? String) ?? (raw["Image"] as? String)
            ?? (raw["image"] as? String) ?? (raw["img"] as? String)
            ?? (raw["pic"] as? String) ?? (raw["picUrl"] as? String)
            ?? (raw["cover"] as? String) ?? (raw["coverUrl"] as? String)
            ?? (raw["sizable_avatar"] as? String)
        guard var cover = cover else { return nil }
        if cover.contains("{size}") {
            cover = cover.replacingOccurrences(of: "{size}", with: "1024")
        }
        // 只给了文件名时拼回 kgimg 的路径
        if cover.range(of: "^\\d{8,}\\.(jpe?g|png|webp)$", options: [.regularExpression, .caseInsensitive]) != nil {
            let prefix = String(cover.prefix(8))
            cover = "https://c1.kgimg.com/stdmusic/1024/\(prefix)/\(cover)"
        }
        if cover.hasPrefix("//") { cover = "https:" + cover }
        return cover
    }

    private static func hashOf(_ raw: [String: Any]) -> String? {
        let audioInfo = raw["audio_info"] as? [String: Any]
        let value = stringValue(raw["FileHash"]) ?? stringValue(raw["fileHash"])
            ?? stringValue(raw["hash"]) ?? stringValue(raw["Hash"])
            ?? stringValue(raw["audio_hash"]) ?? stringValue(raw["audioHash"])
            ?? stringValue(raw["kgHash"])
            ?? stringValue(audioInfo?["hash"]) ?? stringValue(audioInfo?["hash_128"])
        return value?.uppercased()
    }

    /// 对齐 kugouProvider.ts 的 normalizeKugouSong
    static func song(from raw: [String: Any]) -> Song? {
        let base = raw["audio_info"] as? [String: Any] ?? raw
        guard let hash = hashOf(raw) ?? stringValue(raw["id"]), !hash.isEmpty else { return nil }

        let albumRaw = raw["album_info"] as? [String: Any] ?? [:]
        let albumId = stringValue(raw["AlbumID"]) ?? stringValue(raw["album_id"])
            ?? stringValue(albumRaw["album_id"]) ?? stringValue(albumRaw["AlbumID"]) ?? ""
        let albumName = (raw["AlbumName"] as? String) ?? (albumRaw["album_name"] as? String)
            ?? (albumRaw["albumName"] as? String) ?? (raw["album_name"] as? String) ?? ""

        var title = (raw["SongName"] as? String) ?? (raw["songname"] as? String)
            ?? (raw["ori_audio_name"] as? String) ?? (raw["FileName"] as? String)
            ?? (raw["audio_name"] as? String) ?? (base["SongName"] as? String) ?? ""

        let singer = (raw["SingerName"] as? String) ?? (raw["singername"] as? String)
            ?? (raw["author_name"] as? String) ?? (raw["singer_name"] as? String)
            ?? (base["SingerName"] as? String)

        var artists: [Artist] = []
        if let singer, !singer.isEmpty {
            let names = singer.components(separatedBy: CharacterSet(charactersIn: "、&/"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            artists = names.enumerated().map { Artist(id: "\($0.offset)", name: $0.element) }
        }
        // 没有歌手字段时从「歌手 - 歌名」里拆
        if artists.isEmpty, let dash = title.range(of: " - ") {
            let artistPart = String(title[title.startIndex..<dash.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let rest = String(title[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artistPart.isEmpty, !rest.isEmpty {
                title = rest
                artists = artistPart.components(separatedBy: CharacterSet(charactersIn: "、&/"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .enumerated()
                    .map { Artist(id: "\($0.offset)", name: $0.element) }
            }
        }

        let durationRaw = intValue(raw["Duration"]) ?? intValue(raw["duration"])
            ?? intValue(raw["timelength"]) ?? intValue(base["duration"])
        let durationMs = durationRaw.map { $0 > 1000 ? $0 : $0 * 1000 } ?? 0

        return Song(
            id: hash,
            provider: .kugou,
            name: title.isEmpty ? "未知歌曲" : title,
            artists: artists,
            album: Album(id: albumId, name: albumName, coverUrl: cover(of: raw)),
            durationMs: durationMs,
            isCloud: false,
            fee: nil,
            st: nil
        )
    }

    private static func isLiked(_ raw: [String: Any], name: String) -> Bool {
        if name == "我喜欢" || name == "我喜欢的音乐" { return true }
        let listId = intValue(raw["listid"]) ?? intValue(raw["list_id"])
        return listId == 2
    }

    private static func collection(
        from raw: [String: Any],
        type: CollectionKind = .playlist,
        owned: Bool = true,
        fallbackId: String?
    ) -> MusicCollection? {
        let name = (raw["name"] as? String) ?? (raw["listname"] as? String)
            ?? (raw["specialname"] as? String) ?? (raw["album_name"] as? String)
            ?? (raw["author_name"] as? String) ?? ""
        guard !name.isEmpty else { return nil }

        let kind: CollectionKind
        if type == .artist || raw["author_id"] != nil {
            kind = .artist
        } else if type == .album || raw["musiclib_id"] != nil || intValue(raw["type"]) == 2 {
            kind = .album
        } else {
            kind = .playlist
        }

        var id = stringValue(raw["global_collection_id"]) ?? stringValue(raw["globalCollectionId"])
            ?? stringValue(raw["specialid"]) ?? stringValue(raw["specialId"])
        if kind == .album {
            id = stringValue(raw["album_id"]) ?? stringValue(raw["AlbumID"])
                ?? stringValue(raw["albumId"]) ?? stringValue(raw["musiclib_id"])
                ?? stringValue(raw["list_create_listid"]) ?? id
        }
        if kind == .artist {
            id = stringValue(raw["author_id"]) ?? id
        }
        id = id ?? stringValue(raw["id"]) ?? fallbackId

        guard let finalId = id, !finalId.isEmpty else { return nil }

        let liked = kind == .playlist && isLiked(raw, name: name)
        // 「我喜欢」的曲目要打 `liked:` 前缀，用来区分同名普通歌单
        let finalID = liked ? "liked:\(finalId)" : finalId

        return MusicCollection(
            id: finalID,
            provider: .kugou,
            name: name,
            kind: kind,
            coverUrl: cover(of: raw),
            description: (raw["intro"] as? String) ?? (raw["description"] as? String),
            trackCount: intValue(raw["song_count"]) ?? intValue(raw["count"])
                ?? intValue(raw["m_count"]) ?? intValue(raw["total"]) ?? intValue(raw["music_num"]),
            isLiked: liked,
            creatorName: (raw["nickname"] as? String) ?? (raw["author_name"] as? String)
        )
    }
}
