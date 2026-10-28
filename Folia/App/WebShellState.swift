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

    /// 重新声明 category 并激活会话：切后台、进程重建、来电结束后都需要。
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

    /// 网页播放器上报的播放状态 → 锁屏/控制中心。
    ///
    /// 不写 Now Playing 信息时，iOS 会把本 App 当成「没有在播放」，
    /// 退到后台几秒后就掐掉音频。页面自身已经通过 MediaSession 设了标题/封面，
    /// 这里只需要把 playbackRate 设为 1 表示「正在播放」。
    func updatePlaybackState(_ playing: Bool) {
        isPlaying = playing
        if playing {
            activate()
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            if info[MPNowPlayingInfoPropertyPlaybackRate] == nil {
                info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            }
            info[MPNowPlayingInfoPropertyIsLiveStream] = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        } else if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func observeLifecycle() {
        // 进入后台的瞬间再激活一次会话：这是系统判定「能否继续放音频」的最后时机。
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.activate()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activate()
        }
    }

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
            case .ended:
                // 来电 / 其他 App 抢占结束后重新声明 category 再激活，
                // 只 setActive 在部分场景下会失败，音频就再也回不来。
                self?.activate()
            default:
                // .began 时必须把会话让出去，否则系统会直接掐断音频。
                break
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
}
