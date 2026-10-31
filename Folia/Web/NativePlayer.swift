import Foundation
import AVFoundation
import MediaPlayer
import WebKit

/// 原生音频播放器桥。
///
/// 参考Folia汽水版本的实现：用原生AVPlayer播放，而不是用网页的WebAudio。
/// 这样进后台、切App都不会影响声音，从根本上解决"进入抖音后回来没声音"的问题。
///
/// JS通过window.webkit.messageHandlers.foliaPlayer发送命令：
/// - load: 加载并播放音频
/// - play: 继续播放
/// - pause: 暂停
/// - seek: 跳转
/// - volume: 调整音量
/// - muted: 静音
/// - status: 查询状态
///
/// 原生通过window.__foliaNativePlayerEvent回调状态。
final class NativePlayer: NSObject, WKScriptMessageHandler {
    static let shared = NativePlayer()

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?

    /// 当前会话ID，用于区分不同页面/不同启动的请求
    private var currentSession: String?
    /// 当前代际，用于区分不同歌曲
    private var currentGeneration: Int = 0
    /// 当前是否在播放
    private(set) var isPlaying = false
    /// 当前URL
    private var currentURL: String?
    /// 音量意图
    private var volumeIntent: Float = 1.0
    /// 静音意图
    private var mutedIntent = false

    /// 弱引用webView，用于回调JS
    weak var webView: WKWebView?

    override init() {
        super.init()
        setupAudioSession()
    }

    private func setupAudioSession() {
        // 确保音频会话配置正确
        AudioSessionController.shared.configure()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let cmd = body["cmd"] as? String ?? ""
        CrashLog.note("NativePlayer: received cmd=\(cmd)")

        // 保存会话信息
        if let session = body["session"] as? String {
            currentSession = session
        }
        if let generation = body["generation"] as? Int {
            currentGeneration = generation
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch cmd {
            case "load":
                self.handleLoad(body)
            case "play":
                self.handlePlay()
            case "pause":
                self.handlePause()
            case "seek":
                self.handleSeek(body)
            case "volume":
                self.handleVolume(body)
            case "muted":
                self.handleMuted(body)
            case "status":
                self.handleStatus()
            default:
                break
            }
        }
    }

    // MARK: - 命令处理

    private func handleLoad(_ body: [String: Any]) {
        guard let urlString = body["url"] as? String,
              let url = URL(string: urlString) else {
            CrashLog.note("NativePlayer: load failed, invalid url")
            sendEvent(type: "error", message: "invalid url")
            return
        }

        CrashLog.note("NativePlayer: load url=\(urlString.prefix(100))")
        currentURL = urlString
        let position = body["position"] as? Double ?? 0
        let autoplay = body["autoplay"] as? Bool ?? true
        volumeIntent = body["volume"] as? Float ?? 1.0
        mutedIntent = body["muted"] as? Bool ?? false

        // 清理旧的观察
        cleanupObservers()

        // 创建新的播放项
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        playerItem = item

        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }

        player?.volume = mutedIntent ? 0 : volumeIntent
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600))

        // 观察状态
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                CrashLog.note("NativePlayer: ready to play, duration=\(item.duration.seconds)")
                self.sendEvent(type: "loaded", duration: item.duration.seconds)
                if autoplay {
                    self.player?.play()
                    self.isPlaying = true
                    self.sendEvent(type: "state", playing: true)
                }
            case .failed:
                CrashLog.note("NativePlayer: failed - \(item.error?.localizedDescription ?? "unknown")")
                self.sendEvent(type: "error", message: item.error?.localizedDescription ?? "playback failed")
            default:
                break
            }
        }

        durationObserver = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            guard let self, item.duration.isValid else { return }
            self.sendEvent(type: "duration", duration: item.duration.seconds)
        }

        // 定时回调播放进度
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, time.isValid else { return }
            self.sendEvent(type: "time", position: time.seconds, playing: self.isPlaying)
        }

        // 监听播放结束
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinishPlaying(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    private func handlePlay() {
        player?.play()
        isPlaying = true
        sendEvent(type: "state", playing: true)
    }

    private func handlePause() {
        player?.pause()
        isPlaying = false
        sendEvent(type: "state", playing: false)
    }

    private func handleSeek(_ body: [String: Any]) {
        guard let position = body["position"] as? Double else { return }
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        sendEvent(type: "time", position: position, playing: isPlaying)
    }

    private func handleVolume(_ body: [String: Any]) {
        guard let volume = body["volume"] as? Float else { return }
        volumeIntent = volume
        if !mutedIntent {
            player?.volume = volume
        }
    }

    private func handleMuted(_ body: [String: Any]) {
        guard let muted = body["muted"] as? Bool else { return }
        mutedIntent = muted
        player?.volume = muted ? 0 : volumeIntent
    }

    private func handleStatus() {
        let position = player?.currentTime().seconds ?? 0
        let duration = playerItem?.duration.seconds ?? 0
        sendEvent(type: "state", position: position, duration: duration, playing: isPlaying)
    }

    // MARK: - 播放结束

    @objc private func itemDidFinishPlaying(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem, item == playerItem else { return }
        isPlaying = false
        sendEvent(type: "ended", position: item.duration.seconds, duration: item.duration.seconds)
    }

    // MARK: - 回调JS

    private func sendEvent(type: String,
                           position: Double? = nil,
                           duration: Double? = nil,
                           playing: Bool? = nil,
                           message: String? = nil) {
        var event: [String: Any] = [
            "type": type,
            "session": currentSession ?? "",
            "generation": currentGeneration,
            "sentAtMs": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let position = position { event["position"] = position }
        if let duration = duration, duration.isFinite { event["duration"] = duration }
        if let playing = playing { event["playing"] = playing }
        if let message = message { event["message"] = message }

        // 序列化JSON并调用JS
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let js = "window.__foliaNativePlayerEvent && window.__foliaNativePlayerEvent(\(jsonString));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - 清理

    private func cleanupObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        durationObserver?.invalidate()
        durationObserver = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    func reset() {
        cleanupObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        isPlaying = false
        currentURL = nil
        currentSession = nil
        currentGeneration = 0
    }
}
