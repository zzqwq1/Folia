import Foundation

/// 四个平台的统一入口。原版 `src/services/onlineMusic/index.ts` 按 provider 分派，
/// 这里做同一件事：界面层只说「我要这首歌的音频 / 歌词 / 这个集合的曲目」，由它挑实现。
///
/// 所有平台都走同一个自建代理 `https://app.folia-api.top`：
/// 网易云 `/api/netease`、QQ `/api/qq`、酷狗 `/api/kugou`、波点 `/api/bodian`。
actor MusicAPI {
    static let shared = MusicAPI()

    private init() {}

    // MARK: - 音频与歌词

    func audioURL(for song: Song) async throws -> (url: URL, isPreview: Bool) {
        switch song.provider {
        case .netease: return try await NeteaseAPI.shared.audio(for: song)
        case .qq: return try await QQMusicAPI.shared.audio(for: song)
        case .kugou: return try await KugouAPI.shared.audio(for: song)
        case .bodian: return try await BodianAPI.shared.audio(for: song)
        }
    }

    func lyrics(for song: Song) async throws -> [LyricLine] {
        switch song.provider {
        case .netease: return try await NeteaseAPI.shared.lyrics(for: song)
        case .qq: return try await QQMusicAPI.shared.lyrics(for: song)
        case .kugou: return try await KugouAPI.shared.lyrics(for: song)
        case .bodian: return try await BodianAPI.shared.lyrics(for: song)
        }
    }

    // MARK: - 集合

    func album(_ collection: MusicCollection) async throws -> [Song] {
        switch collection.provider {
        case .netease: return try await NeteaseAPI.shared.album(id: collection.id)?.songs ?? []
        case .qq: return try await QQMusicAPI.shared.album(id: collection.id)
        case .kugou: return try await KugouAPI.shared.album(id: collection.id)
        case .bodian: return try await BodianAPI.shared.album(id: collection.id)
        }
    }

    func playlistTracks(_ collection: MusicCollection) async throws -> [Song] {
        switch collection.provider {
        case .netease: return try await NeteaseAPI.shared.playlistTracks(id: collection.id)
        case .qq: return try await QQMusicAPI.shared.playlistTracks(id: collection.id)
        case .kugou: return try await KugouAPI.shared.playlistTracks(id: collection.id)
        case .bodian: return try await BodianAPI.shared.playlistTracks(id: collection.id)
        }
    }

    /// 用户自己的歌单（首页墙面来源）
    func userPlaylists(for account: Account) async throws -> [MusicCollection] {
        switch account.provider {
        case .netease:
            let playlists = try await NeteaseAPI.shared.userPlaylists(userId: account.userId)
            let albums = (try? await NeteaseAPI.shared.userAlbums()) ?? []
            return playlists + albums
        case .qq: return try await QQMusicAPI.shared.userPlaylists(userId: account.userId)
        case .kugou: return try await KugouAPI.shared.userPlaylists(userId: account.userId)
        case .bodian: return try await BodianAPI.shared.userPlaylists(userId: account.userId)
        }
    }

    func search(_ keywords: String, provider: MusicProvider, limit: Int = 50) async throws -> [Song] {
        switch provider {
        case .netease: return try await NeteaseAPI.shared.search(keywords, limit: limit)
        case .qq: return try await QQMusicAPI.shared.search(keywords, limit: limit)
        case .kugou: return try await KugouAPI.shared.search(keywords, limit: limit)
        case .bodian: return try await BodianAPI.shared.search(keywords, limit: limit)
        }
    }
}

// MARK: - 扫码登录的统一入口

/// 四个平台的扫码状态各写了一套 enum / 方法名，登录窗口只认这一份。
enum QRState {
    case waiting
    case scanned
    case confirmed
    case expired
    case failed(String)
}

