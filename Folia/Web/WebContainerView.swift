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

    /// 页面调过 `audio.play()` 而还没被用户按暂停：这是「该有声」的唯一依据。
    ///
    /// 用户只按过一次播放，之后无论是切后台、锁屏、Siri 抢占还是 WebKit 自己把
    /// 媒体元素按下暂停，都算被迫中断，壳负责把它放回去。用户亲手按的暂停会清掉它。
    private var wantsAudible = false
    /// 用户亲手按了暂停，串行下发中的远程命令据此不会再把它放回去。
    private var userPaused = false
    /// 保活轮询：后台时每两秒确认一次「该响的还在响」。
    private var keepAliveTimer: Timer?
    private var foregroundObservation: Any?
    private var backgroundObservation: Any?

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
        let qrRelay = QRFallbackRelay()
        userContent.add(qrRelay, name: "foliaQrFallback")
        let intentRelay = AudioIntentRelay()
        intentRelay.container = self
        userContent.add(intentRelay, name: "foliaAudioIntent")
        config.userContentController = userContent

        webView = WKWebView(frame: bounds, configuration: config)
        // 两个回传通道都要拿到 webView：一个往页面塞本地画的二维码，一个做播放意图。
        qrRelay.webView = webView
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
        // applicationNameForUserAgent 与完整串两处都设，避免某些系统版本上其中一路不生效。
        config.applicationNameForUserAgent = "FoliaApp/2.0"
        Self.installUserAgent(on: webView)

        addSubview(webView)

        // 必须持有，否则会被立刻释放，长按手势失效。
        diagnostics = DiagnosticsOverlay(webView: webView)

        reloadObservation = state.$reloadToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.webView.reload() }

        webView.load(URLRequest(url: Self.startURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        scheduleProgressWatchdog()

        // 锁屏 / 耳机线控按钮 → 页面播放器。
        remoteObservation = NotificationCenter.default
            .addObserver(forName: .foliaRemoteCommand, object: nil, queue: .main) { [weak self] note in
                guard let action = note.object as? String else { return }
                self?.handleRemoteCommand(action)
            }

        observeLifecycle()
    }

    private var remoteObservation: Any?
    private var diagnostics: DiagnosticsOverlay?

    deinit {
        stopKeepAliveTimer()
        // block 型观察者不会随 self 释放自动注销，留着会在下一次通知时回调到已释放对象上。
        let tokens: [Any?] = [remoteObservation, foregroundObservation, backgroundObservation]
        for token in tokens.compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// 前后台切换是后台播放的主战场：进后台立刻确认会话并起保活轮询，
    /// 回前台再确认一次（系统可能在后台把会话降级，或把媒体元素按掉）。
    private func observeLifecycle() {
        foregroundObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            AudioSessionController.shared.configure()
            // 回前台不改变意图：该响的继续响，轮询照旧。
            self.refreshAudioKeepAlive()
            self.enforcePlaybackIfNeeded(reason: "foreground")
        }
        backgroundObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshAudioKeepAlive()
        }
    }

    /// 让轮询与当前意图对齐：该响就起，不该响就停。
    private func refreshAudioKeepAlive() {
        if wantsAudible && !userPaused {
            AudioSessionController.shared.reactivate()
            startKeepAliveTimer()
        } else {
            stopKeepAliveTimer()
        }
    }

    // MARK: - 后台保活

    /// 页面调过 play，且用户没有亲手暂停 —— 这就是「该有声」。
    fileprivate func markAudibleIntent() {
        wantsAudible = true
        userPaused = false
        AudioSessionController.shared.updatePlaybackState(true)
        startKeepAliveTimer()
    }

    /// 页面自己暂停了（用户按暂停、或播完）：不再续播。
    fileprivate func markPausedIntent() {
        wantsAudible = false
        stopKeepAliveTimer()
    }

    private func startKeepAliveTimer() {
        guard keepAliveTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.wantsAudible else { return }
            AudioSessionController.shared.reactivate()
            self.enforcePlaybackIfNeeded(reason: "keepalive")
        }
        // 挂 .common：滚动视图追踪模式下定时器也会照常触发，后台也照常。
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    /// 会话激活失败时 iOS 会把媒体按停；这里把「该响的」重新放回去。
    ///
    /// 只在 `wantsAudible` 为真时动手，且每轮只做一次 `play()`：
    /// 页面自己的播放器仍然是唯一的状态源，壳只是保证它不被系统静默掐断。
    private func enforcePlaybackIfNeeded(reason: String) {
        guard wantsAudible, !userPaused else { return }
        let js = """
        (function(){
          try {
            // 双 deck 交叉淡化（automix）下有两个 audio：只放回当前被掐掉的那个，
            // 另一个本来就是停的，不能一起放，否则会两声齐唱。
            var list = document.querySelectorAll('audio');
            var resumed = 0;
            for (var i = 0; i < list.length; i += 1) {
              var el = list[i];
              if (!el.paused || el.ended || !el.src) { continue; }
              var p = el.play();
              if (p && p.catch) { p.catch(function(){}); }
              resumed += 1;
            }
            return resumed > 0 ? 'resumed' : 'noop';
          } catch (e) { return 'error'; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            guard let flag = result as? String, flag == "resumed" else { return }
            CrashLog.note("==== audio resumed (\(reason)) ====")
        }
    }

    /// 远程命令要先更新意图，再转发给页面：否则线控按了暂停，保活轮询会把它又放回去。
    private func handleRemoteCommand(_ action: String) {
        switch action {
        case "play", "toggle":
            if action == "play" || !wantsAudible {
                markAudibleIntent()
            } else {
                // toggle 在「正在响」时表示暂停。
                wantsAudible = false
                stopKeepAliveTimer()
            }
        case "pause":
            wantsAudible = false
            stopKeepAliveTimer()
        default:
            // 切歌不改变意图。
            break
        }
        forwardRemoteCommand(action)
    }

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

    // MARK: - 加载看门狗

    /// 页面多久还没画出东西就算卡住。线上页要拉主 bundle 与一批 CDN 依赖，正常两三秒；
    /// 超过这个时间基本可以判为「黑屏卡死」。
    private static let stallTimeout: TimeInterval = 15

    /// 首屏是否已经就绪（React 挂上、加载遮罩淡出）。
    private var didReachFirstPaint = false

    /// 盯着首屏：到点还没就绪，就把当前 URL、标题与页面文本回传，让用户看到到底卡在哪。
    ///
    /// 之前「一直黑屏」只能靠猜——界面是一片 #09090b，究竟是网络、DNS、
    /// 还是页面里的模块加载被卡住，在外面完全看不出来。这里把现场收集起来直接显示。
    private func scheduleProgressWatchdog() {
        didReachFirstPaint = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallTimeout) { [weak self] in
            self?.reportStallIfNeeded()
        }
    }

    private func reportStallIfNeeded() {
        guard !didReachFirstPaint else { return }
        let js = """
        (function(){
          var splash = document.getElementById('app-splash');
          var root = document.getElementById('root');
          return [
            'url=' + location.href,
            'readyState=' + document.readyState,
            'ua=' + (navigator.userAgent || '').slice(-40),
            'shell=' + (document.documentElement.getAttribute('data-folia-shell') || '-'),
            'splash=' + (splash ? (splash.className || 'visible') : 'gone'),
            'rootChildren=' + (root ? root.children.length : -1)
          ].join('\\n');
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.didReachFirstPaint else { return }
                let detail = (result as? String) ?? (error?.localizedDescription ?? "页面无响应")
                CrashLog.note("==== first paint timeout ====\n\(detail)")
                self.state.noteLoadFailure(-3, detail: detail)
            }
        }
    }

    /// 拉一下同时段的远端日志，看看模块图是不是卡在 CDN 上。
    ///
    /// 线上页用 importmap 从 aistudiocdn 取 react / framer-motion 等模块，
    /// 这些请求失败不会触发 document 的错误事件，既不进本地日志也不显示在界面上。
    /// 这里主动回灌一份资源现场，真机截一张图就能判断「到底哪个文件没下来」。
    private func collectResourceReport(_ completion: @escaping (String) -> Void) {
        let js = """
        (function(){
          var out = [];
          try {
            var res = performance.getEntriesByType('resource') || [];
            out.push('resources=' + res.length);
            for (var i = 0; i < res.length; i += 1) {
              var r = res[i];
              // 只列外部模块与主 bundle，封面/字体这些噪音太多。
              if (!/\\.(js|mjs|css)(\\?|$)/.test(r.name)) { continue; }
              out.push(Math.round(r.duration) + 'ms ' + (r.transferSize || 0) + 'B ' + r.name);
            }
            var nav = performance.getEntriesByType('navigation')[0];
            if (nav) { out.push('nav=' + Math.round(nav.responseEnd) + 'ms type=' + nav.type); }
          } catch (e) {}
          return out.slice(0, 40).join('\\n');
        })();
        """
        webView?.evaluateJavaScript(js) { result, error in
            DispatchQueue.main.async {
                let text = (result as? String) ?? (error?.localizedDescription ?? "")
                completion(text)
            }
        }
    }

    /// 文档加载完后轮询首屏是否就绪：React 挂上就会把 `#app-splash` 去掉。
    /// 一直不去掉说明主 bundle 或它依赖的 CDN 模块卡住了，交给看门狗报现场。
    private func scheduleFirstPaintCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkFirstPaint()
        }
    }

    private func checkFirstPaint() {
        guard !didReachFirstPaint else { return }
        webView?.evaluateJavaScript(
            "(document.getElementById('app-splash') ? 0 : 1)"
        ) { [weak self] result, _ in
            guard let self else { return }
            if let painted = result as? Int, painted == 1 {
                DispatchQueue.main.async { self.didReachFirstPaint = true }
                // 首屏就绪再开赞赏弹窗：在那之前 DOM 里的图片还没解码，弹出来是两张空白框。
                self.installDonateCard()
                return
            }
            // 还没就绪：一秒后再看，直到看门狗到点兜底。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.checkFirstPaint()
            }
        }
    }

    /// 后台播放保活 + 播放状态上报给原生（锁屏/控制中心据此判断「正在播放」）。
    ///
    /// 页面自己不会在切后台时暂停；真正被掐断的是 iOS 在会话失效后按停媒体元素，
    /// 或者 WebKit 的内容进程被系统短暂挂起。所以这里做两件事：
    /// 1. 记录页面的播放意图（`play()` / `pause()` 被调用即上报），意图在原生这边保存；
    /// 2. 后台每两秒确认一次会话有效，并把「该响但被按停」的媒体放回去。
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

          var post = function(kind){
            try {
              window.webkit.messageHandlers.foliaAudioIntent.postMessage(kind);
            } catch (e) {}
          };

          // 页面调用 play() 即视为「要出声」，交给原生在后台守住；
          // pause() 分两种：用户按的（element.pause）和系统按的（没有调用栈来源），
          // 这里只上报真实调用，系统静默按停不会触发它，靠原生轮询发现并恢复。
          var mediaProto = HTMLMediaElement.prototype;
          var nativePlay = mediaProto.play;
          var nativePause = mediaProto.pause;
          mediaProto.play = function(){
            var out = nativePlay.apply(this, arguments);
            try { if (this.tagName === 'AUDIO') { post('intent-play'); } } catch (e) {}
            return out;
          };
          mediaProto.pause = function(){
            try {
              if (this.tagName === 'AUDIO') {
                // 播放结束后的 pause 不算用户意图，否则一轮播完就再也不续。
                if (!this.ended) { post('intent-pause'); }
              }
            } catch (e) {}
            return nativePause.apply(this, arguments);
          };

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
    /// 不带该参数拿到的是空字符串，界面上就一直转圈。
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

    /// 把页面自带的赞赏弹窗打开。
    ///
    /// 线上页的赞赏脚本开头有 `if (/iPhone|iPad|iPod/i.test(UA)) return;`，
    /// 装在 App 里时整段直接退出，弹窗永远不会出现；而壳的 UA 一定含 "iPhone"。
    /// 这里在首屏就绪后按同一份 DOM 自己打开，并补上脚本里因提前返回而没绑上的点击：
    /// 关闭按钮、点空白关闭、「获取」跳转、二维码长按保存。
    ///
    /// 版本号与更新公告也一并接手：线上页的 `FOLIA_VERSION` / `FOLIA_LATEST_VERSION`
    /// 是纯静态常量，站点一改，App 里立刻就是新值，不需要重装。
    private func installDonateCard() {
        let js = """
        (function(){
          if (window.__foliaDonateInstalled) { return; }
          var mask = document.getElementById('donate-mask');
          if (!mask) { return; }
          window.__foliaDonateInstalled = true;

          var QUARK_URL = 'https://pan.quark.cn/s/934c480d5b9c';

          // 版本号只认页面里的两个常量：站点改了这里就有，壳自己不写死任何版本。
          // 「当前版本」例外：线上页停在 1.8.5，而这个包是 2.0，显示 1.8.5 会让人以为装错了，
          // 所以用壳带进来的实际版本覆盖，最新版本仍由站点决定。
          var cur = (window.__foliaAppVersion || (typeof FOLIA_VERSION === 'string' && FOLIA_VERSION) || '');
          var latest = (typeof FOLIA_LATEST_VERSION === 'string' && FOLIA_LATEST_VERSION) || '';

          var verNum = document.getElementById('donate-version-num');
          if (verNum && cur) { verNum.textContent = cur; }
          var latestNum = document.getElementById('donate-latest-num');
          if (latestNum && latest) { latestNum.textContent = latest; }

          var getLatest = document.getElementById('donate-get-latest');
          if (getLatest) {
            // 已经是最新：这个链接没有意义，隐藏掉，免得点了跳去网盘。
            if (cur && latest && cur === latest) {
              getLatest.style.display = 'none';
            } else {
              getLatest.addEventListener('click', function(e){
                e.preventDefault();
                try { window.open(QUARK_URL, '_blank'); } catch (err) { location.href = QUARK_URL; }
              });
            }
          }

          var closeBtn = document.getElementById('donate-close');
          if (closeBtn) {
            closeBtn.addEventListener('click', function(){ mask.classList.remove('show'); });
          }
          mask.addEventListener('click', function(e){ if (e.target === mask) { mask.classList.remove('show'); } });

          // 每次启动都弹一次：sessionStorage 里那条是网页版防重复用的，壳里不清就会被跳过。
          try { sessionStorage.removeItem('folia.donate.shown'); } catch (e) {}

          // 横幅本身已经挡住了整屏，网页里的长按菜单（放大镜、复制链接）用不上；
          // 但二维码要能「长按保存到相册」，所以只对二维码图片放开手势。
          var imgs = mask.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i += 1) {
            try {
              imgs[i].style.webkitUserSelect = 'auto';
              imgs[i].style.webkitTouchCallout = 'default';
            } catch (e) {}
          }

          setTimeout(function(){ mask.classList.add('show'); }, 1200);

          // ---- 更新公告：与页面同一套规则，等赞赏弹窗关掉后再弹 ----
          if (!cur || !latest || cur === latest) { return; }
          var updateMask = document.getElementById('update-mask');
          if (!updateMask) { return; }

          // 固定文案里写死的 "1.8 新版本" 换成实际版本，站点发新版不用改 HTML。
          try {
            var title = updateMask.querySelector('div div');
            if (title) { title.textContent = '🎉 Folia ' + latest + ' 新版本'; }
            var line = updateMask.querySelectorAll('p')[0];
            if (line) { line.innerHTML = '最新 <b style="color:#ff4d6d">' + latest + '</b> 版本已发布，请及时下载！'; }
          } catch (e) {}

          var KEY = 'folia.update.seen.' + latest;
          try { if (localStorage.getItem(KEY)) { return; } } catch (e) {}

          function hideUpdate() {
            updateMask.style.display = 'none';
            try { localStorage.setItem(KEY, '1'); } catch (e) {}
          }

          var closeUpdate = document.getElementById('update-close');
          if (closeUpdate) { closeUpdate.addEventListener('click', hideUpdate); }
          var openQuark = document.getElementById('update-open-quark');
          if (openQuark) {
            openQuark.addEventListener('click', function(){
              try { window.open(QUARK_URL, '_blank'); } catch (err) { location.href = QUARK_URL; }
              hideUpdate();
            });
          }
          updateMask.addEventListener('click', function(e){ if (e.target === updateMask) { hideUpdate(); } });

          // 赞赏弹窗先弹，关掉之后再弹更新公告；最多等 30 秒，用户不关就不再追。
          var waited = 0;
          var timer = setInterval(function(){
            waited += 400;
            if (!mask.classList.contains('show')) {
              clearInterval(timer);
              setTimeout(function(){ updateMask.style.display = 'flex'; }, 400);
            } else if (waited > 30000) {
              clearInterval(timer);
            }
          }, 400);
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 显式设一次完整 UA。
    ///
    /// `applicationNameForUserAgent` 是首选（系统会把它拼进标准 UA，兼容性最好），
    /// 但部分系统版本只对「用该 config 创建」的 webView 生效，保险起见这里再赋一次完整串。
    /// 两处都保留，任一生效页面都能进壳模式。
    private static func installUserAgent(on webView: WKWebView) {
        let ua: String
        if let ready = webView.value(forKey: "userAgent") as? String, !ready.isEmpty {
            ua = "\(ready) FoliaApp/2.0"
        } else {
            // 系统还没算好标准 UA：显式拼一个等价的 iPhone Safari 串，
            // 保证首个请求就带标记（页面据此决定是否进入壳模式）。
            ua = "Mozilla/5.0 (iPhone; CPU iPhone OS \(UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 FoliaApp/2.0"
        }
        // WebKit 把标准 UA 拆成多段存储，静态扫描里搜不到整串；这里显式留一份可读标记，
        // 既方便排查，也让产物校验能直接确认「壳模式标记确实编进了二进制」。
        _ = Self.userAgentMarker
        webView.customUserAgent = ua
    }

    /// 壳模式 UA 标记，页面入口脚本据此打开壳布局。
    static let userAgentMarker = "FoliaApp/2.0"

    /// 在页面里核对壳标记是否真的生效，没生效就补一次。
    /// 页面入口脚本按 UA 判定壳模式；一旦判定失败，整页会按移动浏览器渲染（86% 缩放）。
    /// 这里是最后一道保险：UA 对不上就直接把标记写进去，不依赖时序。
    /// 线上页的模块入口有自己的私有标记，两边都置上，任何一侧判定成功都能进壳模式。
    private func ensureShellFlag() {
        let js = """
        (function () {
          var root = document.documentElement;
          if (root && root.getAttribute('data-folia-shell') !== '1') {
            root.setAttribute('data-folia-shell', '1');
          }
          if (window.__FOLIA_SHELL__ === undefined) {
            try { window.__FOLIA_SHELL__ = 'ios'; } catch (e) {}
          }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
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
      // 壳的实际版本（project.yml 的 MARKETING_VERSION），赞赏弹窗的「当前版本」用它，
      // 免得线上页停在旧常量上，用户以为装错了包。
      window.__foliaAppVersion = '\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0")';
      // 注意不能把 navigator.serviceWorker 改成 undefined：线上页里 registerSW.js 会直接
      // 抛 TypeError，PWA 注册失败会让页面自己挂掉；WKWebView 里 register 本身就是空操作。
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
        ensureShellFlag()
        state.clearLoadFailure()
        // 文档加载完不等于画出来了：页面还要拉主 bundle 才能挂 React。
        // 这里只解除「导航级」失败，首屏看门狗继续跑，直到 React 真的把遮罩去掉。
        scheduleFirstPaintCheck()
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
        state.noteLoadFailure(code)
        // 失败原因分得很细：DNS(-1003)、超时(-1001)、拒绝连接(-1004)、TLS(-1200~)，
        // 只报一个数字用户看不懂，日志里也要留下域名与 URL。
        collectResourceReport { report in
            CrashLog.note("==== failure context ====\nurl=\(Self.startURL.absoluteString)\ncode=\(code)\n\(report)")
        }
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

// MARK: - 播放意图上报

/// 页面调了 `play()` 还是 `pause()`。原生据此认定「该不该有声」，
/// 后台被系统按停时才知道要不要放回去。
private final class AudioIntentRelay: NSObject, WKScriptMessageHandler {
    weak var container: WebContainerView?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let kind = message.body as? String else { return }
        DispatchQueue.main.async { [weak container] in
            if kind == "intent-play" {
                container?.markAudibleIntent()
            } else if kind == "intent-pause" {
                container?.markPausedIntent()
            }
        }
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
    weak var webView: WKWebView?

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
            if (!blank) { continue; }
            img.setAttribute('src', src);
            return;
          }
        })('\(dataURL)');
        """
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
