import Foundation

/// 歌词解析：四个平台回来的格式各不相同，统一成 [LyricLine]。
///
/// - LRC：`[mm:ss.xx]词`（网易云 / 波点 / 酷狗兜底）
/// - 网易云 yrc：`[mm:ss.xxx](startMs,endMs,0)字`
/// - QQ QRC：`[startMs,durationMs]字(startMs,durationMs)…`
/// - 酷狗 KRC：`[startMs,durationMs]字<offsetMs,durationMs,0>`，另带 `[language:base64]` 翻译
/// - 波点 awlrc：`[mm:ss.xx]…` 逐字行（与 LRC 同一套时间轴，这里只取整行）
enum LyricParser {
    static func parse(_ text: String) -> [LyricLine] {
        guard !text.isEmpty else { return [] }
        if text.contains("[language:") || looksLikeKRC(text) {
            return parseKRC(text)
        }
        if looksLikeQRC(text) {
            return parseQRC(text)
        }
        return parseLRC(text)
    }

    // MARK: - LRC / yrc

    private static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let head = String(line[line.index(after: line.startIndex)..<close])
            guard let start = timestamp(head) else { continue }
            let body = String(line[line.index(after: close)...])

            let (plain, words) = parseWords(body)
            let trimmed = plain.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            lines.append(
                LyricLine(start: start, end: words.last?.end, text: trimmed, words: words)
            )
        }
        lines.sort { $0.start < $1.start }
        return lines
    }

    /// "mm:ss.xx" / "mm:ss.xxx" / "hh:mm:ss.xx"
    private static func timestamp(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// 把行内内容拆成纯文本与逐字时间。yrc 每个字后面跟着 `(startMs,endMs,0)`，
    /// 行首可能还有一个整行时间括号。没有逐字信息时 words 为空。
    private static func parseWords(_ body: String) -> (String, [LyricLine.Word]) {
        guard body.contains("(") else { return (body, []) }

        var plain = ""
        var words: [LyricLine.Word] = []
        var rest = Substring(body)

        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "("),
                  let close = rest[open...].firstIndex(of: ")") else {
                plain += rest
                break
            }
            plain += rest[rest.startIndex..<open]
            let inner = rest[rest.index(after: open)..<close]
            let numbers = inner.split(separator: ",").compactMap { Double($0) }
            let after = rest[rest.index(after: close)...]
            let nextOpen = after.firstIndex(of: "(") ?? after.endIndex
            let chunk = String(after[after.startIndex..<nextOpen])

            if numbers.count >= 2 {
                if !chunk.isEmpty {
                    words.append(
                        LyricLine.Word(start: numbers[0] / 1000, end: numbers[1] / 1000, text: chunk)
                    )
                }
            } else {
                plain += "(" + inner + ")" + chunk
            }
            rest = after[nextOpen...]
        }

        return words.isEmpty ? (body, []) : (plain, words)
    }

    // MARK: - QRC（QQ）

    /// 行头是 `[startMs,durationMs]`，字后面跟 `(startMs,durationMs[,0])`
    private static func looksLikeQRC(_ text: String) -> Bool {
        for raw in text.split(whereSeparator: \.isNewline).prefix(20) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let head = line[line.index(after: line.startIndex)..<close]
            let parts = head.split(separator: ",")
            if parts.count >= 2, Int(parts[0]) != nil, Int(parts[1]) != nil { return true }
        }
        return false
    }

    private static func parseQRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let head = line[line.index(after: line.startIndex)..<close]
            let numbers = head.split(separator: ",").compactMap { Int($0) }
            guard numbers.count >= 2 else { continue }
            let lineStart = Double(numbers[0]) / 1000
            let body = String(line[line.index(after: close)...])

            var words: [LyricLine.Word] = []
            var plain = ""
            var rest = Substring(body)
            while !rest.isEmpty {
                guard let open = rest.firstIndex(of: "("),
                      let end = rest[open...].firstIndex(of: ")") else {
                    plain += rest
                    break
                }
                plain += rest[rest.startIndex..<open]
                let inner = rest[rest.index(after: open)..<end]
                let times = inner.split(separator: ",").compactMap { Double($0) }
                let after = rest[rest.index(after: end)...]
                let nextOpen = after.firstIndex(of: "(") ?? after.endIndex
                let chunk = String(after[after.startIndex..<nextOpen])
                if times.count >= 2, !chunk.isEmpty {
                    words.append(LyricLine.Word(start: times[0] / 1000, end: times[1] / 1000, text: chunk))
                }
                rest = after[nextOpen...]
            }

            let trimmed = plain.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            lines.append(LyricLine(start: lineStart, end: words.last?.end, text: trimmed, words: words))
        }
        lines.sort { $0.start < $1.start }
        return lines
    }

    // MARK: - KRC（酷狗）

    private static func looksLikeKRC(_ text: String) -> Bool {
        for raw in text.split(whereSeparator: \.isNewline).prefix(30) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.contains("<") && line.contains(">") { return true }
            if line.hasPrefix("[") {
                let head = line.prefix(while: { $0 != "]" })
                let parts = head.dropFirst().split(separator: ",")
                if parts.count >= 2, Int(parts[0]) != nil, Int(parts[1]) != nil { return true }
            }
        }
        return false
    }

    /// 行头 `[startMs,durationMs]`，字标签 `<offsetMs,durationMs,0>`（offset 相对行首）。
    /// `[language:base64]` 是翻译行，解出来是 JSON `[{type:1, lyricContent:[[start,text]]}]`。
    private static func parseKRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var translations: [Double: String] = [:]

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") else { continue }

            if line.hasPrefix("[language:") {
                collectTranslations(line, into: &translations)
                continue
            }

            guard let close = line.firstIndex(of: "]") else { continue }
            let head = line[line.index(after: line.startIndex)..<close]
            let numbers = head.split(separator: ",").compactMap { Int($0) }
            guard let first = numbers.first else { continue }
            let lineStartMs = Double(first)
            let lineDurationMs = numbers.count >= 2 ? Double(numbers[1]) : 0
            var rest = Substring(line[line.index(after: close)...])

            var words: [LyricLine.Word] = []
            var plain = ""
            while !rest.isEmpty {
                // 字标签之前的文字（通常是空的）
                if let open = rest.firstIndex(of: "<"), let end = rest[open...].firstIndex(of: ">") {
                    plain += rest[rest.startIndex..<open]
                    let inner = rest[rest.index(after: open)..<end]
                    let times = inner.split(separator: ",").compactMap { Double($0) }
                    let after = rest[rest.index(after: end)...]
                    let nextOpen = after.firstIndex(of: "<") ?? after.endIndex
                    let chunk = String(after[after.startIndex..<nextOpen])
                    if times.count >= 2, !chunk.isEmpty {
                        words.append(LyricLine.Word(
                            start: (lineStartMs + times[0]) / 1000,
                            end: (lineStartMs + times[1]) / 1000,
                            text: chunk
                        ))
                    }
                    rest = after[nextOpen...]
                } else {
                    plain += rest
                    break
                }
            }

            let trimmed = plain.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let start = lineStartMs / 1000
            lines.append(LyricLine(
                start: start,
                end: words.last?.end ?? (start + lineDurationMs / 1000),
                text: trimmed,
                words: words
            ))
        }

        // 有翻译就在同一时间点上拼一行
        if !translations.isEmpty {
            let tolerance = 0.25
            lines = lines.map { line in
                let extra = translations.first { abs($0.key - line.start) <= tolerance }?.value
                guard let extra, !extra.isEmpty, extra != line.text else { return line }
                return LyricLine(start: line.start, end: line.end, text: line.text + "\n" + extra, words: line.words)
            }
        }
        lines.sort { $0.start < $1.start }
        return lines
    }

    private static func collectTranslations(_ line: String, into output: inout [Double: String]) {
        guard let colon = line.firstIndex(of: ":") else { return }
        var payload = String(line[line.index(after: colon)...])
        if payload.hasSuffix("]") { payload.removeLast() }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for entry in json {
            guard (entry["type"] as? Int) == 1 else { continue }
            let rows = entry["lyricContent"] as? [[Any]] ?? []
            for row in rows {
                guard row.count >= 2,
                      let start = (row[0] as? NSNumber)?.doubleValue,
                      let text = row[1] as? String, !text.isEmpty else { continue }
                output[start / 1000] = text
            }
        }
    }
}
