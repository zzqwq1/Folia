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

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // 网易云接口交给本地桥接层：静态包里没有 /api/netease，直接读文件会回落成 index.html。
        if NeteaseBridge.shared.shouldHandle(url) {
            NeteaseBridge.shared.handle(urlSchemeTask)
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard let fileURL = self.resolve(url) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                urlSchemeTask.didFailWithError(URLError(.cannotLoadFromNetwork))
                return
            }

            let response = HTTPURLResponse(
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
            )!

            DispatchQueue.main.async {
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 单次读取，无需中断。
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
