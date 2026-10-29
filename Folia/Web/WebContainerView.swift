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
    /// 首屏卡住后的自动重试时间窗，同样用来限流。
    private var stallRetries: [Date] = []

    /// 由系统音频中断模块同步过来的「正在后台播放」。
    ///
    /// 切歌词界面闪退时整块 `audio` 会从页面上被摘掉，暂停事件根本发不出来；
    /// 用户看到的就是「后台还在响，一进歌词界面 App 没了」。靠播放器自己上报暂停来不及，
    /// 所以由原生在检测到进程终止前一帧的状态时判定要不要自动续播。
    fileprivate static var wasAudibleInBackground = false

    /// 线上站点的域名。导航策略、诊断与重载都以它为基准。
    private static let siteHost = "app.folia-api.top"
    private static let startURL = URL(string: "https://app.folia-api.top/")!

    /// 包内离线副本的入口。
    ///
    /// `project.yml` 把 `Folia/www` 以 folder reference 打进 bundle，路径是 `Folia.app/www/`。
    /// 线上站连续失败时回退到这里，至少让用户能进到一个完整的播放器界面。
    private static var offlineIndexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www")
    }

    /// 当前是否正在用包内离线副本。决定「重试」是回线上还是重新读本地文件。
    private var isShowingOfflineCopy = false

    /// 线上加载失败后自动回退到包内副本前，允许重试的次数。
    ///
    /// 太少会把「刚好一两秒的信号抖动」也当成彻底连不上；太多则让用户白等。
    /// 失败重试本身已有 60 秒 / 2 次的限流，这里只统计「连续失败」。
    private var consecutiveLoadFailures = 0

    /// 连续失败几次判定为「线上真的不可用」，转而回退包内离线副本。
    ///
    /// 取 3：一次可能是瞬时抖动（切网络的瞬间、TLS 握手超时），两次仍可能是弱网下的
    /// 自带重试，三次连续失败基本可以确认是 DNS / 链路 / 劫持层面的持续故障，
    /// 继续重试只会让用户对着同一个失败页干等。
    private static let offlineFallbackThreshold = 3

    /// 页面调过 `audio.play()` 而还没被用户按暂停：这是「该有声」的唯一依据。
    ///
    /// 用户只按过一次播放，之后无论是切后台、锁屏、Siri 抢占还是 WebKit 自己把
    /// 媒体元素按下暂停，都算被迫中断，壳负责把它放回去。用户亲手按的暂停会清掉它。
    private var wantsAudible = false
    /// 用户亲手按了暂停，串行下发中的远程命令据此不会再把它放回去。
    private var userPaused = false
    /// 保活轮询：后台时每两秒确认一次「该响的还在响」。
    private var keepAliveTimer: Timer?
    /// 前台已经探过几次。前台不需要一直轮询，探够就停，省掉反复跨进程执行脚本的开销。
    private var foregroundProbes = 0
    private var foregroundObservation: Any?
    private var backgroundObservation: Any?
    private var networkObservation: Any?

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
        // 注入到所有 frame：离线副本里的 worker 也要把 `/api/...` 补成线上地址，
        // 否则元数据 / 歌词解析在 file:// 下会静默失败。脚本内部按协议判断，线上页不受影响。
        userContent.addUserScript(WKUserScript(
            source: Self.shellBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        // 保活与播放意图上报必须在**页面脚本之前**装好：`play` 事件是 UI 手势那一拍同步发出的，
        // 等 `didFinish` 再注入就已经听不到了 —— 原生收不到 `intent-play`，
        // 后台就不知道该把页面那条 `<audio>` 放回去，表现就是「后台一点声都没有」。
        userContent.addUserScript(WKUserScript(
            source: Self.audioKeeperScript,
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
        config.applicationNameForUserAgent = "FoliaApp/\(Self.appVersion)"
        Self.installUserAgent(on: webView)

        addSubview(webView)

        reloadObservation = state.$reloadToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hardReload() }

        webView.load(URLRequest(url: Self.startURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        scheduleProgressWatchdog()

        // 锁屏 / 耳机线控按钮 → 页面播放器。
        remoteObservation = NotificationCenter.default
            .addObserver(forName: .foliaRemoteCommand, object: nil, queue: .main) { [weak self] note in
                guard let action = note.object as? String else { return }
                self?.handleRemoteCommand(action)
            }

        observeLifecycle()
        observeNetwork()
    }

    /// 用户点「重试」时走这条路。
    ///
    /// 原先直接 `webView.reload()` 有两个坑：一是失败现场里 `webView.url` 常常是 `about:blank`，
    /// `reload()` 只是把空白页又读一遍，用户看到的就是「点了没反应」；
    /// 二是它沿用缓存策略，之前那次坏掉的重定向/或者 Service Worker 吐出的空响应会被原样再用一次。
    /// 所以这里固定回到起点 URL，并绕开本地缓存重新取。
    private func hardReload() {
        CrashLog.note("==== manual reload ====")
        didReachFirstPaint = false
        state.clearLoadFailure()
        // 离线副本上点「重试」的语义是「回线上再试一次」，而不是把本地文件重读一遍。
        // 所以这里先把离线标记清掉、失败计数归零，再走正常的线上加载。
        isShowingOfflineCopy = false
        state.leaveOfflineCopy()
        consecutiveLoadFailures = 0
        // 卡住重试的配额也要一起清掉：否则用户从离线副本点回线上后，
        // 上一轮攒下的 3 次 stall 记录会让首屏看门狗直接放弃重试。
        stallRetries.removeAll()
        webView.load(URLRequest(url: Self.startURL,
                                cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: 30))
        scheduleProgressWatchdog()
    }

    /// 回退到 App 包内的那份 `www/`。
    ///
    /// 线上站连不上时（DNS 故障、运营商劫持、跨境链路不通），继续重试只是在同一个坑里打转。
    /// 包里本来就带着一份完整的构建产物，用它至少能让用户进到界面、看到自己的本地曲库。
    ///
    /// 用 `loadFileURL(... allowingReadAccessTo: www 目录)` 而不是自定义 scheme：
    /// ES module 与相对路径的资源在 `file://` 下按同目录解析，不需要再写一套 WKURLSchemeHandler。
    private func loadOfflineCopy() {
        guard let indexURL = Self.offlineIndexURL else {
            // 包里没带离线副本（构建配置被改过）：只能停在提示层等用户手动重试。
            CrashLog.note("==== offline copy unavailable (no www/index.html in bundle) ====")
            return
        }
        CrashLog.note("==== fallback to bundled offline copy ====")
        isShowingOfflineCopy = true
        didReachFirstPaint = false
        consecutiveLoadFailures = 0
        // 包内副本不再看首屏看门狗的那份配额，清干净，切回线上时从头算。
        stallRetries.removeAll()
        state.enterOfflineCopy()
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        scheduleProgressWatchdog()
    }

    private var remoteObservation: Any?

    deinit {
        stopKeepAliveTimer()
        // block 型观察者不会随 self 释放自动注销，留着会在下一次通知时回调到已释放对象上。
        let tokens: [Any?] = [remoteObservation, foregroundObservation, backgroundObservation, networkObservation]
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
            // 回前台不改变意图：该响的继续响，轮询照旧。
            self.refreshAudioKeepAlive()
            // 系统在后台会把媒体元素按停、把会话降级，回来必须重新声明一次 category
            // 并把页面里那条停住的 `<audio>` 放回去。页面始终是唯一的播放器，
            // 原生不接管出声 —— 两套播放器抢同一个会话，正是之前「后台/回来没声音」的来源。
            self.forceResumeAudio(reason: "foreground", rebuild: true)
            CrashLog.note("==== foreground resume done (audible=\(self.wantsAudible ? 1 : 0) paused=\(self.userPaused ? 1 : 0)) ====")
            // 真正加载失败（没有页面可用）时用户往往先去开 Wi-Fi 再切回来，
            // 这里自己重试一次，不用等他再点「重试」。
            //
            // 离线副本不回切：那是「已经能用了」的兜底状态，
            // 每次回前台都踢回线上重来一遍，等于把用户正在听的播放器反复打断。
            // 要回线上由顶部提示条的「重新连接」显式触发。
            if self.state.showsBlockingNotice {
                self.hardReload()
            }
        }
        backgroundObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 进后台只做两件事：把会话立住，并开始轮询补放。
            // 系统随后来按停页面里的媒体时，4 秒内的那一拍会把它放回去。
            self.refreshAudioKeepAlive()
            self.captureProgressBeforeBackground { _ in
                self.enforcePlaybackIfNeeded(reason: "background")
            }
        }
    }

    /// 进后台时先给会话留一口气，再让保活开始补放。
    ///
    /// 超时兜底必须有：`evaluateJavaScript` 在 App 刚进后台时可能迟迟不回调。
    private func captureProgressBeforeBackground(_ done: @escaping (Bool) -> Void) {
        let js = """
        (function(){
          try {
            var list = document.querySelectorAll('audio');
            for (var i = 0; i < list.length; i += 1) {
              var el = list[i];
              if (!el.src || el.paused) { continue; }
              // 进后台前把还活着的元素直接放一次：系统随后按停它时，
              // 保活那一拍就知道刚才是在唱的，也就知道该不该放回去。
              var p = el.play();
              if (p && p.catch) { p.catch(function(){}); }
              return 'ok';
            }
            return 'idle';
          } catch (e) { return 'error'; }
        })();
        """
        var finished = false
        let finish = { (flag: String) in
            guard !finished else { return }
            finished = true
            CrashLog.note("==== background capture \(flag) ====")
            done(flag == "ok")
        }
        webView?.evaluateJavaScript(js) { result, _ in
            finish(result as? String ?? "noresult")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            finish("timeout")
        }
    }

    /// 网络恢复时自动把停在失败提示上的页面拉起来。
    ///
    /// 用户的实际操作永远是「看到没网 → 去设置里连 Wi-Fi → 切回来」，
    /// 如果非要他再点一次「重试」，大多数人会以为 App 坏了。
    private func observeNetwork() {
        networkObservation = NotificationCenter.default.addObserver(
            forName: .foliaNetworkRestored,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.state.offlineReason != nil else { return }
            self.hardReload()
        }
    }

    /// 让轮询与当前意图对齐：该响就起，不该响就停。
    private func refreshAudioKeepAlive() {
        if wantsAudible && !userPaused {
            AudioSessionController.shared.reactivate()
            startKeepAliveTimer()
            Self.wasAudibleInBackground = true
        } else {
            stopKeepAliveTimer()
            Self.wasAudibleInBackground = false
        }
    }

    // MARK: - 后台保活

    /// 页面调过 play，且用户没有亲手暂停 —— 这就是「该有声」。
    fileprivate func markAudibleIntent() {
        wantsAudible = true
        userPaused = false
        AudioSessionController.shared.updatePlaybackState(true)
        CrashLog.note("==== intent audible (state=\(UIApplication.shared.applicationState.rawValue)) ====")
        startKeepAliveTimer()
    }

    /// 页面自己暂停了。
    ///
    /// 只有 App 处于前台时的 pause 才算用户主动收手：停掉保活轮询，
    /// 否则 4 秒后又被放回去，表现就是「点了暂停又自己唱」。
    /// 后台出现的 pause 一定是被系统掐断的（会话降级、锁屏、切后台），
    /// 必须继续让保活管，所以那种情况直接忽略。
    ///
    /// 这里只停轮询、**不改 `wantsAudible`**：用户再点播放时页面会立刻发新的
    /// `intent-play`，`markAudibleIntent()` 会把意图重新立起来并重启轮询。
    fileprivate func markPausedIntent() {
        guard UIApplication.shared.applicationState == .active else { return }
        stopKeepAliveTimer()
    }

    private func startKeepAliveTimer() {
        guard keepAliveTimer == nil else { return }
        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self, self.wantsAudible, !self.userPaused else { return }
            // 后台每一拍都重试一次 play：系统掐断媒体、缓冲结束、页面自暂停都在这一拍里被兜住。
            // 前台只在「切后台后的头几秒」探一次：那时会话还没被系统按停，探一次就知道
            // 该不该接管；之后一直在前台就交给页面自己，省掉每 4 秒一次跨进程 evaluateJavaScript
            // —— 那一趟要走主线程、在 WebKit 里跑脚本，听歌时滑动列表也会被它拖顿。
            if UIApplication.shared.applicationState == .active {
                guard self.foregroundProbes < 2 else { return }
                self.foregroundProbes += 1
            }
            self.enforcePlaybackIfNeeded(reason: "keepalive")
        }
        // 挂 .common：滚动视图追踪模式下定时器也会照常触发，后台也照常。
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        foregroundProbes = 0
    }

    /// 会话激活失败时 iOS 会把媒体按停；这里把「该响的」重新放回去。
    ///
    /// 只在 `wantsAudible` 为真时动手，且每轮只做一次 `play()`：
    /// 页面自己的播放器是唯一的状态源，壳只是保证它不被系统静默掐断。
    ///
    /// 两个前提缺一不可：
    /// 1. `userPaused` 为假 —— 用户亲手按的暂停绝不覆盖；
    /// 2. 页面处于后台 —— 前台时用户可能只是想暂停，此时接管会把暂停又弹回播放。
    ///    系统掐断媒体只发生在后台，前台不需要也不应该续播。
    private func enforcePlaybackIfNeeded(reason: String) {
        guard wantsAudible, !userPaused else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        // 会话一旦被系统打断（通话、别的 App 抢占、锁屏静音），只调 play() 是没有声音的：
        // 音频通路本身已经不通。这里每拍先把会话要回来，再补 play。
        // 只 setActive 不 setCategory，所以不会像早期那样把播放器按停。
        AudioSessionController.shared.reactivate()
        // 页面出声走 WebAudio，AudioContext 在后台被钉成 interrupted 后，
        // 光 play() 是「返回成功但没声音」。所以每拍都要连上下文一起叫醒，
        // 再按「上下文是否 running」决定要不要重设 category 与重新激活会话。
        resumeAudioContexts { [weak self] active in
            guard let self else { return }
            if active {
                self.resumeAudio(reason: reason)
            } else {
                self.forceResumeAudio(reason: reason, rebuild: true)
            }
        }
    }

    /// 页面上真实在用的 AudioContext 是否处于 running。
    ///
    /// 线上页的 context 留在 React 闭包里，反射拿不到，所以保活脚本从
    /// `createMediaElementSource` 那一处把实例记了下来（见 `audioKeeperScript`）。
    /// 页面还没建过上下文时返回「没被掐住」：那种情况下播放走 `<audio>` 直出，
    /// 不必重设 category。
    private func resumeAudioContexts(_ completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
          try {
            if (typeof window.__foliaResumeAudioContexts === 'function') {
              window.__foliaResumeAudioContexts();
            }
            var c = window.__foliaActiveAudioContext;
            if (!c) { return 'none'; }
            return c.state === 'running' ? 'running' : 'blocked';
          } catch (e) { return 'none'; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            completion((result as? String) != "blocked")
        }
    }

    /// 回前台时的补放：不看前后台状态，其余条件与轮询一致。
    ///
    /// 用户很可能就是从后台回来发现「没声音」：会话在后台已被降级，
    /// 所以这里必须先补一次 `setActive`，否则 play() 成功了也是静音。
    ///
    /// `rebuild` 为真时连 Category 一起重设并派发一次 `visibilitychange`：
    /// 只在回前台用。`setCategory` 之后必须让页面知道自己「又被看见了」，
    /// 它才会把被系统挂起的 WebAudio 上下文 `resume()` 回来。
    private func forceResumeAudio(reason: String, rebuild: Bool = false) {
        guard wantsAudible, !userPaused else { return }
        if rebuild {
            AudioSessionController.shared.activate()
            revivePageAudio()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.resumeAudio(reason: reason)
            }
            return
        }
        AudioSessionController.shared.reactivate()
        resumeAudio(reason: reason)
    }

    /// 回前台时把页面被系统挂起的音频上下文唤醒。
    ///
    /// iOS 在后台会把页面的 `AudioContext` 挂成 `interrupted`，回前台不会自己恢复；
    /// 页面侧没有任何 `statechange` 监听，所以要壳来叫醒它。
    /// 这里只做两件最保守的事：把所有已知上下文 `resume()` 一遍，
    /// 再派发一次 `visibilitychange` 让页面自己走恢复逻辑 —— 不改任何全局原型。
    private func revivePageAudio() {
        let js = """
        (function(){
          try {
            if (typeof window.__foliaResumeAudioContexts === 'function') {
              window.__foliaResumeAudioContexts();
            }
            var names = ['__foliaAudioContext', 'audioContext', '__audioContext'];
            for (var i = 0; i < names.length; i += 1) {
              var c = window[names[i]];
              if (c && typeof c.resume === 'function' && c.state !== 'running') {
                try { c.resume(); } catch (e) {}
              }
            }
            document.dispatchEvent(new Event('visibilitychange'));
            return 'ok';
          } catch (e) { return 'error'; }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func resumeAudio(reason: String) {
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
          var scripts = document.scripts || [];
          var loaded = 0;
          for (var i = 0; i < scripts.length; i += 1) {
            if (scripts[i].src) { loaded += 1; }
          }
          return [
            'url=' + location.href,
            'readyState=' + document.readyState,
            'ua=' + (navigator.userAgent || '').slice(-40),
            'shell=' + (document.documentElement.getAttribute('data-folia-shell') || '-'),
            'splash=' + (splash ? (splash.className || 'visible') : 'gone'),
            'rootChildren=' + (root ? root.children.length : -1),
            'scripts=' + loaded,
            'online=' + (navigator.onLine ? '1' : '0')
          ].join('\\n');
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.didReachFirstPaint else { return }
                // 离线副本本身就是完整构建产物，卡住说明是包内资源的问题，
                // 再回退一次没有意义，只保留「重新读一遍」的重试。
                guard !self.isShowingOfflineCopy else { return }
                let detail = (result as? String) ?? (error?.localizedDescription ?? "页面无响应")
                CrashLog.note("==== first paint timeout ====\n\(detail)")
                self.state.noteStalled(detail: detail)
                self.retryLoadForStall()
            }
        }
    }

    /// 卡住时是否还能自动重试：一分钟内最多三次，避免「卡住 → 重载 → 又卡住」的抖动。
    private func retryLoadForStall() {
        // 卡住和「连不上」是同一件事的两面：换了 bundle 之后页面结构对了、但资源仍拉不下来，
        // 导航是成功的，`didFailProvisionalNavigation` 不会触发，只能在这里累计。
        // 计数与限流分开算：计数决定「要不要回退」，限流只决定「还自动重载几次」。
        consecutiveLoadFailures += 1
        if consecutiveLoadFailures >= Self.offlineFallbackThreshold {
            CrashLog.note("==== consecutive failures reached \(consecutiveLoadFailures) at stall, falling back ====")
            loadOfflineCopy()
            return
        }
        let now = Date()
        stallRetries = stallRetries.filter { now.timeIntervalSince($0) < 60 }
        guard stallRetries.count < 3 else {
            CrashLog.note("==== stall retry exhausted, waiting for manual reload ====")
            return
        }
        stallRetries.append(now)
        CrashLog.note("==== stall retry #\(stallRetries.count) ====")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.didReachFirstPaint = false
            self.webView?.load(URLRequest(url: Self.startURL,
                                          cachePolicy: .reloadIgnoringLocalCacheData,
                                          timeoutInterval: 30))
            self.scheduleProgressWatchdog()
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
        // 真正的那份在 `audioKeeperScript` 里，随文档开始一起注入；这里只兜一次「脚本被清掉」的情况。
        ensureAudioKeeper()
    }

    /// 保活 + 播放状态上报。
    ///
    /// 页面自己不会在切后台时暂停；真正被掐断的是 iOS 在会话失效后按停媒体元素，
    /// 或者 WebKit 的内容进程被系统短暂挂起。所以这里做两件事：
    /// 1. 记录页面的播放意图（`play()` / `pause()` 被调用即上报），意图在原生这边保存；
    /// 2. 后台每两秒确认一次会话有效，并把「该响但被按停」的媒体放回去。
    private static let audioKeeperScript = """
        (function(){
          if (window.__foliaAudioKeeperInstalled) { return; }
          window.__foliaAudioKeeperInstalled = true;

          // 线上页的出声方式是 WebAudio：`<audio>` 只当解码源（`createMediaElementSource`），
          // 真正送到扬声器的是 `AudioBufferSourceNode`，接在 `AudioContext` 上。
          //
          // 这决定了保活必须怎么做：iOS 把 App 切到后台时会把 AudioContext 置为
          // `interrupted`，音频图整体停摆。此时调 `audio.play()` 返回成功却一点声都没有，
          // 页面自己也拿不到恢复时机 —— 源码里没有任何 `statechange` 监听。
          //
          // 注意这里**不改 `window.AudioContext` 构造函数**（不用 Proxy、不换包装），
          // 那和之前改写原型是同一类操作，切歌词重建播放器树时会放大崩溃风险。
          // 改用最保守的方式：只在自己的探测上下文上挂一个监听，并不断探测页面上
          // 那个上下文何时进入 running/interrupted，把状态上报给原生。
          //
          // 页面已有的 AudioContext 实例无法反射取得，所以探测它的状态靠两条路：
          // 1. `__foliaProbe` 自己建一个上下文，只可能是 running/suspended；
          // 2. 页面把 context 挂在 window 上的常见位置（React 应用通常留在闭包里，
          //    所以这一步只是兜底，不指望一定命中）。
          window.__foliaResumeAudioContexts = function(){
            var resumed = 0;
            var extra = window.__foliaAudioContexts || [];
            try {
              var names = ['__foliaAudioContext', 'audioContext', '__audioContext'];
              for (var i = 0; i < names.length; i += 1) {
                var c = window[names[i]];
                if (c && typeof c.resume === 'function' && c.state !== 'running') {
                  try { c.resume(); resumed += 1; } catch (e) {}
                }
              }
              // 页面真实的上下文（从 createMediaElementSource 那里记下来的）。
              for (var j = 0; j < extra.length; j += 1) {
                var d = extra[j];
                if (d && typeof d.resume === 'function' && d.state !== 'running') {
                  try { d.resume(); resumed += 1; } catch (e) {}
                }
              }
            } catch (e) {}
            return resumed;
          };

          // 页面真正的 AudioContext 实例。
          //
          // 播放器的 context 留在 React 闭包里，反射拿不到，于是这里只在
          // `createMediaElementSource` 上绕一层：那是页面把 `<audio>` 接进 WebAudio 的
          // 唯一入口，任何播放器（含切歌词重建后的新实例）都必须经过它。
          // 只包装这一个方法、且只做「记下 this 再原样返回」，不动原型上的其它行为，
          // 与之前那版批量改写原型（会触发切歌词闪退）不是一回事。
          window.__foliaAudioContexts = window.__foliaAudioContexts || [];
          window.__foliaActiveAudioContext = null;
          try {
            var proto = window.AudioContext && window.AudioContext.prototype;
            var raw = proto && proto.createMediaElementSource;
            if (raw && !raw.__foliaWrapped) {
              var wrappedSource = function(){
                try {
                  var list = window.__foliaAudioContexts;
                  for (var i = 0; i < list.length; i += 1) {
                    if (list[i] === this) { return raw.apply(this, arguments); }
                  }
                  list.push(this);
                  window.__foliaActiveAudioContext = this;
                } catch (e) {}
                return raw.apply(this, arguments);
              };
              wrappedSource.__foliaWrapped = true;
              proto.createMediaElementSource = wrappedSource;
            }
          } catch (e) {}

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

          // 注意：这里**不能**去改 `window.fetch` / `XMLHttpRequest` / `HTMLMediaElement.prototype`
          // 这类全局原型。页面是 React 应用，切换歌词形式时会重建整棵播放器树，
          // 期间会对原型链做批量探测；被改写过的原型在 WKWebView 里可能触发
          // 「WebProcess 崩掉」—— 用户看到的就是切歌词形式直接闪退。
          // 现在改成只在真正的媒体元素上挂监听（见下方 capture 阶段），不动任何原型。

          var post = function(kind){
            try {
              window.webkit.messageHandlers.foliaAudioIntent.postMessage(kind);
            } catch (e) {}
          };

          // 用事件捕获而不是包 play/pause：
          // `play` 事件在真正开始播放时触发，`pause` 在停下时触发；
          // 两者都只在 AUDIO 元素上处理，不碰原型链。
          //
          // 同时把「哪首、放到哪、多长」报给原生：壳靠它知道后台该从哪一秒接着放，
          // 以及被打断后续播的是不是同一首。
          var currentAudio = function(){
            var list = document.querySelectorAll('audio');
            for (var i = 0; i < list.length; i += 1) {
              if (!list[i].ended && list[i].src) { return list[i]; }
            }
            return null;
          };
          document.addEventListener('play', function(e){
            var el = e.target;
            if (!el || el.tagName !== 'AUDIO') { return; }
            post('intent-play');
            // 页面切歌时只在这里补一条进度：`src` 变了原生才知道是「换了一首」，
            // 才不会把上一首的秒数套到新曲目上（表现就是回前台从头开始）。
            // 同一首从头再放（缓冲完、切歌词重建播放器树）也要报，但只在确实接近 0 时，
            // 否则会把「放到第 90 秒」误报成 0。
            if ((el.currentTime || 0) < 1.5) {
              try {
                var d = el.duration;
                window.webkit.messageHandlers.foliaAudioIntent.postMessage('progress|' + JSON.stringify({
                  src: el.src,
                  position: el.currentTime || 0,
                  duration: (d && isFinite(d)) ? d : 0,
                  playing: true
                }));
              } catch (e) {}
            }
          }, true);
          document.addEventListener('seeked', function(e){
            var el = e.target;
            if (!el || el.tagName !== 'AUDIO') { return; }
            try {
              window.webkit.messageHandlers.foliaAudioIntent.postMessage('seek|' + JSON.stringify({
                position: el.currentTime || 0
              }));
            } catch (e) {}
          }, true);
          document.addEventListener('pause', function(e){
            var el = e.target;
            if (!el || el.tagName !== 'AUDIO') { return; }
            // 播完的 pause 不算用户意图，否则一轮播完就不再续播。
            if (el.ended) { return; }
            // 前后台都照报：前台的是用户收手，后台的是系统掐断。
            // 两者的区别交给原生判断（`markPausedIntent()` 只在 App 处于 active 时才停轮询），
            // 页面这边不做取舍 —— `visibilityState` 在 WKWebView 切后台的瞬间并不总是
            // 先变 hidden 再发 pause，靠它过滤会把真正的用户暂停也一起吞掉。
            post('intent-pause');
          }, true);

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

          // 进度单独报：每 5 秒一条，只在后台跑。
          var reportProgress = function(){
            try {
              var el = currentAudio();
              if (!el || el.paused) { return; }
              var d = el.duration;
              window.webkit.messageHandlers.foliaAudioIntent.postMessage('progress|' + JSON.stringify({
                src: el.src,
                position: el.currentTime || 0,
                duration: (d && isFinite(d)) ? d : 0,
                playing: true
              }));
            } catch (e) {}
          };

          // WebAudio 走 createMediaElementSource 时元素本身不直出声音，
          // 但 iOS 仍以「页面上有在播放的媒体」来维持后台音频，所以这里持续观察。
          // 播放状态改为纯事件驱动：`playing` / `pause` / `visibilitychange` 时才报。
          // 之前是每秒轮询一次（`setInterval(report, 1000)`），在 WebKit 里要跨进程序列化参数，
          // 播放时每秒一趟会稳定掉帧，滑动列表也发涩。
          document.addEventListener('playing', report, true);
          document.addEventListener('pause', report, true);
          // 补报一次：文档开始时装的监听只覆盖「之后的 play」，而页面可能在
          // 首屏挂载时就自动续上上一首，那一拍早于 React 跑起来，得靠这里补。
          document.addEventListener('DOMContentLoaded', reportProgress, true);
          // 进度只在后台需要：前台交给页面自己走，轮询毫无用处还白耗。
          var progressTimer = 0;
          var syncProgressTimer = function(){
            var backgrounded = document.visibilityState !== 'visible';
            if (backgrounded && !progressTimer) {
              progressTimer = setInterval(reportProgress, 5000);
            } else if (!backgrounded && progressTimer) {
              clearInterval(progressTimer);
              progressTimer = 0;
            }
          };
          document.addEventListener('visibilitychange', syncProgressTimer);
          syncProgressTimer();
          document.addEventListener('visibilitychange', function(){
            if (document.visibilityState === 'visible') { report(); return; }
            // 切后台前再补一条最新进度：系统随后就会把 AudioContext 钉住，
            // 页面的 currentTime 不再前进，原生只能拿到这条里的数字。
            reportProgress();
          });
          report();
        })();
        """

    /// 功能入口：脚本在 `didFinish` 后再补注入一次，兜住「文档开始时注入被页面重置」的情况。
    private func ensureAudioKeeper() {
        webView?.evaluateJavaScript(Self.audioKeeperScript, completionHandler: nil)
    }

    /// 网易云扫码登录的兜底。
    ///
    /// `/login/qr/create` 只有带 `qrimg=true` 才返回 base64 图片，不带就返回空串，
    /// 界面上会一直转圈。这里不再改写 `window.fetch`（改全局函数会影响页面所有请求，
    /// 且切歌词重建播放器树时容易出事），改为只在 DOM 层面兜底：
    /// 二维码图片为空时，从页面里已有的 `qrurl` 本地画一张（见 `foliaQrFallback`）。
    private func installLoginHelpers() {
        let js = """
        (function(){
          if (window.__foliaLoginHelpers) { return; }
          window.__foliaLoginHelpers = true;

          // 观察登录弹窗里的二维码图片：src 为空或加载失败时，把页面上的 qrurl 交给原生重画。
          // 只处理弹窗内部，避免把封面、图标这类正常图片误判成二维码。
          var fixImage = function(img){
            try {
              if (!img || img.__foliaQrFixed) { return; }
              var box = img.closest('[id*="qr"], [class*="qr"], [class*="QR"], [class*="login"]');
              if (!box) { return; }
              var src = img.getAttribute('src') || '';
              if (src && src.indexOf('data:') === 0) { return; }
              img.__foliaQrFixed = true;
              var target = img.getAttribute('data-qrurl') || '';
              if (!target && box.innerText) {
                var m = box.innerText.match(/https?:\\/\\/[^\\s"']+/i);
                if (m) { target = m[0]; }
              }
              if (!target) { return; }
              window.webkit.messageHandlers.foliaQrFallback.postMessage(target);
            } catch (e) {}
          };

          var scan = function(){
            try {
              // 登录弹窗没开着时直接退出：之前在首页也每两秒全文档查一遍
              // `[class*="qr"]`，播放中白白占主线程，滑动会顿。
              if (!document.querySelector('[class*="login"], [id*="login"], [class*="Login"]')) { return; }
              var boxes = document.querySelectorAll('[id*="qr"], [class*="qr"], [class*="QR"]');
              for (var i = 0; i < boxes.length; i += 1) {
                var imgs = boxes[i].querySelectorAll('img');
                for (var j = 0; j < imgs.length; j += 1) { fixImage(imgs[j]); }
              }
            } catch (e) {}
          };

          document.addEventListener('error', function(e){
            var t = e.target;
            if (t && t.tagName === 'IMG') {
              t.__foliaQrFixed = false;
              fixImage(t);
            }
          }, true);

          // 二维码是弹窗打开后才插入的，这里低频轮询一次，避免 MutationObserver 在这类
          // 高频重渲染的页面上放大成本。
          setInterval(scan, 3000);
          scan();
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
    /// 版本号与更新公告也一并接手：壳把 Info.plist 的实际版本写进 `window.__foliaAppVersion`，
    /// 「当前版本」与「最新版本」都取它，改版本只需要改 project.yml 一处。
    private func installDonateCard() {
        let js = """
        (function(){
          if (window.__foliaDonateInstalled) { return; }
          var mask = document.getElementById('donate-mask');
          if (!mask) { return; }
          window.__foliaDonateInstalled = true;

          var QUARK_URL = 'https://pan.quark.cn/s/934c480d5b9c';

          // 两个版本号都取壳带进来的实际版本（Info.plist 的 MARKETING_VERSION）：
          // 线上页的常量停在 1.8.5，沿用会让「当前版本」永远显示旧值。
          // 壳内「最新版本」=「当前版本」，因为包就是从网盘拿的最新那一份。
          var cur = window.__foliaAppVersion || '';
          var latest = cur;

          var verNum = document.getElementById('donate-version-num');
          if (verNum && cur) { verNum.textContent = cur; }
          var latestNum = document.getElementById('donate-latest-num');
          if (latestNum && latest) { latestNum.textContent = latest; }

          var getLatest = document.getElementById('donate-get-latest');
          if (getLatest) {
            // 公告照弹、获取入口保留：这里是「去网盘拿最新包」的唯一入口，
            // 版本号相同也照样可点，不能因为 2.0 就把它藏掉。
            getLatest.addEventListener('click', function(e){
              e.preventDefault();
              try { window.open(QUARK_URL, '_blank'); } catch (err) { location.href = QUARK_URL; }
            });
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

          // 更新公告（#update-mask）在壳里不弹：版本号已经固定成 2.0，
          // 这条「新版本已发布」对已装最新包的人只是打扰。网盘入口保留在赞赏弹窗里。
          var updateMask = document.getElementById('update-mask');
          if (updateMask) { updateMask.style.display = 'none'; }
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
            ua = "\(ready) FoliaApp/\(Self.appVersion)"
        } else {
            // 系统还没算好标准 UA：显式拼一个等价的 iPhone Safari 串，
            // 保证首个请求就带标记（页面据此决定是否进入壳模式）。
            ua = "Mozilla/5.0 (iPhone; CPU iPhone OS \(UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 FoliaApp/\(Self.appVersion)"
        }
        // WebKit 把标准 UA 拆成多段存储，静态扫描里搜不到整串；这里显式留一份可读标记，
        // 既方便排查，也让产物校验能直接确认「壳模式标记确实编进了二进制」。
        _ = Self.userAgentMarker
        webView.customUserAgent = ua
    }

    /// 壳模式 UA 标记，页面入口脚本据此打开壳布局。
    static let userAgentMarker = "FoliaApp/\(appVersion)"

    /// 壳版本号：唯一取自 Info.plist，改版本只改 project.yml 一处。
    /// UA 只用来判定「是不是壳」（正则匹配 `FoliaApp`），带版本号不影响壳模式识别，
    /// 但能让线上日志一眼看出是哪个版本的壳在跑。
    static let appVersion: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

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
      window.__foliaAppVersion = '\(appVersion)';
      // 更新公告在壳里不弹。页面脚本自带 UA 判定会提前 return，本不该弹；
      // 这里在文档开始时先钉一条样式兜底，任何时序下都压住 #update-mask。
      // 脚本注入点早于 <head>，所以等 DOMContentLoaded 再插入。
      (function(){
        function hide(){
          try {
            var style = document.createElement('style');
            style.id = 'folia-hide-update';
            style.textContent = '#update-mask{display:none !important;}';
            (document.head || document.documentElement).appendChild(style);
          } catch (e) {}
        }
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', hide);
        } else {
          hide();
        }
      })();
      // 注意不能把 navigator.serviceWorker 改成 undefined：线上页里 registerSW.js 会直接
      // 抛 TypeError，PWA 注册失败会让页面自己挂掉；WKWebView 里 register 本身就是空操作。
      //
      // 离线副本（file://）里页面代码对接口用的是相对路径（`/api/...`），
      // 在 file:// 下会被解析成 `file:///api/...`，登录、歌单、同步全部直接失败。
      // 这里在文档最开始就包一层 fetch，把相对路径补成线上绝对地址；
      // 只在 file:// 下生效，线上页完全不受影响。
      (function(){
        if (location.protocol !== 'file:' || typeof window.fetch !== 'function') { return; }
        var base = '\(WebContainerView.startURL.absoluteString)';
        var originalFetch = window.fetch;
        window.fetch = function(input, init){
          try {
            if (typeof input === 'string' && input.charAt(0) === '/' && input.charAt(1) !== '/') {
              input = base.replace(/\\/$/, '') + input;
            } else if (input && input.url && input.url.indexOf('file:') === 0) {
              input = base.replace(/\\/$/, '') + '/' + input.url.replace(/^file:\\/\\/.*?\\//, '');
            }
          } catch (e) {}
          return originalFetch.call(window, input, init);
        };
      })();
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
    ///
    /// 包内离线副本的文档是 `file://`，`fetch` / XHR 走不到这里，
    /// 但页面里对 API 的**相对路径**请求在 file:// 下会变成非法地址。
    /// 这里把 `file://` 发起、目标是线上域名的请求直接放行到网络，读不到本地文件时不至于整体失败。
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
            // 离线副本（file://）里出现的绝对地址外链也要外跳：本地页没有站内路由可走。
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        // 离线副本里站内链接如果是绝对地址（https://app.folia-api.top/...），
        // 主框架会直接跳到线上：此时壳还以为自己在本地页上，"重试"会不断往 file:// 打。
        // 主框架真的走出去时，就地切回线上加载态。
        if isMainFrame && isSameSite && scheme != "file" {
            isShowingOfflineCopy = false
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastInsets = .zero
        pushInsetsIfNeeded()
        ensureShellFlag()
        state.clearLoadFailure()
        // 线上页真的加载成功了：之前挂过的离线副本提示要收起来，
        // 否则用户已经回到线上，提示层还盖在页面上说「当前用的是离线版本」。
        if !isShowingOfflineCopy {
            state.leaveOfflineCopy()
        }
        // 这一轮导航成功了，连续失败计数要归零；否则几次零星失败会一直累加，
        // 之后某一次无关的抖动就能直接触发回退。
        consecutiveLoadFailures = 0
        // 卡住重试的配额同属「这一轮」的概念，成功一次就该重新计数。
        stallRetries.removeAll()
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
        // 离线副本是本地文件，导航失败说明包有问题，重试本地文件没有意义，
        // 直接交给提示层（`OfflineNotice`）。
        guard !isShowingOfflineCopy else { return }
        // 回退判断必须排在下面的限流之前：`contentProcessRestarts` 是「进程级重启」的配额，
        // 而这里统计的是「这一轮连续几次加载失败」。若放在限流之后，第一次失败就占掉配额、
        // 第二次直接 return，后面的计数永远到不了阈值 —— 回退逻辑形同虚设。
        consecutiveLoadFailures += 1
        if consecutiveLoadFailures >= Self.offlineFallbackThreshold {
            CrashLog.note("==== consecutive failures reached \(consecutiveLoadFailures), falling back ====")
            loadOfflineCopy()
            return
        }
        guard contentProcessRestarts.count < 2 else { return }
        contentProcessRestarts.append(now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak webView] in
            webView?.load(URLRequest(url: Self.startURL,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 30))
        }
    }

    /// 导航已提交、文档也到了，但主 bundle 没跑起来（`didFailProvisionalNavigation` 不会触发）。
    ///
    /// 现场里最常见的是「页面只剩一张静态壳」：导航看起来成功了，
    /// 用户看到的是纯黑或半截页面，点哪儿都没反应，也没有任何重试入口。
    /// 这里补一条导航级失败通道，界面至少能给出可点的「重试」。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        CrashLog.note("==== navigation failed \(code) \(error.localizedDescription) ====")
        state.noteLoadFailure(code)
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

        // 网页进程被打死后，页面里的 `<audio>` 随之消失，声音立刻断掉 ——
        // 用户实际经历的是「切歌词界面，音乐停了 / App 退回首页」。
        // 这里先把现场抓下来：崩溃前的标题、当前路由，以及崩溃时是否还在出声。
        collectTerminationContext()

        if contentProcessRestarts.count <= 2 {
            // 崩溃前正在出声，且用户没按过暂停：重载后把播放续上。
            // 用户感知到的就不是「闪退了」，而是「歌断了一下又响了」。
            let shouldResume = Self.wasAudibleInBackground && !userPaused
            webView.reload()
            if shouldResume {
                wantsAudible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self else { return }
                    self.forceResumeAudio(reason: "process-restart")
                }
            }
        } else if contentProcessRestarts.count == 3 {
            webView.load(URLRequest(url: Self.startURL))
        } else {
            // 一分钟内挂了四次，说明继续重建只会更糟，先停在这里等用户手动刷新。
            NSLog("[Folia] content process terminated repeatedly, stop auto reload")
        }
    }

    /// 抓一份「进程死掉时页面长什么样」的现场。
    ///
    /// 页面脚本早在切歌词时就已随进程一起消失，`evaluateJavaScript` 拿不到任何东西；
    /// 但 `title` / `url` 仍留在 UI 进程这一侧的 WKWebView 上，
    /// 足以判断「是不是在歌词页被杀」——若是，就能确认是页面重建播放器树时把进程搞死的。
    private func collectTerminationContext() {
        let title = webView.title ?? "-"
        let url = webView.url?.absoluteString ?? "-"
        let audible = Self.wasAudibleInBackground ? "1" : "0"
        CrashLog.note("==== termination context ====\ntitle=\(title)\nurl=\(url)\naudible=\(audible)")
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
        guard let body = message.body as? String else { return }
        DispatchQueue.main.async { [weak container] in
            if body == "intent-play" {
                container?.markAudibleIntent()
            } else if body == "intent-pause" {
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
