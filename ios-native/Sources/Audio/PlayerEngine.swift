import AVFoundation
import MediaPlayer
import UIKit

/// 播放引擎：AVPlayer + 队列 + 循环/随机。
///
/// 原版前端用 A/B 双 `<audio>` 做 automix 无缝过渡；原生侧换成 AVQueuePlayer 的
/// 换项机制会更复杂（每首歌都要重新签名 URL），这里用单个 AVPlayer 在临结尾时预取下一首：
/// 曲目切换时先 resolve 好音频地址再 replaceCurrentItem，间隙通常只有几十毫秒。
@MainActor
final class PlayerEngine: NSObject, ObservableObject {
    enum RepeatMode: String, CaseIterable {
        case off, all, one
    }

    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPreview = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var errorMessage: String?

    /// 队列来源（播放面板头部显示的集合名）
    @Published private(set) var contextName: String = ""

    // 设置项
    @Published var volume: Float = 1 { didSet { player.volume = volume } }
    @Published var isMuted = false { didSet { player.isMuted = isMuted } }
    @Published var repeatMode: RepeatMode = .all
    @Published var isShuffleEnabled = false

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    /// 随机播放时已经用过的下标，避免连续重复
    private var playedIndices: Set<Int> = []

    var currentSong: Song? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    override init() {
        super.init()
        player.volume = volume
        AudioSessionConfigurator.configure()
        observeTime()
        observeEnd()
        setupRemoteCommands()
    }

    // MARK: - 播放控制

    /// 用一个新的集合替换队列并从 startIndex 开始播
    func play(_ songs: [Song], startIndex: Int = 0, contextName: String = "") {
        guard !songs.isEmpty else { return }
        queue = songs
        self.contextName = contextName
        playedIndices = [startIndex]
        load(index: startIndex, autoPlay: true)
    }

    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        playedIndices.insert(index)
        load(index: index, autoPlay: true)
    }

    func togglePlayPause() {
        guard currentSong != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if player.currentItem == nil {
                load(index: currentIndex, autoPlay: true)
            } else {
                player.play()
                isPlaying = true
            }
        }
        updateNowPlaying()
    }

    func next(userInitiated: Bool = true) {
        guard !queue.isEmpty else { return }
        if repeatMode == .one, !userInitiated {
            seek(to: 0)
            player.play()
            return
        }
        let index: Int
        if isShuffleEnabled {
            index = randomIndex()
        } else {
            index = currentIndex + 1
        }
        if index >= queue.count {
            if repeatMode == .off {
                player.pause()
                isPlaying = false
                return
            }
            playedIndices = [0]
            load(index: 0, autoPlay: true)
        } else {
            load(index: index, autoPlay: true)
        }
    }

    /// 原版循环钮：列表循环 → 单曲循环 → 关闭
    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        // 播过 3 秒以上就回到本曲开头，和系统播放器一致
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let index = isShuffleEnabled ? randomIndex() : max(currentIndex - 1, 0)
        load(index: index, autoPlay: true)
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func remove(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if queue.isEmpty {
            stop()
            return
        }
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            load(index: min(currentIndex, queue.count - 1), autoPlay: isPlaying)
        }
    }

    // MARK: - 队列编辑（对应原版 wallpaperHost 的 addToQueue / playNext / moveQueueSong）

    /// 全部加入队列：已经在队列里的同一首跳过（原版 addToQueue 的去重规则）
    func addToQueue(_ songs: [Song]) {
        let existing = Set(queue.map(\.id))
        let fresh = songs.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        queue.append(contentsOf: fresh)
        if wasEmpty {
            load(index: 0, autoPlay: true)
        }
    }

    /// 下一首播放：插在当前曲目后面，队尾播放时接着播
    func playNext(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let song = queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(song, at: insertAt)
        playedIndices.removeAll()
    }

    /// 移到队尾
    func moveToEnd(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let song = queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            // 正在播的那首挪到队尾：保持一致，画面不跳
            currentIndex = queue.count
        }
        queue.append(song)
    }

    func clearQueue() {
        stop()
    }

    func stop() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        queue = []
        currentIndex = -1
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 随机：优先没播过的下标
    private func randomIndex() -> Int {
        let candidates = queue.indices.filter { !playedIndices.contains($0) }
        let pool = candidates.isEmpty ? Array(queue.indices) : candidates
        if candidates.isEmpty { playedIndices.removeAll() }
        let pick = pool.randomElement() ?? 0
        playedIndices.insert(pick)
        return pick
    }

    // MARK: - 载入

    private func load(index: Int, autoPlay: Bool) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        let song = queue[index]
        isLoading = true
        errorMessage = nil
        isPreview = false
        loadTask?.cancel()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (url, preview) = try await NeteaseAPI.shared.audioURL(songId: song.id)
                guard !Task.isCancelled else { return }
                self.isPreview = preview
                let item = AVPlayerItem(url: url)
                self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in
                        self?.handleFailure(item.error?.localizedDescription ?? "无法播放这首歌")
                    }
                }
                self.player.replaceCurrentItem(with: item)
                self.duration = Double(song.durationMs) / 1000
                self.currentTime = 0
                self.isLoading = false
                if autoPlay {
                    self.player.play()
                    self.isPlaying = true
                }
                self.updateNowPlaying()
            } catch {
                guard !Task.isCancelled else { return }
                self.handleFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func handleFailure(_ message: String) {
        isLoading = false
        isPlaying = false
        errorMessage = message
        // 队列里还有下一首就跳过去，别卡在一首坏歌上
        if queue.count > 1 {
            next(userInitiated: false)
        }
    }

    // MARK: - 观察

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.updateNowPlayingElapsed()
            }
        }
    }

    private func observeEnd() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.next(userInitiated: false) }
        }
    }

    // MARK: - 锁屏 / 控制中心

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return MPRemoteCommandHandlerStatus.success
        }
    }

    private func updateNowPlaying() {
        guard let song = currentSong else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artistNames,
            MPMediaItemPropertyAlbumTitle: song.album.name,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let cover = song.album.cover(size: 600) {
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: cover),
                      let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                Task { @MainActor in
                    guard let self, self.currentSong == song else { return }
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    self.updateNowPlayingElapsed()
                }
            }
        }
    }

    /// 只刷新进度，避免每秒重建整份 info 导致锁屏封面闪
    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
