import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import WebKit

/// WKWebView 内嵌官方 Folia 网页版的运行状态。
final class WebShellState: ObservableObject {
    @Published var reloadToken = 0

    func reload() {
        reloadToken += 1
    }

    /// 线上页打不开时（离线、被墙、DNS 故障）要让界面说清楚，
    /// 否则用户只看到一片深色背景，会误判成「又闪退了」。
    @Published private(set) var offlineReason: String?
    /// 现场细节（URL、UA、遮罩状态等），只有诊断需要时才有，显示在提示框下方。
    private(set) var failureDetail: String?

    /// 当前是否跑在包内离线页上。
    ///
    /// 线上站连续重试都失败后，壳会回退到 App 包里的那份 `www/`，
    /// 让用户至少能进到一个可用的界面，而不是对着一个「重试」按钮干等。
    /// 这时候提示层的语义不同：不是「加载失败」，而是「正在用离线副本，点一下回线上」。
    @Published private(set) var isOfflineCopy = false

    /// 提示层是否要显示。
    ///
    /// 离线副本是「有兜底、能继续用」的状态：页面已经画出来了，只是功能不全。
    /// 这时候不该再盖一层全屏遮罩挡着播放器，只留顶部一条轻提示，点一下就能回线上。
    /// 真正的加载失败（没有页面可用）才铺满整屏。
    var showsBlockingNotice: Bool {
        offlineReason != nil && !isOfflineCopy
    }

    func enterOfflineCopy() {
        isOfflineCopy = true
        failureDetail = nil
        offlineReason = "当前用的是离线版本，部分功能可能不可用"
    }

    /// 从离线副本切回线上：把提示换成「正在重新连接」，并清掉离线标记，
    /// 由容器重新走一次线上加载。
    func leaveOfflineCopy() {
        isOfflineCopy = false
        offlineReason = nil
        failureDetail = nil
    }

    func noteLoadFailure(_ code: Int, detail: String? = nil) {
        failureDetail = detail
        switch code {
        case -1009:
            offlineReason = "当前网络不可用"
        case -1001:
            offlineReason = "网络太慢，页面没能加载完"
        case -1003, -1004, -1005:
            offlineReason = "连不上 Folia 服务器"
        case -3:
            // 文档到了、但页面里的脚本一直没跑完：通常是它依赖的 CDN 模块拉不下来。
            offlineReason = "页面脚本没能启动"
        case -1:
            offlineReason = "页面没能加载出来"
        default:
            offlineReason = "页面加载失败（\(code)）"
        }
    }

    /// 文档到了但页面一直没画出来（模块卡在 CDN、Service Worker 吐空壳等）。
    ///
    /// 这种失败不会触发 `didFailProvisionalNavigation`：导航本身是成功的，
    /// 所以不能复用网络错误码，否则用户会看到「当前网络不可用」这种误导性文案。
    func noteStalled(detail: String? = nil) {
        failureDetail = detail
        offlineReason = "页面没能启动起来"
    }

    func clearLoadFailure() {
        offlineReason = nil
        failureDetail = nil
    }
}

/// 冷启动时的缓存清理。
///
/// 「大退后进歌单闪退」的现场是 WebContent 进程被系统回收：进程连同它的堆一起没了，
/// 重启后 WKWebView 又要在同一份磁盘缓存上重建整个页面，很容易二次被压死。
/// 所以冷启动先把两层临时缓存清掉：
///
/// - `WKWebsiteDataTypeMemoryCache`：内存缓存（进程死了本来也会消失，顺手清）；
/// - `WKWebsiteDataTypeDiskCache`：HTTP 磁盘缓存，图片与脚本体量最大的一块。
///
/// 明确不碰 `LocalStorage` / `Cookies` / `IndexedDB` / `ServiceWorkers`：
/// 登录态、歌单队列、播放设置全在里面，清掉等于把用户踢下线。
enum CacheSweeper {
    /// 一个进程只清一次：热启动时清会把正在用的资源也打掉。
    private static var swept = false

