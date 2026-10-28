import UIKit
import SwiftUI
import WebKit
import Combine

/// 承载官方网页版的 WKWebView 容器。
///
/// 目标：网页版的 UI / 动画 / WebGL 可视化 100% 原样运行，原生层只补三件事——
/// 1. 直接远程加载线上站点（与 API 同域，前端请求天然同源，无需本地反代）；
/// 2. 把实测安全区推给网页（页面里已预留 window.__foliaSafeInsets 接口）；
/// 3. 会话配置与后台音频，让锁屏、切后台、来电中断都表现成系统级播放器。
///
/// 早先这里跑的是内置 `www/` + 自定义 scheme `folia://` 的本地包，进歌单会闪退、
/// 音频进不了播放态；线上站点本身已内置壳适配（UA 含 FoliaApp 即进入壳模式），
/// 因此改为套壳线上页：少一层自定义协议，也就少一类 WKURLSchemeTask 事故。
final class WebContainerView: UIView {
    private let state: WebShellState
    private var webView: WKWebView!
    private var reloadObservation: AnyCancellable?
    private var lastInsets: UIEdgeInsets = .zero
    /// 内容进程被回收的次数与时间窗，用来防止「重载→立刻再挂→再重载」的死循环。
    private var contentProcessRestarts: [Date] = []

    /// 线上站点的域名。导航策略、诊断与重载都以它为基准。
    private static let siteHost = "app.folia-api.top"
    private static let startURL = URL(string: "https://app.folia-api.top/")!

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

        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(
            source: Self.shellBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userContent.add(AudioStateRelay(), name: "foliaAudioState")
        userContent.add(JSLogRelay(), name: "foliaJSLog")
        userContent.add(QRFallbackRelay(), name: "foliaQrFallback")
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

        // 必须持有，否则会被立刻释放，长按手势失效。
        diagnostics = DiagnosticsOverlay(webView: webView)

        reloadObservation = state.$reloadToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.webView.reload() }

        webView.load(URLRequest(url: Self.startURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))

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
    private var diagnostics: DiagnosticsOverlay?

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

    /// 网易云扫码登录的兜底。
    ///
    /// 服务端的 `/login/qr/create` 只有带 `qrimg=true` 才返回 base64 图片，
    /// 而本地包里调的是不带该参数的地址，拿到的是空字符串，界面上就一直转圈。
    /// 这里两头都补：请求上补参数；万一还是空，就用 `QRTool` 本地把 `qrurl` 画出来。
    private func installLoginHelpers() {
        let js = """
        (function(){
          if (window.__foliaLoginHelpers) { return; }
          window.__foliaLoginHelpers = true;

          var ensureQrImg = function(url){
            if (!url || url.indexOf('/login/qr/create') < 0) { return url; }
            // 页面自己已经带了就不动。
            if (/[?&]qrimg=/.test(url)) { return url.replace(/qrimg=[^&]*/, 'qrimg=true'); }
            return url + (url.indexOf('?') >= 0 ? '&' : '?') + 'qrimg=true';
          };

          var nativeFetch = window.fetch;
          if (nativeFetch) {
            window.fetch = function(input, init){
              try {
                if (typeof input === 'string') {
                  input = ensureQrImg(input);
                } else if (input && input.url) {
                  var fixed = ensureQrImg(input.url);
                  if (fixed !== input.url) { input = new Request(fixed, input); }
                }
              } catch (e) {}
              return nativeFetch.call(window, input, init).then(function(res){
                try {
                  var u = (res && res.url) || '';
                  if (u.indexOf('/login/qr/create') >= 0) {
                    res.clone().json().then(function(body){
                      var qr = body && body.data && (body.data.qrimg || body.data.qrcode_img);
                      if (qr) { return; }
                      var target = body && body.data && body.data.qrurl;
                      if (!target) { return; }
                      window.webkit.messageHandlers.foliaQrFallback.postMessage(target);
                    }).catch(function(){});
                  }
                } catch (e) {}
                return res;
              });
            };
          }
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
      // 把页面里的未捕获错误回传原生。React 渲染时抛的 TypeError
      // 在 WKWebView 里只会让页面白掉/退回加载界面，控制台看不到，
      // 必须落到本地日志里才能定位是哪个字段为空。
      var report = function(kind, detail){
        try { window.webkit.messageHandlers.foliaJSLog.postMessage(kind + ' ' + detail); } catch (e) {}
      };
      window.addEventListener('error', function(e){
        var t = e && e.target;
        if (t && t !== window && (t.src || t.href)) {
          report('RESOURCE', (t.tagName || '') + ' ' + (t.src || t.href));
          return;
        }
        report('ERROR', (e && e.message) + ' @ ' + (e && e.filename) + ':' + (e && e.lineno));
      }, true);
      window.addEventListener('unhandledrejection', function(e){
        var r = e && e.reason;
        report('REJECTION', (r && (r.stack || r.message)) || String(r));
      });
    })();
    """
}

// MARK: - 导航

extension WebContainerView: WKNavigationDelegate, WKUIDelegate {
    /// 站内（含子域）与媒体资源一律放行；只有主框架跳到站外时才交给系统浏览器。
    ///
    /// 线上页是远程 https：音频、封面、二维码图片全在站外 CDN 上，
    /// 所以按「是不是主框架」区分，只有主框架跳站外才外跳。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" || scheme.isEmpty {
            decisionHandler(.allow)
            return
        }

