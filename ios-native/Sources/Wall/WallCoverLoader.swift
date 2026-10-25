import SwiftUI
import UIKit

/// 多档封面加载器：原版 coverUrl.ts 的 COVER_SIZE_STEPS [256, 512, 1024]。
/// 墙面同一张封面会在很多张卡上重复出现（lattice 是重复的），所以必须在进程内共享缓存，
/// 否则 400 张卡同时发起请求会打爆图片解码。
@MainActor
final class WallCoverLoader: ObservableObject {
    static let shared = WallCoverLoader()

    /// 档位：与 COVER_SIZE_STEPS 一致，1024 只在放大到很深的卡上才用
    enum Tier: Int, CaseIterable {
        case small = 256
        case medium = 512
        case large = 1024
    }

    @Published private(set) var cache: [String: UIImage] = [:]

    private let session: URLSession
    private var inFlight: Set<String> = []

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    static func tier(for requestedPixels: CGFloat) -> Tier {
        if requestedPixels <= 256 { return .small }
        if requestedPixels <= 512 { return .medium }
        return .large
    }

    private static func cacheKey(_ url: URL, tier: Tier) -> String { "\(tier.rawValue)|\(url.absoluteString)" }

    func image(for urlString: String?, tier: Tier) -> UIImage? {
        guard let url = Self.resized(urlString, tier: tier) else { return nil }
        return cache[Self.cacheKey(url, tier: tier)]
    }

    func load(_ urlString: String?, tier: Tier) {
        guard let url = Self.resized(urlString, tier: tier) else { return }
        let key = Self.cacheKey(url, tier: tier)
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)

        Task { [weak self] in
            defer { self?.inFlight.remove(key) }
            guard let (data, _) = try? await session.data(from: url),
                  let image = UIImage(data: data) else { return }
            self?.cache[key] = image
        }
    }

    /// 网易云图床支持 `?param=NyN`；其他源用 `?...` 追加即可，失败时退回原图。
    static func resized(_ urlString: String?, tier: Tier) -> URL? {
        guard var text = urlString, !text.isEmpty else { return nil }
        if text.hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        if !text.contains("param=") {
            text += (text.contains("?") ? "&" : "?") + "param=\(tier.rawValue)y\(tier.rawValue)"
        }
        return URL(string: text)
    }
}

/// 海报底图。封面未到之前显示兜底渐变（原版无封面时的 hsl 兜底），到了之后替换，
/// 并且和 CSS 一样 `background-size: cover; background-position: center`。
struct WallArtwork: View {
    @EnvironmentObject private var covers: WallCoverLoader

    let urlString: String?
    /// 卡片当前需要多少像素（世界尺寸 × 相机缩放 × 屏幕倍率）
    let pixelSize: CGFloat
    /// 兜底渐变的种子（原版用卡片 id 的字符码之和取色相）
    let seed: String
    let theme: WallTheme

    var body: some View {
        let tier = WallCoverLoader.tier(for: pixelSize)
        let image = covers.image(for: urlString, tier: tier)

        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                let pair = theme.fallbackGradient(for: seed)
                LinearGradient(
                    colors: [pair.0, pair.1],
                    startPoint: UnitPoint(x: 0.06, y: 0.06),
                    endPoint: UnitPoint(x: 0.94, y: 0.94)
                )
            }
        }
        .clipped()
        .onAppear { covers.load(urlString, tier: tier) }
        .onChange(of: tier) { _ in covers.load(urlString, tier: tier) }
    }
}
