import Foundation

/// 歌词解析：LRC（`[mm:ss.xx]词`）与网易云逐字 yrc（`[mm:ss.xxx](mm:ss.xxx,mm:ss.xxx,0)字(…)`）。
enum LyricParser {
    static func parse(_ text: String) -> [LyricLine] {
        guard !text.isEmpty else { return [] }
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
}
