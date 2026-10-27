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

    /// 服务端地址，按顺序尝试，第一个「能给出正常应答」的胜出。
    /// 这是自己在服务器上部署的固定域名（Cloudflare 托管解析 + HTTPS），
    /// 地址永久不变，可以分发给任何用户，不依赖开发机或临时隧道。
    /// 换服务器/换域名时改这里，然后重新打包。
    ///
    /// 注意路径前缀：网易接口必须走 `/api/netease`。
    /// 根路径（`https://api.folia-api.top/login/qr/key`）现在直接回
    /// 500「Worker threw exception」，转发会全程失败并退回本地明文通道。
    static let upstreams = [
        "https://app.folia-api.top/api/netease"
    ]

    /// 标记当前可用的隧道下标；坏掉的隧道在一次运行内不再重试，避免每次登录都白等 10 秒。
    private var upstreamIndex = 0
    /// 最近一次二维码 key 是在哪条隧道上签发的（"-" 表示本地兜底生成）。
    /// 校验时用它判断这个 key 上游还认不认。
    private var qrKeySource = ""
    private let origin = "https://music.163.com"

    /// 串行队列：这里既是 cookie 表的唯一访问点，也是「同一 task 只回调一次」的判定点。
    /// 之前用 concurrent + URLSession 回调里直接写 cookie，多接口并发（歌词、封面、详情同时来）
    /// 会把字典写坏，表现为 App 直接闪退回桌面。
    private let queue = DispatchQueue(label: "app.folia.api", qos: .userInitiated)
    /// cookie 表专用锁。
    ///
    /// 不能再用 `queue.sync` 保护 cookie：`request()` 是在 `queue` 上同步阻塞等信号量的，
    /// URLSession 回调若在这期间 `queue.sync` 回写 cookie，就会在同一个串行队列上重入，
    /// 直接卡死到超时——表现就是二维码一直停在「正在加载」。
    /// 用独立锁把 cookie 表的读写和队列解耦。
    private let cookieLock = NSLock()
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
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        deliver(task, status: status, payload: payload, contentType: "application/json; charset=utf-8", url: url, owns: true)
    }

    /// 所有回调的统一出口。
    ///
    /// `owns` 表示这次投递是否负责把 task 从记账表里摘掉（只有走 `respond` 的才摘；
    /// 直接投递的调用方自己已经摘过了）。
    ///
    /// 判定「还在不在表里」和「把回调排到主线程」必须在同一个队列块里完成：
    /// 只要中间露出时间窗，WebKit 就可能在这段时间里 `stop` 掉这个 task，
    /// 之后任何 `didReceive/didFinish` 都会抛 ObjC 异常直接杀进程——表现就是闪退。
    private func deliver(_ task: WKURLSchemeTask, status: Int, payload: Data,
                         contentType: String, url: URL? = nil, owns: Bool = false) {
        queue.async { [weak self] in
            if let self {
                let id = ObjectIdentifier(task)
                if owns {
                    guard self.activeTasks.remove(id) != nil else { return }
                } else {
                    guard self.activeTasks.contains(id) else { return }
                }
            }
            DispatchQueue.main.async {
                Self.push(task, status: status, payload: payload, contentType: contentType, url: url)
            }
        }
    }

    /// 真正调 WebKit。这里已经在主线程，也不再做任何判定。
    private static func push(_ task: WKURLSchemeTask, status: Int, payload: Data, contentType: String, url: URL?) {
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
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(payload)
        task.didFinish()
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

    /// 网易：先并 cookie，再反代；所有隧道都不可用时退回本地明文实现。
    ///
    /// 判定顺序很关键：只有「拿到正常业务 JSON」才算成功。上游 404 / 5xx / HTML
    /// 一律视为不可用（见 `forward`），否则前端看到的就是
    /// 「NetEase gave no QR key: code 404: Not Found」——旧隧道指错服务时就是这样。
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
        // 扫码校验也必须用「已登录」的那份 cookie。
        // 前端轮询时带的是它自己存的匿名 cookie（没有 MUSIC_U），若拿它去转发，
        // 上游会把这次扫码当成另一次会话，回 803 却没有 MUSIC_U，
        // 前端就会报「网易云未下发登录态，请重试扫码」。
        let needsLoginCookie = isAccountRoute || route == "/login/qr/check"
        let effective = needsLoginCookie
            ? (forwarded["MUSIC_U"] != nil ? Self.joinCookie(forwarded) : cookieHeader())
            : (forwarded.isEmpty ? cookieHeader() : Self.joinCookie(forwarded))

        queue.async { [weak self] in
            guard let self, self.activeTasks.contains(ObjectIdentifier(task)) else { return }
            if isAccountRoute {
                NSLog("[Folia] \(route) cookie=\(effective.isEmpty ? "none" : "len\(effective.count)")")
            }
            if !forwarded.isEmpty { self.adopt(forwarded) }

            // 二维码会话是有状态的：unikey 只跟签发它的那条服务端（及其到微信/网易的会话）有效。
            // 只有「本地兜底签发的 key」才必须走本地校验；
            // 如果 key 来自上游（中途换了隧道也算），仍然要转发给上游——上游按 key 查自己的表就能对上，
            // 换到本地明文通道反而查不到这个 key，只会回 800（二维码过期）或永远 802（未在手机上确认）。
            if route == "/login/qr/check", self.keyIsLocallyIssued(query["key"] ?? "") {
                NSLog("[Folia] qr key issued locally, use local check")
                let result = self.dispatch(route: route, query: query, cookie: effective)
                self.respond(task, status: 200, json: result, url: url)
                return
            }

            // 主路径：转发到自己的服务端，它走官方加密通道，803 时能真正拿到 MUSIC_U。
            let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
            switch self.proxy(route: route, rawQuery: rawQuery, cookie: effective) {
            case .ok(let proxied):
                if route == "/login/qr/key" { self.noteQRKey(proxied, source: "tunnel\(self.upstreamIndex)") }
                self.respond(task, status: 200, json: proxied, url: url)
                return
            case .upstreamTimeout(let status):
                // 服务端自己的上游超时（12s）。这是「慢」，不是「这个路由不存在」，
                // 绝不能落进本地兜底：本地兜底没有 /playlist/detail、/song/url/v1 这些路由，
                // 只会回一个假的 code:200，前端当成功解析后字段全空 —— 进歌单闪退、播放卡 00:00。
                NSLog("[Folia] upstream timeout \(route) -> \(status)")
                self.respond(task, status: status, json: [
                    "code": status,
                    "message": "服务端上游超时，请稍后重试"
                ], url: url)
                return
            case nil:
                break
            }
            NSLog("[Folia] upstream unreachable, fallback to local \(route)")
            let result = self.dispatch(route: route, query: query, cookie: effective)
            if route == "/login/qr/key" { self.noteQRKey(result, source: "-") }
            // 本地明文通道不会下发 MUSIC_U，登录态拿不到。
            // 这种情况必须如实报错，不能让界面一直停在「等待扫码 / 未在手机上确认」。
            if route == "/login/qr/check",
               let code = result["code"] as? Int, code == 803,
               self.cookieHeaderValue().contains("MUSIC_U") == false {
                NSLog("[Folia] local qr check has no MUSIC_U")
                self.respond(task, status: 200, json: ["code": 502, "message": "登录服务暂不可用，请稍后重试"], url: url)
                return
            }
            self.respond(task, status: 200, json: result, url: url)
        }
    }

    // MARK: - 反向代理

    /// 记下「这个 key 是谁签发的」。上游应答形如 `{"data":{"unikey":"..."}}`。
    private func noteQRKey(_ json: [String: Any], source: String) {
        let data = json["data"] as? [String: Any]
        guard let key = data?["unikey"] as? String, !key.isEmpty else { return }
        qrKeySource = source + "|" + key
        NSLog("[Folia] qr key from \(source)")
    }

    /// key 是否由本地明文通道签发。只有这种 key 上游不认识，必须本地校验。
    private func keyIsLocallyIssued(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return qrKeySource == "-|" + key
    }

    /// 网易接口转发。
    ///
    /// `upstreams` 的元素自带 `/api/netease` 前缀，而这里的 route 是剥掉前缀后的
    /// 相对路径（`/login/qr/key`），所以拼回去就是 `https://host/api/netease/login/qr/key`。
    /// 酷狗/QQ 的 route 本身已经带 `/api/xxx`，直接拼即可，两种都能对上。
    ///
    /// 返回值区分三态，调用方必须据此决定行为：
    /// - `.ok(JSON)`   拿到正常业务 JSON，直接交给前端
    /// - `.upstreamTimeout`  服务端自己的上游超时（12s），这是「慢」而不是「错」，
    ///   必须原样回 504，绝不能回落到本地兜底——本地兜底没有这个路由，
    ///   只会返回一个假的 code:200，前端把它当成功解析后字段全空，进歌单就崩。
    private enum ForwardResult {
        case ok([String: Any])
        case upstreamTimeout(Int)
    }

    private func proxy(route: String, rawQuery: String?, cookie: String) -> ForwardResult? {
        var path = route
        if let rawQuery, !rawQuery.isEmpty {
            // 网易接口的 cookie 已经在 effective 里并进表了，去掉前端拼的那份，
            // 避免上游收到两份互相矛盾的 cookie。
            let kept = rawQuery.split(separator: "&").filter { !$0.hasPrefix("cookie=") }.joined(separator: "&")
            if !kept.isEmpty { path += "?\(kept)" }
        }
        NSLog("[Folia] proxy \(route)")
        return forward(path, cookie: cookie)
    }

    /// 其它平台转发：路径原样透传。
    private func proxy(path: String, rawQuery: String?, cookie: String) -> [String: Any]? {
        var target = path
        if let rawQuery, !rawQuery.isEmpty {
            target += "?\(rawQuery)"
        }
        NSLog("[Folia] proxy \(path)")
        guard let result = forward(target, cookie: cookie) else { return nil }
        switch result {
        case .ok(let json): return json
        case .upstreamTimeout: return nil
        }
    }

    /// 依次尝试所有隧道，返回第一个「健康」的应答。
    ///
    /// quick tunnel 失效时不会连不上，而是根路径照样 200、业务路由全变
    /// `{"code":404,...,"msg":"Not Found"}`。所以只看「拿到 JSON」不够：
    /// 这种 404 信封必须当成隧道不可用，否则会把错误原样交给前端，
    /// 前端就报「NetEase gave no QR key: code 404: Not Found」。
    ///
    /// 服务端把自己上游的失败也包成 200 + `{"code":504,"message":"netease upstream timeout ..."}`，
    /// 这种信封同样不能当成功交给前端（前端 `C()` 在 online 模式下只看 `code`，
    /// 会把它当成正常数据），必须单独识别成 `.upstreamTimeout`。
    private func forward(_ path: String, cookie: String) -> ForwardResult? {
        let total = Self.upstreams.count
        var timedOut: Int?
        for offset in 0..<total {
            let index = (upstreamIndex + offset) % total
            let base = Self.upstreams[index]
            guard let url = URL(string: base + path),
                  let json = request(url, method: "GET", form: nil, cookie: cookie) else {
                NSLog("[Folia] upstream #\(index) unreachable \(path)")
                continue
            }
            if Self.isUpstreamTimeout(json) {
                // 同一条隧道换个时间重试也不会更快，直接把它记下来，别再耗第二次 30 秒。
                NSLog("[Folia] upstream #\(index) reported its own upstream timeout \(path)")
                timedOut = 504
                continue
            }
            if Self.isUnavailable(json) {
                NSLog("[Folia] upstream #\(index) returned unavailable envelope \(path)")
                continue
            }
            if index != upstreamIndex {
                NSLog("[Folia] switch upstream to #\(index)")
                upstreamIndex = index
            }
            return .ok(json)
        }
        if let status = timedOut { return .upstreamTimeout(status) }
        return nil
    }

    /// 上游「没有这个接口」的应答：404 信封。
    private static func isUnavailable(_ json: [String: Any]) -> Bool {
        if let code = json["code"] as? Int, code == 404 { return true }
        if let msg = json["msg"] as? String, msg == "Not Found" { return true }
        return false
    }

    /// 服务端自报的上游超时：`{"code":504,"message":"netease upstream timeout ..."}`。
    ///
    /// 只认 504/502 且 message 明确提到 upstream，避免把业务里正常的 502/504 误判。
    private static func isUpstreamTimeout(_ json: [String: Any]) -> Bool {
        guard let code = json["code"] as? Int, code == 504 || code == 502 else { return false }
        let message = (json["message"] as? String) ?? ""
        return message.lowercased().contains("upstream")
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
            _ = mutateCookies { (table: inout [String: String]) -> Void in
                for name in names { table.removeValue(forKey: name) }
                if names.isEmpty { table.removeAll() }
            }
            persist()
            return ["code": 200]
        default:
            // 这里绝不能回 code:200。
            //
            // 之前返回 `{"code":200,"message":"local fallback: unsupported route ..."}`，
            // 前端 `er()` 只看 `code`（`e.code != null && Number(e.code) !== 200`），
            // 于是把它当成合法成功响应：`getPlaylistDetail` 拿到没有 `playlist` 的对象，
            // `getAudioSource` 拿到没有 `data` 的对象、`data[0]` 是 undefined，
            // 逐层取值时抛 TypeError —— 表现就是进歌单闪退、播放卡在 00:00。
            // 回 502 才能让前端走自己的错误分支（`tr()` 抛出 unavailable），
            // 由播放器给出「不可用」提示，而不是崩溃。
            NSLog("[Folia] local fallback has no route \(route)")
            return ["code": 502, "message": "服务端暂不可用：\(route)"]
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

        // 这里只做本地绘制，绝不能再调 `proxy`。
        //
        // `dispatch` 只在主路径转发失败后才会被调用（见 `handleNetease`），
        // 也就是说上游刚刚已经失败过一次；此时再转发一遍只会把这段代码
        // 在串行队列上多阻塞 10 秒，前端 20 秒的硬超时会被吃掉一半，
        // 表现就是二维码弹窗一直停在「正在加载」。
        //
        // 本地二维码和上游的是同一个内容：`https://music.163.com/login?codekey=<key>`，
        // 上游 `login_qr_create` 也只是把这个链接画成图。
        //
        // 关键约束：二维码里装的必须是「能对上轮询通道」的那把 key。
        // 轮询走 `type: 3`（eapi `client/login`），而 `unikey?type=3` 签发的 key
        // 对应的就是 `music.163.com/login?codekey=` 这个链接——
        // 两者是同一把 key，扫完 eapi 侧能看到 802/803，不会回 800。
        // 反过来说：不要在这里换 URL 形式、也不要另外签一把 key，否则一定对不上。
        let loginURL = "https://music.163.com/login?codekey=\(key)"
        NSLog("[Folia] qr create locally key=\(key)")
        guard let qrimg = QRTool.dataURL(for: loginURL), !qrimg.isEmpty else {
            return ["code": 502, "message": "二维码生成失败"]
        }
        return [
            "code": 200,
            "data": [
                "code": 200,
                "qrurl": loginURL,
                "qrimg": qrimg
            ]
        ]
    }

    /// 二维码状态轮询。
    ///
    /// `type` 必须和签发 key 时一致（都是 3）。上游 `login_qr_check` 里写死的也是
    /// `type: 3`，之前这里写 1 属于笔误。
    private func qrCheck(key: String) -> [String: Any] {
        guard !key.isEmpty else { return ["code": 400, "message": "missing key"] }
        guard let json = post("/api/login/qrcode/client/login", form: ["key": key, "type": "3"]) else {
            return ["code": 801, "message": "等待扫码"]
        }
        guard let code = json["code"] as? Int else { return ["code": 801, "message": "等待扫码"] }

        switch code {
        case 803:
            let payloadCookie = json["cookie"] as? String ?? ""
            _ = mutateCookies { (table: inout [String: String]) -> Void in
                NSLog(
                    "[Folia] netease 803 jsonCookie="
                        + (payloadCookie.isEmpty
                            ? "empty"
                            : "len\(payloadCookie.count) hasMUSIC_U=\(payloadCookie.contains("MUSIC_U"))")
                        + " table=len\(table.count) hasMUSIC_U=\(table["MUSIC_U"] != nil)"
                )
            }
            adoptCookie(from: json["cookie"])
            guard hasMusicU() else {
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
                    self.deliver(task, status: 200, payload: Data(), contentType: "text/plain; charset=utf-8", url: url)
                    NSLog("[Folia] lyric-proxy failed \(error.localizedDescription) \(target.host ?? "")")
                    return
                }
                let contentType = http?.allHeaderFields
                    .first { String(describing: $0.key).lowercased() == "content-type" }
                    .map { String(describing: $0.value) }
                    ?? "text/plain; charset=utf-8"
                self.deliver(task, status: http?.statusCode ?? 200, payload: data ?? Data(), contentType: contentType, url: url)
            }
        }.resume()
    }

    // MARK: - HTTP

    private func post(_ path: String, form: [String: String]) -> [String: Any]? {
        guard let url = URL(string: origin + path) else { return nil }
        return request(url, method: "POST", form: form)
    }

    private func request(_ url: URL, method: String, form: [String: String]?, cookie: String? = nil) -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 30)
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
                    let joined = headerCookies.joined(separator: ", ")
                    // 这里绝对不能 `queue.sync`：request() 正阻塞在 queue 上等信号量，
                    // 回调再往同一个串行队列 sync 就是自锁，必然等到超时。
                    // absorb 内部只碰 cookieLock，与本队列无关。
                    self.absorb(setCookie: joined)
                }
                // 非 2xx 一律视为不可用：上游 404 时说明路由不存在（隧道指错了服务），
                // 5xx 时说明服务端挂了，两种情况都不应该把应答当成成功交给前端。
                if !(200...299).contains(http.statusCode) { failed = true }
            }
            result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if result == nil, let text = String(data: data, encoding: .utf8) {
                NSLog("[Folia] api non-json response: \(text.prefix(200))")
            }
            if failed { result = nil }
        }.resume()

        // 必须比服务端自己的上游超时（12s）长，否则我们会在服务端把 504 信封写回来之前就放弃，
        // 拿不到那个信封 → forward 全部 miss → 落到本地兜底 → 前端拿到假 code:200 →
        // 进歌单闪退、播放卡 00:00。歌单详情实测最慢要 8.8s，加上隧道往返留到 35s。
        if semaphore.wait(timeout: .now() + 35) == .timedOut { return nil }
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

    /// 在 cookie 锁内读改表。返回闭包的返回值。
    private func mutateCookies<T>(_ body: (inout [String: String]) -> T) -> T {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        return body(&cookies)
    }

    private func cookieHeader() -> String {
        Self.joinCookie(mutateCookies { $0 })
    }

    /// 供主线程外的判定读取，避免直接碰 `cookies`。
    private func cookieHeaderValue() -> String {
        cookieHeader()
    }

    /// cookie 表里有没有真实登录态。必须和 cookie 表同一把锁下读，不能直接访问 `cookies`。
    private func hasMusicU() -> Bool {
        mutateCookies { $0["MUSIC_U"] != nil }
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
        let changed = mutateCookies { (table: inout [String: String]) -> Bool in
            var changed = false
            for (name, value) in incoming where table[name] != value {
                table[name] = value
                changed = true
            }
            return changed
        }
        if changed { persist() }
    }

    private func adoptCookie(from value: Any?) {
        adopt(Self.parseCookieString(value as? String))
    }

    private func absorb(setCookie: String?) {
        guard let setCookie, !setCookie.isEmpty else { return }
        let parsed = Self.parseSetCookie(setCookie)
        let changed = mutateCookies { (table: inout [String: String]) -> Bool in
            var changed = false
            for (name, val) in parsed where table[name] != val {
                table[name] = val
                changed = true
            }
            return changed
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
        // 先在锁内取快照，再落盘：写文件不该占着 cookie 锁。
        let snapshot = mutateCookies { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
            try? data.write(to: Self.cookieFile, options: .atomic)
        }
    }

    // MARK: - 响应

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
