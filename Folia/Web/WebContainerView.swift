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

    /// 重建之后又崩时，额外给一次重建配额。
    ///
    /// 原先「重建过一次就退离线副本」的判据太早下结论：轻量页面重建后能稳住，
    /// 用户只是恰好还在歌单页时才需要第二次机会。给一次就够 ——
    /// 两次重建之后还挂，说明问题不在壳这一层，继续重试只是黑屏循环。
    private var rebuildQuotaUsed = false

    /// 本次启动是否在使用「崩溃后」的干净存储。成功加载一次后置为 false。
    ///
    /// 启动时恒为 false：默认存储已经是干净的，不需要「恢复」。
    /// 只有 `rebuildWebView` 换到临时存储后才置真，用于在页面稳定后收尾。
    private var recoveringFromCrash = false

    /// 最近这段时间里「内容进程死掉」的时刻，不分是不是重建之后。
    ///
    /// `rebuildQuotaUsed` 那个保护位是靠 `checkFirstPaint()` 复位的：
    /// 页面只要画出来一次就允许再重建一次。这在「偶发一次回收」上是对的，
    /// 但歌单页是**一进去就把进程顶死**——每次重建都能画出首屏、用户再点歌单、
    /// 再被顶死，配额被无限续上，用户感受到的就是「一进歌单就闪退，永远好不了」。
    /// 所以再加一条与「画没画出来」无关的判据：按时间窗口数死亡次数。
    private var processDeaths: [Date] = []
    /// 进程死亡达到这个次数，就不再重建，改为原地重载。
    private static let deathWindow: TimeInterval = 60
    private static let deathLimit = 2

    /// 上一次真正**提交过**的主框架地址。
    ///
    /// 这是「大退重进、进歌单闪回加载界面」的救命信息：进程一死，`webView.url`
    /// 立刻退成 `about:blank`，`reload()` / `reloadFromOrigin()` 都变成空操作
    /// （没有可重载的文档），壳只能自己去把这个地址重新打开。
    private var lastCommittedURL: URL?

    /// 上一次**确认过页面真的画出来了**的站内地址。
    ///
    /// `lastCommittedURL` 记的是「主框架提交过」，它有两个坑：
    /// 1. 提交不等于画出来 —— 提交之后的 bundle 拉取失败、模块报错都会停在加载遮罩上，
    ///    这时它仍是真，于是看门狗「页面已经交付」的豁免条件（行 `guard lastCommittedURL == nil`）
    ///    会一直成立，真正卡死的加载再也得不到重试；
    /// 2. 用户从抖音 / 其他 App 里点链接回本 App 时，WKWebView 会**接着**加载那个外站地址，
    ///    提交成功后它就被覆盖成一个不是我们站点的 URL，此后进程再被回收，
    ///    壳既没有可重开的地址，也拿不到「页面已交付」的凭据。
    ///
    /// 所以单独记一份「首屏确认过、且属于本站」的地址，进程被回收后优先按它重开。
    /// 清空时机只有两处：换新实例（`rebuildWebView`）、用户主动重试（`hardReload`）。
    private var lastVisibleURL: URL?

    /// 上一轮运行里「用户真的看到过」的站内地址，跨启动保留。
    ///
    /// 用户报告的「大退进歌单闪退」现场是：杀掉 App 再打开，壳从头加载首页，
    /// 首屏还没确认就进了歌单，随后进程被内存顶死 —— 这一次启动里
    /// `lastVisibleURL` / `lastCommittedURL` 都是空的，`reloadInPlace` 只能回 `startURL`，
    /// 用户看到的就是「回到加载界面」。所以把上一次确认画出来的地址也落一份盘：
    /// 它是站内真实路径，重开一次只会落到同一个路由，不会带用户去别处。
    private static let pageHistoryKey = "folia.shell.lastVisibleURL"

    private var pageHistory: [URL] {
        guard let raw = UserDefaults.standard.string(forKey: Self.pageHistoryKey) else { return [] }
        return [URL(string: raw)].compactMap { $0 }
    }

    private func rememberVisibleURL(_ url: URL) {
        guard Self.trustedSiteURL(url) != nil else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: Self.pageHistoryKey)
    }

    /// 把进程顶死的那一页长什么样（路径 + 标题），只用于日志归因。
    private var deadPageFingerprint: String {
        let path = lastCommittedURL?.path ?? "-"
        let title = webView?.title ?? "-"
        return "\(path) | \(title)"
    }

    /// 连续失败这个次数就不再自动重载，停在界面上等用户手动点「重试」。
    ///
    /// 自动重载本身就会把页面换成加载界面 —— 用户点一次歌单、被顶死、然后
    /// 自动转两圈再顶死，「看起来就是闪退」。停住不动至少是稳定的，而且
    /// 界面上的重试入口是显式的、用户能理解的。冷启动会把这个计数清零。
    private static let autoReloadLimit = 2

    /// 这一轮已经自动重载了几次（首屏画出来、或用户手动点重试时清零）。
    private var consecutiveAutoReloads = 0

    /// 正在展示的文件选择面板。必须强引用：只被 `present` 持有的话，
    /// 回调那头可能已经释放，选中文件就永远传不回页面。
    private var filePicker: FilePickerPresenter?

    /// 这一轮「离开 App」期间音频可能被别家 App 占过，回前台要强制复核一次通路。
    ///
    /// 为什么不能靠探测判断：`.mixWithOthers` 下对方出声时
    /// `isOtherAudioPlaying` 会短暂翻真，但用户切回来的那一拍它通常已经翻回 false，
    /// 页面侧 `<audio>` 也仍报 `playing`、AudioContext 还是 running ——
    /// 三个判据全部显示「通路健康」，可实际一点声都没有（丢的是系统那一层通路）。
    private var stayedBackgroundedWhileAudible = false

    /// 离开过 App 且当时正在放：回前台必须重建一次音频通路。
    ///
    /// 与 `stayedBackgroundedWhileAudible` 的区别：
    /// - 前者问的是「页面自己还在出声吗」，靠 `isMediaHealthy` / 时钟推进来判；
    ///   被抖音这类 App 抢过后，页面往往**仍然报 playing、时钟也在走**，只是系统
    ///   那层通路被摘走了，于是它得出「健康」的结论，什么都不做 —— 用户听到的就是没声音。
    /// - 这一位是「按事实重建」：离开过、又该响，就不再多问，直接
    ///   `setCategory` + `setActive` 并把上下文叫醒。只重设通路，不动播放进度。
    ///
    /// 只在不该响的时候清掉（见 `markPausedIntent` / `finishAudioRecovery`），
    /// 这样保活轮询后续几拍仍会带着这条判据，直到页面自己重新出声。
    private var preemptedByOtherApp = false

    init(state: WebShellState) {
        self.state = state
        super.init(frame: .zero)
        // 会话控制器回前台要判断「通路到底断没断」，只有容器能跨进程问页面的播放时钟。
        AudioSessionController.shared.container = self
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
        // **不要**再往 `config.preferences` 上 setValue 那些私有偏好名。
        //
        // 早先这里有两行：
        //     setValue(true, forKey: "allowFileAccessFromFileURLs")
        //     setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        // 想的是「让 file:// 页面读本地视频」。这两个名字只是 WebKit 内部的偏好名，
        // 并不对应 WKPreferences 公开的 KVC 属性；只要系统版本不认，KVC 就抛
        // NSUnknownKeyException，ObjC 异常 Swift 接不住，直接一路炸到 UIApplicationMain，
        // 表现是「点图标瞬间退回桌面」—— 每次启动必现。
        //
        // 视频背景那条链实际走的是「原生文件选择面板 → 页面拿到 blob:」，
        // 根本不读 file://，删掉这两行对功能没有影响。
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

        // **启动一律用默认存储，不再因为「上次崩过」就换临时存储。**
        //
        // 早先这里是 `CacheSweeper.isStoreDirty` 决定要不要走 `.nonPersistent()`，
        // 换来的稳定性极其有限，代价却是把用户的登录态、歌单缓存、播放设置
        // 全部锁在一个用完即弃的沙盒里 —— 而且这个状态会跨启动延续：
        // 只要标记没被清掉，用户**每次打开都要重新登录**，且无从恢复。
        // 真机反馈「大退后再进歌单闪退、登录状态没了」正是这一条。
        //
        // 现在改用更保守的自愈：崩溃后只在**当前这一轮**换干净存储重建
        // （见 `rebuildWebView`），下一次启动照常读用户的真实数据。
        // 若那一轮里反复崩，退到包内离线副本，也不会牵连登录态。
        if CacheSweeper.isStoreDirty {
            // 旧版本遗留的标记：直接作废，把存储还回去。
            CacheSweeper.clearDirty()
            CrashLog.note("==== legacy dirty flag cleared on launch ====")
        }
        let config = makeConfiguration(forceCleanStore: false)

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
    ///
    /// `cleanStore` 只在线程被「脏数据」拖死的封顶那一轮才为真（见下面的注释），
    /// 普通崩溃一律保留用户的默认存储 —— 登录态、歌单缓存、播放设置全在里面。
    private func rebuildWebView(resumeAudio: Bool, cleanStore: Bool = false) {
        // 旧实例的事件全部解绑，避免它继续往原生回传状态。
        reloadObservation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()

        let previousWantsAudible = resumeAudio
        // **不再把「换存储」这件事落盘。**
        //
        // 原先这里是 `markDirty("rebuild-after-crash")`，本意是「万一下一轮还挂，
        // 下次启动也直接用干净存储」。实际代价完全失控：
        // 只要重建过一次，这个标记就落到了 UserDefaults 里；而清除它需要
        // 「重建后成功加载 + 8 秒内不再挂」，在歌单页这种重灾区根本走不到。
        // 于是标记长期驻留 —— 之后**每一次启动都用 nonPersistent 存储**，
        // 用户看到的就是「大退重进登录态没了」，且他自己没有任何办法恢复。
        // 重建只影响当前这一轮，绝不外溢到下次启动。
        recoveringFromCrash = cleanStore
        contentProcessRestarts.removeAll()
        // 保活轮询手里的 `self` 是这一轮的，重建后照旧可用；
        // 但旧页面那份播放意图已经随进程消失，若还在响就重新记一次。
        if resumeAudio {
            Self.wasAudibleInBackground = true
        }

        // **默认保留用户存储。**
        //
        // 早先这里无条件走 `.nonPersistent()`，理由是「新实例读不到磁盘上的旧数据，
        // 也就不会按同样的方式再死一次」。实测这条既治不了根，又直接造成
        // 「进歌单闪退之后登录态没了」：换存储只是让新页面看不到 cookie 与 localStorage，
        // 崩溃本身照样发生。歌单页那一次进程死亡的原因是一次性渲染几百张封面把内存顶满，
        // 跟磁盘数据无关 —— 真正管用的是新进程池 + 下面的配额保护。
        // 只有「这一轮已经重建过、还是被压死」才动用干净存储做最后一次兜底，
        // 而且它在 `didFinish` 后就会被收尾，不会带进下一次启动。
        let config = makeConfiguration(forceCleanStore: cleanStore)
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
        // 新实例还没有提交过任何文档：上一次那个地址属于旧进程，留着只会让
        // 「页面已不存在」那条分支把用户送回一个已经不属于当前实例的 URL。
        lastCommittedURL = nil
        lastVisibleURL = nil
        consecutiveAutoReloads = 0
        state.clearLoadFailure()
        state.leaveOfflineCopy()

        // 重建时**允许命中缓存**，不要 `.reloadIgnoringLocalCacheData`。
        //
        // 重建的触发条件就是「进程刚被内存压力顶死」。此时再强制绕开缓存，
        // 新进程必须把所有脚本、封面、可视化引擎重新下载并重新解码一遍，
        // 内存曲线在刚起来的那几秒直接冲顶 —— 结果就是刚重建好、用户一进歌单
        // 又被压死，形成「一进歌单就闪退」的死循环。
        // 用 `.useProtocolCachePolicy` 复用磁盘上已经有的资源，
        // 又因为新进程池本身是干净的，不会把旧进程的坏状态带过来。
        webView.load(URLRequest(url: Self.startURL,
                                cachePolicy: .useProtocolCachePolicy,
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
        rebuildQuotaUsed = false
        // 时间窗里攒下的死亡记录也一起清：用户手动点了重试，说明他愿意再试一轮，
        // 不该因为刚才那几次而当场被判成「重建也没用」。
        processDeaths.removeAll()
        consecutiveAutoReloads = 0
        lastCommittedURL = nil
        lastVisibleURL = nil
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
            // 这一次是「唤醒重载」，不是用户主动要重来：把看门狗也重开，
            // 但**不能**因此把「本次启动见过首屏」这条事实抹掉 —— 那是判断
            // 「页面是不是真的死了」的唯一依据，抹掉后下面那个 8 秒兜底
            // 会在页面其实已经正常的情况下照样跑一次重建。
            webView.load(URLRequest(url: Self.startURL,
                                    cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: 30))
            scheduleProgressWatchdog()
            // 页面上本来就有内容（曾被判死只是探测失败）：给足时间让这份文档
            // 自己画回来，别在 8 秒后无脑重建 —— 重建会把用户手上的歌单整页丢掉。
            let hadContent = reachedFirstPaintOnce
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let self, !self.didReachFirstPaint else { return }
                // 原来就有内容的页面，允许它在更长时间里自己画回来，绝不重建。
                guard !hadContent else {
                    CrashLog.note("==== foreground wake: page had content, keep waiting (no rebuild) ====")
                    return
                }
                CrashLog.note("==== foreground wake: reload did not paint, rebuilding ====")
                self.rebuildWebView(resumeAudio: resume, cleanStore: true)
            }
            return
        }
        rebuildWebView(resumeAudio: resume)
    }

    /// 时间窗里死了几次（顺带把过期的记录丢掉）。
    private func deathCountInWindow(now: Date) -> Int {
        processDeaths = processDeaths.filter { now.timeIntervalSince($0) < Self.deathWindow }
        return processDeaths.count
    }

    /// 在同一个 `WKWebView` 实例上把页面重新打开，尽量保住用户所在的位置。
    ///
    /// 为什么不能只 `reload()`：进程被回收后 `webView.url` 已经是 `about:blank`，
    /// `reload()` 与 `reloadFromOrigin()` 都**没有可重载的文档**，调了等于没调，
    /// 界面就永远停在加载页上。而 `rebuildWebView()` 加载的是首页，会把用户
    /// 正在看的那一页整页丢掉 —— 他感受到的正是「闪退回加载界面」。
    /// 所以这里按可信度依次试：当前地址 → 上次提交的地址 → 首页 → 包内副本。
    ///
    /// 返回 false 表示「没有任何可打开的目标」，调用方应改走重建。
    @discardableResult
    private func reloadInPlace(after reason: String) -> Bool {
        if isShowingOfflineCopy, let indexURL = Self.offlineIndexURL {
            CrashLog.note("==== reload offline copy in place (\(reason)) ====")
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
            scheduleProgressWatchdog()
            return true
        }

        let current = webView.url
        let target: URL
        if let current, current.scheme == "https", current.host == Self.siteHost {
            // 同一份文档还在，直接重载最快，也不会丢掉当前的 SPA 路由。
            CrashLog.note("==== reload in place \(current.path) (\(reason)) ====")
            didReachFirstPaint = false
            documentFinished = false
            hasEvaluatedFirstPaint = false
            webView.reload()
            scheduleProgressWatchdog()
            return true
        }
        if let last = Self.trustedSiteURL(lastVisibleURL) ?? Self.trustedSiteURL(lastCommittedURL) {
            target = last
        } else if let entry = pageHistory.last, Self.trustedSiteURL(entry) != nil {
            // 大退之后没有「刚才那一页」的凭据（首屏还没确认、或上一次重建把记录清了），
            // 但有上一轮启动时回到过的页面宿主地址：按路径重开，用户不会被扔回首页。
            target = entry
        } else {
            target = Self.startURL
        }
        CrashLog.note("==== reopen \(target.path) in place (\(reason)) ====")
        didReachFirstPaint = false
        documentFinished = false
        hasEvaluatedFirstPaint = false
        webView.load(URLRequest(url: target,
                                cachePolicy: .useProtocolCachePolicy,
                                timeoutInterval: 30))
        scheduleProgressWatchdog()
        return true
    }

    /// 这一轮回前台是「用户从别的 App 点链接回来」引起的，不是从桌面临时切走。
    ///
    /// 两种情况看到的现场完全不同：后者页面还停在原处，前者主框架已经在加载
    /// 那个外站链接 —— 探测会在页面已经换掉之后才开始问，得出的结论没有意义。
    private var pendingArrivalHandoff = false

    /// 站内地址才算数：外站（用户从别的 App 点链接打开的那种）不能拿来当重开目标。
    private static func trustedSiteURL(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.host == siteHost else { return nil }
        return url
    }

    /// 原地重载，并带「连续自动重载」的次数保护。
    ///
    /// 自动重载本身就会把页面换成加载界面：用户点一次歌单 → 被顶死 → 自动转两圈
    /// 又顶死，「看起来就是闪退」。所以连着两次起不来就停手，
    /// 把决定权交给界面上的「重试」（用户能理解那个动作）。
    ///
    /// `countTowardsLimit` 只在「进程死了、壳自己把页面拉回来」时打开；
    /// 用户在别的 App 里操作后回到前台这类场景也走这里，但那是**用户看得见的正常重开**，
    /// 一次就把它算进配额，会让后面真正需要自愈的两次机会提前用光 ——
    /// 用户看到的就是「切回来闪一下加载界面，之后进歌单又闪一次」。
    @discardableResult
    private func attemptInPlaceReload(force: Bool, reason: String, countTowardsLimit: Bool = true) -> Bool {
        if !force, countTowardsLimit {
            consecutiveAutoReloads += 1
            guard consecutiveAutoReloads <= Self.autoReloadLimit else {
                CrashLog.note("==== auto reload gave up after \(consecutiveAutoReloads - 1)x (\(reason)) ====")
                state.noteLoadFailure(-1001)
                return false
            }
        }
        return reloadInPlace(after: reason)
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
        let arriving = pendingArrivalHandoff
        pendingArrivalHandoff = false
        // 正在加载（首屏还没到）时页面本来就没装好，别把它当成死掉；
        // 已经在整屏提示「加载失败」的那条路走 `hardReload()`，不重复判定。
        guard documentFinished, !state.showsBlockingNotice else { return }
        // 缓冲期：冻结的进程被唤醒后要先跑几十毫秒 JS 才回答得上，紧贴着回调问会误判。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !arriving else { return }
            // 判「页面死了」不能看 `didReachFirstPaint`：它会被导航与看门狗清零，
            // 而用户从歌单页切回来时，这一路上很可能刚重开过一次看门狗。
            // 于是「页面好好地在歌单上」也会被判成唤醒失败 → 白走一次重载 →
            // 用户看到的就是「切回来闪一下加载界面，歌也断了」。
            // 用 `reachedFirstPaintOnce`（本次启动出现过首屏）当判据才准。
            // 再加一条「主框架提交过站内文档」（`lastCommittedURL`）：大退重进之后
            // 首屏常常没被采到，只看前一条会把一份正在正常显示的页面判成死的。
            // 两条都不成立，才确实「没有任何可用的页面」，走唤醒恢复。
            if !self.reachedFirstPaintOnce, self.lastCommittedURL == nil {
                self.probePageLiveness(thenRecover: true)
                return
            }
            // **页面显示什么，就以什么为准。**
            //
            // 「本次启动见过首屏」在下面两种场景里是过期的：用户从抖音回本 App 时
            // WKWebView 接着加载了那边的落地页、或者进程被回收后壳走了一次「原地重开」。
            // 前者此时页面上根本不是我们的播放器，后者还在下载第一份文档 ——
            // 只按历史标记判断会漏掉这两种「真的是空页面」的情况。
            self.probePageLiveness(thenRecover: false) { [weak self] loaded in
                guard let self, loaded else { return }
                // 确认页面上真的是一份挂好内容的站内文档：不然后面的「进程死亡、
                // 一进歌单就退回加载界面」会被当成死页面，白走一遍重开。
                self.markVisiblePageIfNeeded()
            }
        }
    }

    /// 把「当前这份已经画出来的站内文档」记下来，供进程被回收后原样重开。
    ///
    /// `#app-splash` 还在就说明首屏还没走完（React 没挂上或还在拉 bundle），
    /// 这时候记下来等于把一份加载界面当成「用户所在的位置」。
    private func markVisiblePageIfNeeded() {
        let container = webView
        container?.evaluateJavaScript(
            "(function(){return document.getElementById('app-splash') ? 'loading' : 'ready';})()"
        ) { [weak self, weak container] result, _ in
            guard let self, let container, container === self.webView else { return }
            guard (result as? String) == "ready" else { return }
            if let url = Self.trustedSiteURL(container.url) {
                self.lastVisibleURL = url
                self.rememberVisibleURL(url)
            }
            self.reachedFirstPaintOnce = true
            self.markFirstPaintSettled()
        }
    }

    /// 「首屏确实画出来了」的收尾：复位各处的自动重载配额。
    ///
    /// 与 `checkFirstPaint()` 里那段重复，但两条路必须都做：
    /// `checkFirstPaint` 只在 `didFinish` 之后排一次，而「大退重进 → 进歌单」这条路
    /// 往往走的是回前台探测（`markVisiblePageIfNeeded`），首屏检查那一轮早就过期了。
    /// 配额不复位，用户在歌单里正常翻两次就会把 `consecutiveAutoReloads` 用光 ——
    /// 之后真正需要自愈的那一次直接被拦下，用户看到的就是「回到加载界面」。
    private func markFirstPaintSettled() {
        rebuiltSinceLaunch = false
        rebuildQuotaUsed = false
        consecutiveAutoReloads = 0
    }

    /// 问页面「还活着吗」：先一条最便宜的表达式，再确认 body 有子节点。
    ///
    /// `completion` 只在「确认页面还活着」时为真；不传就是纯探测。
    private func probePageLiveness(thenRecover recover: Bool,
                                   completion: ((Bool) -> Void)? = nil) {
        webView.evaluateJavaScript("1+1") { [weak self] result, error in
            guard let self else { return }
            if error != nil || result == nil {
                CrashLog.note("==== wake probe failed: no response from page ====")
                if recover { self.recoverAfterForegroundWake() }
                return
            }
            // `1+1` 能答只说明 JS 引擎还在；页面剩下空壳时同样是「点了没反应」，
            // 再确认一次挂载点是不是还在。
            self.webView.evaluateJavaScript(
                "(function(){return document.body ? document.body.children.length : 0;})()"
            ) { alive, _ in
                guard (alive as? NSNumber)?.intValue ?? 0 == 0 else {
                    completion?(true)
                    return
                }
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
            // 已经回到前台：清掉进后台时刻。
            //
            // 这个值只用来回答「进程被杀时，它在后台待了多久」。
            // 不清空的话，用户上一次切后台的时间会一直留着，
            // 之后任何一次进程终止都会算出一个很大的 backgroundAge，
            // 被判成「系统回收」而走原地重载 —— 真正的崩溃反而漏掉了。
            self.enteredBackgroundAt = nil
            // 回前台这一拍先同步一次「该响」：会话控制器要用它决定补不补通路。
            // 必须排在容器自己那轮异步探测之前 —— 那一轮走 JS 往返，会晚几百毫秒。
            AudioSessionController.shared.wantsAudible = self.wantsAudible && !self.userPaused
            // **马上再声明一次抢占**，不要等会话控制器那一轮异步复核。
            //
            // 用户从抖音回来时，对方 App 的会话通常还没被系统淡出，
            // `isOtherAudioPlaying` 在这一拍仍是真；会话控制器的 `didBecomeActive`
            // 一旦读到它就不再执行 `rebuildPathQuietly()`，而这条判断之后没有任何补救 ——
            // 页面那侧 `<audio>` 仍报 playing、AudioContext 仍是 running，
            // 下面 `probeThenRecover` 的几条判据全都显示「通路健康」，一格都不动。
            // 结果就是「切回来界面在放、进度在走、一点声音都没有」。
            // 这一句把「离开过 App 且该响」这个事实直接交给页面侧的恢复：
            // 它会重新 `setCategory` + `setActive`，并在上下文真的 running 之后再补 `play`。
            if self.wantsAudible && !self.userPaused {
                self.preemptedByOtherApp = true
            }
            // 回前台不改变意图：该响的继续响，轮询照旧。
            //
            // `stayedBackgroundedWhileAudible` 交给 `probeThenRecover` 消费：
            // 它在那一拍里先看「该响却实际没在出声」，是才强制重建一次通路。
            // 只是切出去看了一眼、回来还在正常放的，这一条不会动手 ——
            // 这就是「来回切不打断」的保证。
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
            self.enteredBackgroundAt = Date()
            // 记一个「在后台待过」的标记，回前台时用它决定要不要强制复核一次通路。
            //
            // 为什么不能只靠回前台那一拍的 `isOtherAudioPlaying`：用户切去看抖音，
            // 对方出声时本 App 的会话就丢了；等切回来时对方早已被系统淡出，
            // 这个标志已经翻回 false，页面侧 `<audio>` 也仍报 playing、
            // AudioContext 还是 running —— 三个判据全显示「通路健康」，实际却没声。
            // 所以只要「在后台待过 + 仍然该响」，回前台就强制复核一次。
            if self.wantsAudible && !self.userPaused {
                self.stayedBackgroundedWhileAudible = true
            }
            // 同步给会话控制器：回前台那一刻由它补一次「无条件重建通路」。
            //
            // 容器侧的探测是异步的（要跨进程执行 JS），而丢掉通路之后页面侧
            // 往往还能自报健康，探测半天也不一定下得了结论；会话控制器这边只需要
            // 「进后台时该响」这一个前提，就能在回来的第一拍把系统那层通路接回来。
            // 两路互不冲突：它只重建 category，不碰播放进度。
            AudioSessionController.shared.wantsAudible = self.wantsAudible && !self.userPaused
            AudioSessionController.shared.backgroundedWhilePlayingOK = self.wantsAudible && !self.userPaused
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
        // 用户亲手开始放：之前那次「被别的 App 抢占」的账已经无关，别再重复重建通路。
        preemptedByOtherApp = false
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
    ///
    /// 例外：切到别的 App / 回桌面时，页面会先收到一次 `pause` 再失去可见性。
    /// 那一拍 `applicationState` 仍是 `.active`，若按「用户收手」处理，
    /// 轮询就停了，回到 App 里发现歌没了 —— 所以这里补一条 `visibilityState` 判断。
    fileprivate func markPausedIntent() {
        guard UIApplication.shared.applicationState == .active else { return }
        // 刚进后台、正被别家 App 抢占的那一拍：页面收到的 pause 是系统掐的，不是用户收手。
        //
        // 这一拍 `applicationState` 往往还是 `.active`（系统先停媒体、再切状态），
        // 若按「用户收手」处理，回来时 `userPaused` 为真，`recoverAudioPath` 直接 return，
        // 谁也不会再把歌放回去 —— 用户听到的就是「切去看别的 App，回来一点声都没了」。
        guard !stayedBackgroundedWhileAudible else {
            CrashLog.note("==== pause ignored (came back from background) ====")
            return
        }
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
                self.preemptedByOtherApp = false
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
            // 配额只用来「降低探测频率」，不能变成「探够就再也不管」。
            //
            // 早先是 `foregroundProbes < 6`：一直停在前台听歌时，12 秒后保活就彻底
            // 停摆，之后无论被谁静默掐断都没人接手 —— 用户看到的是「放在那不动，
            // 过一阵自己没声了」。现在改成每两拍（4 秒）重新放行一轮，
            // 实际效果是「隔 2 秒探一次」，既不会每拍都碰音频通路，也不会漏掉。
            if self.foregroundProbes >= 2 {
                self.foregroundProbes = 0
            }
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
        // 本 App 的会话当前是否还「活着」。
        //
        // `setActive(true)` 是幂等的：会话活着时它是空操作，不会按停任何媒体元素。
        // 但**会话已经被系统收走**时（看完抖音回来、别家播放器抢占），页面里的
        // `<audio>` 往往仍报 `playing`、AudioContext 也还是 running ——
        // 只看这两个事实会判成「通路完好」，于是什么都不做，用户听到的就是
        // 「界面在放、进度在走，一点声音都没有」。所以把会话活性也算进判据。
        let sessionAlive = session.isOtherAudioPlaying == false

        // 刚从后台回来、当时正在放：先看页面到底还在不在出声。
        //
        // 为什么单独判这一条：被抖音这类 App 抢过之后，`isOtherAudioPlaying` 在
        // 回到前台那一拍已经翻回 false（对方正在被系统淡出），页面里的 `<audio>`
        // 却仍报 `playing`、AudioContext 也还是 running —— 三个判据全部显示
        // 「通路健康」，实际一点声都没有（丢的是系统那一层通路）。
        // 所以这里换成「页面自报有没有在出声」这个唯一可靠的事实：
        // 它说在播就一格都不动（正常切出去看一眼回来仍不断），
        // 说没在播就直接重建一次通路，不再等连拍判断。
        if stayedBackgroundedWhileAudible {
            stayedBackgroundedWhileAudible = false
            isMediaHealthy { [weak self] healthy in
                guard let self else { return }
                guard healthy else {
                    CrashLog.note("==== audio silent after background, rebuilding path (\(reason)) ====")
                    self.brokenProbeStreak = 0
                    self.recoverAudioPathPass(reason: "back-from-background", attempt: 0)
                    return
                }
                // `paused == false` 还不足以证明**真的在出声**：被别家 App 抢占过之后，
                // 媒体元素常常仍报 playing，时间轴却已经冻住。再确认一次时钟在走。
                self.isPlaybackClockAdvancing { advancing in
                    guard !advancing else {
                        CrashLog.note("==== audio alive after background, skip rebuild (\(reason)) ====")
                        self.brokenProbeStreak = 0
                        self.finishAudioRecovery()
                        return
                    }
                    CrashLog.note("==== audio clock stuck after background, rebuilding path (\(reason)) ====")
                    self.brokenProbeStreak = 0
                    self.recoverAudioPathPass(reason: "clock-stuck", attempt: 0)
                }
            }
            return
        }

        // 被别的 App 抢过、且用户仍要声音：不再问「页面自报健不健康」。
        //
        // 这一条专门治「从抖音回来，界面在放、进度在走、一点声都没有」：
        // 被抢占之后页面侧的三项事实（`<audio>` 未暂停、`currentTime` 在推进、
        // AudioContext 是 running）全部为真，靠探测永远发现不了 ——
        // 丢的是它们下面那一层系统通路。所以只要「离开过 App + 该响」，
        // 就重建一次会话：`setCategory` 会让 WebKit 把媒体元素按停一瞬间，
        // 所以重建之后必须跟一次 `resumeAudio`（`recoverAudioPathPass` 里已经做了）。
        if preemptedByOtherApp {
            preemptedByOtherApp = false
            CrashLog.note("==== audio path preempted by another app, rebuilding path (\(reason)) ====")
            brokenProbeStreak = 0
            recoverAudioPathPass(reason: "preempted", attempt: 0)
            return
        }

        resumeAudioContexts { [weak self] contextOK in
            guard let self else { return }

            if contextOK && !silencedHint && sessionAlive {
                // 通路完好：一格音频状态都不要碰，只把「想做待办」结掉。
                CrashLog.note("==== audio path healthy, skip rebuild (\(reason)) ====")
                self.brokenProbeStreak = 0
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
                if healthy && !silencedHint && sessionAlive {
                    CrashLog.note("==== audio path healthy via media probe, skip rebuild (\(reason)) ====")
                    self.brokenProbeStreak = 0
                    self.finishAudioRecovery()
                    return
                }
                // 连续两次判「断」才真去重建。
                //
                // 保活轮询是 2 秒一拍，而 `evaluateJavaScript` 与 `AudioContext.state`
                // 都有一拍延迟：页面正在换页 / 正在 seek / 正在交叉淡化时，
                // 单次探测很容易抓到「media 暂时还没进 playing」的瞬间。
                // 早先这里一次为假就 `setCategory` + `setActive`，那是**自己动手把
                // 好端端的歌按停**：用户听着就是「没碰它，突然停一下又接着放」，
                // 一卡一顿。现在要求连续两拍都断才动手，误判窗口扩大到 4 秒，
                // 真正的断流（进程挂起、会话被夺）照样能在 4 秒内被发现。
                self.brokenProbeStreak += 1
                guard self.brokenProbeStreak >= 2 else {
                    CrashLog.note("==== audio probe suspicious, waiting second sample (\(reason)) ====")
                    self.finishAudioRecovery()
                    return
                }
                self.brokenProbeStreak = 0
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

    /// 供会话控制器在回前台那一拍调用：页面时钟还在走吗（只读，不动任何状态）。
    func verifyPlaybackClockAdvancing(_ completion: @escaping (Bool) -> Void) {
        isPlaybackClockAdvancing(completion)
    }

    /// 页面时钟到底有没有在走（比 `paused` 更硬的事实）。
    ///
    /// 被抖音这类 App 抢过之后，页面里的 `<audio>` 常常仍报 `paused == false`、
    /// `AudioContext.state == running`，可时间轴其实已经冻住了 —— 系统把整条
    /// 音频通路摘走，WebKit 那侧的媒体元素看起来一切正常。
    /// 所以拿 `currentTime` 隔 400ms 采两次：只在**确实没推进**时才判为断了。
    private func isPlaybackClockAdvancing(_ completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
          var list = document.querySelectorAll('audio');
          for (var i = 0; i < list.length; i += 1) {
            var el = list[i];
            if (!el.src || el.ended || el.paused) { continue; }
            window.__foliaClockT0 = el.currentTime;
            window.__foliaClockEl = el;
            return 'sampled';
          }
          return 'idle';
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, (result as? String) == "sampled" else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.webView?.evaluateJavaScript(
                    "(function(){var el=window.__foliaClockEl,"
                        + "t0=window.__foliaClockT0;"
                        + "if(!el||typeof t0!=='number'){return 'gone';}"
                        + "return (el.currentTime > t0 + 0.05) ? 'advancing' : 'stuck';})()"
                ) { result, _ in
                    completion((result as? String) == "advancing")
                }
            }
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
                if ok {
                    self.resumeAudio(reason: reason)
                    self.finishAudioRecovery()
                } else if attempt >= 3 {
                    // 上下文始终起不来，也不能就此收工。
                    //
                    // 早先这里是「attempt 用完就 `resumeAudio` 然后结束」：媒体元素被
                    // `play()` 起来了，但 AudioContext 还是 suspended —— 页面上进度在走、
                    // 一点声都没有，而且再没人重试。现在改成保留这一次的补放，
                    // 同时**不重置**连续判据之外的状态：下一拍保活（4 秒后）会再走一遍，
                    // 直到上下文真的 running 或者用户自己暂停。
                    CrashLog.note("==== audio context still suspended after \(attempt) retries (\(reason)) ====")
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

    /// 连续几次探测判定「通路断了」。只有累计到 2 次才真的重建会话。
    ///
    /// 单次探测会因为页面换页 / seek / 交叉淡化的瞬间抖动而误报，
    /// 误报的代价是「亲手把正在放歌按停一次」，用户听到的就是无端卡顿。
    private var brokenProbeStreak = 0

    /// 进入后台的时刻。用来区分「进程被系统正常回收」与「进程真的崩了」。
    private var enteredBackgroundAt: Date?

    /// 后台待多久后进程被杀算「系统回收」而不是崩溃。
    ///
    /// iOS 在应用退到后台后随时会回收 WebContent 进程，这是**正常行为**：
    /// 内存吃紧、切走了几分钟、开了别的 App 都会触发。把它当成崩溃处理会连累
    /// 三件事：判脏存储（下次启动没登录态）、换临时存储（歌单数据全丢）、
    /// 自动续播（页面从 0 开始，听起来就是「自己重播了」）。
    /// 30 秒是个保守分界：真正在用的崩溃几乎都发生在进程活跃期间。
    private static let backgroundReclaimThreshold: TimeInterval = 30

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
        // 补放时**不再把 position 往回调**。
        //
        // 这里原本会调用 `healAudioDrift()`，用原生记住的页面进度覆盖 `currentTime`。
        // 但那份进度是页面**几秒前**上报的快照：拿它去纠正正在播放的元素，
        // 等于每次都把歌拽回过去。真机反馈正是这样 ——
        // 进度条卡在同一处反复播放，怎么都过不去；大退重开后又从旧位置开始。
        // 声音与字幕的偏差在「保活补放」这一条路上本来就只有几百毫秒，
        // 交给页面自己的播放时钟推进即可，不需要原生插手。
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

    /// **本次启动**是否已经见过一次首屏。
    ///
    /// 与 `didReachFirstPaint` 的区别是它不会被导航 / 看门狗 / `probePageLiveness` 清掉：
    /// 这些地方清 `didReachFirstPaint` 是为了「这一轮重新等首屏」，
    /// 但回前台探测那一条路把「首屏没到」直接当成「页面已经死了」，
    /// 于是只要用户切出去一会儿（或者只是页面慢了一拍），
    /// 就会被判成唤醒失败、白走一遍重载 —— 用户看到的就是「切回来闪一下加载界面」。
    /// 首屏一旦出现过，`WKWebView` 的 SPA 路由切换不会把它退回去，这个标记就可以当硬事实用。
    private var reachedFirstPaintOnce = false
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
        // 每次都重新取一份页面：浏览器缓存里可能留着上一版的入口脚本。
        _ = fetchIndexStamp()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallTimeout) { [weak self] in
            self?.reportStallIfNeeded()
        }
    }

    /// 读一次页面里记下的「文档版本」标记（见 `shellBridgeScript` 里的 `__foliaIndexStamp`）。
    ///
    /// 只用来在日志里留证据：卡在加载界面时，真机日志里这一行就能区分
    /// 「脚本报错了」和「脚下这份 HTML / 入口脚本就是旧的那一份」。
    private func fetchIndexStamp() -> Bool {
        webView?.evaluateJavaScript("(window.__foliaIndexStamp || '-')") { result, _ in
            guard let stamp = result as? String, !stamp.isEmpty else { return }
            CrashLog.note("==== index stamp \(stamp) ====")
        }
        return true
    }

    private func reportStallIfNeeded() {
        guard !didReachFirstPaint else { return }
        // **曾经画出来过的页面，永远不再判「卡在首屏」。**
        //
        // 这是「进歌单 / 切歌词之后闪回加载界面」最直接的一条成因：
        // 看门狗只看 `didReachFirstPaint`，而这个标志会被 `scheduleProgressWatchdog()`
        // 无条件清零 —— 报暂停被拒、唤醒重载、原地重载都会重开一次。
        // 于是用户正常听着歌、在歌单里翻两分钟，30 秒到点后这里照常跑一遍诊断：
        // 这时 `documentFinished` 常被中间那次导航置回 false，
        // `hasEvaluatedFirstPaint` 也是 false，两条豁免都不成立 → 直接 `retryLoadForStall()`。
        // 三次之后还要回退到离线副本。用户看到的就是「歌听得好好地，界面突然转圈」。
        // 页面既然已经画出来过，就没有「首屏卡住」这回事了，这条判据必须最先返回。
        guard !reachedFirstPaintOnce else { return }
        // **用户手上正有一份 SPA 页面时，也不能重载。**
        //
        // 上面那条只认「本次启动成功画过首屏」。但「大退重进 → 进歌单 → 闪回加载界面」
        // 的现场里，这一次启动的首屏可能根本没被采到（`checkFirstPaint` 只在 `didFinish`
        // 之后才排，而 SPA 路由切换不触发 `didFinish`；进程还被回收过一次），
        // `reachedFirstPaintOnce` 于是为假。此时看门狗 30 秒到点照样会判「卡在首屏」
        // 去 `retryLoadForStall()` —— 用户看到的就是「正在用，突然整页退回加载界面」。
        //
        // 判据换成「真的画出来过一份站内文档」，且要区分两种「有页面」：
        //
        // - `reachedFirstPaintOnce`：本次启动见过首屏。它不会被导航清掉，
        //   用户从歌单页切回来时最可靠。
        // - `lastVisibleURL`：**只在首次加载 / 原地重开之后**由 `didFinish` 写入。
        //   早先这里用的是 `lastCommittedURL`（只要是主框架提交就写），于是
        //   「提交了但 bundle 拉不下来、停在加载遮罩上」也会被豁免，
        //   真正卡死的加载永远等不到重试。现在「提交过」不再算交付，
        //   必须真的拿到过一份完整文档。
        //
        // 注意**不能用 `webView.url`**：用户从抖音回本 App 时 WKWebView 会接着
        // 加载那边的落地页，此时地址是外站、页面也不是播放器。那种情况必须
        // 允许下面把页面拉回站内，否则用户会一直停在一个没有播放界面的页面上。
        guard !reachedFirstPaintOnce, lastVisibleURL == nil else { return }
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
            'stamp=' + (window.__foliaIndexStamp || '-'),
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
            // 重试**必须绕开缓存**。
            //
            // 卡在加载界面的现场里有一条是「脚下这份文档/入口脚本本身是旧的那一份」：
            // 线上发版后文件名带新哈希，而本地那份 HTML 仍指向已经下线的旧入口，
            // 脚本 404 后 React 永远挂不上（诊断串里就是 `rootChildren=0`）。
            // 用 `.reloadIgnoringLocalCacheData` 会把这份坏文档再读一遍，等于原地打转；
            // 回退阈值虽然能兜到离线副本，但那是「能用但功能不全」。
            // 这里直接按「重新取」发一次请求，坏文档才有机会被换掉。
            self.webView?.load(URLRequest(url: Self.startURL,
                                          cachePolicy: .reloadRevalidatingCacheData,
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
                    self.reachedFirstPaintOnce = true
                    self.markFirstPaintSettled()
                }
                // 页面已经画出来了：解除「刚重建过」的保护位，允许下一次进程被回收
                // 再走一遍自愈（否则这一次成功后，之后真正的 OOM 会被判成
                // 「重建也没用」而直接退到离线副本）。
                self.rebuiltSinceLaunch = false
                // 配额同样复位：页面既然画出来了，说明上一次重建已经成功，
                // 之后再被回收属于新的一次故障，应该拥有完整的自愈机会。
                self.rebuildQuotaUsed = false
                // 页面确实起来了：自动重载的次数保护复位，下一次故障还能自愈。
                self.consecutiveAutoReloads = 0
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
          // 旧版线上页的常量停在 1.8.5，沿用会让「当前版本」永远显示旧值。
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

          // 更新公告（#update-mask）在壳里不弹：版本号已经固定成壳的实际版本，
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

    /// 视频层（背景视频 / 歌词页可视化层）的兜底驱动。
    ///
    /// 线上页的 `<video>` 播放时机挂在「播放器状态变化」与一个 2 秒的定时校正上：
    /// 只要那次 `play()` 被拦（控制中心收起后媒体进程被挂起、切后台再回来），
    /// 它就再也不会自己起来 —— 用户看到的就是「视频背景设了，画面却一直是静态的、
    /// 或者停在第一帧找不到效果」。这里补的正是这一拍：
    /// - 页面已经在放：一格都不动；
    /// - 明确处于暂停且有源：补一次 `play()`。
    /// 只覆盖**静音**的视频（或有 `aria-hidden` 标记的那些），
    /// 带声音的视频层绝不碰，免得和播放器的音频通路抢。
    /// 只读 DOM，不改任何全局原型，对普通播放页的音频没有影响。
    private func driveBackgroundVideo() {
        let js = """
        (function(){
          try {
            var list = document.querySelectorAll('video');
            var played = 0, none = 0;
            for (var i = 0; i < list.length; i += 1) {
              var v = list[i];
              var hidden = v.getAttribute('aria-hidden') === 'true';
              // **只有静音的视频才允许壳代它 play()。**
              //
              // 早先这里用的是 `video[aria-hidden="true"]` 这一个选择器，
              // 只覆盖「设置里的背景视频」，歌词/可视化页那一层（用户自己导入的
              // 本地视频）根本不在这条链上，于是「导入了却一直不显示」。
              // 但也不能对所有 `<video>` 无脑补放：带声音的视频被壳反复 play()
              // 会和播放器的音频抢通路，听起来就是歌一卡一顿。
              // 所以判断依据改成「静音」这一条客观事实：静音的视频层
              // （背景视频、可视化视频）都该一直在放，带声的一格都不碰。
              if (!v.muted && !hidden) { continue; }
              if (!v.currentSrc && !v.src) { none += 1; continue; }
              if (v.ended) { continue; }
              // 视频层必须是循环播放：页面自己的循环开关在重建图层后经常没接上，
              // 播到结尾就停住，看起来就是「导入成功了但画面不动」。
              try { v.loop = true; } catch (e) {}
              if (v.paused) {
                var p = v.play();
                if (p && p.catch) { p.catch(function(){}); }
                played += 1;
              }
            }
            if (played > 0) { return 'played'; }
            return none > 0 ? 'no-source' : (list.length ? 'playing' : 'none');
          } catch (e) { return 'error'; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            // 只在真的动了手、或者一个源都没有时留一行：
            // 保活每 4 秒会走一次这里，健康时写日志会把文件刷满。
            guard let flag = result as? String, flag == "played" || flag == "no-source" else { return }
            CrashLog.note("==== video layer drive: \(flag) ====")
        }
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
      // 免得壳里显示的版本和装上的包对不上。
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
      // 线上页的标志性版本号。
      //
      // 线上 `index.html` 里整张赞赏卡（`#donate-version-num`）与实际部署的前端版本
      // （`/assets/main-<hash>.js`）都能用来判断「脚下这份文档是哪一版」。
      // 这不是界面上的版本号（那个由 `installDonateCard` 改成壳的真实版本），
      // 只用来识别「浏览器里还留着一份很老的 HTML/入口脚本」。
      //
      // 新版（2.1）的 `index.html` 由 `vite build` 生成，里面没有赞赏卡，
      // `#donate-version-num` 取不到：此时标记里那一项就是空串，只有入口脚本的哈希可看。
      window.__foliaIndexStamp = (function(){
        try {
          var hit = document.getElementById('donate-version-num');
          var text = hit ? (hit.textContent || '').trim() : '';
          var scripts = document.querySelectorAll('script[src]');
          var entry = '';
          for (var i = 0; i < scripts.length; i += 1) {
            var m = /\\/assets\\/(index|main)-([A-Za-z0-9_-]{6,})\\.js/.exec(scripts[i].src || '');
            if (m) { entry = m[1] + '-' + m[2]; break; }
          }
          return text + '|' + entry;
        } catch (e) { return ''; }
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
    ///
    /// 「点了导入、选好视频了，界面一点提示都没有」的现场里，有两种完全不同的原因：
    /// 面板根本没弹出来（没有可用的 `topPresenter`），或者弹出来了、页面那侧没有接住。
    /// 双方都不报错，用户只能干等，所以这里把入口与结果都记进日志。
    private func presentFilePicker(_ completionHandler: @escaping ([URL]?) -> Void) {
        let presenter = FilePickerPresenter()
        filePicker = presenter
        let controller = topPresenter
        CrashLog.note("==== open panel requested (presenter=\(controller == nil ? "nil" : "ok")) ====")
        guard let controller else {
            // 没有可挂的面板：必须回一个空结果，否则页面那条 `change` 永远不触发。
            CrashLog.note("==== open panel abandoned: no presenter ====")
            filePicker = nil
            completionHandler(nil)
            return
        }
        presenter.present(from: controller) { [weak self] urls in
            // 把选中的文件描述记下来：用户反馈「导入视频后没变化」，
            // 日志里至少要先能分清「面板根本没选中」「选中了但不是视频」
            // 与「选中了、扩展名也对，是页面那侧没接住」这三种完全不同的情况。
            if let urls, !urls.isEmpty {
                let described = urls.map { url -> String in
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
                    return "\(url.lastPathComponent) ext=\(url.pathExtension) size=\(size)"
                }.joined(separator: " | ")
                CrashLog.note("==== open panel picked \(urls.count): \(described) ====")
            } else {
                CrashLog.note("==== open panel picked 0 (cancelled) ====")
            }
            completionHandler(urls)
            self?.filePicker = nil
            // 选完两秒后补一份视频层现场：如果页面确实接住了文件，
            // 这一份里就能看到 kind=blob、ready/err 的真实值；
            // 若仍然 `videos=0` 或 `kind=none`，问题就在页面那一侧的赋值链上。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.collectVideoLayerReport { report in
                    CrashLog.note("==== video layer after pick ====\n\(report)")
                }
            }
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

    /// 是不是「用户从别的 App 点链接回来的」那一拍导航。
    ///
    /// 从抖音这类 App 回到本 App 时，系统会把那条链接交给正在运行的 WKWebView，
    /// 让它在主框架上**接着**加载 —— 界面上原来看着的播放器被换成了一个外站页面。
    /// 这个判定必须宽一点：新浪微博的链接会先经过 `t.cn` 再 302，
    /// 同一次点击可能触发多条主框架导航，第一条就必须拦住，否则后面的重定向会绕过检查。
    ///
    /// 返回 true 表示「已经当外链处理掉了」（外跳系统浏览器或直接丢弃），
    /// 调用方应立即 `cancel`，壳随后把用户带回站内自己的那份页面。
    private func handleArrivalNavigation(_ url: URL, scheme: String) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let isSameSite = host == Self.siteHost || host.hasSuffix(".\(Self.siteHost)")
        // 正在站内正常用着（或正在往线上切）时不拦：站内外链已经由上面那条
        // 「主框架跳站外」分支出去了，这里只处理「当前页并非我们的页面」的情况。
        if isShowingOfflineCopy || isOnSitePage { return false }
        if isSameSite {
            // 外站页面上的站内链接：用户未必想回 Folia，但留在一个已经不属于我们的
            // 文档上没有任何意义（播放器不在，回前台只会显示那个页面），直接回站内。
            CrashLog.note("==== arrival navigation: back to site \(url.path) ====")
            pendingArrivalHandoff = true
            scheduleArrivalReload(after: "arrival-site-link")
            return true
        }
        // 如果是 App 的普通链接，交给系统浏览器；业务落地页（详见 `shouldReloadOnArrival`）
        // 只记一笔，不打开浏览器，把用户带回站内。
        if shouldReloadOnArrival(url) {
            CrashLog.note("==== arrival navigation: discard landing page \(host) ====")
        } else if scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        pendingArrivalHandoff = true
        scheduleArrivalReload(after: "arrival-link")
        return true
    }

    /// 当前文档不是站内页面时，主框架上的任何导航都可能是「外部闯入」。
    private func isArrivalCandidate() -> Bool {
        isShowingOfflineCopy || isOnSitePage ? false : true
    }

    /// 当前文档是不是站内那份线上页面（离线副本不算）。
    private var isOnSitePage: Bool {
        guard !isShowingOfflineCopy, let url = webView?.url else { return false }
        guard url.scheme == "https" else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == Self.siteHost || host.hasSuffix(".\(Self.siteHost)")
    }

    /// 落地页不值得在外部浏览器里再打开一次的那一类（视频分享页、短链）。
    private func shouldReloadOnArrival(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let shortLinkHosts = ["t.cn", "v.douyin.com", "iesdouyin.com", "douyin.com", "iesvideo.com"]
        return shortLinkHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// 把用户带回站内自己的页面。
    ///
    /// 不直接在 `decidePolicyFor` 里调用 `load`：那一条回调里换导航会打乱
    /// WKWebView 自己的决策栈（历史上出现过「导航被丢弃、页面永远停在空白」）。
    /// 放到下一拍再走，并复用 `reloadInPlace` 的选址逻辑（站内上次的地址优先）。
    private func scheduleArrivalReload(after reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.attemptInPlaceReload(force: false, reason: reason,
                                            countTowardsLimit: false) else {
                self.webView.load(URLRequest(url: Self.startURL,
                                             cachePolicy: .useProtocolCachePolicy,
                                             timeoutInterval: 30))
                self.scheduleProgressWatchdog()
                return
            }
            // 这一次重开是用户自己操作引起的，不是「页面死了」：探测那一轮
            // 不能拿它当证据去继续判死、继续重开。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.markVisiblePageIfNeeded()
            }
        }
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

        // 用户从抖音 / 微信这类 App 点链接回到本 App 时，系统会把那条链接交给我们
        // 已经在跑的 WKWebView，让主框架接着加载它 —— 播放器界面被换成一个外站页面。
        // 之后无论切后台再回来、还是进程被回收，壳都没有一份可用的站内文档，
        // 用户看到的就是「回到加载界面」。这里把这种「闯入式」导航全部拦下，
        // 并把用户带回他自己那份站内页面。
        if isMainFrame && (navigationAction.navigationType == .linkActivated || isArrivalCandidate()) {
            if handleArrivalNavigation(url, scheme: scheme) {
                decisionHandler(.cancel)
                return
            }
        }

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
        // 记下「真正提交过的地址」：进程死掉之后 `webView.url` 会退成 `about:blank`，
        // 只有这一份记录能把用户重新送回他当时所在的那一页。
        if webView.url?.scheme == "https", webView.url?.host == Self.siteHost {
            lastCommittedURL = webView.url
            // 新的一页能提交，说明上一轮的自动重载已经是有效的，配额重新给。
            consecutiveAutoReloads = 0
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
        // 这一份文档真的送到了：先记下来，后面进程被回收时才有地方重开。
        // 用户从别的 App 点链接回本 App 时，这一下记的可能是外站地址，
        // 所以要用站内校验过滤（`lastCommittedURL` 保持原语义不动）。
        if let url = Self.trustedSiteURL(webView.url) {
            lastVisibleURL = url
            rememberVisibleURL(url)
        }
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
        // 与 `contentProcessRestarts` 分开记：那一份会被 `rebuildWebView` 清空，
        // 而「一分钟内死了几次」必须跨重建累计，否则每换一次实例就重新计数，
        // 死亡循环永远达不到阈值。
        processDeaths.append(now)
        // 这是与「ObjC 异常闪退」完全不同的另一条路径：网页把 WebProcess 搞死了。
        // 计进日志才能区分到底是哪一种。
        CrashLog.note("==== web content process terminated (#\(contentProcessRestarts.count)) url=\(webView.url?.absoluteString ?? "-") ====")

        // 先判断这次进程死亡是「系统回收」还是「真崩溃」。
        //
        // 这个区分决定后面三件事怎么办，是本次修复的核心：
        // 系统回收（在后台待久了才被杀）不应该判脏存储、不换临时存储、
        // 也不自动续播 —— 否则用户看到的就是「大退后没登录态、歌单数据没了、
        // 一点播放就从 0 开始重播」。
        let backgroundAge = enteredBackgroundAt.map { Date().timeIntervalSince($0) } ?? 0
        let reclaimedBySystem = UIApplication.shared.applicationState != .active
            && backgroundAge >= Self.backgroundReclaimThreshold

        // 网页进程被打死后，页面里的 `<audio>` 随之消失，声音立刻断掉 ——
        // 用户实际经历的是「切歌词界面，音乐停了 / App 退回首页」。
        // 这里先把现场抓下来：崩溃前的标题、当前路由，以及崩溃时是否还在出声。
        collectTerminationContext()

        if reclaimedBySystem {
            // 后台被系统回收：复用默认存储原地重载即可。
            //
            // 这一条以前会 `markDirty` + `nonPersistent` 重建，代价是全套登录态与
            // 歌单缓存清零；而它恰恰发生在「用户切出去一会儿再回来」这种最平常的场景里，
            // 于是「大退重进要重新登录」变成了必然。系统回收本就没弄脏任何数据，
            // 原存储继续用才是正确的。
            CrashLog.note("==== web content reclaimed by system after \(Int(backgroundAge))s in background, reloading in place ====")
            CacheSweeper.clearDirty()
            if !reloadInPlace(after: "reclaimed-by-system") {
                stopKeepAliveTimer()
                rebuildWebView(resumeAudio: false)
            }
            return
        }

        // 不再落盘任何「存储脏」标记。
        //
        // 这里原本是 `markDirty("webcontent-terminated")`，用来让**下次启动**
        // 也用干净存储。代价是登录态跨启动丢失，且清除条件几乎不可达
        // （见 `rebuildWebView` 里的说明）。现在自愈限定在当前这一轮：
        // 真崩溃就走下面的重建，下一次启动照常读用户数据。

        // 崩溃前正在出声，且用户没按过暂停：重载后把播放续上。
        let shouldResume = Self.wasAudibleInBackground && !userPaused

        if wakeRecoveryInFlight {
            // 这次挂掉本来就是「前台唤醒」那一轮在修，别把它判成「重建也救不了」。
            wakeRecoveryInFlight = false
            CrashLog.note("==== web content died during wake recovery, rebuilding once more ====")
            stopKeepAliveTimer()
            rebuildWebView(resumeAudio: shouldResume)
            return
        }

        // **页面已经没了，重建 WebView 救不回来。**
        //
        // 这一条是「大退之后一进歌单就闪回加载界面」的直接成因：进程被杀掉以后
        // `webView.url` 会变成 `about:blank`，提交过的文档已经不在这个进程里了。
        // 此时再换一个新实例去加载首页，等于把用户手上正看着的那一页整页丢掉 ——
        // 他看到的不是「歌单崩了」，而是「整个 App 退回加载界面」。
        // 唯一能保住他当前页面的做法是：让同一个实例重新打开**上次提交过的那个 URL**。
        //
        // 这一条必须排在「时间窗内死过几次」之前：那个分支要按次数判断，
        // 而这里只要还有上次的地址就一定能把用户送回原处，不该被次数提前拦掉。
        if webView.url == nil || webView.url?.scheme == "about" {
            CrashLog.note("==== web content died without a page, reopen \(lastCommittedURL?.path ?? "-") ====")
            if reloadInPlace(after: "no-page") { return }
        }

        // 时间窗内已经死过几次：不再重建，只原地重载一次；再死就停在界面上。
        //
        // 重建（换 WKWebView 实例、换进程池）本身是**有代价的**：新实例要重新建进程、
        // 重新解码它自己那份页面。而触发它的场景恰恰是「内存刚被顶死」，
        // 于是会出现「重建 → 又死 → 再重建」的循环 —— 用户看到的就是
        // 「一进歌单就闪退回加载界面，怎么都不好」。真正的解法是这一步：
        // 连着死就不再自动重建，把决定权交给用户（界面上的重试）。
        if deathCountInWindow(now: now) >= Self.deathLimit {
            CrashLog.note("==== web content died \(deathCountInWindow(now: now))x in \(Int(Self.deathWindow))s (\(deadPageFingerprint)), no more rebuild ====")
            // 选歌词形式 / 大退进歌单之后回到加载界面，主因在这一分支原来走的是
            // `attemptInPlaceReload`：它的配额一旦在正常使用中被耗光（见 `markFirstPaintSettled`
            // 的说明），这里就会直接 return —— 页面已经没了，用户就停在加载界面上。
            // 这一支本来就是「连着死、不能再重建」的最后一根救命绳，不该再被配额拦，
            // 所以显式 `force`：只把用户送回他刚才那一页，不做任何重建。
            if !reloadInPlace(after: "repeat-death") {
                state.noteLoadFailure(-1001)
            }
            return
        }

        // 真崩溃：重建 WebView，但**保留用户的默认存储**。
        //
        // 「进歌单闪退、退回加载界面」的现场是内容进程被压死：页面上那个歌单列表
        // 要一次性渲染几百张封面，内存一下顶到上限。解法因此不在「换存储」——
        // 换存储只能让这一轮读不到旧数据，属于治标，而且代价是丢掉登录态。
        // 真正要做的是让新进程别重复同样的死法：重建实例 + 新进程池，
        // 配合下面的 `rebuiltSinceLaunch` 做次数保护，避免无限循环。
        stopKeepAliveTimer()
        rebuiltSinceLaunch = true
        CrashLog.note("==== web content died \(contentProcessRestarts.count)x, rebuilding web view ====")
        rebuildWebView(resumeAudio: shouldResume)
    }

    /// 抓一份「进程死掉时页面长什么样」的现场。
    ///
    /// 页面脚本早在切歌词时就已随进程一起消失，`evaluateJavaScript` 拿不到任何东西；
    /// 但 `title` / `url` 仍留在 UI 进程这一侧的 WKWebView 上，
    /// 足以判断「是不是在歌词页被杀」——若是，就能确认是页面重建播放器树时把进程搞死的。
    ///
    /// 另外补一份「视频层」现场：用户导入本地视频后界面没变化、随后退出就闪退，
    /// 只有知道页面上那几个 `<video>` 到底有没有挂上源、是什么协议（`blob:` / `file:`）、
    /// 解码到了哪一步（`readyState` / `error.code`），才能区分是
    /// 「页面根本没接住这个文件」还是「接住了但解码把进程顶死」。
    private func collectTerminationContext() {
        let title = webView.title ?? "-"
        let url = webView.url?.absoluteString ?? "-"
        let audible = Self.wasAudibleInBackground ? "1" : "0"
        let head = "==== termination context ====\ntitle=\(title)\nurl=\(url)\naudible=\(audible)"
        // 进程刚死时这条 JS 通常已经打不回来，所以先落标题/URL，再异步补视频现场；
        // 补回来的那几行会单独成段，不会覆盖上面的内容。
        CrashLog.note(head)
        collectVideoLayerReport { report in
            CrashLog.note("==== video layer at termination ====\n\(report)")
        }
    }

    /// 页面里所有 `<video>` 的关键状态，一行一个。
    ///
    /// 只读 DOM，不改任何状态。歌词/可视化页的视频层与背景视频
    /// （`video[aria-hidden="true"]`）都在这份清单里。
    private func collectVideoLayerReport(_ completion: @escaping (String) -> Void) {
        let js = """
        (function(){
          try {
            var list = document.querySelectorAll('video');
            if (!list.length) { return 'videos=0'; }
            var out = ['videos=' + list.length];
            for (var i = 0; i < list.length; i += 1) {
              var v = list[i];
              var src = String(v.currentSrc || v.src || '');
              var kind = src.indexOf('blob:') === 0 ? 'blob'
                : src.indexOf('file:') === 0 ? 'file'
                : src.indexOf('data:') === 0 ? 'data'
                : src ? 'remote' : 'none';
              out.push([i,
                'hidden=' + (v.getAttribute('aria-hidden') || '-'),
                'kind=' + kind,
                'ready=' + v.readyState,
                'net=' + v.networkState,
                'err=' + (v.error ? v.error.code : '-'),
                'size=' + v.videoWidth + 'x' + v.videoHeight,
                'paused=' + (v.paused ? 1 : 0),
                't=' + Math.round((v.currentTime || 0) * 10) / 10,
                'd=' + (isFinite(v.duration) ? Math.round(v.duration * 10) / 10 : '-')
              ].join(' '));
            }
            return out.join('\\n');
          } catch (e) { return 'error ' + (e && e.message); }
        })();
        """
        webView?.evaluateJavaScript(js) { result, error in
            DispatchQueue.main.async {
                completion((result as? String) ?? (error?.localizedDescription ?? "-"))
            }
        }
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
