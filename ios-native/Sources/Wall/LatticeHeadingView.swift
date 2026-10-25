import SwiftUI

/// 探索墙的一格标题。逐条对齐 `LatticeHeading.tsx` + `LatticeSections.css`：
/// - 直角、`var(--lattice-poster-background)` 底、`poster-ink` 字，裁掉溢出
/// - 序号徽标在左上（`top/left 14`），分段徽标在右上（`right 14`）
/// - 文案块 `right/bottom/left 17`、`gap 8`：标题 `clamp(44, 4vw, 72)` / 行高 0.96 / 字距 -0.045em / 最多两行，
///   副标题 15 / 650 / 0.78 透明度 / 单行省略
/// - 没有标题的段落（`.is-untitled`）：徽标 22px、副标题放大到 `clamp(22, 2vw, 36)` 并允许换行
struct LatticeHeadingView: View {
    let heading: WallHeadingInstance
    let section: WallSectionSpec
    let total: Int
    let theme: WallTheme
    var lightsOut: Bool = false

    private var position: String {
        String(format: "%02d / %02d", heading.section + 1, total)
    }

    /// `.lattice-heading-copy strong { font-size: clamp(44px, 4vw, 72px) }`，vw 用格宽折算
    private func titleFontSize(_ width: CGFloat) -> CGFloat {
        min(max(width * 0.04, 44), 72)
    }

    /// `.is-untitled .lattice-heading-copy small { font-size: clamp(22px, 2vw, 36px) }`
    private func subtitleFontSize(_ width: CGFloat) -> CGFloat {
        min(max(width * 0.02, 22), 36)
    }

    var body: some View {
        let isUntitled = section.heading.isEmpty
        let copyWidth = max(heading.width - 34, 1)

        ZStack(alignment: .topLeading) {
            theme.posterBackground

            VStack(alignment: .leading, spacing: 8) {
                if !isUntitled {
                    let size = titleFontSize(heading.width)
                    let fitted = WallTitleFit.fit(
                        section.heading,
                        width: copyWidth,
                        style: WallTitleFit.Style(fontSize: size, trackingEm: -0.045),
                        lines: 2
                    )
                    Text(fitted)
                        .font(.system(size: size, weight: .bold))
                        .tracking(size * -0.045)
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: copyWidth, alignment: .leading)
                }

                Text(section.summary)
                    .font(.system(size: isUntitled ? subtitleFontSize(heading.width) : 15, weight: .semibold))
                    .tracking(isUntitled ? subtitleFontSize(heading.width) * -0.03 : 0)
                    .foregroundStyle(theme.ink.opacity(isUntitled ? 0.9 : 0.78))
                    .lineLimit(isUntitled ? nil : 1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: isUntitled)
                    .frame(width: copyWidth, alignment: .leading)
            }
            .frame(width: heading.width - 34, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.leading, 17)
            .padding(.trailing, 17)
            .padding(.bottom, 17)

            badge(position, size: isUntitled ? 22 : 11)
                .padding(.leading, 14)
                .padding(.top, 14)

            if heading.parts > 1 {
                badge("\(heading.part + 1)/\(heading.parts)", size: 11)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
                    .padding(.top, 14)
            }

            // `::after`：熄灯时压黑 82%
            Color.black
                .opacity(lightsOut ? 0.82 : 0)
                .allowsHitTesting(false)
        }
        .frame(width: heading.width, height: heading.height, alignment: .topLeading)
        .clipped()
    }

    /// `.lattice-poster-badge`：`padding 5 8`、11 / 800、字距 0.12em、黑 62%；
    /// `.is-untitled` 时 `padding 8 12`、22px
    private func badge(_ text: String, size: CGFloat) -> some View {
        let untitled = size > 11
        return Text(text)
            .font(.system(size: size, weight: .heavy))
            .tracking(size * 0.12)
            .monospacedDigit()
            .foregroundStyle(theme.ink)
            .padding(.vertical, untitled ? 8 : 5)
            .padding(.horizontal, untitled ? 12 : 8)
            .background(Color.black.opacity(0.62))
    }
}
