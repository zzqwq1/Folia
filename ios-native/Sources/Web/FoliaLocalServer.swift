import Foundation
import Network

/// 本地 HTTP 服务器：WKWebView 加载的原版前端（bundle 内 dist）与线上 API 走同源，
/// 规避 Cloudflare 无 CORS 预检（405）以及 WKURLSchemeHandler 读不到 POST body 的限制。
/// 静态文件从 bundle 的 dist 目录提供；`/netease/` `/qq/` `/kugou/` `/api/` 前缀请求
/// 原样转发到 https://app.folia-api.top（Cookie 由 URLSession 自动存储与回传，网易云登录态可用）。
final class FoliaLocalServer {
    static let shared = FoliaLocalServer()

    private let port: UInt16 = 48231
    private let queue = DispatchQueue(label: "folia.local.server")
    private var listener: NWListener?
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("[FoliaLocalServer] listener failed: %@", String(describing: error))
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("[FoliaLocalServer] failed to start on %d: %@", port, String(describing: error))
        }
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
        guard let pathOnly = URL(string: request.path)?.path else {
            sendResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("bad request".utf8), on: connection)
            return
        }

        if request.method == "OPTIONS" {
            sendResponse(status: 204, headers: [:], body: Data(), on: connection)
            return
        }

        if pathOnly.hasPrefix("/netease/") || pathOnly.hasPrefix("/qq/") ||
            pathOnly.hasPrefix("/kugou/") || pathOnly.hasPrefix("/api/") {
            proxy(request, on: connection)
        } else {
            serveStatic(pathOnly, on: connection)
        }
    }

    // ---- API 代理 ----

    private let hopByHopHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host",
    ]

    private func proxy(_ request: HTTPRequest, on connection: NWConnection) {
        guard let target = URL(string: "https://app.folia-api.top" + request.path) else {
            sendResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("bad path".utf8), on: connection)
            return
        }

        var urlRequest = URLRequest(url: target)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body
        for (key, value) in request.headers {
            if hopByHopHeaders.contains(key) { continue }
            if key == "origin" { continue } // 代理侧无需转发 Origin
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        session.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            let httpResponse = response as? HTTPURLResponse
            if let error {
                NSLog("[FoliaLocalServer] proxy failed %@: %@", target.absoluteString, String(describing: error))
                self.sendResponse(status: 502, headers: ["Content-Type": "application/json"],
                                  body: Data(#"{"code":502,"msg":"proxy failed"}"#.utf8), on: connection)
                return
            }
            let status = httpResponse?.statusCode ?? 502
            var headers: [String: String] = [:]
            if let all = httpResponse?.allHeaderFields as? [String: Any] {
                for (key, value) in all {
                    guard let keyLower = (key as String).lowercased() as String? else { continue }
                    if self.hopByHopHeaders.contains(keyLower) { continue }
                    if keyLower == "set-cookie" || keyLower == "content-length" { continue }
                    if let strValue = value as? String {
                        headers[key as String] = strValue
                    }
                }
            }
            let body = data ?? Data()
            self.sendResponse(status: status, headers: headers, body: body, on: connection)
        }.resume()
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

        if let data = try? Data(contentsOf: fileURL) {
            sendResponse(status: 200, headers: ["Content-Type": mimeType(for: relative)], body: data, on: connection)
            return
        }

        // SPA 兜底：非 API 路径找不到资源时返回 index.html（React Router 接管）
        let indexURL = distURL.appendingPathComponent("index.html")
        if let indexData = try? Data(contentsOf: indexURL) {
            sendResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: indexData, on: connection)
        } else {
            sendResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found".utf8), on: connection)
        }
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

    private func sendResponse(status: Int, headers: [String: String], body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        var headerLines = ""
        for (key, value) in headers {
            headerLines += "\(key): \(value)\r\n"
        }
        head += headerLines + "Content-Length: \(body.count)\r\n"
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
