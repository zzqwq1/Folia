import Foundation

/// 直接访问线上 API，等价于原版前端的 fetchWithCreds（src/services/onlineMusic/netease/netease.ts）：
/// 基础地址 https://app.folia-api.top/api/netease，登录态用一个 cookie 字符串走 `?cookie=` 查询参数，
/// 响应体照旧是 { code, data | songs | playlist ... } 的原样 JSON。
///
/// 原版之所以在 iOS 壳里跑一个本地 HTTP 服务器，是因为 WKWebView 里 fetch 有 CORS 与 cookie 限制；
/// 原生 URLSession 没有这两条约束，代理层可以整个去掉。
actor NeteaseAPI {
    static let shared = NeteaseAPI()

    private let base = "https://app.folia-api.top/api/netease"
    /// 纯 weapi 的兜底路由：不依赖家用/服务器隧道，机房 IP 上登录后取账号要用它
    private let nativeBase = "https://app.folia-api.top/api/native/netease"
    private let session: URLSession

    /// 登录态：网易云 `/login/qr/check` 在 803 时回的 cookie 串
    private var signInCookie: String? {
        didSet { Keychain.set(signInCookie, for: Self.cookieKey) }
    }
    /// 未登录时用匿名 cookie 访问公开接口（与前端 anonymous_cookie 一致）
    private var anonymousCookie: String? {
        didSet { UserDefaults.standard.set(anonymousCookie, forKey: Self.anonKey) }
    }

    private static let cookieKey = "folia.netease.cookie"
    private static let anonKey = "folia.netease.anonymousCookie"
    /// 匿名注册失败后的冷却时间，避免每次请求都去打一个已经挂掉的路由
    private var anonRetryAfter: Date?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        signInCookie = Keychain.get(Self.cookieKey)
        anonymousCookie = UserDefaults.standard.string(forKey: Self.anonKey)
    }

    var isSignedIn: Bool { signInCookie != nil }

    func signOut() {
        signInCookie = nil
        anonymousCookie = nil
    }

    // MARK: - 基础请求

    struct APIError: LocalizedError {
        let code: Int?
        let message: String
        var errorDescription: String? { message }
    }

    /// 发一个 GET，返回原始 JSON 对象。`needsTimestamp` 对应原版对 login/user/playlist-detail 的去缓存处理。
    @discardableResult
    func get(
        _ route: String,
        query: [String: String] = [:],
        needsTimestamp: Bool = false,
        allowAnonymous: Bool = true
    ) async throws -> [String: Any] {
        if allowAnonymous, signInCookie == nil, anonymousCookie == nil {
            await registerAnonymous()
        }

        guard var components = URLComponents(string: base + route) else {
            throw APIError(code: nil, message: "bad route \(route)")
        }
        var items = components.queryItems ?? []
        for (key, value) in query {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: value))
        }
        if needsTimestamp {
            items.append(URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        }
        if let cookie = signInCookie ?? (allowAnonymous ? anonymousCookie : nil) {
            items.append(URLQueryItem(name: "cookie", value: cookie))
        }
        items.append(URLQueryItem(name: "realIP", value: "116.25.146.177"))
        components.queryItems = items

        guard let url = components.url else {
            throw APIError(code: nil, message: "bad url for \(route)")
        }
        var request = URLRequest(url: url)
        request.setValue("https://app.folia-api.top", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(code: nil, message: "no response")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw APIError(code: http.statusCode, message: "HTTP \(http.statusCode): \(text)")
        }
        // 上游拒绝时要让它冒出来，而不是当成空列表
        let code = (json["code"] as? NSNumber)?.intValue
        if let code, [301, 401, 403].contains(code), signInCookie != nil {
            throw APIError(code: code, message: json["message"] as? String ?? "登录已失效")
        }
        return json
    }

    /// 直接打原生兜底路由（/api/native/netease），不走隧道、不带匿名 cookie
    private func getNative(_ route: String, query: [String: String] = [:]) async throws -> [String: Any] {
        guard var components = URLComponents(string: nativeBase + route) else {
            throw APIError(code: nil, message: "bad route \(route)")
        }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError(code: nil, message: "bad url for \(route)") }
        var request = URLRequest(url: url)
        request.setValue("https://app.folia-api.top", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(code: nil, message: "no response") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw APIError(code: http.statusCode, message: "HTTP \(http.statusCode): \(text)")
        }
        return json
    }

    /// 匿名 cookie：不登录也能读公开歌单、搜索
    private func registerAnonymous() async {
        // 上游这个路由会间歇性 503（netease backend offline）。失败要退避，
        // 否则每个接口调用都会先白等一次，首页会空着。
        if let until = anonRetryAfter, Date() < until { return }
        guard let url = URL(string: "\(base)/register/anonimous") else { return }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cookie = json["cookie"] as? String, !cookie.isEmpty else {
            anonRetryAfter = Date().addingTimeInterval(120)
            return
        }
        anonymousCookie = cookie
        anonRetryAfter = nil
    }

    // MARK: - 账号与扫码登录

    /// 当前登录状态；未登录（或 cookie 已失效）返回 nil
    func currentAccount() async throws -> Account? {
        guard signInCookie != nil else { return nil }
        let json = try await get("/login/status", needsTimestamp: true, allowAnonymous: false)
        if let code = (json["code"] as? NSNumber)?.intValue, [301, 401, 403].contains(code) {
            signInCookie = nil
            return nil
        }
        guard let data = json["data"] as? [String: Any] ?? json["account"] as? [String: Any],
              (data["profile"] as? [String: Any]) != nil || (data["nickname"] as? String)?.isEmpty == false
        else {
            // 机房 IP 上 /login/status 会回 -462 且不带资料，但 cookie 是好的。
            // 这时退回走原生路由（纯 weapi 取账号），否则「扫码成功」后会被当成没登录。
            if let fallback = try? await getNative("/user/account", query: ["cookie": signInCookie ?? ""]) {
                let raw = fallback["profile"] as? [String: Any] ?? fallback["account"] as? [String: Any]
                if let raw { return Self.account(from: raw) }
            }
            return nil
        }
        let profile = data["profile"] as? [String: Any] ?? data
        return Self.account(from: profile)
    }

    private static func account(from raw: [String: Any]) -> Account {
        Account(
            userId: String((raw["userId"] as? NSNumber)?.intValue ?? (raw["id"] as? NSNumber)?.intValue ?? 0),
            provider: .netease,
            nickname: raw["nickname"] as? String ?? "",
            avatarUrl: raw["avatarUrl"] as? String,
            vipType: (raw["vipType"] as? NSNumber)?.intValue
        )
    }

    /// 扫码第一步：拿 key
    /// 服务端在这一次请求就会下发 cookie（在响应顶层，不在 data 内），后续 create/check 必须带上，
    /// 否则二维码与轮询状态可能对不上，登录拿不到 cookie。
    func qrKey() async throws -> String {
        let json = try await get("/login/qr/key", needsTimestamp: true, allowAnonymous: false)
        if let cookie = json["cookie"] as? String, !cookie.isEmpty, signInCookie == nil {
            anonymousCookie = cookie
        }
        guard let data = json["data"] as? [String: Any], let key = data["unikey"] as? String else {
            throw APIError(code: (json["code"] as? NSNumber)?.intValue, message: qrMessage(json))
        }
        return key
    }

    /// 扫码第二步：拿二维码图片（data:image/png;base64,...）
    func qrImage(key: String) async throws -> String {
        let json = try await get("/login/qr/create", query: ["key": key, "qrimg": "true"], needsTimestamp: true, allowAnonymous: false)
        guard let data = json["data"] as? [String: Any], let image = data["qrimg"] as? String, !image.isEmpty else {
            throw APIError(code: (json["code"] as? NSNumber)?.intValue, message: qrMessage(json))
        }
        return image
    }

    enum QRState {
        case waiting      // 801
        case scanned      // 802
        case confirmed    // 803
        case expired      // 800
        case failed(String)
    }

    /// 最近一次扫码轮询里网易云给的码（-462 风控等要据此提示「先去浏览器验证」）
    private var lastQRCodeValue = 0
    func lastQRCode() -> Int { lastQRCodeValue }

    /// 扫码第三步：轮询。803 时把 cookie 存下来，后续请求带上。
    func checkQR(key: String) async -> QRState {
        guard let json = try? await get("/login/qr/check", query: ["key": key], needsTimestamp: true, allowAnonymous: false) else {
            return .failed("网络异常，稍后重试")
        }
        lastQRCodeValue = (json["code"] as? NSNumber)?.intValue ?? 0
        switch (json["code"] as? NSNumber)?.intValue {
        case 800: return .expired
        case 801: return .waiting
        case 802: return .scanned
        case 803:
            if let cookie = json["cookie"] as? String, !cookie.isEmpty {
                signInCookie = cookie
                anonymousCookie = nil
                return .confirmed
            }
            return .failed("登录成功但没有拿到登录状态")
        default:
            return .failed(qrMessage(json))
        }
    }

    private func qrMessage(_ json: [String: Any]) -> String {
        let code = (json["code"] as? NSNumber)?.intValue
        let text = (json["message"] as? String) ?? (json["msg"] as? String) ?? "未知错误"
        return "code \(code.map(String.init) ?? "none"): \(text)"
    }

    // MARK: - 曲库

    /// 用户歌单列表（含「我喜欢的音乐」）
    func userPlaylists(userId: String, limit: Int = 1000, offset: Int = 0) async throws -> [MusicCollection] {
        let json = try await get("/user/playlist", query: [
            "uid": userId, "limit": String(limit), "offset": String(offset),
        ], needsTimestamp: true)
        let list = json["playlist"] as? [[String: Any]] ?? []
        return list.map { raw in
            let creatorId = (raw["creator"] as? [String: Any]).flatMap { ($0["userId"] as? NSNumber)?.intValue }
            let specialType = (raw["specialType"] as? NSNumber)?.intValue
            let liked = specialType == 5 && String(creatorId ?? 0) == userId
            return Self.collection(from: raw, kind: .playlist, isLiked: liked)
        }
    }

    /// 收藏的专辑
    func userAlbums(limit: Int = 100, offset: Int = 0) async throws -> [MusicCollection] {
        let json = try await get("/album/sublist", query: ["limit": String(limit), "offset": String(offset)])
        let list = json["data"] as? [[String: Any]] ?? []
        return list.map { Self.collection(from: $0, kind: .album, isLiked: false) }
    }

    /// 每日推荐
    func dailySongs() async throws -> [Song] {
        let json = try await get("/recommend/songs")
        let list = json["data"].flatMap { ($0 as? [String: Any])?["songs"] as? [[String: Any]] } ?? json["songs"] as? [[String: Any]] ?? []
        return list.compactMap(Self.song(from:))
    }

    /// 私人 FM
    func personalFM() async throws -> [Song] {
        let json = try await get("/personal_fm")
        let list = json["data"] as? [[String: Any]] ?? []
        return list.compactMap(Self.song(from:))
    }

    /// 推荐歌单（电台页的推荐位）
    func recommendedPlaylists(limit: Int = 35) async throws -> [MusicCollection] {
        let json = try await get("/personalized", query: ["limit": String(limit)])
        let list = json["result"] as? [[String: Any]] ?? []
        return list.map { Self.collection(from: $0, kind: .radio, isLiked: false) }
    }

    /// 歌单详情
    func playlistDetail(id: String) async throws -> MusicCollection? {
        let json = try await get("/playlist/detail", query: ["id": id], needsTimestamp: true)
        guard let raw = json["playlist"] as? [String: Any] else { return nil }
        return Self.collection(from: raw, kind: .playlist, isLiked: false)
    }

    /// 歌单全部曲目
    func playlistTracks(id: String, limit: Int = 1000, offset: Int = 0) async throws -> [Song] {
        let json = try await get("/playlist/track/all", query: [
            "id": id, "limit": String(limit), "offset": String(offset),
        ])
        let list = json["songs"] as? [[String: Any]] ?? []
        return list.compactMap(Self.song(from:))
    }

    /// 专辑详情 + 曲目
    func album(id: String) async throws -> (collection: MusicCollection, songs: [Song])? {
        let json = try await get("/album", query: ["id": id])
        guard let raw = json["album"] as? [String: Any] else { return nil }
        let songs = (json["songs"] as? [[String: Any]] ?? []).compactMap(Self.song(from:))
        return (Self.collection(from: raw, kind: .album, isLiked: false), songs)
    }

    /// 搜索（曲目）
    func search(_ keywords: String, limit: Int = 50, offset: Int = 0) async throws -> [Song] {
        let json = try await get("/cloudsearch", query: [
            "keywords": keywords, "limit": String(limit), "offset": String(offset),
        ])
        let result = json["result"] as? [String: Any] ?? json
        let list = result["songs"] as? [[String: Any]] ?? []
        return list.compactMap(Self.song(from:))
    }

    /// 音频地址。level 为 exhigh 时是 320k；VIP 曲目也通常能拿到签名地址。
    func audioURL(songId: Int, level: String = "exhigh") async throws -> (url: URL, isPreview: Bool) {
        let json = try await get("/song/url/v1", query: [
            "id": String(songId), "level": level, "randomCNIP": "true", "https": "true",
        ])
        guard let first = (json["data"] as? [[String: Any]])?.first else {
            throw APIError(code: (json["code"] as? NSNumber)?.intValue, message: "没有拿到音频地址")
        }
        guard let text = first["url"] as? String, !text.isEmpty else {
            throw APIError(code: (first["code"] as? NSNumber)?.intValue, message: "这首歌暂时没有可播放的音源")
        }
        let https = text.hasPrefix("http://") ? "https://" + text.dropFirst(7) : text
        guard let url = URL(string: https) else {
            throw APIError(code: nil, message: "音频地址无效")
        }
        return (url, first["freeTrialInfo"] is [String: Any])
    }

    // MARK: - 歌词

    func lyrics(songId: Int) async throws -> [LyricLine] {
        let json = try await get("/lyric/new", query: ["id": String(songId)])
        let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String
            ?? (json["lrc"] as? String)
            ?? ""
        let yrc = (json["yrc"] as? [String: Any])?["lyric"] as? String ?? ""
        return LyricParser.parse(yrc.isEmpty ? lrc : yrc)
    }

    // MARK: - MusicAPI 用的字符串版入口

    func audio(for song: Song) async throws -> (url: URL, isPreview: Bool) {
        guard let id = Int(song.id) else {
            throw APIError(code: nil, message: "歌曲 id 无效")
        }
        return try await audioURL(songId: id)
    }

    func lyrics(for song: Song) async throws -> [LyricLine] {
        guard let id = Int(song.id) else { return [] }
        return try await lyrics(songId: id)
    }

    // MARK: - 登录

    func signIn(cookie: String) async throws -> Account {
        signInCookie = cookie
        guard let account = try await currentAccount() else {
            throw APIError(code: nil, message: "cookie 无效")
        }
        return account
    }

    // MARK: - JSON → 模型

    private static func collection(from raw: [String: Any], kind: CollectionKind, isLiked: Bool) -> MusicCollection {
        let artists = (raw["artists"] as? [[String: Any]]) ?? (raw["artist"] as? [String: Any]).map { [$0] } ?? []
        let creator = (raw["creator"] as? [String: Any])?["nickname"] as? String
            ?? artists.first?["name"] as? String
            ?? (raw["artist"] as? [String: Any])?["name"] as? String
        return MusicCollection(
            id: String((raw["id"] as? NSNumber)?.intValue ?? 0),
            provider: .netease,
            name: raw["name"] as? String ?? "",
            kind: kind,
            coverUrl: raw["coverImgUrl"] as? String ?? raw["picUrl"] as? String,
            description: raw["description"] as? String ?? raw["briefDesc"] as? String,
            trackCount: (raw["trackCount"] as? NSNumber)?.intValue ?? (raw["size"] as? NSNumber)?.intValue,
            isLiked: isLiked || (raw["isLiked"] as? Bool ?? false),
            creatorName: creator
        )
    }

    /// 对齐 netease.ts 的 normalizeSongResult
    static func song(from raw: [String: Any]) -> Song? {
        let base = raw["simpleSong"] as? [String: Any] ?? raw
        let id = (base["id"] as? NSNumber)?.intValue ?? (raw["id"] as? NSNumber)?.intValue ?? 0
        guard id > 0 else { return nil }

        let artists = (base["ar"] as? [[String: Any]])
            ?? (base["artists"] as? [[String: Any]])
            ?? (raw["artists"] as? [[String: Any]])
            ?? []
        let albumRaw = (base["al"] as? [String: Any]) ?? (base["album"] as? [String: Any]) ?? [:]
        let t = (base["t"] as? NSNumber)?.intValue ?? (raw["t"] as? NSNumber)?.intValue ?? 0

        let privilege = base["privilege"] as? [String: Any] ?? raw["privilege"] as? [String: Any]
        let st = (privilege?["st"] as? NSNumber)?.intValue

        return Song(
            id: String(id),
            provider: .netease,
            name: base["name"] as? String ?? raw["name"] as? String ?? "未知歌曲",
            artists: artists.enumerated().map { index, artist in
                Artist(
                    id: String((artist["id"] as? NSNumber)?.intValue ?? index),
                    name: artist["name"] as? String ?? ""
                )
            }.filter { !$0.name.isEmpty },
            album: Album(
                id: String((albumRaw["id"] as? NSNumber)?.intValue ?? 0),
                name: albumRaw["name"] as? String ?? "",
                coverUrl: albumRaw["picUrl"] as? String ?? albumRaw["blPicUrl"] as? String
                    ?? (albumRaw["artist"] as? [String: Any])?["picUrl"] as? String
            ),
            durationMs: (base["dt"] as? NSNumber)?.intValue ?? (base["duration"] as? NSNumber)?.intValue ?? 0,
            isCloud: t == 1 || t == 2,
            fee: (base["fee"] as? NSNumber)?.intValue,
            st: st
        )
    }
}

/// 登录态存 Keychain：cookie 是密码级的东西，不该落在 UserDefaults。
enum Keychain {
    private static let service = "app.folia.major.native"

    static func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for key: String) {
        let query = baseQuery(key)
        if let value, let data = value.data(using: .utf8) {
            SecItemDelete(query as CFDictionary)
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attributes as CFDictionary, nil)
        } else {
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