extension MusicProvider {
    /// 取二维码 key + 图片地址（`data:image/png;base64,...` 或 http 地址）
    func makeQRCode() async throws -> (key: String, image: String) {
        switch self {
        case .netease:
            let key = try await NeteaseAPI.shared.qrKey()
            let image = try await NeteaseAPI.shared.qrImage(key: key)
            return (key, image)
        case .qq:
            let key = try await QQMusicAPI.shared.qrKey()
            let image = try await QQMusicAPI.shared.qrImage(key: key)
            return (key, image)
        case .kugou:
            let key = try await KugouAPI.shared.qrKey()
            let image = try await KugouAPI.shared.qrImage(key: key)
            return (key, image)
        case .bodian:
            let key = try await BodianAPI.shared.qrKey()
            let image = try await BodianAPI.shared.qrImage(key: key)
            return (key, image)
        }
    }

    func pollQR(key: String) async -> QRState {
        switch self {
        case .netease:
            switch await NeteaseAPI.shared.checkQR(key: key) {
            case .waiting: return .waiting
            case .scanned: return .scanned
            case .confirmed: return .confirmed
            case .expired: return .expired
            case .failed(let reason): return .failed(reason)
            }
        case .qq:
            switch await QQMusicAPI.shared.checkQR(key: key) {
            case .waiting: return .waiting
            case .scanned: return .scanned
            case .confirmed: return .confirmed
            case .expired: return .expired
            case .failed(let reason): return .failed(reason)
            }
        case .kugou:
            switch await KugouAPI.shared.checkQR(key: key) {
            case .waiting: return .waiting
            case .scanned: return .scanned
            case .confirmed: return .confirmed
            case .expired: return .expired
            case .failed(let reason): return .failed(reason)
            }
        case .bodian:
            switch await BodianAPI.shared.checkQR(key: key) {
            case .waiting: return .waiting
            case .scanned: return .scanned
            case .confirmed: return .confirmed
            case .expired: return .expired
            case .failed(let reason): return .failed(reason)
            }
        }
    }

    func cancelQR(key: String) async {
        switch self {
        case .netease: break
        case .qq: await QQMusicAPI.shared.cancelQR(key: key)
        case .kugou: await KugouAPI.shared.cancelQR(key: key)
        case .bodian: await BodianAPI.shared.cancelQR(key: key)
        }
    }

    /// 扫码确认后把账号读出来
    func loadAccount() async throws -> Account? {
        switch self {
        case .netease: return try await NeteaseAPI.shared.currentAccount()
        case .qq: return try await QQMusicAPI.shared.currentAccount()
        case .kugou: return try await KugouAPI.shared.currentAccount()
        case .bodian: return try await BodianAPI.shared.currentAccount()
        }
    }

    /// 最近一次轮询拿到的平台码（网易云要据此判断风控）
    func lastQRCode() async -> Int {
        switch self {
        case .netease: return await NeteaseAPI.shared.lastQRCode()
        case .qq: return await QQMusicAPI.shared.lastQRCode()
        case .kugou: return await KugouAPI.shared.lastQRCode()
        case .bodian: return await BodianAPI.shared.lastQRCode()
        }
    }
}

// MARK: - 共用的小工具

/// 一个带 30 秒超时的 URLSession（网易云以外的三个平台用）
func foliaURLSession() -> URLSession {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
}

/// 把一个 `Any` 里的数字 / 字符串统一读成 String（三个平台的 id 类型很不一致）
func stringValue(_ raw: Any?) -> String? {
    switch raw {
    case let text as String: return text
    case let number as NSNumber: return number.stringValue
    default: return nil
    }
}

func intValue(_ raw: Any?) -> Int? {
    switch raw {
    case let number as NSNumber: return number.intValue
    case let text as String: return Int(text)
    default: return nil
    }
}

/// 把 `http://` 的封面 / 音频地址改成 https，避免 ATS 拦截
func httpsURL(_ text: String) -> URL? {
    guard !text.isEmpty else { return nil }
    let fixed = text.hasPrefix("http://") ? "https://" + text.dropFirst("http://".count) : text
    return URL(string: fixed)
}

/// 把毫秒 / 秒混着给的时长统一成毫秒（QQ 与波点给的是秒）
func normalizeDurationMs(_ raw: Any?) -> Int {
    guard let value = intValue(raw) else { return 0 }
    return value > 0 && value < 10_000 ? value * 1000 : value
}
