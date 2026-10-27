import Foundation
import WebKit
import UIKit

/// 把 App Bundle 里的 www/ 目录挂到一个自定义 scheme 上。
///
/// 为什么不用 file://：网页版是 Vite 产物，用 ES module + Web Worker + fetch 加载资源。
/// file:// 下这些请求都会被当成跨域拒绝，页面直接白屏。自定义 scheme 可以稳定返回
/// 正确的 MIME 类型，并且不触发 CORS 限制。
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "folia"

    private let root: URL
    /// 用串行队列 + 顶层 GCD 桥接：WebKit 允许在非主线程回调任务。
    private let queue = DispatchQueue(label: "app.folia.bundle-scheme", qos: .userInitiated)

    /// 静态任务的记账表，只在 `queue` 上读写。
    ///
    /// WebKit 会在页面重载、切歌、取消导航时 `stop` 掉还没回完的 task，
    /// 之后任何 `didReceive/didFinish` 都是 ObjC 异常，直接杀进程（闪退）。
    /// 之前这里完全没记账，`stop` 时只通知了 LocalApiBridge，
    /// 于是读文件的这一步照样回调——这是「进歌单闪退」的第二条来源。
    private var active = Set<ObjectIdentifier>()

    /// 判定与投递必须在同一个队列块里，否则中间仍会露出被 `stop` 的时间窗。
    private func finish(_ task: WKURLSchemeTask, response: HTTPURLResponse?, data: Data?, error: Error?) {
        queue.async { [weak self] in
            guard let self, self.active.remove(ObjectIdentifier(task)) != nil else { return }
            DispatchQueue.main.async {
                if let error {
                    task.didFailWithError(error)
                    return
                }
                guard let response, let data else {
                    task.didFailWithError(URLError(.badServerResponse))
                    return
                }
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // 各平台接口交给桥接层：静态包里没有 /api/netease、/api/kugou 等目录，
        // 直接读文件会回落成 index.html，前端拿到 HTML 去 JSON.parse 就报错。
        if LocalApiBridge.shared.shouldHandle(url) {
            LocalApiBridge.shared.handle(urlSchemeTask)
            return
        }

        // 先入账再排读盘：读盘是异步的，若反过来，`stop` 可能先到、入账后到，
        // 就把一个已取消的任务又记成活的了。
        queue.async { self.active.insert(ObjectIdentifier(urlSchemeTask)) }

        queue.async { [weak self] in
            guard let self else { return }
            guard let fileURL = self.resolve(url) else {
                self.finish(urlSchemeTask, response: nil, data: nil, error: URLError(.fileDoesNotExist))
                return
            }
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                self.finish(urlSchemeTask, response: nil, data: nil, error: URLError(.cannotLoadFromNetwork))
                return
            }

            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": MimeType.of(fileURL.pathExtension),
                    "Content-Length": "\(data.count)",
                    "Cache-Control": "public, max-age=31536000, immutable",
                    "Access-Control-Allow-Origin": "*",
                    // WebAudio / 波形分析要读音频采样，没有这个头谱线就是一条平线。
                    "Access-Control-Allow-Headers": "*",
                    "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
                ]
            ) else {
                self.finish(urlSchemeTask, response: nil, data: nil, error: URLError(.badServerResponse))
                return
            }

            self.finish(urlSchemeTask, response: response, data: data, error: nil)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 接口请求由 LocalApiBridge 自己记账；静态任务记在这里，两边都要撤。
        LocalApiBridge.shared.cancel(urlSchemeTask)
        queue.async { self.active.remove(ObjectIdentifier(urlSchemeTask)) }
    }

    /// folia://app/assets/x.js → <Bundle>/www/assets/x.js
    private func resolve(_ url: URL) -> URL? {
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }

        // 目录型路由（SPA 深链接）统一回落到 index.html。
        let hasExtension = (path as NSString).pathExtension.isEmpty == false
        if !hasExtension { path = "/index.html" }

        let candidate = root.appendingPathComponent(String(path.dropFirst()))
        let resolved = candidate.standardizedFileURL
        // 目录穿越防护：必须仍在 www/ 之内。
        guard resolved.path.hasPrefix(root.path) else { return nil }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            // 找不到静态文件时，前端路由交给 index.html。
            let fallback = root.appendingPathComponent("index.html")
            return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
        }
        return resolved
    }
}

enum MimeType {
    private static let table: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "wav": "audio/wav",
        "flac": "audio/flac",
        "ogg": "audio/ogg",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "wasm": "application/wasm",
        "map": "application/json; charset=utf-8",
        "txt": "text/plain; charset=utf-8"
    ]

    static func of(_ ext: String) -> String {
        table[ext.lowercased()] ?? "application/octet-stream"
    }
}
