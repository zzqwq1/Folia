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

    static func sweepOnColdLaunch() {
        guard !swept else { return }
        swept = true
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
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // 失败不影响网页功能，只是切后台可能被系统暂停。
            NSLog("[Folia] audio session setup failed: \(error.localizedDescription)")
        }
    }

    /// 从后台回到前台时再激活一次：系统可能在后台把会话降级。
    func reactivate() {
        try? AVAudioSession.sharedInstance().setActive(true)
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
            // 先无条件把会话立起来：即便本 App 认为「没在播」，
            // 网页侧也可能刚从后台恢复播放，会话不通就一点声都没有。
            self.reactivate()
            if self.isPlaying {
                self.beginBackgroundTask()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reactivate()
        }
    }

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
}