    /// 上次运行是不是崩着退出的。
    ///
    /// 崩过之后下一次启动改用一次性的干净存储目录（见 `WebContainerView.setUp()`），
    /// 成功加载出一轮后自动清掉。正常退出时不动它，否则每次启动都要重新下载全站。
    private static let dirtyKey = "folia.webstore.dirty"
    private static let dirtyAtKey = "folia.webstore.dirtyAt"

    /// 脏标记的有效期。
    ///
    /// 这个标记的意义是「上一次运行崩了，这一次用临时存储绕开脏数据」。
    /// 但它此前只有一条清除路径：重建后页面加载完成、且 8 秒内没再挂。
    /// 只要用户在歌单页反复触发进程死亡，这条路径就永远走不到，标记就一直挂着，
    /// 于是**每次启动都是临时存储**：登录态没了、歌单缓存没了 —— 用户看到的就是
    /// 「大退后软件复原了，要重新登录」，而且他自己不可能知道怎么恢复。
    /// 加一个有效期：超过一天就认为旧数据已经不是问题，回到默认存储。
    private static let dirtyTTL: TimeInterval = 24 * 60 * 60

    /// 标记「这次运行不干净」。
    ///
    /// 在内容进程死掉时立刻写下，并且**不等**进程正常退出 ——
    /// 用户描述的现象是「大退重进还是闪退」，说明上一次崩溃没有任何收尾机会，
    /// 只能在运行期实时落盘。
    static func markDirty(_ reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(reason, forKey: dirtyKey)
        defaults.set(Date().timeIntervalSince1970, forKey: dirtyAtKey)
        defaults.synchronize()
    }

    static var isStoreDirty: Bool {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: dirtyKey) != nil else { return false }
        // 过期的标记自动作废：宁可冒一次「旧数据还在」的风险，
        // 也不能让用户永远回不到自己的登录态。
        let stamped = defaults.double(forKey: dirtyAtKey)
        if stamped > 0, Date().timeIntervalSince1970 - stamped > dirtyTTL {
            clearDirty()
            CrashLog.note("==== dirty store flag expired, back to default store ====")
            return false
        }
        return true
    }

    static func clearDirty() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: dirtyKey)
        defaults.removeObject(forKey: dirtyAtKey)
        defaults.synchronize()
    }

    static func sweepOnColdLaunch() {
        guard !swept else { return }
        swept = true

        // 清理范围刻意只到「HTTP 缓存」，**不动 Service Worker 与离线缓存**。
        //
        // 早先这里是「崩过就清 SW」，想的是「旧 SW 把进程拖死了」。实际相反：
        // 线上站用 SW 做缓存优先，第二次启动几乎所有脚本都从本地拿，WebContent 进程
        // 起得又快又稳；把 SW 清掉之后，下一个进程必须重新拉整站脚本与可视化引擎，
        // 在内存最紧张的那一刻反而更容易被压死 —— 用户看到的就是
        // 「大退重进还是闪退」，甚至比第一次更严重。
        //
        // 所以这里统一只清两层临时缓存；万一真的被脏数据卡住，
        // 由 `WebContainerView` 在「一分钟内连挂三次」时改用 `nonPersistent` 存储兜底。
        let types: Set<String> = [
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeDiskCache,
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            CrashLog.note("==== cold launch: cleared memory + disk cache ====")
        }
    }
}

/// 后台播放所需的音频会话。
///
/// 网页版自身用 WebAudio / <audio> 播放，WKWebView 的媒体进程同样遵守 AVAudioSession 约束：
/// 只有把会话设成 .playback 并且允许后台音频，锁屏/切后台才不会被系统打断。
final class AudioSessionController {
    static let shared = AudioSessionController()

    private var observersInstalled = false
    /// 页面当前是否在播放，用于锁屏信息与后台保活。
    private var isPlaying = false

