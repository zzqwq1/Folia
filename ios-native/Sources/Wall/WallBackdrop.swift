import SwiftUI

/// 墙面背景：径向双光斑 + 底色 + 噪点 + 暗角。
/// 对应 .lattice-root 的 background 与 ::before/::after 两层伪元素。
struct WallBackdrop: View {
    let theme: WallTheme
    var hasVignette: Bool = true
    var isLightsOut: Bool = false

    var body: some View {
        ZStack {
            theme.bg

            // radial-gradient(circle at 14% 12%, accent 16%, transparent 29%)
            RadialGradient(
                colors: [theme.accent.opacity(0.16), theme.accent.opacity(0)],
                center: UnitPoint(x: 0.14, y: 0.12),
                startRadius: 0,
                endRadius: 520
            )

            // radial-gradient(circle at 86% 82%, secondary 20%, transparent 32%)
            RadialGradient(
                colors: [theme.secondary.opacity(0.20), theme.secondary.opacity(0)],
                center: UnitPoint(x: 0.86, y: 0.82),
                startRadius: 0,
                endRadius: 620
            )

            // ::after —— feTurbulence baseFrequency .92 / 2 octaves，图层 opacity .13，soft-light
            WallNoise()
                .blendMode(.softLight)
                .opacity(0.13)
                .allowsHitTesting(false)

            if hasVignette {
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.78),
                        .init(color: Color.black.opacity(0.52), location: 1),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 900
                )
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

/// 噪点。原版是一张 inline SVG 的 feTurbulence；这里生成一次位图后平铺，
/// 用量少（只铺满一屏）且可缓存，不会拖慢墙面渲染。
struct WallNoise: View {
    private static let tile: UIImage = WallNoise.makeTile()

    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
    }

    private static func makeTile() -> UIImage {
        let size = 180
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let cg = context.cgContext
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<(size * size / 3) {
                let x = CGFloat(Int.random(in: 0..<size, using: &generator))
                let y = CGFloat(Int.random(in: 0..<size, using: &generator))
                let value = CGFloat(Int.random(in: 0...255, using: &generator)) / 255
                cg.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
}
