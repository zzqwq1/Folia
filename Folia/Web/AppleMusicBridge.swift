import Foundation
import WebKit
import MusicKit
import CryptoKit

/// Apple Music 原生 provider 桥。
///
/// 线上页面的 `providerRegistry` 里已经有完整的 Apple Music provider（`Bh`），
/// 但它把**所有**能力都委托给一条原生通道：
///
/// ```js
/// window.webkit.messageHandlers.foliaProviderAuth.postMessage({ id, action, ...params })
/// // 原生 => window.__foliaProviderAuthReply({ id, payload: { ok, data | error } })
/// ```
///
/// 逆向 `Xm()` 得到的调用点（`action` / 超时）：
/// - `appleMusicOpen`    `{}`                       20s
/// - `appleMusicStatus`  `{}`                       20s
/// - `appleMusicClose`   `{}`                        5s
/// - `appleMusicLogout`  `{}`                       10s
/// - `appleMusicRequest` `{ operation, params }`    30s
///
/// `appleMusicRequest` 的 `operation` 只有四个（页面侧 `Ah/Th` 分发）：
/// - `librarySongs`   `{limit, offset}` → `/v1/me/library/songs`
/// - `playlists`      `{limit, offset}` → `/v1/me/library/playlists`
/// - `playlistTracks` `{playlistId, limit, offset}` → `/v1/me/library/playlists/{id}/tracks`
/// - `lyrics`         `{songId}` 或 `{librarySongId}` → `.../lyrics`
///
/// **注意超时预算**：页面 `Ah()` 一次 `getUserPlaylists` 会循环翻页（最多 200 次），
/// 但每次 `Xm` 各有 30 秒。所以每次 `fetchPage` 必须独立、快速（这里的 URLSession
/// 超时设 20 秒），绝不能把多次翻页合并进一次原生等待，否则页面整体判超时。
///
/// 页面侧对回包形状的校验极硬（`kh()`）：
/// `items` 必须是数组、`hasMore` 必须是布尔、`nextOffset` 必须是安全整数且
/// `nextOffset >= offset + items.length`；`hasMore == true` 时还必须 `> offset`。
/// 任何一条不满足都会抛 `invalid-response`，整页变错误态。
final class AppleMusicBridge: NSObject, WKScriptMessageHandler {
    private static let apiBase = "https://api.music.apple.com"
    private static let storefrontKey = "folia.appleMusic.storefront"

    /// 页面侧回包走主线程（`evaluateJavaScript` 必须在主线程）。
    weak var webView: WKWebView?

    init(webView: WKWebView?) {
        self.webView = webView
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let requestId = body["id"] as? String,
              let action = body["action"] as? String else { return }
        switch action {
        case "appleMusicOpen":
            open(requestId)
        case "appleMusicStatus":
            status(requestId)
        case "appleMusicClose":
            reply(requestId, ["ok": true, "data": NSNull()])
        case "appleMusicLogout":
            logout(requestId)
        case "appleMusicRequest":
            let operation = (body["operation"] as? String) ?? ""
            let params = (body["params"] as? [String: Any]) ?? [:]
            perform(requestId, operation: operation, params: params)
        default:
            reply(requestId, ["ok": false, "error": "unsupported-operation"])
        }
    }

    // MARK: - 授权

    private func open(_ requestId: String) {
        Task { @MainActor in
            let status = await MusicAuthorization.request()
            guard status == .authorized else {
                self.reply(requestId, ["ok": false, "error": "auth-required",
                                       "data": ["authorization": "\(status)"]])
                return
            }
            do {
                // `MusicDataRequest.currentCountryCode` 是商店区域（如 `us` / `cn`），
                // 只用来给账号 id 派生一个稳定种子。
                let storefront = try await MusicDataRequest.currentCountryCode.lowercased()
                UserDefaults.standard.set(storefront, forKey: Self.storefrontKey)
            } catch {
                // 取 storefront 失败不影响主体流程，派生种子时留空即可。
            }
            self.reply(requestId, ["ok": true, "data": ["authorized": true]])
        }
    }

