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

    private var configured = false

    func configure() {
        guard !configured else { return }
        configured = true

        let session = AVAudioSession.sharedInstance()
        do {
            // 不加 .mixWithOthers：混音会让系统把本 App 当成「可被压低」的次要音频，
            // 切后台、锁屏时更容易被静音。要让锁屏控制中心把它当主播放器，就得独占。
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // 音频会话失败不影响网页功能，只是切后台可能被系统暂停。
            NSLog("[Folia] audio session setup failed: \(error.localizedDescription)")
        }

        observeInterruptions()
        configureRemoteCommands()
    }

    /// 从后台回到前台时再激活一次：系统可能在后台把会话降级。
    func reactivate() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }

            switch type {
            case .ended:
                // 来电 / 其他 App 抢占结束后重新激活会话，让网页继续播放。
                try? AVAudioSession.sharedInstance().setActive(true)
            default:
                // .began 时必须把会话让出去，否则系统会直接掐断音频。
                break
            }
        }
    }

    /// 锁屏控制中心/耳机线控按钮。
    ///
    /// WKWebView 里的 <audio> 不会自动注册远程控制事件，这里占住这组事件，
    /// 再通过 JS 转给页面自身的播放器，锁屏才能暂停/继续而不是显示成「未在播放」。
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
