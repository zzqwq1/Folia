import SwiftUI

/// 首屏加载遮罩，对应 index.html 里的 `#app-splash`：
/// 纯 #09090b 底、居中 28pt 间距的「Folia」词标 + 13 根波形竖条，
/// 词标逐个字母跳到不同字形（Loki 片头那种字体轮盘），竖条按随机高低循环呼吸。
/// 原版淡出 320ms ease；这里同样在首帧之后淡出。
struct SplashView: View {
    /// 词标字号：原版 clamp(64px, 17vw, 200px)
    let titleSize: CGFloat

    struct Bar: Identifiable {
        let id: Int
        let width: CGFloat
        let peak: CGFloat
        let floor: CGFloat
        let alpha: CGFloat
        let glow: CGFloat
        let duration: Double
    }

    struct Glyph: Identifiable {
        let id: Int
        let letter: String
        let font: Font
        let boxWidth: CGFloat
        let scaleX: CGFloat
        let scaleY: CGFloat
        let shadowRadius: CGFloat
        let shadowOpacity: Double
    }

    /// 原版 FAMILIES：Inter / serif / monospace / cursive / fantasy / system-ui
    /// （第二个元素是 iOS 上对应的字体 PostScript 名）
    private static let families: [(label: String, font: String)] = [
        ("Inter", "HelveticaNeue"),
        ("serif", "TimesNewRomanPSMT"),
        ("monospace", "Menlo-Regular"),
        ("cursive", "SnellRoundhand"),
        ("fantasy", "Papyrus"),
        ("system-ui", "HelveticaNeue"),
    ]
    private static let weights: [Font.Weight] = [.regular, .semibold, .heavy]
    private static let letters: [String] = ["F", "o", "l", "i", "a"]

    @State private var bars: [Bar] = SplashView.makeBars()
    @State private var glyphs: [Glyph] = SplashView.makeGlyphs()
    @State private var innerVisible = false

    var body: some View {
        ZStack {
            Color(hex: 0x09090B)

            VStack(spacing: 28) {
                title
                wave
            }
            .opacity(innerVisible ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            // app-splash-in: 420ms ease 180ms forwards
            withAnimation(.easeIn(duration: 0.42).delay(0.18)) {
                innerVisible = true
            }
        }
        .task {
            // 380ms 一拍，一拍只换一个字母，偶尔两个
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 380_000_000)
                guard !Task.isCancelled else { return }
                mutateGlyphs()
            }
        }
    }

    private var title: some View {
        HStack(spacing: 0) {
            ForEach(glyphs) { glyph in
                Text(glyph.letter)
                    .font(glyph.font)
                    .foregroundStyle(Color.white)
                    .shadow(
                        color: Color.white.opacity(glyph.shadowOpacity),
                        radius: glyph.shadowRadius
                    )
                    .scaleEffect(x: glyph.scaleX, y: glyph.scaleY, anchor: .center)
                    .frame(width: titleSize * glyph.boxWidth)
            }
        }
        .font(.system(size: titleSize, weight: .semibold))
        .lineLimit(1)
    }

    private var wave: some View {
        HStack(alignment: .center, spacing: max(6, titleSize * 0.055)) {
            ForEach(bars) { bar in
                SplashBar(bar: bar, height: waveHeight)
            }
        }
        .frame(height: waveHeight)
    }

    /// clamp(42px, 7.5vw, 92px)
    private var waveHeight: CGFloat { min(max(titleSize * 0.46, 42), 92) }

    // MARK: - 随机化

    private static func makeBars() -> [Bar] {
        (0..<13).map { index -> Bar in
            let envelope = sin(((Double(index) + 0.5) / 13.0) * .pi)
            let peak = min(1, 0.32 + envelope * Double.random(in: 0.38...0.72))
            return Bar(
                id: index,
                width: CGFloat.random(in: 3.5...6.5),
                peak: CGFloat(peak),
                floor: CGFloat.random(in: 0.08...0.24),
                alpha: CGFloat.random(in: 0.55...1),
                glow: CGFloat.random(in: 6...26),
                duration: Double.random(in: 0.82...1.5)
            )
        }
    }

    private static func makeGlyphs() -> [Glyph] {
        letters.enumerated().map { index, letter in
            // 盒子宽度：按最大字宽留余量（原版用 canvas 量，这里取经验值）
            let box: CGFloat = (letter == "i" || letter == "l") ? 0.46 : 0.92
            return Glyph(
                id: index,
                letter: letter,
                font: Font.custom("HelveticaNeue", size: 100).weight(.semibold),
                boxWidth: box,
                scaleX: 1,
                scaleY: 1,
                shadowRadius: 10,
                shadowOpacity: 0.45
            )
        }
    }

    private func mutateGlyphs() {
        var next = glyphs
        let swaps = Double.random(in: 0...1) < 0.25 ? 2 : 1
        for _ in 0..<swaps {
            let index = Int.random(in: 0..<next.count)
            let old = next[index]
            let family = Self.families.randomElement() ?? Self.families[0]
            let weight = Self.weights.randomElement() ?? .semibold
            let italic = Double.random(in: 0...1) < 0.25
            let sizeScale = CGFloat.random(in: 0.86...1.12)
            let widthScale: CGFloat = [0.86, 0.94, 1, 1.06, 1.12].randomElement() ?? 1
            let glow = Self.randomGlow()
            var font = Font.custom(family.font, size: 100).weight(weight)
            if italic { font = font.italic() }
            next[index] = Glyph(
                id: old.id,
                letter: old.letter,
                font: font,
                boxWidth: old.boxWidth,
                scaleX: sizeScale * widthScale,
                scaleY: sizeScale,
                shadowRadius: glow.radius,
                shadowOpacity: glow.opacity
            )
        }
        glyphs = next
    }

    /// 辉光分三档：干净、微光、过曝
    private static func randomGlow() -> (radius: CGFloat, opacity: Double) {
        let roll = Double.random(in: 0...1)
        if roll < 0.3 {
            return (CGFloat.random(in: 2...6), 0.35)
        }
        if roll < 0.75 {
            return (CGFloat.random(in: 6...14), 0.7)
        }
        return (CGFloat.random(in: 10...18), 0.95)
    }
}

/// 单根波形竖条：scaleY 在 floor 与 peak 之间循环，奇偶条相位错开一半。
private struct SplashBar: View {
    let bar: SplashView.Bar
    let height: CGFloat

    @State private var high = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(bar.alpha))
            .frame(width: bar.width, height: height)
            .shadow(color: Color.white.opacity(0.35), radius: bar.glow / 2)
            .scaleEffect(y: high ? bar.peak : bar.floor, anchor: .center)
            .onAppear {
                // 原版的负 animation-delay 用初始相位模拟：奇数条从「高」起步、偶数条从「低」起步，
                // 之后统一在 floor ↔ peak 之间来回。
                high = bar.id % 2 == 1
                withAnimation(.easeInOut(duration: bar.duration).repeatForever(autoreverses: true)) {
                    high.toggle()
                }
            }
    }
}
