import Foundation
import AVFoundation
import MediaPlayer

/// 全局播放器：单实例 AVPlayer + NowPlaying + RemoteCommand。
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?

    init() {
        setupRemoteCommands()
    }

    deinit {
        if let obs = timeObserver, let player {
            player.removeTimeObserver(obs)
        }
    }

    func play(_ track: Track, cookie: String?) async {
        errorMessage = nil
        isLoading = true
        current = track
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
        player?.pause()
        player = nil
        current = nil
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Private

    private func startPlayback(url: URL, track: Track) {
        let item = AVPlayerItem(url: url)
        player?.replaceCurrentItem(with: item)
        if player == nil {
            player = AVPlayer(playerItem: item)
        }
        player?.play()
        isPlaying = true
        updateNowPlaying()
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
        if let duration = track.durationMs {
            info[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000.0
        }
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
    }
}