        let host = url.host?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        let isSameSite = host == Self.siteHost || host.hasSuffix(".\(Self.siteHost)")

        if isMainFrame && (scheme == "http" || scheme == "https") && !isSameSite {
            // 站外链接（登录协议页、赞赏、QQ 群等）走系统浏览器。
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
        installLoginHelpers()
        // App 启动时会被系统重新激活会话；每次页面加载完再补一次，
        // 覆盖「之前被来电/其他播放器降级」的情况。
        AudioSessionController.shared.reactivate()
    }

    /// 远程页加载失败时自动重试一次，避免停在白屏上。
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        // -999 是「被新导航取消」，属正常流程。
        guard code != NSURLErrorCancelled else { return }
        CrashLog.note("==== provisional navigation failed \(code) \(error.localizedDescription) ====")
        let now = Date()
        contentProcessRestarts = contentProcessRestarts.filter { now.timeIntervalSince($0) < 60 }
        guard contentProcessRestarts.count < 2 else { return }
        contentProcessRestarts.append(now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak webView] in
            webView?.load(URLRequest(url: Self.startURL))
        }
    }

    /// 内容进程被系统回收（内存压力）时自动恢复，但要限流：
    /// 无脑 reload 会形成「加载界面 → 立刻再被杀 → 再 reload」的死循环，
    /// 用户在界面上看到的就是反复闪回加载界面。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        contentProcessRestarts = contentProcessRestarts.filter { now.timeIntervalSince($0) < 60 }
        contentProcessRestarts.append(now)
        // 这是与「ObjC 异常闪退」完全不同的另一条路径：网页把 WebProcess 搞死了。
        // 计进日志才能区分到底是哪一种。
        CrashLog.note("==== web content process terminated (#\(contentProcessRestarts.count)) url=\(webView.url?.absoluteString ?? "-") ====")

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

// MARK: - 页面日志回传

/// 网页里的未捕获错误 / 资源加载失败，落到本地日志，供「闪退」定位。
private final class JSLogRelay: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        CrashLog.note("JS \(body)")
    }
}

// MARK: - 二维码兜底

/// 服务端没给二维码图片时，用 `qrurl` 在本地画一张，再塞回页面的二维码弹窗。
private final class QRFallbackRelay: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let url = message.body as? String,
              let dataURL = QRTool.dataURL(for: url) else {
            CrashLog.note("QR fallback: cannot render \(message.body)")
            return
        }
        CrashLog.note("QR fallback: rendered locally for \(url)")
        let js = """
        (function(src){
          var imgs = document.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i += 1) {
            var img = imgs[i];
            var box = img.getBoundingClientRect();
            // 二维码弹窗里那张图：方形、边长 120 以上，且当前没有可用图源。
            if (box.width < 100 || Math.abs(box.width - box.height) > 8) { continue; }
            var blank = !img.getAttribute('src') || img.getAttribute('src').indexOf('data:') === 0 && img.naturalWidth === 0;
            if (!blank && img.complete && img.naturalWidth > 0) { continue; }
            img.removeAttribute('srcset');
            img.setAttribute('src', src);
            try { img.style.opacity = '1'; } catch (e) {}
            return;
          }
          // 页面上没有现成的 img 时才兜底：替换掉“正在加载二维码”的占位文字。
          var all = document.querySelectorAll('div,p,span');
          for (var j = 0; j < all.length; j += 1) {
            var el = all[j];
            if (el.children.length > 0) { continue; }
            if ((el.textContent || '').indexOf('二维码') < 0) { continue; }
            var holder = el.parentElement;
            if (!holder) { continue; }
            var pic = document.createElement('img');
            pic.src = src;
            pic.style.cssText = 'width:200px;height:200px;display:block;margin:8px auto;border-radius:8px;background:#fff';
            holder.appendChild(pic);
            return;
          }
        })('\(dataURL)');
        """
        message.webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - 诊断面板

