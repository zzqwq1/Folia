import Foundation

struct Playlist: Identifiable, Hashable {
    let id: String
    let provider: Provider
    let title: String
    let coverUrl: String?
    let trackCount: Int
    let creator: String?
}

struct Track: Identifiable, Hashable {
    let id: String
    let provider: Provider
    let title: String
    let artist: String
    let album: String?
    let coverUrl: String?
    let durationMs: Int?
}

struct UserProfile: Hashable {
    let provider: Provider
    let userId: String
    let nickname: String
    let avatarUrl: String?
}
