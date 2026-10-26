//
//  PlayerEngine.swift
//  Folia
//
//  原生播放内核：AVPlayer 负责解码与播放，AVAudioSession 负责后台/锁屏，
//  MPRemoteCommandCenter 接管控制中心与耳机线控。
//  这是「系统级性能」的核心：音频完全走系统播放器，列表滚动再重也不会影响出声。
//

import AVFoundation
import MediaPlayer

@MainActor
final class PlayerEngine: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var queue: [Track] = []
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .all

    enum RepeatMode { case off, all, one }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    /// 由 App 启动时注入，用于把歌曲解析成可播放地址。
    weak var library: LibraryStore?
    @Published private(set) var isLoadingTrack = false
    @Published private(set) var message: String?

    init() {
        configureSession()
        configureRemoteCommands()
        startTimeObserver()
    }

    // MARK: - 音频会话

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // 会话配置失败时静默降级为 App 内播放。
            NSLog("[Folia] audio session error: \(error)")
        }
    }

    // MARK: - 播放控制

    func play(_ track: Track, in tracks: [Track]? = nil) {
        if let tracks, !tracks.isEmpty { queue = tracks }
        current = track
        currentTime = 0
        duration = track.duration
        message = nil

        // 已经有直链就立即出声，不必等解析。
        if let url = track.streamURL {
            loadTask?.cancel()
            isLoadingTrack = false
            startPlayback(url: url)
            return
        }

        loadTask?.cancel()
        isLoadingTrack = true
        loadTask = Task { [weak self] in
            guard let strongSelf = self else { return }
            defer { strongSelf.isLoadingTrack = false }

            do {
                guard let library = strongSelf.library else { return }
                let url = try await library.streamURL(for: track)
                guard !Task.isCancelled else { return }
                strongSelf.startPlayback(url: url)
            } catch {
                guard !Task.isCancelled else { return }
                strongSelf.message = "该歌曲暂时无法播放"
            }
        }
    }

    private func startPlayback(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        endObserver.map(NotificationCenter.default.removeObserver)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackEnded()
            }
        }

        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func togglePlayPause() {
        guard current != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    func next() {
        guard let current,
              let index = queue.firstIndex(of: current) else { return }
        let nextIndex: Int
        if shuffle, queue.count > 1 {
            repeat {
                nextIndex = Int.random(in: 0..<queue.count)
            } while nextIndex == index
        } else {
            nextIndex = index + 1
        }
        if nextIndex < queue.count {
            play(queue[nextIndex])
        } else if repeatMode == .all, let first = queue.first {
            play(first)
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func previous() {
        guard let current,
              let index = queue.firstIndex(of: current) else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if index > 0 {
            play(queue[index - 1])
        } else {
            seek(to: 0)
        }
    }

    private func handleTrackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
        } else {
            next()
        }
    }

    // MARK: - 进度

    private func startTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            let total = self.player.currentItem?.duration.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                if let total, total.isFinite, total > 0 {
                    self.duration = total
                }
            }
        }
    }

    // MARK: - 锁屏 / 控制中心

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying { self.togglePlayPause() }
            }
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
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