    private func status(_ requestId: String) {
        let authorization = MusicAuthorization.currentStatus
        guard authorization == .authorized else {
            self.reply(requestId, ["ok": true, "data": ["authenticated": false]])
            return
        }
        // 用户身份：页面的 `xh()` 要求 `id` 是 64 位小写 hex。
        // MusicKit 没有「取当前 Apple Music 用户 id」的公开接口，这里用
        // 落盘的设备种子 + 商店区域派生一个 —— 同机恒定，不会每次调用都换人。
        let seed = Self.accountSeed()
        guard !seed.isEmpty else {
            self.reply(requestId, ["ok": true, "data": ["authenticated": false]])
            return
        }
        let digest = Self.sha256Hex(seed)
        self.reply(requestId, ["ok": true, "data": [
            "authenticated": true,
            "user": ["id": digest, "nickname": "Apple Music"]
        ]])
    }

    private func logout(_ requestId: String) {
        // MusicKit 的 user token 由系统托管，App 侧没有「代用户退订」的接口；
        // 页面只需要知道「这边已经把它当成未登录」，下次进 Apple Music 会重新弹授权。
        UserDefaults.standard.removeObject(forKey: Self.storefrontKey)
        reply(requestId, ["ok": true, "data": NSNull()])
    }

    /// 派生账号身份的种子。
    ///
    /// 页面 `xh()` 要求 `id` 是 64 位小写 hex，且同一个账号在多次 `appleMusicStatus`
    /// 之间必须恒定（否则页面把它当换人，整个音乐库界面重启）。
    /// MusicKit 没有「取当前用户 id」的公开接口，所以用落盘的设备种子 + 商店区域派生：
    /// 同机恒定、换区域会变。
    private static func accountSeed() -> String {
        let storefront = UserDefaults.standard.string(forKey: storefrontKey) ?? ""
        let device = UserDefaults.standard.string(forKey: "folia.appleMusic.deviceSeed")
            ?? {
                let fresh = UUID().uuidString
                UserDefaults.standard.set(fresh, forKey: "folia.appleMusic.deviceSeed")
                return fresh
            }()
        guard MusicAuthorization.currentStatus == .authorized, !device.isEmpty else { return "" }
        return device + "|" + storefront
    }

