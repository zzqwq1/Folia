import Foundation
import AVFoundation

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
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 音频会话失败不影响网页功能，只是切后台可能被系统暂停。
            NSLog("[Folia] audio session setup failed: \(error.localizedDescription)")
        }

        observeInterruptions()
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
                break
            }
        }
    }
}
