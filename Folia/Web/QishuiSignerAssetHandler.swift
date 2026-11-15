import Foundation
import WebKit

/// 把线上站点缺失的 `/qishui-auth-v6/*` 资源用**包内文件**补上。
///
/// 这是汽水登录修不好的真正根因。
///
/// 页面（`main-*.js` 里的汽水 provider）这样定位签名器：
///
/// ```js
/// const base = y(3213);                              // 站点公开资源基路径
/// iframe.src = `${base}/qishui-auth-v6/signer.html`;
/// ```
///
/// 但线上部署里 **`/qishui-auth-v6/` 这一整套文件根本不存在**（实测）：
///
/// ```text
/// GET /qishui-auth-v6/signer.html     -> 200 text/html       17108B  ← 其实是 SPA 的 index.html
/// GET /qishui-auth-v6/signer-hook.js  -> 200 text/javascript 16741B  ← 同样是 index.html
/// GET /qishui-auth-v6/sdk-glue.js     -> 200 text/javascript 16738B  ← 同样是 index.html
/// ```
///
/// 服务器只配了 history 回退，任何未知路径都吐 index.html。于是那个 iframe 里
/// 装的是**一整份播放器 SPA**，`sdk-glue` 永远起不来，`__foliaSign` 一路超时 ——
/// 用户看到的就是「扫码确认了，但还是登录不了」。
///
/// 从参考构建（3.0.5）里拿到的官方同构文件一共 11 个，全部打进包内
/// `www/qishui-signer/`，这里按 URL 文件名逐一映射。
///
/// **为什么必须留在 `https://app.folia-api.top` 这一域下。**
///
/// 页面侧 `Ie()` 会把签名请求 `postMessage` 给 iframe，而 `sdk-glue` 在算
/// `a_bogus` 时会读同源 `localStorage` 的 `xmst`（88 字节 msToken），并且
/// 二次验证（`security_host.html` 里的 `ucWebSecondVerify`）还要在同一个源里
/// 发 XHR。换成别的 scheme 就等于换源，签名和验证都会失效。
///
/// 但 `WKURLSchemeHandler` 不允许注册 `http` / `https`，所以走两步：
/// 1. `WebContainerView.decidePolicyFor` 认出这几条 URL，`targetFrame.load()`
///    到本 scheme；
/// 2. 本 handler 回包时把 `Access-Control-Allow-Origin` 设成主站源。
///
/// 第 2 步是关键：文档换到了 `folia-signer://`，而主页面仍在
/// `https://app.folia-api.top`，两者是**跨源**。没有这道 CORS 头，页面就
/// 读不到 `iframe.contentWindow`，也就 `postMessage` 不进去。
final class QishuiSignerAssetHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let fileURL = QishuiSignerAssets.bundledURL(lastPathComponent: url.lastPathComponent),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url,
                                       statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: [
                                           "Content-Type": QishuiSignerAssets.mimeType(for: url),
                                           "Content-Length": "\(data.count)",
                                           "Cache-Control": "no-store",
                                           "Access-Control-Allow-Origin": QishuiSignerAssets.pageOrigin,
                                       ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 单次同步返回，没有异步任务要取消。
    }
}

enum QishuiSignerAssets {
    /// 站点缺失的目录前缀。页面从这里拼签名器地址。
    static let remotePrefix = "/qishui-auth-v6/"
    /// 拦截后使用的自定义 scheme。
    static let scheme = "folia-signer"
    /// 主页面所在的源。CORS 头必须精确回它，不能用 `*`
    /// （`document.domain` / `contentWindow` 判定都要同源的明确值）。
    static let pageOrigin = "https://app.folia-api.top"

    /// 这个 URL 是不是页面要的签名器资源。
    static func isSignerAsset(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "app.folia-api.top" else { return false }
        guard url.path.hasPrefix(remotePrefix) else { return false }
        return bundledURL(lastPathComponent: url.lastPathComponent) != nil
    }

    /// 改写成本地 scheme，交给 `QishuiSignerAssetHandler`。
    static func rewrite(_ url: URL) -> URL? {
        let name = url.lastPathComponent
        guard bundledURL(lastPathComponent: name) != nil else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "qishui-auth-v6"
        components.path = "/" + name
        return components.url
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    /// 线上站点缺失资源 → 包内文件的映射。
    ///
    /// 只有 `signer.html` / `signer-hook.js` / `signer-bridge.js` 是页面直接要的；
    /// 其余是它们的依赖（`sdk-glue` → `bdms`，二次验证 → `react*` / `security_host`）。
    ///
    /// **注意 `sdk-glue.js` 的 bdms / captcha 是它自己去 CDN 拉的**
    /// （`lf-headquarters-speed.yhgfb-cn-static.com` / `lf-rc1...`），
    /// 包内这两份只是兜底，不参与拦截时也不会影响线上那条路。
    private static let fileTypes: [String: String] = [
        "signer.html": "html",
        "security_host.html": "html",
        "mfa.html": "html",
        "security_seed.html": "html",
        "signer-hook.js": "js",
        "signer-bridge.js": "js",
        "sdk-glue.js": "js",
        "bdms.js": "js",
        "react.js": "js",
        "react-dom.js": "js",
        // 原生宿主适配层：官方 `signer-bridge.js` 只往 `parent` 发 ready，
        // 而本壳的签名器是没有父页面的隐藏 WebView，靠这条把 ready 转成原生 `booted`。
        "host-boot.js": "js",
    ]

    /// 包内对应文件的地址。
    static func bundledURL(lastPathComponent: String) -> URL? {
        guard let ext = fileTypes[lastPathComponent] else { return nil }
        let base = (lastPathComponent as NSString).deletingPathExtension
        return Bundle.main.url(forResource: base, withExtension: ext,
                               subdirectory: "www/qishui-signer")
    }
}