    /// 每次启动、回到前台、进入后台都要调。
    ///
    /// 早先这里有个 `guard !configured` 的一次性开关：只要第一遍设 category 失败
    /// （比如启动瞬间还被别的 App 占着音频），后面就再也不会重设，
    /// 于是「退出 App 就没声音」。现在每次都幂等地重设一遍，代价只有几毫秒。
    func configure() {
        activate()
        if !observersInstalled {
            observersInstalled = true
            observeInterruptions()
            observeLifecycle()
            configureRemoteCommands()
        }
    }

    /// 重新声明 category 并激活会话：冷启动、进程重建、来电结束后都需要。
    ///
    /// 关键约束：**播放中不要调这里**。`setCategory` 会让系统重建音频通路，
    /// WebKit 的媒体元素会被一并按停 —— 表现就是「从后台切回来音乐突然暂停」。
    /// 播放期间只需要 `setActive(true)`（见 `reactivate()`）。
    ///
    /// 「开一次机只设一次 category」是刻意的：`setCategory` 是**进程级**设置，
    /// 只要进程活着就一直有效，系统收回的只是 active 资格。
    /// 真实日志里「进抖音再回来没声音」的现场正是这条被当成恢复手段反复调用 ——
    /// 每调一次就把正在响的媒体按停一次，页面随即上报暂停，恢复链自己被自己打断。
    ///
    /// 唯一需要真正重设的场合是**被别家 App 抢占之后**：系统会把我们从
    /// 「正在播放的应用」里摘出去，`setActive(true)` 改不回来，只有重新声明 category
    /// 才能要回后台播放资格。那两条由 `rebuildPathQuietly()` / `healIfPreempted()` 负责，
    /// 它们只在对路的那一拍触发一次，不会进入保活循环。
    func activate() {
        configureCategoryIfNeeded()
        ensureActive()
    }

