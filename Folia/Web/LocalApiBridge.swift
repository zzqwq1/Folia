import Foundation
import WebKit

/// 网页版把各平台的接口挂在 `/api/<provider>/...` 上，静态包里没有这些目录。
/// 在 `folia://app/` 协议下，前端硬编码的 `/api/kugou`、`/api/qq`、`/api/bodian`
/// 以及 `folia://app/api/netease` 全会落到本层，由这里翻译成真实请求。
///
/// 路由：
///   /api/netease/*     → 反代到电脑上的 NeteaseCloudMusicApi（官方加密通道，能拿到 MUSIC_U）
///   /api/kugou|qq|bodian → 反代到同一个 upstream（这三个服务端与网易共用一台机器）
///   /api/lyric-proxy   → 反代酷狗官方接口（前端用它绕 CORS）
///
/// 上游不可达时，网易接口退回本地明文实现，至少保证未登录也能浏览/播放。
final class LocalApiBridge {
    static let shared = LocalApiBridge()

    /// 网页版里的网易接口前缀（前端在 folia: 协议下写死的值）。
    static let neteasePrefix = "/api/netease"
    /// 普通接口前缀：前端在 folia://app/ 下解析出的相对路径，经隧道转到电脑上的服务端。
    static let otherPrefixes = ["/api/kugou", "/api/qq", "/api/bodian"]
    /// 歌词代理前缀：`/api/lyric-proxy?url=<encodeURIComponent(原始地址)>`。
    /// 这个接口本来就是要「把任意地址（酷狗、网易等）的内容取回来绕 CORS」，
    /// 直接把整个路径甩给隧道是错的，必须解析出 url 参数、直接请求原始地址。
    static let lyricProxyPrefix = "/api/lyric-proxy"

    /// 电脑上跑的服务端经 Cloudflare 隧道暴露的公网地址。
    /// 换隧道/换电脑时只改这一行，然后重新打包。
    static let upstream = "https://reproductive-advertiser-merger-treatment.trycloudflare.com"

    private let origin = "https://music.163.com"
    /// 串行队列：这里既是 cookie 表的唯一访问点，也是「同一 task 只回调一次」的判定点。
    /// 之前用 concurrent + URLSession 回调里直接写 cookie，多接口并发（歌词、封面、详情同时来）
    /// 会把字典写坏，表现为 App 直接闪退回桌面。
    private let queue = DispatchQueue(label: "app.folia.api", qos: .userInitiated)
    private var cookies: [String: String] = [:]
    /// WKURLSchemeTask 只要重复 didReceive/didFinish，WebKit 就会抛 ObjC 异常杀掉进程。
    /// 页面切歌时会主动取消上一条请求，这里必须记账。
    private var activeTasks = Set<ObjectIdentifier>()

    private init() {
        cookies = Self.loadCookies()
    }

    // MARK: - 入口

    func shouldHandle(_ url: URL) -> Bool {
        let path = url.path
        if path.hasPrefix(Self.neteasePrefix) { return true }
        if path.hasPrefix(Self.lyricProxyPrefix) { return true }
        return Self.otherPrefixes.contains { path.hasPrefix($0) }
    }

    func handle(_ task: WKURLSchemeTask) {
        queue.async { self.activeTasks.insert(ObjectIdentifier(task)) }
        guard let url = task.request.url else {
            respond(task, status: 400, json: ["code": 400, "message": "bad url"])
            return
        }
        let path = url.path
        guard !path.hasPrefix(Self.neteasePrefix) else {
            handleNetease(task, url: url)
            return
        }
        guard !path.hasPrefix(Self.lyricProxyPrefix) else {
            handleLyricProxy(task, url: url)
            return
        }
        // 其余平台整条 URL 透传，路径和查询串都保持原样。
        handlePassthrough(task, url: url)
    }

    /// WebKit 取消请求（切歌、页面重载、超时）时会走这里；之后任何回调都必须被丢弃。
    func cancel(_ task: WKURLSchemeTask) {
        queue.async { self.activeTasks.remove(ObjectIdentifier(task)) }
    }

    /// 队列上的唯一出口：每个 task 只会真正回调一次，已取消的静默丢弃。
    private func respond(_ task: WKURLSchemeTask, status: Int, json: [String: Any], url: URL? = nil) {
        queue.async { [weak self] in
            guard let self, self.activeTasks.remove(ObjectIdentifier(task)) != nil else { return }
            Self.deliver(task, status: status, json: json, url: url)
        }
    }