    private static func sha256Hex(_ text: String) -> String {
        // 页面 `xh()` 的硬校验是 `/^[a-f0-9]{64}$/`。
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 数据请求

    private func perform(_ requestId: String, operation: String, params: [String: Any]) {
        let limit = min(max(Self.intValue(params["limit"]) ?? 100, 1), 100)
        let offset = max(Self.intValue(params["offset"]) ?? 0, 0)
        switch operation {
        case "librarySongs":
            fetchPage(requestId, path: "/v1/me/library/songs", query: ["limit": "\(limit)", "offset": "\(offset)"])
        case "playlists":
            fetchPage(requestId, path: "/v1/me/library/playlists", query: ["limit": "\(limit)", "offset": "\(offset)"])
        case "playlistTracks":
            let playlistId = (params["playlistId"] as? String) ?? ""
            guard !playlistId.isEmpty else {
                reply(requestId, ["ok": false, "error": "invalid-request"])
                return
            }
            fetchPage(requestId,
                      path: "/v1/me/library/playlists/\(Self.encode(playlistId))/tracks",
                      query: ["limit": "\(limit)", "offset": "\(offset)"])
        case "lyrics":
            if let songId = params["songId"] as? String, !songId.isEmpty {
                fetchLyrics(requestId, path: "/v1/catalog/songs/\(Self.encode(songId))/lyrics")
            } else if let libraryId = params["librarySongId"] as? String, !libraryId.isEmpty {
                fetchLyrics(requestId, path: "/v1/me/library/songs/\(Self.encode(libraryId))/lyrics")
            } else {
                reply(requestId, ["ok": false, "error": "invalid-request"])
            }
        default:
            reply(requestId, ["ok": false, "error": "unsupported-operation"])
        }
    }

    /// 跨进程过来的数字是 `NSNumber`，`as? Int` 在部分情况下会失败
    /// （页面 `kh()` 传的 `offset` 可能是浮点形式），这里统一收一遍。
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func encode(_ value: String) -> String {
        // `.urlPathAllowed` 里含 `/`，歌单 id 万一带斜杠会把路径拆开。
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func fetchPage(_ requestId: String, path: String, query: [String: String]) {
        let requestedOffset = Int(query["offset"] ?? "") ?? 0
        request(path: path, query: query) { result in
            switch result {
            case .failure(let failure):
                self.reply(requestId, ["ok": false, "error": failure.code])
            case .success(let json):
                // Apple 的资源对象本身就是 `{id, type, attributes, ...}`，
                // 与页面 `Sh()` / `Ch()` 的读取路径完全一致，原样透传即可。
                let data = (json["data"] as? [[String: Any]]) ?? []
                let next = (json["next"] as? String) ?? ""
                // 页面 `kh()` 的硬校验：`hasMore` 必须是 bool、`nextOffset` 必须是
                // 安全整数，且不得小于 `offset + items.length`。
                // Apple 的 `next` 解析不出来时宁可报「没有更多」，也不要让页面
                // 拿着同一个 offset 反复打同一个请求（那会 200 次翻页直接把 30 秒烧光）。
                var hasMore = false
                var nextOffset = requestedOffset + data.count
                if !next.isEmpty,
                   let parsed = self.nextOffset(from: next),
                   parsed > requestedOffset {
                    hasMore = true
                    nextOffset = parsed
                }
                self.reply(requestId, ["ok": true, "data": [
                    "items": data,
                    "hasMore": hasMore,
                    "nextOffset": nextOffset
                ]])
            }
        }
    }

    /// Apple 的 `next` 是形如 `/v1/me/library/songs?offset=100&limit=100` 的路径。
    private static func nextOffset(from next: String) -> Int? {
        guard let components = URLComponents(string: "https://api.music.apple.com" + next),
              let raw = components.queryItems?.first(where: { $0.name == "offset" })?.value else {
            return nil
        }
        return Int(raw)
    }

    private func fetchLyrics(_ requestId: String, path: String) {
        request(path: path, query: [:]) { result in
            switch result {
            case .failure(let failure):
                // 页面 `Dh()` 对歌词的失败是「静默降级成无歌词」，只把
                // `auth-required` 往上抛。这里照原样回错误码即可。
                self.reply(requestId, ["ok": false, "error": failure.code])
            case .success(let json):
                let data = (json["data"] as? [[String: Any]]) ?? []
                let attributes = data.first?["attributes"] as? [String: Any]
                let text = (attributes?["ttml"] as? String) ?? ""
                // 页面 `Dh()` 要求 `ttml` 是**非空**字符串，否则返回 null（视为无歌词）。
                self.reply(requestId, ["ok": true, "data": ["ttml": text]])
            }
        }
    }

    /// 用 `MusicDataRequest` 发请求：它自带 developer token 与 music user token，
    /// 不需要页面侧拼 MusicKit JS 实例。
    ///
    /// 超时取 20 秒：页面给 `appleMusicRequest` 的预算是 30 秒，留 10 秒给
    /// JSON 整形 + 回包跨进程。超过预算页面会直接判 `native-provider-request-timeout`，
    /// 那时连错误码都保不住，只能整页报错。
    private func request(_ path: String, query: [String: String],
                         completion: @escaping (Result<[String: Any], RequestFailure>) -> Void) {
        var components = URLComponents(string: Self.apiBase + path)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            completion(.failure(RequestFailure(code: "invalid-request")))
            return
        }
        Task {
            do {
                // `MusicDataRequest` 只有 `urlRequest` 这一个构造入参，
                // GET 与超时都必须写在 request 本身上（它没有 `method` 属性）。
                var urlRequest = URLRequest(url: url, timeoutInterval: 20)
                urlRequest.httpMethod = "GET"
                let response = try await MusicDataRequest(urlRequest: urlRequest).response()
                guard let json = try JSONSerialization.jsonObject(with: response.data)
                        as? [String: Any] else {
                    completion(.failure(RequestFailure(code: "invalid-response")))
                    return
                }
                completion(.success(json))
            } catch {
                completion(.failure(RequestFailure(code: Self.classify(error))))
            }
        }
    }

    /// 回包需要的是 `String` 错误码，但 `Result` 的失败类型必须是 `Error`。
    /// 用一个只有 `code` 的小结构包一层，避免把 `String` 直接塞进 `Result`。
    private struct RequestFailure: Error {
        let code: String
    }

    /// 页面 `wh()` 会把错误码映射成三类展示：`auth-required` / `network` / `unavailable`。
    private static func classify(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("401") || text.contains("403") || text.contains("unauthorized") {
            return "auth-required"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                return "network"
            default: return "request-failed"
            }
        }
        return "request-failed"
    }

    // MARK: - 回包

    private func reply(_ requestId: String, _ payload: [String: Any]) {
        let envelope: [String: Any] = ["id": requestId, "payload": payload]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let js = "window.__foliaProviderAuthReply && window.__foliaProviderAuthReply(\(json));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
