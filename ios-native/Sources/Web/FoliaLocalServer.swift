import Foundation
import Network

/// 本地 HTTP 服务器：WKWebView 加载的原版前端（bundle 内 dist）与线上 API 走同源，
/// 规避 Cloudflare 无 CORS 预检（405）以及 WKURLSchemeHandler 读不到 POST body 的限制。
/// 静态文件从 bundle 的 dist 目录提供；`/api/`（以及旧的 `/netease/` `/qq/` `/kugou/`）前缀请求
/// 原样转发到 https://app.folia-api.top。
final class FoliaLocalServer {
    static let shared = FoliaLocalServer()

    private let port: UInt16 = 48231
    private let upstream = "https://app.folia-api.top"
    private let queue = DispatchQueue(label: "folia.local.server")
    private var listener: NWListener?
    private let session: URLSession
    /// 登录相关的请求单独一条会话：禁缓存、超时放宽到登录轮询能接受的范围。
    private let loginSession: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)

        let loginConfig = URLSessionConfiguration.ephemeral
        loginConfig.timeoutIntervalForRequest = 20
        loginConfig.timeoutIntervalForResource = 30
        loginConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        loginConfig.httpCookieStorage = nil
        loginSession = URLSession(configuration: loginConfig)
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
            let listener = try NWListener(using: params, on: endpointPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { (state: NWListener.State) in
                if case .failed(let error) = state {
                    NSLog("[FoliaLocalServer] listener failed: %@", String(describing: error))
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            record("server listening on 127.0.0.1:\(port), upstream \(upstream)")
            probeUpstreamOnce()
        } catch {
            NSLog("[FoliaLocalServer] failed to start on %d: %@", port, String(describing: error))
        }
    }

    // ---- 现场诊断 ----
    // 设备上没有 Mac 抓日志：把每次请求与上游往返的结果留在内存里，页面通过 `/__folia/diag` 取走并显示。
    // 静态文件加载成功只说明本机服务器活着，登录成败要看这里的落点。

    private let diagQueue = DispatchQueue(label: "folia.local.diag")
    private var diagEvents: [String] = []

    private func record(_ line: String) {
        NSLog("[FoliaLocalServer] %@", line)
        diagQueue.sync {
            diagEvents.append(line)
            if diagEvents.count > 200 { diagEvents.removeFirst(diagEvents.count - 200) }
        }
    }

    private func diagSnapshot() -> [String] {
        diagQueue.sync { diagEvents }
    }

    /// 绕开 WKWebView，用原生 URLSession 直连一次上游登录接口：
    /// 通了说明网络没问题、问题在本机代理与页面之间；不通就是这台设备到上游的路由/DNS/TLS 有问题。
    private func probeUpstreamOnce() {
        guard let url = URL(string: "\(upstream)/api/netease/login/qr/key") else { return }
        let startedAt = Date()
        var request = URLRequest(url: url)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let error = error as NSError? {
                self.record("upstream probe FAILED in \(elapsed)ms: \(error.domain) \(error.code) \(error.localizedDescription)")
                return
            }
            let http = response as? HTTPURLResponse
            let encoding = http?.allHeaderFields["Content-Encoding"] as? String ?? "-"
            self.record("upstream probe -> \(http?.statusCode ?? 0) in \(elapsed)ms bytes=\(data?.count ?? 0) contentEncoding=\(encoding)")
        }.resume()
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                self.readRequest(connection, buffer: Data())
            }
        }
        connection.start(queue: queue)
    }

    // ---- HTTP 请求解析 ----

    private struct HTTPRequest {
        let method: String
        let path: String // 含 query
        let headers: [String: String]
        let body: Data
    }

    /// 同一个 URL 只建一次：登录轮询 2 秒打一次，每次新建 URL 会让底层没有机会复用连接。
    private var targetCache: [String: URL] = [:]

    /// 一条响应可以带多个 `Set-Cookie`：按字典收发会把它们合成一行、后写的盖掉先写的，登录态那一枚可能就丢了。
    private struct HTTPReply {
        let status: Int
        var headers: [String: String]
        var cookies: [String]
        let body: Data
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }

            if let request = self.parseRequestIfComplete(buf) {
                self.process(request, on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.readRequest(connection, buffer: buf)
        }
    }

    private func parseRequestIfComplete(_ buffer: Data) -> HTTPRequest? {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.startIndex)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key.lowercased()] = value
        }

        var body = Data()
        if let contentLength = headers["content-length"].flatMap(Int.init), contentLength > 0 {
            let bodyRange = (headerEnd.startIndex + 4)..<buffer.endIndex
            let available = buffer.subdata(in: bodyRange)
            guard available.count >= contentLength else { return nil } // body 未收完
            body = available.prefix(contentLength)
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    // ---- 路由 ----

    private func process(_ request: HTTPRequest, on connection: NWConnection) {
        record("\(request.method) \(request.path)")
        guard let url = URL(string: "http://127.0.0.1\(request.path)") else {
            sendResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("bad request".utf8), on: connection)
            return
        }
        let pathOnly = url.path

        // 页面取诊断用；带 `*` 的 CORS 头，页面从任意源都能读。
        if pathOnly == "/__folia/diag" {
            let json = (try? JSONSerialization.data(withJSONObject: ["events": diagSnapshot()], options: [])) ?? Data("{}".utf8)
            sendResponse(status: 200, headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-store",
            ], body: json, on: connection)
            return
        }

        if request.method == "OPTIONS" {
            // 预检：页面跨源访问本服务器时，不带这几个头整个请求就会被浏览器拦下。
            sendResponse(status: 204, headers: [
                "Access-Control-Allow-Origin": request.headers["origin"] ?? "*",
                "Access-Control-Allow-Credentials": "true",
                "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": request.headers["access-control-request-headers"] ?? "Content-Type, X-QQ-Session, X-Requested-With",
                "Access-Control-Max-Age": "86400",
                "Vary": "Origin",
            ], body: Data(), on: connection)
            return
        }

        if isProxyPath(pathOnly) {
            proxy(request, on: connection)
        } else {
            serveStatic(pathOnly, on: connection)
        }
    }

    /// 平台前缀有两种写法：`/api/<平台>/...`（构建注入的默认值）和旧的 `/<平台>/...`。
    /// 线上 Worker 两种都认，转发时原样送过去即可。
    private func isProxyPath(_ path: String) -> Bool {
        path.hasPrefix("/netease/") || path.hasPrefix("/qq/") ||
            path.hasPrefix("/kugou/") || path.hasPrefix("/api/")
    }

    // ---- API 代理 ----

    private let hopByHopHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host",
    ]

    private func proxy(_ request: HTTPRequest, on connection: NWConnection) {
        let forwardPath = request.path // path 与 query 一起原样转发，避免 query 里的转义被二次编码。
        let targetKey = upstream + forwardPath
        let target: URL
        if let cached = targetCache[targetKey] {
            target = cached
        } else if let built = URL(string: targetKey) {
            target = built
            targetCache[targetKey] = built
        } else {
            sendResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("bad path".utf8), on: connection)
            return
        }

        // 登录三步（扫码取 key / 出图 / 轮询）最怕被缓存成旧答案：用固定 URL 再叠 no-cache，
        // 有些网关按 URL 命中缓存，no-store 反而不起作用。
        let isLogin = forwardPath.contains("/login")
        let noCache = isLogin || request.headers["cache-control"]?.contains("no-cache") == true

        var urlRequest = URLRequest(url: target)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body
        urlRequest.httpShouldHandleCookies = false
        let bodyMethod = ["POST", "PUT", "PATCH"].contains(request.method)
        for (key, value) in request.headers {
            if hopByHopHeaders.contains(key) { continue }
            // 转发时 body 已按原字节重发，带过去的 Content-Length 可能已被 URLSession 改写；
            // Accept-Encoding 也要交回 URLSession 决定，否则它按声明返回压缩体而我们不解压。
            if key == "content-length" || key == "accept-encoding" { continue }
            // 页面与代理现在同源，浏览器会自动补 Origin；原样转发会让上游把它当成跨站请求。
            if key == "origin" { continue }
            // fetch 的 keepalive / sec-* 头在代理连接上无意义。
            if key.hasPrefix("sec-") { continue }
            // 本机的 cookie（WKWebView 存的那份）不该覆盖上游自己的会话：登录态由前端用
            // `?cookie=` 显式带上（netease.ts 的 fetchWithCreds），这里转发 cookie 头只会串味。
            if key == "cookie" { continue }
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if bodyMethod && request.headers["content-type"] == nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if noCache {
            urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            urlRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }

        let startedAt = Date()
        let task = (isLogin ? loginSession : session).dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            let httpResponse = response as? HTTPURLResponse
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let error {
                let e = error as NSError
                self.record("proxy FAILED \(request.method) \(target.path) in \(elapsed)ms: \(e.domain) \(e.code) \(e.localizedDescription)")
                self.sendResponse(status: 502, headers: ["Content-Type": "application/json"],
                                  body: Data(#"{"code":502,"msg":"proxy failed"}"#.utf8), on: connection)
                return
            }
            let status = httpResponse?.statusCode ?? 502
            let rawBody = data ?? Data()
            // URLSession 谈好压缩后会自己把体解压好，但响应头往往是上游原样：解压后的 JSON 配上
            // `Content-Encoding: gzip`，WebKit 会再解一次压，直接 `TypeError: Load failed`。
            // 只有确认交回来的仍是压缩体（gzip 魔数 1f 8b）时才保留这枚头。
            let bodyIsCompressed = rawBody.count >= 2
                && rawBody[rawBody.startIndex] == 0x1f
                && rawBody[rawBody.startIndex + 1] == 0x8b
            var headers: [String: String] = [:]
            var cookies: [String] = []
            if let all = httpResponse?.allHeaderFields as? [String: Any] {
                for (key, value) in all {
                    let keyLower = key.lowercased()
                    if self.hopByHopHeaders.contains(keyLower) { continue }
                    if keyLower == "content-length" { continue }
                    if keyLower == "content-encoding" && !bodyIsCompressed { continue }
                    if keyLower == "set-cookie" {
                        if let one = value as? String {
                            cookies.append(one)
                        } else if let many = value as? [String] {
                            cookies.append(contentsOf: many)
                        }
                        continue
                    }
                    // CORS 头由下面按同源重写：上游给的是 app.folia-api.top 的那份，留着会和页面自己的源打架。
                    if keyLower.hasPrefix("access-control-") { continue }
                    let text = value as? String ?? String(describing: value)
                    headers[key] = text
                }
            }
            // 页面经 http://127.0.0.1:48231 访问本服务器，是跨源请求：CORS 头不补，fetch 会直接失败，
            // 前端只能报「登录失败」。带 cookie 的请求不允许用 `*`，所以照抄请求的 Origin 并允许凭据。
            headers["Access-Control-Allow-Origin"] = request.headers["origin"] ?? "*"
            headers["Access-Control-Allow-Credentials"] = "true"
            headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
            if let requested = request.headers["access-control-request-headers"] {
                headers["Access-Control-Allow-Headers"] = requested
            } else {
                headers["Access-Control-Allow-Headers"] = "Content-Type, X-QQ-Session, X-Requested-With"
            }
            headers["Vary"] = "Origin"
            if cookies.contains(where: { Self.isSessionCookie($0) }) {
                self.record("proxy \(request.method) \(target.path) -> \(status) in \(elapsed)ms, session cookie from upstream")
            } else {
                let encoding = httpResponse?.allHeaderFields["Content-Encoding"] as? String ?? "-"
                let type = httpResponse?.allHeaderFields["Content-Type"] as? String ?? "-"
                self.record("proxy \(request.method) \(target.path) -> \(status) in \(elapsed)ms bytes=\(data?.count ?? 0) type=\(type) enc=\(encoding)")
            }
            let body = rawBody
            self.sendResponse(status: status, headers: headers, cookies: cookies, body: body, on: connection)
        }
        task.resume()
    }

    /// 登录态那一枚 cookie 的名字（网易云 MUSIC_U、QQ 的 qm_keyst、酷狗 kg_mid 等），只用来打日志。
    private static func isSessionCookie(_ header: String) -> Bool {
        let name = header.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        return name.contains("music_u") || name.contains("session") || name == "qm_keyst" || name == "kg_mid"
    }

    // ---- 静态文件 ----

    private func serveStatic(_ path: String, on connection: NWConnection) {
        var relative = path
        if relative == "/" { relative = "/index.html" }
        // 去前导斜杠并拒绝路径穿越
        while relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.contains("..") && !relative.contains("\0") else {
            sendResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found".utf8), on: connection)
            return
        }

        let distURL = Bundle.main.bundleURL.appendingPathComponent("dist", isDirectory: true)
        let fileURL = distURL.appendingPathComponent(relative)

        // 静态文件也要允许跨源：页面可能是 file:// 或别的源加载的，挡掉的话整个界面都起不来。
        if let data = try? Data(contentsOf: fileURL) {
            sendStatic(headers: ["Content-Type": mimeType(for: relative)], body: data, on: connection)
            return
        }

        // runtime-config.js 只在 Docker 网关里存在（那里由 nginx 现写），bundle 里没有。
        // 真发一次空配置，而不是掉进下面的兜底：脚本拿到 HTML 会被 WKWebView 当 MIME 不符拒掉。
        if relative == "runtime-config.js" {
            let script = Data("window.__FOLIA_RUNTIME_CONFIG__ = window.__FOLIA_RUNTIME_CONFIG__ || {};\n".utf8)
            sendStatic(headers: ["Content-Type": mimeType(for: relative)], body: script, on: connection)
            return
        }

        // 静态资源缺失要回 404：回 index.html 的话，带 MIME 校验的请求会报一个与真正原因无关的错。
        let missing = !(relative as NSString).pathExtension.isEmpty
        let indexURL = distURL.appendingPathComponent("index.html")
        if !missing, let indexData = try? Data(contentsOf: indexURL) {
            sendStatic(headers: ["Content-Type": "text/html; charset=utf-8"], body: indexData, on: connection)
        } else {
            sendResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found".utf8), on: connection)
        }
    }

    /// 静态响应统一带上跨源头（不带凭据：静态资源不读 cookie）。
    private func sendStatic(headers: [String: String], body: Data, on connection: NWConnection) {
        var all = headers
        all["Access-Control-Allow-Origin"] = "*"
        sendResponse(status: 200, headers: all, body: body, on: connection)
    }

    private func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wasm": return "application/wasm"
        case "webmanifest": return "application/manifest+json"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    // ---- 响应 ----

    private func sendResponse(status: Int, headers: [String: String], cookies: [String] = [], body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        for cookie in cookies {
            head += "Set-Cookie: \(cookie)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }
}