    /// 只在第一次真正声明 category。
    private func configureCategoryIfNeeded() {
        guard !categoryConfigured else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback,
                                                            mode: .default,
                                                            options: Self.categoryOptions)
            categoryConfigured = true
            NSLog("[Folia] audio category configured (playback + mixWithOthers)")
        } catch {
            // 失败不影响网页功能，只是切后台可能被系统暂停。
            NSLog("[Folia] audio session setup failed: \(error.localizedDescription)")
        }
    }

    /// 本进程是否已经把 category 设成「后台播放 + 混音」。
    private var categoryConfigured = false

    /// 只在会话没被激活时补一次 `setActive` —— 幂等、**不重建 category**。
    ///
    /// 回前台且用户仍在播放时走这里。与 `activate()` 的区别就是不碰 category：
    /// 通路被别家 App 收走时 `setActive(true)` 能不能救回来不一定，但它绝不会
    /// 把正在响的媒体按停，所以可以在每一拍前台恢复里无条件调用。
    func ensureActive() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionIsActive = true
        } catch {
            sessionIsActive = false
            NSLog("[Folia] audio session re-activate failed: \(error.localizedDescription)")
        }
    }

    /// 重设 category 时统一走这里，保证各处策略一致。
    ///
    /// `.mixWithOthers` 是「不打断别人、也不被别人打断」的关键：
    /// 用空的 options 时本 App 会**独占**音频通路 —— 用户原本在 QQ 音乐听歌，
    /// 一切进 Folia，对方的会话就被系统掐掉（表现是进度在走却没声）；
    /// 而本 App 一旦占住通路就不放，退出去之后对方也接不回来。
    /// 混音模式下两边可以共存，退出任意一方都不会让另一方卡死。
    private static let categoryOptions: AVAudioSession.CategoryOptions = [.mixWithOthers]

    /// 从后台回到前台时再激活一次：系统可能在后台把会话降级。
    func reactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionIsActive = true
        } catch {
            sessionIsActive = false
        }
    }

    /// 正在播放时持有的后台任务。
    ///
    /// `beginBackgroundTask` 在 iOS 13+ 只保证约 30 秒，真正让音频在后台续着的是
    /// `UIBackgroundModes: audio` + 活跃的音频会话；这个任务的作用是把
    /// WebProcess 从「被挂起」边缘拉回来，让 JS 定时器（进度、自动切歌）继续跑。
    /// 到期后若仍在播放，就地续一个新任务。
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "folia.playback") { [weak self] in
            // 过期回调可能在后台线程进来，统一挪回主线程处理。
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackgroundTask()
                // 到期时还在播，就再续一次，保证进度条与歌词不冻结。
                if self.isPlaying { self.beginBackgroundTask() }
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// 网页播放器上报的播放状态 → 锁屏/控制中心。
    ///
    /// 不写 Now Playing 信息时，iOS 会把本 App 当成「没有在播放」，
    /// 退到后台几秒后就掐掉音频。页面自身已经通过 MediaSession 设了标题/封面，
    /// 这里只需要把 playbackRate 设为 1 表示「正在播放」。
    ///
    /// 另一件必须做的事：播放期间申请一个后台任务。
    /// 网页版的时间轴推进、自动切歌全靠 JS 定时器跑在主线程上，
    /// 没有后台任务时 WebProcess 会在退到后台几十秒后被系统挂起，
    /// 表现就是「后台还在响，切回来进度和歌词都停在原地，然后被页面自己暂停」。
    ///
    /// 这里刻意**不动 `isPlaying` 之外的任何音频状态**：播放中只续后台任务与播放速率，
    /// 不调 `setActive`。后者的语义是「占用音频设备」，音效播放、Siri、来电刚结束等
    /// 场景下反复调用会让系统重新评估本 App 的播放资格，页面那边就表现为莫名暂停。
    func updatePlaybackState(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            beginBackgroundTask()
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        } else {
            // **结束后台任务不能挂在 Now Playing 上。**
            //
            // 早先是 `else if var info = ...nowPlayingInfo { endBackgroundTask() ... }`：
            // 页面从未写过 Now Playing 时这个值就是 nil，走不到 `endBackgroundTask` ——
            // 任务一直占着，而 `beginBackgroundTask` 有 `guard backgroundTask == .invalid`，
            // 之后每次播放都申请不到新任务，后台 JS 定时器（进度、自动切歌）提前冻结。
            endBackgroundTask()
            if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private func observeLifecycle() {
        // 进入后台的瞬间再激活一次会话：这是系统判定「能否继续放音频」的最后时机。
        // 这里只 setActive，正响着的时候重设 category 会当场把声音按停。
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // **不再在这里 `reactivate()`**。
            //
            // 早先这里写的是「进后台无条件 setActive」，理由是「这是系统判定能否继续出声的
            // 最后时机」。实际相反：`setActive(true)` 会让系统重新评估音频资格，
            // WebKit 的媒体元素被当场按停一次，页面侧收到 pause 就再也不会自己起来；
            // 会话本来就活着的时候调它，等于亲手把歌掐断 —— 用户看到的就是
            // 「切到桌面 / 锁屏，歌立刻停」。
            //
            // 真正需要重建通路的场景只有「被系统收走过」：来电结束、控制中心静音泄漏，
            // 那两条分别由 `interruptionNotification` 与 `healIfSilenced()` 处理。
            if self.isPlaying {
                self.beginBackgroundTask()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 回到前台时**不在这里**动会话。
            //
            // 这里的两个分支（没在播就 `reactivate()`、在播就把 `sessionIsActive` 置假）
            // 都只在「会话确实已经被系统收走」时才有意义，而这一条判断只有
            // `didBecomeActive` 那一拍才可靠 —— 它紧跟在本通知之后。
            // 放在这里的问题是：`willEnterForeground` 会先于 `didBecomeActive` 触发，
            // 用户只是切出去看了一眼别的 App、会话好端端的，也会被置假并走一次
            // `setActive(true)`，表现为「切回来歌停半拍」。
            //
            // 统一收口到 `didBecomeActive`：那里先看会话有没有被收走，再看是否需要
            // 重建通路，重复调用也是幂等的。
            _ = self
        }

        // 状态栏划出控制中心：系统把音频通路静音、状态却仍是「播放中」，
        // 本 App 收不到中断事件，会话里只剩 `.silenceHint`。控制中心收起时收尾。
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.markSilencedBySystemPanel()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // **简化回前台逻辑：只做一次幂等的setActive，不做其他操作。**
            //
            // 之前这里做了太多操作，每次回前台都重建音频通路，
            // 很容易把正在播放的歌按停，导致用户听到的就是「回来就没声音了」。
            // 真正的通路重建交给容器的探针：它会先检查，确认确实没声了才会恢复。
            if self.isPlaying || self.wantsAudible || self.backgroundedWhilePlayingOK {
                self.ensureActive()
            }
            self.backgroundedWhilePlayingOK = false
            self.preemptedByOtherApp = false
        }
    }

    /// 回前台后问页面：「你的播放时钟还在走吗」。
    ///
    /// 只看 `paused` 不够 —— 被别家 App 抢占后媒体元素常常仍报 `playing`，
    /// 时间轴却已经冻住；而只看 `AudioContext.state` 同样不够，它会停在 running。
    /// 隔 400ms 采两次 `currentTime`，只有确实没推进才算「通路真的断了」。
    private func audioPathVerify(_ completion: @escaping (Bool) -> Void) {
        guard let container else {
            completion(false)
            return
        }
        container.verifyPlaybackClockAdvancing(completion)
    }

    /// 上一次进后台时，「该响」这个前提是否成立。
    ///
    /// 由容器侧在 `didEnterBackground` 时同步过来：它掌握 `wantsAudible` / `userPaused`
    /// 这两个页面意图，比 `isPlaying`（来自 Now Playing 上报，会被后台的暂停事件改写）更可信。
    /// 回前台时用完即清，只影响「回来的第一拍」。
    var backgroundedWhilePlayingOK = false {
        didSet {
            guard backgroundedWhilePlayingOK else { return }
            // 进后台那一刻若还在放，记下 `isPlaying`，
            // 免得后台的 pause 上报把它冲掉之后判据失真。
            backgroundedAndPlaying = backgroundedAndPlaying || isPlaying
        }
    }

    private var backgroundedAndPlaying = false

    /// 页面侧是否认为自己「该响」。由容器同步，只用于回前台这一拍的判断。
    var wantsAudible = false

    /// 当前承载页面的容器。
    ///
    /// 回前台判断「通路到底断没断」必须去问页面自己的播放时钟，而唯一能跨进程执行
    /// JS 的地方在容器里。弱引用：容器持有 `state`，反向持有会成环。
    weak var container: WebContainerView?

    /// **清掉「离开期间一直在放」的记账。**
    ///
    /// `backgroundedAndPlaying` 只置真、全文件没有置假点：用户暂停之后它仍为真，
    /// `rebuildPathQuietly` / `healIfSilenced` / `recoverIfInactive` 的守卫因此长期成立，
    /// 每次回前台都会白重建一次通路（`setCategory` 会把正在响的媒体按停一次）。
    func notePlaybackStopped() {
        backgroundedAndPlaying = false
        backgroundedWhilePlayingOK = false
    }

    private func rebuildPathQuietly() {
        // **不再用 `isPlaying` 当门。**
        //
        // 它来自页面的播放状态上报，而手机背面朝上 / 锁屏时 WebKit 会真的按停媒体元素，
        // 页面随即上报 `paused`，这个标志就永久为假 —— 于是「进抖音再回来没声音」
        // 这一条重建路径一次都不会跑。判据改用可累加的 `backgroundedAndPlaying`
        // （进后台时该响就置位，只在回前台这一拍读过之后清掉）与 `wantsAudible`。
        guard isPlaying || backgroundedAndPlaying || wantsAudible else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: Self.categoryOptions)
            try session.setActive(true)
            sessionIsActive = true
            NSLog("[Folia] audio path rebuilt after background (unconditional)")
        } catch {
            NSLog("[Folia] audio path rebuild after background failed: \(error.localizedDescription)")
            sessionIsActive = false
            // 这次没成：允许下一次回前台再声明一次 category。
            categoryConfigured = false
        }
        NotificationCenter.default.post(name: .foliaAudioPathRebuilt, object: nil)
    }

    /// 上一轮切后台期间，音频被别的 App 占用过。
    ///
    /// 进后台时先挂上，回前台时按实际结果收窄：`isOtherAudioPlaying` 已经翻回
    /// false 并不代表通路没丢（对方只是被系统淡出了），所以这里不无条件重建，
    /// 而是交给 `preemptedByOtherApp` 与页面侧的「有没有在出声」共同判定。
    private var preemptedByOtherApp = false

    /// 被别家 App 抢占之后回到前台：重建一次通路。
    ///
    /// 与 `healIfSilenced` 的分工：那一条管「本 App 自己的系统面板」，
    /// 这一条管「整个 App 被切到后台、通路被对方拿走」。
    /// 只有用户明确「该响」（`isPlaying`）时才重建 —— 用户自己按了暂停就不该动，
    /// 否则表现就是「我明明停了，换个 App 回来又自己响」。
    private func healIfPreempted() {
        guard preemptedByOtherApp else { return }
        preemptedByOtherApp = false
        healIfPreemptedNow()
    }

    /// 真正执行「被抢占后的修复」，返回是否动过音频状态。
    ///
    /// 拆出来的原因：`didBecomeActive` 那一拍 `isOtherAudioPlaying` 经常已经翻回 false，
    /// `preemptedByOtherApp` 根本没置位，可通路确实被摘走了。容器侧会另发一次
    /// `recoverIfPreempted()` 兜底，两条路都必须能真正执行，所以这里不能只看标志位。
    @discardableResult
    func recoverIfPreempted() -> Bool {
        guard isPlaying || backgroundedAndPlaying || wantsAudible else { return false }
        return healIfPreemptedNow()
    }

    /// 被别家 App 抢占、且页面确认已经没在出声之后：真正把通路要回来。
    ///
    /// 与 `healIfPreemptedNow()` 的分工：那一条只补幂等的 `setActive`，
    /// 因为无法确认媒体是否还在响，`setCategory` 有可能把好端端的歌掐断。
    /// 这一条只在容器**已经用页面时钟确认没在出声**之后调用 ——
    /// 这时不重建就一定一直静音，重建没有额外损失。
    ///
    /// 日志 05-12-20 的现场：容器打了
    /// `audio path preempted by another app, rebuilding path (pending)`，
    /// 可两边的 `setActive` 都成功、`preemptedByOtherApp` 又各自用完即清，
    /// 真正 `setCategory` 的重建一次都没跑过，用户听到的一直是静音。
    @discardableResult
    func rebuildAfterPreemption() -> Bool {
        guard isPlaying || backgroundedAndPlaying || wantsAudible else { return false }
        rebuildPathQuietly()
        return true
    }

    @discardableResult
    private func healIfPreemptedNow() -> Bool {
        // 判据同上：只看 `isPlaying` 会漏掉「被别的 App 按停过、页面已上报 paused」的情形。
        guard isPlaying || backgroundedAndPlaying || wantsAudible else { return false }
        // **这里不再 `setCategory`，只补一次幂等的 `setActive`。**
        //
        // 用户报的「从抖音回来没声音」，现场其实是：页面 `<audio>` 仍报 playing、
        // 播放时钟也在走，只是系统那一层通路被对方拿走过。`setCategory` 会重建
        // 整条通路，WebKit 的媒体元素会被按停一次 —— 对一条只是在等通行权的
        // 通路做这件事，就是亲手把歌掐断，而且掐完还未必能补回来。
        // 真正需要重建通路的判断留给容器：它会先 `ensureActive` + 唤醒上下文，
        // 隔 0.6 秒确认页面确实没声，才走 `recoverAudioPathPass`。
        // 两处都做就等于双重重建，日志里紧跟 `rebuild (pending)` 的
        // `paused by user (confirmed)` 就是这么来的。
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            sessionIsActive = true
            NSLog("[Folia] session re-activated after other-app preemption")
        } catch {
            NSLog("[Folia] session re-activate after preemption failed: \(error.localizedDescription)")
            sessionIsActive = false
            // 真的连 setActive 都失败，说明 category 也被系统摘掉了：
            // 这一拍才允许重新声明一次。
            categoryConfigured = false
            rebuildPathQuietly()
            return true
        }
        // 页面侧跟上：AudioContext 多半停在 interrupted，媒体元素也被按停过。
        // 恢复动作仍然只有 WebContainerView 那一份串行通道（见 `probeThenRecover`），
        // 这里只发信号，不自己补 `play`，避免两路抢同一个 deck。
        NotificationCenter.default.post(name: .foliaAudioPathRebuilt, object: nil)
        return true
    }

    /// 状态栏/控制中心盖住本 App 时记一笔，仅在「该响」时。
    ///
    /// `didBecomeActive` 同时覆盖来电、切 App 回来等情况，那些都不需要重建通路；
    /// 只有「刚才被系统面板盖过」才值得动用 `setCategory`。
    private func markSilencedBySystemPanel() {
        silencedBySystemPanel = isPlaying
        // 系统面板盖住本 App 时，会话极可能已被系统置为非 active（部分机型连
        // `secondaryAudioShouldBeSilencedHint` 都不会置位）。先记下来，
        // 让 `healIfSilenced` 在收起时一定会重建一次通路。
        if isPlaying {
            sessionIsActive = false
            NSLog("[Folia] system panel opened while playing, session assumed inactive")
        }
    }

    /// 收尾时若通路被静音，就重建一次 category 再把会话激活。
    ///
    /// 与 `activate()` 的区别只在触发条件：播放中不动 category 是为了避免误暂停，
    /// 而这里**已经没声了**，重建不会有额外损失；不重建则一直是「显示在播但没声音」。
    ///
    /// 原来的判据是 `secondaryAudioShouldBeSilencedHint`，但拉下状态栏 / 控制中心
    /// 之后再收起时，这个 hint 在老机型与部分系统版本上根本不会置位（它描述的是
    /// 「别的系统音该不该被静音」，不是「我们的音乐会话是否还活着」）。于是
    /// 「状态栏滑下再回来没声音」一直没被这条兜住。
    ///
    /// 现在的判据换成「会话是否还 active」：拉下控制中心时系统会临时把我们的
    /// 音频会话置为非 active，收起后不会有任何回调把它救回来。只要该响却已经
    /// 不是 active，就重建。重建是幂等的，通路本来好着时最多丢一小节声音。
    private func healIfSilenced() {
        guard silencedBySystemPanel else { return }
        silencedBySystemPanel = false
        // 判据同上：`isPlaying` 会因页面被按停而变假，不能当唯一门。
        guard isPlaying || backgroundedAndPlaying || wantsAudible else { return }
        let session = AVAudioSession.sharedInstance()
        guard session.secondaryAudioShouldBeSilencedHint || !sessionIsActive else { return }
        do {
            try session.setCategory(.playback, mode: .default, options: Self.categoryOptions)
            try session.setActive(true)
            sessionIsActive = true
            NSLog("[Folia] audio path rebuilt after system panel")
        } catch {
            NSLog("[Folia] audio path rebuild failed: \(error.localizedDescription)")
            sessionIsActive = false
            categoryConfigured = false
        }
        // 页面那边此时仍是「在播」状态：重建通路后 AudioContext 可能停在 interrupted，
        // 需要页面自己再唤醒一次。
        //
        // 注意：这里**不能**再发 `play` 遥控命令。控制中心收起时
        // `didBecomeActive` 也会触发 WebContainerView 的恢复流程，
        // 两路同时补 `play` 会让两套 deck 互相抢，表现为卡顿和爆音。
        // 页面侧的恢复统一由 WebContainerView 串行执行。
        NotificationCenter.default.post(name: .foliaAudioPathRebuilt, object: nil)
    }

    /// 会话当前是否「我们认为」仍处于 active。
    ///
    /// `AVAudioSession` 没有公开的「isActive」查询：只能自己在设过之后记一笔。
    /// 这个标志只用来放宽 `healIfSilenced` / `recoverIfInactive` 的触发条件，
    /// 错了也只会多一次幂等的 `setActive`。
    private var sessionIsActive = false

    /// 每次收到 `didBecomeActive` 后由壳确认：会话到底还活着没有。
    ///
    /// `healIfSilenced` 只在「刚才被系统面板盖过」时动 category，其余场景
    /// （切到别的 App 再回来、来电结束）会话同样可能被系统置为非 active，
    /// 而那一路没有任何回调。这里只做一次幂等的 `setActive(true)`：
    /// 会话本来就活着时它是空操作，不会像 `setCategory` 那样把媒体按停。
    private func recoverIfInactive() {
        // 判据同上：`isPlaying` 不可靠时也要能补这一次幂等的 `setActive`。
        guard isPlaying || wantsAudible, !sessionIsActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionIsActive = true
            NSLog("[Folia] session re-activated after becoming active")
        } catch {
            NSLog("[Folia] session re-activate failed: \(error.localizedDescription)")
            // 重新激活失败通常意味着 category 本身已经被系统摘掉了：
            // 清掉一次性标志，让下一次回前台能重新声明一次。
            sessionIsActive = false
            categoryConfigured = false
        }
    }

    /// 上一次 `willResignActive` 是否由状态栏/控制中心引起。
    private var silencedBySystemPanel = false

    /// 系统级中断（来电、闹钟、别的 App 抢占）是否还没结束。
    ///
    /// `.began` 与 `.ended` 必须成对看：`.began` 一到，音频通路就被系统收走了；
    /// 只有确实被收走过，`.ended` 时重设 category 才有意义。
    private var interrupted = false

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }

            switch type {
            case .began:
                // .began 时必须把会话让出去，否则系统会直接掐断音频。
                self?.interrupted = true
                self?.sessionIsActive = false
                NSLog("[Folia] audio interrupted")
            default:
                guard let self, self.interrupted else { return }
                // 通话 / 其他 App 抢占结束后重新声明 category 再激活。
                // 只 setActive 在部分机型上会失败，而页面那边此时已经判为暂停，
                // 不把通路要回来就是「前后台都没声音」。
                //
                // 只在「确实被中断过」时才重设：`setCategory` 会重建音频通路，
                // 播放中无谓地调它反而会把页面媒体按停 ——
                // 这正是早先「切后台/切回来音乐莫名暂停」的来源之一。
                self.interrupted = false
                self.activate()
            }
        }
    }

    /// 锁屏控制中心/耳机线控按钮。
    ///
    /// 早先这里禁掉了 play / pause / togglePlayPause，理由是「一接管系统就反复送 pauseCommand，
    /// 点了播放立刻自动暂停」。真正的原因是早先那版内置本地包里的音频一直没进播放态，
    /// 系统自然判定本 App 没在播。现在壳直接套线上页，页面自己通过 MediaSession 管播放，
    /// 本 App 只负责把命令转发进页面，命令本身全部启用。
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        let handler: (String) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { script in
            return { _ in
                NotificationCenter.default.post(name: .foliaRemoteCommand, object: script)
                return .success
            }
        }

        center.playCommand.addTarget(handler: handler("play"))
        center.pauseCommand.addTarget(handler: handler("pause"))
        center.togglePlayPauseCommand.addTarget(handler: handler("toggle"))
        center.nextTrackCommand.addTarget(handler: handler("next"))
        center.previousTrackCommand.addTarget(handler: handler("prev"))
    }
}

extension Notification.Name {
    static let foliaRemoteCommand = Notification.Name("app.folia.remote-command")
    /// 网络从不可用恢复到可用。壳据此自动重载停在失败提示上的页面。
    static let foliaNetworkRestored = Notification.Name("app.folia.network-restored")
    /// 控制中心/状态栏收起后音频会话已重建，页面侧需要走一次统一的通路恢复。
    static let foliaAudioPathRebuilt = Notification.Name("app.folia.audio-path-rebuilt")
}