    /// 其它平台：不改写任何参数，直接转发。
    private func handlePassthrough(_ task: WKURLSchemeTask, url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.activeTasks.contains(ObjectIdentifier(task)) else { return }
            guard let proxied = self.proxy(path: url.path, rawQuery: url.query, cookie: "") else {
                NSLog("[Folia] upstream unreachable \(url.path)")
                self.respond(task, status: 200, json: [
                    "code": 502,
                    "message": "服务端未连接：\(url.path)"
                ], url: url)
                return
            }
            self.respond(task, status: 200, json: proxied, url: url)
        }
    }

    /// 网易：先并 cookie，再反代；上游确实连不通时退回本地明文实现。
    ///
    /// 注意这里的判定顺序：上游返回了应答（哪怕是 404 / 500）就不算「连不通」。
    /// 之前 /api/netease 指向只挂了网易的旧隧道，这条路径一直 404，
    /// 前端看到的就是「NetEase gave no QR key: code 404: Not Found」。
    /// 现在网易由同一个网关的 3103 提供，正常会返回真实 unikey。
    private func handleNetease(_ task: WKURLSchemeTask, url: URL) {
        var route = url.path
        if route.hasPrefix(Self.neteasePrefix) {
            route = String(route.dropFirst(Self.neteasePrefix.count))
        }
        if route.isEmpty { route = "/" }
        let query = Self.query(url)

        // 前端把 localStorage 里的 cookie 拼在 ?cookie= 上，这是权威来源：
        // 扫码成功那一刻前端已写入 localStorage，而桥接层进程内的表可能还没拿到。
        // 注意：前端在没登录时会退而带上「匿名 cookie」，那个没有 MUSIC_U，
        // 对账号类接口必须忽略，否则会把匿名态当登录态。
        let forwarded = Self.parseCookieString(query["cookie"])
        let isAccountRoute = route == "/login/status" || route == "/user/account"
        let effective = isAccountRoute
            ? (forwarded["MUSIC_U"] != nil ? Self.joinCookie(forwarded) : cookieHeader())
            : (forwarded.isEmpty ? cookieHeader() : Self.joinCookie(forwarded))

        queue.async { [weak self] in
            guard let self, self.activeTasks.contains(ObjectIdentifier(task)) else { return }
            if isAccountRoute {
                NSLog("[Folia] \(route) cookie=\(effective.isEmpty ? "none" : "len\(effective.count)")")
            }
            if !forwarded.isEmpty { self.adopt(forwarded) }

            // 主路径：转发到电脑上的服务端，它走官方加密通道，803 时能真正拿到 MUSIC_U。
            let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
            if let proxied = self.proxy(route: route, rawQuery: rawQuery, cookie: effective) {
                self.respond(task, status: 200, json: proxied, url: url)
                return
            }
            NSLog("[Folia] upstream unreachable, fallback to local \(route)")
            let result = self.dispatch(route: route, query: query, cookie: effective)
            self.respond(task, status: 200, json: result, url: url)
        }
    }

    // MARK: - 反向代理

    /// 网易接口转发。上游 NeteaseCloudMusicApi 的路由直接挂在根上（`/login/qr/key`），
    /// 没有 `/api/netease` 这一层，所以这里要把前缀拼回去。
    private func proxy(route: String, rawQuery: String?, cookie: String) -> [String: Any]? {
        var target = Self.upstream + route
        if let rawQuery, !rawQuery.isEmpty {
            // 网易接口的 cookie 已经在 effective 里并进表了，去掉前端拼的那份，
            // 避免上游收到两份互相矛盾的 cookie。
            let kept = rawQuery.split(separator: "&").filter { !$0.hasPrefix("cookie=") }.joined(separator: "&")
            if !kept.isEmpty { target += "?\(kept)" }
        }
        guard let url = URL(string: target) else { return nil }
        NSLog("[Folia] proxy \(route)")
        return request(url, method: "GET", form: nil, cookie: cookie)
    }

    /// 其它平台转发：路径原样透传。
    private func proxy(path: String, rawQuery: String?, cookie: String) -> [String: Any]? {
        var target = Self.upstream + path
        if let rawQuery, !rawQuery.isEmpty {
            target += "?\(rawQuery)"
        }
        guard let url = URL(string: target) else { return nil }
        NSLog("[Folia] proxy \(path)")
        return request(url, method: "GET", form: nil, cookie: cookie)
    }

    // MARK: - 本地兜底（仅网易）

    private func dispatch(route: String, query: [String: String], cookie: String) -> [String: Any] {
        switch route {
        case "/login/qr/key":
            return qrKey()
        case "/login/qr/create":
            return qrCreate(key: query["key"] ?? "")
        case "/login/qr/check":
            return qrCheck(key: query["key"] ?? "")
        case "/login/status":
            return loginStatus(cookie: cookie)
        case "/user/account":
            return userAccount(cookie: cookie)
        case "/register/anonimous":
            return registerAnonymous()
        case "/logout":
            let names = Self.parseCookieString(query["cookie"]).keys
            for name in names { cookies.removeValue(forKey: name) }
            if names.isEmpty { cookies.removeAll() }
            persist()
            return ["code": 200]
        default:
            return ["code": 200, "message": "local fallback: unsupported route \(route)"]
        }
    }

    // MARK: - 二维码登录（本地兜底）

    private func qrKey() -> [String: Any] {
        guard let json = post("/api/login/qrcode/unikey", form: ["type": "3"]),
              let key = json["unikey"] as? String, !key.isEmpty else {
            return ["code": 502, "message": "网易云接口无响应"]
        }
        return ["code": 200, "data": ["code": 200, "unikey": key]]
    }

    private func qrCreate(key: String) -> [String: Any] {
        guard !key.isEmpty else { return ["code": 400, "message": "missing key"] }
        let loginURL = "https://music.163.com/login?codekey=\(key)"
        let qrimg = QRTool.dataURL(for: loginURL) ?? ""
        return [
            "code": 200,
            "data": [
                "code": 200,
                "qrurl": loginURL,
                "qrimg": qrimg
            ]
        ]
    }

    private func qrCheck(key: String) -> [String: Any] {
        guard !key.isEmpty else { return ["code": 400, "message": "missing key"] }
        guard let json = post("/api/login/qrcode/client/login", form: ["key": key, "type": "1"]),
              let code = json["code"] as? Int else {
            return ["code": 502, "message": "网易云接口无响应"]
        }

        switch code {
        case 803:
            let payloadCookie = json["cookie"] as? String ?? ""
            NSLog(
                "[Folia] netease 803 jsonCookie="
                    + (payloadCookie.isEmpty
                        ? "empty"
                        : "len\(payloadCookie.count) hasMUSIC_U=\(payloadCookie.contains("MUSIC_U"))")
                    + " table=len\(cookies.count) hasMUSIC_U=\(cookies["MUSIC_U"] != nil)"
            )
            adoptCookie(from: json["cookie"])
            guard cookies["MUSIC_U"] != nil else {
                NSLog("[Folia] netease 803 without MUSIC_U, giving up")
                return ["code": 502, "message": "网易云未下发登录态，请重试扫码"]
            }
            return ["code": 803, "message": "授权登陆成功", "cookie": cookieHeader()]
        case 800:
            return ["code": 800, "message": "二维码已过期"]
        case 801:
            return ["code": 801, "message": "等待扫码"]
        case 802:
            return ["code": 802, "message": "待确认"]
        default:
            return ["code": code]
        }
    }

    // MARK: - 账号（本地兜底）

    private func loginStatus(cookie: String) -> [String: Any] {
        if let payload = accountPayload(cookie: cookie) {
            return ["code": 200, "data": merged(["code": 200], payload)]
        }
        return ["code": 301, "data": ["code": 301], "message": "未登录"]
    }

    private func userAccount(cookie: String) -> [String: Any] {
        if let payload = accountPayload(cookie: cookie) {
            return merged(["code": 200], payload)
        }
        return ["code": 301, "account": NSNull(), "profile": NSNull(), "message": "未登录"]
    }

    private func merged(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in extra { out[key] = value }
        return out
    }

    /// 用登录态打 /api/nuser/account/get，转成前端要的 account + profile。
    private func accountPayload(cookie: String) -> [String: Any]? {
        guard !cookie.isEmpty else { return nil }
        for attempt in 0..<3 {
            if let payload = fetchAccount(cookie: cookie) { return payload }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.5) }
        }
        return nil
    }

    private func fetchAccount(cookie: String) -> [String: Any]? {
        guard let url = URL(string: "\(origin)/api/nuser/account/get?timestamp=\(Int(Date().timeIntervalSince1970 * 1000))"),
              let json = request(url, method: "GET", form: nil, cookie: cookie),
              let profile = json["profile"] as? [String: Any] else {
            return nil
        }
        var user = profile
        user["avatarUrl"] = profile["avatarUrl"] as? String ?? ""
        user["backgroundUrl"] = profile["backgroundUrl"] as? String ?? ""
        let detail = json["account"] as? [String: Any] ?? [:]
        let account: [String: Any] = [
            "id": detail["id"] ?? profile["userId"] ?? 0,
            "userName": detail["userName"] ?? profile["nickname"] ?? "",
            "type": detail["type"] ?? 1,
            "status": detail["status"] ?? 0,
            "createTime": detail["createTime"] ?? 0,
            "salt": detail["salt"] ?? "",
            "profile": user
        ]
        return ["account": account, "profile": user]
    }

    /// 匿名 cookie：不登录也能浏览歌曲详情/歌词/搜索。
    private func registerAnonymous() -> [String: Any] {
        if let json = post("/api/register/anonimous", form: ["username": Self.anonymousUsername]),
           let raw = json["cookie"] as? String, !raw.isEmpty {
            adoptCookie(from: raw)
        }
        return ["code": 200, "cookie": cookieHeader()]
    }

    /// 歌词代理：`?url=` 里是已经过 encodeURIComponent 的原始地址。
    /// 直接请求它并把原始响应体交还给页面，不做 JSON 包装——
    /// 前端拿到的是歌词文本（或图片字节），包成 JSON 反而会让它解析失败。
    private func handleLyricProxy(_ task: WKURLSchemeTask, url: URL) {
        guard let raw = Self.query(url)["url"],
              let target = URL(string: raw),
              let scheme = target.scheme,
              scheme == "http" || scheme == "https" else {
            respond(task, status: 400, json: ["code": 400, "message": "lyric-proxy 缺少合法的 url 参数"], url: url)
            return
        }

        var request = URLRequest(url: target, timeoutInterval: 10)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            self.queue.async {
                guard self.activeTasks.remove(ObjectIdentifier(task)) != nil else { return }
                if let error, text == nil {
                    Self.deliver(task, status: 200, payload: Data(), contentType: "text/plain; charset=utf-8", url: url)
                    NSLog("[Folia] lyric-proxy failed \(error.localizedDescription) \(target.host ?? "")")
                    return
                }
                let contentType = http?.allHeaderFields
                    .first { String(describing: $0.key).lowercased() == "content-type" }
                    .map { String(describing: $0.value) }
                    ?? "text/plain; charset=utf-8"
                Self.deliver(task, status: http?.statusCode ?? 200, payload: data ?? Data(), contentType: contentType, url: url)
            }
        }.resume()
    }

    // MARK: - HTTP

    private func post(_ path: String, form: [String: String]) -> [String: Any]? {
        guard let url = URL(string: origin + path) else { return nil }
        return request(url, method: "POST", form: form)
    }

    private func request(_ url: URL, method: String, form: [String: String]?, cookie: String? = nil) -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Referer / Content-Type 是网易接口的要求；转发到隧道时不能带。
        if url.host == "music.163.com" {
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
            if let form {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        let header = cookie ?? cookieHeader()
        if !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        if let form {
            request.httpBody = form
                .map { key, value in
                    let escaped = value.addingPercentEncoding(
                        withAllowedCharacters: .alphanumerics
                    ) ?? value
                    return "\(key)=\(escaped)"
                }
                .joined(separator: "&")
                .data(using: .utf8)
        }

        var result: [String: Any]?
        var failed = false
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data else {
                failed = true
                return
            }
            if let http = response as? HTTPURLResponse {
                // 不能写 `allHeaderFields as? [String: String]`：只要有一个非字符串值，
                // 整个转换就会失败，Set-Cookie 会被静默丢掉，登录态随之丢失。
                var headerCookies: [String] = []
                for (key, value) in http.allHeaderFields {
                    guard String(describing: key).lowercased() == "set-cookie" else { continue }
                    if let list = value as? [String] {
                        headerCookies.append(contentsOf: list)
                    } else {
                        headerCookies.append(String(describing: value))
                    }
                }
                if !headerCookies.isEmpty {
                    // 回调跑在 URLSession 自己的线程上，cookie 表只能回串行队列改。
                    let joined = headerCookies.joined(separator: ", ")
                    self.queue.sync { self.absorb(setCookie: joined) }
                }
                // 上游 5xx 视为不可用，让网易接口能退回本地实现。
                if (500...599).contains(http.statusCode) { failed = true }
            }
            result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if result == nil, let text = String(data: data, encoding: .utf8) {
                NSLog("[Folia] api non-json response: \(text.prefix(200))")
            }
        }.resume()

        // 隧道不可达时最多等 10 秒。之前 25 秒会让登录弹窗长时间卡住，看起来像"未响应"。
        if semaphore.wait(timeout: .now() + 10) == .timedOut { return nil }
        if failed && result == nil { return nil }
        return result
    }

    private static var userAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Mobile/15E148 FoliaApp/2.0"
    }

    /// 网易匿名接口要求的固定设备指纹（与社区实现一致）。
    private static let anonymousUsername =
        "MzE3NTQ2MzU1MDU3MzYzNTQwOS4xNTUzNTAzNjcxMDQyLjE1NTM1MDM2NzE1NTEuMC4wLjAuMC4wLjAuMA=="

    // MARK: - Cookie

    private func cookieHeader() -> String {
        Self.joinCookie(cookies)
    }

    private static func joinCookie(_ dict: [String: String]) -> String {
        dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 解析 `k=v; k2=v2` 形式的 cookie 串。
    private static func parseCookieString(_ text: String?) -> [String: String] {
        guard let text, !text.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<eq])
            let val = String(trimmed[trimmed.index(after: eq)...])
            guard !name.isEmpty, !val.isEmpty else { continue }
            out[name] = val
        }
        return out
    }

    /// 合并前端带来的 cookie（前端优先，覆盖桥接层里的同名字段）。
    private func adopt(_ incoming: [String: String]) {
        guard !incoming.isEmpty else { return }
        var changed = false
        for (name, value) in incoming where cookies[name] != value {
            cookies[name] = value
            changed = true
        }
        if changed { persist() }
    }

    private func adoptCookie(from value: Any?) {
        adopt(Self.parseCookieString(value as? String))
    }

    private func absorb(setCookie: String?) {
        guard let setCookie, !setCookie.isEmpty else { return }
        var changed = false
        for (name, val) in Self.parseSetCookie(setCookie) where cookies[name] != val {
            cookies[name] = val
            changed = true
        }
        if changed { persist() }
    }

    /// 解析 Set-Cookie 头。
    /// 不能用 ", " 切分：`Expires=Thu, 23 Oct 2036 ...` 里也有逗号加空格，
    /// 切完会把半截字符串当成 cookie 名塞进表里，登录态反而被搅乱。
    private static func parseSetCookie(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in splitSetCookie(text) {
            let head = line.components(separatedBy: ";").first ?? ""
            guard let eq = head.firstIndex(of: "=") else { continue }
            let name = String(head[head.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(head[head.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard isCookieName(name), !val.isEmpty else { continue }
            out[name] = val
        }
        return out
    }

    private static func splitSetCookie(_ text: String) -> [String] {
        // 一条 cookie 的结束标志是「逗号后紧跟 `name=`」的形式，而不是任意逗号。
        var lines: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                var k = j
                while k < chars.count, chars[k] != "=", chars[k] != ";", chars[k] != "," { k += 1 }
                let candidate = String(chars[j..<min(k, chars.count)])
                if k < chars.count, chars[k] == "=", isCookieName(candidate) {
                    lines.append(current)
                    current = ""
                    i = j
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func isCookieName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    private static var cookieFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("netease-cookies.json")
    }

    private static func loadCookies() -> [String: String] {
        guard let data = try? Data(contentsOf: cookieFile),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private func persist() {
        if let data = try? JSONSerialization.data(withJSONObject: cookies) {
            try? data.write(to: Self.cookieFile, options: .atomic)
        }
    }

    // MARK: - 响应

    private static func deliver(_ task: WKURLSchemeTask, status: Int, json: [String: Any], url: URL? = nil) {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        deliver(task, status: status, payload: payload, contentType: "application/json; charset=utf-8", url: url)
    }

    /// 原样投递响应体（歌词代理用：可能是歌词文本，也可能是封面图字节）。
    private static func deliver(_ task: WKURLSchemeTask, status: Int, payload: Data, contentType: String, url: URL? = nil) {
        let target = url ?? task.request.url ?? URL(string: "https://api.ncm.local/")
        guard let target,
              let response = HTTPURLResponse(
                url: target,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": contentType,
                    "Content-Length": "\(payload.count)",
                    "Cache-Control": "no-store",
                    "Access-Control-Allow-Origin": "*"
                ]
              ) else {
            DispatchQueue.main.async { task.didFailWithError(URLError(.badServerResponse)) }
            return
        }
        DispatchQueue.main.async {
            task.didReceive(response)
            task.didReceive(payload)
            task.didFinish()
        }
    }

    private static func query(_ url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        var dict: [String: String] = [:]
        for item in items where item.value != nil {
            dict[item.name] = item.value
        }
        return dict
    }
}
