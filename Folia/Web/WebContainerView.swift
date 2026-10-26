import UIKit
import SwiftUI
import WebKit
import Combine

/// 承载官方网页版的 WKWebView 容器。
///
/// 目标：网页版的 UI / 动画 / WebGL 可视化 100% 原样运行，原生层只补三件事——
/// 1. 用自定义 scheme 稳定加载本地 ES module / Worker；
/// 2. 把实测安全区推给网页（页面里已预留 window.__foliaSafeInsets 接口）；
/// 3. 会话配置与后台音频，让锁屏、切后台、来电中断都表现成系统级播放器。
final class WebContainerView: UIView {
    private let state: WebShellState
    private var webView: WKWebView!
    private var reloadObservation: AnyCancellable?
    private var lastInsets: UIEdgeInsets = .zero

    private static let startURL = URL(string: "\(BundleSchemeHandler.scheme)://app/index.html")!

    init(state: WebShellState) {
        self.state = state
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WebView

    private func setUp() {
        backgroundColor = UIColor(red: 0x09 / 255, green: 0x09 / 255, blue: 0x0b / 255, alpha: 1)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = false
        config.websiteDataStore = .default()

        if let wwwRoot = Bundle.main.url(forResource: "www", withExtension: nil) {
            config.setURLSchemeHandler(BundleSchemeHandler(root: wwwRoot),
                                       forURLScheme: BundleSchemeHandler.scheme)
        }

        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(
            source: Self.shellBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = userContent

        webView = WKWebView(frame: bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = backgroundColor
        webView.scrollView.backgroundColor = backgroundColor
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // 让 UA 带 FoliaApp：网页版据此进入「壳模式」，关掉整页 86% 缩放，安全区改用实测值。
        webView.customUserAgent = Self.userAgent

        addSubview(webView)

        reloadObservation = state.$reloadToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.webView.reload() }

        webView.load(URLRequest(url: Self.startURL))
    }

    private static var userAgent: String {
        let base = WKWebView().value(forKey: "userAgent") as? String ?? ""
        // 尾巴上追加标记，保留原有 Safari/WebKit 版本信息，页面识别与兼容判断都不受影响。
        return base.isEmpty ? "FoliaApp/2.0" : "\(base) FoliaApp/2.0"
    }

    // MARK: - 安全区

    override func layoutSubviews() {
        super.layoutSubviews()
        pushInsetsIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        pushInsetsIfNeeded()
    }

    private func pushInsetsIfNeeded() {
        let insets = safeAreaInsets
        guard insets != lastInsets else { return }
        lastInsets = insets

        let js = """
        (function(){
          window.__foliaSafeInsets = {top: \(Int(insets.top.rounded())),
                                      bottom: \(Int(insets.bottom.rounded())),
                                      left: \(Int(insets.left.rounded())),
                                      right: \(Int(insets.right.rounded()))};
          try { window.dispatchEvent(new Event('folia-safe-insets')); } catch (e) {}
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - 注入脚本

    /// 首帧之前就跑：给页面打上壳标记，并把 SW 注册直接掐掉。
    ///
    /// WKWebView 不支持 Service Worker；网页版残留的注册调用只会抛错并在控制台刷屏。
    private static let shellBridgeScript = """
    (function(){
      document.documentElement.setAttribute('data-folia-shell', '1');
      window.__FOLIA_SHELL__ = 'ios';
      try {
        Object.defineProperty(navigator, 'serviceWorker', {
          configurable: true,
          get: function(){ return undefined; }
        });
      } catch (e) {}
      // WKWebView 里 window.open 不开新窗口，站外链接改由原生导航策略接管外跳。
      var nativeOpen = window.open;
      window.open = function(url){
        if (url && typeof url === 'string') {
          try { location.href = url; return null; } catch (e) {}
        }
        return nativeOpen ? nativeOpen.apply(window, arguments) : null;
      };
    })();
    """
}

// MARK: - 导航

extension WebContainerView: WKNavigationDelegate, WKUIDelegate {
    /// 站外链接不进 WebView，交系统浏览器打开。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == BundleSchemeHandler.scheme || scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastInsets = .zero
        pushInsetsIfNeeded()
    }
}

// MARK: - SwiftUI 包装

struct WebShellView: UIViewRepresentable {
    @EnvironmentObject private var state: WebShellState

    func makeUIView(context: Context) -> WebContainerView {
        WebContainerView(state: state)
    }

    func updateUIView(_ uiView: WebContainerView, context: Context) {}
}
