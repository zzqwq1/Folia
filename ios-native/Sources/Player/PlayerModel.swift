import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// 全局播放器：单实例 AVPlayer + NowPlaying + RemoteCommand + 队列/循环。
/// 为播放页对齐桌面 1.8.5（FloatingPlayerControls / ProgressBar）补齐了：
/// 进度发布（currentTime/duration）、seek、队列（上一首/下一首）、循环模式。
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// 播放进度（播放页进度条 + 歌词滚动共用，每 0.25s 更新）。
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    /// 当前队列（上一首/下一首的数据源；单曲播放时为 []，切歌钮禁用）。
    @Published private(set) var queue: [Track] = []

    /// 循环模式：对齐桌面 FloatingPlayerControls 的循环槽位。
    enum LoopMode: String {
        case off, all, one
    }
    @Published private(set) var loopMode: LoopMode = .all

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// 队列里切歌时复用的 Cookie（同一队列同属一个平台/账号）。
    private var currentCookie: String?

    init() {
        setupRemoteCommands()
        setupEndObserver()
    }

    /// 播放一首歌；`queue` 为空表示单曲播放（切歌钮不可用）。
    func play(_ track: Track, cookie: String?, queue: [Track] = []) async {
        errorMessage = nil
        isLoading = true
        current = track
        self.queue = queue
        currentCookie = cookie
        resetProgress()
        defer { isLoading = false }

        do {
            let url: URL
            switch track.provider {
            case .netease:
                url = try await FoliaAPI.neteaseSongUrl(id: track.id, cookie: cookie ?? "")
            default:
                throw APIClient.APIError.badStatus(501, "provider \(track.provider.rawValue) not wired")
            }
            startPlayback(url: url, track: track)
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
            current = nil
            queue = []
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
    }

    func stop() {
        removeTimeObserver()
        player?.pause()
        player = nil
        current = nil
        queue = []
        resetProgress()
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 拖动进度（对齐 ProgressBar 的轨道拖动）。
    func seek(to time: TimeInterval) {
        guard let item = player?.currentItem else { return }
        let clamped = min(max(time, 0), max(item.duration.seconds, 0))
        item.seek(to: CMTime(seconds: clamped, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        currentTime = clamped
    }

    func toggleLoop() {
        switch loopMode {
        case .off: loopMode = .all
        case .all: loopMode = .one
        case .one: loopMode = .off
        }
        updateNowPlaying()
    }

    /// 下一首：尊重循环模式；无队列时回到开头重播。
    func playNext() {
        guard let current else { return }
        if loopMode == .one {
            seek(to: 0)
            player?.play()
            isPlaying = true
            updateNowPlaying()
            return
        }
        guard let idx = queue.firstIndex(of: current) else {
            seek(to: 0)
            player?.play()
            isPlaying = true
            updateNowPlaying()
            return
        }
        if idx + 1 < queue.count {
            Task { await play(queue[idx + 1], cookie: currentCookie, queue: queue) }
        } else if loopMode == .all, let first = queue.first {
            Task { await play(first, cookie: currentCookie, queue: queue) }
        }
        // loop off 且已到队尾：自然停住（对齐桌面行为）
    }

    /// 上一首：已播超过 3s 则回开头；否则回上一首。
    func playPrevious() {
        guard let current else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let idx = queue.firstIndex(of: current), idx > 0 else {
            seek(to: 0)
            return
        }
        Task { await play(queue[idx - 1], cookie: currentCookie, queue: queue) }
    }

    // MARK: - Private

    private func startPlayback(url: URL, track: Track) {
        let item = AVPlayerItem(url: url)
        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
        }
        player?.play()
        isPlaying = true
        setupTimeObserver()
        updateNowPlaying()
    }

    private func resetProgress() {
        currentTime = 0
        duration = 0
    }

    private func setupTimeObserver() {
        removeTimeObserver()
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds
                if let item = self.player?.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 {
                    self.duration = item.duration.seconds
                }
                self.updateNowPlaying()
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackEnd()
            }
        }
    }

    private func handleTrackEnd() {
        switch loopMode {
        case .one:
            seek(to: 0)
            player?.play()
            isPlaying = true
            updateNowPlaying()
        case .all, .off:
            playNext()
        }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
        ]
        if let album = track.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let trackDuration = track.durationMs {
            info[MPMediaItemPropertyPlaybackDuration] = Double(trackDuration) / 1000.0
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.play(); self?.isPlaying = true; self?.updateNowPlaying() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.pause(); self?.isPlaying = false; self?.updateNowPlaying() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }
}
