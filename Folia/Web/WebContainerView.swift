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
    /// 内容进程被回收的次数与时间窗，用来防止「重载→立刻再挂→再重载」的死循环。
    private var contentProcessRestarts: [Date] = []

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
        userContent.add(AudioStateRelay(), name: "foliaAudioState")
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

        // 锁屏 / 耳机线控按钮 → 页面播放器。
        remoteObservation = NotificationCenter.default
            .addObserver(forName: .foliaRemoteCommand, object: nil, queue: .main) { [weak self] note in
                guard let action = note.object as? String else { return }
                self?.forwardRemoteCommand(action)
            }

        // WebKit 的内容进程被杀（内存压力 / 系统回收）时会白屏。自动重载而不是留一片黑。
        // 走 WKNavigationDelegate 的 webProcessDidTerminate 回调，无需再挂通知。
    }

    private var remoteObservation: Any?

    /// 页面里的播放器是 React 状态机，没有全局 API，这里按 DOM 上的按钮与媒体元素找。
    private func forwardRemoteCommand(_ action: String) {
        let js = """
        (function(a){
          try {
            var media = document.querySelector('audio,video');
            var ms = navigator.mediaSession;
            // 页面自身已经绑过 setActionHandler，优先借它的处理器：
            // 它走的是 React 状态机，切歌后 UI、队列、歌词都会同步；
            // 直接点 DOM 在页面重载后或按钮被隐藏时会静默失效。
            if (a === 'play') {
              var playFn = window.__foliaMediaCommand && window.__foliaMediaCommand.play;
              if (playFn) { playFn(); return; }
              if (media && media.play) { media.play(); return; }
              if (ms) { try { ms.playbackState = 'playing'; } catch (e) {} }
              return;
            }
            if (a === 'pause') {
              var pauseFn = window.__foliaMediaCommand && window.__foliaMediaCommand.pause;
              if (pauseFn) { pauseFn(); return; }
              if (media && media.pause) { media.pause(); return; }
              return;
            }
            var fn = window.__foliaMediaCommand && window.__foliaMediaCommand[a];
            if (fn) { fn(); return; }
            // 兜底：界面上没有暴露接口时，按 data-testid / aria-label 点按钮。
            var sel = a === 'next'
              ? ['[data-testid="player-next"]','[aria-label*="下一"]','[aria-label*="Next"]']
              : a === 'prev'
                ? ['[data-testid="player-prev"]','[aria-label*="上一"]','[aria-label*="Previous"]']
                : ['[data-testid="player-toggle"]','[aria-label*="播放"]','[aria-label*="暂停"]'];
            for (var i = 0; i < sel.length; i += 1) {
              var el = document.querySelector(sel[i]);
              if (el) { el.click(); return; }
            }
            if (a === 'toggle' && media) { media.paused ? media.play() : media.pause(); }
          } catch (e) {}
        })('\(action)');
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 后台播放保活 + 播放状态上报给原生（锁屏/控制中心据此判断「正在播放」）。
    private func installAudioKeeper() {
        let js = """
        (function(){
          if (window.__foliaAudioKeeperInstalled) { return; }
          window.__foliaAudioKeeperInstalled = true;

          // 记录页面自身的 MediaSession 处理器，供锁屏按钮直接调用。
          var handlers = window.__foliaMediaCommand = window.__foliaMediaCommand || {};
          try {
            var ms = navigator.mediaSession;
            if (ms && ms.setActionHandler) {
              ['play','pause','previoustrack','nexttrack'].forEach(function(name){
                try {
                  var prev = ms.setActionHandler.bind(ms);
                  var wrapped = function(detail){
                    if (typeof detail === 'function') {
                      handlers[name === 'previoustrack' ? 'prev' : name === 'nexttrack' ? 'next' : name] = detail;
                    }
                    return prev(detail);
                  };
                  ms.setActionHandler = wrapped;
                } catch (e) {}
              });
            }
          } catch (e) {}

          var lastState = '';
          var report = function(){
            try {
              var el = document.querySelector('audio,video');
              var state = '';
              if (el) { state = el.paused ? 'paused' : 'playing'; }
              else if (navigator.mediaSession) { state = navigator.mediaSession.playbackState || ''; }
              if (!state || state === lastState) { return; }
              lastState = state;
              window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.foliaAudioState
                && window.webkit.messageHandlers.foliaAudioState.postMessage(state);
            } catch (e) {}
          };

          // WebAudio 走 createMediaElementSource 时元素本身不直出声音，
          // 但 iOS 仍以「页面上有在播放的媒体」来维持后台音频，所以这里持续观察。
          setInterval(report, 1000);
          document.addEventListener('playing', report, true);
          document.addEventListener('pause', report, true);
          document.addEventListener('visibilitychange', function(){
            if (document.visibilityState === 'visible') { report(); }
          });
          report();
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
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
        installAudioKeeper()
        // App 启动时会被系统重新激活会话；每次页面加载完再补一次，
        // 覆盖「之前被来电/其他播放器降级」的情况。
        AudioSessionController.shared.reactivate()
    }

    /// 内容进程被系统回收（内存压力）时自动恢复，但要限流：
    /// 无脑 reload 会形成「加载界面 → 立刻再被杀 → 再 reload」的死循环，
    /// 用户在界面上看到的就是反复闪回加载界面。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        contentProcessRestarts = contentProcessRestarts.filter { now.timeIntervalSince($0) < 60 }
        contentProcessRestarts.append(now)

        if contentProcessRestarts.count <= 2 {
            webView.reload()
        } else if contentProcessRestarts.count == 3 {
            webView.load(URLRequest(url: Self.startURL))
        } else {
            // 一分钟内挂了四次，说明继续重建只会更糟，先停在这里等用户手动刷新。
            NSLog("[Folia] content process terminated repeatedly, stop auto reload")
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        AudioSessionController.shared.reactivate()
    }
}

// MARK: - 播放状态上报

/// 页面里的播放器播放/暂停时通知原生，用来维持锁屏与控制中心的「正在播放」状态。
private final class AudioStateRelay: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let state = message.body as? String else { return }
        AudioSessionController.shared.updatePlaybackState(state == "playing")
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
