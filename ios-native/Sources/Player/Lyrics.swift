import Foundation

/// 单行歌词：主行 + 可选的翻译（对齐 VisualizerSubtitleOverlay 的「主行 + 翻译」）。
struct LyricLine: Identifiable, Equatable {
    let id: UUID
    let time: TimeInterval
    let text: String
    var translation: String?

    init(time: TimeInterval, text: String, translation: String? = nil) {
        self.id = UUID()
        self.time = time
        self.text = text
        self.translation = translation
    }
}

/// LRC 解析：标准 [mm:ss.xx] 标签 + 元信息行过滤 + 翻译合并。
/// 对齐桌面歌词链路的 lrc（主歌词）+ tlyric（翻译）双轨。
enum LyricParser {

    /// 主歌词 + 翻译合并成一行（翻译取时间最接近的翻译行）。
    static func merge(main: String, translation: String?) -> [LyricLine] {
        var mainLines = parse(main)
        guard !mainLines.isEmpty else { return mainLines }
        guard let translation, !translation.isEmpty else { return mainLines }
        let transLines = parse(translation)
        guard !transLines.isEmpty else { return mainLines }

        for i in mainLines.indices {
            let t = mainLines[i].time
            guard let closest = transLines.min(by: { abs($0.time - t) < abs($1.time - t) }),
                  abs(closest.time - t) < 2.0 else { continue }
            mainLines[i].translation = closest.text
        }
        return mainLines
    }

    /// 解析标准 LRC 文本。支持一行多时间戳、mm:ss.xx / mm:ss.xxx 分位。
    static func parse(_ lrcText: String) -> [LyricLine] {
        let pattern = "\\[(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [LyricLine] = []
        for raw in lrcText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            let last = matches[matches.count - 1]
            let bodyStart = last.range.location + last.range.length
            let body = ns.substring(from: bodyStart).trimmingCharacters(in: .whitespaces)
            // 跳过纯标记 / 无正文行（对齐桌面 hasReadableText 过滤）
            guard hasReadableText(body) else { continue }

            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let fracRaw = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
                let frac: Double
                switch fracRaw.count {
                case 3: frac = (Double(fracRaw) ?? 0) / 1000.0
                case 2: frac = (Double(fracRaw) ?? 0) / 100.0
                case 1: frac = (Double(fracRaw) ?? 0) / 10.0
                default: frac = 0
                }
                let time = minutes * 60 + seconds + frac
                lines.append(LyricLine(time: time, text: body))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// 是否存在可读正文（过滤空行 / 纯符号标记行）。
    private static func hasReadableText(_ s: String) -> Bool {
        let stripped = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }
        return stripped.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
    }
}
