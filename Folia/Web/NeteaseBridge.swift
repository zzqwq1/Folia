import Foundation
import WebKit

/// 网页版把网易云接口写在 `/api/netease/...` 上，静态包里没有这个目录，
/// 于是请求会回落到 index.html（HTML），前端解析 JSON 失败 → 扫码登录报 start-error。
///
/// 这里在自定义 scheme 里把 `/api/netease/*` 截下来，翻译成网易官方接口的调用：
/// 入参形状保持 NeteaseCloudMusicApi 的约定（前端直接按它的字段名读），
/// 出参由网易官方的 eapi / weapi 返回结构重排成前端期望的形状。
/// 全部本地实现，不依赖自建 API 服务，也不做任何云端更新检查。
final class NeteaseBridge {
    static let shared = NeteaseBridge()

    /// 网页版里的接口前缀。
    static let prefix = "/api/netease"
    /// 壳内页面（folia://）把接口指向这个主机，由本层截获。
    static let host = "api.ncm.local"

    private let origin = "https://music.163.com"
    private let queue = DispatchQueue(label: "app.folia.netease", qos: .userInitiated, attributes: .concurrent)
    private var cookies: [String: String] = [:]

    private init() {
        cookies = Self.loadCookies()
    }

    // MARK: - 入口

    func shouldHandle(_ url: URL) -> Bool {
        // 页面本身（index.html / assets/*）也挂在 api.ncm.local 这个 host 下，
        // 但它们是静态资源，必须交给 BundleSchemeHandler 读磁盘；
        // 否则首页会显示成桥接层返回的 JSON。
        return url.path.hasPrefix(Self.prefix)
    }

    func handle(_ task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            Self.finish(task, status: 400, json: ["code": 400, "message": "bad url"])
            return
        }
        // 剥掉 /api/netease 前缀拿到真正的接口路径。
        var route = url.path
        if route.hasPrefix(Self.prefix) {
            route = String(route.dropFirst(Self.prefix.count))
        } else if let range = route.range(of: "/api/netease") {
            route = String(route[range.upperBound...])
        }
        if route.isEmpty { route = "/" }
        let query = Self.query(url)
        // 前端把 localStorage 里的 cookie 拼在 ?cookie= 上，这是权威来源：
        // 扫码成功那一刻前端已写入 localStorage，而桥接层进程内的表可能还没拿到，
        // 不合并就会出现「刚扫码成功，紧接着 login/status 说没有账号」。
        // 注意：前端在没登录时会退而带上「匿名 cookie」，那个没有 MUSIC_U，
        // 只对歌曲/歌词接口有用；对账号类接口必须忽略，否则会把匿名态当登录态。
        let forwarded = Self.parseCookieString(query["cookie"])
        let isAccountRoute = route == "/login/status" || route == "/user/account"
        let effective = isAccountRoute
            ? (forwarded["MUSIC_U"] != nil ? Self.joinCookie(forwarded) : cookieHeader())
            : (forwarded.isEmpty ? cookieHeader() : Self.joinCookie(forwarded))

        queue.async { [weak self] in
            guard let self else { return }
            if isAccountRoute {
                // 对应前端诊断里的 "login cookie=no"：这里能看出真实登录态到底有没有。
                NSLog("[Folia] \(route) cookie=\(effective.isEmpty ? "none" : "len\(effective.count)")")
            }
            if !forwarded.isEmpty { self.adopt(forwarded) }
            let result = self.dispatch(route: route, query: query, cookie: effective)
            Self.finish(task, status: 200, json: result, url: url)
        }
    }

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
            // 前端会把待注销的 cookie 一并带来，只清这些字段，
            // 避免把匿名 cookie 也删掉导致歌曲接口变慢。
            let names = Self.parseCookieString(query["cookie"]).keys
            for name in names { cookies.removeValue(forKey: name) }
            if names.isEmpty { cookies.removeAll() }
            persist()
            return ["code": 200]
        default:
            // 其它接口静态包本来就跑不通，给个明确的 JSON 让前端走「接口不可用」分支，
            // 而不是拿 HTML 去 JSON.parse 抛异常闪烁。
            return ["code": 200, "message": "local bridge: unsupported route \(route)"]
        }
    }

    // MARK: - 二维码登录

    private func qrKey() -> [String: Any] {
        guard let json = post("/api/login/qrcode/unikey", form: ["type": "3"]),
              let key = json["unikey"] as? String, !key.isEmpty else {
            return ["code": 502, "message": "网易云接口无响应"]
        }
        // 前端只认 data.unikey，保持 NeteaseCloudMusicApi 的返回形状。
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
            // 803 带登录态，有两种下发方式：JSON 的 cookie 字段，或响应的 Set-Cookie。
            // 后者已经在 request 里被 absorb 收进 cookie 表，所以这里统一看整张表。
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
                // 没拿到登录态就不要回 803，否则前端的 checkLogin 会把空 cookie 写进
                // localStorage 并当成登录成功，随后 refresh 必然失败。
                NSLog("[Folia] netease 803 without MUSIC_U, giving up")
                return ["code": 502, "message": "网易云未下发登录态，请重试扫码"]
            }
            let header = cookieHeader()
            return ["code": 803, "message": "授权登陆成功", "cookie": header]
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

    // MARK: - 账号

    private func loginStatus(cookie: String) -> [String: Any] {
        if let payload = accountPayload(cookie: cookie) {
            return ["code": 200, "data": merged(["code": 200], payload)]
        }
        // 拿不到账号时回 301（未登录），让前端走「未登录」分支，
        // 而不是拿到一个 code=200 但 profile 为空的响应去判 refresh-failed。
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
    /// 网易侧登录态有几秒钟落地延迟，所以失败时短重试几次。
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

    // MARK: - HTTP

    /// 表单 POST（网易的 unikey / client/login / anonimous 都走这个）。
    private func post(_ path: String, form: [String: String]) -> [String: Any]? {
        guard let url = URL(string: origin + path) else { return nil }
        return request(url, method: "POST", form: form)
    }

    private func request(_ url: URL, method: String, form: [String: String]?, cookie: String? = nil) -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
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
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data else { return }
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
                    self.absorb(setCookie: headerCookies.joined(separator: ", "))
                }
            }
            result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if result == nil, let text = String(data: data, encoding: .utf8) {
                NSLog("[Folia] netease non-json response: \(text.prefix(200))")
            }
        }.resume()

        if semaphore.wait(timeout: .now() + 20) == .timedOut { return nil }
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

    /// 803 / anonimous 把 cookie 放在 JSON 字段里，直接收下。
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

    private static func finish(_ task: WKURLSchemeTask, status: Int, json: [String: Any], url: URL? = nil) {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let response = HTTPURLResponse(
            url: url ?? task.request.url ?? URL(string: "https://api.ncm.local/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": "\(payload.count)",
                "Cache-Control": "no-store",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
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
