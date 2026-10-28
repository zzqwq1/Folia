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
final class FoliaBackgroundAudio: NSObject {
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
    /// 「没能出声」的补救次数已经用满：再补下去只会变成反复起播的杂音。
    private var gaveUp = false

    private var src = ""
    private var position: TimeInterval = 0
    private var sourceDuration: TimeInterval = 0

    private let player = AVPlayer()
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var routeObservation: NSObjectProtocol?
    /// 起播阶段的重试次数。`AVPlayer` 在会话刚切换、网络刚断时第一次 `play()`
    /// 经常直接失败，不留退路就是「后台一点声都没有」。
    private var playAttempts = 0
    private var retryWork: DispatchWorkItem?
    /// 上一次观察到进度推进的时刻。
    private var lastProgressAt = Date()

    private override init() {
        super.init()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        // 主队列每隔半秒跑一次（原来是 0.25 秒）：接管只在后台发生，半秒的相位差听不出来，
        // 但主线程的回调量减半，回前台后不会因为还在刷新 Now Playing 而卡一下。
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.tick(time)
        }
        // 接管期间音频通路发生切换（拔耳机、蓝牙断开、来电结束）时 AVPlayer 会停住，
        // 不回前台就再也不会自己响，这里补一次 play。
        routeObservation = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recoverIfStalled(reason: "route")
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
        if let src, !src.isEmpty, src != self.src {
            // 换了曲目：进度必须跟着新歌走，旧进度套上去就是「回前台从头开始」。
            self.src = src
            self.position = max(0, position ?? 0)
            sourceDuration = duration.map { $0 > 1 ? $0 : 0 } ?? 0
            return
        }
        if let src, !src.isEmpty { self.src = src }
        if let position { self.position = max(0, position) }
        if let duration, duration > 1 { sourceDuration = duration }
    }

    /// 页面把某一首从头放起（用户在前台点了歌），时间戳是这一刻的。
    ///
    /// 只在「确实换了曲目」时才算从头开始：同一首反复触发 `play`
    /// （缓冲完、切歌词重建播放器树）不能把进度清成 0，否则回前台就会从头开始。
    func pageStartedTrack(src: String?) {
        guard let src, !src.isEmpty else { return }
        let isNewTrack = src != self.src
        self.src = src
        hasReport = true
        pagePlaying = true
        guard isNewTrack else { return }
        position = 0
        sourceDuration = 0
        pendingFreshStart = true
    }

    /// 页面自己 seek 了。接管中就直接把原生对齐。
    func pageSeeked(to position: Double) {
        self.position = max(0, position)
        if isActive { seekNative(to: self.position, thenPlay: pagePlaying) }
    }

    // MARK: - 接管

    /// 在后台起播，接着页面最后一次汇报的进度放。
    ///
    /// `position` 显式给出时以它为准：进后台前刚抓到的进度、或回前台交还后要接着的那一秒，
    /// 都比定时汇报更准（汇报最长有三秒延迟）。
    func start(reason: String, position explicitPosition: TimeInterval? = nil) {
        guard hasReport, pagePlaying, !isActive else {
            logState("skip-\(reason)")
            return
        }
        guard let url = URL(string: src), !src.isEmpty else {
            CrashLog.note("==== native takeover skipped: no source (\(reason)) ====")
            return
        }
        // 后台任务只保证约 30 秒，真正让进程活着的是「正在出声」这件事本身；
        // 但 WebProcess 一旦被挂起，页面就再也不会自己切下一首，这里先把任务续上。
        UIApplication.shared.beginBackgroundTask(withName: "folia.native-takeover")
        if let explicitPosition {
            position = max(0, explicitPosition)
        } else if pendingFreshStart {
            // 页面刚开始这一首却还没报进度：从 0 接管，而不是拿上一首的进度乱跳。
            position = 0
        }
        pendingFreshStart = false
        isActive = true
        didPlayInActive = false
        gaveUp = false
        // 上一次有进度推进的时刻。用它判断「亮着 rate 但根本没出声」。
        lastProgressAt = Date()
        CrashLog.note("==== native takeover start (\(reason)) at \(String(format: "%.1f", position))s ====")
        logState("start")
        load(url: url, seekTo: position)
    }

    /// 页面已经放不出声音（回前台重建 AudioContext 也没救回来）时，由原生接着这一秒放。
    ///
    /// 与 `start` 的区别只有两点：不看 `pagePlaying`（页面此刻是「在播但其实没声」，
    /// 状态机上仍算在播，页面侧一旦把它置成暂停就永远轮不到这里），
    /// 并且进度一律以调用方给的为准。
    func startFresh(position: TimeInterval, reason: String) {
        guard !isActive, !src.isEmpty, URL(string: src) != nil else {
            CrashLog.note("==== native retake skipped (\(reason)) ====")
            return
        }
        hasReport = true
        pagePlaying = true
        start(reason: reason, position: position)
    }

    /// 交还给页面：停掉原生，返回交还时的进度（秒）。
    ///
    /// 只要接管期间有过进度就返回，不再要求「确实响成过」：接管了却因为会话竞争没出声时，
    /// 页面在后台同样停了好几秒，此时返回 nil 会让前台从页面自己的旧进度续上，
    /// 用户看到的就是「回来既没声、又对不上」。
    func handBack() -> TimeInterval? {
        guard isActive else { return nil }
        let current = currentPosition()
        let played = didPlayInActive
        stopInternal()
        CrashLog.note("==== native takeover end at \(String(format: "%.1f", current))s played=\(played ? 1 : 0) ====")
        return current > 0 ? current : nil
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

    /// 进后台接管前的自检日志：出问题时靠它判断到底是「没接管」还是「接管了没声音」。
    func logState(_ tag: String) {
        CrashLog.note("==== native takeover state (\(tag)) report=\(hasReport ? 1 : 0) playing=\(pagePlaying ? 1 : 0) active=\(isActive ? 1 : 0) rate=\(String(format: "%.1f", player.rate)) pos=\(String(format: "%.1f", position)) ====")
        CrashLog.note("native source: \(src.isEmpty ? "-" : src)")
    }

    // MARK: - 内部

    private func load(url: URL, seekTo position: TimeInterval) {
        // 接管这一刻会话可能刚被系统降级：不先激活，AVPlayer 起来了也是静音。
        try? AVAudioSession.sharedInstance().setActive(true)
        playAttempts = 0
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let self else { return }
            switch observed.status {
            case .readyToPlay:
                DispatchQueue.main.async { self.seekNative(to: position, thenPlay: true) }
            case .failed:
                let message = observed.error?.localizedDescription ?? "-"
                CrashLog.note("==== native takeover item failed ====")
                CrashLog.note("item failed: \(message)")
                DispatchQueue.main.async { self.scheduleRetry(reason: "item-failed") }
            default:
                break
            }
        }
        // `replaceCurrentItem` 会把上一首的 rate 清成 0：不在这里补一次 play，
        // 回调链上任何一环没走到（readyToPlay 迟迟不来），就一直是「接管了但没声」。
        player.replaceCurrentItem(with: item)
        player.isMuted = false
        // 音量一开始就拉满：这里压到 0 再等 seek 回调放回来，一旦回调没走到
        // （item 换掉、接管被取消）就是彻底静音，而日志上看一切正常。
        // 爆音由 `seek` 的零容差 + `automaticallyWaitsToMinimizeStalling = false` 规避。
        player.volume = 1
        // 音频类 App 必须显式告诉系统「我要出声」，否则后台被当成纯计算进程静音拉走。
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()
    }

    private func seekNative(to position: TimeInterval, thenPlay: Bool) {
        let seek = CMTime(seconds: max(0, position), preferredTimescale: 600)
        player.seek(to: seek, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            // 这里不再拿 `isActive` 当门槛：seek 完成时接管可能刚被取消（回前台的竞态），
            // 由 `stopInternal` 负责真正停下，回调只要保证「该响的时候一定起播」。
            guard thenPlay else { return }
            DispatchQueue.main.async {
                guard self.isActive else { return }
                self.player.play()
                self.didPlayInActive = true
                self.refreshNowPlaying()
                // play() 只是「请求播放」，真正是否出声要看一小会儿之后的 rate。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.recoverIfStalled(reason: "after-play")
                }
            }
        }
    }

    /// 接管中却发现没在响：补激活会话再 play 一次，最多几次。
    ///
    /// 这一步是「后台没声音」的直接补救：系统在切后台瞬间会把会话降级，
    /// 此时 AVPlayer 的 rate 会掉到 0，而且不会再自己恢复。
    ///
    /// 注意这里**不重设 category**：后台调用 `setCategory` 会让系统重新评估音频资格，
    /// 每一次都可能在刚接通的通路上再断一次，是「接管了却没声」的放大器。
    /// 只对会话做 `setActive`，配一次零容差 seek 把停顿的 item 顶起来。
    private func recoverIfStalled(reason: String) {
        guard isActive, !gaveUp, player.currentItem != nil else { return }
        if player.rate > 0 && Date().timeIntervalSince(lastProgressAt) < 2.0 { return }
        guard playAttempts < 8 else {
            gaveUp = true
            CrashLog.note("==== native takeover give up (\(reason)) ====")
            return
        }
        playAttempts += 1
        // 卡住超过两秒才补进度：真在放的时候不要每 0.25 秒 seek 一次。
        let stalled = Date().timeIntervalSince(lastProgressAt) > 2.0
        try? AVAudioSession.sharedInstance().setActive(true)
        // 音量被系统静音过（通话、其他 App 抢占）时不会被自动还原。
        if !player.isMuted { player.volume = 1 }
        player.play()
        if stalled {
            // 卡住时播放器常常停在缓冲态，不 seek 就永远不动。
            player.seek(to: CMTime(seconds: max(0, position), preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero)
            // seek 之后必须重新确认 play：部分机型 seek 会隐式暂停。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.isActive else { return }
                self.player.play()
            }
        }
        CrashLog.note("==== native takeover replay (\(reason)) attempt=\(playAttempts) ====")
    }

    private func scheduleRetry(reason: String) {
        guard isActive else { return }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, !self.src.isEmpty, let url = URL(string: self.src) else { return }
            CrashLog.note("==== native takeover retry (\(reason)) ====")
            self.load(url: url, seekTo: self.position)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func tick(_ time: CMTime) {
        guard isActive else { return }
        let t = time.seconds
        if t.isFinite, t > 0 {
            position = t
            playAttempts = 0
            lastProgressAt = Date()
            // 只要时间轴推进过就算「真的在响」：`didPlayInActive` 原来只在 seek 回调里置位，
            // 回调没走到时 `handBack()` 会返回 nil，回前台就丢了进度、也不对齐。
            if player.rate > 0 { didPlayInActive = true }
        }
        // 「接管了却没声音」的看门狗。AVPlayer 在音频通路不通时表现得很有欺骗性：
        // rate 可能仍是 1、时间也在走，可喇叭里什么都没有，所以只能按「有没有在出进度」兜。
        if let item = player.currentItem, item.status == .readyToPlay {
            let stalled = Date().timeIntervalSince(lastProgressAt) > 2.0
            if player.rate <= 0 || stalled {
                recoverIfStalled(reason: "tick")
            }
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
        retryWork?.cancel()
        retryWork = nil
        playAttempts = 0
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
