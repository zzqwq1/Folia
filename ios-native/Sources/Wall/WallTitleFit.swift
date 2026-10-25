import SwiftUI
import UIKit
import CoreText

/// 标题拟合：原版 fitSettledTitle.ts 的 fitTitleToWidth。
///
/// 桌面端用 DOM 探针逐字二分，取「不超过 N 行 + 省略号」的最长前缀。
/// 原生侧用 CoreText 量同一段文字在给定字号 / 字距下的行数，算法结构保持一致：
/// 先判断整串是否超行，超行就在字素边界上二分，找到还能放下省略号的最长前缀。
enum WallTitleFit {
    static let maxLines = 3
    static let ellipsis = "…"

    struct Style {
        var fontSize: CGFloat
        /// CSS 的 letter-spacing（em）
        var trackingEm: CGFloat
        var weight: UIFont.Weight = .bold
        var lineHeightMultiple: CGFloat = 0.96
    }

    /// 返回适配 width 的标题（必要时截断并补省略号）。
    /// `minimumScale` 允许在文字太短、行数不够时不做缩放（与 CSS clamp 的行为一致）。
    static func fit(_ text: String, width: CGFloat, style: Style) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, width > 8 else { return trimmed }

        if lineCount(trimmed, width: width, style: style) <= maxLines {
            return trimmed
        }

        let graphemes = Array(trimmed)
        var low = 0
        var high = graphemes.count
        var best = ellipsis

        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(graphemes.prefix(mid))
                .trimmingCharacters(in: .whitespacesAndNewlines) + ellipsis
            if lineCount(candidate, width: width, style: style) <= maxLines {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    /// 行数。CoreText 的 CTFramesetter 会按可用宽度换行，行数为 frame 的实际行数。
    static func lineCount(_ text: String, width: CGFloat, style: Style) -> Int {
        guard !text.isEmpty else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: attributes(style))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: max(width, 1), height: 100_000),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as NSArray
        return lines.count
    }

    private static func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let font = UIFont.systemFont(ofSize: style.fontSize, weight: style.weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineHeightMultiple
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font,
            .kern: style.fontSize * style.trackingEm,
            .paragraphStyle: paragraph,
        ]
    }
}
