import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// WKWebView 内嵌官方 Folia 网页版的运行状态。
final class WebShellState: ObservableObject {
    @Published var reloadToken = 0

    func reload() {
        reloadToken += 1
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
    /// **这里刻意只保留切歌，禁掉 play / pause / togglePlayPause。**
    ///
    /// WKWebView 里的 <audio> 走 WebAudio 的 createMediaElementSource 后，声音由页面自己的
    /// AudioContext 输出，系统侧没有一条「正在播放」的媒体轨道。这种状态下 App 一旦把
    /// MPRemoteCommandCenter 的播放命令全部接过来，iOS 就会把本 App 当成「当前正在播放的
    /// 媒体应用」，并反复送来 pauseCommand；iOS 每次送来 playback 类事件时还会
    /// deactivate 一次 AVAudioSession，WebAudio 随之被打断 —— 用户看到的就是
    /// 「点了播放，进度条刚动一下又自动暂停」。
    ///
    /// 不接管这几个命令时，锁屏只显示标题/封面而不提供播放按钮；换来的是一按播放能一直放。
    /// 切歌命令不受影响：它们不涉及会话激活，也不会被系统主动重发。
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        let handler: (String) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { script in
            return { _ in
                NotificationCenter.default.post(name: .foliaRemoteCommand, object: script)
                return .success
            }
        }

        center.nextTrackCommand.addTarget(handler: handler("next"))
        center.previousTrackCommand.addTarget(handler: handler("prev"))
    }
}

extension Notification.Name {
    static let foliaRemoteCommand = Notification.Name("app.folia.remote-command")
}