/// 长按左上角触发：把本地崩溃日志直接铺在屏幕上，截图即可发出来。
/// 不接电脑也能拿到现场，这是排查「闪退」最快的路径。
final class DiagnosticsOverlay: NSObject {
    private weak var webView: WKWebView?
    private var panel: UIView?
    private static let size: CGFloat = 64

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        let long = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        long.minimumPressDuration = 1.2
        long.numberOfTouchesRequired = 1
        // 只挂在左上角的窄条上，避免抢走页面里的长按操作。
        let strip = UIView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        strip.backgroundColor = .clear
        strip.isUserInteractionEnabled = true
        strip.addGestureRecognizer(long)
        strip.autoresizingMask = [.flexibleRightMargin, .flexibleBottomMargin]
        webView.addSubview(strip)
    }

    @objc private func handle(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        if panel != nil { hide() } else { show() }
    }

    private func show() {
        guard let web = webView, let host = web.superview else { return }
        let container = UIView(frame: host.bounds)
        container.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let label = UILabel(frame: container.bounds.insetBy(dx: 16, dy: 56))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        label.textColor = .white
        label.text = "（读取中…）"
        label.lineBreakMode = .byCharWrapping
        container.addSubview(label)

        // 再给两个按钮：原生日志 + 播放探针。播放失败的原因几乎都在探针里
        // （play() 被拒 / 媒体错误码 / 音频 CDN 探测结果），比 Swift 日志有用得多。
        let close = UIButton(type: .system)
        close.setTitle("关闭", for: .normal)
        close.frame = CGRect(x: 16, y: 12, width: 72, height: 32)
        close.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        container.addSubview(close)

        let native = UIButton(type: .system)
        native.setTitle("原生日志", for: .normal)
        native.frame = CGRect(x: 96, y: 12, width: 96, height: 32)
        native.addTarget(self, action: #selector(showNativeLog), for: .touchUpInside)
        container.addSubview(native)

        let audio = UIButton(type: .system)
        audio.setTitle("播放探针", for: .normal)
        audio.frame = CGRect(x: 200, y: 12, width: 96, height: 32)
        audio.addTarget(self, action: #selector(showAudioProbe), for: .touchUpInside)
        container.addSubview(audio)

        // 现场勘验：直接把页面此刻的真实数值铺出来。
        // 「进度条不动」可能是没声音，也可能是状态机把时间写丢了，
        // 只有这两组数字能区分，光看界面看不出来。
        let live = UIButton(type: .system)
        live.setTitle("现场", for: .normal)
        live.frame = CGRect(x: 304, y: 12, width: 72, height: 32)
        live.addTarget(self, action: #selector(showLiveState), for: .touchUpInside)
        container.addSubview(live)

        host.addSubview(container)
        panel = container
        showAudioProbe()
    }

    @objc private func showNativeLog() {
        guard let label = panel?.subviews.compactMap({ $0 as? UILabel }).first else { return }
        guard let url = CrashLog.fileURL,
              let body = try? String(contentsOf: url, encoding: .utf8) else {
            label.text = "（还没有日志）"
            return
        }
        // 只留最后一屏，太长反而看不清。
        label.text = String(body.suffix(4000))
    }

    /// 读页面里播放探针收集到的现场。页面不可用（加载失败）时给一句明确的提示，
    /// 免得看起来像「面板坏了」。
    @objc private func showAudioProbe() {
        guard let web = webView else { return }
        web.evaluateJavaScript(
            "window.__folioAudioProbe ? window.__folioAudioProbe.dump() : '(页面里没有探针，可能还没加载完)'"
        ) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let label = self?.panel?.subviews.compactMap({ $0 as? UILabel }).first else { return }
                if let error {
                    label.text = "读取失败：\(error.localizedDescription)"
                    return
                }
                let text = (result as? String) ?? "（没有数据）"
                label.text = "==== 播放探针 ====\n" + (text.isEmpty ? "（还没有事件，先点一下播放）" : text)
            }
        }
    }

    /// 页面上此刻的真实数值：哪个 deck 在放、音频元素自己的 currentTime 与 duration。
    /// 「进度条不动」时这两组数字一对就知道卡在哪一层。
    @objc private func showLiveState() {
        guard let web = webView else { return }
        let js = """
        (function(){
          var out = [];
          var list = document.querySelectorAll('audio');
          out.push('audio 元素数: ' + list.length);
          for (var i = 0; i < list.length; i += 1) {
            var a = list[i];
            out.push('[' + i + '] paused=' + a.paused + ' ended=' + a.ended +
              ' t=' + a.currentTime.toFixed(2) + ' dur=' + (isFinite(a.duration) ? a.duration.toFixed(1) : '-') +
              ' rs=' + a.readyState + ' ns=' + a.networkState +
              ' err=' + (a.error ? a.error.code : '-'));
            out.push('    src=' + ((a.currentSrc || a.getAttribute('src') || '-').slice(-70)));
          }
          try {
            var bars = document.querySelectorAll('[role="slider"]');
            for (var j = 0; j < bars.length; j += 1) {
              out.push('slider aria-valuenow=' + bars[j].getAttribute('aria-valuenow') +
                ' aria-valuemax=' + bars[j].getAttribute('aria-valuemax'));
            }
          } catch (e) {}
          if (window.__folioAudioProbe) {
            out.push('---- 探针 ----');
            out.push(window.__folioAudioProbe.dump());
          }
          return out.join('\\n');
        })();
        """
        web.evaluateJavaScript(js) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let label = self?.panel?.subviews.compactMap({ $0 as? UILabel }).first else { return }
                if let error {
                    label.text = "读取失败：\(error.localizedDescription)"
                    return
                }
                label.text = "==== 现场 ====\n" + ((result as? String) ?? "（没有数据）")
            }
        }
    }

    @objc private func hideTapped() { hide() }

    private func hide() {
        panel?.removeFromSuperview()
        panel = nil
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
