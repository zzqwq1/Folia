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
    /// 重新声明 category 并激活会话：冷启动、进程重建、来电结束后都需要。
    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            sessionIsActive = true
        } catch {
            sessionIsActive = false
            // 失败不影响网页功能，只是切后台可能被系统暂停。
            NSLog("[Folia] audio session setup failed: \(error.localizedDescription)")
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
        } else if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            endBackgroundTask()
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
            // 回来时先看「音频通路是不是被别的 App 占着」。
            //
            // 这是「看完抖音回来，界面显示在播放、却一点声音都没有」的正面解法。
            // 用户去看了个带声的视频，本 App 的会话被系统降级或收走；页面的播放器
            // 状态仍是 playing，AudioContext 也还是 running，所以壳侧那套
            // 「先探测再动手」的判据完全看不出问题。
            //
            // `.mixWithOthers` 下别家 App 出声时，`isOtherAudioPlaying` 会翻真；
            // 只在这一刻把 `sessionIsActive` 置假，让下面那次幂等的 `setActive(true)`
            // 真正跑一遍。它不重建 category，正在响的媒体不会被按停。
            if self.isPlaying, AVAudioSession.sharedInstance().isOtherAudioPlaying {
                self.sessionIsActive = false
            }
            self.healIfSilenced()
            self.recoverIfInactive()
        }
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
        guard isPlaying else { return }
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
        guard isPlaying, !sessionIsActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionIsActive = true
            NSLog("[Folia] session re-activated after becoming active")
        } catch {
            NSLog("[Folia] session re-activate failed: \(error.localizedDescription)")
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
