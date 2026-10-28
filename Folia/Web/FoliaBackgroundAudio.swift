import AVFoundation
import MediaPlayer
import UIKit

/// 后台出声。
///
/// 线上页用 WebAudio 出声：`<audio>` 只当解码源（`createMediaElementSource`），
/// 真正送到扬声器的是 AudioContext 里的节点图。iOS 在 App 退到后台时会把进程内的
/// AudioContext 整体钉住（WebKit 已知问题，Safari 里也一样）：页面仍以为自己「在播」，
/// 时间轴却不再前进；回到前台也不会自己解开。壳侧对 `<audio>` 反复 `play()` 拿不回来，
/// 这就是「退到后台没声音、再进来也没声音」。
///
/// 所以后台这一段改由原生接着放：页面定期报上当前曲目地址、进度与是否在播，
/// 壳用 `AVPlayer` 从同一个原始音频地址接着出声；回到前台再交还给页面。
///
/// 接管期间页面的均衡器、自动化效果、歌词跳字都不生效，这是这条路的固有代价。
final class FoliaBackgroundAudio {
    static let shared = FoliaBackgroundAudio()

    /// 页面从未汇报过状态时一律不接管：宁可不响，也不能在用户没播歌时自己出声。
    private(set) var hasReport = false
    /// 最后一条汇报里页面是否正在播放。
    private(set) var pagePlaying = false
    /// 正在接管：声音由原生放，页面那条被系统钉住的通路应该停着。
    private(set) var isActive = false

    /// 接管后确实响过。没响成过就谈不上「交还」，回前台直接放弃。
    private var didPlayInActive = false
    /// 页面自己的播放器从头放起了某一首：这时不该再拿旧进度去接管。
    private var pendingFreshStart = false

    private var src = ""
    private var position: TimeInterval = 0
    private var sourceDuration: TimeInterval = 0

    private let player = AVPlayer()
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    private init() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.tick(time)
        }
    }

    // MARK: - 页面汇报

    /// 页面每 3 秒来一条。`playing` 为 nil 表示这次没取到，沿用上一次。
    func updateReport(src: String?, position: Double?, duration: Double?, playing: Bool?) {
        guard !isActive else { return }
        if let playing {
            hasReport = true
            pagePlaying = playing
        }
        if let src, !src.isEmpty { self.src = src }
        if let position { self.position = max(0, position) }
        if let duration, duration > 1 { sourceDuration = duration }
    }

    /// 页面把某一首从头放起（用户在前台点了歌），时间戳是这一刻的。
    func pageStartedTrack(src: String?) {
        if let src, !src.isEmpty { self.src = src }
        position = 0
        sourceDuration = 0
        hasReport = true
        pagePlaying = true
        pendingFreshStart = true
    }

    /// 页面自己 seek 了。接管中就直接把原生对齐。
    func pageSeeked(to position: Double) {
        self.position = max(0, position)
        if isActive { seekNative(to: self.position, thenPlay: pagePlaying) }
    }

    // MARK: - 接管

    /// 在后台起播，接着页面最后一次汇报的进度放。
    func start(reason: String) {
        guard hasReport, pagePlaying, !isActive else { return }
        guard let url = URL(string: src), !src.isEmpty else {
            CrashLog.note("==== native takeover skipped: no source (\(reason)) ====")
            return
        }
        // 页面刚开始这一首却还没报进度：从 0 接管，而不是拿上一首的进度乱跳。
        if pendingFreshStart { position = 0 }
        pendingFreshStart = false
        isActive = true
        didPlayInActive = false
        CrashLog.note("==== native takeover start (\(reason)) at \(String(format: "%.1f", position))s ====")
        load(url: url, seekTo: position)
    }

    /// 交还给页面：停掉原生，返回交还时的进度（秒）。没接管过、或一次都没响成，返回 nil。
    func handBack() -> TimeInterval? {
        guard isActive else { return nil }
        let current = currentPosition()
        let played = didPlayInActive
        stopInternal()
        CrashLog.note("==== native takeover end at \(String(format: "%.1f", current))s played=\(played ? 1 : 0) ====")
        return played ? current : nil
    }

    /// 接管中被用户按了暂停：先淡出再停，避免「咔」一声。
    func pauseForUser() {
        guard isActive else { return }
        let current = currentPosition()
        stopInternal()
        position = current
        pagePlaying = false
    }

    /// 接管中用户又按了播放。
    func resumeForUser() {
        guard hasReport, pagePlaying, !isActive else { return }
        start(reason: "user-play")
    }

    /// 当前进度：优先用播放器报文，锁屏拖动后也能对上。
    func currentPosition() -> TimeInterval {
        guard isActive, let item = player.currentItem else { return position }
        let t = item.currentTime().seconds
        if t.isFinite, t > 0 { return t }
        return position
    }

    var isPlayingInBackground: Bool {
        isActive && player.rate > 0
    }

    // MARK: - 内部

    private func load(url: URL, seekTo position: TimeInterval) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.seekNative(to: position, thenPlay: true) }
        }
        player.replaceCurrentItem(with: item)
        // 先把音量压到 0：接管那一刻页面那条通路刚被系统钉住，硬切会「咔」一声。
        player.volume = 0
    }

    private func seekNative(to position: TimeInterval, thenPlay: Bool) {
        let seek = CMTime(seconds: max(0, position), preferredTimescale: 600)
        player.seek(to: seek, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, self.isActive, thenPlay else { return }
            self.player.play()
            self.didPlayInActive = true
            self.player.volume = 1
            self.refreshNowPlaying()
        }
    }

    private func tick(_ time: CMTime) {
        guard isActive else { return }
        let t = time.seconds
        if t.isFinite, t > 0 {
            position = t
        }
        refreshNowPlayingTime()
        // 一首放完：页面那边此时正被系统钉住，不会再自己切歌。
        // 先停下原生，免得出声与页面各说各话；用户回到 App 后页面会自己接下一首。
        if let item = player.currentItem {
            let end = item.duration.seconds
            if end.isFinite, end > 0, t >= end - 0.4, player.rate > 0 {
                CrashLog.note("==== native takeover reached end ====")
                stopInternal()
                pagePlaying = false
            }
        }
    }

    private func stopInternal() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        isActive = false
        didPlayInActive = false
    }

    private func refreshNowPlaying() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPMediaItemPropertyPlaybackDuration] = sourceDuration > 1 ? sourceDuration : player.currentItem?.duration.seconds ?? 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlayingTime() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition()
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        let end = player.currentItem?.duration.seconds ?? 0
        if end.isFinite, end > 1 { info[MPMediaItemPropertyPlaybackDuration] = end }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
