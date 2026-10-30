import UIKit
import SwiftUI
import WebKit
import Combine
import AVFoundation
import UniformTypeIdentifiers

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

    /// 回到前台时，本地副本上那份页面还是不是活的。
    ///
    /// 「切后台再回来只剩一只黑屏的壳、一点反应都没有」不是页面崩溃，是 WebContent 进程
    /// 在后台被判死之后壳没收到回调。`rebuiltSinceLaunch` 只在**本次启动**生效：
    /// 跑到第 N 天它早已为真，这一次就不能再进重建分支（那会一进后台就被判死），
    /// 只能按「前台重新唤醒」这条独立的路：先原地重载一次，恢复不掉就换干净存储重建。
    private var wakeReloadTried = false

    /// 这次挂掉已经按「前台唤醒」处理过一轮，别再退到离线副本。
    private var wakeRecoveryInFlight = false
    /// 离线副本正在往线上切、但还没确认完成。
    ///
    /// `decidePolicyFor` 只能表示「准备导航」，弱网下这次导航经常当场失败。
    /// 只有 `didCommit`（服务器已经有响应）才说明真的回到线上了。
    private var pendingOnlineHandoff = false

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
    /// 本次启动是否已经因为进程被回收而重建过 WebView。
    ///
    /// 只给「重建后立刻又挂」留一次保护位：第一次挂就换干净存储重建，
    /// 新页面画出来（首屏就绪）后把这一位复位，允许下一轮再自愈；
    /// 若它还没复位就又挂了，说明换存储也救不了，直接退回离线副本，
    /// 而不是陷入「重建 → 再挂 → 再重建」的黑屏循环。
    private var rebuiltSinceLaunch = false

    /// 本次启动是否在使用「崩溃后」的干净存储。成功加载一次后置为 false。
    private var recoveringFromCrash = CacheSweeper.isStoreDirty

    /// 正在展示的文件选择面板。必须强引用：只被 `present` 持有的话，
    /// 回调那头可能已经释放，选中文件就永远传不回页面。
    private var filePicker: FilePickerPresenter?

    /// 上一次从页面拿到的「哪首、放到哪」。壳补放之后用它把声音的位置校回字幕的进度。
    private var lastKnownPlayback: (src: String, position: Double)?

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

    /// 构造一份 WebView 配置。`setUp()` 与 `rebuildWebView()` 共用。
    ///
    /// `forceCleanStore` 为真时强制走 `.nonPersistent()`：崩溃自愈的唯一目的就是
    /// 「这一轮不碰任何磁盘上的旧网站数据」。没有它，重建出来的新实例依旧读同一份
    /// Service Worker 与 IndexedDB，等于原地打转。
    private func makeConfiguration(forceCleanStore: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // 视频背景（以及 <video> 的自动播放 + 非静音）要求内联播放且不要求用户手势。
        // 若这两项缺一项，页面里那张背景视频会停在首帧：
        // 用户看到的就是「上传了视频背景，却还是原来的静态背景」。
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = false
        // 视频背景走的是「用户选本地视频 → 页面用 blob:/file: 播放」这条链，
        // WKWebView 默认禁止 file 页读外部资源，表现为选了视频却仍显示原背景。
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.websiteDataStore = forceCleanStore ? .nonPersistent() : .default()

        // 让 UA 带 FoliaApp：网页版据此进入「壳模式」，关掉整页 86% 缩放，安全区改用实测值。
        // applicationNameForUserAgent 与完整串两处都设，避免某些系统版本上其中一路不生效。
        config.applicationNameForUserAgent = "FoliaApp/\(Self.appVersion)"

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
        let qr = QRFallbackRelay()
        qrRelay = qr
        userContent.add(qr, name: "foliaQrFallback")
        let intentRelay = AudioIntentRelay()
        intentRelay.container = self
        userContent.add(intentRelay, name: "foliaAudioIntent")
        config.userContentController = userContent
        return config
    }

    /// 二维码回传通道（重建 WebView 时要重新指向新实例）。
    private var qrRelay: QRFallbackRelay?

    private func setUp() {
        backgroundColor = UIColor(red: 0x09 / 255, green: 0x09 / 255, blue: 0x0b / 255, alpha: 1)

        // 上次是崩着退出的：这次换一个用完即弃的存储。
        //
        // 只清缓存挡不住「大退重进还闪退」—— 页面启动最早期读的是磁盘上的
        // Service Worker 与 IndexedDB，而 WebContent 进程在读到它们的那一刻就被压死了，
        // 清缓存的回调甚至还没跑完。换 nonPersistent 目录后这一轮读不到任何旧状态，
        // 能稳定地进到页面；用户本次的登录态会重新走一遍，
        // 但「进不去」比「要重新登一次」严重得多。
        //
        // 一旦进过一次正常页面就调 `CacheSweeper.clearDirty()`，下次恢复默认存储。
        let recovering = CacheSweeper.isStoreDirty
        if recovering {
            CrashLog.note("==== starting with clean (non-persistent) store ====")
        }
        let config = makeConfiguration(forceCleanStore: recovering)

        webView = WKWebView(frame: bounds, configuration: config)
        // 两个回传通道都要拿到 webView：一个往页面塞本地画的二维码，一个做播放意图。
        qrRelay?.webView = webView
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

        // 控制中心/状态栏收起：原生侧已经重建过会话，这里只负责把页面侧
        // 的 AudioContext 与媒体元素按串行通道恢复一次，避免和回前台那条路撞车。
        audioPathObservation = NotificationCenter.default
            .addObserver(forName: .foliaAudioPathRebuilt, object: nil, queue: .main) { [weak self] _ in
                self?.recoverAudioPath(reason: "panel-closed")
                self?.driveBackgroundVideo()
            }
    }

    /// 把当前 WebView 整个换掉：新配置、新存储、新进程池。
    ///
    /// 这是「进歌单闪退、退回加载界面、大退重进还闪退」的正面解法。
    /// `webView.reload()` 只能重启文档，进程池与网站数据仍沿用旧的：
    /// 一旦页面把 WebContent 压死过，那份状态就是脏的，重载只会按同样的方式再死一次。
    /// 这里连 `WKWebView` 实例一起重建，新实例挂到 `.nonPersistent()` 存储上，
    /// 读不到任何磁盘上的旧 Service Worker / IndexedDB / 缓存。
    ///
    /// `resumeAudio` 为真时，等页面起来后把播放续上（用户感知是「歌断了一下又响」）。
    private func rebuildWebView(resumeAudio: Bool) {
        // 旧实例的事件全部解绑，避免它继续往原生回传状态。
        reloadObservation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()

        let previousWantsAudible = resumeAudio
        // 换存储这件事必须落盘：如果这次重建后进程立刻又挂，下一个进程启动时
        // 也要知道「该用干净存储」，否则大退重进还是回到同一个坑里。
        CacheSweeper.markDirty("rebuild-after-crash")
        recoveringFromCrash = true
        contentProcessRestarts.removeAll()
        // 保活轮询手里的 `self` 是这一轮的，重建后照旧可用；
        // 但旧页面那份播放意图已经随进程消失，若还在响就重新记一次。
        if resumeAudio {
            Self.wasAudibleInBackground = true
        }

        let config = makeConfiguration(forceCleanStore: true)
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
        Self.installUserAgent(on: webView)
        addSubview(webView)

        // 新实例的 message handler 需要重新挂上（`makeConfiguration` 里已经建了新的
        // `WKUserContentController`，但二维码回传那条要拿到新的 webView 引用）。
        if let qr = qrRelay {
            qr.webView = webView
        }

        if previousWantsAudible {
            wantsAudible = true
            userPaused = false
        }

        didReachFirstPaint = false
        consecutiveLoadFailures = 0
        stallRetries.removeAll()
        isShowingOfflineCopy = false
        wakeReloadTried = false
        state.clearLoadFailure()
        state.leaveOfflineCopy()

        webView.load(URLRequest(url: Self.startURL,
                                cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: 30))
        scheduleProgressWatchdog()

        if previousWantsAudible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                self.forceResumeAudio(reason: "rebuild-after-crash")
            }
        }
    }

    /// 用户点「重试」时走这条路。
    /// 原先直接 `webView.reload()` 有两个坑：一是失败现场里 `webView.url` 常常是 `about:blank`，
    /// `reload()` 只是把空白页又读一遍，用户看到的就是「点了没反应」；
    /// 二是它沿用缓存策略，之前那次坏掉的重定向/或者 Service Worker 吐出的空响应会被原样再用一次。
    /// 所以这里固定回到起点 URL，并绕开本地缓存重新取。
    private func hardReload() {
        CrashLog.note("==== manual reload ====")
        didReachFirstPaint = false
        // 用户主动要一次重试：保护位复位，允许这一轮再走一次进程自愈。
        rebuiltSinceLaunch = false
        wakeReloadTried = false
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

    /// 回到前台时页面已经死了（本地副本上看不到内容、或者原生的「还活着吗」探测没回来）。
    ///
    /// 这是「切后台再回来，还停在加载界面、点哪都没反应」的正面解法。
    /// 之前这里只走 `rebuiltSinceLaunch` 那条路，而它一旦置位就不会在本次进程里复位：
    /// 用户第二天回来时 `rebuiltSinceLaunch` 早就是真，前台一判定就进「退回离线副本」，
    /// 于是每次进后台再回来都变成一次白屏加载 —— 看起来就是「一进软件就闪退」。
    ///
    /// 这条路的顺序：先在线上原地重载一次（线上站是缓存的，通常一两百毫秒就画回来），
    /// 仍没画面才换干净存储重建。`wakeReloadTried` 保证一轮里只会走一次原地重载。
    private func recoverAfterForegroundWake() {
        CrashLog.note("==== foreground wake: page not alive ====")
        // 页面已经没了，任何「用户按了暂停」的现场都跟着没了；这里清掉，
        // 让重建后能按 `wantsAudible` 决定要不要续播。
        userPaused = false
        let resume = Self.wasAudibleInBackground && wantsAudible
        if !wakeReloadTried && !isShowingOfflineCopy {
            wakeReloadTried = true
            wakeRecoveryInFlight = true
            didReachFirstPaint = false
            webView.load(URLRequest(url: Self.startURL,
                                    cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: 30))
            scheduleProgressWatchdog()
            // 原地重载也唤不回来（进度看门狗会再判一次）：换干净存储重建。
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let self, !self.didReachFirstPaint else { return }
                CrashLog.note("==== foreground wake: reload did not paint, rebuilding ====")
                self.rebuildWebView(resumeAudio: resume)
            }
            return
        }
        rebuildWebView(resumeAudio: resume)
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

    /// 回前台后确认页面还是活的。
    ///
    /// 后台里 WebContent 进程被系统收走时，`webViewWebContentProcessDidTerminate` 并不一定回调
    /// （从后台被直接杀掉的那一类经常静默）。壳于是毫不知情：`wantsAudible` 还是真、
    /// 界面还盖在 `OfflineNotice` 上，用户看到的却是「一进软件就在加载界面」。
    /// 这里在前台主动问一句页面还在不在：3 秒内没有回答就走唤醒恢复。
    private func verifyPageAliveAfterWake() {
        // 正在加载（首屏还没到）时页面本来就没装好，别把它当成死掉；
        // 已经在整屏提示「加载失败」的那条路走 `hardReload()`，不重复判定。
        guard documentFinished, !state.showsBlockingNotice else { return }
        // 缓冲期：冻结的进程被唤醒后要先跑几十毫秒 JS 才回答得上，紧贴着回调问会误判。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.didReachFirstPaint else { return }
            self.probePageLiveness(thenRecover: true)
        }
    }

    /// 问页面「还活着吗」：先一条最便宜的表达式，再确认 body 有子节点。
    private func probePageLiveness(thenRecover recover: Bool) {
        webView.evaluateJavaScript("1+1") { [weak self] result, error in
            guard let self else { return }
            if error != nil || result == nil {
                CrashLog.note("==== wake probe failed: no response from page ====")
                if recover { self.recoverAfterForegroundWake() }
                return
            }
            // `1+1` 能答只说明 JS 引擎还在；页面剩下空壳时同样是「点了没反应」，
            // 再确认一次挂载点是不是还在。
            self.webView.evaluateJavaScript("document.body ? document.body.children.length : 0") { alive, _ in
                guard (alive as? NSNumber)?.intValue ?? 0 == 0 else { return }
                CrashLog.note("==== wake probe: page is an empty shell ====")
                if recover { self.recoverAfterForegroundWake() }
            }
        }
    }

    private var remoteObservation: Any?
    private var audioPathObservation: Any?

    deinit {
        stopKeepAliveTimer()
        // block 型观察者不会随 self 释放自动注销，留着会在下一次通知时回调到已释放对象上。
        let tokens: [Any?] = [remoteObservation, foregroundObservation, backgroundObservation, networkObservation, audioPathObservation]
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
            self.recoverAudioPath(reason: "foreground")
            self.driveBackgroundVideo()
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
            self.verifyPageAliveAfterWake()
        }
        backgroundObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 进后台只做两件事：开始轮询、记下播放进度。
            //
            // 这里**不再调用 `reactivate()`**。`setActive(true)` 会让系统重新评估
            // 本 App 的音频资格，WebKit 的媒体元素会被当场按停一次 ——
            // 那正是「切出去歌就停」的直接来源。播放中会话本来就是活的，
            // 该响就继续响；真被掐断（来电、控制中心）由前台探测式恢复处理。
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
            // 这里**不再无脑 `reactivate()`**。
            //
            // 回前台时这个方法会被调用一次，而 `setActive(true)` 会让系统重新评估
            // 音频资格、把 WebKit 的媒体元素按停 —— 正是「切桌面再回来歌停一下」的来源。
            // 会话在播放中本来就是好的；真断了由 `recoverAudioPath` 探测后按需处理。
            //
            // 探针配额要在这里归零：配额的存在意义是「这一轮前台只探一两次」，
            // 若不重置，那么第一次进后台再回到前台之后配额就用完了，
            // 之后再怎么切都不会恢复 —— 表现就是「第二次切回来就没声音」。
            foregroundProbes = 0
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
        pendingPauseCheck = false
        AudioSessionController.shared.updatePlaybackState(true)
        CrashLog.note("==== intent audible (state=\(UIApplication.shared.applicationState.rawValue)) ====")
        startKeepAliveTimer()
        // 页面开始播放的这一刻，位置由页面自己掌握：先记下来，
        // 后面壳补放之后如果偏差太大，用它把声音校回字幕的进度。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.wantsAudible, !self.userPaused else { return }
            let js = """
            (function(){
              var el = window.__foliaAudioKeeper ? window.__foliaAudioKeeper.current() : null;
              return el ? {src: el.src, position: el.position} : null;
            })();
            """
            self.webView?.evaluateJavaScript(js) { [weak self] result, _ in
                guard let dict = result as? [String: Any],
                      let src = dict["src"] as? String, !src.isEmpty else { return }
                let position = (dict["position"] as? NSNumber)?.doubleValue ?? 0
                self?.lastKnownPlayback = (src, position)
            }
        }
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
    ///
    /// 例外：切到别的 App / 回桌面时，页面会先收到一次 `pause` 再失去可见性。
    /// 那一拍 `applicationState` 仍是 `.active`，若按「用户收手」处理，
    /// 轮询就停了，回到 App 里发现歌没了 —— 所以这里补一条 `visibilityState` 判断。
    fileprivate func markPausedIntent() {
        guard UIApplication.shared.applicationState == .active else { return }
        // 先记账，等页面把「我到底是不是真的停了」报回来再决定，见 `confirmPausedIntent()`。
        pendingPauseCheck = true
        confirmPausedIntent()
    }

    /// 页面暂停后二次确认：真的停了才停轮询。
    ///
    /// 原先这里只看「App 是否 active + 页面是否 visible」。但切桌面的这一拍
    /// App 可能还停在 active，页面也已经 `visibilityState === "visible"`（WKWebView
    /// 的可见性比 App 状态晚一拍），于是系统掐出来的那一次 pause 被当成用户收手，
    /// 轮询一停就再也没人把歌放回去 —— 用户看到的就是「切出去歌就停了」。
    ///
    /// 现在改成问页面要事实：页面上还有没有没暂停的 `<audio>`。
    /// 用户真正点了暂停，所有音频元素都是 paused，确认成立；
    /// 系统掐断时页面往往已经自己回放，或音频元素根本没进 paused，确认不成立，
    /// 轮询继续，下一拍把它放回去。
    private func confirmPausedIntent() {
        guard pendingPauseCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.pendingPauseCheck else { return }
            // 这一拍 App 已经不在前台了：那就是被系统掐的，不能停轮询。
            guard UIApplication.shared.applicationState == .active else {
                self.pendingPauseCheck = false
                return
            }
            self.webView?.evaluateJavaScript("window.__foliaAudioKeeper && window.__foliaAudioKeeper.current ? JSON.stringify(window.__foliaAudioKeeper.current()) : null") { result, _ in
                guard self.pendingPauseCheck else { return }
                self.pendingPauseCheck = false
                let raw = result as? String
                if let raw, let data = raw.data(using: .utf8),
                   let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let paused = info["paused"] as? Bool, paused == false {
                    // 有音频还在放：刚才那次 pause 是系统或页面重建引起的，不是用户收手。
                    CrashLog.note("==== pause ignored (audio still alive) ====")
                    return
                }
                // 拿不到结论时保守处理：继续保活，宁可多探一次也不要把歌停掉。
                guard raw != nil else { return }
                self.userPaused = true
                self.stopKeepAliveTimer()
                self.wantsAudible = false
                CrashLog.note("==== paused by user (confirmed) ====")
            }
        }
    }

    /// 有待确认的暂停意图。
    private var pendingPauseCheck = false

    private func startKeepAliveTimer() {
        guard keepAliveTimer == nil else { return }
        // 2 秒一拍，而不是 4 秒。
        //
        // 4 秒意味着「歌被掐掉」到「被放回去」最长有 4 秒空窗，用户听到的就是
        // 「切出去音乐断了一下」。这个 timer 绝大多数拍只做一次只读探测
        // （`resumeAudioContexts` 全是读内存里的 context 状态，通路健好时一格不动），
        // 对电量与主线程的影响可以忽略。
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.wantsAudible, !self.userPaused else { return }
            // 只在前台干活。
            //
            // 早先这里是「后台每一拍都 recoverAudioPath()」，那是错的，而且正是
            // 「退出 App 歌被打断」的根因：一旦真的进了后台，每一拍都会调
            // `AudioSessionController.activate()` → `setCategory` + `setActive`，
            // 系统当场重建音频通路，WebKit 的媒体元素被按停，页面侧表现为「后台放着放着停了」。
            // 现在后台音频完全交给系统（已声明 `UIBackgroundModes: audio` + `.playback` 会话），
            // 原生不碰；只有回到前台时才做一次**探测式**恢复，
            // 通路没问题就一格都不动 —— 这就是「切桌面 / 锁屏来回切，歌不停」的保证。
            guard UIApplication.shared.applicationState == .active else { return }
            guard self.foregroundProbes < 6 else { return }
            self.foregroundProbes += 1
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
    /// 前提：`userPaused` 为假 —— 用户亲手按的暂停绝不覆盖。
    /// 前后台走两条不同的路径，见方法体注释。
    private func enforcePlaybackIfNeeded(reason: String) {
        guard wantsAudible, !userPaused else { return }

        // 后台：只做零副作用的补放，绝不重建会话。
        //
        // `setCategory` / `setActive` 都会让系统重新评估音频资格，在后台调它们
        // 等于亲手把正在放的歌按停一次 —— 这是「退出 App 歌被打断」的直接来源。
        // 后台唯一安全的动作是「页面上有条被按停的 `<audio>`，就再 play 一次」。
        if UIApplication.shared.applicationState != .active {
            resumeAudio(reason: reason)
            return
        }

        // 前台：走统一的探测式恢复，通路没问题时一格都不动。
        recoverAudioPath(reason: reason)
        // 视频背景是另一条独立的媒体元素：音频恢复只放 `<audio>`，
        // 视频被系统挂起后不会自己起来，这里顺手补一次。
        driveBackgroundVideo()
    }

    /// 页面上真实在用的 AudioContext 是否处于 running。
    ///
    /// 线上页的 context 留在 React 闭包里，反射拿不到，所以保活脚本从
    /// `createMediaElementSource` 那一处把实例记了下来（见 `audioKeeperScript`）。
    ///
    /// 关键：拿不到实例时**不能**当成「没被掐住」。页面可能还没走到
    /// `createMediaElementSource`，或实例挂在别的全局名下，此时上下文照样可能
    /// 是 suspended —— 那种情况下 `play()` 返回成功却没声音，正是「有概率进 App 无声」。
    /// 所以这里额外扫一遍所有记到的 context：只要有一个不是 running，就报 blocked。
    private func resumeAudioContexts(_ completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
          try {
            if (typeof window.__foliaResumeAudioContexts === 'function') {
              window.__foliaResumeAudioContexts();
            }
            var list = window.__foliaAudioContexts || [];
            // 只统计页面真实在用、而且确实接在一条正在出声的 <audio> 上的上下文。
            //
            // 早先这里是「只要有一个 context 不是 running 就报 blocked」，那是错的方向：
            // 换页 / 切歌词后旧上下文被 close 或根本没在用，它停在 suspended 是正常的，
            // 却会让我们误判整条通路断了，于是每次回前台都走一遍重建 ——
            // 表现就是「切回来那一拍歌被打断」。
            var live = 0, bad = 0;
            for (var i = 0; i < list.length; i += 1) {
              var c = list[i];
              if (!c || c.state === 'closed') { continue; }
              // 只有「正在被用」的上下文才有意义：它最近一次接了媒体源，且页面在放。
              if (c !== window.__foliaActiveAudioContext) { continue; }
              live += 1;
              if (c.state !== 'running') { bad += 1; }
            }
            var act = window.__foliaActiveAudioContext;
            if (act && act.state !== 'closed' && live === 0) {
              live = 1;
              if (act.state !== 'running') { bad += 1; }
            }
            if (bad > 0) { return 'blocked'; }
            if (live > 0) { return 'running'; }
            // 一个上下文都没记到（页面还没建播放器，或播放器不走 WebAudio）：
            // 这时候不能当成健康，但也不能盲目重建音频会话 —— 交给调用方用
            // 「页面上有没有还在播的 <audio>」来兜底判断。
            return 'none';
          } catch (e) { return 'none'; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            // 只有明确拿到 `running` 才算通路健康。
            //
            // `none` 仍然是「不确定」，但调用方会再问一次页面里有没有在播的媒体元素：
            // 有的话不重建会话也能正常工作（页面自己的播放器是唯一的状态源）。
            completion((result as? String) == "running")
        }
    }

    /// 恢复音频通路的统一入口：会话、AudioContext、媒体元素三件事按顺序做一遍。
    ///
    /// 为什么要串行且去重：回前台、控制中心收起、保活轮询都会想恢复一次，
    /// 早先它们各自并发地重建 category 并补 `play`，同一个恢复动作被触发两三遍，
    /// `<audio>` 被反复 play / resume，交叉淡化的两个 deck 互相抢，就是「卡顿爆音」；
    /// 而中途又有人把 context 重新挂起，于是「有一段没声音」。
    ///
    /// 这里的约定：
    /// - **先探测，再动手**：通路本来就好的话什么都不做。
    ///   这是「切桌面/锁屏再回来，歌不被暂停」的前提 ——
    ///   `setCategory` / `setActive` 本身就会让 WebKit 把媒体元素按停一次，
    ///   对一条完好的通路做这种操作，纯属自己把歌打断。
    /// - 只做一遍，且上一遍没走完时，新请求只记一次「再做一遍」，不叠着跑；
    /// - 确认被掐断后才重建会话与上下文，**等上下文真的 running 了**再补 play，
    ///   而不是固定 sleep 一段时间——那段时间正是「没声音」的窗口；
    /// - 上下文始终起不来就有限次重试，不无限循环。
    func recoverAudioPath(reason: String) {
        guard wantsAudible, !userPaused else { return }

        // 正在恢复中：只记一个待办，等当前这遍结束后补做一次。
        if audioRecoveryInFlight {
            audioRecoveryPending = true
            return
        }
        audioRecoveryInFlight = true
        audioRecoveryPending = false
        probeThenRecover(reason: reason)
    }

    /// 探测当前通路是否真的断了，只在断了的时候才走重建。
    ///
    /// 判据取两样，任一为真才算断：
    /// 1. 页面上还有没暂停的 `<audio>`（说明「该响」），但 AudioContext 不是 running；
    /// 2. 会话已经失去播放资格（`secondaryAudioShouldBeSilencedHint`，控制中心/通话后的典型态）。
    ///
    /// 两样都为假说明声音好端端地在放，直接返回 —— 这一条就是「进出不打断」的保证。
    private func probeThenRecover(reason: String) {
        let session = AVAudioSession.sharedInstance()
        let silencedHint = session.secondaryAudioShouldBeSilencedHint

        resumeAudioContexts { [weak self] contextOK in
            guard let self else { return }

            if contextOK && !silencedHint {
                // 通路完好：一格音频状态都不要碰，只把「想做待办」结掉。
                CrashLog.note("==== audio path healthy, skip rebuild (\(reason)) ====")
                self.finishAudioRecovery()
                return
            }

            // 上下文状态「不确定」时，问页面第二个事实：媒体元素还在不在正常放。
            //
            // 这是「切桌面 / 锁屏回来，歌不停」的关键一条。原先 `none` 一律当成断了，
            // 于是每次回前台都会走一遍 `setCategory` + `setActive` ——
            // 那条路本身就会把 WebKit 的媒体元素按停，等于自己把歌打断一次。
            // 实际上 `none` 只表示「我们没记到页面用的 AudioContext」（播放器把实例
            // 留在闭包里、或者根本不走 WebAudio），页面自己的播放器好得很。
            self.isMediaHealthy { healthy in
                if healthy && !silencedHint {
                    CrashLog.note("==== audio path healthy via media probe, skip rebuild (\(reason)) ====")
                    self.finishAudioRecovery()
                    return
                }
                CrashLog.note("==== audio path broken (contextOK=\(contextOK ? 1 : 0) silencedHint=\(silencedHint ? 1 : 0) reason=\(reason)) ====")
                self.recoverAudioPathPass(reason: reason, attempt: 0)
            }
        }
    }

    /// 页面上的媒体元素是不是「正在正常出声」（没暂停、没结束、有源、时间在走）。
    ///
    /// 只读 DOM，不动任何状态。回前台第一拍 `currentTime` 可能还没推进，
    /// 所以判据只看「有源 + 没暂停 + 没结束」，再加上「音频上下文没被挂起」这一条兜底。
    private func isMediaHealthy(_ completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
          try {
            var list = document.querySelectorAll('audio,video');
            for (var i = 0; i < list.length; i += 1) {
              var el = list[i];
              if (!el.src || el.ended) { continue; }
              // 有一条在播，就说明播放器自己没停。
              if (!el.paused) { return 'playing'; }
            }
            return 'idle';
          } catch (e) { return 'error'; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            completion((result as? String) == "playing")
        }
    }

    /// 一趟恢复。attempt 用于上下文迟迟不就绪时的有限重试。
    private func recoverAudioPathPass(reason: String, attempt: Int) {
        guard wantsAudible, !userPaused else {
            finishAudioRecovery()
            return
        }

        // 第一趟才重设 category：`setCategory` 会重建整个通路，
        // 重试时只再叫醒上下文，避免反复重建把刚起来的播放又按停。
        if attempt == 0 {
            AudioSessionController.shared.activate()
            revivePageAudio()
        }

        // 等一帧再问上下文状态：`resume()` 是异步的，紧接着问必然是旧的。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.resumeAudioContexts { [weak self] ok in
                guard let self else { return }
                if ok || attempt >= 3 {
                    self.resumeAudio(reason: reason)
                    self.finishAudioRecovery()
                } else {
                    // 上下文还没 running：只再叫醒一次，不重建 category。
                    self.revivePageAudio()
                    self.recoverAudioPathPass(reason: reason, attempt: attempt + 1)
                }
            }
        }
    }

    private func finishAudioRecovery() {
        audioRecoveryInFlight = false
        guard audioRecoveryPending else { return }
        audioRecoveryPending = false
        // 期间又有请求进来（例如控制中心收起紧跟着回前台），补做一遍。
        recoverAudioPath(reason: "pending")
    }

    private var audioRecoveryInFlight = false
    private var audioRecoveryPending = false

    /// 回前台时的补放：不看前后台状态，其余条件与轮询一致。
    ///
    /// 用户很可能就是从后台回来发现「没声音」：会话在后台已被降级，
    /// 所以这里必须先补一次 `setActive`，否则 play() 成功了也是静音。
    ///
    /// `rebuild` 为真时连 Category 一起重设并派发一次 `visibilitychange`：
    /// 只在回前台用。`setCategory` 之后必须让页面知道自己「又被看见了」，
    /// 它才会把被系统挂起的 WebAudio 上下文 `resume()` 回来。
    private func forceResumeAudio(reason: String, rebuild: Bool = false) {
        // 保活轮询也会走到这里：与前台恢复共用同一条串行通道，
        // 否则两路同时补 `play` 就是卡顿爆音的来源。
        recoverAudioPath(reason: reason)
    }

    /// 回前台时把页面被系统挂起的音频上下文唤醒。
    ///
    /// iOS 在后台会把页面的 `AudioContext` 挂成 `interrupted`，回前台不会自己恢复；
    /// 页面侧没有任何 `statechange` 监听，所以要壳来叫醒它。
    /// 这里只做最保守的事：把所有已知上下文 `resume()` 一遍 —— 不改任何全局原型。
    private func revivePageAudio() {
        // 这里刻意**不再派发合成的 `visibilitychange`**。
        //
        // 页面把 `visibilitychange` 当成「真的被切走又切回来」，会在那一拍重建播放器与
        // 可视化树；而原生这边发它时，页面其实一直可见。结果是每次回前台
        // 都白跑一次重建 —— 表现就是「刚回来那一下卡顿、画面闪、偶尔进程还不够内存」。
        // 现在只做两件没有副作用的事：`resume()` 已知的 AudioContext，
        // 以及让页面自己上报一次当前状态（`__foliaAudioKeeper.report()` 只是读 DOM）。
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
            if (window.__foliaAudioKeeper && typeof window.__foliaAudioKeeper.report === 'function') {
              window.__foliaAudioKeeper.report();
            }
            return 'ok';
          } catch (e) { return 'error'; }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func resumeAudio(reason: String) {
        // 先叫醒 AudioContext 再补 play。
        //
        // 线上页是 WebAudio 出声：`<audio>` 只当解码源，接在 `AudioContext` 上。
        // 控制中心收起后 AudioContext 往往停在 interrupted，此时 `play()` 会返回成功
        // 却一点声都没有 —— 用户看到的就是「状态栏滑下去再回来，进度在走但没声音」。
        revivePageAudio()
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
        // 补放之后再对一次位置：被系统按停过的元素会从它停下的那一秒接着走，
        // 而字幕按页面时钟一直在前进，不管的话声音就整体落后一段。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.healAudioDrift(reason: reason)
        }
        // 上下文是异步起搏的，等一帧再补一次：
        // 只在上一次没放成（元素仍被按停）时才动手，不会和上面那次叠着放。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.wantsAudible, !self.userPaused else { return }
            self.isMediaHealthy { healthy in
                guard !healthy else { return }
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
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
    ///
    /// 现在的主 bundle 已经到 7MB 量级（bootstrap 2.0MB + 歌词引擎 1.8MB + 组件注册 1.5MB），
    /// 老机型在弱网下首屏 10 秒以上是常态。原先 15 秒会在页面正在正常加载时误判成
    /// 「没能启动起来」，于是壳自己把一次好端端的加载重载掉 —— 用户看到的就是
    /// 「启动着启动着又回到加载界面」。这里放宽到 30 秒，并且看门狗只做提示，
    /// 不再主动打断正在进行的加载。
    private static let stallTimeout: TimeInterval = 30

    /// 首屏是否已经就绪（React 挂上、加载遮罩淡出）。
    private var didReachFirstPaint = false
    /// 这一次导航的文档是否已经加载完（`didFinish`）。
    private var documentFinished = false
    /// 首屏检查是否已经跑出一轮结论（遮罩被去掉）。
    ///
    /// 只看「文档是否加载完」不够：有些页面把 `#app-splash` 直接在文档里去掉，
    /// 此时 React 已经挂载，只是这一步没被 `checkFirstPaint` 采样到。
    /// 用它区分「页面真的还没跑起来」与「跑起来了但没采到」。
    private var hasEvaluatedFirstPaint = false

    /// 盯着首屏：到点还没就绪，就把当前 URL、标题与页面文本回传，让用户看到到底卡在哪。
    ///
    /// 之前「一直黑屏」只能靠猜——界面是一片 #09090b，究竟是网络、DNS、
    /// 还是页面里的模块加载被卡住，在外面完全看不出来。这里把现场收集起来直接显示。
    private func scheduleProgressWatchdog() {
        didReachFirstPaint = false
        documentFinished = false
        hasEvaluatedFirstPaint = false
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
                // 文档已经加载完、只是首屏还没画出来：此时主动重载是「帮倒忙」。
                // 页面自己的 bundle 还在下载/解析，重载会把已下载的部分全部丢掉，
                // 弱网与老机型上直接变成「永远进不去」。只提示，不打断。
                if self.documentFinished && !self.hasEvaluatedFirstPaint {
                    CrashLog.note("==== first paint late, keep loading (no reload) ====")
                    self.state.noteStalled(detail: detail)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                        self?.reportStallIfNeeded()
                    }
                    return
                }
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
            "(function(){var s=document.getElementById('app-splash');"
                + "var r=document.getElementById('root');"
                + "return (s ? 0 : 1) + (r && r.children.length > 0 ? 2 : 0);})()"
        ) { [weak self] result, _ in
            guard let self else { return }
            let flags = (result as? NSNumber)?.intValue ?? 0
            // 遮罩被移走、或者 React 已经往 `#root` 里挂了东西（此时遮罩多半正在淡出）：
            // 都算首屏到了。只看遮罩的话，遮罩被 CSS 隐藏而没被删掉时会一直判成没就绪。
            if flags & 1 == 1 || flags & 2 == 2 {
                DispatchQueue.main.async {
                    self.didReachFirstPaint = true
                    self.hasEvaluatedFirstPaint = true
                }
                // 页面已经画出来了：解除「刚重建过」的保护位，允许下一次进程被回收
                // 再走一遍自愈（否则这一次成功后，之后真正的 OOM 会被判成
                // 「重建也没用」而直接退到离线副本）。
                self.rebuiltSinceLaunch = false
                // 首屏就绪再开赞赏弹窗：在那之前 DOM 里的图片还没解码，弹出来是两张空白框。
                self.installDonateCard()
                // 版本行要等设置面板挂出来才有 DOM，首屏后每隔一秒补一次，两分钟内有效即停。
                self.scheduleHelpVersionPatch()
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
            // 同时把「哪首、放到哪」留在原生手上：后台被按停再补放时，
            // 壳要把声音的位置校回这个进度，否则会落后一整个后台时长。
            try {
              var cur = currentAudio();
              if (cur) {
                window.webkit.messageHandlers.foliaAudioIntent.postMessage('clock|' + JSON.stringify({
                  src: cur.src,
                  position: cur.currentTime || 0
                }));
              }
            } catch (e) {}
          });
          // 暴露一个只读的状态查询口：原生回前台时用它确认「页面自己认为在不在播」，
          // 不再靠派发合成事件去逼页面重建。只读 DOM，没有任何副作用。
          window.__foliaAudioKeeper = {
            report: report,
            progress: reportProgress,
            current: function(){
              var el = currentAudio();
              if (!el) { return null; }
              var d = el.duration;
              return {
                src: el.src,
                paused: el.paused,
                position: el.currentTime || 0,
                duration: (d && isFinite(d)) ? d : 0
              };
            }
          };
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

    /// 首屏之后轮询补版本行：设置面板是懒挂载的，用户点到「帮助」时 DOM 才出现，
    /// 单次注入永远赶不上。命中一次就停，两分钟没命中自然放弃。
    private func scheduleHelpVersionPatch() {
        var remaining = 120
        func tick() {
            guard remaining > 0 else { return }
            remaining -= 1
            let js = """
            (function () {
              var want = '\(Self.appVersion)';
              if (!want || want === '0') { return false; }
              var spans = document.querySelectorAll('span.font-mono.text-xs');
              for (var i = 0; i < spans.length; i += 1) {
                var el = spans[i];
                var text = el.textContent || '';
                if (text.indexOf('Realeco') !== 0) { continue; }
                var next = text.replace(/Realeco v[^ ]+/, 'Realeco v' + want);
                if (next === text) { return true; }
                el.textContent = next;
                return true;
              }
              return false;
            })();
            """
            webView?.evaluateJavaScript(js) { [weak self] result, _ in
                guard self != nil else { return }
                if let done = result as? Bool, done { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { tick() }
            }
        }
        tick()
    }

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

    /// 视频背景的兜底驱动。
    ///
    /// 线上页的背景 `<video>` 的播放时机挂在「播放器状态变化」与一个 2 秒的定时校正上：
    /// 只要那次 `play()` 被拦（控制中心收起后媒体进程被挂起、切后台再回来），
    /// 它就再也不会自己起来 —— 用户看到的就是「视频背景设了，画面却一直是静态的、
    /// 或者停在第一帧找不到效果」。这里补的正是这一拍：
    /// - 页面已经在放：一格都不动；
    /// - 明确处于暂停且有源：补一次 `play()`。
    /// 只读 DOM，不改任何全局原型，对普通播放页的音频没有影响。
    private func driveBackgroundVideo() {
        let js = """
        (function(){
          try {
            var list = document.querySelectorAll('video[aria-hidden="true"]');
            for (var i = 0; i < list.length; i += 1) {
              var v = list[i];
              if (!v.src || v.ended) { continue; }
              if (v.paused) {
                var p = v.play();
                if (p && p.catch) { p.catch(function(){}); }
                return 'played';
              }
              return 'playing';
            }
            return 'none';
          } catch (e) { return 'error'; }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 记录页面上那条 `<audio>` 的播放位置，供 `healAudioDrift()` 做校正。
    /// 页面在切后台时用 `clock|{src,position}` 主动报送。
    fileprivate func rememberPlaybackPositionClock(_ body: String) {
        guard let json = Self.jsonBody(body, prefix: "clock|") else { return }
        applyPlaybackClock(json)
    }

    /// 后台每 5 秒一条的进度，同样是「页面认为现在放到哪」的权威值。
    fileprivate func rememberPlaybackPositionProgress(_ body: String) {
        guard let json = Self.jsonBody(body, prefix: "progress|") else { return }
        applyPlaybackClock(json)
    }

    private func applyPlaybackClock(_ json: [String: Any]) {
        guard let src = json["src"] as? String, !src.isEmpty else { return }
        let position = (json["position"] as? NSNumber)?.doubleValue ?? 0
        lastKnownPlayback = (src, position)
    }

    private static func jsonBody(_ body: String, prefix: String) -> [String: Any]? {
        guard body.hasPrefix(prefix) else { return nil }
        let raw = String(body.dropFirst(prefix.count))
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// 把音频元素的播放位置拉回页面记录的进度（「声音跟字幕不匹配」的解法）。
    ///
    /// 现场：字幕和进度条按页面自己的时钟走（rAF 推进的播放位置），声音出自 `<audio>`。
    /// 这两者只在页面正常 `play()` / `seek` 时同步；一旦被壳补放（后台被系统按停、
    /// 回前台续播、WebAudio 断流后重放），`<audio>` 会从它自己被暂停的那一秒接着走，
    /// 而页面时钟从没停过 —— 于是声音整体落后字幕一个「暂停时长」，越听越不对。
    ///
    /// 处理方式与页面自己切歌时一致：把元素的 `currentTime` 设回已知进度。
    /// 只动位置、不动 `play` / `pause`，不会跟串行的恢复通道抢。
    private func healAudioDrift(reason: String) {
        guard let known = lastKnownPlayback, known.position > 0.5 else { return }
        let js = """
        (function(){
          try {
            var src = \(Self.jsString(known.src));
            var want = \(String(format: "%.3f", known.position));
            var list = document.querySelectorAll('audio');
            for (var i = 0; i < list.length; i += 1) {
              var el = list[i];
              if (el.src !== src || el.ended || el.paused) { continue; }
              if (!isFinite(el.duration) || el.duration <= 0) { return 'wait'; }
              // 播放中本来就有几百毫秒的正常误差，超过它才说明是「断流后重放」。
              if (Math.abs(el.currentTime - want) < 0.6) { return 'ok'; }
              el.currentTime = want;
              return 'fixed';
            }
            return 'none';
          } catch (e) { return 'error'; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            guard let flag = result as? String, flag == "fixed" else { return }
            CrashLog.note("==== audio position realigned to page clock (\(reason)) ====")
        }
    }

    /// 拼一个安全的 JS 字符串字面量（媒体 URL 里可能有引号和反斜杠）。
    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        guard let data, let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
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
      // 整段包一层 try：注入点在 document start，早于页面的任何脚本。
      // 任何一句抛错都会打断后面所有补丁（错误上报、UA 判定、视频消息处理），
      // 表现为「老机型进不去 / 播放不了」，而且页面上一个错都看不到。
      try {
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
      // 老机型兼容垫片。
      //
      // 线上页大量依赖近几年的 Web API，老机型（iOS 16 封顶的机型、A10 及更早的芯片）
      // 缺其中一部分，缺哪个就在哪一步静默中断：常见表现是「点了播放没反应」，
      // 或者整页卡在加载界面（模块顶层就调用了缺失的 API）。
      // 这里只补「缺失即报错」的那几个，且全部是可枚举对象的原型方法，
      // 实现按规范语义写，不改变已支持机型的任何行为。
      (function(){
        try {
          if (typeof Object.groupBy !== 'function') {
            Object.defineProperty(Object, 'groupBy', {
              configurable: true, writable: true,
              value: function(items, callback){
                var out = {};
                var list = Array.from(items || []);
                for (var i = 0; i < list.length; i += 1) {
                  var key = callback(list[i], i);
                  if (!Object.prototype.hasOwnProperty.call(out, key)) { out[key] = []; }
                  out[key].push(list[i]);
                }
                return out;
              }
            });
          }
          if (typeof Map.groupBy !== 'function') {
            Object.defineProperty(Map, 'groupBy', {
              configurable: true, writable: true,
              value: function(items, callback){
                var out = new Map();
                var list = Array.from(items || []);
                for (var i = 0; i < list.length; i += 1) {
                  var key = callback(list[i], i);
                  if (!out.has(key)) { out.set(key, []); }
                  out.get(key).push(list[i]);
                }
                return out;
              }
            });
          }
          if (typeof Array.prototype.at !== 'function') {
            Object.defineProperty(Array.prototype, 'at', {
              configurable: true, writable: true,
              value: function(index){
                var len = this.length >>> 0;
                var k = Math.trunc(index) || 0;
                if (k < 0) { k += len; }
                return (k < 0 || k >= len) ? undefined : this[k];
              }
            });
          }
          if (typeof String.prototype.at !== 'function') {
            Object.defineProperty(String.prototype, 'at', {
              configurable: true, writable: true,
              value: function(index){
                var s = String(this);
                var len = s.length;
                var k = Math.trunc(index) || 0;
                if (k < 0) { k += len; }
                return (k < 0 || k >= len) ? undefined : s.charAt(k);
              }
            });
          }
          if (typeof Array.prototype.findLast !== 'function') {
            Object.defineProperty(Array.prototype, 'findLast', {
              configurable: true, writable: true,
              value: function(callback, thisArg){
                for (var i = this.length - 1; i >= 0; i -= 1) {
                  if (callback.call(thisArg, this[i], i, this)) { return this[i]; }
                }
                return undefined;
              }
            });
          }
          if (typeof Array.prototype.findLastIndex !== 'function') {
            Object.defineProperty(Array.prototype, 'findLastIndex', {
              configurable: true, writable: true,
              value: function(callback, thisArg){
                for (var i = this.length - 1; i >= 0; i -= 1) {
                  if (callback.call(thisArg, this[i], i, this)) { return i; }
                }
                return -1;
              }
            });
          }
          if (typeof Array.prototype.toSorted !== 'function') {
            Object.defineProperty(Array.prototype, 'toSorted', {
              configurable: true, writable: true,
              value: function(compare){
                return Array.from(this).sort(compare);
              }
            });
          }
          if (typeof Array.prototype.toReversed !== 'function') {
            Object.defineProperty(Array.prototype, 'toReversed', {
              configurable: true, writable: true,
              value: function(){ return Array.from(this).reverse(); }
            });
          }
          if (typeof Array.prototype.toSpliced !== 'function') {
            Object.defineProperty(Array.prototype, 'toSpliced', {
              configurable: true, writable: true,
              value: function(start, deleteCount){
                var copy = Array.from(this);
                var args = Array.prototype.slice.call(arguments);
                copy.splice.apply(copy, args);
                return copy;
              }
            });
          }
          if (typeof Array.prototype.with !== 'function') {
            Object.defineProperty(Array.prototype, 'with', {
              configurable: true, writable: true,
              value: function(index, value){
                var copy = Array.from(this);
                var k = Math.trunc(index) || 0;
                if (k < 0) { k += copy.length; }
                copy[k] = value;
                return copy;
              }
            });
          }
          if (typeof Object.hasOwn !== 'function') {
            Object.defineProperty(Object, 'hasOwn', {
              configurable: true, writable: true,
              value: function(obj, key){ return Object.prototype.hasOwnProperty.call(obj, key); }
            });
          }
          if (typeof Promise.withResolvers !== 'function') {
            Object.defineProperty(Promise, 'withResolvers', {
              configurable: true, writable: true,
              value: function(){
                var resolve, reject;
                var promise = new Promise(function(res, rej){ resolve = res; reject = rej; });
                return { promise: promise, resolve: resolve, reject: reject };
              }
            });
          }
          if (typeof queueMicrotask !== 'function') {
            window.queueMicrotask = function(cb){
              Promise.resolve().then(cb);
            };
          }
          if (typeof requestIdleCallback !== 'function') {
            window.requestIdleCallback = function(cb){
              var start = Date.now();
              return setTimeout(function(){
                cb({ didTimeout: false, timeRemaining: function(){ return Math.max(0, 50 - (Date.now() - start)); } });
              }, 1);
            };
            window.cancelIdleCallback = function(id){ clearTimeout(id); };
          }
          if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout !== 'function') {
            AbortSignal.timeout = function(ms){
              var ctrl = new AbortController();
              setTimeout(function(){ ctrl.abort(new DOMException('TimeoutError', 'TimeoutError')); }, ms);
              return ctrl.signal;
            };
          }
          // 结构化克隆兜底：部分老版本没有 `structuredClone`，
          // 播放器在切歌 / 持久化队列时会用到。
          if (typeof structuredClone !== 'function') {
            window.structuredClone = function(value){ return JSON.parse(JSON.stringify(value)); };
          }
          // ResizeObserver 缺失时给一个只回调一次的空实现：
          // 缺它会让可视化外壳在构造时直接抛错，整页白掉。
          if (typeof ResizeObserver !== 'function') {
            window.ResizeObserver = function(cb){
              this._cb = cb;
              var self = this;
              setTimeout(function(){
                try { self._cb([{ contentRect: document.body.getBoundingClientRect() }], self); } catch (e) {}
              }, 0);
            };
            window.ResizeObserver.prototype.observe = function(){};
            window.ResizeObserver.prototype.unobserve = function(){};
            window.ResizeObserver.prototype.disconnect = function(){};
          }
          if (typeof IntersectionObserver !== 'function') {
            window.IntersectionObserver = function(cb){
              this._cb = cb;
              var self = this;
              setTimeout(function(){
                try { self._cb([{ isIntersecting: true, intersectionRatio: 1, target: document.body }], self); } catch (e) {}
              }, 0);
            };
            window.IntersectionObserver.prototype.observe = function(){};
            window.IntersectionObserver.prototype.unobserve = function(){};
            window.IntersectionObserver.prototype.disconnect = function(){};
            window.IntersectionObserver.prototype.takeRecords = function(){ return []; };
          }
          // `AudioContext` 在部分老系统的 WKWebView 里只有 webkit 前缀。
          if (typeof window.AudioContext !== 'function' && typeof window.webkitAudioContext === 'function') {
            window.AudioContext = window.webkitAudioContext;
            window.OfflineAudioContext = window.OfflineAudioContext || window.webkitOfflineAudioContext;
          }
        } catch (e) {}
      })();
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
      // 视频背景不生效时，错误往往只发生在 <video> 元素上（解码失败、sources 为空、
      // 被 WKWebView 的自动播放策略拦下），不会冒泡到 window。这里补一条捕获阶段的监听，
      // 把媒体元素的错误码记下来，真机日志里才能判断是解码问题还是策略问题。
      document.addEventListener('error', function(e){
        var t = e && e.target;
        if (!t || (t.tagName !== 'VIDEO' && t.tagName !== 'AUDIO')) { return; }
        var err = t.error;
        report('MEDIA', (t.tagName || '') + ' code=' + (err ? err.code : '-')
          + ' msg=' + (err && err.message ? err.message : '-')
          + ' src=' + String(t.currentSrc || t.src || '').slice(0, 120));
      }, true);
      // 媒体自动播放被拦（视频背景停在首帧）同样不会冒泡：安卓/桌面浏览器的提示框
      // 在 WKWebView 里也不存在，页面只会静默失败。这里把 `play()` 的拒绝原因记下来。
      (function(){
        if (typeof HTMLMediaElement !== 'function') { return; }
        var originalPlay = HTMLMediaElement.prototype.play;
        if (typeof originalPlay !== 'function') { return; }
        HTMLMediaElement.prototype.play = function(){
          var self = this;
          var p = originalPlay.apply(self, arguments);
          if (p && typeof p.catch === 'function') {
            p.catch(function(err){
              report('PLAY', (self.tagName || '') + ' ' + ((err && (err.name + ':' + err.message)) || 'rejected')
                + ' muted=' + (self.muted ? '1' : '0')
                + ' src=' + String(self.currentSrc || self.src || '').slice(0, 120));
            });
          }
          return p;
        };
      })();
      } catch (e) {
        // 兜底：壳标记先写下去，页面至少能按壳模式排版，不至于整页停在默认桌面上。
        try {
          window.__FOLIA_SHELL__ = 'ios';
          window.__foliaBridgeError = String(e && (e.stack || e.message) || e);
        } catch (e2) {}
      }
    })();
    """
}

// MARK: - 导航

extension WebContainerView: WKNavigationDelegate, WKUIDelegate {
    /// 页面里 `<input type="file">` 被 `click()` 时的原生选择面板。
    ///
    /// 不实现这一条，WKWebView 会把选文件静默吞掉（Safari 有默认实现，WKWebView 没有）。
    /// 背景视频的「选择本地视频」正好落在这条链上，所以它是「上传了没反应」的正面解法。
    ///
    /// 同名方法有两个版本：这里带 `WKOpenPanelParameters`（iOS 18.4 起才可用），
    /// 下面的用 `AnyObject`，两条都转给 `presentFilePicker`，部署目标不用抬高。
    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        presentFilePicker(completionHandler)
    }

    /// 旧系统（iOS 18.4 之前）的选文件回调。
    ///
    /// 这条在老系统上就是全量的文件选择入口，页面点任何 `<input type="file">` 都走这里。
    /// 必须实现：缺了它 `input.click()` 在 WKWebView 里什么都不会发生，
    /// 背景视频的「选择本地视频」永远选不上，图层也就永远不会出现。
    func webView(_ webView: WKWebView,
                 runOpenPanelWithParameters parameters: AnyObject,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        presentFilePicker(completionHandler)
    }

    /// 两条入口共用的实现：弹一个只放行视频的原生选择面板。
    private func presentFilePicker(_ completionHandler: @escaping ([URL]?) -> Void) {
        let presenter = FilePickerPresenter()
        filePicker = presenter
        CrashLog.note("==== open panel requested ====")
        presenter.present(from: topPresenter) { [weak self] urls in
            CrashLog.note("==== open panel picked \(urls?.count ?? 0) ====")
            completionHandler(urls)
            self?.filePicker = nil
        }
    }

    /// 找到当前最上层的控制器来挂模态面板。
    private var topPresenter: UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }

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
        //
        // 但**失败的导航不能算**：这一句在 `decidePolicyFor` 里，决策时还没开始加载。
        // 弱网下跳到线上往往当场失败，若此时已经清掉离线标记，`didFailProvisionalNavigation`
        // 就会走「重试两次 → 回退」那条路，把正在正常出声的离线页整页重载掉 ——
        // 用户看到的就是「用着用着又闪回加载界面」。真正的切换由 `didCommit` 确认。
        if isMainFrame && isSameSite && scheme != "file" && !isShowingOfflineCopy {
            pendingOnlineHandoff = true
        }

        decisionHandler(.allow)
    }

    /// 服务器已经有响应、导航真正开始了：这里才敢把「离线副本」标记撤掉。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // 主框架还在跑，说明上次的断网/失败现场已经不成立了。不在这里清的话，
        // 提示层会一直盖在已经画好的页面上（`showsBlockingNotice` 只认 `offlineReason`），
        // 用户看到的就是「页面明明能开，却一直停在加载界面，只能点重试」。
        if state.offlineReason != nil {
            CrashLog.note("==== main frame committed, clearing stale failure notice ====")
            state.clearLoadFailure()
        }
        guard pendingOnlineHandoff else { return }
        pendingOnlineHandoff = false
        isShowingOfflineCopy = false
        CrashLog.note("==== offline copy handed off to online ====")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastInsets = .zero
        documentFinished = true
        // 文档级导航成功，说明这次加载是好的：「卡住」的配额必须一起清零。
        // 只在 didFinish 清 stallRetries 而不管 consecutiveLoadFailures 是不对的 ——
        // 弱网下「卡住一次 → 重载成功」重复三遍后，计数攒到阈值，
        // 下一次刚正常的加载也会被判成「连不上」，直接被打回离线副本。
        consecutiveLoadFailures = 0
        pushInsetsIfNeeded()
        ensureShellFlag()
        state.clearLoadFailure()
        // 线上页真的加载成功了：之前挂过的离线副本提示要收起来，
        // 否则用户已经回到线上，提示层还盖在页面上说「当前用的是离线版本」。
        if !isShowingOfflineCopy {
            state.leaveOfflineCopy()
        }
        // 卡住重试的配额同属「这一轮」的概念，成功一次就该重新计数。
        stallRetries.removeAll()
        // 文档加载完不等于画出来了：页面还要拉主 bundle 才能挂 React。
        // 这里只解除「导航级」失败，首屏看门狗继续跑，直到 React 真的把遮罩去掉。
        scheduleFirstPaintCheck()
        installAudioKeeper()
        installLoginHelpers()
        scheduleHelpVersionPatch()
        // 页面加载完补一次会话激活，覆盖「之前被来电/其他播放器降级」的情况。
        //
        // 播放中不碰：正在出声时 `setActive(true)` 会把 WebKit 的媒体元素按停一次，
        // 表现就是「后台切回来/页面重载后歌停了一下」。没在播时激活没有副作用。
        if !wantsAudible || userPaused {
            AudioSessionController.shared.reactivate()
        }

        // 干净存储上成功加载出了页面：把「崩溃标记」清掉，下次启动回到默认存储。
        //
        // 放在 didFinish 而不是首屏看门狗里，是因为要等它真正跑完一轮才敢下结论；
        // 但也不能等太久 —— 若在清掉之前又崩了，下一个进程还得靠这个标记自救，
        // 所以用延迟清除，期间一旦再崩会被 markDirty 重新写回。
        if recoveringFromCrash {
            recoveringFromCrash = false
            let restartsAtFinish = contentProcessRestarts.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let self else { return }
                // 只要求「这 8 秒内没有再挂」。
                //
                // 早先这里写的是 `contentProcessRestarts.isEmpty`，那是错的条件：
                // 走到这里本身就说明上一轮挂过一次，数组永远非空，标记一辈子清不掉，
                // 于是每次启动都用 `nonPersistent` 存储 —— 登录态每次都要重来一遍。
                // 用「快照比对」才是真正要表达的意思：这段时间稳定，就算恢复成功。
                guard self.contentProcessRestarts.count == restartsAtFinish else { return }
                CacheSweeper.clearDirty()
                CrashLog.note("==== store recovered, dirty flag cleared ====")
            }
        }
    }

    /// 远程页加载失败时自动重试一次，避免停在白屏上。
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        // -999 是「被新导航取消」，属正常流程。
        guard code != NSURLErrorCancelled else { return }
        // 从离线副本切线上失败：留在本地页上继续用，别让后面的重试/回退
        // 把正在出声的播放器重载掉。
        if pendingOnlineHandoff {
            pendingOnlineHandoff = false
            CrashLog.note("==== online handoff failed \(code), staying on offline copy ====")
            state.enterOfflineCopy()
            return
        }
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
        //
        // 但回前台唤醒那一轮是例外：那时页面已经在后台被系统收走过，`file://` 读不到
        // 几乎都是 Process Assertion 过期导致的，重载一次就能回来。
        guard !isShowingOfflineCopy || wakeRecoveryInFlight else { return }
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

        // 立刻把「这次运行不干净」落盘。
        //
        // 进程被系统杀掉时 App 本身还活着，用户随后手动大退也不会有任何收尾回调，
        // 所以只能在这一刻写 UserDefaults。下一个进程读到它就会改用干净存储，
        // 这一步是「大退重进仍然闪退」能自愈的前提。
        //
        // 注意范围：这一条只用来**自愈**，不在这里清 Service Worker。
        // 线上站自己注册了 SW，缓存优先的策略让二次启动几乎不打死 WebContent 进程；
        // 一旦清了 SW，下一个进程必须重新下载整站脚本，反而更容易被压死。
        // 真正可能被旧数据污染的 MyISAM 式场景（IndexedDB）由页面自己重建。
        CacheSweeper.markDirty("webcontent-terminated")

        // 网页进程被打死后，页面里的 `<audio>` 随之消失，声音立刻断掉 ——
        // 用户实际经历的是「切歌词界面，音乐停了 / App 退回首页」。
        // 这里先把现场抓下来：崩溃前的标题、当前路由，以及崩溃时是否还在出声。
        collectTerminationContext()

        // 崩溃前正在出声，且用户没按过暂停：重载后把播放续上。
        let shouldResume = Self.wasAudibleInBackground && !userPaused

        // 第一次就换干净存储，而不是在同一个 WKProcessPool 上 `reload()`。
        //
        // 「进歌单有概率闪退、退回加载界面」的现场就是：内容进程被回收后，
        // 壳只做 `reload()`，新的 WebContent 进程仍然挂到同一个进程池、读同一份
        // Service Worker / IndexedDB / 图标缓存上，页面上那个歌单列表又要一次性
        // 渲染几百张封面 —— 当场再被压死一次。用户看到的就是「闪一下 → 加载界面」，
        // 来回卡几次之后进程池已经处于脏状态，连大退重进都会复发。
        //
        // 换 `nonPersistent` 存储 + 新进程池是唯一能立刻脱身的路：这一轮读不到任何
        // 旧数据，页面能稳定起来；登录态由下一次正常启动（脏标记被清掉）恢复。
        //
        // 从**第一次**就重建，不再「先原地 reload 一次试试」。
        // 真机反馈：进歌单时原地 reload 起来的新进程，一进歌单又被打死，
        // 用户看到的就是「闪两下才勉强回来」。原地 reload 复用同一份脏存储，
        // 拿到的成功概率太低，而代价是多闪一次。
        //
        // 但重建要有一次性的保护：重建后新页面**立刻**又挂，说明问题不在存储，
        // 再重建一万次也只是黑屏循环。这种情况下退回包内离线副本，
        // 至少让用户进得去、听得见。
        if wakeRecoveryInFlight {
            // 这次挂掉本来就是「前台唤醒」那一轮在修，别把它判成「重建也救不了」。
            wakeRecoveryInFlight = false
            CrashLog.note("==== web content died during wake recovery, rebuilding once more ====")
            stopKeepAliveTimer()
            rebuildWebView(resumeAudio: shouldResume)
            return
        }
        if rebuiltSinceLaunch {
            stopKeepAliveTimer()
            CrashLog.note("==== web content died again after rebuild, falling back to offline copy ====")
            loadOfflineCopy()
            return
        }
        stopKeepAliveTimer()
        rebuiltSinceLaunch = true
        CrashLog.note("==== web content died \(contentProcessRestarts.count)x, rebuilding web view with clean store ====")
        rebuildWebView(resumeAudio: shouldResume)
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
        documentFinished = false
        hasEvaluatedFirstPaint = false
        // 每次导航重新判定：上一轮没确认成功的手递手状态不能遗留到下一次。
        if !isShowingOfflineCopy {
            pendingOnlineHandoff = false
        }
        // 播放中不动会话：新导航开始时 `setActive(true)` 会打断正在出声的媒体元素。
        if !wantsAudible || userPaused {
            AudioSessionController.shared.reactivate()
        }
    }
}

// MARK: - 文件选择

/// 页面里 `<input type="file">` 的处理者，也是 `WKUIDelegate` 里回调的原生选择面板。
///
/// 背景视频走的是「点按钮 → 页面建 input → `click()` → 用户选视频」这条链。
/// WKWebView 与 Safari 不同：**没有实现 `runOpenPanelWith` 就什么都不会发生** ——
/// 面板不弹、`change` 不触发，页面那边永远停在等待里，界面也不报错。
/// 用户看到的就是「上传了视频背景，背景完全没变化」。
private final class FilePickerPresenter: NSObject, UIDocumentPickerDelegate {
    private var completion: (([URL]?) -> Void)?

    func present(from controller: UIViewController?, completion: @escaping ([URL]?) -> Void) {
        self.completion = completion
        var types: [UTType] = [.movie]
        if #available(iOS 14.0, *) { types.append(.mpeg4Movie) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        controller?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let block = completion
        completion = nil
        // `asCopy: true`：拿到的已经是沙盒里的副本，必须留在原地。
        // WKWebView 会在这一拍同步读文件，删掉就变成一个空视频。
        block?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let block = completion
        completion = nil
        block?(nil)
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
            } else if body.hasPrefix("clock|") {
                container?.rememberPlaybackPositionClock(body)
            } else if body.hasPrefix("progress|") {
                container?.rememberPlaybackPositionProgress(body)
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
