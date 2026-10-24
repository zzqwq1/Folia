import Foundation
import MediaPlayer
import UIKit

/// 锁屏控制桥：
/// - 接收前端 `navigator.mediaSession`（经 JS 包装 → WKScriptMessageHandler）上报的
///   元数据与播放状态，写入 MPNowPlayingInfoCenter，驱动系统锁屏 / 控制中心；
/// - 把 MPRemoteCommandCenter（耳机线控、锁屏按钮、CarPlay）命令回传给前端 `window.__foliaRemote`；
/// - 后台 JS 定时器被系统冻结时，用原生定时器自增 ElapsedPlaybackTime 兜底进度。
final class FoliaMediaBridge {

    static let shared = FoliaMediaBridge()

    /// 把远程命令转发到前端 JS（由 FoliaWebHostController 注入 evaluateJavaScript）
    var commandHandler: ((String) -> Void)?
    /// 把 seek 事件转发到前端 JS
    var seekHandler: ((TimeInterval) -> Void)?

    private var registered = false
    private let nowPlaying = MPNowPlayingInfoCenter.default()

    // 元数据
    private var title = ""
    private var artist = ""
    private var album = ""
    private var artworkURL: URL?

    // 播放状态
    private var paused = true
    private var elapsed: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var lastAudioStateAt: Date?

    private var artworkCache: [String: MPMediaItemArtwork] = [:]

    func ensureRegistered() {
        guard !registered else { return }
        registered = true

        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            self?.commandHandler?("play")
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.commandHandler?("pause")
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.commandHandler?("toggle")
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.commandHandler?("next")
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.commandHandler?("prev")
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seekHandler?(positionEvent.positionTime)
            return .success
        }

        // 兜底：后台 JS 冻结时自增进度
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.advanceIfFrozen()
        }
    }

    // MARK: - 前端状态同步

    func updateMetadata(title: String, artist: String, album: String, artworkURL: String?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL.flatMap(URL.init(string:))
        refreshNowPlaying()
        loadArtworkIfNeeded()
    }

    func updatePlaybackState(isPlaying: Bool) {
        paused = !isPlaying
        refreshNowPlaying()
    }

    func updateAudioState(paused: Bool, duration: TimeInterval, currentTime: TimeInterval) {
        self.paused = paused
        self.duration = duration
        self.elapsed = currentTime
        lastAudioStateAt = Date()
        refreshNowPlaying()
    }

    // MARK: - NowPlaying 渲染

    private func refreshNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPMediaItemPropertyAlbumTitle] = album
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : 1.0
        if let key = artworkURL?.absoluteString, let art = artworkCache[key] {
            info[MPMediaItemPropertyArtwork] = art
        }
        nowPlaying.nowPlayingInfo = info
    }

    private func loadArtworkIfNeeded() {
        guard let url = artworkURL, artworkCache[url.absoluteString] == nil else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, let data, error == nil, let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artworkCache[url.absoluteString] = artwork
            DispatchQueue.main.async { self.refreshNowPlaying() }
        }.resume()
    }

    private func advanceIfFrozen() {
        guard !paused, duration > 0 else { return }
        if let last = lastAudioStateAt, Date().timeIntervalSince(last) > 2.5 {
            elapsed += 1
            if elapsed > duration { elapsed = duration }
            refreshNowPlaying()
        }
    }
}
