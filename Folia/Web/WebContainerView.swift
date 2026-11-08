import UIKit
import SwiftUI
import WebKit
import Combine
import AVFoundation
import CoreImage
import CryptoKit
import UniformTypeIdentifiers
import os

/// 承载官方网页版的 WKWebView 容器。
///
/// 本轮（2.1/212 之后）针对两条实测仍未修复的反馈做的结构性改动：
/// 1. 「进抖音再回软件没声音」：根因不在探测，而在**音频会话在离开期间被系统没收后，
///    回前台时没有任何一条路无条件把它重新激活** —— `AudioSessionController.didBecomeActive`
///    的三条分支全部以 `isPlaying` 为门（手机背面朝上时 WebKit 会真的按停媒体元素，
///    页面随后上报 `paused`，`isPlaying` 就永久为假），容器侧又以页面自报的健康状态为准。
///    现在改成：离开过 App 且用户没亲手暂停 → 回前台**先无条件激活会话再判定**，
///    `isPlaying` 一律由容器按播放意图推进，不再单靠页面上报。
/// 2. 「大退进歌单回加载界面」：首屏只认 `#app-splash` 这一个节点，而线上站的加载遮罩
///    在 SPA 路由切换时还会再出现一次 —— 于是「进歌单」被记成首屏未完成，
///    30 秒看门狗判死 → 自动重载 → 用户回到加载界面。现在遮罩只在①仍在加载 / ②根本没挂上
///    这两种情况下才算「没画出来」，SPA 内部再出现的遮罩一律不算。
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
    /// in-place 重开后要补装的路由守卫（落脚点哈希）。
    ///
    /// 旧 WebView 出生时装的是「不钉」脚本，document-start 注入改不了它；
    /// 只能在重开落地的 didFinish 时机用 evaluateJavaScript 补装。
    private var pendingPinFragment: String?
    /// 首屏卡住后的自动重试时间窗，同样用来限流。
    private var stallRetries: [Date] = []

    /// 由系统音频中断模块同步过来的「正在后台播放」。
    ///
    /// 切歌词界面闪退时整块 `audio` 会从页面上被摘掉，暂停事件根本发不出来；
    /// 用户看到的就是「后台还在响，一进歌词界面 App 没了」。靠播放器自己上报暂停来不及，
    /// 所以由原生在检测到进程终止前一帧的状态时判定要不要自动续播。
    fileprivate static var wasAudibleInBackground = false

    /// 冷启动打开哪一屏。
    ///
    /// 上个版本直接打首页（`startURL`）。对「上次是死在歌单里」的用户来说，
    /// 首页等于重新拉一遍全部脚本 + 首屏封面，内存最容易在那几秒顶满；
    /// 而用户真正关心的是「歌还能不能放」。
    ///
    /// 所以：落盘的最后一个页面如果是重负载路由，就不再从这里进去 ——
    /// 直接开 `#player`。正常用户（从没把进程顶死过）走原路径，行为不变。
    private static func launchURL() -> URL {
        // 冷启动恒进首页。看门狗退役之后，`launchURL` 里"顶死过就降级到稳定页"
        // 的逻辑已经没有任何意义——它只会把"用户上次死在歌单"变成"永远从首页再撞一次"。
        return startURL
    }

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
    /// 取 4：一次可能是瞬时抖动（切网络的瞬间、TLS 握手超时），两次仍可能是弱网下的
    /// 自带重试；冷启动那几秒网络栈还在起，第三次失败也未必是真的连不上。
    /// 四次连续失败（配合 2.5 秒间隔约 10 秒）基本可以确认是 DNS / 链路 / 劫持层面的
    /// 持续故障，继续重试只会让用户对着同一个失败页干等。
    private static let offlineFallbackThreshold = 4

    /// 封面降载规则表的编译结果缓存。
    ///
    /// `makeConfiguration` 每次重建都要**同步**等一次编译（规则表必须同步就绪）。
    /// 而实测这台机器上编译一直超时 —— 每次重建都在主线程白等 2 秒，
    /// 日志里「rebuild after process death」到「crash route guard installed」
    /// 之间那 2-3 秒就是它。编译成功就缓存，失败/超时也只试一次。
    fileprivate static var foliaRuleListCache: WKContentRuleList?
    fileprivate static var foliaRuleListUnavailable = false

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
    /// 停在离线副本上时，定时探一下线上域名，通了就自动切回去。
    ///
    /// 冷启动那几秒 iOS 的网络栈常常还没就绪，连发几次 `-1009` 就会被打回离线副本；
    /// 而离线包的启动遮罩不会自己摘 —— 用户看到的就是「卡在 Folia 加载界面」。
    /// 不能让用户自己再点重试，也不能一直留在离线页。
    private var onlineProbeTimer: Timer?
    private var onlineProbeAttempts = 0
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

    /// 汽水音乐请求通道。桥对象挂在 `window.__foliaBridge` 上，
    /// 每次主框架提交后由 `installQishuiBridge()` 重新挂上。
    private let qishuiRelay = QishuiBridge()

    /// 把「用户正在看的那一页」落盘。
    ///
    /// 这里记**完整地址（含哈希路由）**，不再提前去哈希。
    ///
    /// 上一版是在这里就把哈希抹掉，结果是：重建时的落脚点永远是首页
    /// （日志 `rebuild: reopen /`），而 `landingHistory` 这一路也永远是 `/` ——
    /// 等于「大退进歌单」直接被强行送回首页，用户看到的就是加载界面。
    ///
    /// 真正该防的不是「记住这个歌单」，而是「**再进一次刚把进程顶死的那个歌单**」。
    /// 那件事改由 `noteRouteDeath` / `deathCount` 按路由判断：只有它在最近一分钟内
    /// 真的顶死过进程，才降级到不带哈希的那一屏（见 `rebuildWebView` 里 `landing`）。
    /// 这样正常来回切换路由不会被误伤，出事的那一次又会自动绕开。
    private func rememberVisibleURL(_ url: URL) {
        guard let trusted = Self.trustedSiteURL(url) else { return }
        UserDefaults.standard.set(trusted.absoluteString, forKey: Self.pageHistoryKey)
        // **同步地址位。**
        //
        // 日志 10-30-15Z 第 20 行：新实例打开的是 `#player`，死报上来的却是歌单。
        // `lastCommittedURL` / `lastVisibleURL` 只在别处零散更新，`refreshPageLocation`
        // 每拍采到的真实地址没有落到这两位上，于是重建时读到的仍是旧值。
        // 现在统一在这里写 —— 落盘、内存地址位、以及「这一屏是不是重负载」的判定
        // 用的是同一个地址，不会互相打架。
        if Self.isMemoryHeavy(trusted) {
            // 这个路由顶死过进程：可以记住（下次进来看见它就在 `launchURL` 里降级），
            // 但绝不放进「重建落脚点」的两个候选位。
            return
        }
        lastCommittedURL = trusted
        lastVisibleURL = trusted
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

    /// 本次启动里离开过 App（进过后台）。
    ///
    /// 与 `stayedBackgroundedWhileAudible` 的区别：那个只在「进后台时该响」时置位，
    /// 这个只表示「离开过的这一轮还没结束」。被抖音抢占时 `wantsAudible` 可能
    /// 已经被页面的一串 pause 打成假，`stayedBackgroundedWhileAudible` 于是不置位，
    /// 于是页面随后报的 pause 会被当成「用户亲手暂停」——恢复链永久锁死。
    /// 只有用户亲手点播放（`markAudibleIntent`）才清掉它。
    private var wasBackgroundedThisSession = false

    /// 离开过 App 且离开时该响，但**回来之后还没有任何一次确认过「真的在出声」**。
    ///
    /// 与 `preemptedByOtherApp` / `stayedBackgroundedWhileAudible` 的区别：
    /// 那两位走的是「先问页面、再决定要不要动手」，而被抖音摘走之后页面每一层
    /// 判据都显示健康，于是永远不动手（日志 07-21-43Z 第 25-33 行）。
    /// 这一位只表达一条事实：**这次离开没有留下任何「回来看过、确实有声」的证据**，
    /// 所以回前台第一拍就该无条件重建一次系统通路（`setCategory` + `setActive`）。
    /// 一旦页面开始出声（保活里时钟在走 / 用户重新点了播放）就清掉，
    /// 保证「切出去看一眼回来歌不断」不会每次都断一下。
    private var leftAppWhileAudible = false

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

    /// 系统内存告警。日志里有没有这一条，是区分「真的被内存顶死」和
    /// 「WebKit 自己崩」的关键证据：有告警 → 继续压内存；一条都没有 → 换方向。
    private var memoryWarningObservation: Any?
    /// 内存水位遥测定时器（每 30 秒一条 `mem` 日志）。
    private var memLogTimer: Timer?

    init(state: WebShellState) {
        self.state = state
        super.init(frame: .zero)
        // 会话控制器回前台要判断「通路到底断没断」，只有容器能跨进程问页面的播放时钟。
        AudioSessionController.shared.container = self
        setUp()
        memoryWarningObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            CrashLog.note("==== app memory warning ====")
        }
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
        // 封面图降载：**在图片解码这一层**限制内存，而不是等页面自己响应开关。
        //
        // 日志 10-31-12-11-34Z 的现场：冷启动 8 秒进歌单，进程立刻被顶死。
        // 歌单详情一次性铺几百张封面，每张解码后都要占 WebContent 的常驻内存 ——
        // 这是「闪退频繁」的根。
        //
        // 原先的对策是给页面挂 `window.__foliaLowMemory` 让线上页自己降载，
        // 但线上入口脚本（`assets/main-*.js`）里根本没有读这个开关的代码，
        // 等于什么都没做。WKContentRuleList 是 WebKit 自己的网络/策略层，
        // 不需要页面配合，也不会碰 DOM：
        // - 只拦**图片**资源（`resource-type` = image），接口与脚本不受影响；
        // - 只拦 `@2x` / `@3x` 这一类超采样变体（网易云的封面都是这个命名），
        //   页面会退到 1x，视觉几乎无差，解码内存直接降到约 1/4～1/9；
        // - 不带域名白名单，任何图床都适用 —— 网页版换域名也不会失效。
        //
        // 规则表必须**同步**准备好再交给 config：`WKUserContentController` 与
        // `WKWebViewConfiguration` 都不能在后台线程回填。用信号量在这里等一次，
        // 同一份 JSON 编译过之后走的是磁盘缓存，只有本进程第一次（几十毫秒）真的解析。
        if let rules = WKContentRuleListStore.default().foliaDownscaleRuleList() {
            userContent.add(rules)
            CrashLog.note("==== content rule list installed: block @2x/@3x cover images ====")
        }
        // 注入到所有 frame：离线副本里的 worker 也要把 `/api/...` 补成线上地址，
        // 否则元数据 / 歌词解析在 file:// 下会静默失败。脚本内部按协议判断，线上页不受影响。
        userContent.addUserScript(WKUserScript(
            source: Self.shellBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        // 先注入原生播放器桥，确保它拿到的是真正的原始play
        userContent.addUserScript(WKUserScript(
            source: Self.nativePlayerBridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // 再注入audioKeeperScript（它的play包装会在原生播放器的外层，但不影响原生接管）
        userContent.addUserScript(WKUserScript(
            source: Self.audioKeeperScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // 横屏时网页会把一排桌面窗口按钮画到右上角（见 `hideWindowChromeScript`）。
        userContent.addUserScript(WKUserScript(
            source: Self.hideWindowChromeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // 低内存画像：把站点自己的性能设置预置成最低档，并断掉 WebGL。
        // 不依赖站点读 `__foliaLowMemory`（线上入口脚本没读），全部走站点
        // 已有的 localStorage 设置键 + 优雅的 WebGL 失败回退路径。
        userContent.addUserScript(WKUserScript(
            source: Self.lowMemoryProfileScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // 基础实例（普通冷启动）不钉路由：页面自己切到哪一屏是页面的自由。
        // 只有 `rebuildWebView` 重建时才把落脚点钉死（见 rebuildWebView 里的注入）。
        userContent.addUserScript(WKUserScript(
            source: Self.pinnedLandingScriptDisabled(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // 刚把进程顶死过的深链：短时间内由页面侧拦截，别再让它自动跳回去。
        let routeGuard = Self.routeGuardScript()
        if !routeGuard.isEmpty {
            userContent.addUserScript(WKUserScript(
                source: routeGuard,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            CrashLog.note("==== crash route guard installed ====")
        }
        userContent.add(AudioStateRelay(), name: "foliaAudioState")
        userContent.add(JSLogRelay(), name: "foliaJSLog")
        let qr = QRFallbackRelay()
        qrRelay = qr
        userContent.add(qr, name: "foliaQrFallback")
        let intentRelay = AudioIntentRelay()
        intentRelay.container = self
        userContent.add(intentRelay, name: "foliaAudioIntent")
        // 汽水音乐音源：线上页的请求入口是 `window.electron.qishuiRequest`。
        // 壳里没有 Electron，这条通道由原生代发（见 `QishuiBridge`）。
        // 注意 `electron` 这个对象同时是 0.7.24 判定桌面窗口的依据，
        // 桌面分支在 iPhone 上的影响已逐条核对（见 `bridgeInstallScript`）。
        userContent.add(qishuiRelay, name: "foliaQishui")
        // 注册原生播放器桥
        NativePlayer.shared.webView = nil
        // 原生播放器自己只动 AVPlayer，完全不碰壳的意图系统：用户走 cmd=pause 时
        // `userPaused` 永不置真，进后台后保活按 `wantsAudible=true` 把歌放回去。
        NativePlayer.shared.container = self
        userContent.add(NativePlayer.shared, name: "foliaPlayer")
        config.userContentController = userContent
        return config
    }

    /// 降载用的内容规则：「拦掉超采样的封面变体」。
    ///
    /// 单独抽出来是因为要经 `WKContentRuleListStore` 编译成一份可复用的规则表
    /// （WebKit 只认编译后的 `WKContentRuleList`，且编译是异步的）。
    /// 规则内容刻意写得很窄：
    /// - `resource-type` 只到 `image`，API / 脚本 / 字体一条都不碰；
    /// - `url-filter` 只匹配文件名形如 `@2x.png` / `@3x.jpg` / `@2x.webp` 的图片，
    ///   网易云与大部分图床的封面都是这个命名，1x 版本仍在，页面不会缺图；
    /// - 没有 `if-domain`：任何域名下的封面都一样处理，站点换域名不受影响。
    static let downscaleRuleJSON = #"[{"trigger":{"url-filter":".*@[23]x\\.(png|jpg|jpeg|webp)(\\?.*)?$","resource-type":["image"]},"action":{"type":"block"}}]"#

    /// 藏掉网页版按「桌面窗口」渲染出来的标题栏控件条。
    ///
    /// 页面用 `Boolean(window.electron)` 判定桌面版（见 `App.tsx` 的 `isElectronWindow`），
    /// 而壳必须保留 `window.electron.qishuiRequest` 才能用汽水音源 ——
    /// 于是横屏时右上角会多出一排「全屏 / 最小化 / 最大化 / 关闭」，
    /// 既不是这个 App 的控件，点了还会调壳里没实现的窗口方法。
    /// 只按「布局形状」隐藏那一个容器（`absolute top-0 left-0 right-0 z-[9999] h-8`），
    /// 不碰页面其它任何界面；用属性选择器避免在 CSS 里转义方括号。
    static let hideWindowChromeScript = """
    (function(){
      try {
        var css = 'div[class~="absolute"][class~="top-0"][class~="left-0"][class~="right-0"][class~="z-[9999]"][class~="h-8"]{display:none !important;}';
        function install(){
          try {
            if (!document.documentElement) { return; }
            if (document.getElementById('__folia_no_window_chrome')) { return; }
            var style = document.createElement('style');
            style.id = '__folia_no_window_chrome';
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          } catch (e) {}
        }
        install();
        document.addEventListener('DOMContentLoaded', install);
        setTimeout(install, 400);
      } catch (e) {}
    })();
    """

    /// 汽水音乐音源的桥。页面侧入口是 `window.electron.qishuiRequest`。
    ///
    /// 线上页只有在 `typeof window.electron?.qishuiRequest === 'function'` 时才会把
    /// 「汽水音乐」标成可用音源，否则在列表里是灰的、提示需要桌面端。
    /// 桌面端这条通道由 Electron 主进程代发，iOS 里没有，所以原生替它发（见 `QishuiBridge`）。
    ///
    /// **为什么可以保留 `electron` 这个名字。**
    ///
    /// 0.7.24 的 `App.tsx` 用 `Boolean(window.electron)` 得出 `isElectronWindow`，
    /// 早就担心这会把 iOS 壳误认成桌面窗口。逐个核对 0.7.24 源码后，它的下游分支在
    /// iPhone 上都不会造成实际影响：
    /// - `voiceInputPauseSupported = isElectronWindow && runsOnWindows()`：
    ///   `runsOnWindows()` 读 UA，iOS 的 UA 不含 `win`，恒为假；
    /// - `useCustomWindowRadius = isElectronWindow && transparentPlayerBackground && !wallpaperMode`：
    ///   只在该组合下才挂窗口圆角的 `useEffect` 去等 `isWindowMaximized`，普通不透明播放页不进入；
    /// - `usesCustomWindowChrome = isElectronWindow && !wallpaperMode` 会渲染一条 32px 的标题栏外壳，
    ///   但它是 `absolute` + `pointer-events-none` 的浮层，只吞掉自身那一条高度，
    ///   不参与布局流，也不拦截点击；
    /// - 其余 `window.electron?.xxx` 全是可选链，缺方法就短路，不会抛错。
    /// 所以保留它换回汽水音源，代价只是顶部多一条透明浮层。
    ///
    /// 另外补三个最小实现，避免桌面分支里 `await` 一个不存在的函数：
    /// `isWindowMaximized` / `isWindowFullscreen` 返回 `false`，`onWindowFullscreenChanged`
    /// 返回一个空的退订函数（页面把返回值当 unsubscribe 用）。
    static let bridgeInstallScript = """
    (function(){
      var bridge = window.electron || {};
      var seq = 0;
      var pending = {};
      // **必须原样 resolve `{ok, data|error}`，不能自己拆包。**
      //
      // 线上页的调用点是 `n = await window.electron.qishuiRequest(e,t)`，紧接着
      // `if(!n.ok){ … n.error.stage … }`（`providerRegistry` 里的 `Z()`）。
      // 也就是说它要的就是 Electron `ipcRenderer.invoke` 那种「直接给出结果对象」，
      // 由页面自己去判 `ok`、自己去读 `error`。
      //
      // 上一版把它写成了「永不 resolve、等壳回调」的挂起 Promise，而页面里
      // 根本没有接回调的那一环 —— `n` 永远是 `undefined`，于是
      // `n.error.stage` 抛 TypeError，二维码一步都走不到。
      bridge.qishuiRequest = function(action, params) {
        return new Promise(function(resolve){
          var id = 'q' + (++seq) + '_' + Date.now();
          pending[id] = { resolve: resolve };
          var timer = setTimeout(function(){
            // 壳没回包时也要落地：否则页面侧会一直转圈，且看不到任何原因。
            if (!pending[id]) { return; }
            delete pending[id];
            resolve({ ok: false, error: { code: 'network', message: 'qishui bridge timeout' } });
          }, 25000);
          pending[id].timer = timer;
          try {
            window.webkit.messageHandlers.foliaQishui.postMessage({
              id: id, action: String(action), params: params || {}
            });
          } catch (e) {
            clearTimeout(timer);
            delete pending[id];
            resolve({ ok: false, error: { code: 'network', message: 'bridge unavailable' } });
          }
        });
      };
      bridge.__foliaNative = true;
      bridge.__foliaResolve = function(id, payload) {
        var slot = pending[id];
        if (!slot) { return; }
        delete pending[id];
        if (slot.timer) { clearTimeout(slot.timer); }
        var obj;
        try {
          obj = typeof payload === 'string' ? JSON.parse(payload) : payload;
        } catch (e) {
          obj = null;
        }
        // 形状兜底：`Z()` 在 `!n.ok` 分支里无条件读 `n.error.stage`，
        // 所以 `error` 必须是个对象，不能是 undefined。
        if (!obj || typeof obj !== 'object') {
          obj = { ok: false, error: { code: 'network', message: 'bad payload' } };
        } else if (!obj.ok && (!obj.error || typeof obj.error !== 'object')) {
          obj = { ok: false, error: { code: 'network', message: 'request failed' } };
        }
        slot.resolve(obj);
      };
      // 窗口句柄的最小实现：壳里没有最大化 / 全屏窗口的概念，一律报「不是」。
      //
      // 页面把 `Boolean(window.electron)` 当成桌面版，横屏时会渲染一排窗口按钮
      // （全屏 / 最小化 / 最大化 / 关闭）。`WindowControls` 里这些函数是裸调用，
      // 缺一个就是 `TypeError: u.minimizeWindow is not a function`，整棵控件树抛错。
      // 控件条本身已由 `hideWindowChromeScript` 藏掉，这里只补「不缺方法」。
      try {
        if (typeof bridge.isWindowMaximized !== 'function') {
          bridge.isWindowMaximized = function(){ return Promise.resolve(false); };
        }
        if (typeof bridge.isWindowFullscreen !== 'function') {
          bridge.isWindowFullscreen = function(){ return Promise.resolve(false); };
        }
        if (typeof bridge.onWindowFullscreenChanged !== 'function') {
          bridge.onWindowFullscreenChanged = function(){ return function(){}; };
        }
        if (typeof bridge.minimizeWindow !== 'function') {
          bridge.minimizeWindow = function(){ return Promise.resolve(true); };
        }
        if (typeof bridge.toggleMaximizeWindow !== 'function') {
          bridge.toggleMaximizeWindow = function(){ return Promise.resolve(false); };
        }
        if (typeof bridge.maximizeWindow !== 'function') {
          bridge.maximizeWindow = function(){ return Promise.resolve(false); };
        }
        if (typeof bridge.toggleFullscreenWindow !== 'function') {
          bridge.toggleFullscreenWindow = function(){ return Promise.resolve(false); };
        }
        if (typeof bridge.closeWindow !== 'function') {
          bridge.closeWindow = function(){ return Promise.resolve(true); };
        }
        if (typeof bridge.openRemoteControl !== 'function') {
          bridge.openRemoteControl = function(){ return Promise.resolve(false); };
        }
      } catch (e) {}
      try {
        if (typeof bridge.getLoginDiagnostics !== 'function') {
          // 线上页取的是 `await window.electron.getLoginDiagnostics(providerId)`，
          // 返回的数组会被逐行拼进诊断报告。这里给出壳侧的固定事实。
          bridge.getLoginDiagnostics = function(){
            return Promise.resolve([
              'bridge=swift',
              'qishuiRequest=native'
            ]);
          };
        }
      } catch (e) {}
      // 0.7.25 的启动流程里这两个是**裸调用**（不是可选链）：
      // `Promise.allSettled([e.getSettings(), e.getCacheDirectory(), …])`。
      // 缺方法会同步抛 TypeError，把整段设置初始化打断，页面随后卡死并触发重建。
      try {
        if (typeof bridge.getSettings !== 'function') {
          // 返回空对象即可：页面用 `if (a) { …a }` 展开，空对象等价于「没有自定义设置」。
          bridge.getSettings = function(){
            return Promise.resolve({});
          };
        }
        if (typeof bridge.getCacheDirectory !== 'function') {
          // 页面读的是 `o?.path` / `o.isDefault`，给同形状的空目录。
          bridge.getCacheDirectory = function(){
            return Promise.resolve({ path: '', isDefault: true });
          };
        }
      } catch (e) {}
      // **把桥提前到 document-start 就挂上。**
      //
      // 线上页在启动阶段就会算音源可用性（`mx()` 检查 `window.electron.qishuiRequest`
      // 是否为函数），而 `installQishuiBridge()` 要等 `didCommit` 之后才注入。
      // 这里先放一个「每次调用都回 network 错误」的同形状实现：万一页面抢在前面调用，
      // 拿到的是 `{ok:false,error:{…}}` 这种合法结果，而不是 `undefined`。
      // 真实现随后由 `installQishuiBridge()` 覆盖。
      if (typeof bridge.qishuiRequest !== 'function') {
        bridge.qishuiRequest = function(){
          return Promise.resolve({ ok: false, error: { code: 'network', message: 'qishui bridge not ready' } });
        };
      }
      window.electron = bridge;
      window.__foliaBridge = bridge;
    })();
    """

    /// 二维码回传通道（重建 WebView 时要重新指向新实例）。
    private var qrRelay: QRFallbackRelay?

    /// 本次启动是否已经真的弹过赞赏窗。
    ///
    /// 内容进程被系统回收后壳会重建 WebView，新文档的 `window.__foliaDonateInstalled`
    /// 又变回 undefined，首屏就绪时就会再弹一次 —— 用户看到的就是「弹两次」。
    /// 这里用进程内标记跨文档去重，App 冷启动时自然复位。
    private var donateShownThisLaunch = false

    /// 按配置造一个 WKWebView，并把导航/UI 代理与外观一次性设好。
    ///
    /// `setUp()` 与 `rebuildWebView()` 共用：两处原先各写一遍这段设置，
    /// 漏一项就表现为「重建后的页面和原来不是同一个行为」。
    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let view = WKWebView(frame: bounds, configuration: configuration)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isOpaque = false
        view.backgroundColor = backgroundColor
        view.scrollView.backgroundColor = backgroundColor
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = self
        view.uiDelegate = self
        Self.installUserAgent(on: view)
        return view
    }

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
        webView = makeWebView(configuration: config)
        // 两个回传通道都要拿到 webView：一个往页面塞本地画的二维码，一个做播放意图。
        qrRelay?.webView = webView
        qishuiRelay.webView = webView
        // 原生播放器也要拿到webView，用于回调JS
        NativePlayer.shared.webView = webView

        addSubview(webView)

        reloadObservation = state.$reloadToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hardReload() }

        webView.load(URLRequest(url: Self.launchURL(), cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        // **冷启动也要看门狗。**
        //
        // 早先只有重建那条路（`installRebuiltWebView`）才 `startPageHeartbeat()`，
        // 于是「大退重进 → 进歌单 → 主线程被封面解码卡死」这一路没有任何东西
        // 能发现进程还在、页面却不回话 —— 用户就一直停在加载遮罩上，
        // 只能杀 App 重开。「大退进歌单回加载界面」有一半就是它。
        startPageHeartbeat()
        scheduleProgressWatchdog()

        // 锁屏 / 耳机线控按钮 → 页面播放器。
        remoteObservation = NotificationCenter.default
            .addObserver(forName: .foliaRemoteCommand, object: nil, queue: .main) { [weak self] note in
                guard let action = note.object as? String else { return }
                self?.handleRemoteCommand(action)
            }

        // 内存水位遥测：每 30 秒一条 `mem app=… avail=…`。
        // WebContent 被回收的真正原因（jetsam 还是 WebKit 自崩）壳拿不到，
        // 应用自身的 footprint 与系统剩余额度是唯一能拿到的旁证 ——
        // 下一份日志里把死亡时间戳对上这条曲线，就能判断是不是内存顶死。
        memLogTimer?.invalidate()
        memLogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            CrashLog.note(Self.memoryLogLine())
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

    /// 应用进程内存水位（phys_footprint）与系统剩余额度（os_proc_available_memory），单位 MB。
    private static func memoryLogLine() -> String {
        let availMB = Int(os_proc_available_memory() / 1048576)
        var footprintMB = -1
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        if kr == KERN_SUCCESS {
            footprintMB = Int(info.phys_footprint / 1048576)
        }
        return "==== mem app=\(footprintMB)mb avail=\(availMB)mb ===="
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
        // **先卸掉旧实例，再等它被回收，最后才造新实例。**
        //
        // 重建的触发条件就是「内容进程刚被内存顶死」。如果在这一拍直接新建
        // `WKWebView`，新旧两个进程会在内存最紧张的时刻同时存在（旧进程的尸体
        // 要下一次 runloop 才回收干净），新进程刚起来就可能被系统一并挤掉 ——
        // 用户看到的是「重建完立刻又闪回加载界面」。日志里 3 秒内连挂两次
        // （`web content process terminated (#1)` 打了两次）正是这个。
        // 先解绑观察：`reloadObservation` 持有 sink，sink 里没有 self，
        // 但留着它会在旧实例上继续响应「重试」。
        reloadObservation = nil

        let discarded = webView
        discarded?.stopLoading()
        discarded?.navigationDelegate = nil
        discarded?.uiDelegate = nil
        discarded?.configuration.userContentController.removeAllScriptMessageHandlers()
        discarded?.removeFromSuperview()
        // 解绑后旧实例不再被任何人持有，交给 ARC 在下一轮 runloop 回收。
        webView = nil
        // **停掉旧实例的看门狗。**
        //
        // 心跳脚本打在 `self` 上，而它按定时器每 5 秒问一次页面。
        // 换实例期间若不先停掉，旧那一发 `evaluateJavaScript` 会把回调落到
        // 正在装载的新实例上；一旦新页面 12 秒内还没回话，就会被判「卡死」
        // 再触发一次重建 —— 日志里「刚 reopen 又在同一路由死一次」正是这条路的变体。
        stopPageHeartbeat()
        stopKeepAliveTimer()

        // 重建也是在主线程上跑的：此刻极可能正停在一次触摸事务（`touchesBegan`
        // 到 `touchesEnded`）中间 —— 用户就是点歌单那一拍把进程顶死的。
        // 在这时候把调用链来源的那个 `WKWebView` 从父视图上摘掉，UIKit 会在
        // 同一个 runloop 里继续往它派发结束事件，事件路径指向已卸下的视图，
        // ObjC 层直接抛异常；Swift 接不住，进程当场退出 —— 用户看到的是
        // 「大退进歌单，整个 App 没了」，而不是回到加载界面。
        // 所以换实例这一步一律等当前触摸事务跑完（队列里排到 `touchesEnded` 之后）。
        DispatchQueue.main.async { [weak self] in
            self?.installRebuiltWebView()
        }

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

        // 重建前先记下用户当时所在的那一页：新实例必须回到同一个路由。
        //
        // 「大退进歌单回到加载界面」有一半来自这里 —— 重建后无条件打 `startURL`，
        // 用户明明在歌单上，被扔回首页的加载遮罩，看起来就是闪退。
        //
        // 顺序很重要：这几个地址下面就要被清空，必须在清空**之前**取。
        // 早先把 `let landing` 写在清空之后，读到的永远是 nil，
        // 于是每次都落到 `startURL` —— 日志里的 `rebuild: reopen /` 就是它。
        let landingHistory = pageHistory.reversed().compactMap { Self.trustedSiteURL($0) }.first
        // **重建时的地址优先级：死前那一页 > 首屏确认过的那一页 > 落盘的历史 > 首页。**
        //
        // `lastVisibleURL` 只在「首屏确认过」之后才写，而「大退进歌单」的现场
        // 是首屏还没确认就进了歌单 —— 它那时是空的，重建只能落到首页。
        // `lastCommittedURL` 现在会由终止回调补记死前地址（以及 `didFinish` /
        // `markVisiblePageIfNeeded` 在 SPA 路由切换时补记），所以它最能代表
        // 「用户正在看的那一页」。日志里 `rebuild: reopen /` 就是它缺位的结果。
        let lastKnown = Self.trustedSiteURL(lastCommittedURL)
            ?? Self.trustedSiteURL(deadLandingURL)
            ?? Self.trustedSiteURL(lastVisibleURL)
        // **任何一个候选是「重负载路由」就直接跳过它。**
        //
        // 日志 10-30-15Z 第 11-20 行：`deadLandingURL` / `lastCommittedURL` /
        // 落盘历史**全部**指向那个歌单。即便落脚点被降级成了 `#player`，
        // 新实例装载期间只要再触发一次重建（进程再死、看门狗判卡死、用户点重试），
        // 读到的还是同一批地址，于是又把歌单打开一次、再死一次。
        // 所以这里不是「改写落脚点」，而是**逐个剔除**：
        // 凡是被记成顶死过进程的路由，一律不参与落脚点计算。
        func usable(_ url: URL?) -> URL? {
            guard let url, Self.trustedSiteURL(url) != nil else { return nil }
            return Self.isMemoryHeavy(url) ? nil : url
        }
        // **死路由这一轮已经被顶死过，就绝不再把它当落脚点。**
        //
        // 现场（07-23-35Z / 07-23-56Z / 08-00-01Z）：落脚点明明是
        // `#collection/online/netease/playlist/14400331811`，重建后 4-10 秒又被顶死，
        // 用户看到的就是「大退进歌单 → 回到加载界面」。
        //
        // 关键教训：**光把落脚点换掉不够，必须换掉「这个路由」。**
        // 所以这里不看候选源是谁，只看「这个地址是不是刚死过的那个」。
        var landing: URL = usable(lastKnown)
            ?? usable(landingHistory)
            ?? Self.startURL
        // **优先检查deadLandingURL：如果它是#player，直接用它。**
        //
        // 问题场景：lastCommittedURL可能已经被污染成无hash首页（进程死亡时
        // webView.url只剩域名），它不是memory heavy，所以usable返回非nil，
        // 导致landing先被设为无hash首页。但deadLandingURL是我们在死亡回调里
        // 专门设置的，应该更权威。
        if let deadURL = Self.trustedSiteURL(deadLandingURL),
           let fragment = deadURL.fragment,
           fragment.hasPrefix("player") {
            landing = deadURL
        } else if usable(lastKnown) == nil, usable(landingHistory) == nil {
            // 候选全被剔除时，退到`#player`，而不是首页。
            let died = Self.trustedSiteURL(deadLandingURL)
                ?? Self.trustedSiteURL(lastCommittedURL)
                ?? Self.trustedSiteURL(lastVisibleURL)
            if let died, let stable = Self.stableFallback(from: died) {
                landing = stable
            }
        }
        // **新实例从头加载一次，把它自己打开的那一屏重新记下来。**
        //
        // `lastKnown` 有可能是旧进程残留的地址（日志 10-30-15Z 第 20 行：
        // 新实例打开的是 `#player`，报上来的却是歌单）。新页面画出来之后，
        // 保活会把真实地址同步进 `lastVisibleURL`；在此之前，地址位一律以
        // 「这一拍真正要打开的那一屏」为准，避免下一次重建又读到旧值。
        lastCommittedURL = landing
        lastVisibleURL = landing
        // **降级目标不能原地降落。**
        //
        // 日志 09-27-39Z：歌单路由刚顶死进程，降级逻辑把落脚点退回
        // `https://app.folia-api.top/` —— 首页。而用户看到的「回到加载界面」
        // 就是这一屏：首页自己也要重新拉一遍全部脚本和封面，内存再冲一次顶，
        // 于是重建等于没重建。
        //
        // 改成退到**播放器**（`#player`）：那一屏复用已经解出来的音频引擎，
        // 不渲染歌单的封面网格，正是用户想要的「歌还在放」。
        // 只有连播放器都没得退（比如死在播放器本身）才真的回首页。
        //
        // **无条件降级，不再看 `deathCount`。**
        //
        // 日志 10-30-15Z 是这里最关键的一次现场：
        //   11 `rebuild after process death (...#collection/.../14400331811)`
        //   13 `landing ... died before, open stable ...#player`
        //   17 `rebuild: reopen ...#player`
        //   18 `index stamp -`                                           ← 连 index 都没回来
        //   19 `route death recorded: ...#collection/.../14400331811`     ← 还是歌单
        //   20 `web content process terminated (#1) url=...#collection/.../14400331811`
        // 新实例打开的确实是 `#player`，可 3 秒后又「死在歌单上」，而且又是 `(#1)`。
        // 这只有一种解释：**进程压根没打开新页面**，死亡回调是旧实例残留的那一发；
        // 或者新实例被别处（落盘历史 / 旧地址位）又送回了歌单。
        // 不管是哪一种，结论一样：`deathCount` 这个「60 秒内死过一次」的判据不可靠 ——
        // 它读的是落盘时间，而落盘那一拍可能被上一次启动的残留污染。
        // 现在改成**只要候选路由是可降级的路由，无条件降级**：
        // 进程死过一次之后，壳不去猜「是不是巧合」，直接走最轻的那一屏。
        if let stable = Self.stableFallback(from: landing) {
            landing = stable
        }
        // **把那个死路由从所有候选源里抹掉，而不只是改写落脚点字符串。**
        //
        // 上一层算出来的 `landing` 是安全的，但 `lastCommittedURL` /
        // `lastVisibleURL` / 落盘的 `pageHistory` 里仍旧留着歌单地址。
        // 新实例装载期间**任何一次**重建（进程再死一次、看门狗判卡死、用户点重试）
        // 都会重新从这些地址位里读落脚点，于是又把歌单打开一次、再死一次 ——
        // 用户看到的就是「怎么弄都回到加载界面，删了重下也一样」。
        // 日志 10-30-15Z 第 19-20 行就是这一发：新实例刚开 `#player`，
        // 3 秒后报出来的死路由仍然是歌单。
        //
        // **必须在这一行之前取地址位。** 下面第 622 行会把这两位改写成 `landing`，
        // 之后再读就成了 `#player`，真正死掉的歌单反而漏记 —— 那正是
        // 「新实例开 `#player`、3 秒后又死在歌单」的另一半原因。
        let doomed = Self.trustedSiteURL(deadLandingURL)
            ?? Self.trustedSiteURL(lastCommittedURL)
            ?? Self.trustedSiteURL(lastVisibleURL)
        // **只驱逐会话（`routeDeath`，60 秒窗），不永久标记重负载。**
        //
        // 这里只知道「要重建时地址位指向这个路由」，并不知道它真的顶死过进程 ——
        // 重建也可能是看门狗判卡死、用户点重试、`hardReload` 触发的。
        // 早先这一行是 `markMemoryHeavy`，落在 `UserDefaults` 里且只能被
        // `markVisiblePageIfNeeded` 洗掉：于是用户正常进一次歌单、恰好碰上重建，
        // 这个歌单就被永久判成重负载。真正的「顶死过」由
        // `recordRouteDeath`（进程终止回调里）负责。
        if let dead = doomed, Self.stableFallback(from: dead) != nil {
            Self.forgetVisibleRoute(dead)
            Self.noteRouteDeath(dead)
        }
        if let history = landingHistory,
           history.absoluteString != landing.absoluteString,
           Self.stableFallback(from: history) != nil {
            Self.forgetVisibleRoute(history)
        }
        CrashLog.note("==== landing sources: committed=\(lastCommittedURL?.absoluteString ?? "-") visible=\(lastVisibleURL?.absoluteString ?? "-") dead=\(deadLandingURL?.absoluteString ?? "-") → \(landing.absoluteString) ====")
        // **重建的落脚点必须是「壳说了算」。**
        //
        // 计算出来的 `landing` 只是壳想打开的那一屏；页面在启动头几秒会把
        // 持久化过的路由恢复回去（folia(12).log：12:48:51 重建打开的是 `/`，
        // 12:48:55 死亡地址又变回同一个歌单）。所以把这一屏直接编进 document-start
        // 脚本钉住，而不是指望页面老实待着。
        config.userContentController.addUserScript(WKUserScript(
            source: Self.pinnedLandingScript(landing.fragment),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        deadLandingURL = nil

        didReachFirstPaint = false
        consecutiveLoadFailures = 0
        stallRetries.removeAll()
        isShowingOfflineCopy = false
        wakeReloadTried = false
        // 新实例还没有提交过任何文档：上一次那个地址属于旧进程。
        // 先留一份给 `landing` 用，再清。
        lastCommittedURL = nil
        lastVisibleURL = nil
        // **地址位立刻立成新实例真正要打开的那一屏。**
        //
        // 日志 10-30-15Z：不清回来时，新实例装载期间任何一次重建读到的都是旧值，
        // 于是又把歌单打开一次。`landing` 已经过 `usable()` 过滤与无条件降级，
        // 是这一拍能活下来的那一屏，地址位跟着它走最安全。
        lastCommittedURL = landing
        lastVisibleURL = landing
        consecutiveAutoReloads = 0
        state.clearLoadFailure()
        state.leaveOfflineCopy()
        // 新实例要重新开始「首屏还没画出来」的判定：不清掉的话看门狗一挂上就
        // 看到旧的「已就绪」，进程真被回收时反而没人兜底。
        documentFinished = false

        // 重建时**允许命中缓存**，不要 `.reloadIgnoringLocalCacheData`。
        //
        // 重建的触发条件就是「进程刚被内存压力顶死」。此时再强制绕开缓存，
        // 新进程必须把所有脚本、封面、可视化引擎重新下载并重新解码一遍，
        // 内存曲线在刚起来的那几秒直接冲顶 —— 结果就是刚重建好、用户一进歌单
        // 又被压死，形成「一进歌单就闪退」的死循环。
        // 用 `.useProtocolCachePolicy` 复用磁盘上已经有的资源，
        // 又因为新进程池本身是干净的，不会把旧进程的坏状态带过来。
        if previousWantsAudible {
            wantsAudible = true
            userPaused = false
        }

        pendingRebuild = (config, landing)

        if previousWantsAudible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                // **用户在这 3 秒里亲手按了暂停就不要再补放。**
                // 早先这个块只看 `previousWantsAudible`（3 秒前的快照），
                // 用户按下暂停后它照样把歌放起来 —— 「点了暂停自己又响」。
                guard self.wantsAudible, !self.userPaused else { return }
                self.forceResumeAudio(reason: "rebuild-after-crash")
            }
        }
    }

    /// 待安装的重建参数：等到触摸事务结束、旧实例回收之后再造新实例。
    ///
    /// 单独存一份而不是闭包捕获，是为了让「一次触摸里连挂两次」只装一次：
    /// 后一次会把前一次的地址覆盖掉，不会出现两个实例同时挂到视图上。
    private var pendingRebuild: (config: WKWebViewConfiguration, landing: URL)?

    /// 进程死掉那一拍记下的「用户当时在看的那一页」。
    ///
    /// 只给紧接着的那一次重建用：重建一旦装上就清掉，不会污染之后的重开目标
    /// （用户随后可能自己换了页面）。
    private var deadLandingURL: URL?

    /// 跨实例累计的进程终止时刻。
    ///
    /// `contentProcessRestarts` 是实例状态，`rebuildWebView` 一换实例就归零，
    /// 所以「刚重开 3 秒又死」这件事只有静态的这份数得出来。
    /// 撞线后重建前会清一次 IndexedDB（见 `installRebuiltWebView`）。
    private static var recentTerminations: [Date] = []

    /// 在新一轮 runloop 里把重建后的实例装上并打开 `landing`。
    private func installRebuiltWebView() {
        guard let pending = pendingRebuild else { return }
        // 这一拍里又发生过一次重建（`webView` 已经被别人装上了）：让位。
        //
        // **必须先判空再清 `pendingRebuild`。** 早先顺序是反的：先 `nil` 再
        // `guard webView == nil`，让位那一次把整份重建参数扔掉了 —— 而这一拍
        // `webView` 非空只说明「有实例」，不说明「这个实例装过页面」
        // （`hardReload` 那条路会建实例，但装载请求在另一个延迟块里）。
        // 结果就是既没装载、也没人再来装载，用户对着空白壳等。
        guard webView == nil else { return }
        pendingRebuild = nil
        // **落脚点必须带哈希路由。** 日志 07-23-35Z 第 13 行、07-23-56Z 第 14/24/34 行
        // 全是 `rebuild: reopen /` —— 地址位里明明是
        // `#collection/online/netease/playlist/14400331811`，落到的却是首页：
        // `URL.path` 对哈希路由恒等于 `/`，打印出来会掩盖真实落脚点。
        // 这里改成打完整地址，后面的现场才判断得了「是不是又回到了死掉的那一屏」。
        CrashLog.note("==== rebuild: reopen \(pending.landing.absoluteString) ====")
        // **装上新实例的同时就把地址位立到落脚点。**
        //
        // 日志 10-30-15Z 第 19-20 行：新实例明明打开的是 `#player`，
        // 3 秒后却报「死在歌单上」。那时 `lastCommittedURL` / `lastVisibleURL`
        // 还留着旧进程的值，任何一次重建都会读到它。这里在装载这一刻重设一次，
        // 让「地址位」与「屏幕上真正打开的那一屏」始终是同一件事。
        lastCommittedURL = pending.landing
        lastVisibleURL = pending.landing
        let view = makeWebView(configuration: pending.config)
        webView = view
        addSubview(view)
        // 新实例的 message handler 需要重新挂上（`makeConfiguration` 里已经建了新的
        // `WKUserContentController`，但二维码回传那条要拿到新的 webView 引用）。
        qrRelay?.webView = view
        qishuiRelay.webView = view
        // 原生播放器也要更新webView引用
        NativePlayer.shared.webView = view
        // **重开 3 秒又死的连环：先把 IndexedDB 清一遍再打开。**
        //
        // 日志 10-25-10Z → 10-25-13Z：重建明明打开 `#player`，3 秒后又死在
        // 那份歌单上，地址位也确实变成了 `#collection/...`。
        // bundle 里没有任何路由持久化（没有 zustand persist、没有 route 相关的
        // localStorage key），唯一能把启动拉回歌单一屏的是 IndexedDB 里的
        // 「上次播放 / 队列 / 歌单缓存」（`useSessionRestoreController` 的
        // `getFromCache('last_song')`）。所以连死两次就清这一份：
        // cookie 不碰（登录态保住），只是让启动期没有重现场可恢复。
        let burst = Self.recentTerminations.count >= 2
        let landing = pending.landing
        let open = {
            _ = view.load(URLRequest(url: landing,
                                     cachePolicy: .useProtocolCachePolicy,
                                     timeoutInterval: 30))
        }
        if burst {
            CrashLog.note("==== death burst: purging indexeddb before reopen (terminations=\(Self.recentTerminations.count)) ====")
            view.configuration.websiteDataStore.removeData(
                ofTypes: [WKWebsiteDataTypeIndexedDBDatabases],
                modifiedSince: .distantPast
            ) {
                // 旧进程的尸体要下一轮 runloop 才回收：再等 1.5 秒，
                // 让两份 WebContent 不要在同一拍里重叠（重叠那几秒的整机内存最紧）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { open() }
            }
        } else {
            open()
        }
        // **这一轮死亡连击到此为止：账本清零，下一段安静期重新数。**
        //
        // 不清的话，「60 秒内死 2 次」的账会一直挂着，下次任何一次正常重建
        // （比如看门狗误判）都会再触发一遍 IndexedDB 清洗。
        if Self.recentTerminations.count >= 2 {
            Self.recentTerminations.removeAll()
        }
        startPageHeartbeat()
        scheduleProgressWatchdog()
    }

    // MARK: - 页面主线程看门狗

    /// 页面主线程卡死（不是进程被回收）的事件端口。
    ///
    /// 歌单页把 WebProcess 顶死有两种表现：
    /// 1. 进程被系统回收 —— 有 `webViewWebContentProcessDidTerminate` 回调；
    /// 2. **主线程自己卡死**（一次性解码几百张封面，同步布局几十秒）—— 进程还在，
    ///    没有任何回调，壳这边看起来「页面活得好好的」。
    ///
    /// 日志 09-59-19Z 是第二种的变体：进程被回收了，但新页面在 `#player` 上
    /// 迟迟不画、也不回调。两种情况壳都必须自己发现，不能等页面施舍一个事件。
    private var hbGeneration = 0
    private var hbLastBeat = Date()
    private var pageHeartbeat: Timer?

    /// 上一次「页面无响应 → 强制重建」的时刻。
    ///
    /// 重建要新建一个 WebContent 进程，而旧进程的尸体要等下一轮 runloop 才回收；
    /// 内存最紧的那几秒里两份页面同时存在，系统会直接回收整个 App —— 用户看到的
    /// 就是「闪退」。2026-11-05 的日志里两次重建相隔 61 秒，第二次之后 App 没了。
    /// 页面无响应不等于进程死了：一次性解码几百张封面本来就会占住主线程十几秒，
    /// 这种时候该等它自己缓过来，而不是把整页推倒重来，所以同一轮里只允许一次。
    private var lastUnresponsiveRebuild: Date?

    /// 每 5 秒问页面一句「还活着吗」，连续 20 秒没有回音才按卡死处理。
    ///
    /// 时间窗原来取 12 秒，但日志里首页在正常使用中也会被判成无响应 ——
    /// 歌单封面批量解码、雾笺预计算这类同步任务经常超过 12 秒，误判一次就要
    /// 重建一次，重建本身就可能是闪退的直接原因。20 秒把常见的大任务排除掉，
    /// 真正卡死的情况最多多等 8 秒。
    private static let heartbeatInterval: TimeInterval = 5.0
    private static let heartbeatDeadline: TimeInterval = 20.0

    private func startPageHeartbeat() {
        // 页面看门狗已退役。它是「后台 JS 挂起 → evaluateJavaScript 超时不回 →
        // 误判页面卡死 → 强制重建 → 用户回到加载界面」的源头。页面还活着靠
        // webViewWebContentProcessDidTerminate 这一个信号就够，不需要它再捅一刀。
        return
    }

    private func stopPageHeartbeat() {
        pageHeartbeat?.invalidate()
        pageHeartbeat = nil
    }

    private func pageHeartbeatTick() {
        guard let webView else { return }
        // **后台不算卡死。**
        //
        // 进后台后 WebKit 会挂起该页的脚本执行，`evaluateJavaScript` 的回调十几秒都不回来。
        // 上一版因此把一次正常的后台停留记成「页面无响应 20 秒」，然后在后台把整个
        // WebView 重建 —— 用户切回来看到的就是加载界面（folia(6).log 16:08:36 那一笔，
        // 前一行正是 `background capture idle`）。只有 App 在前台，回调不来才算真卡死。
        guard UIApplication.shared.applicationState == .active else {
            hbLastBeat = Date()
            return
        }
        // 页面还没提交过任何文档（首屏加载中）时不计时：那时卡在网络上很正常。
        guard lastCommittedURL != nil else {
            hbLastBeat = Date()
            return
        }
        // **先按时限判一次，再发这一拍。**
        //
        // 早先判断写在「发心跳」之后，且用的是同一拍刚拿到的 `hbLastBeat`：
        // 一旦有一发回调永远不来（进程还在、主线程卡死正是这样），
        // `hbLastBeat` 就冻住不动，从那一刻起**每一个 5 秒周期**都会判一次超时
        // 并重建一次 —— 每趟重建都要 3-4 秒装载，用户看到的就是
        // 「进歌单 → 黑一下 → 加载界面 → 黑一下 → 加载界面」，永远回不来。
        // 现在超时那次处理完就重置基准并重置代数，让旧回调全部作废，
        // 新实例重新计时。
        if Date().timeIntervalSince(hbLastBeat) >= Self.heartbeatDeadline {
            hbLastBeat = Date()
            hbGeneration += 1
            // **同一轮里只重建一次。**
            //
            // 页面无响应多半是它自己在做大任务（批量解码封面、预计算歌词笔画），
            // 这时重建等于把正在干的活连同整个进程扔掉重来，而且新旧两份进程
            // 会同时占内存。日志里两次重建相隔 61 秒、第二次之后 App 被系统回收 ——
            // 那一次才是用户说的「闪退」。第一次超时照旧重建；如果重建完 120 秒内
            // 又超时，就只记一笔继续等，让页面自己缓过来（定时器仍在跑，
            // 过了这个窗口再超时才会重新重建）。
            if let last = lastUnresponsiveRebuild,
               Date().timeIntervalSince(last) < 120 {
                CrashLog.note("==== page unresponsive, rebuild throttled ====")
                return
            }
            lastUnresponsiveRebuild = Date()
            CrashLog.note("==== page unresponsive for \(Int(Self.heartbeatDeadline))s, force rebuild ====")
            let dead = Self.trustedSiteURL(lastVisibleURL) ?? Self.trustedSiteURL(lastCommittedURL)
            if let dead {
                Self.recordRouteDeath(dead)
            }
            deadLandingURL = dead
            documentFinished = false
            didReachFirstPaint = false
            hasEvaluatedFirstPaint = false
            stopKeepAliveTimer()
            let resume = !userPaused && (wantsAudible || Self.wasAudibleInBackground)
            rebuildWebView(resumeAudio: resume)
            return
        }
        hbGeneration += 1
        let gen = hbGeneration
        webView.evaluateJavaScript("'alive'") { [weak self] result, _ in
            guard let self, gen == self.hbGeneration else { return }
            if (result as? String) == "alive" {
                self.hbLastBeat = Date()
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
        UserDefaults.standard.removeObject(forKey: Self.routeDeathKey)
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
        if webView == nil {
            // 重建还在异步路上：那一路已经会打 `startURL` 并挂上看门狗，这里不能再走一遍，
            // 否则会拿到两次并发加载。
            rebuildWebView(resumeAudio: false)
            return
        }
        webView.load(URLRequest(url: Self.startURL,
                                cachePolicy: .reloadIgnoringLocalCacheData,
                                timeoutInterval: 30))
        startPageHeartbeat()
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
        // 页面其实还在（只是唤醒探测没回来）：只能用「原地重开」，
        // 打 `startURL` 会把用户手上的歌单整页换成首页加载遮罩。
        let alive = isOnSitePage && documentFinished && pageLooksAlive()
        if !wakeReloadTried && !isShowingOfflineCopy {
            wakeReloadTried = true
            wakeRecoveryInFlight = true
            if alive {
                CrashLog.note("==== foreground wake: page alive, reload in place ====")
                reloadInPlace(after: "foreground-wake")
                return
            }
            didReachFirstPaint = false
            // 重建是异步的：这一拍可能手上没有实例（旧实例已卸、新实例还没装）。
            // 对 nil 调 `load` 什么都不发生，用户就永远停在加载界面。
            guard let container = webView else {
                wakeRecoveryInFlight = false
                rebuildWebView(resumeAudio: resume)
                return
            }
            // 这一次是「唤醒重载」，不是用户主动要重来：把看门狗也重开，
            // 但**不能**因此把「本次启动见过首屏」这条事实抹掉 —— 那是判断
            // 「页面是不是真的死了」的唯一依据，抹掉后下面那个 8 秒兜底
            // 会在页面其实已经正常的情况下照样跑一次重建。
            container.load(URLRequest(url: Self.startURL,
                                      cachePolicy: .reloadIgnoringLocalCacheData,
                                      timeoutInterval: 30))
            scheduleProgressWatchdog()
            // 页面上本来就有内容（曾被判死只是探测失败）：给足时间让这份文档
            // 自己画回来，别在 8 秒后无脑重建 —— 重建会把用户手上的歌单整页丢掉。
            let hadContent = reachedFirstPaintOnce
            // 八秒后若已经换过实例（这期间进程挂了、重建过一次），这次兜底必须作废：
            // 新实例可能正好好地在打开落脚点，再重建一次就是无缘无故把页面换掉。
            let armed = ObjectIdentifier(container)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let self, !self.didReachFirstPaint else { return }
                guard let current = self.webView, ObjectIdentifier(current) == armed else {
                    CrashLog.note("==== foreground wake 8s fallback dropped (webview replaced) ====")
                    return
                }
                // 原来就有内容的页面，允许它在更长时间里自己画回来，绝不重建。
                guard !hadContent else {
                    CrashLog.note("==== foreground wake: page had content, keep waiting (no rebuild) ====")
                    return
                }
                CrashLog.note("==== foreground wake: reload did not paint, rebuilding ====")
                // 持久存储：换新实例已足够清掉坏状态，不能把登录态也清了。
                self.rebuildWebView(resumeAudio: resume, cleanStore: false)
            }
            return
        }
        rebuildWebView(resumeAudio: resume)
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
        // 重建是**异步**的（旧实例要先卸掉、回收，下一轮 runloop 才建新的）。
        // 这段空窗里的任何调用都拿不到实例，直接说「没有可打开的目标」，
        // 由调用方改走重建 —— 对着 nil 调 `load` 什么都不会发生，页面就永远停在加载界面。
        guard webView != nil else {
            CrashLog.note("==== reload in place skipped (no web view) (\(reason)) ====")
            return false
        }
        if isShowingOfflineCopy, let indexURL = Self.offlineIndexURL {
            CrashLog.note("==== reload offline copy in place (\(reason)) ====")
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
            scheduleProgressWatchdog()
            return true
        }

        // **死前记下的地址优先，`webView.url` 只作兜底。**
        //
        // 日志 05-13-29Z 第 11 行 `rebuild: reopen /` 的来源：进程被顶死的那一拍
        // `webView.url` 已经退成 `https://app.folia-api.top/`（只剩域名、没有哈希路由），
        // 而 `deadLandingURL` 里明明是完整的
        // `#collection/online/netease/playlist/14400331811`。
        // 早先这里先取 `webView.url`，于是新实例打开的是首页，用户回到加载界面。
        let current = Self.trustedSiteURL(lastCommittedURL)
            ?? Self.trustedSiteURL(deadLandingURL)
            ?? Self.trustedSiteURL(webView.url)
        // **进程已经死过就绝不再判「页面还活着」。**
        //
        // `pageLooksAlive()` 的三条判据（`documentFinished` / `isLoading` / 5 秒内有无终止）
        // 约束的都是壳手上的标记，不是 WebContent 进程本身：进程死掉之后
        // `isLoading` 常常立刻变回 false，`documentFinished` 只要被别处重新置真
        // （`didFinish` 晚一拍、唤醒探测补记）这套判据就齐了，于是这里返回 true，
        // 壳记一句 `reload in place skipped (page alive)` 就再没人打开页面。
        // 真机两轮日志里两次进程死亡都撞在这里，用户看到的就是「回到加载界面」。
        let justDied = contentProcessRestarts.last.map { Date().timeIntervalSince($0) < 5 } ?? false
        let target: URL
        if let current, current.scheme == "https", current.host == Self.siteHost {
            // 页面还在时**不** `webView.reload()`：那是一次完整文档重载，
            // 用户看到的仍是加载遮罩闪一下，歌单与播放状态全部丢掉。
            if documentFinished, !justDied, pageLooksAlive() {
                CrashLog.note("==== reload in place skipped (page alive) (\(reason)) ====")
                markVisiblePageIfNeeded()
                return true
            }
            // 文档还在下载（进程刚被回收、正在重开的那一拍）：直接重载最快。
            CrashLog.note("==== reload in place \(current.path) (\(reason)) ====")
            didReachFirstPaint = false
            documentFinished = false
            hasEvaluatedFirstPaint = false
            // **一律用 `load(URLRequest)`，绝不用 `webView.reload()`。**
            //
            // 进程被回收后，`webView.url` 仍残留着死前那个地址，但那个文档已经不在
            // 任何进程里了。`reload()` 只对「当前进程里已有文档」有效，这一拍调它
            // 等于什么都没做 —— 日志里的 `reload in place skipped (page alive)
            // (repeat-death)` 之后页面一直停在加载界面，就是它。
            // 显式 `load` 同一地址是唯一能真正把文档重新拉起来的做法。
            webView.load(URLRequest(url: current,
                                    cachePolicy: .useProtocolCachePolicy,
                                    timeoutInterval: 30))
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

    /// 页面这一拍是否真的还活着。
    ///
    /// 只用于「进程刚被回收、壳正要决定要不要重新打开」这类一拍内的决策。
    ///
    /// 不能靠 `evaluateJavaScript` 同步等结果：它的回调也排在主线程上，
    /// 在主线程里阻塞等待等于自己等自己。所以改用立刻可得的信号：
    /// 1. 手上有没有一份**完整的**文档（`documentFinished`）；
    /// 2. 有没有「刚刚」发生过进程终止（5 秒内）；
    /// 3. 是否正在下载新文档（`webView.isLoading`）。
    ///
    /// 有任一条不成立，就不能当成「页面好好地活着」。
    private func pageLooksAlive(now: Date = Date()) -> Bool {
        // 还没拿到过任何一份完整文档：谈不上「活着」。
        guard documentFinished else { return false }
        if webView.isLoading { return false }
        if let last = contentProcessRestarts.last,
           now.timeIntervalSince(last) < 5 { return false }
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
        // 重建空窗期没有实例：那一路会自己重新加载，这里不能对 nil 调 `loadFileURL`。
        // 探测要排在这条 guard 之前：没有实例的时候正是「最该等着回线上」的时候。
        scheduleOnlineProbe()
        guard let container = webView else { return }
        container.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        scheduleProgressWatchdog()
    }

    /// 离线副本上每隔几秒探一次线上，通了就自动切回去。
    ///
    /// 见 `onlineProbeTimer` 的说明：冷启动时的假性断网会被判成「线上不可用」，
    /// 而离线页停在启动遮罩上，用户以为 App 卡死了。12 次 × 5 秒 ≈ 1 分钟足够覆盖
    /// 用户从看加载界面到自己动手操作的那段时间。
    private func scheduleOnlineProbe() {
        onlineProbeTimer?.invalidate()
        onlineProbeAttempts = 0
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.isShowingOfflineCopy else {
                timer.invalidate()
                return
            }
            // 离线页正在出声（本地曲库）：换页会打断播放，这一拍先探，不切。
            self.onlineProbeAttempts += 1
            guard self.onlineProbeAttempts <= 12 else {
                CrashLog.note("==== offline probe gave up after 12 tries ====")
                timer.invalidate()
                return
            }
            guard !self.wantsAudible else { return }
            self.probeOnlineOnce()
        }
        onlineProbeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func probeOnlineOnce() {
        var request = URLRequest(url: Self.startURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            guard error == nil, status < 400 else { return }
            DispatchQueue.main.async {
                guard self.isShowingOfflineCopy, !self.wantsAudible else { return }
                CrashLog.note("==== offline probe ok (status \(status)), hopping back online ====")
                self.onlineProbeTimer?.invalidate()
                self.onlineProbeTimer = nil
                self.hardReload()
            }
        }
        task.resume()
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
            // **地址先采，判据后看。**
            //
            // 日志 05-13-29Z：这次启动首屏从没被采到（`reachedFirstPaintOnce` 为假），
            // 用户点进歌单后进程被顶死，死前 UI 侧记下的地址是
            // `#collection/online/netease/playlist/14400331811`，可壳手上
            // `lastCommittedURL` / `lastVisibleURL` 全空，重建只能落到首页 ——
            // 用户看到的就是「大退进歌单回到加载界面」。
            // 所以每条唤醒路径都先采一次地址（不依赖首屏判据），再决定要不要走恢复。
            self.refreshPageLocation()
            if !self.reachedFirstPaintOnce, self.lastCommittedURL == nil {
                // 采地址是异步的，这一拍 `lastCommittedURL` 仍是旧的：照样往下判活，
                // 真没页面时 `recoverAfterForegroundWake()` 会重开；
                // 采回来的地址会让那一次重开落在用户原来的歌单上。
                self.probePageLiveness(thenRecover: true)
                return
            }
            self.probePageLiveness(thenRecover: false) { [weak self] loaded in
                guard let self, loaded else { return }
                // **页面显示什么，就以什么为准。**
                //
                // 「本次启动见过首屏」在下面两种场景里是过期的：用户从抖音回本 App 时
                // WKWebView 接着加载了那边的落地页、或者进程被回收后壳走了一次「原地重开」。
                // 前者此时页面上根本不是我们的播放器，后者还在下载第一份文档 ——
                // 只按历史标记判断会漏掉这两种「真的是空页面」的情况。
                // 确认页面上真的是一份挂好内容的站内文档：不然后面的「进程死亡、
                // 一进歌单就退回加载界面」会被当成死页面，白走一遍重开。
                self.markVisiblePageIfNeeded()
            }
        }
    }

    /// 采一次「页面现在停在哪个地址」，供进程被回收后原样重开。
    ///
    /// 与 `markVisiblePageIfNeeded` 的分工：那个要等首屏判据（`#root` 有内容）成立，
    /// 所以在大退重进、首屏还没确认的那段时间里什么都不记；这个只看地址与体量，
    /// 只要页面上已经挂了内容就记。
    ///
    /// 为什么必须单独有一条：歌单是 pushState 路由，主框架不重新提交，
    /// `didCommit` / `didFinish` 都不会再触发；而 `webView.url` 在进程死亡那一拍
    /// 已经只剩域名。所以「用户正在看哪一页」只能靠每隔一会儿问一次页面补上。
    private func refreshPageLocation() {
        guard let container = webView else { return }
        // **每一拍都先把「要不要提前降载」判出来，且不受下面任何门控影响。**
        //
        // 原先这一拍只有在页面「已经画出来、body 还有子节点」时才执行（下面的 `guard`），
        // 而歌单详情顶死进程恰好发生在那条路判断成立之前 —— 日志里地址采到了，
        // 降载开关却一次都没被设上。现在判断只看地址（`location.href` 在加载中也拿得到），
        // 一旦落在「顶死过进程」的详情路由上，就先挂降载再看别的。
        Self.applyLowMemoryProbe(to: container)
        // **每一拍先把「主框架现在停在哪」记下来。**
        //
        // 下面那段 JS 要求 `body` 已经有子节点才肯记地址，可它恰恰在最需要的时候失效：
        // 进程被顶死前的那几秒、以及死掉那一拍，JS 要么打不回来、要么 `body` 已经空。
        // 日志 08-00-01Z / 08-01-45Z 里，「死前那一页」明明就是
        // `#collection/online/netease/playlist/14400331811`，`landing sources`
        // 里却一个地址都没有，最后落到 `/`。哈希路由不会触发 `didCommit`，这一路要是不记，
        // 就没有别的地方记得到。只在页面**已经画出来之后**才采，避免把首屏的
        // `startURL` 当成用户所在页面。
        //
        // **这个值不可信，绝不能用来覆盖地址位。**
        //
        // `WKWebView.url` 在 SPA 哈希路由切换之后仍然只返回不带 hash 的 `/`
        // （pushState / hashchange 都不产生新的导航），所以这里读到的是一个
        // 「丢了路由的残值」。日志 10-31-12-10-33Z 第 41 行刚同步过
        // `.../playlist/14400331811`，第 47/48 行同一份运行里重建出来的
        // `landing sources` 却全是 `/` —— 就是被这一拍覆盖回去的。
        // 唯一保留的用途：页面从没记到过任何地址时，至少有个站内地址可用。
        if reachedFirstPaintOnce,
           lastVisibleURL == nil,
           let live = Self.trustedSiteURL(container.url) {
            CrashLog.note("==== page location seeded \(live.absoluteString) ====")
            lastVisibleURL = live
            lastCommittedURL = live
        }
        // 回调里除了地址，还要求页面**已经画出来**（`firstPaintProbeScript` 不返回 loading）。
        //
        // 日志 05-13-29Z 的现场：这一次启动首屏从没被采到，随后进程被顶死，
        // 重建落到首页 —— `markVisiblePageIfNeeded` 不会给看门狗豁免，
        // 看门狗 30 秒到点判「卡在首屏」，又整页重载一次，用户看到的就是
        // 「进歌单 → 回到加载界面」。所以地址与「首屏已交付」必须在这一拍同时立起来。
        container.evaluateJavaScript(
            "(function(){return [String(location.href), (document.body ? document.body.children.length : 0)].join('|');})()"
        ) { [weak self, weak container] rawResult, _ in
            guard let self, let container, container === self.webView,
                  let raw = rawResult as? String else { return }
            let parts = raw.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, (Int(parts[1]) ?? 0) > 0,
                  let url = URL(string: String(parts[0])),
                  let trusted = Self.trustedSiteURL(url) else { return }
            // 进程刚死的那一刻这份页面已经不在，`body` 子节点为 0 会直接返回；
            // 只有活着的页面才会走到这里，所以这里记下的就是「用户正在看的地址」。
            if trusted != self.lastCommittedURL {
                CrashLog.note("==== page location captured \(trusted.absoluteString) ====")
            }
            self.lastCommittedURL = trusted
            self.lastVisibleURL = trusted
            self.rememberVisibleURL(trusted)
            
            container.evaluateJavaScript(Self.firstPaintProbeScript) { [weak self, weak container] phase, _ in
                guard let self, let container, container === self.webView else { return }
                guard ((phase as? String) ?? "loading") != "loading" else { return }
                // **重负载标记加长稳定期，不轻易清除。**
                //
                // 问题：歌单页面内存大，即使刚打开时没崩溃，播放一段时间后也可能
                // 因为内存累积而崩溃。如果刚打开10秒就清除标记，下次再打开又会崩溃。
                // 现在延迟60秒，并且确认页面还在同一个路由才清除。
                // 优先保证不闪退，用户要正确率优先。
                let paintedURL = trusted
                DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self, weak container] in
                    guard let self, let container, container === self.webView else { return }
                    // 确认60秒后页面还在同一个路由，没有导航走，也没有崩溃
                    container.evaluateJavaScript(
                        "(function(){return String(location.href);})()"
                    ) { [weak self] currentURL, _ in
                        guard let self, let current = currentURL as? String,
                              current == paintedURL.absoluteString else { return }
                        // 60秒后还在这个路由，说明这个机型能扛住，才清除标记
                        CrashLog.note("==== route stable for 60s, clearing memory-heavy flag: \(paintedURL.absoluteString) ====")
                        Self.clearMemoryHeavy(paintedURL)
                    }
                }
                Self.clearRouteDeath(trusted)
                self.reachedFirstPaintOnce = true
                self.markFirstPaintSettled()
            }
        }
    }

    /// 把「这一屏要不要降载」推给页面，并落到 `window.__foliaLowMemory` /
    /// `data-folia-low-memory` 两位上（线上页以后要读，直接就有）。
    ///
    /// 与地址采集解耦：只看 `location.href`，页面还在加载、`body` 还是空的时候也能判。
    /// 这正是「进歌单 8 秒就死」那个时间窗 —— 等页面画出来再降载就来不及了。
    private static func applyLowMemoryProbe(to container: WKWebView) {
        let js = """
        (function(){
          try {
            var heavy = \(memoryHeavyLiteral());
            var here = String(location.href);
            var isHeavy = false;
            for (var i = 0; i < heavy.length; i += 1) {
              if (heavy[i] && here.indexOf(heavy[i]) === 0) { isHeavy = true; break; }
            }
            window.__foliaLowMemory = isHeavy;
            var root = document.documentElement;
            if (!root) { return isHeavy; }
            if (isHeavy) { root.setAttribute('data-folia-low-memory', '1'); }
            else { root.removeAttribute('data-folia-low-memory'); }
            // 把内存收紧落到图片上：重负载路由给封面挂 `loading="lazy"`，
            // 屏幕外的不请求、不解码（见 `audioKeeperScript` 里的 `__foliaTuneImages`）。
            if (typeof window.__foliaTuneImages === 'function') { window.__foliaTuneImages(isHeavy); }
            return isHeavy;
          } catch (e) { return false; }
        })();
        """
        container.evaluateJavaScript(js) { result, _ in
            guard let heavy = result as? Bool, heavy else { return }
            // 只在真的判成重负载时打一行，避免每条路由切换都刷日志。
            CrashLog.note("==== low memory mode on (route is memory heavy) ====")
        }
    }

    /// 把「当前这份已经画出来的站内文档」记下来，供进程被回收后原样重开。
    ///
    /// 判据见 `firstPaintProbeScript`：只认「还在加载」与「根本没挂上」，
    /// **不认** SPA 内部再出现一次的加载遮罩。
    private func markVisiblePageIfNeeded() {
        let container = webView
        container?.evaluateJavaScript(Self.firstPaintProbeScript) { [weak self, weak container] result, _ in
            guard let self, let container, container === self.webView else { return }
            let phase = (result as? String) ?? "loading"
            guard phase != "loading" else { return }
            // 只负责「首屏已交付」这一位；真实地址由 `refreshPageLocation` 的 JS
            // （读 `location.href`）负责 —— `container.url` 在 SPA 路由下不含 hash。
            if self.lastVisibleURL == nil, let url = Self.trustedSiteURL(container.url) {
                self.lastVisibleURL = url
                self.lastCommittedURL = url
            }
            self.reachedFirstPaintOnce = true
            // 画出来了，顺手再判一次降载：回前台这条路只走这里，不走 `refreshPageLocation`。
            Self.applyLowMemoryProbe(to: container)
            self.markFirstPaintSettled()
        }
    }

    /// 首屏到底画出来没有 —— 三条判据，返回 `loading` / `empty` / `ready`。
    ///
    /// 为什么不能只看 `#app-splash` 是否存在：线上站的加载遮罩在**路由内部加载**时
    /// 还会再挂出来一次（进歌单、切歌词都会）。于是「用户已经在歌单里正常听着歌」
    /// 也会被判成首屏没完成，`reachedFirstPaintOnce` 一直是假，30 秒看门狗到点
    /// 直接 `retryLoadForStall()` —— 用户看到的就是「进歌单回到加载界面」。
    ///
    /// 现在区分两种「有遮罩」：
    /// - 文档还在加载（`readyState === 'loading'`）→ 真的没画出来；
    /// - 遮罩还在，但 `#root` 已经挂上内容 → 页面本身已经画出来了，遮罩只是
    ///   路由切换时又露出一次；
    /// - `#root` 空且没有遮罩 → 悬空的白页，算没起来。
    ///
    /// 只有「文档已加载完、`#root` 一个子节点都没有、遮罩也还在」才算真的没起来。
    private static let firstPaintProbeScript = """
        (function(){
          try {
            if (document.readyState === 'loading') { return 'loading'; }
            var root = document.getElementById('root');
            if (root && root.children.length > 0) { return 'ready'; }
            var splash = document.getElementById('app-splash');
            if (!splash) { return 'empty'; }
            return 'loading';
          } catch (e) { return 'ready'; }
        })();
        """

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
        guard let container = webView else {
            // 重建还没装上新实例：没有可问的页面。
            if recover { recoverAfterForegroundWake() }
            return
        }
        container.evaluateJavaScript("1+1") { [weak self] result, error in
            guard let self else { return }
            if error != nil || result == nil {
                CrashLog.note("==== wake probe failed: no response from page ====")
                if recover { self.recoverAfterForegroundWake() }
                return
            }
            // `1+1` 能答只说明 JS 引擎还在；页面剩下空壳时同样是「点了没反应」，
            // 再确认一次挂载点是不是还在。
            container.evaluateJavaScript(
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
        stopPageHeartbeat()
        // block 型观察者不会随 self 释放自动注销，留着会在下一次通知时回调到已释放对象上。
        let tokens: [Any?] = [remoteObservation, foregroundObservation, backgroundObservation, networkObservation, audioPathObservation, audioPathRebuiltObservation]
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
            // 从抖音这类 App 回来时，页面很可能在离开期间被系统按停过一次，
            // 随后上报了 `intent-pause`。那一拍 `userPaused` 可能已经被置真，
            // 若不清掉，下面所有以 `!userPaused` 为门的恢复全部不会执行 ——
            // 用户看到的就是「界面在放、进度在走、一点声都没有」。
            // 只有「用户亲手暂停」才该保留，而那种情况页面不会在离开期间被系统按停。
            if self.wasBackgroundedThisSession, self.wantsAudible {
                self.userPaused = false
                self.pendingPauseCheck = false
            }
            // 回前台这一拍先同步一次「该响」：会话控制器要用它决定补不补通路。
            // 必须排在容器自己那轮异步探测之前 —— 那一轮走 JS 往返，会晚几百毫秒。
            AudioSessionController.shared.wantsAudible = self.wantsAudible && !self.userPaused
            // 同一份意图也同步给会话控制器的 `isPlaying`。
            //
            // 它原本只由页面的播放状态上报推进，而进后台/被抖音按停时页面会如实报
            // `paused`，`isPlaying` 于是变成假。`rebuildAfterPreemption()` /
            // `rebuildPathQuietly()` 的守卫是 `isPlaying || backgroundedAndPlaying || wantsAudible`，
            // 前两位在这一拍都可能为假，只靠 `wantsAudible` 撑着 —— 而它依赖上面那行
            // 刚刚同步过去的时机。这里补上，保证「离开过 App 且该响」这一轮
            // 通路重建不会因为会话层自己的一方状态被静默跳过。
            if self.wantsAudible, !self.userPaused {
                AudioSessionController.shared.updatePlaybackState(true)
            }
            // **马上再声明一次抢占**，不要等会话控制器那一轮异步复核。
            //
            // 用户从抖音回来时，对方 App 的会话通常还没被系统淡出，
            // `isOtherAudioPlaying` 在这一拍仍是真；会话控制器的 `didBecomeActive`
            // 一旦读到它就不再执行 `rebuildPathQuietly()`，而这条判断之后没有任何补救 ——
            // 页面那侧 `<audio>` 仍报 playing、AudioContext 仍是 running，
            // 下面 `probeThenRecover` 的几条判据全都显示「通路健康」，一格都不动。
            // 结果就是「切回来界面在放、进度在走、一点声音都没有」。
            // 这里只**记账**，不动手：真正要不要 `setCategory` 交给 `probeThenRecover`
            // 在「恢复之后仍然没声」时才决定。
            //
            // 早先这一句会直接把 `preemptedByOtherApp` 置真，而 `probeThenRecover`
            // 的处理是无条件 `recoverAudioPathPass` → `setCategory` + `setActive`。
            // `setCategory` 一定会让 WebKit 把媒体元素按停一次，于是每次从抖音回来
            // 都要先断一下再补回来；补不回来（上下文还停在 `interrupted`）就一直是
            // 「界面在放、进度在走、没有声音」。真实日志里这条被反复触发，
            // 也正是「进抖音再回来没声音」始终修不掉的原因。
            if self.wasBackgroundedThisSession, self.wantsAudible, !self.userPaused {
                self.preemptedByOtherApp = true
                // 同时记下「这一轮离开还没有任何一次确认过有声」：
                // `probeThenRecover` 的最前面据此**当场**重建一次系统通路，
                // 不再等页面自报（它永远报健康），也不被串行锁耽误。
                self.leftAppWhileAudible = true
            }
            // **会话在离开期间可能已经被系统收走，这里先无条件把它激活。**
            //
            // 用户报的场景是「播放期间进抖音再回来没声音」，而控制中心那一栏仍是本 App 在播 ——
            // 说明播放意图没丢，丢的是系统那一层通路。以前的判据全都要求「页面确实在出声」，
            // 手机背面朝上被按停时页面会如实上报 `paused`，于是所有分支都判「本来就没在放」，
            // 一次 `setActive` 都不做。`ensureActive()` 只补 `setActive`、不重建 category，
            // 通路还活着时是空操作，不会按停任何媒体；真正被收走时它是最便宜的一次尝试。
            //
            // 注意这里刻意**不调 `activate()`**：category 一旦重设，WebKit 的媒体元素
            // 会被当场按停一次，页面随即上报 pause —— 用户听到的就是「切回来歌断一下」。
            // 只有确认被别家 App 抢过（上面那条 `preemptedByOtherApp`）才允许重建通路，
            // 那一步交给会话控制器的 `healIfPreempted()`。
            if self.wantsAudible && !self.userPaused {
                AudioSessionController.shared.ensureActive()
            }
            // **不要无条件重建音频通路！**
            //
            // 之前这里只要用户离开过App且还在播放，就调用rebuildAfterPreemption()，
            // 也就是setCategory。这会重建音频通路，WebKit的媒体元素会被当场按停一次。
            // 这就是为什么用户说"进入抖音后回来没声音"——我们自己把歌按停了！
            //
            // 正确做法：只做一次幂等的setActive，不重建category。
            // 真正的通路重建交给探针：它会先检查，确认确实没声了才重建。
            if self.wasBackgroundedThisSession, self.wantsAudible, !self.userPaused {
                self.leftAppWhileAudible = true
            }
            // 回前台时立即触发一次探针，确认音频状态
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
        // **通路重建的那一拍，页面一定会报一次 pause，那不是用户收手。**
        //
        // `setCategory` 会让 WebKit 把媒体元素按停（见 `AudioSessionController.reactivate`
        // 的说明），页面随即发 `intent-pause`。日志 05-12-20 第 46 行 → 第 48 行的
        // `paused by user (confirmed)` 就是它：0.35 秒的确认窗口恰好落在重建之后，
        // `audioRecoveryInFlight` 却已经被 `finishAudioRecovery()` 放掉，
        // 于是 `wantsAudible` 被打成假、保活停摆 —— 用户听到的就是「回来一直没声」。
        // 记一个时间窗，`markPausedIntent` 据此直接忽略这一条。
        //
        // **只订一次。** 这里原来每次 `didBecomeActive` 都重新 addObserver，
        // 并且直接覆盖 token —— 旧 token 再没有机会注销，于是每切一次前后台
        // 就多留一个观察者，`pathRebuiltAt` 也会被连着写好几遍。
        if audioPathRebuiltObservation == nil {
            audioPathRebuiltObservation = NotificationCenter.default.addObserver(
                forName: .foliaAudioPathRebuilt,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.pathRebuiltAt = Date()
                CrashLog.note("==== audio path rebuilt, pause events ignored for 2s ====")
            }
        }
        backgroundObservation = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.enteredBackgroundAt = Date()
            // **无条件置真。**
            //
            // 早先它带 `wantsAudible && !userPaused` 的条件：只要页面在离开前自己报过一次
            // pause（`wantsAudible` 被打成假，日志 05-12-20 第 48 行那种），这一条就永远
            // 不置位；回前台时「离开过 App、该复核通路」的所有分支于是全部不成立，
            // 会话层的 `setCategory` 重建一次都不会跑 —— 用户听到的就是
            // 「进抖音再回来，界面在放、进度在走、一点声音都没有」。
            // 它记录的是「离开过 App」这个事实，与当时页面自报什么无关；
            // 真正「要不要动手」由回前台那一刻的探测决定（见 `probeThenRecover`：
            // 页面时钟还在走就一格都不碰，这才是「切出去看一眼回来歌不断」的保证）。
            self.wasBackgroundedThisSession = true
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
            // **递归查找Shadow DOM里的audio元素。**
            function collectAudio(root, out) {
              try {
                var nodes = root.querySelectorAll('audio');
                for (var n = 0; n < nodes.length; n += 1) { out.push(nodes[n]); }
                var all = root.querySelectorAll('*');
                for (var i = 0; i < all.length; i += 1) {
                  if (all[i].shadowRoot) {
                    collectAudio(all[i].shadowRoot, out);
                  }
                }
              } catch (e) {}
            }
            var list = [];
            collectAudio(document, list);
            for (var i = 0; i < list.length; i += 1) {
              var el = list[i];
              if (!el.src || el.paused) { continue; }
              // 记下「进后台前真正在出声的那一个 deck」。
              // 双 deck 交叉淡化时另一个 deck 也是 paused + 有 src，
              // 回前台补活若拿不到这个指针，就会挑错元素（爆音 / 无声）。
              window.__foliaLastAudio = el;
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
    /// NativePlayer 原生播放器在收到 cmd=play 时也会走这里同步意图。
    func markAudibleIntent() {
        // **用户亲手按了播放，这一轮「离开过 App」的账就到此为止。**
        //
        // 早先刻意不清它，理由是「离开过是事实」。但事实已经用完 —— 用户现在的
        // 动作明确表达了「我要它响」，此后页面再报 pause 就是他自己的事。
        // 不清的代价在帧率上看得见：这一位此后一直为真，`confirmPausedIntent`
        // 与 `markPausedIntent` 里所有以它为门的判断都永久放行，用户亲手按的暂停
        // 永远认不下来（`paused by user (confirmed)` 再也不会出现），保活继续每 2 秒
        // `play()` 一次 —— 用户看到的就是「点了暂停过一会儿自己又唱」。
        wasBackgroundedThisSession = false
        wantsAudible = true
        userPaused = false
        pendingPauseCheck = false
        // 用户亲手点播放：清掉补放节流，保证下一次自动兜底立刻生效。
        lastResumeAttempt = nil
        // 用户亲手开始放：之前那次「被别的 App 抢占」的账已经无关，别再重复重建通路。
        preemptedByOtherApp = false
        // 同理：用户亲手点播放，就是「这一轮离开过 App」的欠账已经不再需要壳去兜底。
        // 不清的话，下一次从抖音回来会先白重建一次通路（听感上就是断一下）。
        leftAppWhileAudible = false
        // **用户亲手点播放就是这一轮已经收尾的唯一凭据，所以这一位必须在这里清。**
        //
        // 早先刻意不清（注释说的是「离开过是事实」），代价是它从此恒为真：
        // `confirmPausedIntent` / `markPausedIntent` 里所有以它为门的判断永久放行，
        // 用户之后亲手按的暂停一律认不下来，保活每 2 秒把歌放回去一次。
        // 需要保留的只是「离开期间系统摘走通路」这一个短暂窗口，
        // 它由 `stayedBackgroundedWhileAudible` / `preemptedByOtherApp` 表达。
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
    /// - Parameter reason: 非 nil 表示这条暂停是**原生自己发起的**（锁屏 / 耳机 /
    ///   控制中心的远程命令），不需要再问页面二次确认 —— 用户明确按了按钮，
    ///   页面自报的 `intent-pause` 只是回执。页面自发上报时传 nil，走原来的确认链。
    ///   NativePlayer 收到 cmd=pause 时也会走这里同步意图（reason="native-pause"）。
    func markPausedIntent(reason: String? = nil) {
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
        // 刚从后台回来、或者刚被别的 App 抢过：页面这一拍报的 pause 一律不信。
        //
        // `stayedBackgroundedWhileAudible` 只在回前台那一拍被清掉，而抖音这类 App
        // 会把系统通路摘走好几秒，期间页面会陆续报几条 pause。只要「本次启动见过首屏」
        // 且离开过 App，就不该把 `userPaused` 置真 —— 一旦置真，
        // `recoverAudioPath` 顶层守卫会拦掉整条恢复链，用户听到的就是「一点声都没有」。
        if preemptedByOtherApp || wasBackgroundedThisSession {
            // 例外：原生自己发起的暂停（锁屏 / 耳机）不受这一条约束 ——
            // 那是用户在锁屏上明确按的，不是抖音摘通路抖出来的 pause。
            if reason == nil {
                CrashLog.note("==== pause ignored (preempted / just back from background) ====")
                return
            }
        }
        // **刚重建过通路（2 秒内）：这条 pause 是 `setCategory` 按停媒体元素造成的。**
        //
        // 这是「进抖音再回来一直没声」的最后一道漏洞：重建通路那一步必然让
        // WebKit 把正在响的媒体按停一次，页面如实发 `intent-pause`；
        // 而它出现时 `audioRecoveryInFlight` 可能已经被收尾放掉，
        // 0.35 秒的确认于是把它当用户收手，`wantsAudible` 永久为假。
        if let rebuiltAt = pathRebuiltAt, Date().timeIntervalSince(rebuiltAt) < 2 {
            // 远程命令同理：锁屏上按的暂停，哪怕恰好落在通路重建的 2 秒窗里也算数。
            if reason == nil {
                CrashLog.note("==== pause ignored (right after audio path rebuild) ====")
                return
            }
        }
        // 原生自己发起的暂停：用户明确按了按钮，直接认账。
        //
        // 早先这条路径只改 `wantsAudible`，`userPaused` 从不置真 —— 于是
        // 「锁屏暂停 → 进程被系统回收 → 重建」时 `resume` 判成真，歌自己又响。
        if reason != nil {
            userPaused = true
            stopKeepAliveTimer()
            wantsAudible = false
            preemptedByOtherApp = false
            leftAppWhileAudible = false
            stayedBackgroundedWhileAudible = false
            Self.wasAudibleInBackground = false
            AudioSessionController.shared.notePlaybackStopped()
            CrashLog.note("==== paused by user (\(reason ?? "")) ====")
            return
        }
        // 先记账，等页面把「我到底是不是真的停了」报回来再决定，见 `confirmPausedIntent()`。
        //
        // **记账时就同时记下这一拍有没有恢复/清理在跑。**
        //
        // 日志 05-12-20（第 46 行 → 第 48 行）的现场：容器刚打完
        // `audio path preempted by another app, rebuilding path (pending)`，
        // 0.6 秒的静音确认还没回来，这时页面报了一次 pause（就是恢复动作自己引发的），
        // 记账 -> 0.35 秒后再确认时 `audioRecoveryInFlight` 已被 `finishAudioRecovery()`
        // 放掉，于是判成 `paused by user (confirmed)`，`wantsAudible=false`、
        // `wasBackgroundedThisSession=false`，整条恢复链被永久锁死 —— 用户听到的就是
        // 「从抖音回来界面在放、进度在走、一点声音都没有」。
        // 串行锁是**异步**的，不能等到 0.35 秒之后再看；必须按「这条 pause 出现的那一刻
        // 有没有恢复在跑」来判。
        pendingPauseCheck = true
        pendingPauseDuringRecovery = audioRecoveryInFlight
            || preemptedByOtherApp
            || stayedBackgroundedWhileAudible
        confirmPausedIntent()
    }

    /// 页面明确告诉壳：这一次暂停是用户亲手按的（见 `ios-native-audio.js` 的 `notifyUserPause`）。
    ///
    /// 不再走 `confirmPausedIntent` 那条「按最近一次触摸去猜」的链：
    /// 实测不可靠 —— 日志里用户明明按了暂停，`gestureAge` 却是 83 秒，
    /// 这一拍被判成「不是用户」，`wantsAudible` 留了下来；20 秒后切后台，
    /// 续播链又把歌放起来（用户听到的就是「暂停后退出后台还在放」）。
    /// 这里只换成可靠信号，例外一条不少：恢复在跑、刚重建通路、刚被别家 App 抢过，
    /// 都仍然不认账，避免把「从抖音回来没声」那条旧病重新放出来。
    fileprivate func markUserPauseFromPage() {
        guard UIApplication.shared.applicationState == .active else { return }
        // **用户点暂停 = 最高优先级：把正在进行的一切音频恢复动作全部取消。**
        //
        // 日志 23-02-08Z：shell 试图自动恢复播放（audio recovery），页面返回 busy，
        // shell 就保持 `audioRecoveryInFlight=true` 等待重试；这时用户点暂停却被挡在
        // guard 外面，两个 pause 事件（intent-pause-user + 常规 pause）全部被忽略，
        // 续播链留着 wantsAudible=true 进了后台，歌继续放 —— 正是用户报的
        // 「暂停后退出后台会继续播放」。
        // audio recovery / preempted / pathRebuild 都是**壳的判断**，用户的手是**事实**。
        if audioRecoveryInFlight || audioRecoveryPending || preemptedByOtherApp || stayedBackgroundedWhileAudible {
            CrashLog.note("==== user pause cancels in-flight audio recovery ====")
            audioRecoveryInFlight = false
            audioRecoveryPending = false
            preemptedByOtherApp = false
            stayedBackgroundedWhileAudible = false
        }
        if let rebuiltAt = pathRebuiltAt {
            CrashLog.note("==== user pause (after audio path rebuild \(Int(Date().timeIntervalSince(rebuiltAt)))s ago) ====")
            pathRebuiltAt = nil
        }
        pendingPauseCheck = false
        pendingPauseDuringRecovery = false
        userPaused = true
        stopKeepAliveTimer()
        wantsAudible = false
        leftAppWhileAudible = false
        // 用户已经收手，这一轮「离开过 App」的欠账全部结清：
        // 否则下一次进后台，续播链仍会按旧账把歌放回去。
        wasBackgroundedThisSession = false
        Self.wasAudibleInBackground = false
        AudioSessionController.shared.notePlaybackStopped()
        CrashLog.note("==== paused by user (page button) ====")
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
            self.webView?.evaluateJavaScript("(function(){try{return String(window.__foliaUserGestureAge ? window.__foliaUserGestureAge() : 999999)}catch(e){return '999999'}})()") { gesture, _ in
                guard self.pendingPauseCheck else { return }
                let gestureAge = Double((gesture as? String) ?? "999999") ?? 999999
                // 先停掉这一轮的确认，再决定是不是「用户收手」。
                self.pendingPauseCheck = false
                // 这一条 pause 出现的那一刻，恢复/清理正在跑：它一定是恢复动作自己
                // 引发的（`setCategory` 会让 WebKit 把媒体元素按停一次），不是用户收手。
                defer { self.pendingPauseDuringRecovery = false }
                guard !self.pendingPauseDuringRecovery else {
                    CrashLog.note("==== pause not by user (recovery in flight at pause time) ====")
                    return
                }
                // **没有用户手势的这一拍 pause 一律不算用户收手。**
                //
                // 系统掐断（切后台、别的 App 抢通路、锁屏）绝不会伴随触摸；
                // 页面自建播放器树、切歌、AudioContext 被挂起也都无手势。
                // 真实日志里出现过「抖音抢占 → 误报 paused by user (confirmed)
                // → 恢复链永久锁死」，就是缺这一条。手势龄不可用时也按「非用户」处理：
                // 宁可多放一回，也不能把恢复链永久锁死。
                guard gestureAge < 1.5 else {
                    CrashLog.note("==== pause not by user (gestureAge=\(Int(gestureAge))) ====")
                    return
                }
                // **页面其实还在放：这条 pause 是系统/页面自己的一次抖动，**
                // 绝不能把播放意图打成假。日志里 `pause not by user` 之后紧接着
                // 4 秒的 `intent audible (state=0)` 空窗，就是这里太早认账。
                if self.preemptedByOtherApp || self.stayedBackgroundedWhileAudible {
                    CrashLog.note("==== pause not by user (path recovering) ====")
                    return
                }
                // **还得再问页面一句：现在到底还有没有在播。**
                //
                // 只靠手势龄不够。日志 05-12-20 的现场是：
                //   1. `intent audible (state=2)` + `foreground resume done (audible=1)`；
                //   2. 2 秒后 `paused by user (confirmed)` —— 用户根本没碰屏幕，
                //      是恢复过程本身（`setCategory` / `setActive` / 补 `play`）
                //      让页面把 deck 按停了一次，`pause` 事件随之从页面报上来；
                //   3. 于是 `wantsAudible` 被打成假，保活与整条恢复链一起停摆，
                //      用户听到的就是「回来以后界面在放、进度在走、一点声音都没有」。
                // 页面自报暂停的这一刻，只要还有一条 `<audio>` 带着源没播完，
                // 就说明播放器自己没停，这次的 pause 不是用户收手。
                // **恢复过程自己引发的 pause，不能算用户收手。**
                //
                // 日志 05-12-20：第 46 行容器刚打完「抢占，重建通路」，
                // 第 48 行就出现 `paused by user (confirmed)` —— 用户根本没碰屏幕，
                // 是 `setCategory` / `setActive` 把 deck 按停了一次。
                // 恢复进行中（串行锁还握着、或刚发过抢占/后台恢复）时，pause 一律放过。
                if self.audioRecoveryInFlight || self.preemptedByOtherApp
                    || self.stayedBackgroundedWhileAudible || self.wasBackgroundedThisSession {
                    CrashLog.note("==== pause not by user (recovery in flight) ====")
                    return
                }
                self.hasPlayableAudio { playable in
                    guard self.pendingPauseCheck == false else { return }
                    if playable, self.wantsAudible {
                        CrashLog.note("==== pause ignored (page still has queued audio) ====")
                        return
                    }
                    self.userPaused = true
                    self.stopKeepAliveTimer()
                    self.wantsAudible = false
                    self.preemptedByOtherApp = false
                    // 用户亲手停了：这一轮「离开过 App」的欠账也随之作废。
                    self.leftAppWhileAudible = false
                    // 会话层那本「离开期间在放」的账也一并结掉，否则回前台还会白重建通路。
                    AudioSessionController.shared.notePlaybackStopped()
                    // **这里刻意不清 `wasBackgroundedThisSession`。**
                    //
                    // 保留它的原因：之后若再从别的 App 回来，`probeThenRecover` 里
                    // 「离开过就别轻信页面自报暂停」这条判据还得在。
                    // 它的收尾点只有 `markAudibleIntent`（用户亲手点了播放）。
                    self.stayedBackgroundedWhileAudible = false
                    CrashLog.note("==== paused by user (confirmed, gestureAge=\(Int(gestureAge))) ====")
                }
            }
        }
    }

    /// 页面上是否还有「带着源、没播完」的音频元素。
    ///
    /// 只读 DOM。用来区分「用户亲手暂停（所有 deck 都停了）」与
    /// 「恢复过程让页面抖了一下（播放器自己还挂着一首歌）」。
    private func hasPlayableAudio(_ completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
          try {
            // **递归查找Shadow DOM里的audio元素。**
            function collectAudio(root, out) {
              try {
                var nodes = root.querySelectorAll('audio');
                for (var n = 0; n < nodes.length; n += 1) { out.push(nodes[n]); }
                var all = root.querySelectorAll('*');
                for (var i = 0; i < all.length; i += 1) {
                  if (all[i].shadowRoot) {
                    collectAudio(all[i].shadowRoot, out);
                  }
                }
              } catch (e) {}
            }
            var list = [];
            collectAudio(document, list);
            for (var i = 0; i < list.length; i += 1) {
              var el = list[i];
              var elSrc = el.currentSrc || el.src;
              if (elSrc && !el.ended) { return true; }
            }
            // 线上站没有 `<audio>`（纯 WebAudio）：按页面自报的播放事实判断，
            // 否则这一层在线上站恒为 false，「恢复过程抖出来的 pause」会被认成
            // 用户亲手暂停，把恢复链整条锁死。
            var st = 'none';
            try {
              var ms = navigator.mediaSession;
              st = ms && ms.playbackState ? ms.playbackState : 'none';
            } catch (e) {}
            if (st === 'none' && window.__foliaPlaybackState) { st = window.__foliaPlaybackState; }
            if (st === 'playing') { return true; }
            var ctx = window.__foliaAudioContexts || [];
            for (var c = 0; c < ctx.length; c += 1) {
              if (ctx[c] && ctx[c].state === 'running') { return true; }
            }
            return false;
          } catch (e) { return false; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            completion((result as? Bool) ?? false)
        }
    }

    /// 有待确认的暂停意图。
    private var pendingPauseCheck = false
    /// 记账那一条 pause 时，恢复/清理是否正在跑。
    private var pendingPauseDuringRecovery = false
    /// 最近一次「通路重建」的时刻（`.foliaAudioPathRebuilt`）。
    private var pathRebuiltAt: Date?
    /// 通路重建的通知订阅。
    private var audioPathRebuiltObservation: Any?

    private func startKeepAliveTimer() {
        // 用原生播放器后，不需要保活定时器，避免反复触发恢复逻辑干扰原生播放器
        return
        guard keepAliveTimer == nil else { return }
        // 2 秒一拍，而不是 4 秒。
        //
        // 4 秒意味着「歌被掐掉」到「被放回去」最长有 4 秒空窗，用户听到的就是
        // 「切出去音乐断了一下」。这个 timer 绝大多数拍只做一次只读探测
        // （`resumeAudioContexts` 全是读内存里的 context 状态，通路健好时一格不动），
        // 对电量与主线程的影响可以忽略。
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            // **只认「用户亲手暂停」这一条停车条件。**
            //
            // 早先守卫是 `wantsAudible, !userPaused`，而 `wantsAudible` 会被页面的一次
            // `intent-pause` 打成假（日志 05-12-20 第 48 行 `paused by user (confirmed)`
            // 之后就是这一种）。那一拍之后保活彻底停摆，再没有任何一条路把歌放回去 ——
            // 用户听到的就是「从抖音回来，界面在放、进度在走、一点声音都没有」。
            // 现在守卫只看 `userPaused`，页面暂停时由 `resumeAudio()` 补一次 `play()`；
            // `userPaused` 只在用户真的点了暂停时置真（带手势龄与可播元素双重确认）。
            guard let self, !self.userPaused else { return }
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
            // **每一拍顺手记一次地址。**
            //
            // 歌单 / 歌词是哈希路由，主框架不重新提交，`didCommit` / `didFinish` 都不会再来，
            // 而进程被顶死时 `webView.url` 只剩域名（日志 05-13-29Z 第 11 行
            // `rebuild: reopen /`）。没有这条周期性采集，「死前用户在哪个歌单」
            // 就只有回前台那一拍碰运气才能拿到。
            self.refreshPageLocation()
            // 保活**只允许补放，不允许改播放意图**。
            //
            // `enforcePlaybackIfNeeded` 在 `!wantsAudible` 时会把意图硬置回真，
            // 这是给「页面被系统掐停」留的后路，但保活是每 2 秒一拍的常驻循环：
            // 一旦哪一拍 `wantsAudible` 已经被判成假（而 `userPaused` 恰好还没立起来），
            // 它就会把歌重新放起来 —— 用户看到的就是「点了暂停，过一会儿自己又唱」。
            // 意图的恢复只在回前台 / 后台那两拍做（见 `didBecomeActive` / `didEnterBackground`）。
            guard self.wantsAudible else { return }
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
        guard !userPaused else { return }
        // 页面自己报过暂停（但那一次不是用户收手）：先补 `play()` 把意图立起来，
        // 再走探测。不补的话 `recoverAudioPath` 顶层守卫会把整条恢复链拦掉，
        // 而保活已经是唯一还在跑的恢复路径了。
        if !wantsAudible {
            // **用户亲手按过暂停，绝不把「该响」再立起来。**
            //
            // folia(6).log 16:09:45 用户按暂停（`paused by user (page button)`，
            // `userPaused=true`、`wantsAudible=false`），16:09:50 一进后台，
            // 恢复链走到这里时 `userPaused` 还在（顶层 `guard !userPaused` 看的是它），
            // 而下面的 `resumeAudio` 没有再看一次 —— 于是页面已经停住、
            // 原生播放器（AVPlayer，独立进程）却被页面的 play 入口重新叫醒，
            // 用户听到的就是「暂停后退出后台，歌又自己放起来」。
            guard !userPaused else { return }
            wantsAudible = true
            AudioSessionController.shared.updatePlaybackState(true)
            CrashLog.note("==== audible intent restored (\(reason)) ====")
        }

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
    private func resumeAudioContexts(_ completion: @escaping (String) -> Void) {
        let js = """
        (function(){
          try {
            if (typeof window.__foliaResumeAudioContexts === 'function') {
              window.__foliaResumeAudioContexts();
            }
            var list = window.__foliaAudioContexts || [];
            // 把壳的播放意图告诉页面：纯 WebAudio 页面既没有 `<audio>`、
            // 也常常不写 `playbackState`，没有这一位就只能一路判成 `no-elements`。
            window.__foliaWantsAudible = \(wantsAudible && !userPaused ? "true" : "false");
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
              live += 1;
              if (c.state !== 'running') { bad += 1; }
            }
            // **一个都没记到 → `unknown`，不是 `running`。**
            //
            // 线上页把 AudioContext 留在闭包里，`__foliaAudioContexts` 经常是空的。
            // 早先这里：报 `none` → 调用方再串两条跨进程查询，一次恢复要三四拍；
            // 后来改成报 `running` → 调用方直接 `finishAudioRecovery()` 收工，
            // 于是「该响却没响」的那些拍一格都不动。两种都不对。
            // 现在把「不知道」如实报上去，由调用方按页面自己的媒体事实判断
            // （见 `probeThenRecover` 里 `unknown` 那条分支）。
            // **一个都没记到 → 再问一次页面自己的事实。**
            //
            // 线上站的播放引擎是纯 WebAudio，`document.querySelectorAll('audio')`
            // 恒为空（我在产物里扫过 `bootstrap` / `drumHits` / `three` 三个包，
            // `audioElem=0`）。于是：
            //   - `resumeAudioContexts` 永远是 `unknown`
            //   - `isMediaHealthy` 永远是 `idle`
            //   - `isPlaybackClockAdvancing` 永远采样不到、报 `false`
            // 三者合起来让恢复链每 2 秒判一次「断了」，`recoverAudioPathPass`
            // 只做 `setCategory` + `setActive`，而真正缺的动作是「让页面自己接着播」。
            // 日志 09-26-18Z 第 13-41 行整整 28 秒就是这个死循环，
            // 直到第 42 行用户亲手点播放（`intent audible`）才有声。
            //
            // 现在把「页面没有任何媒体元素」这件事单独报成 `no-elements`，
            // 由调用方直接走 `resumeAudio` 里那条 `__foliaMediaCommand.play` 通道。
            // 页面的 MediaSession 若是 `playing`，说明它自认为在放 —— 那不是断流，
            // 报 `media-playing` 交给调用方跳过重建，避免白白打断。
            // **优先用__foliaLastAudio，避免每次都遍历整个DOM树。**
            //
            // 之前每次探针都递归遍历整个DOM+Shadow DOM，页面复杂时会卡死12秒。
            // 现在优先用keeper里记录的最后一个audio元素，又快又准。
            var liveMedia = 0;
            var last = window.__foliaLastAudio;
            if (last) {
              var lastSrc = last.currentSrc || last.src;
              if (lastSrc && !last.ended) { liveMedia += 1; }
            }
            // 只有last无效时才做一次轻量查找（不递归Shadow DOM，太慢）
            if (liveMedia === 0) {
              try {
                var nodes = document.querySelectorAll('audio,video');
                for (var i = 0; i < nodes.length; i += 1) {
                  var src = nodes[i].currentSrc || nodes[i].src;
                  if (src && !nodes[i].ended) { liveMedia += 1; break; }
                }
              } catch (e) {}
            }
            if (liveMedia === 0 && list.length === 0) {
              var ms = navigator.mediaSession;
              var st = ms && ms.playbackState ? ms.playbackState : 'none';
              // 页面自己的上报优先。`__foliaPlaybackState` 是 keeper 从
              // `MediaSession.prototype.playbackState` 的 setter 上记下来的，
              // 代表「页面最后一次认为自己处于什么状态」。
              if (st === 'none' && window.__foliaPlaybackState) { st = window.__foliaPlaybackState; }
              // **只有页面真的报过 `playing` 才算健康。**
              if (st === 'playing') { return 'media-playing'; }
              // 如果__foliaLastAudio是null，说明还没开始播放过，不要触发恢复
              if (!window.__foliaLastAudio) {
                return 'no-last-audio';
              }
              return 'no-elements';
            }
            if (live === 0) { return 'unknown'; }
            if (bad > 0) { return 'blocked'; }
            return 'running';
          } catch (e) { return 'unknown'; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            completion((result as? String) ?? "unknown")
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
        // 用原生播放器后，不需要网页音频恢复逻辑，避免干扰原生播放器
        return
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
    /// 判据只用「页面自己这一侧的事实」：还有没暂停的 `<audio>` 却不出声、
    /// AudioContext 不是 running。系统层面的 `secondaryAudioShouldBeSilencedHint`
    /// 不作为判据（`.mixWithOthers` 下它经常为真），见下面恢复段里的说明。
    private func probeThenRecover(reason: String) {
        // **（0）离开过 App、仍该响：直接重建音频通路，不问页面。**
        //
        // 这是"进入抖音后回来没声音"的正确解法。
        // 纯WebAudio页面有个致命问题：currentTime在走，但系统音频通路被收走了，
        // 实际没有声音。页面侧的三项事实（<audio>未暂停、currentTime在推进、
        // AudioContext是running）全部为真，靠探测永远发现不了——
        // 丢的是它们下面那一层系统通路。
        //
        // 所以只要"离开过App + 该响"，就重建一次会话：
        // setCategory会让WebKit把媒体元素按停一瞬间，
        // 但重建之后立即跟一次resumeAudio，用户只会听到短暂的停顿，然后继续播放。
        // 优先保证正确率，不追求不打断。
        if leftAppWhileAudible {
            leftAppWhileAudible = false
            preemptedByOtherApp = false
            stayedBackgroundedWhileAudible = false
            brokenProbeStreak = 0
            CrashLog.note("==== audio path rebuilt on return from background (\(reason)) ====")
            AudioSessionController.shared.rebuildAfterPreemption()
            recoverAudioPathPass(reason: "left-app", attempt: 0)
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
        //
        // **必须排在最前面。** 早先它在 `stayedBackgroundedWhileAudible` 分支之后，
        // 而后者一定会走到（离开过 + 该响就置位），并且只要页面报「在播 + 时钟在走」
        // 就 `finishAudioRecovery()` 收工 —— `preemptedByOtherApp` 于是在这一拍被
        // 悄悄跳过，下一次探测它已被别处清掉，重建通路的那条路一次都没跑过。
        if preemptedByOtherApp {
            preemptedByOtherApp = false
            stayedBackgroundedWhileAudible = false
            brokenProbeStreak = 0
            // **先问页面到底还在不在出声，别一上来就重建。**
            //
            // `setCategory` 会把 WebKit 的媒体元素按停一次 —— 对一条其实完好的通路
            // 做这件事，就是自己把歌打断；而补不回来的那一次，用户听到的是
            // 「回来以后一直没声音」。所以先走一遍最便宜的检查（会话只补
            // `setActive`、上下文只 `resume()`），只有它跑完仍然没声，才动用
            // `setCategory` 重建通路。
            CrashLog.note("==== audio path preempted by another app, verifying (\(reason)) ====")
            AudioSessionController.shared.ensureActive()
            revivePageAudio()
            // **会话侧也要真跑一次修复，不能只补 `setActive`。**
            //
            // 日志 05-12-20 的现场：这里打了 `rebuilding path (pending)`，
            // 紧接着 2 秒后出现 `paused by user (confirmed)` —— 会话侧的
            // `preemptedByOtherApp` 这一拍没置位（`isOtherAudioPlaying` 已经翻回 false），
            // `healIfPreempted()` 于是什么都不做；而这里补完 `setActive` 之后
            // 页面侧的 `playing` 标记又是旧的，判定为「还在响」，整条重建一次都没跑。
            // 现在两边都按同一份播放意图执行，不会再互相抵消。
            AudioSessionController.shared.recoverIfPreempted()
            // **只试一次快速修复，没声就真的重建。**
            //
            // 日志 05-12-20：这里两边的 `setActive` 都成功，`preemptedByOtherApp`
            // 又被各自「用完即清」，于是 `setCategory` 的重建一次都没跑过 ——
            // 页面报「还在响」，用户听到的一直是静音。
            // 所以不能把「没声」交给下一拍保活（`wantsAudible` 可能在同一拍被打成假），
            // 必须在这里隔 0.6 秒一次性给结论：没声就 `rebuildAfterPreemption()`。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.wantsAudible, !self.userPaused else {
                    self?.finishAudioRecovery()
                    return
                }
                self.isMediaHealthy { healthy in
                    guard healthy else {
                        CrashLog.note("==== audio still silent after preemption, rebuilding path (\(reason)) ====")
                        AudioSessionController.shared.rebuildAfterPreemption()
                        self.recoverAudioPathPass(reason: "preempted", attempt: 0)
                        return
                    }
                    // **`__foliaHeard` 不足以证明「这一拍真的在出声」。**
                    //
                    // 保活是 2 秒一拍，而那个节点标记有 5 秒有效期：抖音把系统通路
                    // 摘走之后 5 秒内它一直是真，于是这里判「还活着」直接收工 ——
                    // 用户听到的就是「回来以后界面在放、进度在走、一点声音都没有」。
                    // 抢占这一条必须看时钟：通路被摘走后 WebKit 的媒体时钟同样会停。
                    self.isPlaybackClockAdvancing { advancing in
                        guard advancing else {
                            CrashLog.note("==== audio clock stuck after preemption, rebuilding path (\(reason)) ====")
                            AudioSessionController.shared.rebuildAfterPreemption()
                            self.recoverAudioPathPass(reason: "preempted-stuck", attempt: 0)
                            return
                        }
                        CrashLog.note("==== audio alive after preemption, skip rebuild (\(reason)) ====")
                        self.finishAudioRecovery()
                    }
                }
            }
            return
        }

        // 判据只有两条：页面是否在出声、AudioContext 是否 running。
        // 系统层面的 `isOtherAudioPlaying` / `secondaryAudioShouldBeSilencedHint`
        // 在 `.mixWithOthers` 下经常为真而本 App 完全正常 —— 真实日志里连续 7 次
        // `audio path broken (contextOK=1 silencedHint=1 reason=keepalive)` 就是它，
        // 判成断流 → `setCategory` 按停媒体 → 下一拍再判 → 无限循环。
        // 所以整段判断里不出现任何会话层的是否出声判据。

        // 刚从后台回来、当时正在放：先看页面到底还在不在出声。
        //
        // 为什么单独判这一条：被抖音这类 App 抢过之后，`isOtherAudioPlaying` 在
        // 回到前台那一拍已经翻回 false（对方正在被系统淡出），页面里的 `<audio>`
        // 却仍报 `playing`、AudioContext 也还是 running —— 几个判据全部显示
        // 「通路健康」，实际一点声都没有（丢的是系统那一层通路）。
        // 这条路只在 `preemptedByOtherApp` 没立起来时才会跑到（那一位已经置位的
        // 情况在上面就重建了），所以这里按「页面自报有没有在出声」判：
        // 它说在播就一格都不动（正常切出去看一眼回来仍不断），
        // 说没在播就直接重建一次通路。
        if stayedBackgroundedWhileAudible {
            stayedBackgroundedWhileAudible = false
            // **离开过 App 这一轮，会话侧必须真跑一次修复。**
            //
            // `setActive` 对「被抖音摘走的后台播放资格」不够：系统把我们移出
            // 「正在播放的应用」之后，只有重新声明一次 category 才能要回来。
            // `recoverIfPreempted()` 只在真的失败时才 `setCategory`，
            // 通了的那一拍一格都不动，所以「切出去看一眼回来歌不断」仍然成立。
            AudioSessionController.shared.recoverIfPreempted()
            // 会话可能在这一拍被重新声明：让页面跟着把上下文叫醒。
            revivePageAudio()
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
                        self.leftAppWhileAudible = false
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

        resumeAudioContexts { [weak self] contextState in
            guard let self else { return }

            // 媒体事实先问：离开过 App 这一轮由 `resumeAudioContexts` / `isMediaHealthy`
            // 自己判，绝不能因为「探不出 AudioContext」就收工。
            //
            // **这一条是「进抖音回来没声音」的直接修复。**
            // 线上页把 AudioContext 留在闭包里，`resumeAudioContexts` 永远返回
            // `unknown`；早先这里把 `unknown` 交给 `isMediaHealthy`，而那一位当时要求
            // `window.__foliaHeard` 为真 —— 这个标记只在 `playing` 事件里置位、5 秒过期，
            // 系统中止后媒体被静默续上时根本不再发 `playing`。
            // 于是真实日志里出现连续 7 条
            // `audio probe suspicious, waiting second sample (keepalive)`：每一拍都判
            // 「可疑」，`brokenProbeStreak` 永远到不了 2（`finishAudioRecovery` 之后被别的
            // 调用重置），`recoverAudioPathPass`（唯一会 `setCategory` 重建通路的地方）
            // 一次都没跑过 —— 用户听到的就是「界面在放、进度在走、一点声音都没有」。
            // 现在只要页面自己还挂着未暂停的媒体，就直接看**时钟有没有在走**：
            // 时钟在走 = 通路好，时钟冻住 = 通路真的断了，两种都立刻有结论，
            // 不再依赖那个会过期的标记。
            self.isMediaHealthy { healthy in
                guard healthy else {
                    // 媒体被按停、或页面上没有可播元素：按上下文状态决定。
                    self.handleContextRecovery(contextState: contextState, reason: reason)
                    return
                }
                // 在出声，且 AudioContext 明确 running：通路完好，一格都不碰。
                if contextState == "running" {
                    CrashLog.note("==== audio path healthy, skip rebuild (\(reason)) ====")
                    self.brokenProbeStreak = 0
                    self.leftAppWhileAudible = false
                    self.finishAudioRecovery()
                    return
                }
                // 时钟在走、上下文查不到（闭包内）：同样视为通路完好。
                //
                // 唯一例外是「离开过 App、会话可能已被摘走」那一轮 —— 那种情况
                // 由 `preemptedByOtherApp` / `stayedBackgroundedWhileAudible` 两条
                // 分支先行处理，走到这里说明它们已经判过没有重建的必要。
                self.isPlaybackClockAdvancing { advancing in
                    if advancing {
                        CrashLog.note("==== audio path healthy via clock, skip rebuild (\(reason)) ====")
                        self.brokenProbeStreak = 0
                        self.leftAppWhileAudible = false
                        self.finishAudioRecovery()
                        return
                    }
                    CrashLog.note("==== audio clock stuck, rebuilding path (\(reason)) ====")
                    self.brokenProbeStreak = 0
                    self.recoverAudioPathPass(reason: reason, attempt: 0)
                }
            }
        }
    }

    /// 媒体元素没有在出声时的收尾：按 AudioContext 状态决定恢复还是重建。
    private func handleContextRecovery(contextState: String, reason: String) {
        // **页面自认为在放（纯 WebAudio，没有媒体元素）：一格都不碰。**
        //
        // 这类页面的 `isMediaHealthy` 永远报 `idle`（DOM 里没有 `audio`），
        // 若按「没在出声」处理，保活每 2 秒就会把它打断一次。
        // 页面 MediaSession 报 `playing` 就是「引擎在跑」的事实，直接收工。
        //
        // 同时把「这次离开 App 没有留下出声证据」那一位清掉。
        // 日志 09-57-58Z：第 46-47 行 `audio alive after preemption, skip rebuild`
        // → `audio path healthy, skip rebuild` 已经确认引擎在跑，可下一拍保活
        // 又带着这一位重来一遍，恢复链被反复唤醒、反复 `resume()`。
        // 引擎自己健康的证据比「离开过」这一事实更新，以它为准。
        if contextState == "media-playing" {
            CrashLog.note("==== audio engine running per mediaSession, skip rebuild (\(reason)) ====")
            brokenProbeStreak = 0
            leftAppWhileAudible = false
            preemptedByOtherApp = false
            finishAudioRecovery()
            return
        }
        if contextState == "running" {
            // 上下文活着、时钟也没走：页面这一拍八成在换歌 / 重建播放器树，
            // 交给下一拍保活，别动手。
            CrashLog.note("==== audio silent with running context, retrying later (\(reason)) ====")
            finishAudioRecovery()
            return
        }
        // 还没开始播放过，不要反复尝试恢复
        if contextState == "no-last-audio" {
            CrashLog.note("==== no last audio yet, skip recovery (\(reason)) ====")
            brokenProbeStreak = 0
            finishAudioRecovery()
            return
        }
        // 连续两次判「断」才真去重建。
        //
        // 保活轮询是 2 秒一拍，而 `evaluateJavaScript` 与 `AudioContext.state`
        // 都有一拍延迟：页面正在换页 / 正在 seek / 正在交叉淡化时，
        // 单次探测很容易抓到「media 暂时还没进 playing」的瞬间。
        brokenProbeStreak += 1
        guard brokenProbeStreak >= 2 else {
            CrashLog.note("==== audio probe suspicious, waiting second sample (context=\(contextState) reason=\(reason)) ====")
            finishAudioRecovery()
            // 两拍之间隔一个完整周期（4 秒）再采第二次，不受中断影响。
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self, self.wantsAudible, !self.userPaused else { return }
                self.recoverAudioPath(reason: "\(reason)-second-sample")
            }
            return
        }
        brokenProbeStreak = 0
        CrashLog.note("==== audio path broken (context=\(contextState) reason=\(reason)) ====")
        // **纯 WebAudio 页面：不管上下文状态，直接让页面自己接着播。**
        //
        // 这一类页面（线上站就是）没有 `<audio>` 可 play，`recoverAudioPathPass`
        // 里的 `setCategory` + `setActive` 只修系统那层通路，页面引擎还是停着的。
        // 日志 09-26-18Z 第 13-41 行连续 28 秒都是
        // `audio path broken (context=unknown ...)`，
        // 每拍只重建会话、从没碰过播放引擎，直到用户手动点播放才响。
        if contextState == "no-elements" {
            CrashLog.note("==== pure webaudio page, rebuilding path + page play entry (\(reason)) ====")
            AudioSessionController.shared.ensureActive()
            recoverAudioPathPass(reason: reason, attempt: 0)
            return
        }
        recoverAudioPathPass(reason: reason, attempt: 0)
    }

    /// 页面上的媒体元素是不是「正在正常出声」（没暂停、没结束、有源、时间在走）。
    ///
    /// 只读 DOM，不动任何状态。回前台第一拍 `currentTime` 可能还没推进，
    /// 所以判据只看「有源 + 没暂停 + 没结束」，再加上「音频上下文没被挂起」这一条兜底。
    private func isMediaHealthy(_ completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
          try {
            // 优先用__foliaLastAudio，避免遍历整个DOM树
            var el = window.__foliaLastAudio;
            if (el) {
              var src = el.currentSrc || el.src;
              if (src && !el.ended && !el.paused) { return 'playing'; }
            }
            // 轻量查找
            var nodes = document.querySelectorAll('audio,video');
            for (var i = 0; i < nodes.length; i += 1) {
              var node = nodes[i];
              var src = node.currentSrc || node.src;
              if (src && !node.ended && !node.paused) { return 'playing'; }
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
          // 优先用__foliaLastAudio，避免遍历整个DOM树
          var el = window.__foliaLastAudio;
          if (el) {
            var src = el.currentSrc || el.src;
            if (src && !el.ended && !el.paused) {
              window.__foliaClockT0 = el.currentTime;
              window.__foliaClockEl = el;
              return 'sampled';
            }
          }
          // 轻量查找
          var nodes = document.querySelectorAll('audio');
          for (var i = 0; i < nodes.length; i += 1) {
            var node = nodes[i];
            var src = node.currentSrc || node.src;
            if (src && !node.ended && !node.paused) {
              window.__foliaClockT0 = node.currentTime;
              window.__foliaClockEl = node;
              return 'sampled';
            }
          }
          // **没有 `<audio>` 不代表没在放。**
          //
          // 线上站的播放引擎是纯 WebAudio，`document.querySelectorAll('audio')`
          // 恒为空（见 `resumeAudioContexts` 里同一段说明）。早先这里直接报
          // `idle` → 调用方恒判「时钟没走」，于是回前台的每一处「时钟确认」出口
          // 都白走一遍 `setCategory`，把正在响的媒体按停一次。
          // 现在按页面自报的播放事实兜底：MediaSession 报 `playing`、或记到的
          // AudioContext 里有 running 的，都算「时钟在走」。
          var st = 'none';
          try {
            var ms = navigator.mediaSession;
            st = ms && ms.playbackState ? ms.playbackState : 'none';
          } catch (e) {}
          if (st === 'none' && window.__foliaPlaybackState) { st = window.__foliaPlaybackState; }
          if (st === 'playing') { return 'media-playing'; }
          var ctx = window.__foliaAudioContexts || [];
          for (var c = 0; c < ctx.length; c += 1) {
            if (ctx[c] && ctx[c].state === 'running') { return 'context-running'; }
          }
          return 'idle';
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            // 纯 WebAudio 页面：没有可采样的 `currentTime`，只能按页面自报的状态认定。
            if (result as? String) == "media-playing" { completion(true); return }
            if (result as? String) == "context-running" { completion(true); return }
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

        // 第一趟才补激活会话。`activate()` 内部只在**本进程第一次**真正
        // `setCategory`，之后只补 `setActive` —— 所以这里反复走进来也不会
        // 像以前那样「每拍都把正在响的媒体按停一次」。
        if attempt == 0 {
            AudioSessionController.shared.activate()
        }
        // **系统通路修好之后，页面引擎自己停着也不会出声。**
        //
        // 纯 WebAudio 页面（线上站）的恢复链以前到这里就结束了：只 `setCategory`
        // + `setActive`，从不碰页面播放引擎。日志 09-57-58Z 第 43-50 行
        // 反复 `preempted by another app, verifying` → `silent with running context`
        // 就是这一层：系统通路全绿，页面却一直不响，直到用户手动点播放。
        // 所以每一趟最后都让页面自己补一次播放入口（幂等，正在响时无副作用）。
        resumeAudio(reason: reason)
        // 无论如何都叫醒一次页面上下文：`resume()` 是幂等的，
        // 而日志里 `contextOK=0` 之后恢复链一步都没往前走，就是从这少了一拍。
        revivePageAudio()

        // 等一帧再问上下文状态：`resume()` 是异步的，紧接着问必然是旧的。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.resumeAudioContexts { [weak self] state in
                guard let self else { return }
                // **只有明确 `blocked` 才继续等上下文。**
                //
                // `unknown` 表示页面没把 AudioContext 暴露到 `window` 上（线上页就是这样）。
                // 早先把「查不到」当成「还没起好」，于是这里 150ms 一轮、最多 4 轮，
                // 每轮都只是再问一次同一个查不到的东西 —— 那几百毫秒里页面一直没有声，
                // 用户听到的就是「回来要等两秒才响」。上下文查不到就直接补放，
                // 真有问题由下一拍保活的媒体探测接手。
                if state != "blocked" {
                    // 前面已经调用过resumeAudio了，这里不要再调用第二次
                    // 150ms内两次play()会导致第一次的Promise被abort
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
    ///
    /// **每一次「收工」都要把它归零。** 任何一条提前 return 的分支漏掉归零，
    /// 这个 1 就会一直留到下一次探测：那时只需再 +1 就到 2，
    /// 防抖被整段跳过，单次瞬时抖动就会被判成断流、白重建一次通路。
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
        let heavyRoutes = Self.memoryHeavyLiteral()
        let js = """
        (function(){
          try {
            // **每次都检查当前路由是否是重负载路由，及时切换低内存模式。**
            //
            // 原先只在 `audioKeeperScript` 注入时检查一次，那是页面刚加载时的路由。
            // 用户从首页导航到歌单时路由变了，低内存标志没跟着更新 ——
            // 等歌单渲染到一半内存爆了才闪退。这里（`revivePageAudio`）每拍补一次。
            try {
              var heavy = \(heavyRoutes);
              var here = location.href;
              var isHeavy = false;
              for (var hi = 0; hi < heavy.length; hi += 1) {
                if (heavy[hi] && here.indexOf(heavy[hi]) === 0) {
                  isHeavy = true;
                  break;
                }
              }
              window.__foliaLowMemory = isHeavy;
              var root = document.documentElement;
              if (isHeavy) { root.setAttribute('data-folia-low-memory', '1'); }
              else { root.removeAttribute('data-folia-low-memory'); }
              if (typeof window.__foliaTuneImages === 'function') { window.__foliaTuneImages(isHeavy); }
            } catch (e) {}
            
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

    /// 页面元素（或页面登记的播放入口）**当前是不是正在响**；判断不了时返回 `null`。
    ///
    /// `playEntryJS` 的第三、四级出口会「不管当前状态直接放一下」：元素级要
    /// `paused` 才返回，但它只取第一个媒体元素，双 deck 里可能挑到待命的那一个；
    /// 第四级直接写 `playbackState = 'playing'` 更是无条件。恢复链反复调用时，
    /// 这等于把正在响的歌又 play 一次、把状态位冒充成播放中。
    /// 所以调用方在动手前先用这一句确认：`true` 就跳过，`null` 才按原逻辑兜底。
    private static let playbackBusyJS = """
    (function(){
      try {
        // **递归查找Shadow DOM里的媒体元素。**
        function collectMedia(root, out) {
          try {
            var nodes = root.querySelectorAll('audio,video');
            for (var n = 0; n < nodes.length; n += 1) { out.push(nodes[n]); }
            var all = root.querySelectorAll('*');
            for (var i = 0; i < all.length; i += 1) {
              if (all[i].shadowRoot) {
                collectMedia(all[i].shadowRoot, out);
              }
            }
          } catch (e) {}
        }
        var list = [];
        collectMedia(document, list);
        for (var i = 0; i < list.length; i += 1) {
          var el = list[i];
          var elSrc = el.currentSrc || el.src;
          if (elSrc && !el.ended && !el.paused) { return true; }
        }
        var st = 'none';
        try {
          var ms = navigator.mediaSession;
          st = ms && ms.playbackState ? ms.playbackState : 'none';
        } catch (e) {}
        if (st === 'none' && window.__foliaPlaybackState) { st = window.__foliaPlaybackState; }
        return st === 'playing' ? true : null;
      } catch (e) { return null; }
    })();
    """

    /// 页面「点一下播放」的兜底入口，注入到每一段补放脚本的最前面，定义局部 `__foliaPlay()`。
    ///
    /// 为什么需要兜底：线上站是纯 WebAudio，DOM 里没有 `<audio>`，
    /// 唯一能让引擎重新出声的动作就是「等价于点一次播放按钮」。
    /// 早先只认 `navigator.mediaSession.setActionHandler('play')` 登记的那一个处理器，
    /// 页面没登记就 `noop` —— 日志 10-24-58Z 第 32 行之后 4 分 39 秒静音、
    /// 直到用户亲手点播放（第 33 行）才恢复，正是这条路断在了「找不到入口」。
    ///
    /// 四级顺序：页面登记的处理器 → 页面自己的按钮 → 媒体元素 → 置回播放态。
    ///
    /// **顺序不能反**：线上站的播放按钮是 React 受控组件，`click()` 在
    /// 播放器树被重建后会点到旧节点上静默失效；而 mediaSession 的 `play`
    /// 处理器内部走的是 `mediaSessionPlayRef.current()`，始终指向当前播放器。
    private static let playEntryJS = """
    var __foliaPlay = function(){
      try {
        // 一级：页面通过 setActionHandler('play') 登记的真实入口。
        // 线上 bundle 已核实走的就是这一条（`mediaSessionPlayRef`）。
        var fn = window.__foliaMediaCommand && window.__foliaMediaCommand.play;
        if (typeof fn === 'function') {
          return function(){ try { var r = fn(); if (r && r.catch) { r.catch(function(){}); } } catch (e) {} };
        }
        // 二级：页面上真实存在的播放按钮。线上站没有 `player-toggle` 这类 testid，
        // 只能按 aria-label / 可访问名找，且必须在 aria-pressed=true（正在放）时跳过，
        // 否则等于把正在响的歌按停。
        var btn = null;
        var nodes = document.querySelectorAll('button,[role=\"button\"]');
        for (var i = 0; i < nodes.length; i += 1) {
          var n = nodes[i];
          var label = (n.getAttribute('aria-label') || '') + ' ' + (n.getAttribute('title') || '') + ' ' + (n.textContent || '');
          if (!/播放|暂停|Play|Pause/i.test(label)) { continue; }
          if (n.getAttribute('aria-pressed') === 'true' || /暂停|Pause/i.test(label)) { continue; }
          btn = n;
          break;
        }
        if (btn) {
          return function(){ try { btn.click(); } catch (e) {} };
        }
        // 三级：媒体元素（线上站 DOM 里没有，但别的版本可能有）。
        var v = document.querySelector('audio,video');
        if (v && v.paused && typeof v.play === 'function') {
          return function(){ try { var p = v.play(); if (p && p.catch) { p.catch(function(){}); } } catch (e) {} };
        }
        // 四级：**什么都不做。**
        //
        // 早先这里会写 `navigator.mediaSession.playbackState = 'playing'`，
        // 以为「至少让下一次探测判成 media-playing，别把恢复链判死」。
        // 但那是让**壳自己**伪造出「页面在放」的事实：紧接着新加的
        // `isMediaHealthy` / `isPlaybackClockAdvancing` / `busy` 三道判据
        // 都会读到这个伪造值，于是恢复链以为已经好了、彻底收工 ——
        // 用户听到的就是「状态栏显示在放，实际一点声都没有」。
        // 宁可如实报 `no-elements`，让保活继续补放。
      } catch (e) {}
      return null;
    };
    """

    /// 上一次给页面补放的时间。用来给 `resumeAudio` 节流。
    ///
    /// 线上站的 play handler 是**幂等**的（页内 `resumePlayback` 判断已在放就直接返回），
    /// 但反复跨进程调它仍有代价：每次都会让播放器重建一次 `play()` 链路，
    /// 在弱机上是能听出来的顿挫。6 秒三拍足够覆盖「切出去再回来」的真实恢复。
    private var lastResumeAttempt: Date?

    private func resumeAudio(reason: String) {
        // **用户已经亲手收手，谁都别再把歌放回去。**
        //
        // 调用方里 `recoverAudioPathPass` 与保活的守卫都看了 `userPaused`，
        // 但进后台那条链（`enforcePlaybackIfNeeded(reason: "background")` → 这里）
        // 中间的 `!wantsAudible` 分支会在 `userPaused=true` 时直接放行；
        // 而原生 AVPlayer 独立于 WebContent 进程在放，页面一次 play 入口
        // 就足以把它叫醒 —— 这是「暂停后退出后台继续播放」的最后一道缝。
        guard !userPaused else { return }
        // **节流：6 秒内最多补放一次。**
        //
        // `resumeAudio` 现在真的能调起页面播放了（之前 `__foliaMediaCommand`
        // 在线上站根本不存在，等于空转）。而线上站**不一定写**
        // `navigator.mediaSession.playbackState`，于是探测仍可能报
        // `no-elements`。若不节流，保活每 2 秒就会调一次页面的 play handler，
        // 用户听到的就是「每隔两秒被按一下」的卡顿。
        //
        // 6 秒 = 三拍保活。真正「点一次就恢复」的场景第一拍就生效；
        // 只有连续三拍都没恢复才再试，那时的确需要重试。
        if let last = lastResumeAttempt, Date().timeIntervalSince(last) < 6 {
            CrashLog.note("==== page play entry throttled (\(reason)) ====")
            return
        }
        lastResumeAttempt = Date()
        // 先叫醒 AudioContext 再补 play。
        //
        // 线上页是 WebAudio 出声：`<audio>` 只当解码源，接在 `AudioContext` 上。
        // 控制中心收起后 AudioContext 往往停在 interrupted，此时 `play()` 会返回成功
        // 却一点声都没有 —— 用户看到的就是「状态栏滑下去再回来，进度在走但没声音」。
        revivePageAudio()
        let js = """
        (function(){
          try {
            var __busy = \(Self.playbackBusyJS);
            if (__busy === true) { return 'busy'; }
            \(Self.playEntryJS)
            // 双 deck 交叉淡化（automix）下有两个 `<audio>`：一个在放、一个待命。
            // 待命的那个同样是 `paused` 且有 `src`，**不能**一起 `play()` ——
            // 那会让两首歌同时出声，用户听到的是爆音和互相抢拍。
            // 所以只认「刚才确实在出声的那一个」：优先用__foliaLastAudio
            var pick = window.__foliaLastAudio;
            var chosen = null;
            var pickSrc = pick ? (pick.currentSrc || pick.src) : null;
            // 不检查isConnected，因为纯WebAudio页面的audio元素不在DOM里
            if (pick && pickSrc && !pick.ended && pick.paused) {
              chosen = pick;
            } else {
              // 轻量查找，不递归Shadow DOM
              var nodes = document.querySelectorAll('audio');
              for (var i = 0; i < nodes.length; i += 1) {
                var el = nodes[i];
                var elSrc = el.currentSrc || el.src;
                if (!el.paused || el.ended || !elSrc) { continue; }
                if (!chosen || (el.currentTime || 0) > (chosen.currentTime || 0)) { chosen = el; }
              }
            }
            if (!chosen) {
              // **页面里根本没有可 play 的 `<audio>`：改用页面自己的播放入口。**
              //
              // 日志 07-40-38Z 第 29-52 行：恢复链每 2 秒循环一次
              // `audio probe suspicious (context=unknown)` → `audio path broken`，
              // 一直修不好，直到第 53 行用户亲手点了一次播放（`intent audible`）才响。
              //
              // 原因是线上站的播放引擎是**纯 WebAudio**（`AudioContext` +
              // `createMediaElementSource`，产物里 `audio` 元素一个都没有），
              // 而这条恢复链从头到尾只在找 `document.querySelectorAll('audio')` ——
              // 找不到就 `noop`，等于什么都没做。系统通路重建多少次都没用，
              // 因为缺的不是通路，是「页面自己没在放」。
              //
              // 页面把真正的播放入口登记在 `navigator.mediaSession.setActionHandler('play')`，
              // 壳在 `audioKeeperScript` 里已经把它存进 `__foliaMediaCommand.play`。
              // 调它等价于用户点了播放，是这里唯一真正能让 WebAudio 引擎重新出声的动作。
              //
              // `__foliaPlay()` 返回的是**无参闭包**，不要往里传 `{ action }` ——
              // 那会让 handler 拿到一个陌生参数（线上站的 handler 是无参箭头函数，
              // 传了也没用，但别的版本可能拿首参当事件对象用）。
              var playFn = __foliaPlay();
              if (typeof playFn === 'function') {
                try { playFn(); } catch (e) {}
                if (window.__foliaAudioContexts) {
                  for (var k = 0; k < window.__foliaAudioContexts.length; k += 1) {
                    var ck = window.__foliaAudioContexts[k];
                    if (ck && ck.state === 'suspended' && typeof ck.resume === 'function') {
                      try { ck.resume(); } catch (e) {}
                    }
                  }
                }
                return 'resumed-entry';
              }
              return 'noop';
            }
            window.__foliaLastAudio = chosen;
            var p = chosen.play();
            if (p && p.catch) { p.catch(function(){}); }
            return 'resumed-element';
          } catch (e) { return 'error'; }
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            // **四种结果都要进日志。**
            //
            // 日志 10-31-12-10-33Z 第 27-45 行连续八拍只有
            // `pure webaudio page, calling page play entry`，一条结果都没有 ——
            // 分不清是「被节流吃掉」「没有入口」还是「入口调了但没出声」。
            // 没有这一位，这条恢复链是黑盒。
            let flag = (result as? String) ?? "no-result"
            CrashLog.note("==== audio page play entry (\(reason)) result=\(flag) ====")
        }
        // 补放时**不再把 position 往回调**。
        //
        // 这里原本会调用 `healAudioDrift()`，用原生记住的页面进度覆盖 `currentTime`。
        // 但那份进度是页面**几秒前**上报的快照：拿它去纠正正在播放的元素，
        // 等于每次都把歌拽回过去。真机反馈正是这样 ——
        // 进度条卡在同一处反复播放，怎么都过不去；大退重开后又从旧位置开始。
        // 声音与字幕的偏差在「保活补放」这一条路上本来就只有几百毫秒，
        // 交给页面自己的播放时钟推进即可，不需要原生插手。
        // 上下文是异步起搏的，等一帧再补一次。
        //
        // 只在这一拍确实「没放成」时才动手：纯 WebAudio 页面没有 `<audio>` 可判，
        // 只能看页面自报的 playbackState（`busy === true` 就收手）；
        // 有元素时按元素是否仍被按停判断 —— 两处都不会和上面那次叠着放。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.wantsAudible, !self.userPaused else { return }
            let retryJS = """
            (function(){
              try {
                var __busy = \(Self.playbackBusyJS);
                if (__busy === true) { return 'busy'; }
                \(Self.playEntryJS)
                // **递归查找Shadow DOM里的audio元素。**
                function collectAudio(root, out) {
                  try {
                    var nodes = root.querySelectorAll('audio');
                    for (var n = 0; n < nodes.length; n += 1) { out.push(nodes[n]); }
                    var all = root.querySelectorAll('*');
                    for (var i = 0; i < all.length; i += 1) {
                      if (all[i].shadowRoot) {
                        collectAudio(all[i].shadowRoot, out);
                      }
                    }
                  } catch (e) {}
                }
                var el = window.__foliaLastAudio;
                if (!el) {
                  // 轻量查找
                  var nodes = document.querySelectorAll('audio');
                  for (var i = 0; i < nodes.length; i += 1) {
                    var x = nodes[i];
                    var src = x.currentSrc || x.src;
                    if (!src || x.ended) { continue; }
                    if (!el || (x.currentTime || 0) > (el.currentTime || 0)) { el = x; }
                  }
                }
                if (!el) {
                  // 与上面同理：纯 WebAudio 的页面没有 `<audio>` 可用，
                  // 这一拍也必须回到页面自己的播放入口，否则第二次补放同样落空。
                  var fn = __foliaPlay();
                  if (typeof fn === 'function') {
                    try { fn(); } catch (e) {}
                    return 'resumed';
                  }
                  return 'noop';
                }
                var p = el.play();
                if (p && p.catch) { p.catch(function(){}); }
                return 'resumed';
              } catch (e) { return 'error'; }
            })();
            """
            // 这一拍直接用上面同一段「补放」，而不是再问一次是否健康。
            //
            // 早先这里是「不健康才再 play 一次」，而 `isMediaHealthy` 看的是
            // `!el.paused` —— 被系统按停、页面还没重报的那一拍它会判「健康」，
            // 于是第二次补放从来不发，歌就一直停着。
            self.webView?.evaluateJavaScript(retryJS) { result, _ in
                let flag = (result as? String) ?? "no-result"
                CrashLog.note("==== audio page play retry (\(reason)) result=\(flag) ====")
            }
        }
    }

    /// 远程命令要先更新意图，再转发给页面：否则线控按了暂停，保活轮询会把它又放回去。
    ///
    /// **线控 / 耳机的暂停必须走 `markPausedIntent(reason:)`，不能只改 `wantsAudible`。**
    /// 早先这里只写 `wantsAudible = false` + 停轮询，`userPaused` 一直为假、
    /// `WebContainerView.wasAudibleInBackground` 也还是真：
    /// 用户在锁屏按了暂停 → 进程随后被系统回收 → `webViewWebContentProcessDidTerminate`
    /// 里 `resume = !userPaused && (wantsAudible || wasAudibleInBackground)` 判成真，
    /// 新实例一装好就把歌放起来 —— 用户看到的就是「我明明暂停了，重进 App 自己又响」。
    private func handleRemoteCommand(_ action: String) {
        switch action {
        case "play", "toggle":
            if action == "play" || !wantsAudible {
                markAudibleIntent()
            } else {
                // toggle 在「正在响」时表示暂停。
                markPausedIntent(reason: "remote-toggle")
            }
        case "pause":
            markPausedIntent(reason: "remote-pause")
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
            // 先看页面是不是本来就在响：`playEntryJS` 的三、四级出口是无条件的，
            // 恢复链每拍都调一次会把正在放的歌重新 play 一遍。
            var __busy = \(Self.playbackBusyJS);
            \(Self.playEntryJS)
            // **递归查找Shadow DOM里的媒体元素。**
            function collectMedia(root, out) {
              try {
                var nodes = root.querySelectorAll('audio,video');
                for (var n = 0; n < nodes.length; n += 1) { out.push(nodes[n]); }
                var all = root.querySelectorAll('*');
                for (var i = 0; i < all.length; i += 1) {
                  if (all[i].shadowRoot) {
                    collectMedia(all[i].shadowRoot, out);
                  }
                }
              } catch (e) {}
            }
            var allMedia = [];
            collectMedia(document, allMedia);
            var media = allMedia[0] || null;
            var cmd = window.__foliaMediaCommand || {};
            // 页面自己通过 setActionHandler 登记的处理器，走的是 React 状态机，
            // 切歌后 UI、队列、歌词都会同步。线上站只登记了这四个动作。
            var bound = a === 'play' ? cmd.play
              : a === 'pause' ? cmd.pause
              : a === 'next' ? cmd.next
              : a === 'prev' ? cmd.prev
              : null;
            if (typeof bound === 'function') {
              var r = bound({ action: a });
              if (r && r.catch) { r.catch(function(){}); }
              return;
            }
            if (a === 'toggle') {
              // `playbackState` 是页面自己维护的，比 DOM 可靠得多。
              var ms = navigator.mediaSession;
              var st = ms && ms.playbackState;
              if (st === 'playing') {
                if (typeof cmd.pause === 'function') { cmd.pause(); return; }
              } else {
                if (__busy === true) { return; }
                var play = __foliaPlay();
                if (play) { play(); return; }
              }
            }
            if (a === 'play') {
              if (__busy === true) { return; }
              var p = __foliaPlay();
              if (p) { p(); return; }
            }
            if (a === 'pause') {
              // 页面没登记 `pause` 处理器时的兜底：把每个在放的媒体元素都按停，
              // 再把状态位改成 `paused`。否则锁屏暂停在纯 WebAudio 页面完全空转。
              // 直接用前面收集好的allMedia（包含Shadow DOM里的元素）。
              var any = false;
              for (var i = 0; i < allMedia.length; i += 1) {
                if (!allMedia[i].paused && typeof allMedia[i].pause === 'function') {
                  try { allMedia[i].pause(); any = true; } catch (e) {}
                }
              }
              try {
                var msPause = navigator.mediaSession;
                if (msPause) { msPause.playbackState = 'paused'; }
              } catch (e) {}
              if (!any && window.__foliaAudioContexts) {
                for (var k = 0; k < window.__foliaAudioContexts.length; k += 1) {
                  var ck = window.__foliaAudioContexts[k];
                  if (ck && typeof ck.suspend === 'function' && ck.state === 'running') {
                    try { ck.suspend(); } catch (e) {}
                  }
                }
              }
              return;
            }
            // 上一首 / 下一首只能靠界面按钮：线上站没有暴露任何全局切歌接口。
            var sel = a === 'next'
              ? ['[aria-label*="下一"]','[aria-label*="Next"]']
              : a === 'prev'
                ? ['[aria-label*="上一"]','[aria-label*="Previous"]']
                : [];
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
    private static let stallTimeout: TimeInterval = 60

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
                // 用户还在一份活着的站内页面上：绝不整页重载。
                //
                // 「大退进歌单回到加载界面」的最直接来源就是这里：页面明明好好地挂在歌单上
                // （`didFinish` 过、`#root` 有内容），只因首屏那一拍没被采到，
                // 就被判成「停在加载界面」，整页重载一次 —— 用户看到的就是闪回加载页。
                // `isOnSitePage && documentFinished` 是「手上有一份完整站内文档」的硬事实，
                // 比任何历史标记都可靠，必须最先返回。
                if self.isOnSitePage && self.documentFinished && self.pageLooksAlive() {
                    CrashLog.note("==== first paint timeout but page alive, no reload ====")
                    self.markVisiblePageIfNeeded()
                    return
                }
                if self.documentFinished && !self.hasEvaluatedFirstPaint {
                    CrashLog.note("==== first paint late, keep loading (no reload) ====")
                    self.state.noteStalled(detail: detail)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                        self?.reportStallIfNeeded()
                    }
                    return
                }
                // **如果网络是通的且页面还在加载，再等一会儿。**
                //
                // 从用户反馈的截图看：readyState=interactive、online=1、scripts=4，
                // 说明页面还在加载脚本，React还没挂载。这时候重载等于把已下载的
                // 脚本全部丢掉，弱网下永远进不去。
                if detail.contains("online=1") && detail.contains("readyState=interactive") {
                    CrashLog.note("==== page still loading (interactive, online), keep waiting ====")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
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
        // 页面还好端端地在站内：这一次「卡住」只是探针没采到，不能重载。
        if isOnSitePage && documentFinished && pageLooksAlive() {
            CrashLog.note("==== stall retry skipped (page alive) ====")
            markVisiblePageIfNeeded()
            return
        }
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
        // 一秒后若已经换了新实例（进程被顶死 → 重建），这次「卡死重载」必须作废：
        // 新实例正在打开落脚点，被这里再打一次 `startURL` 就等于又回到首页。
        let armed = ObjectIdentifier(webView as AnyObject)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            guard let current = self.webView, ObjectIdentifier(current as AnyObject) == armed else {
                CrashLog.note("==== stall retry dropped (webview replaced) ====")
                return
            }
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
        webView?.evaluateJavaScript(Self.firstPaintProbeScript) { [weak self] result, _ in
            guard let self else { return }
            // 判据集中在 `firstPaintProbeScript`：只有「文档已加载完、`#root` 空、
            // 遮罩仍挂着」才算没画出来。以前这里要求遮罩被移除或 `#root` 非空，
            // 而线上站进歌单时会重新挂一次遮罩、`#root` 也可能在路由切换的空隙里
            // 短暂为空 —— 于是 30 秒看门狗到点就判死并重载，用户看到的就是
            // 「进歌单回到加载界面」。现在这两种情况都不再让 `reachedFirstPaintOnce` 为假。
            let phase = (result as? String) ?? "loading"
            // **`empty`（`#root` 空、无遮罩的悬空白页）不算画出来。**
            //
            // 它早先被当成成功，是因为怕「进歌单时 `#root` 短暂为空」被误判。
            // 但那种空隙是毫秒级的，而这里每拍都会重探：真正的空壳会一直空着，
            // 记成成功只会让 30 秒看门狗失去最后一次自愈机会，用户就一直对着白屏。
            if phase == "ready" {
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
                // 这一页既然画出来了，就洗清它「会顶死进程」的嫌疑：
                // 用户下次正常落脚到同一路由时不该被无谓地降级。
                //
                // **只清「刚死过」那一份，绝不清 `memoryHeavyRoutes`。**
                // 日志 10-30-15Z：重建后新实例打开 `#player`，这一屏当然能画出来；
                // 若在这里把「谁是重负载路由」也一并抹掉，下一次再进那个歌单
                // 又会被当成普通页面直接打开 —— 于是再死一次，用户看到的就是
                // 「每次都要重新经历一遍闪退」。重载标记只允许在「它自己这一次
                // 真的活下来了」时才清（见 `markVisiblePageIfNeeded`）。
                if let live = WebContainerView.trustedSiteURL(self.webView.url),
                   WebContainerView.stableFallback(from: live) == nil {
                    WebContainerView.clearRouteDeath(live)
                }
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

    /// 后台保活 + 播放状态上报给原生（锁屏/控制中心据此判断「正在播放」）。
    /// 页面自己不会在切后台时暂停；真正被掐断的是 iOS 在会话失效后按停媒体元素，
    /// 或者 WebKit 的内容进程被系统短暂挂起。所以这里做两件事：
    /// 1. 记录页面的播放意图（`play()` / `pause()` 被调用即上报），意图在原生这边保存；
    /// 2. 后台每两秒确认一次会话有效，并把「该响但被按停」的媒体放回去。
    private func installAudioKeeper() {
        // 真正的那份在 `audioKeeperScript` 里，随文档开始一起注入；这里只兜一次「脚本被清掉」的情况。
        ensureAudioKeeper()
        // 按播放意图同步一次：页面状态上报只在 `playing` / `pause` 事件时发一条，
        // 而锁屏 / 背面朝上时 WebKit 会真的按停媒体元素并发 `pause`，
        // `AudioSessionController.isPlaying` 于是变假，回前台的几条恢复分支全被它挡住。
        // 这里在每次文档加载完时按 `wantsAudible` 重新对齐一次。
        AudioSessionController.shared.updatePlaybackState(wantsAudible && !userPaused)
    }

    /// 保活 + 播放状态上报。
    ///
    /// 页面自己不会在切后台时暂停；真正被掐断的是 iOS 在会话失效后按停媒体元素，
    /// 或者 WebKit 的内容进程被系统短暂挂起。所以这里做两件事：
    /// 1. 记录页面的播放意图（`play()` / `pause()` 被调用即上报），意图在原生这边保存；
    /// 2. 后台每两秒确认一次会话有效，并把「该响但被按停」的媒体放回去。
    /// 保活脚本。因为要把「重负载路由表」插进脚本正文，只能按需拼装 ——
    /// 存成 `static let` 的话初始化器里引用 `Self` 会被 Swift 拒绝（covariant Self）。
    private static func audioKeeperScript() -> String {
        audioKeeperBody.replacingOccurrences(of: "__FOLIA_HEAVY_ROUTES__", with: memoryHeavyLiteral())
    }

    private static let audioKeeperBody = """
        (function(){
          if (window.__foliaAudioKeeperInstalled) { return; }
          window.__foliaAudioKeeperInstalled = true;

          // **降载开关：这个路由曾经把 WebProcess 顶死过。**
          //
          // 按地址前缀装在**所有页面脚本之前**。线上页目前不读它，
          // 真正压内存的是 `__foliaTuneImages`（图片 lazy/async）与 WebKit 的内容规则。
          try {
            var heavy = __FOLIA_HEAVY_ROUTES__;
            var here = location.href;
            for (var hi = 0; hi < heavy.length; hi += 1) {
              if (heavy[hi] && here.indexOf(heavy[hi]) === 0) {
                window.__foliaLowMemory = true;
                document.documentElement.setAttribute('data-folia-low-memory', '1');
                break;
              }
            }
          } catch (e) {}

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
            try { if (typeof window.__foliaPruneAudioContexts === 'function') { window.__foliaPruneAudioContexts(); } } catch (e) {}
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

          // 播放器重建时旧上下文会被 `close()`：留着它会让原生误判「通路还在」，
          // 于是该唤醒的那一次永远不跑（回前台后界面在放、一点声都没有）。
          window.__foliaPruneAudioContexts = function(){
            try {
              var list = window.__foliaAudioContexts || [];
              var kept = [];
              for (var i = 0; i < list.length; i += 1) {
                if (list[i] && list[i].state !== 'closed') { kept.push(list[i]); }
              }
              window.__foliaAudioContexts = kept;
              var act = window.__foliaActiveAudioContext;
              if (act && act.state === 'closed') { window.__foliaActiveAudioContext = null; }
            } catch (e) {}
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
                  // 每次接新媒体源都顺手清一次已关闭的上下文：切歌词 / 换播放器树时
                  // 页面会新建 context 并关掉旧的，旧的一直留在列表里会让
                  // `resumeAudioContexts` 把一条已经死掉的通路当成「健康」。
                  if (typeof window.__foliaPruneAudioContexts === 'function') {
                    window.__foliaPruneAudioContexts();
                  }
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

          // 记录页面自身的 MediaSession 处理器，供锁屏按钮与音频恢复直接调用。
          //
          // **这是线上站唯一真实存在的播放入口。** 反查过线上 bundle：
          // 播放/暂停由 React 闭包里的 `mediaSessionPlayRef` 承担，通过
          // `navigator.mediaSession.setActionHandler('play', ...)` 登记；
          // 页面**从未**暴露过 `window.__foliaMediaCommand`（整个 bundle 里
          // `__folia*` 只有 `__folia_current_time`）。之前所有「调页面播放入口」
          // 的兜底因此全是空转 —— 日志 10-24-58Z 里 4 分 39 秒无声就是这么来的。
          //
          // **必须装在实例上而不是原型上，且必须只装一次。** 本脚本会注入两次
          //（`atDocumentStart` + `didFinish`）；若每次都用当前值再 `bind` 一次覆盖，
          // 第二次包住的就是自己，调用会无限递归。所以用 `__foliaWrapped` 门控。
          var handlers = window.__foliaMediaCommand = window.__foliaMediaCommand || {};
          try {
            var ms = navigator.mediaSession;
            if (ms && ms.setActionHandler) {
              // **已装过就不再重装，但必须保持引用一致。**
              //
              // 包装器闭包里捕获的是 `handlers` 这个变量。本脚本会注入两次，
              // 第二次执行时 `window.__foliaMediaCommand` 是同一个对象，所以
              // 「已装过就直接跳过」不会让记录丢失；而若在这里摘掉重装，
              // 页面在两次注入之间登记过的 handler 就会永远丢失（页面不会再登记
              // 同一个 effect）。所以只在没有包装时安装。
              if (!ms.setActionHandler.__foliaWrapped) {
                var prev = ms.setActionHandler;
                var wrapped = function(detail){
                  try {
                    var key = arguments[0];
                    if (typeof detail === 'function' && typeof key === 'string') {
                      if (key === 'play') { handlers.play = detail; }
                      else if (key === 'pause') { handlers.pause = detail; }
                      else if (key === 'previoustrack') { handlers.prev = detail; }
                      else if (key === 'nexttrack') { handlers.next = detail; }
                    }
                  } catch (e) {}
                  return prev.apply(ms, arguments);
                };
                wrapped.__foliaWrapped = true;
                wrapped.__foliaRaw = prev;
                ms.setActionHandler = wrapped;
              }
            }
          } catch (e) {}

          // **图片解码限流：按当前路由决定同时留几张封面的解码位。**
          //
          // 这是「闪退频繁」的直接对策。歌单详情一次铺几百张封面，WebKit 给每个
          // `<img>` 解码后都要占一份常驻内存，几百张叠加足以把 WebContent 顶没
          // （日志 10-31-12-11-34Z：冷启动 8 秒进歌单立刻死）。
          //
          // 线上页并不读 `__foliaLowMemory`（入口脚本里根本没这段），所以壳在这里
          // 自己接管图片的 `decoding` 与 `loading` 两个提示位：
          // - 普通页面：`decoding="async"`，不阻塞主线程，也不改变加载策略；
          // - 重负载路由（顶死过进程的那些歌单）：新插入的封面改成 `loading="lazy"`，
          //   屏幕外的封面不请求、不解码，只有滚到眼前才占内存。
          // 唯一的越界是首次扫描时给**已在文档里**的图片补 lazy —— 那是这批图片
          // 内存最紧张的一刻，且 lazy 只影响「还没开始加载的」，不会撤掉已显示的图。
          // 只动这两个属性，不碰 `src`、不改 `HTMLImageElement.prototype`、不拦请求，
          // 页面的懒加载、点击放大、预加载逻辑全部照旧。
          window.__foliaTuneImages = function(heavy){
            try {
              var imgs = document.images;
              for (var i = 0; i < imgs.length; i += 1) {
                var img = imgs[i];
                try {
                  if (!img.getAttribute('decoding')) { img.setAttribute('decoding', 'async'); }
                  if (heavy && !img.getAttribute('loading')) { img.setAttribute('loading', 'lazy'); }
                } catch (e) {}
              }
            } catch (e) {}
            // **一次性把这一批里的图片全扫一遍，然后立刻断开。**
            //
            // 页面用的是虚拟列表，滚动时每帧都在批量插入节点。原先这里是
            // `subtree: true` 的常驻观察器，等于让壳在页面自己的渲染循环里
            // 再多跑一遍 DOM 遍历 —— 0.7.24 的歌词页（雾笺 / 町景）本来就
            // 每帧重排，这一份额外开销会直接算进掉帧里。
            // 改成「写完属性就断开」，只在拍到的这一批上花一次钱。
            try {
              if (window.__foliaImageObserver || typeof MutationObserver !== 'function') { return; }
              var observer = new MutationObserver(function(records){
                var heavyNow = !!window.__foliaLowMemory;
                for (var r = 0; r < records.length; r += 1) {
                  var nodes = records[r].addedNodes;
                  for (var n = 0; n < nodes.length; n += 1) {
                    var node = nodes[n];
                    if (!node || node.nodeType !== 1) { continue; }
                    try {
                      var batch = node.tagName === 'IMG' ? [node] : node.querySelectorAll('img');
                      for (var b = 0; b < batch.length; b += 1) {
                        if (!batch[b].getAttribute('decoding')) { batch[b].setAttribute('decoding', 'async'); }
                        if (heavyNow && !batch[b].getAttribute('loading')) { batch[b].setAttribute('loading', 'lazy'); }
                      }
                    } catch (e) {}
                  }
                }
                try {
                  observer.disconnect();
                  if (window.__foliaImageObserver === observer) { window.__foliaImageObserver = null; }
                } catch (e) {}
              });
              window.__foliaImageObserver = observer;
              observer.observe(document.documentElement || document, { childList: true, subtree: true });
            } catch (e) {}
          };
          try { window.__foliaTuneImages(!!window.__foliaLowMemory); } catch (e) {}

          // **媒体会话属性也绕一层。**
          //
          // 日志 10-24-58Z 第 32 行 `context=no-elements reason=pending` 之后
          // 整整 4 分 39 秒没有任何动作，直到用户亲手点播放才响（第 33 行）。
          // 原因就在这里：`playbackState` 是一个 setter 属性，页面每次上报
          // 「我在放 / 我停了」都要写它。壳以前既没记写过什么、也没读过它，
          // 于是 `resumeAudioContexts` 里读到的 `playbackState` 常常是 `none`，
          // 被判成 `no-elements`，恢复链只能去调 `__foliaMediaCommand.play`；
          // 而线上站是否登记过 play handler 并不能保证（它可能只登记 pause）。
          // 记下页面自己写过的每一次值，壳至少知道「页面认为自己该在放」。
          // 只为记录，不改变任何行为。
          try {
            var protoDesc = null;
            try {
              protoDesc = window.MediaSession
                ? Object.getOwnPropertyDescriptor(window.MediaSession.prototype, 'playbackState')
                : null;
            } catch (e) { protoDesc = null; }
            if (protoDesc && protoDesc.set && protoDesc.configurable && !protoDesc.set.__foliaWrapped) {
              var rawProtoSet = protoDesc.set;
              var protoSet = function(v){
                try { window.__foliaPlaybackState = v; } catch (e) {}
                return rawProtoSet.call(this, v);
              };
              protoSet.__foliaWrapped = true;
              Object.defineProperty(window.MediaSession.prototype, 'playbackState', {
                configurable: true,
                enumerable: protoDesc.enumerable,
                get: protoDesc.get,
                set: protoSet
              });
            }
          } catch (e) {}

          // 注意：这里**不能**去改 `window.fetch` / `XMLHttpRequest` / `HTMLMediaElement.prototype`
          // 这类全局原型。页面是 React 应用，切换歌词形式时会重建整棵播放器树，
          // 期间会对原型链做批量探测；被改写过的原型在 WKWebView 里可能触发
          // 「WebProcess 崩掉」—— 用户看到的就是切歌词形式直接闪退。
          // 现在改成只在真正的媒体元素上挂监听（见下方 capture 阶段），不动任何原型。

          // 「最近 1.5 秒内用户真的碰过屏幕」。
          //
          // 判断一次 pause 是不是用户收手，只有一个可靠依据：**用户刚刚点了屏幕**。
          // 系统掐断（切后台、别的 App 抢通路、锁屏）永远不会伴随手势；
          // 而页面自己重建播放器树、切歌、AudioContext 被挂起也都是无手势的 pause。
          // 之前靠「app 是否 active + 时间窗」推断，结果被抖音抢占后误判成
          // 「paused by user (confirmed)」（真实日志），恢复链就此锁死。
          var lastTouchAt = 0;
          var noteTouch = function(){ lastTouchAt = Date.now(); };
          ['touchstart', 'touchend', 'mousedown', 'click', 'pointerdown'].forEach(function(name){
            try { window.addEventListener(name, noteTouch, { capture: true, passive: true }); } catch (e) {}
          });
          window.__foliaUserGestureAge = function(){
            if (!lastTouchAt) { return 999999; }
            return Date.now() - lastTouchAt;
          };

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
            // **递归查找Shadow DOM里的audio元素。**
            function collectAudio(root, out) {
              try {
                var nodes = root.querySelectorAll('audio');
                for (var n = 0; n < nodes.length; n += 1) { out.push(nodes[n]); }
                var all = root.querySelectorAll('*');
                for (var i = 0; i < all.length; i += 1) {
                  if (all[i].shadowRoot) {
                    collectAudio(all[i].shadowRoot, out);
                  }
                }
              } catch (e) {}
            }
            var list = [];
            collectAudio(document, list);
            for (var i = 0; i < list.length; i += 1) {
              var itemSrc = list[i].currentSrc || list[i].src;
              if (!list[i].ended && itemSrc) { return list[i]; }
            }
            return null;
          };
          document.addEventListener('play', function(e){
            var el = e.target;
            if (!el || el.tagName !== 'AUDIO') { return; }
            // 记下「真正在出声的那一个 deck」：壳在后台/被抢占后补放时只放它，
            // 不能把待命的另一个 deck 一起放（爆音、抢拍）。
            window.__foliaLastAudio = el;
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
          document.addEventListener('playing', function(e){
            var el = e.target;
            if (!el || el.tagName !== 'AUDIO') { return; }
            // **这一条是本轮「抖音回来没声音」的直接修复。**
            //
            // `playing` 事件只在 WebKit 认为解码管线真的开始播放时发一次。
            // AudioContext 被系统钉成 interrupted 后，`play()` 仍会成功、
            // `pause` 事件不触发、`paused` 一直是 false —— 差别只有「有没有这个事件」。
            // 壳用它当「确实在出声」的唯一凭据（见 `isMediaHealthy`），
            // 被抢走的通路上这个标记会一直是假，于是保活每一拍都会真的去重建通路，
            // 而不是像以前那样被 `paused == false` 骗过、两拍都判健康然后收工。
            window.__foliaHeard = true;
            if (window.__foliaHeardTimer) { clearTimeout(window.__foliaHeardTimer); }
            // 5 秒后作废：声音被摘走后不会再有 `playing`，下一拍探测必须重新判。
            window.__foliaHeardTimer = setTimeout(function(){ window.__foliaHeard = false; }, 5000);
          }, true);
          document.addEventListener('pause', function(e){
            var el = e.target;
            if (!el || el.tagName !== 'AUDIO') { return; }
            window.__foliaHeard = false;
            // 不检查isConnected，因为纯WebAudio页面的audio元素不在DOM里
            if (el.paused && (el.currentSrc || el.src)) {
              window.__foliaLastAudio = el;
            }
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
              // 优先用__foliaLastAudio（可能不在DOM里）
              var el = window.__foliaLastAudio;
              if (!el) { el = document.querySelector('audio,video'); }
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
        webView?.evaluateJavaScript(Self.audioKeeperScript(), completionHandler: nil)
    }

    /// 汽水音乐音源桥：给页面挂上 `window.electron.qishuiRequest`。
    ///
    /// 线上站把汽水音乐作为一个可选音源，判定条件是
    /// `typeof window.electron?.qishuiRequest === 'function'`；不满足就报
    /// `unavailable / Qishui requires the desktop app`，音源在列表里直接不可用。
    /// 那段代码在桌面端由 Electron 主进程代发请求，iOS 壳里没有 Electron，
    /// 于是这里用 `WKScriptMessageHandler` 把同一件事接过来（见 `QishuiBridge`）。
    ///
    /// 返回值形状必须严格对齐页面期望：
    /// - 成功：`{ ok: true, data }`
    /// - 失败：`{ ok: false, error: { code, message, stage?, upstreamCode? } }`
    /// 页面拿到的是**整个对象**（不是只取 `data`），由它自己判 `ok`、自己读 `error`。
    /// 任何一个字段错位，页面侧都会当成未知错误，登录二维码就停在转圈。
    private func installQishuiBridge() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.bridgeInstallScript) { _, error in
            if let error {
                NSLog("[Qishui] bridge install failed: %@", String(describing: error))
            }
        }
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

    /// 权威 UA 串。原生代发的请求（汽水音源）也带同一个，服务端才能认成壳。
    static var userAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS \(UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 \(userAgentMarker)"
    }

    /// 壳模式 UA 标记，页面入口脚本据此打开壳布局。
    static let userAgentMarker = "FoliaApp/\(appVersion)"

    /// 壳版本号：唯一取自 Info.plist，改版本只改 project.yml 一处。
    /// UA 只用来判定「是不是壳」（正则匹配 `FoliaApp`），带版本号不影响壳模式识别，
    /// 但能让线上日志一眼看出是哪个版本的壳在跑。
    static let appVersion: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

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
        // 上一次已经真正弹出过就不再注入：重建后的新文档会重跑首屏逻辑。
        if donateShownThisLaunch { return }
        let js = """
        (function(){
          if (window.__foliaDonateInstalled) { return false; }
          var mask = document.getElementById('donate-mask');
          if (!mask) { return false; }
          window.__foliaDonateInstalled = true;

          var QUARK_URL = 'https://pan.quark.cn/s/934c480d5b9c';

          // 两个版本号都取壳带进来的实际版本（Info.plist 的 MARKETING_VERSION）：
          // 线上页自己的常量停在 '2.1'，沿用会显示成旧值。
          // 壳内「最新版本」=「当前版本」，因为包就是从网盘拿的最新那一份。
          var cur = window.__foliaAppVersion || '';
          var latest = cur;

          // 线上页的弹窗脚本会读这两个全局常量自行回填，先改掉，
          // 否则它晚一拍执行又把 '2.1' 写回去。
          try {
            if (cur) {
              try { window.FOLIA_VERSION = cur; } catch (e) {}
              try { window.FOLIA_LATEST_VERSION = cur; } catch (e) {}
            }
          } catch (e) {}

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
          return true;
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            // 只有真的挂上并排好了弹窗才算「弹过」，DOM 还没就绪时留给下一次首屏检查重试。
            if result as? Bool == true {
                self?.donateShownThisLaunch = true
            }
        }
    }

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
      // **确保页面拿到的 `electron` 是个可写的普通对象。**
      //
      // 0.7.24 的 `App.tsx` 用 `Boolean(window.electron)` 得出 `isElectronWindow`，
      // 而汽水音源又只在 `window.electron.qishuiRequest` 存在时才可用 ——
      // 两者共用同一个对象。所以这里不能把它钉死成 `undefined`（那会连带让汽水音源消失），
      // 而是保证它就是一个空的、可写的普通对象，具体方法由 `bridgeInstallScript` 在提交后补上。
      // 桌面窗口分支在 iPhone 上的实际影响已逐条核对，见 `bridgeInstallScript` 的注释。
      try {
        if (!Object.prototype.hasOwnProperty.call(window, 'electron')
            || typeof window.electron !== 'object'
            || window.electron === null) {
          try { delete window.electron; } catch (e) {}
          window.electron = {};
        }
      } catch (e) {}
      // 壳的实际版本（project.yml 的 MARKETING_VERSION），赞赏弹窗的「当前版本」用它，
      // 免得壳里显示的版本和装上的包对不上。
      window.__foliaAppVersion = '\(appVersion)';
      // 线上页的赞赏脚本自己会读这两个常量回填版本号，而它的常量停在 '2.1'。
      // 在 document-start 阶段就钉成壳版本，晚执行的页面脚本读到的也是新值。
      try {
        Object.defineProperty(window, 'FOLIA_VERSION', { value: '\(appVersion)', writable: true, configurable: true });
        Object.defineProperty(window, 'FOLIA_LATEST_VERSION', { value: '\(appVersion)', writable: true, configurable: true });
      } catch (e) {}
      // **不要动 `navigator.userAgent`。**
      //
      // 这里曾经把 UA 里的 iPhone/iPad/iPod 换成 Macintosh，好让线上页那个
      // `if (/iPhone|iPad|iPod/i.test(UA)) return;` 放行、由页面自己弹赞赏窗。
      // 但壳这边 `installDonateCard()` 也会弹一次，且比页面早 400ms ——
      // 用户看到的就是「弹两次赞赏界面」。赞赏窗由壳独占，页面那份保持 return。
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
      // 线上 `index.html` 里赞赏卡上的版本号（`#donate-version-num`）与实际部署的
      // 前端版本（`/assets/main-<hash>.js`）都能用来判断「脚下这份文档是哪一版」。
      // 这不是界面上的版本号，只用来识别「浏览器里还留着一份很老的 HTML/入口脚本」。
      //
      // 壳侧的赞赏弹窗已经删掉，`#donate-version-num` 只作为线上页的自带标记读取：
      // 取不到就是空串，此时只有入口脚本的哈希可看。
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
          // **记录所有调用过play()的元素，即使它不在DOM树里。**
          // 纯WebAudio页面的audio元素只存在于JS闭包里，不在DOM里，
          // 所以querySelectorAll和document上的事件监听都收不到它。
          // 在这里直接记录，探针就能找到它了。
          try {
            if (self.tagName === 'AUDIO') {
              window.__foliaLastAudio = self;
            }
          } catch (e) {}
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
    ///
    /// **必须先有一个文档**。冷启动 / 重建后的第一发导航，`webView.url` 还是 nil，
    /// 这一发一定是壳自己 `load` 出去的，不可能是从别的 App 闯进来的。
    /// 早先这里只看「当前不是站内页」，于是首屏加载被判成闯入者，在
    /// `decidePolicyFor` 里被 `cancel` 掉 —— 日志里就是连续多条
    /// `provisional navigation failed … 102 帧框加载已中断`，连错三次后
    /// 还会把用户推到包内离线副本（「进不去 / 停在加载界面」）。
    private func isArrivalCandidate() -> Bool {
        if isShowingOfflineCopy || isOnSitePage { return false }
        guard let current = webView?.url else { return false }
        // `about:blank` 不算已有文档。
        if current.scheme == "about" { return false }
        return true
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
                // 手上还是活的站内页面：宁可什么都不做，也不把用户踢回加载界面。
                if self.isOnSitePage {
                    CrashLog.note("==== arrival reload skipped (still on site) ====")
                    return
                }
                if let container = self.webView {
                    container.load(URLRequest(url: Self.startURL,
                                              cachePolicy: .useProtocolCachePolicy,
                                              timeoutInterval: 30))
                    self.scheduleProgressWatchdog()
                }
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

        // **原生这一层的兜底。** 页面侧脚本拦得住 `pushState` / `location.hash` /
        // `assign` / `replace`，但拦不住 `location.href = ...` 那种整页导航 ——
        // 那是一次真正的导航请求，只有这里看得见。
        // 只在「手上已经有一份站内文档」时才取消：首屏本身就是这个地址时取消，
        // 用户会被扔在一张空白页上。
        if isMainFrame && isSameSite && scheme == "https",
           !isShowingOfflineCopy,
           Self.bannedRoute(url),
           let current = webView.url, Self.trustedSiteURL(current) != nil {
            CrashLog.note("==== cancelled navigation to banned route: \(url.absoluteString) ====")
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    /// 服务器已经有响应、导航真正开始了：这里才敢把「离线副本」标记撤掉。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // 同理：旧实例在换掉之后补发的导航回调一律不认，否则会把地址位写回死路由。
        guard webView === self.webView else { return }
        // 主框架还在跑，说明上次的断网/失败现场已经不成立了。不在这里清的话，
        // 提示层会一直盖在已经画好的页面上（`showsBlockingNotice` 只认 `offlineReason`），
        // 用户看到的就是「页面明明能开，却一直停在加载界面，只能点重试」。
        if state.offlineReason != nil {
            CrashLog.note("==== main frame committed, clearing stale failure notice ====")
            state.clearLoadFailure()
        }
        // 汽水音乐音源桥：线上页只有检测到 `window.electron.qishuiRequest` 才会把
        // 「汽水音乐」标成可用（`runtime-unavailable` 会让它在音源列表里直接不可选）。
        // 每次提交都补一次，SPA 内部路由切换不会丢。
        //
        // **不能同步注入**：这是首屏唯一的提交点，`evaluateJavaScript` 一旦抛错
        // （页面 JS 上下文还没就绪 / 被 CSP 挡 / 实例正在换），异常会顺着
        // `decidePolicyFor` 往上传，主框架提交被中断，用户看到的就是黑屏。
        // 所以推迟到下一个 runloop，并且单独吞掉错误 —— 桥挂了只影响汽水音源，
        // 绝不能连带整个页面打不开。
        // 每次提交都补一次：桥挂在页面对象上，换文档就没了。
        // `bridgeInstallScript` 里对已存在的方法做了覆盖，重复执行是安全的。
        DispatchQueue.main.async { [weak self] in
            self?.installQishuiBridge()
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
        guard webView === self.webView else { return }
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
            // 进程死后要靠它把用户送回原处，所以与 `lastVisibleURL` 一起写。
            // 只靠 `didCommit` 那一条的话，SPA 内部路由切换（歌单是 pushState，
            // 不触发主框架提交）永远记不下来 —— 这就是日志里
            // `rebuild: reopen /`（明明在歌单上，重建却回了首页）的来源。
            lastCommittedURL = url
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
        // **in-place 重开后的路由守卫在这里补装。**
        //
        // 旧 WebView 出生时装的是「不钉」脚本，进程死了又原地重开时，
        // document-start 注入改不了既有的 userContentController 装载
        // （会随每次 reload 叠加）。只能在文档落地的这一刻把守卫种进页面：
        // SPA 的路由恢复发生在 React 挂载后（进程重启后至少几秒），
        // didFinish 时机完全来得及压住它。
        if let pin = pendingPinFragment {
            pendingPinFragment = nil
            let js = Self.pinnedLandingScript(pin)
            webView.evaluateJavaScript(js, completionHandler: nil)
            CrashLog.note("==== in-place pin guard armed (#\(pin)) ====")
        }
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
        // 旧实例的回调一律作废：重建后它仍可能补发一次失败，
        // 那样会改写 `consecutiveLoadFailures` 甚至把新页面顶成离线副本。
        guard webView === self.webView else { return }
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
        //
        // **这个例外必须在第一次失败时就消费掉。** 它代表的只是「唤醒那一轮」这个
        // 瞬时窗口；早先没人清它，`wakeReloadTried` 一旦置真它就永久为真，
        // 于是离线副本上的每一次导航失败都会继续走下面的 2 秒自动重载 ——
        // 用户看到离线页反复刷回加载界面。消费掉之后，离线副本的失败
        // 交回给提示层（`OfflineNotice`），不再自动重试。
        if wakeRecoveryInFlight {
            wakeRecoveryInFlight = false
        } else if isShowingOfflineCopy {
            return
        }
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
        // 记下这一拍装的是哪个实例：两秒后若已经换成新实例，这次重载必须作废。
        //
        // 否则「进程刚被顶死 → 重建装好了新实例」与「两秒前的失败重载块」会叠在一起：
        // 新实例刚打开落脚点就被改写成首页，用户看到的就是回到加载界面。
        let armed = ObjectIdentifier(webView as AnyObject)
        // 两秒半后再试：冷启动那几秒网络栈常常还没就绪，
        // 间隔太密会把「正在起网」连判三次直接打回离线副本（`folia(8).log` 第 5-19 行）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            guard let current = self.webView, ObjectIdentifier(current as AnyObject) == armed else {
                CrashLog.note("==== failed-nav retry dropped (webview replaced) ====")
                return
            }
            // 这两秒里页面自己回来了（或本来就没死）：不能再整页重载回首页。
            //
            // 弱网下一次子资源失败也会走到这里，而用户手上那份 SPA 页面还是活的。
            // 无条件 `load(startURL)` 会把歌单、播放状态、当前曲目全部丢掉，
            // 用户看到的就是「用着用着闪回加载界面」。
            if self.isOnSitePage && self.documentFinished && self.pageLooksAlive() {
                CrashLog.note("==== failed-nav retry skipped (page alive) ====")
                return
            }
            self.webView?.load(URLRequest(url: Self.startURL,
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
    /// 内容进程一死，立刻把它在原地址上重开。
    ///
    /// 极简版：不做封禁、不做降级、不换存储、不重建实例。`WKWebView` 在进程被杀后
    /// 会自动换一个新的 WebContent 进程；我们只需要给它喂一个地址。能拿到死前那一页
    /// 就用死前那一页（用户还在同一个歌单），拿不到就 reload（WKWebView 自己知道
    /// 当前 URL）。iPhone 画像额外把 WebGL 关 15 分钟（参考包实测：关 GL 后 0 次回收）。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        CrashLog.note("==== web content process terminated, reloading in place ====")
        documentFinished = false
        didReachFirstPaint = false
        hasEvaluatedFirstPaint = false
        collectTerminationContext()
        // **60 秒内死两次以上，重载落回首页，不再落回死前那一页。**
        //
        // 自救机器退役之后，如果某个页面本身就会把进程顶死（folia(8).log：
        // gl=off 的情况下进歌单 3 秒内还是死），原地重载就是「死 → 回同一页 →
        // 再死」的死循环。第二次往后的死亡直接落首页：登录、搜索、扫码都在
        // 首页，App 保持可用；用户想再进那个页面可以自己再点。单次死亡
        // （后台被系统回收这种一次性事件）不受影响，照常回原页。
        let now = Date()
        contentProcessRestarts = contentProcessRestarts.filter { now.timeIntervalSince($0) < 60 }
        let deathLoop = contentProcessRestarts.count >= 2
        contentProcessRestarts.append(now)
        // **跨实例的死亡账本要在这里记。**
        //
        // folia(13).log 的现场：13:20:41 → 13:20:47 → 13:20:50 连死三次，
        // 前两次 `reloading in place`（不换实例），第三次才走死亡熔断重建。
        // 而 `installRebuiltWebView` 里的 `death burst: purging indexeddb`
        // 读的是 `Self.recentTerminations` —— 这个数组**从来没有人写入过**，
        // 所以永远为空、`burst` 永远为假、IndexedDB 永远不会被清。
        // 结果就是：重建落脚明明是 `/`，页面启动后照旧从 IndexedDB 的
        // `last_song` / 队列缓存把路由恢复回歌单，再死一次。
        // 这里把时刻按全局账本记一份（60 秒窗口，与 contentProcessRestarts 同判据），
        // 重建那边才数得出「这一轮到底连死几次」。
        Self.recentTerminations = Self.recentTerminations.filter {
            now.timeIntervalSince($0) < 60
        }
        Self.recentTerminations.append(now)
        if deathLoop {
            CrashLog.note("==== death loop (2+ terminations in 60s), rebuilding (persistent store kept) ====")
        }
        // **死亡熔断重建用默认持久存储，绝不再用 `.nonPersistent()`。**
        //
        // folia(11).log 的现场：`rebuilding with clean store` 之后用户登录态、
        // 音源、设置全部消失 —— nonPersistent 存储把 localStorage 一起清了，
        // 用户看到「闪退一次就恢复出厂」。而它要解决的坏状态（SPA 路由恢复用的
        // sessionStorage）本来就挂在 WebView 实例上：换新实例 = 换新
        // WebContent 进程 = sessionStorage 天然清零，根本不需要动持久存储。
        // cookie / localStorage 全保留，新页面照常读到登录态。
        let reopen = { [weak self, weak webView] in
            guard let self = self, let webView = webView else { return }
            if deathLoop {
                // 熔断走重建：新实例的钉路由走 document-start 注入
                // （见 rebuildWebView），这里挂着的旧守卫指令一并作废。
                self.pendingPinFragment = nil
                self.rebuildWebView(resumeAudio: false, cleanStore: false)
                return
            }
            // **in-place 重开也要摆脱死前的坏路由，且重开后补装守卫。**
            //
            // folia(14).log 14:24:22：第一次死亡在首页 `/`，in-place reload 后
            // 页面从 localStorage 把路由恢复回歌单（14:24:26 死在
            // `#collection/.../playlist/...`）—— 旧 WebView 出生时装的是
            // 「不钉」脚本，document-start 注入改不了它，reload 之后 SPA 的
            // 路由恢复照旧发生。结果就是：in-place 重开把用户一次次送回
            // 撑死进程的那一屏，攒够两次才轮到熔断重建。
            //
            // 死前 URL 有哈希就退到播放器（和熔断的 stableFallback 同判据）；
            // 死前在首页就只能留在首页 —— 首页本身的恢复只能靠重开后补装
            // 的守卫压住：SPA 的路由恢复发生在 React 挂载之后（进程重启后
            // 至少几秒），didFinish 时机补装完全来得及。
            let deadURL = Self.trustedSiteURL(webView.url)
                ?? Self.trustedSiteURL(self.lastVisibleURL)
                ?? Self.trustedSiteURL(self.lastCommittedURL)
            let pin: String?
            if let dead = deadURL, let fallback = Self.stableFallback(from: dead) {
                CrashLog.note("==== in-place reopen downgraded to \(fallback.absoluteString) ====")
                pin = fallback.fragment
                webView.load(URLRequest(url: fallback))
            } else if let url = deadURL {
                // 死在首页时 fragment 为 nil —— 但首页恰恰要钉「空哈希」：
                // folia(14) 里 14:22:26 死在 `/`，重开后页面把路由恢复到歌单，
                // 14:24:26 死在歌单路由。空串走 pinnedLandingScript 的
                // 「钉空哈希」分支，守卫同样生效。
                pin = url.fragment ?? ""
                webView.load(URLRequest(url: url))
            } else {
                pin = nil
                webView.reload()
            }
            guard let pin else { return }
            // 守卫跟着这次重开走：页面一 didFinish 就装上，钉住落脚点 6 秒。
            self.pendingPinFragment = pin
        }
        if ShellProfile.current == .aggressive {
            Self.setGLBlockCookie { reopen() }
        } else {
            reopen()
        }
    }

    /// 进程在同一个路由上反复被顶死时的退路：留在同一个页面，退到它不带哈希的那一屏。
    ///
    /// 举例：`https://app.folia-api.top/#collection/online/netease/playlist/14400331811`
    /// → `https://app.folia-api.top/#player`。用户仍然在 Folia 里、登录态与播放队列都在，
    /// 只是不会自动替他再打开一次那个会撑爆进程的歌单详情，也不会被扔回首页的加载遮罩。
    /// 本来就已在首页（没有哈希可退）时返回 nil，交给重建流程处理。
    private static func stableFallback(from url: URL) -> URL? {
        guard trustedSiteURL(url) != nil else { return nil }
        guard let fragment = url.fragment, !fragment.isEmpty else { return nil }
        // **先退播放器，再退首页。**
        //
        // 退首页等于「回到加载界面」—— 用户报的就是这个。首页本身要重新拉全部
        // 脚本和首屏封面，内存曲线在重建后那几秒正是最紧的时候，很容易再被顶死。
        // 播放器那一屏结构最轻，而且用户真正想要的是「歌继续放」。
        // **已经是播放器就不用再降级。**
        //
        // 早先这里会退到不带哈希的首页，理由是「连播放器都撑不住」。
        // 但通往这里的调用几乎都不是「真的死在播放器上」：`rebuildWebView` 里
        // 对任何一个非首页路由都走这一步，而降级的结果经常正是 `#player`——
        // 于是二次重建时 `landing` 已经是 `#player`，又被打回首页，
        // 用户第三次看到的就是首页的加载遮罩。首页本身是最重的一屏，
        // 退到那里只会更容易再被顶死。留在播放器即可。
        if fragment.hasPrefix("player") {
            return nil
        }
        return URL(string: "https://\(siteHost)/#player")
    }

    /// 「这个路由上次死在哪一刻」，跨重建、跨实例保留。
    ///
    /// 内存里那份 `processDeaths` 一直没攒到 2（日志 `08-00-01Z` 两次死亡都是 `#1`），
    /// 说明它随实例一起被换掉了 —— 追这个变量为什么不保留，不如**根本不依赖它**：
    /// 直接把死亡时刻按路由写进 `UserDefaults`，新实例读得到，进程重启也读得到。
    private static let routeDeathKey = "folia.shell.routeDeaths"

    /// 「这个路由把进程顶死过」的跨启动标记。
    ///
    /// 与 `routeDeathKey` 的区别：那个只管 60 秒内的重建降级，过期就没意义了；
    /// 这一份要活得更久 —— 用户下次再进同一个歌单，壳仍然应该按「重负载页面」
    /// 对待（注入的降载开关见 `memoryHeavyLiteral()`），否则一进去又会死，
    /// 然后又是「闪退 → 加载界面」。
    private static let memoryHeavyKey = "folia.shell.memoryHeavyRoutes"

    /// 记录「这个路由把进程顶死过」。**无条件都记。**
    ///
    /// 两份都要写：
    /// - `memoryHeavyKey`（跨启动）：下次再进同一个歌单仍然按重负载对待；
    /// - `routeDeathKey`（60 秒窗）：重建时 `rebuildWebView` 与 `launchURL` 据此决定降级。
    ///
    /// 早先只在 `webContentProcessDidTerminate` 里按「详情页或无哈希」的条件记，
    /// 落到 `noteRouteDeath` 的只有一部分，冷启动那条路就再也认不出来。
    static func recordRouteDeath(_ url: URL) {
        guard let trusted = trustedSiteURL(url) else { return }
        markMemoryHeavy(trusted)
        noteRouteDeath(trusted)
        banRoute(trusted)
    }

    /// 进程在某个深链路由上被顶死过：短时间内禁止页面再自动跳回那一条。
    ///
    /// 单靠「重建时换个落脚点」不够 —— 实测新实例明明打开的是 `#player`，
    /// 两三秒后页面自己又跳回同一个歌单，然后进程再被顶死，循环往复。
    /// 封禁只在**前台真崩溃**时生效；后台被系统回收是整机内存压力，
    /// 和这条路由本身没关系。
    private static let routeBanKey = "folia.shell.routeBan"
    private static let routeBanSeconds: Double = 180

    /// 目标地址是否还落在封禁表里（只认主框架的哈希路由）。
    static func bannedRoute(_ url: URL) -> Bool {
        // 路由封禁退役。之前"刚顶死过就 ban 180 秒"，实测变成了
        // "用户一进歌单就被踢回加载界面"——用户感知就是闪退。
        return false
    }

    private static func banRoute(_ url: URL) {
        guard UIApplication.shared.applicationState == .active else { return }
        guard let fragment = url.fragment, !fragment.isEmpty else { return }
        // 播放器 / 启动屏这些壳自己会落脚的轻路由永远不封。
        if fragment.hasPrefix("player") || fragment.hasPrefix("app-splash") { return }
        var table = UserDefaults.standard.dictionary(forKey: routeBanKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        table = table.filter { $0.value > now }
        table[fragment] = now + routeBanSeconds
        UserDefaults.standard.set(table, forKey: routeBanKey)
        CrashLog.note("==== route banned for \(Int(routeBanSeconds))s: #\(fragment) ====")
    }

    /// 「崩溃后先关 WebGL」的截止时间，存 cookie（毫秒时间戳，页面侧用 `Date.now()` 比）。
    /// iPhone 包专用。用 cookie 而不是把它烤进 document-start 用户脚本：
    /// 用户脚本在 WebView 创建时就定型了，进程被回收后只是对同一实例 load 新地址，
    /// 脚本不会重新生成 —— 烤进去的值永远是启动那一刻的状态（folia(7).log 实锤：
    /// `webgl off for 15 minutes` 打出来之后，页面侧仍然 `armed ... gl=on`）。
    /// cookie 走 `httpCookieStore`，跨文档生效，且保证在新文档的启动脚本运行前就位。
    private static let glOffCookieName = "folia_gl_off_until"

    private static func setGLBlockCookie(completion: @escaping () -> Void) {
        let untilMs = Int(Date().timeIntervalSince1970 * 1000) + 15 * 60 * 1000
        guard let cookie = HTTPCookie(properties: [
            .domain: "." + siteHost,
            .path: "/",
            .name: glOffCookieName,
            .value: String(untilMs),
            .expires: Date().addingTimeInterval(960),
        ]) else {
            completion()
            return
        }
        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) {
            CrashLog.note("==== webgl off for 15 minutes (cookie set) ====")
            completion()
        }
    }

    /// 两种壳画像，编译期决定（同一个 workflow 打两次包）。
    ///
    /// - `aggressive`（iPhone 包）：按参考包 IOS-Folia-3.0.4 的做法压渲染分辨率、
    ///   限 WebGL 上下文数、关掉每页常驻的 GPU 背景。牺牲一点画布锐度换稳定。
    /// - `light`（iPad 包）：iPad 内存更大，只做「不改变观感」的几项（封面尺寸、
    ///   懒加载、GL 上下文回收），保留站点默认背景与全部动效。
    enum ShellProfile {
        case aggressive
        case light

        static var current: ShellProfile {
            #if PROFILE_IPAD
            return .light
            #else
            return .aggressive
            #endif
        }
    }

    /// 低内存画像：在页面任何脚本读 localStorage 之前（document-start），把站点
    /// **看不见的性能项**调低，并把封面 URL 尺寸压下来。
    ///
    /// 依据：首页 / 歌单 / `#player` / `#lattice` 都死于 WebContent 内存超限，且四条死亡
    /// 记录全部 `audible=1`（播放中 GPU 出画时死）。上一版把 `visualizer_mode` 覆盖成
    /// `still`、并且断掉 WebGL —— 那会直接把用户选的歌词样式吃掉（「选了什么样式都是
    /// 静止」），已经撤销。现在只做三种不改变观感的事：
    /// 1. 背景从默认 `latent`（每页都跑的 GPU 着色器，会反复把封面传成贴图）换成
    ///    `common`（纯 DOM 几何背景），并按站点自己的开关停掉主页动态背景
    ///    （`disable_home_dynamic_background`）。**只有 iPhone 画像做这一步**，
    ///    iPad 画像保留站点默认背景与全部动效（用户要求「不用做太多优化，不然会很丑」）。
    /// 2. 把 `window.devicePixelRatio` 压到画像给定值：three / pixi 按 dpr 分配画布，
    ///    3x 的全屏画布显存是 1.5x 的数倍。歌词样式仍按用户的选择渲染，只是画布小一档。
    /// 3. 封面 URL 尺寸（歌单 / 拼贴墙更狠）+ 出生即 `loading=lazy` / `decoding=async`，
    ///    不给一次铺满几百张大图的机会。改 URL 即可，不需要站点配合。
    /// 另外回收已从文档摘除的 WebGL 上下文（学自参考包 `scale.js`）。
    /// 布尔设置按站点 `storagePrimitives` 的约定存 `'true'/'false'` 字符串。
    static func lowMemoryProfileScript() -> String {
        // iPhone 包压到 1：这与参考包 IOS-Folia-3.0.4 的最终选择一致（它的注释写明
        // 「DPR 1 已经超过屏幕物理分辨率」，再高只会在旋转 / 重建合成层时把显存翻倍）。
        // iPad 包压到 2（iPad 屏大、内存也大，2 已经够省，再低就真的糊了）。
        let aggressive = ShellProfile.current == .aggressive
        let dpr = aggressive ? "1" : "2"
        let heavyCap = aggressive ? "120" : "320"
        let profileDict = aggressive
            ? "{'visualizer_frame_rate':'60','visualizer_background_mode':'common','disable_home_dynamic_background':'true','disable_visualizer_vignette':'true','disable_visualizer_geometric_background':'true','visualizer_glow_blur_quantize':'true'}"
            : "{}"
        let profileName = aggressive ? "iphone" : "ipad"
        return """
        (function () {
            'use strict';
            function report(text) {
                try { window.webkit.messageHandlers.foliaJSLog.postMessage('LOWMEM ' + text); } catch (e) {}
            }
            // **只调「看不见的性能项」，不碰用户选过的样式。**
            //
            // 上一版把 `visualizer_mode` 写成 `still`（纯 DOM 静态歌词），用户反馈
            // 「歌词样式选了后没变化、全是静止」—— 那是壳把选择器覆盖掉了，必须撤掉。
            // 同理不断 WebGL：断掉之后 GPU 可视化模式全部拿不到画布，用户看到的
            // 也是「样式不生效」，而不是「降级」。
            // iPhone 包额外把默认的 `latent` GPU 背景（每页都在跑、反复把封面传成贴图）
            // 换成 `common`（纯 DOM 几何背景），并停掉主页动态背景 —— iPad 包不动这些。
            var PROFILE = \(profileDict);
            try {
                for (var key in PROFILE) {
                    try { localStorage.setItem(key, PROFILE[key]); } catch (e) {}
                }
            } catch (e) {}

            // **崩溃后 15 分钟内不建 WebGL 上下文。**
            //
            // folia(6).log：首页（`cv=0 gl=0`，一块画布都没有）活了 40 秒；一进歌单 /
            // 一进 `#player`，2 秒内进程就被回收。那两秒里唯一新增的重东西就是可视化器
            // 建的那块 GL 画布。参考包 IOS-Folia-3.0.4 的实测记录也是「关掉 WebGL 后
            // 回收次数为 0」。所以被回收过一次之后先关 15 分钟，保住可用性；
            // 窗口过了自动恢复，不会像上一版那样把歌词样式永久吃掉。
            // **每次文档启动时从 cookie 现读截止时间。**
            // cookie 由壳在进程被回收时写入（见 setGLBlockCookie），15 分钟内新建文档
            // 都会拿到它。
            var GL_BLOCKED = false;
            try {
                var cookieParts = (document.cookie || '').split(';');
                for (var ci = 0; ci < cookieParts.length; ci++) {
                    var eq = cookieParts[ci].indexOf('=');
                    if (eq < 0) { continue; }
                    if (cookieParts[ci].slice(0, eq).trim() === 'folia_gl_off_until') {
                        GL_BLOCKED = Date.now() < parseInt(cookieParts[ci].slice(eq + 1), 10);
                        break;
                    }
                }
            } catch (e) {}
            if (GL_BLOCKED) {
                try {
                    var rawBlockedGetContext = HTMLCanvasElement.prototype.getContext;
                    HTMLCanvasElement.prototype.getContext = function (type) {
                        if (String(type).indexOf('webgl') === 0) { return null; }
                        return rawBlockedGetContext.apply(this, arguments);
                    };
                } catch (e) {}
            }

            // **画布分辨率。**
            // 站点里的 three / pixi 按 `window.devicePixelRatio` 分配画布。这台机器真实
            // dpr 是 3，一块全屏画布的显存 + 合成层是 1 的数倍，回前台重建合成层时最容易
            // 顶死。锁到 \(dpr) 之后画布按该值分配，再由系统放大；UI 文字仍由 WebKit
            // 按物理像素重绘，不会变糊。
            try {
                Object.defineProperty(window, 'devicePixelRatio', {
                    get: function () { return \(dpr); },
                    configurable: true
                });
            } catch (e) {}

            // **WebGL 上下文回收（学自参考包 IOS-Folia-3.0.4 的 scale.js）。**
            // Pixi / three 销毁画布时不总会释放 GL 上下文，每进一次可视化 / 拼贴墙就多一个，
            // 十几个之后 WebContent 就被系统回收。参考包的判据很保守：只回收「已经从文档里
            // 摘掉、且曾经挂上去过」的画布，正在出画的那块绝不动，避免把渲染搞坏。
            var glQueue = [];
            var glLiveCount = function () {
                if (!glQueue) { return 0; }
                var n = 0;
                for (var i = 0; i < glQueue.length; i += 1) {
                    if (glQueue[i] && glQueue[i].canvas && glQueue[i].canvas.isConnected) { n += 1; }
                }
                return n;
            };
            try {
                var pruneGl = function (keep) {
                    glQueue.slice().forEach(function (entry) {
                        if (entry.canvas.isConnected) { entry.wasConnected = true; return; }
                        if (entry.canvas !== keep && entry.wasConnected) {
                            try {
                                var ext = entry.ctx.getExtension('WEBGL_lose_context');
                                if (ext) { ext.loseContext(); }
                            } catch (e) {}
                            var idx = glQueue.indexOf(entry);
                            if (idx >= 0) { glQueue.splice(idx, 1); }
                        }
                    });
                };
                var rawGl = HTMLCanvasElement.prototype.getContext;
                HTMLCanvasElement.prototype.getContext = function (type) {
                    var ctx = rawGl.apply(this, arguments);
                    if (ctx && String(type).indexOf('webgl') === 0) {
                        var known = false;
                        for (var gi = 0; gi < glQueue.length; gi += 1) {
                            if (glQueue[gi].ctx === ctx) { known = true; break; }
                        }
                        if (!known) {
                            pruneGl(this);
                            glQueue.push({ canvas: this, ctx: ctx, wasConnected: Boolean(this.isConnected) });
                            var canvasRef = this;
                            setTimeout(function () { pruneGl(canvasRef); }, 0);
                        }
                    }
                    return ctx;
                };
                try {
                    new MutationObserver(function () {
                        for (var mi = 0; mi < glQueue.length; mi += 1) {
                            if (glQueue[mi].canvas.isConnected) { glQueue[mi].wasConnected = true; }
                        }
                    }).observe(document.documentElement, { childList: true, subtree: true });
                } catch (e) {}
            } catch (e) {}

            // **封面尺寸上限。**
            // 站点列表一次铺几百张封面，大图位会要到 512~1024：一张 1024 的封面解码后
            // 就是 4MB 常驻，几百张立刻几百 MB。网易云 CDN 用 `?param=宽y高` 出图，
            // 改 URL 就换尺寸，不需要站点配合。重路由（歌单 / 拼贴墙）压到 \(heavyCap)，
            // 其它页面压到 320。
            var capFor = function () {
                var h = String(location.hash || '');
                if (h.indexOf('collection') >= 0 || h.indexOf('lattice') >= 0) { return \(heavyCap); }
                return 320;
            };
            var shrink = function (u) {
                if (typeof u !== 'string') { return u; }
                var i = u.indexOf('param=');
                if (i < 0) { return u; }
                var start = i + 6;
                var y = u.indexOf('y', start);
                if (y < 0 || y - start > 5) { return u; }
                var end = y + 1;
                while (end < u.length) {
                    var c = u.charCodeAt(end);
                    if (c < 48 || c > 57) { break; }
                    end += 1;
                }
                var w = parseInt(u.slice(start, y), 10);
                var h = parseInt(u.slice(y + 1, end), 10);
                if (!w || !h) { return u; }
                var cap = capFor();
                if (w <= cap && h <= cap) { return u; }
                var nw, nh;
                if (w >= h) { nw = cap; nh = Math.max(1, Math.round(cap * h / w)); }
                else { nh = cap; nw = Math.max(1, Math.round(cap * w / h)); }
                return u.slice(0, start) + nw + 'y' + nh + u.slice(end);
            };
            // 在 `src` 的 Setter 层降尺寸 + 出生即懒加载，不产生二次请求。
            try {
                var srcDesc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
                if (srcDesc && srcDesc.set) {
                    var rawSet = srcDesc.set;
                    Object.defineProperty(HTMLImageElement.prototype, 'src', {
                        get: srcDesc.get,
                        set: function (v) {
                            try {
                                if (!this.getAttribute('loading')) { this.setAttribute('loading', 'lazy'); }
                                if (!this.getAttribute('decoding')) { this.setAttribute('decoding', 'async'); }
                            } catch (e) {}
                            rawSet.call(this, shrink(v));
                        },
                        configurable: true
                    });
                }
            } catch (e) {}
            // **CSS 背景图必须在下发请求之前就改写。**
            //
            // 站点大量用 `style.backgroundImage` 铺封面（歌单行、拼贴墙、播放页背景）。
            // 上一版只靠 3 秒一轮的 `[style*="param="]` 扫描 —— 那等于先让浏览器按
            // 1024 的原图请求、解码（一张就是 4MB），3 秒后才换成小图：峰值早就到了。
            // 页面上几百行时，这就是「进歌单两秒内进程被回收」最合理的解释。
            // 现在在 `CSSStyleDeclaration` 的写入层截住，请求发出前就已经是 \(heavyCap) / 320。
            var cssShrink = function (v) {
                return typeof v === 'string' && v.indexOf('param=') >= 0 ? shrink(v) : v;
            };
            try {
                var rawSetProperty = CSSStyleDeclaration.prototype.setProperty;
                CSSStyleDeclaration.prototype.setProperty = function (name, value, priority) {
                    if (typeof value === 'string' && value.indexOf('param=') >= 0) {
                        value = shrink(value);
                    }
                    return rawSetProperty.call(this, name, value, priority);
                };
            } catch (e) {}
            try {
                var imageProps = ['background', 'backgroundImage', 'borderImage', 'maskImage'];
                for (var pi = 0; pi < imageProps.length; pi += 1) {
                    (function (prop) {
                        var desc = Object.getOwnPropertyDescriptor(CSSStyleDeclaration.prototype, prop);
                        if (!desc || !desc.set) { return; }
                        Object.defineProperty(CSSStyleDeclaration.prototype, prop, {
                            get: desc.get,
                            set: function (v) { desc.set.call(this, cssShrink(v)); },
                            configurable: true
                        });
                    })(imageProps[pi]);
                }
            } catch (e) {}
            // 兜底：走 `setAttribute('style', ...)` / innerHTML 铺进来的背景图。
            // 每 15 秒一轮，只处理还带着 param= 的元素（被改写过的不再命中）。
            var styleScanTick = 0;
            setInterval(function () {
                styleScanTick += 1;
                if (styleScanTick % 3 !== 0) { return; }
                try {
                    // **心跳**：每 15 秒报一次页面规模，进程死之前的最后一条就是现场。
                    report('hb dom=' + document.getElementsByTagName('*').length
                        + ' img=' + document.images.length
                        + ' cv=' + document.getElementsByTagName('canvas').length
                        + ' gl=' + glLiveCount());
                } catch (e) {}
                try {
                    var nodes = document.querySelectorAll('[style*="param="]');
                    for (var i = 0; i < nodes.length; i += 1) {
                        var el = nodes[i];
                        var css = el.getAttribute('style');
                        var next = shrink(css);
                        if (next !== css) { el.setAttribute('style', next); }
                    }
                    var imgs = document.images;
                    for (var j = 0; j < imgs.length; j += 1) {
                        var img = imgs[j];
                        if (!img.getAttribute('decoding')) { img.setAttribute('decoding', 'async'); }
                        if (!img.getAttribute('loading')) { img.setAttribute('loading', 'lazy'); }
                    }
                } catch (e) {}
            }, 5000);
            report('armed profile=\(profileName) dpr=\(dpr) caps=' + capFor() + ' mode=user gl=' + (GL_BLOCKED ? 'off' : 'on'));
        })();
        """
    }

    /// 把「刚顶死进程的深链」编成一段 document-start 脚本。
    ///
    /// 为什么放在页面侧而不是导航策略里：SPA 的换页走的是 `location.hash` /
    /// `history.pushState`，根本不经过 `decidePolicyFor`，`WKNavigationDelegate`
    /// 看不到这些导航。脚本只做两件事：
    /// 1. 启动时清掉「名字像路由、值里又带死路由」的 localStorage / sessionStorage 项，
    ///    断了 SPA 从持久化状态复活歌单的那条路；
    /// 2. 监听 `hashchange` / `popstate` 并在启动后几个时点复查 —— 一旦发现当前 hash
    ///    命中封禁路由，立刻 `replaceState` 改回 `#player` 并补发 `hashchange`，
    ///    SPA 的路由监听者收到通知后自己把视图复位。
    /// **不拦 pushState / location.hash / fetch / XHR / 点击**：那些拦截只能挡 URL 或网络，
    /// 挡不住 SPA 内部 React state 的切换，结果就是「视图进歌单、URL 没变、数据被断 →
    /// 歌单一片空白」，正是上一版用户报告的回归。
    static func routeGuardScript() -> String {
        // 封路脚本退役：不再往页面里塞"检测到这个 hash 就跳走"的守卫。
        // 之前它的"踢回首页"动作，正是用户看到的"闪退回加载界面"之一。
        return ""
    }

    /// 把「这一次启动壳要落在哪一屏」钉进 `location.hash`。
    ///
    /// 只钉**启动那一刻**：`fragment` 为 nil 时脚本什么都不做，页面自己切路由
    /// 照旧。传进来的那一屏一定经过 `rebuildWebView` 的降级计算（死路由已剔除），
    /// 所以钉住它不会把用户送回刚顶死进程的歌单。
    ///
    /// 为什么需要它：`folia(12).log` 12:48:51 壳是带着 `/` 重建的，12:48:55 的
    /// 死亡地址却已经变回 `#collection/online/netease/playlist/14400331811` ——
    /// 页面在启动的头几秒把持久化过的路由恢复了回去，而那一屏正是把进程顶死的那一屏。
    /// 原生层把落脚点算得再准，只要页面能自己改回去就白算。
    static func pinnedLandingScript(_ fragment: String?) -> String {
        // **落脚点「没有哈希」也要钉**：钉的是「空 hash」，不是「什么都不钉」。
        //
        // folia(13).log 13:20:50：重建落脚 `https://app.folia-api.top/`（无哈希），
        // 13:20:52 死亡地址又变回 `#collection/online/netease/playlist/14400331811`。
        // 上一版这里对 nil 直接返回空脚本 —— 死亡熔断重建恰恰多数落在无哈希首页，
        // 于是「钉路由」在最需要它的场景下完全不生效。
        // 普通冷启动才允许真的「什么都不钉」（传 Optional.none 之外的哨兵做不到，
        // 所以用单独的 `pinnedLandingScript(enabled:)`）。
        let want: String
        if let fragment, !fragment.isEmpty {
            let escaped = fragment
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            want = "#\(escaped)"
        } else {
            want = ""
        }
        let escapedWant = want
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (function(){
          var want = "\(escapedWant)";
          try { window.__foliaPinnedRoute = want; } catch (e) {}
          var deadline = Date.now() + 6000;
          function pin(){
            try {
              if (Date.now() > deadline) { return; }
              if (location.hash === want) { return; }
              // 直接用 want（含空串）：`want || location.hash` 在 want 为空串时
              // 会取回旧哈希，replaceState 变成无操作，「钉空哈希」就废了。
              history.replaceState(history.state, '', location.pathname + location.search + want);
            } catch (e) {}
          }
          pin();
          // **复查窗口 6 秒，不带 done 标记。**
          //
          // 上一版的 `done`（hash 一旦等于 want 就停）在最常见的场景下是反的：
          // 页面的路由恢复是「先落在壳钉的地址上、几秒后 SPA 再把它改走」，
          // done 一置位就再也守不住。改为整个启动窗口内持续钉，
          // 代价只是启动头 6 秒里用户点不进别的路由 —— 闪退现场这 6 秒
          // 本来就是加载期，用户点什么都在等。
          var timer = setInterval(function(){
            pin();
            if (Date.now() > deadline) { clearInterval(timer); }
          }, 200);
          try { window.addEventListener('load', pin); } catch (e) {}
        })();
        """
    }

    /// 普通冷启动用：真的什么都不钉，页面路由完全自由。
    static func pinnedLandingScriptDisabled() -> String {
        """
        (function(){ try { window.__foliaPinnedRoute = ''; } catch (e) {} })();
        """
    }

    /// 退役前 routeGuardScript 的完整实现，保留参考但不再被调用。
    /// （函数体原样保留在仓库历史里，线上不再注入这段脚本。）
    private static func routeGuardScriptLegacy() -> String {
        let now = Date().timeIntervalSince1970
        let table = (UserDefaults.standard.dictionary(forKey: routeBanKey) as? [String: Double] ?? [:])
            .filter { $0.value > now }
        guard !table.isEmpty else { return "" }
        let entries = table.map { fragment, until -> String in
            let escaped = fragment
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            // **必须是毫秒。** 页面侧比对的是 `Date.now()`（毫秒），
            // 这里早先塞进去的是 `timeIntervalSince1970`（秒），
            // 于是每一拍都被判成「早就过期」—— 守护脚本看着装上了，
            // 实际一条都没拦住（`folia(8).log`：`GUARD armed banned=1`
            // 之后再没有任何 blocked/kicked，页面照样跳回歌单）。
            return "[\"\(escaped)\",\(Int(until * 1000))]"
        }
        let list = "[" + entries.joined(separator: ",") + "]"
        return """
        (function(){
          var banned = \(list);
          var fallback = '#player';
          var lastKick = 0;
          // 诊断只有一条通道：页面 console 在 WKWebView 里看不到，
          // 必须走 `foliaJSLog` 落到壳的日志里，下一份 `folia.log` 才判断得了
          // 「守护脚本到底有没有跑、被谁绕过去了」。
          function report(text){
            try { window.webkit.messageHandlers.foliaJSLog.postMessage('GUARD ' + text); } catch (e) {}
          }
          function blocked(hash){
            var h = String(hash || '');
            if (h.charAt(0) === '#') { h = h.slice(1); }
            if (!h) { return false; }
            for (var i = 0; i < banned.length; i += 1) {
              var frag = banned[i][0];
              if (banned[i][1] <= Date.now()) { continue; }
              if (h.slice(0, frag.length) === frag) { return true; }
            }
            return false;
          }
          function kick(){
            try {
              var h = location.hash || '';
              if (!blocked(h)) { return; }
              var now = Date.now();
              if (now - lastKick < 400) { return; }
              lastKick = now;
              report('kicked ' + h);
              try { history.replaceState(history.state, '', location.pathname + location.search + fallback); } catch (e) {}
              try { location.hash = fallback; } catch (e) {}
              try { window.dispatchEvent(new HashChangeEvent('hashchange')); } catch (e) {}
            } catch (e) {}
          }
          function routeOf(url){
            try { return (new URL(String(url), location.href).hash) || ''; } catch (e) { return ''; }
          }
          // **不拦任何导航入口。** 历史教训：
          // 拦 `history.pushState` / `location.hash =` / `location.href =` / `<a>` 点击，
          // 全都只能挡住 URL 这一层 —— SPA 内部的 React state 已经切到歌单视图了，
          // 渲染照常发生，发的数据请求又被我们断掉，用户看到的就是「点进歌单一片空白」。
          // 真正危险的「进程死后 SPA 自动复活歌单」由两件事接住：
          // 1. 原生层的 `landing sources` 在重建时已经把落脚点降级到 `#player`；
          // 2. 下面的 kick() 发现当前 hash 命中封禁就立刻把它改回 `#player`，
          //    SPA 的 hashchange/popstate 监听者收到通知后自己会复位视图。
          // 用户**主动**点歌单属于正常浏览，不该拦 —— 进程真死了，
          // 原生会准确记下死在哪条路由，下次启动降级，而不是让用户连试都试不了。
          // 封禁期内的导航意图还会被 SPA 的持久化状态重新激活。
          // 只删「名字像路由/视图、值里又带死路由」的存储项 ——
          // 不碰播放队列与登录态，也不动 DOM（这两点上一个版本踩过坑）。
          try {
            var routeKeyPattern = /route|view|nav|location|last|history|tab/i;
            ['localStorage', 'sessionStorage'].forEach(function(name){
              var store = window[name];
              if (!store) { return; }
              var keys = [];
              for (var i = 0; i < store.length; i += 1) { keys.push(store.key(i)); }
              for (var k = 0; k < keys.length; k += 1) {
                var key = keys[k];
                if (!key || !routeKeyPattern.test(key)) { continue; }
                var val = null;
                try { val = store.getItem(key); } catch (e) { continue; }
                if (!val) { continue; }
                for (var b = 0; b < banned.length; b += 1) {
                  var frag = banned[b][0].replace(/^#/, '');
                  if (banned[b][1] > Date.now() && val.indexOf(frag) >= 0) {
                    try { store.removeItem(key); } catch (e) {}
                    report('dropped poisoned route state ' + key);
                    break;
                  }
                }
              }
            });
          } catch (e) {}
          // **不拦数据请求、不拦 history.pushState/replaceState。**
          // 这两层拦截都只能挡住 URL / 网络这一面，挡不住 SPA 内部 React state 的切换，
          // 结果就是「用户点歌单 → URL 没变但视图变了 → 渲染需要的数据被我们断掉 → 空白」。
          // 进程真死了由原生层的 `landing sources` 降级 + 这里的 kick() 收尾，足够了。
          report('armed banned=' + banned.length + ' hash=' + (location.hash || '-'));
          window.addEventListener('hashchange', kick);
          window.addEventListener('popstate', kick);
          document.addEventListener('DOMContentLoaded', kick);
          // 只在封禁窗口内高频复查：SPA 恢复路由往往发生在加载完成后的十几秒里，
          // 单靠几个固定时间点会漏掉。200ms × 600 拍 ≈ 2 分钟，之后自然停。
          var ticks = 0;
          var timer = setInterval(function(){
            kick();
            ticks += 1;
            // 前 40 秒各报一次当前哈希：下一份日志据此判断
            // 「页面是不是自己跳走了、跳的时候守护脚本在不在」。
            if (ticks === 25 || ticks === 50 || ticks === 100 || ticks === 200) {
              report('tick ' + ticks + ' hash=' + (location.hash || '-'));
            }
            if (ticks > 600) { clearInterval(timer); }
          }, 200);
          [0, 400, 1200, 2500, 5000].forEach(function(ms){ setTimeout(kick, ms); });
        })();
        """
    }

    static func markMemoryHeavy(_ url: URL) {
        var set = Set(UserDefaults.standard.stringArray(forKey: memoryHeavyKey) ?? [])
        set.insert(url.absoluteString)
        UserDefaults.standard.set(Array(set), forKey: memoryHeavyKey)
        CrashLog.note("==== memory heavy route remembered: \(url.absoluteString) ====")
    }

    static func isMemoryHeavy(_ url: URL) -> Bool {
        let set = Set(UserDefaults.standard.stringArray(forKey: memoryHeavyKey) ?? [])
        return set.contains(url.absoluteString)
    }

    /// 这个路由自己真的画出来了：把「重负载」标记撤掉。
    ///
    /// 只在 `markVisiblePageIfNeeded` 里调，且传进去的是页面**当前真实所在**的地址。
    /// 不这么做的话，标记一旦写下就永远洗不掉 —— 用户换了部手机、清了缓存、
    /// 或者站点本身优化过之后，那个歌单会被永久按最重的模式对待。
    private static func clearMemoryHeavy(_ url: URL) {
        var set = Set(UserDefaults.standard.stringArray(forKey: memoryHeavyKey) ?? [])
        guard set.remove(url.absoluteString) != nil else { return }
        UserDefaults.standard.set(Array(set), forKey: memoryHeavyKey)
        CrashLog.note("==== memory-heavy flag cleared: \(url.absoluteString) ====")
    }

    /// 把一个「会顶死进程」的路由从落盘的浏览历史里抹掉。
    ///
    /// 只抹**同一条**路由：用户别的歌单、别的页面照常记住。
    /// 目的很直接 —— 这个地址永远不该再成为重建的落脚点。
    /// 重建的地址优先级是「死前那页 > 首屏那页 > 落盘历史 > 首页」，
    /// 前三个都可能是这个歌单，所以落盘这份也必须在死亡那一刻就断掉，
    /// 否则下一次启动（或新实例的又一次重建）会把它原样读回来。
    private static func forgetVisibleRoute(_ url: URL) {
        let raw = UserDefaults.standard.string(forKey: pageHistoryKey)
        guard let saved = raw.flatMap(URL.init(string:)) else { return }
        guard saved.absoluteString == url.absoluteString else { return }
        UserDefaults.standard.removeObject(forKey: pageHistoryKey)
        CrashLog.note("==== forgot risky landing route: \(url.absoluteString) ====")
    }

    /// 注入给页面的降载开关：`window.__foliaLowMemory`。
    ///
    /// 壳这边只负责把「当前页是不是顶死过进程的那种重页面」告诉页面，
    /// 具体怎么省内存由页面自己决定 —— 壳不碰 DOM，避免和 React 抢节点。
    ///
    /// 注意：线上入口脚本目前**并没有**读这个开关（`assets/main-*.js` 里没有相关代码），
    /// 所以真正生效的降载是 WebKit 层的内容规则（拦 `@2x`/`@3x` 封面解码，
    /// 见 `buildConfiguration` 里的 `downscaleRuleJSON`）。这两位留着不改名，
    /// 只是给页面以后加降载逻辑时留的接口，同时也方便真机日志核对判定是否打中。
    ///
    /// `audioKeeperScript` 在 `.atDocumentStart` 注入，那时 `location.href`
    /// 已经是目标路由，所以这里只需要把地址表编进脚本，不必按导航逐次重装。
    private static func memoryHeavyLiteral() -> String {
        let list = UserDefaults.standard.stringArray(forKey: memoryHeavyKey) ?? []
        let quoted = list.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
        return "[" + quoted.joined(separator: ",") + "]"
    }

    /// 记一次「这个地址把进程顶死了」。
    private static func noteRouteDeath(_ url: URL) {
        // 路由死亡簿退役。它存在的全部意义就是给 bannedRoute/routeGuardScript
        // 喂数据；那俩都关了，它也不再需要记任何东西。
        return
    }

    /// 这个地址在最近一分钟内死过几次（只看近期，旧记录不算）。
    private static func deathCount(for url: URL) -> Int {
        let table = UserDefaults.standard.dictionary(forKey: routeDeathKey) as? [String: Double] ?? [:]
        guard let stamp = table[url.absoluteString] else { return 0 }
        return Date().timeIntervalSince1970 - stamp < 60 ? 1 : 0
    }

    /// 页面确实画出来了，这个路由就洗清嫌疑，下次仍允许直接落脚。
    private static func clearRouteDeath(_ url: URL) {
        var table = UserDefaults.standard.dictionary(forKey: routeDeathKey) as? [String: Double] ?? [:]
        guard table.removeValue(forKey: url.absoluteString) != nil else { return }
        UserDefaults.standard.set(table, forKey: routeDeathKey)
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
        // 旧实例迟到的回调一律作废：重建之后它仍可能补发一次 `didStart`，
        // 那会把新实例的首屏状态置假、还可能清掉 `pendingOnlineHandoff`。
        guard webView === self.webView else { return }
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
            } else if body == "intent-pause-user" {
                // 页面直接点名「用户按的暂停」：不再靠手势龄去猜（见 `notifyUserPause`）。
                container?.markUserPauseFromPage()
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

// MARK: - 汽水音乐音源

/// 汽水音乐的请求通道。
///
/// 线上页把汽水音源的全部请求收敛到 `window.electron.qishuiRequest(action, params)`，
/// 桌面端由 Electron 主进程直接跑官方接口；iOS 壳里没有 Electron，所以按协议自己实现。
///
/// 登录走**网页端扫码协议**，不是开放平台那套：
/// - `POST api.qishui.com/passport/web/get_qrcode/` 拿二维码；
/// - `POST api.qishui.com/passport/web/check_qrconnect/` 轮询状态；
/// - 确认后服务端直接把会话 cookie 下发到 `Set-Cookie`，登录即完成。
///
/// 关键点有两个，缺一不可：
/// 1. 这些接口都要求 44 位 `a_bogus` 签名。签名由抖音风控 SDK 结合浏览器环境算出，
///    原生侧造不出来，所以在壳里开一个隐藏的 WKWebView 跑 SDK（`www/qishui-signer/`），
///    只取签名、不发请求。
/// 2. 会话 cookie 必须写进**页面那个 WKWebView 的 `WKHTTPCookieStore`**，
///    而不是 URLSession 自己的 cookie 仓，否则页面后续请求带不上登录态。
///
/// 返回值形状由页面严格依赖（`qishuiTransport.ts`）：
/// `{ok:true, data}` 或 `{ok:false, error:{code, message, upstreamCode?, stage?}}`。
private final class QishuiBridge: NSObject, WKScriptMessageHandler {
    /// 汽水网页端登录的 aid：`get_qrcode` / `check_qrconnect` 都按它识别应用。
    private static let passportAid = "386088"
    private static let passportBase = "https://api.qishui.com/passport/web"

    /// 页面上 `login_qr_key` → `login_qr_create` → `login_qr_check` 三步共用的会话。
    private struct QRSession {
        let token: String
        let image: String
        let expires: Date
        /// 观测用：这个 token 的轮询是否已经打过一条 waiting 日志（只打第一条，
        /// 避免 2-3 秒一拍的轮询把日志刷爆）。
        var loggedWaiting = false
    }

    private var pendingQR: [String: QRSession] = [:]

    weak var webView: WKWebView?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 跑签名 SDK 的隐藏容器。惰性创建，只在真正要登录时才付出这份启动开销。
    private lazy var signer = QishuiSigner()

    /// 页面上一次成功的登录态。cookie 由页面自己的 `WKHTTPCookieStore` 保存，
    /// 这里只记「有没有登录过」，用于诊断和 `login_status`。
    private static let signedInKey = "folia.qishui.signedIn"

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String else { return }
        // 诊断通道：页面侧调 `window.electron.getLoginDiagnostics()` 时会带 action `__diag`。
        // 之前失败只剩一句 `start-error`，分不清是网络、解包还是壳没回包。
        if body["action"] as? String == "__diag" {
            DispatchQueue.main.async { [weak self] in
                self?.reply(id: id, payload: ["ok": true, "data": Self.diagnostics()])
            }
            return
        }
        guard let action = body["action"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]
        // 每次调用都必须回一条结果。页面侧抛异常时整个 Promise 永久挂起，
        // 界面上就是「点了没反应」，所以这里不能有静默 return。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // 诊断：页面到底在要哪些接口。没有这行，日志里只有「登录成功」，
            // 完全看不出「进不去」卡在哪一步。轮询的 check 太密，排除掉。
            if action != "login_qr_check" {
                CrashLog.note("==== qishui action=\(action) ====")
            }
            let result: [String: Any]
            do {
                result = ["ok": true, "data": try self.perform(action, params)]
            } catch let failure as Failure {
                // 把后端原话留在日志里：界面上只看到「失败」，但下一次诊断报告能带出原因。
                NSLog("[Qishui] %@ failed: %@ %@", action, failure.code, failure.message)
                CrashLog.note("==== qishui \(action) failed: \(failure.code) \(failure.message) ====")
                result = ["ok": false, "error": failure.payload]
            } catch {
                NSLog("[Qishui] %@ failed: %@", action, String(describing: error))
                result = ["ok": false, "error": ["code": "invalid-response",
                                                 "message": "Qishui operation failed"]]
            }
            self.reply(id: id, payload: result)
        }
    }

    /// 壳侧自检：页面在诊断报告的 `qishui details` 里逐行展示这些内容。
    ///
    /// 之前这里是空数组，报告永远是 `(none)`。现在至少带上「用的是哪套登录协议」
    /// 「有没有登录成功过」，下次出问题能直接排除壳这一层。
    private static func diagnostics() -> [String] {
        let signedIn = UserDefaults.standard.bool(forKey: signedInKey)
        return [
            "bridge=swift",
            "qishuiRequest=native",
            "login=web-passport",
            "signedIn=" + (signedIn ? "yes" : "no")
        ]
    }

    // MARK: - 操作分发

    private func perform(_ action: String, _ params: [String: Any]) throws -> Any {
        switch action {
        case "login_qr_key": return try createQRKey()
        case "login_qr_create": return try qrImage(key: string(params["key"]))
        case "login_qr_check": return try checkQR(key: string(params["key"]))
        case "login_qr_cancel":
            // **「取消」不再真的删除二维码会话。**
            //
            // folia(11).log 11:57:26~11:57:27：原生轮询刚查到 `scanned`
            //（用户已扫码、正等另一台设备点确认），下一拍页面就发了
            // `login_qr_cancel` —— 页面侧扫码 UI 的取消计时和轮询节奏对不上，
            // 会话一删，壳的轮询立刻停（`pendingQR[token] == nil`），
            // `confirmed` 永远等不到，用户在手机上点了确认也白点。
            // 扫码会话反正 5 分钟自动过期，这里只记日志、不删，
            // 让壳的轮询一直跑到 confirmed / expired 为止。
            CrashLog.note("==== qishui login_qr_cancel ignored (keep polling) ====")
            // 取消指令只当噪音，但**必须保证自驱动轮询还在跑**：
            // 页面要么带着 key 来（那就绑到这条会话），要么干脆不带
            //（那就续上手上唯一那条未结算的会话）。
            let key = (params["key"] as? String).flatMap { pendingQR[$0] != nil ? $0 : nil }
                ?? pendingQR.keys.first
            if let key, nativeQRToken != key {
                startNativeQRPoll(token: key)
            }
            return NSNull()
        case "search": return ["items": [], "hasMore": false, "nextOffset": 0]
        case "login_status":
            // **必须回一个「像用户」的对象。**
            // 页面侧 `normalizeQishuiUser` 只认 `id`，缺了直接抛 `invalid-response`，
            // 登录收尾就被记成 `account-not-read` —— 表现就是「扫码确认后没进去」。
            // 之前这里回 `{loggedIn: true}`，值是真的、形状却不对，读账号那一步必然失败。
            guard UserDefaults.standard.bool(forKey: Self.signedInKey) else { return NSNull() }
            return currentUser()
        case "user_playlists":
            // 登录后页面立刻会读账号的歌单 / 喜欢列表。壳没有汽水的车机接口，
            // 这里回**合法的空页**而不是抛错：`playlistsOf` 一失败，
            // 整个登录收尾就落回 `account-not-read`，界面停在失败态。
            return ["items": [], "hasMore": false, "total": 0, "nextOffset": 0]
        case "liked_songs":
            return ["ids": [], "whole": true]
        case "recent_played", "playlist_tracks", "artist_songs":
            return ["items": [], "hasMore": false, "nextOffset": 0]
        case "playlist_detail", "artist_detail":
            return NSNull()
        case "logout":
            pendingQR.removeAll()
            stopNativeQRPoll(reason: "logout")
            UserDefaults.standard.removeObject(forKey: Self.signedInKey)
            return NSNull()
        default:
            // 登录成功之后，页面还会继续读首页推荐 / 排行榜 / 最近播放等接口。
            // 壳里没有汽水的车机签名（P-256 CSR + ticket guard），给不出真数据，
            // 但**抛错会让整个汽水入口显示为失败** —— 真机上的表现就是
            // 「显示登录成功，却进不去」。回一个合法空页，至少能进去看到「暂无内容」。
            CrashLog.note("==== qishui unsupported action=\(action), empty page ====")
            return ["items": [], "hasMore": false, "nextOffset": 0]
        }
    }

    // MARK: - 扫码登录

    /// 第一步：要一张二维码。
    ///
    /// 网页端协议里 `get_qrcode` 一次就返回 token 和图，页面的「key」和「创建」
    /// 两步在这里合并成一次请求，token 就是 key。
    private func createQRKey() throws -> Any {
        let json = try signedGet("/get_qrcode/", query: Self.deviceParams() + [
            ("next", "https://api.qishui.com"),
            ("need_logo", "false"),
            ("need_short_url", "false"),
            ("is_frontier", "true")
        ])
        let data = json["data"] as? [String: Any] ?? [:]
        guard let token = data["token"] as? String, !token.isEmpty else {
            throw Failure(code: "invalid-response", message: "Qishui returned no QR token")
        }
        // **不用**服务端返回的 `qrcode` 图：那张图里编的是网页端地址，
        // 抖音扫开就是一个 404 页。改为按客户端的扫码入口自己生成一张，
        // 地址形状是汽水客户端的 `scan_login` 链接。
        let image = try Self.makeQRImage(Self.scanURL(token: token))
        pendingQR[token] = QRSession(token: token,
                                     image: image,
                                     expires: Date().addingTimeInterval(300))
        // **原生自驱动轮询：页面死了也有人接住「已扫码确认」。**
        //
        // folia(10).log：整份日志只有 login_status，从头到尾没有一条
        // `qr check state=...` —— 页面侧 qr key 存 JS 内存，WebContent 每 3~7 秒
        // 死一次，key 随进程丢失，页面重启后不再轮询；扫码成功（服务端状态）
        // 永远没人来问，`signedInKey` 永远不置位 —— 用户看到的就是
        // 「另一台设备显示登录成功，Folia 没进去」。
        // 现在壳自己按 3 秒一拍查这个 token，confirmed 时置位 + 收 cookie
        // （UserDefaults / URLSession 仓都是持久的，不随页面进程死而丢）；
        // 页面下一次 login_status 就能捡起登录态。
        startNativeQRPoll(token: token)
        return ["key": token]
    }

    /// 二维码里编的地址：汽水客户端的扫码登录入口。
    ///
    /// 抖音只认这种形状 —— 它按 `bff-pc` 这个入口把 token 交给账号服务，
    /// 换成网页端地址会被当成未知路由，直接 404。
    private static func scanURL(token: String) -> String {
        var comps = URLComponents(string: "https://bff-pc.qishui.com/light/invoke/scan_login")!
        comps.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "os", value: "Mac"),
            // 展示在抖音确认页上的设备名。抖音要求非空，缺了会被拒。
            URLQueryItem(name: "computer_name", value: "Folia")
        ]
        // `+` 要转成 `%20`：token 里有 `+` 时，抖音按表单解码会把它当成空格。
        return comps.string!.replacingOccurrences(of: "+", with: "%20")
    }

    /// 把一段文本编成二维码，返回 `data:image/png;base64,...`。
    ///
    /// 用系统自带的 `CIQRCodeGenerator`，不引第三方库：二维码内容必须由我们自己决定，
    /// 服务端给的那张图内容不对。
    private static func makeQRImage(_ text: String) throws -> String {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else {
            throw Failure(code: "invalid-response", message: "QR generate failed")
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent),
              let png = UIImage(cgImage: cgImage).pngData() else {
            throw Failure(code: "invalid-response", message: "QR encode failed")
        }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private func qrImage(key: String) throws -> Any {
        guard let entry = pendingQR[key] else {
            throw Failure(code: "unavailable", message: "QR session expired")
        }
        return ["imageUrl": entry.image]
    }

    /// 原生自驱动的扫码轮询。页面侧（`login_qr_check`）照常可用，这里只是兜底：
    /// WebContent 进程死亡循环时页面轮询断了流，由壳把它接回来。
    private var nativeQRTimer: Timer?

    /// 轮询用的一次性定时器拍数（每拍 3 秒）。每拍都重新排一发，
    /// 不依赖「发出去的那一发回调一定会回来」。
    private var nativeQRToken: String?
    private var nativeQRTicks = 0

    private func startNativeQRPoll(token: String) {
        nativeQRTimer?.invalidate()
        nativeQRTimer = nil
        nativeQRToken = token
        nativeQRTicks = 0
        CrashLog.note("==== qishui native poll started ====")
        scheduleNativeQRPoll()
    }

    /// **一拍一排，而不是 `Timer(repeats: true)`。**
    ///
    /// folia(12).log 的现场：12:46:45 最后一拍 `native poll state=scanned`，
    /// 之后 2 分半钟再无任何 `native poll`，直到进程重启。`login_qr_cancel`
    /// 已经被忽略、会话也还在 `pendingQR` 里，唯一剩下的可能是重复定时器
    /// 在某一拍之后不再触发（投递到的 runloop / 进程状态一变就静默失效，
    /// 而 `nativeQRTimer` 仍非 nil，之后没有任何人再把它拉起来）。
    /// 改成每拍结束都重新 `asyncAfter` 排下一发：只要会话在，
    /// 序列就会一直自续，任何单拍丢失都能在 3 秒后自愈。
    private func scheduleNativeQRPoll() {
        nativeQRTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            self?.nativeQRPollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        nativeQRTimer = timer
    }

    private func stopNativeQRPoll(reason: String) {
        nativeQRTimer?.invalidate()
        nativeQRTimer = nil
        nativeQRToken = nil
        nativeQRTicks = 0
        CrashLog.note("==== qishui native poll stopped (\(reason)) ====")
    }

    private func nativeQRPollTick() {
        guard let token = nativeQRToken else { return }
        let signedIn = UserDefaults.standard.bool(forKey: Self.signedInKey)
        guard pendingQR[token] != nil, !signedIn else {
            stopNativeQRPoll(reason: signedIn ? "signed-in" : "session-gone")
            return
        }
        nativeQRTicks += 1
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // 页面同拍轮询时 `checkQR`（含去重的 waiting 日志）照旧；
            // 原生自驱动这一路直接走 inner，避免双份日志。
            let result = try? self.checkQRInner(key: token)
            let state = (result as? [String: Any])?["state"] as? String
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 失败也照常续下一拍：`scanned` 到 `confirmed` 之间任何一次
                // 网络抖动都不该把整条轮询带走（会话 5 分钟才过期）。
                guard let state else {
                    CrashLog.note("==== qishui native poll error, retrying ====")
                    self.scheduleNativeQRPoll()
                    return
                }
                if state == "confirmed" || state == "expired" || state == "scanned" {
                    CrashLog.note("==== qishui native poll state=\(state) ====")
                }
                if state == "confirmed" || state == "expired" {
                    self.stopNativeQRPoll(reason: state)
                    // **确认登录后立刻把页面从「等待扫码」界面里拉出来。**
                    //
                    // 页面自己的轮询已经被取消指令断了流；如果不通知它，
                    // 它要等下一次 login_status（往往是重启 / 闪退之后）才能
                    // 发现登录成功。这里主动触发一次存储事件，页面侧的
                    // qishui shim 监听到后立刻重查登录态、收尾进主界面。
                    if state == "confirmed", let view = self.webView {
                        // **确认后用 reload 收尾，而不是写 localStorage。**
                        //
                        // 之前的方案是 `localStorage.setItem('folia_qishui_signed_in', …)`，
                        // 指望页面侧监听 storage 事件 —— 但 WebKit 里同页面的
                        // storage 写入根本不触发本页的 storage 事件（那只跨文档），
                        // 页面侧也从未装过任何读这个 key 的逻辑，等于纯空转。
                        // 页面此刻停在「等待扫码」界面，它自己的轮询早被
                        // login_qr_cancel 断了，没有任何事件会把它拉出来。
                        //
                        // reload 是最朴素也最可靠的收尾：页面重启时第一件事
                        // 就是 `login_status`，壳这边 signedInKey 已置位、
                        // `login_status` 会回 `currentUser()`（合法形状），
                        // 登录收尾由页面自己的启动流程完成。cookie 若已拿到
                        // 也随 importCookies 进了 WebView 存储，一并生效。
                        CrashLog.note("==== qishui confirmed: reloading page to finish login ====")
                        view.reload()
                    }
                    return
                }
                self.scheduleNativeQRPoll()
            }
        }
    }

    /// 轮询观测层：check 的结果平时不进日志（太密），但状态变化必须可见 ——
    /// 「另一台设备显示登录成功，这边永远等待」这种现场，没有这条日志就分不出
    /// 是「页面没在轮询」还是「轮询一直 waiting」。waiting 只打每个 token 的第一条。
    private func checkQR(key: String) throws -> Any {
        // **页面只要还在问，就说明会话还活着 —— 顺手把原生自驱动接回来。**
        //
        // folia(12).log：`login_qr_cancel` 之后页面的轮询断了，壳这边的轮询也
        // 在同一次操作里没了声。谁先停的分布清，那就别赌：页面每问一次
        // `login_qr_check`，壳就确保自驱动轮询在线。页面停了没关系，壳还在问；
        // 页面在问就更不影响（两条轮询都只是读同一个 token 的状态）。
        if nativeQRToken != key, pendingQR[key] != nil {
            startNativeQRPoll(token: key)
        }
        let result = try checkQRInner(key: key)
        let state = (result as? [String: Any])?["state"] as? String ?? "?"
        if state != "waiting" {
            CrashLog.note("==== qishui qr check state=\(state) ====")
        } else if !(pendingQR[key]?.loggedWaiting ?? true) {
            pendingQR[key]?.loggedWaiting = true
            CrashLog.note("==== qishui qr check state=waiting (first) ====")
        }
        return result
    }

    private func checkQRInner(key: String) throws -> Any {
        guard let entry = pendingQR[key] else { return ["state": "expired"] }
        if Date() > entry.expires {
            pendingQR.removeValue(forKey: key)
            return ["state": "expired"]
        }
        // `token` 同时放 query 与 body，`next` 也补进 query。
        //
        // 真机日志 `case=account-not-read ... code=3 message=缺少参数`：
        // `get_qrcode` 成功（token 拿到了），紧接着第一次 `check_qrconnect`
        // 就被服务端按「缺参数」拒了 —— 说明它要的参数不在我们发的位置上。
        // 网页端两个位置都认，服务端校验只认 query 里的 `token`/`next`，
        // 所以两边都带（重复参数不会报错），再留 body 兼容旧的签名校验。
        let json = try signedPost("/check_qrconnect/",
                                  query: Self.deviceParams() + [
                                    ("next", "https://api.qishui.com"),
                                    ("token", entry.token)
                                  ],
                                  body: [("token", entry.token)])
        let data = json["data"] as? [String: Any] ?? [:]
        let status = ((data["status"] as? String) ?? "").lowercased()
        let code = (data["error_code"] as? NSNumber)?.intValue ?? 0
        switch status {
        case "confirmed":
            // 服务端说「已确认」不等于壳已经拿到会话：session cookie 可能还没下发。
            //
            // 真机日志：扫码确认之后页面一直停在等待态，最后没进登录 ——
            // 原因就是这里。`check_qrconnect` 在 confirmed 这一拍只回状态，
            // 真正的会话是**跟着 `redirect_url` 那次跳转**下发的
            // （Set-Cookie 落在重定向响应上）。只读 `status` 永远拿不到 cookie。
            // 所以补一次跳转，再判定会话。
            if !hasSession(), let redirect = (data["redirect_url"] as? String), !redirect.isEmpty {
                followLoginRedirect(redirect)
            }
            CrashLog.note("==== qishui qr confirmed, session=\(hasSession()) ====")
            // **服务端确认过，登录就算成功了。**
            //
            // 会话 cookie 拿不到只影响「壳自己去拉汽水数据」；而这个壳里所有
            // 汽水请求本来就由这里代发，登录态是由 `login_status` 回答的。
            // 死等 cookie 只会让页面永远停在等待态 —— 真机上的表现正是
            // 「扫码确认后没进去」。cookie 真拿到了仍然照常导进 WebView。
            pendingQR.removeValue(forKey: key)
            UserDefaults.standard.set(true, forKey: Self.signedInKey)
            try? importCookies()
            return ["state": "confirmed"]
        case "scanned":
            return ["state": "scanned"]
        case "expired":
            pendingQR.removeValue(forKey: key)
            return ["state": "expired"]
        case "error", "failed":
            pendingQR.removeValue(forKey: key)
            let message = (data["description"] as? String) ?? "扫码登录失败"
            throw Failure(code: "unavailable", message: message,
                          upstream: String(code), stage: "account")
        default:
            // 网页端的「等待扫码」有两条路：`status` 为空且 `error_code=0`，
            // 或者风控要求稍后再查（`error_code=7`）。两者都当作继续轮询。
            if code == 0 || code == 7 { return ["state": "waiting"] }
            pendingQR.removeValue(forKey: key)
            let message = (data["description"] as? String) ?? "扫码登录失败（code=\(code)）"
            throw Failure(code: "unavailable", message: message,
                          upstream: String(code), stage: "account")
        }
    }

    /// `login_status` 要回的用户对象。
    ///
    /// 页面侧只要求 `id` 非空（昵称 / 头像都是展示字段）。壳走的是网页通行证登录，
    /// 拿不到车机接口的 `me/info`，所以用会话 cookie 的哈希做稳定 id：
    /// 同一次登录跨启动不变，退出登录换一份，不会每次启动都变成「另一个用户」。
    private func currentUser() -> [String: Any] {
        let seed = (session.configuration.httpCookieStorage?.cookies ?? [])
            .first { $0.name == "sessionid" || $0.name == "sessionid_ss" }?
            .value ?? UUID().uuidString
        let digest = SHA256.hash(data: Data(seed.utf8))
        let id = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return ["id": id, "nickname": "汽水音乐", "avatar": "", "isVip": false]
    }

    /// 会话 cookie 是否已经到手。`sessionid` 一族任一存在即视为登录完成。
    ///
    /// 名字放宽到「含 session / 以 sid_ 开头 / passport_csrf」：
    /// 汽水的登录票据除了 `sessionid` 还可能是 `sid_ucp_v1`、`session_key`
    /// 这类变体，死守四个名字会漏判成「一直没登录」。
    private func hasSession() -> Bool {
        let names: Set<String> = ["sessionid", "sessionid_ss", "sid_tt", "sid_guard"]
        let cookies = session.configuration.httpCookieStorage?.cookies ?? []
        return cookies.contains { cookie in
            guard !cookie.value.isEmpty else { return false }
            if names.contains(cookie.name) { return true }
            let lowered = cookie.name.lowercased()
            return lowered.contains("session") || lowered.hasPrefix("sid_") || lowered.contains("passport_csrf")
        }
    }

    /// 跟一次 `redirect_url`，把那次跳转下发的 `Set-Cookie` 收进会话。
    ///
    /// 扫码确认后会话并不在 `check_qrconnect` 的响应里，而是在它给的跳转上。
    /// 同步等最多 8 秒：这是第二道重定向，正常 1 秒内就回来了。
    private func followLoginRedirect(_ raw: String) {
        guard let url = URL(string: raw), url.scheme == "https" else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + 8)
    }

    /// 把这次登录产生的 cookie 同步到页面的 WebView。
    ///
    /// 登录请求是 URLSession 发的，`Set-Cookie` 落在它自己的 cookie 仓里；
    /// 页面后续请求（`luna/me` 等）走的是 WKWebView，两个仓不互通，必须搬一次。
    /// `WKHTTPCookieStore` 只能在主线程碰，这里同步等它写完，保证随后的轮询结果
    /// 返回给页面时，页面紧接着发的请求已经能带上登录态。
    private func importCookies() throws {
        guard let webView,
              let cookies = session.configuration.httpCookieStorage?.cookies,
              !cookies.isEmpty else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let targets = cookies.filter {
            $0.domain.contains("qishui.com") || $0.domain.contains("douyin.com")
        }
        guard !targets.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let group = DispatchGroup()
            for cookie in targets {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { done.signal() }
        }
        _ = done.wait(timeout: .now() + 5)
    }

    // MARK: - 网络

    /// 带 `a_bogus` 签名的 GET。
    ///
    /// 网页端这两个接口都是 GET，`aid` 等参数必须写在 **query string** 上：
    /// 只放 body 会被服务端当成缺少参数的裸路径，直接回 404。
    /// 签名也必须在参数拼好之后做 —— `a_bogus` 是按整个地址算出来的。
    private func signedGet(_ path: String, query: [(String, String)]) throws -> [String: Any] {
        let qs = form(query)
        let unsigned = Self.passportBase + path + (qs.isEmpty ? "" : "?" + qs)
        let signed = try signer.sign(url: unsigned)
        guard let url = URL(string: signed) else {
            throw Failure(code: "invalid-response", message: "Invalid signed Qishui URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.setValue("https://www.qishui.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://www.qishui.com/", forHTTPHeaderField: "Referer")

        // **GET 路也要短超时（login_status / login_qr_key / login_qr_create 都走这里）。**
        //
        // folia(14).log 14:16:26：页面启动第一发 `login_status` 挂满 30 秒，
        // 登录 UI 卡死在「查询登录态」，出码两步一次都没发出。上一轮只改了
        // signedPost，漏了这条 —— 而 login_status 恰恰是 GET。
        request.timeoutInterval = 10
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response as? HTTPURLResponse
            box.error = error
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + 12) == .timedOut {
            throw Failure(code: "network", message: "Qishui service could not be reached")
        }
        if box.error != nil {
            throw Failure(code: "network", message: "Qishui service could not be reached")
        }
        guard let http = box.response, let data = box.data else {
            throw Failure(code: "network", message: "Qishui service could not be reached")
        }
        // 登录成功后 `Set-Cookie` 会在这里，先收进 URLSession 的仓，再同步给页面。
        if let headers = http.allHeaderFields as? [String: String],
           let url = http.url {
            session.configuration.httpCookieStorage?.setCookies(
                HTTPCookie.cookies(withResponseHeaderFields: headers, for: url),
                for: url, mainDocumentURL: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // 404 / 403 这类「地址问题」只靠状态码定位不了：把签名器交回来的实际地址
            // 和响应体前一段打出来，才能判断是路径拼错、还是域名被 SDK 换掉。
            let snippet = box.data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? ""
            NSLog("[Qishui] http %d path=%@ signed=%@ body=%@",
                  http.statusCode, path, signed, snippet)
            throw Failure(code: http.statusCode == 429 ? "unavailable" : "network",
                          message: "Qishui HTTP \(http.statusCode)",
                          upstream: String(http.statusCode))
        }
        return try jsonObject(data)
    }

    /// 带 `a_bogus` 签名的 POST。
    ///
    /// 网页端 `check_qrconnect` 的形状是「公共参数在 query、`token` 在 body」，
    /// 还要带 `x-ss-stub`（body 的 SHA-256 大写十六进制）作为完整性校验。
    /// 三者缺一个都会被服务端判成非法请求。
    private func signedPost(_ path: String,
                            query: [(String, String)],
                            body: [(String, String)]) throws -> [String: Any] {
        let qs = form(query)
        let payload = form(body)
        let unsigned = Self.passportBase + path + (qs.isEmpty ? "" : "?" + qs)
        let signed = try signer.sign(url: unsigned)
        guard let url = URL(string: signed) else {
            throw Failure(code: "invalid-response", message: "Invalid signed Qishui URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.stub(for: payload), forHTTPHeaderField: "x-ss-stub")
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.setValue("https://www.qishui.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://www.qishui.com/", forHTTPHeaderField: "Referer")

        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        // **所有汽水请求都要短超时。**
        //
        // folia(14).log 14:16:26：页面启动后第一发 `login_status` 挂满 30 秒，
        // 登录 UI 直接卡死在「查询登录态」上 —— 后续的 login_qr_key /
        // login_qr_create（出二维码那两步）一次都没发出来。folia(13) 里
        // check_qrconnect 也一样挂 30 秒。汽水全部走这个函数，统一降到
        // 10 秒：慢网下第一发可能失败，但页面会立刻拿到 network 错误并
        // 走自己的重试/重渲染，而不是把用户晾在转圈上。
        request.timeoutInterval = 10
        session.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response as? HTTPURLResponse
            box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        if let error = box.error {
            throw Failure(code: "network", message: error.localizedDescription,
                          upstream: (error as NSError).code.description)
        }
        guard let http = box.response, let data = box.data else {
            throw Failure(code: "network", message: "Qishui returned no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            NSLog("[Qishui] http %d path=%@ signed=%@ body=%@",
                  http.statusCode, path, signed, snippet)
            throw Failure(code: http.statusCode == 429 ? "unavailable" : "network",
                          message: "Qishui HTTP \(http.statusCode)",
                          upstream: String(http.statusCode))
        }
        return try jsonObject(data)
    }

    /// `x-ss-stub`：请求体的 SHA-256，大写十六进制。
    private static func stub(for body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    /// 请求用的 UA。
    ///
    /// 必须是**汽水桌面客户端**的 UA，不能是普通浏览器 UA：
    /// 服务端按 UA 决定二维码里编什么跳转地址，普通浏览器 UA 会拿到网页登录地址，
    /// 抖音扫到之后打开就是一个 404 页。
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) SodaMusic/3.1.0 "
        + "Chrome/136.0.7103.59 Electron/36.4.0-rs.22.release.main.1 "
        + "TTElectron/36.4.0-rs.22.release.main.1 Safari/537.36"

    /// 网页端 passport 每次请求都要带的设备身份。
    ///
    /// 服务端按 `device_id` / `install_id` 做风控计数，缺了会直接拒绝要码；
    /// 这两个值本地生成一次就固定下来，和网页端「同一台设备反复扫码」等价。
    private static func deviceParams() -> [(String, String)] {
        let key = "folia.qishui.device"
        let defaults = UserDefaults.standard
        let deviceId: String
        let installId: String
        if let saved = defaults.dictionary(forKey: key),
           let device = saved["deviceId"] as? String,
           let install = saved["installId"] as? String {
            deviceId = device
            installId = install
        } else {
            let seed = "\(Int(Date().timeIntervalSince1970 * 1000))\(Int.random(in: 0..<1_000_000))"
            deviceId = seed
            installId = seed + String(Int.random(in: 0..<1000))
            defaults.set(["deviceId": deviceId, "installId": installId], forKey: key)
        }
        return [
            ("passport_jssdk_version", "2.4.13"),
            ("passport_jssdk_type", "normal"),
            ("is_from_ttaccountsdk", "1"),
            ("aid", Self.passportAid),
            ("language", "zh"),
            ("is_new_login", "1"),
            ("is_from_iesaccountsaas", "1"),
            ("device_id", deviceId),
            ("install_id", installId),
            ("did", deviceId),
            ("iid", installId),
            ("device_platform", "PC"),
            ("version_code", "3.3.0"),
            ("biz_trace_id", String(format: "%08x", UInt32.random(in: 0...UInt32.max))),
            ("account_sdk_source", "web"),
            ("p_js_v", "2.4.13"),
            ("p_js_t", "normal"),
            ("p_zt", "3.3.5"),
            ("p_ver", "1.0.29"),
            ("request_host", "file://"),
            ("p_bd", "1.0.0.41")
        ]
    }

    /// 拼 `key=value&...`（用于 query string）。
    ///
    /// `+` 必须转义：不转的话服务端会把它解成空格，token 和签名都会失效。
    private func form(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(code: "invalid-response", message: "Qishui response is not JSON")
        }
        // 只看**顶层**状态：`check_qrconnect` 把「继续轮询」「过期」这些业务状态
        // 全写在 `data` 里，顶层仍是 0。在这里把 `data` 里的码也当成失败，
        // 轮询会被直接打断。
        let code = (json["status_code"] as? NSNumber)?.intValue
            ?? (json["error_code"] as? NSNumber)?.intValue ?? 0
        if code != 0 {
            let message = (json["status_msg"] as? String)
                ?? (json["message"] as? String)
                ?? "Qishui rejected the request"
            throw Failure(code: "unavailable", message: message,
                          upstream: String(code), stage: "account")
        }
        return json
    }

    private func string(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// 页面侧的错误分类只认这几个字段，多传会被忽略。
    private struct Failure: Error {
        let code: String
        let message: String
        var upstream: String?
        var stage: String?

        var payload: [String: Any] {
            var body: [String: Any] = ["code": code, "message": message]
            if let upstream { body["upstreamCode"] = upstream }
            if let stage { body["stage"] = stage }
            return body
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        var data: Data?
        var response: HTTPURLResponse?
        var error: Error?
    }

    /// 把结果交回页面里对应的那个 Promise。
    private func reply(id: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        // 先把 payload 编成「JS 字符串字面量」，再把它嵌进调用里：
        // 这样 payload 内部的任何引号、反斜杠、换行都由 JSON 自己保证转义正确，
        // 不用手工拼三层转义（上一版就是手工拼的，base64 里的特殊字符会把脚本弄坏）。
        guard let literalData = try? JSONSerialization.data(withJSONObject: [text], options: []),
              var literal = String(data: literalData, encoding: .utf8) else { return }
        // `[text]` 编出来是 `["..."]`，去掉两侧方括号就得到单个字符串字面量。
        literal.removeFirst()
        literal.removeLast()
        let safeId = id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let js = """
        try {
          var bridge = window.__foliaBridge;
          var payload = \(literal);
          if (bridge && bridge.__foliaResolve) { bridge.__foliaResolve('\(safeId)', payload); }
        } catch (e) {}
        """
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

/// 汽水请求签名器。
///
/// `api.qishui.com/passport/*` 要 44 位 `a_bogus`，它由抖音风控 SDK 结合浏览器环境
/// 算出，原生侧复现不了。这里用离线 WKWebView 加载 `www/qishui-signer/signer.html`，
/// 让 SDK 在真实浏览器环境里算签名，只把「补好签名的 URL」取回来，请求本身不发。
///
/// 生命周期：第一次用到时才建 WebView；之后常驻复用，避免每次扫码都重新初始化 SDK。
private final class QishuiSigner {
    /// 签名结果。失败时抛错，让上层归到 `network` 而不是拿到半成品 URL。
    struct SignError: Error {
        let message: String
    }

    private var webView: WKWebView?
    private var loaded = false
    private var booted = false
    private var waiting: [String: (Result<String, SignError>) -> Void] = [:]
    private var queue: [(id: String, url: String)] = []
    private var seq = 0
    private let lock = NSLock()
    /// 空闲自毁定时器：签名器是一个独立的 WebContent 进程，不用时白占内存。
    private var idleTimer: Timer?

    /// 给 `url` 补上 `a_bogus`，返回补齐后的完整 URL。
    ///
    /// 调用方在后台线程（`QishuiBridge` 的消息处理线程），这里同步等结果：
    /// 一次扫码只有两三个请求，阻塞可控，也让上层逻辑保持直白。
    func sign(url: String) throws -> String {
        let box = SignBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                box.value = .failure(SignError(message: "signer released"))
                done.signal()
                return
            }
            self.prepare()
            let id = "s" + String(self.nextSeq())
            self.store(id: id) { result in
                switch result {
                case .success(let signed): box.value = .success(signed)
                case .failure(let error): box.value = .failure(error)
                }
                done.signal()
            }
            self.dispatch(id: id, url: url)
            self.armIdleRetire()
        }
        if done.wait(timeout: .now() + 20) == .timedOut {
            throw SignError(message: "signer timeout")
        }
        switch box.value {
        case .success(let signed)?: return signed
        case .failure(let error)?: throw error
        case nil: throw SignError(message: "signer produced no result")
        }
    }

    private func nextSeq() -> Int {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        return seq
    }

    private func store(id: String, _ handler: @escaping (Result<String, SignError>) -> Void) {
        lock.lock(); waiting[id] = handler; lock.unlock()
    }

    private func take(id: String) -> ((Result<String, SignError>) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return waiting.removeValue(forKey: id)
    }

    /// 120 秒没有新的签名请求就把签名 WebView 整个放掉。
    ///
    /// 签名器是第二个 WebContent 进程：SDK 页面挂在那儿哪怕完全不动，
    /// 也常驻几十 MB。汽水的请求是突发性的（登录那几下、搜歌那几下），
    /// 空闲时段占着毫无意义；下一次 `sign()` 会按需重建（几百毫秒的 SDK 装载）。
    /// 定时器在每次签名发出时重置，所以它不可能在请求还在飞行时触发
    /// （签名同步等待最多 20 秒，远小于 120 秒）。
    private func armIdleRetire() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.webView = nil
            self.loaded = false
            self.booted = false
            self.idleTimer = nil
            CrashLog.note("==== qishui signer retired after 120s idle ====")
        }
    }

    /// 建 WebView 并加载本地页面。只做一次。
    private func prepare() {
        if webView == nil {
            let config = WKWebViewConfiguration()
            // 签名页独立存储，不和主页面 cookie 混在一起。
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(WeakSignerHandler(owner: self),
                                             name: "foliaQishuiSigner")
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 configuration: config)
            // 签名器必须和真实请求用同一个 UA：SDK 会把 UA 等因素算进 `a_bogus`，
            // 两边不一致时服务端会判签名无效。
            view.customUserAgent = QishuiBridge.webUA
            view.isOpaque = false
            view.backgroundColor = .clear
            webView = view
        }
        guard !loaded, let webView,
              let index = Bundle.main.url(forResource: "signer",
                                          withExtension: "html",
                                          subdirectory: "www/qishui-signer") else {
            if !loaded { loaded = true }
            return
        }
        loaded = true
        // `allowingReadAccessTo` 指到目录，页面才能加载同目录下的 `sdk-glue.js`。
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    /// 调页面里的 `__foliaSign`。SDK 还没初始化完（`booted` 未到）时先排队，
    /// 否则首次扫码会在 SDK 装载的几百毫秒里直接拿到 `signer not loaded`。
    private func dispatch(id: String, url: String) {
        guard let webView else {
            take(id: id)?(.failure(SignError(message: "signer unavailable")))
            return
        }
        guard booted else {
            queue.append((id, url))
            return
        }
        // 两个参数都编成 JSON 字符串字面量再嵌进脚本，避免网址里的引号、`&` 破坏语法。
        guard let data = try? JSONSerialization.data(withJSONObject: [id, url]),
              var pair = String(data: data, encoding: .utf8) else {
            take(id: id)?(.failure(SignError(message: "signer argument error")))
            return
        }
        pair.removeFirst(); pair.removeLast()
        let js = """
        (function(){
          var handler = window.webkit.messageHandlers.foliaQishuiSigner;
          if (typeof window.__foliaSign !== 'function') {
            handler.postMessage({ type: 'not-ready' });
            return;
          }
          var args = [\(pair)];
          var id = args[0], url = args[1];
          window.__foliaSign('GET', url).then(function(r){
            handler.postMessage({ id: id, ok: true, url: r.url });
          }).catch(function(e){
            handler.postMessage({ id: id, ok: false,
                                  message: String((e && e.message) || e) });
          });
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] _, error in
            guard let self else { return }
            if error != nil {
                self.take(id: id)?(.failure(SignError(message: "signer script error")))
            }
        }
    }

    fileprivate func receive(_ body: [String: Any]) {
        // 签名页加载完成，SDK 已就绪：把排队中的请求一次性发出去。
        if (body["type"] as? String) == "booted" {
            booted = true
            let pending = queue
            queue.removeAll()
            for item in pending { dispatch(id: item.id, url: item.url) }
            return
        }
        guard let id = body["id"] as? String, let handler = take(id: id) else { return }
        if (body["ok"] as? Bool) == true, let url = body["url"] as? String {
            handler(.success(url))
        } else {
            let reason = (body["message"] as? String) ?? "sign failed"
            NSLog("[Qishui] signer failed: %@", reason)
            handler(.failure(SignError(message: reason)))
        }
    }
}


/// 让 `WKUserContentController` 不强持有签名器（它被 `QishuiBridge` 持有）。
private final class WeakSignerHandler: NSObject, WKScriptMessageHandler {
    weak var owner: QishuiSigner?
    init(owner: QishuiSigner) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        owner?.receive(body)
    }
}

private final class SignBox: @unchecked Sendable {
    var value: Result<String, QishuiSigner.SignError>?
}

// MARK: - 原生播放器桥JS

extension WebContainerView {
    /// 原生播放器桥脚本。
    ///
    /// 参考Folia汽水版本的ios-native-audio.js：拦截HTMLMediaElement的play()，
    /// 把音频地址交给原生AVPlayer播放，网页里的audio元素静音暂停。
    /// 这样进后台、切App都不会影响声音。
    static func nativePlayerBridgeScript() -> String {
        // 从 Bundle 读取独立 JS 文件（Folia/www/ios-fix/ios-native-audio.js），
        // 保持脚本原样，避免在 Swift 字符串里转义反斜杠，也便于对照参考版本。
        if let url = Bundle.main.url(forResource: "ios-native-audio",
                                    withExtension: "js",
                                    subdirectory: "www/ios-fix"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        // 读不到就返回空脚本，不影响页面正常加载
        return ""
    }
}

// MARK: - 降载内容规则

private extension WKContentRuleListStore {
    /// 同步拿到降载规则表；编译失败就当作没有（不让它挡住页面）。
    ///
    /// 只在主线程调用（`makeConfiguration` 里），用信号量等编译回调：
    /// 2 秒超时兜底，避免规则处理异常时拖住启动。
    func foliaDownscaleRuleList() -> WKContentRuleList? {
        if let cached = WebContainerView.foliaRuleListCache { return cached }
        // 这台机器上编译过但没成：别每次重建再白等 2 秒。
        if WebContainerView.foliaRuleListUnavailable { return nil }
        var compiled: WKContentRuleList?
        let semaphore = DispatchSemaphore(value: 0)
        compileContentRuleList(forIdentifier: "folia-downscale-images",
                               encodedContentRuleList: WebContainerView.downscaleRuleJSON) { list, error in
            if let error {
                NSLog("[Folia] content rule list compile failed: %@", error.localizedDescription)
            }
            compiled = list
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            WebContainerView.foliaRuleListUnavailable = true
            return nil
        }
        guard let compiled else {
            WebContainerView.foliaRuleListUnavailable = true
            return nil
        }
        WebContainerView.foliaRuleListCache = compiled
        return compiled
    }
}

